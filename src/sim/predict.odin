package sim

// Trajectory predictor (docs/DESIGN.md §4.4). From a relative state it walks
// forward on rails, finding the next sphere-of-influence event by sampling
// and bisection, and returns the list of conic segments. The same event list
// drives the on-rails ship (events are applied exactly at their time) and
// the drawn path.

import "core:math"
import gen "sim:gen"
import orbit "sim:orbit"

Event_Kind :: enum u8 {
	Horizon, // ran out of prediction time
	Exit,    // leaves the primary's sphere of influence
	Enter,   // enters `target`'s sphere of influence
	Collide, // hits the primary's surface
	Node,    // a planned impulsive burn (`node` indexes the plan)
}

Segment :: struct {
	primary: gen.Body_Handle,
	orbit:   orbit.Orbit,
	t0, t1:  f64,
	end:     Event_Kind,
	target:  gen.Body_Handle, // for Enter
	node:    int,             // for Node
}

// A planned burn (docs/DESIGN.md §4.6): time plus Δv in the local frame at
// that time. Prograde is along velocity; radial is the outward normal.
Node :: struct {
	t:        f64,
	prograde: f64,
	radial:   f64,
}

node_dv :: proc(n: Node) -> f64 {
	return math.sqrt(n.prograde * n.prograde + n.radial * n.radial)
}

// Local frame unit vectors for a relative state.
local_frame :: proc(pos, vel: [2]f64) -> (prograde, radial: [2]f64) {
	v := orbit.length(vel)
	prograde = v > 0 ? vel / v : [2]f64{1, 0}
	n := pos - prograde * orbit.dot(pos, prograde)
	nl := orbit.length(n)
	radial = nl > 1e-9 ? n / nl : [2]f64{-prograde.y, prograde.x}
	return
}

// World-frame Δv of a node applied at a relative state.
node_dv_world :: proc(n: Node, pos, vel: [2]f64) -> [2]f64 {
	p, r := local_frame(pos, vel)
	return p * n.prograde + r * n.radial
}

HORIZON_MAX  :: 120.0 * 86400.0
MAX_SEGMENTS :: 8
MAX_SAMPLES  :: 20000
STAR_HYPERBOLA_HORIZON :: 20.0 * 86400.0 // a ship leaving the star's frame is not tracked forever

// Walk forward from a relative state, applying `nodes` (sorted by time) as
// impulses where they fall.
predict :: proc(sys: ^gen.System, primary: gen.Body_Handle, pos, vel: [2]f64, t: f64, out: ^[dynamic]Segment, nodes: []Node = nil) {
	clear(out)
	p := primary
	pos := pos
	vel := vel
	t0 := t
	next_node := 0
	for next_node < len(nodes) && nodes[next_node].t <= t0 do next_node += 1
	for _ in 0 ..< MAX_SEGMENTS + len(nodes) {
		b := &sys.bodies[p]
		o := orbit.from_state(pos, vel, b.mu, t0)
		horizon := HORIZON_MAX
		if o.e < 1 do horizon = min(orbit.period(o) * 1.02, HORIZON_MAX)
		// A planned node always ends the segment, even past the natural
		// horizon: the plan must be followed to be drawn or measured.
		t_limit := t0 + horizon
		node_here := next_node < len(nodes)
		if node_here do t_limit = nodes[next_node].t
		ev, te, target := find_event(sys, p, o, t0, t_limit)
		seg := Segment{primary = p, orbit = o, t0 = t0, t1 = te, end = ev, target = target, node = -1}
		if ev == .Horizon && node_here {
			seg.end = .Node
			seg.node = next_node
		}
		append(out, seg)
		switch seg.end {
		case .Horizon, .Collide:
			return
		case .Exit:
			rp, rv := orbit.state_at(o, te)
			pos, vel, p = to_parent_frame(sys, p, rp, rv, te)
		case .Enter:
			rp, rv := orbit.state_at(o, te)
			pos, vel = to_child_frame(sys, target, rp, rv, te)
			p = target
		case .Node:
			pos, vel = orbit.state_at(o, te)
			vel += node_dv_world(nodes[next_node], pos, vel)
			next_node += 1
		}
		t0 = te
	}
}

@(private = "file")
find_event :: proc(sys: ^gen.System, p: gen.Body_Handle, o: orbit.Orbit, t0, t_end: f64) -> (Event_Kind, f64, gen.Body_Handle) {
	b := &sys.bodies[p]
	t_end := t_end
	rp := orbit.periapsis(o)
	ra := o.e < 1 ? orbit.apoapsis(o) : 1e300
	// A hyperbola leaves the sphere at a known time: no need to scan past it.
	if o.e >= 1 {
		if p != gen.STAR {
			ch := (1 - b.soi / o.a) / o.e
			if ch > 1 {
				H := math.acosh(ch)
				M := o.e * math.sinh(H) - H
				n := orbit.mean_motion(o)
				t_exit := (o.t0 - o.M0 / n) + M / n
				if t_exit > t0 do t_end = min(t_end, t_exit + 60)
			}
		} else {
			t_end = min(t_end, t0 + STAR_HYPERBOLA_HORIZON)
		}
	}
	// Only children whose orbits the path can actually reach are checked.
	kids := make([dynamic]gen.Body_Handle, context.temp_allocator)
	for &cb, ci in sys.bodies {
		if cb.parent != p do continue
		lo := orbit.periapsis(cb.orbit) - cb.soi
		hi := orbit.apoapsis(cb.orbit) + cb.soi
		if hi < rp || lo > ra do continue
		append(&kids, gen.Body_Handle(ci))
	}

	v_peri := math.sqrt(max(o.mu * (2 / rp - 1 / o.a), 1e-12))
	// Base step from the orbit itself. Each reachable child has a radial band
	// (its orbit plus its sphere) and a tight step that cannot skip its
	// sphere (half a sphere per step); the tight step only applies while the
	// ship is inside that band, and only then is the child's position solved.
	Kid :: struct {
		h:      gen.Body_Handle,
		lo, hi: f64, // radial band
		tight:  f64, // step inside the band
	}
	kinfo := make([dynamic]Kid, context.temp_allocator)
	for c in kids {
		cb := &sys.bodies[c]
		vc := orbit.circular_speed(b.mu, cb.orbit.a)
		append(&kinfo, Kid{h = c, lo = orbit.periapsis(cb.orbit) - cb.soi, hi = orbit.apoapsis(cb.orbit) + cb.soi, tight = max(0.5 * cb.soi / (v_peri + vc), 0.5)})
	}
	base_h := o.e < 1 ? orbit.period(o) / 300 : (t_end - t0) / 500
	base_h = max(base_h, 0.5)
	if (t_end - t0) / base_h > MAX_SAMPLES do base_h = (t_end - t0) / MAX_SAMPLES
	// Step allowed from radius r: tight inside a child's band, otherwise no
	// further than the nearest band edge could be reached at periapsis speed.
	step_from :: proc(kinfo: []Kid, base_h, v_peri, r: f64) -> f64 {
		h := base_h
		for k in kinfo {
			if r >= k.lo && r <= k.hi {
				h = min(h, k.tight)
			} else {
				dist := r < k.lo ? k.lo - r : r - k.hi
				h = min(h, max(dist / v_peri, k.tight))
			}
		}
		return h
	}
	h := step_from(kinfo[:], base_h, v_peri, orbit.length(orbit.position_at(o, t0)))

	// Conditions, each "true" when the event has happened at time t.
	collide :: proc(sys: ^gen.System, p: gen.Body_Handle, o: orbit.Orbit, t: f64, _: gen.Body_Handle) -> bool {
		return orbit.length(orbit.position_at(o, t)) < sys.bodies[p].radius
	}
	exit :: proc(sys: ^gen.System, p: gen.Body_Handle, o: orbit.Orbit, t: f64, _: gen.Body_Handle) -> bool {
		pos, vel := orbit.state_at(o, t)
		return orbit.length(pos) > sys.bodies[p].soi && orbit.dot(pos, vel) > 0
	}
	enter :: proc(sys: ^gen.System, p: gen.Body_Handle, o: orbit.Orbit, t: f64, c: gen.Body_Handle) -> bool {
		pos, vel := orbit.state_at(o, t)
		cp, cv := orbit.state_at(sys.bodies[c].orbit, t)
		d := pos - cp
		return orbit.length(d) < sys.bodies[c].soi && orbit.dot(d, vel - cv) < 0
	}
	Cond :: #type proc(sys: ^gen.System, p: gen.Body_Handle, o: orbit.Orbit, t: f64, c: gen.Body_Handle) -> bool

	refine :: proc(sys: ^gen.System, p: gen.Body_Handle, o: orbit.Orbit, lo, hi: f64, c: gen.Body_Handle, cond: Cond) -> f64 {
		lo, hi := lo, hi
		for _ in 0 ..< 40 {
			mid := (lo + hi) * 0.5
			if cond(sys, p, o, mid, c) do hi = mid
			else do lo = mid
			if hi - lo < 1e-3 do break
		}
		return hi
	}

	// An ellipse with no reachable children repeats: if one period is clear,
	// the rest of the span is too.
	scan_end := t_end
	if o.e < 1 && len(kids) == 0 do scan_end = min(t_end, t0 + orbit.period(o) * 1.001)

	// One Kepler solve per sample; the condition procs above are only used to
	// refine once a sample trips.
	prev := t0
	for prev < scan_end {
		t := min(prev + h, scan_end)
		pos, vel := orbit.state_at(o, t)
		r := orbit.length(pos)
		if r < b.radius do return .Collide, refine(sys, p, o, prev, t, gen.NONE, collide), gen.NONE
		if p != gen.STAR && r > b.soi && orbit.dot(pos, vel) > 0 do return .Exit, refine(sys, p, o, prev, t, gen.NONE, exit), gen.NONE
		// Children are only solved while the ship is inside their band.
		for k in kinfo {
			if r < k.lo || r > k.hi do continue
			cb := &sys.bodies[k.h]
			cp, cv := orbit.state_at(cb.orbit, t)
			d := pos - cp
			if orbit.length(d) < cb.soi && orbit.dot(d, vel - cv) < 0 {
				return .Enter, refine(sys, p, o, prev, t, k.h, enter), k.h
			}
		}
		h = step_from(kinfo[:], base_h, v_peri, r)
		prev = t
	}
	return .Horizon, t_end, gen.NONE
}
