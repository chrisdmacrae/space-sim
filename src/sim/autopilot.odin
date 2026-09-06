package sim

// Autopilot, part one (docs/DESIGN.md §4.6): Lambert-based transfers between
// children of a common parent body, with an escape leg from the ship's
// current primary and a capture leg at the destination. A search over
// departure time and flight time scores every transfer; each objective picks
// its own. The chosen plan is flown as nodes, stage by stage, replanning
// after each burn.

import "core:fmt"
import "core:math"
import core "sim:core"

SHOOT_DEBUG :: #config(SHOOT_DEBUG, false)
import econ "sim:econ"
import gen "sim:gen"
import orbit "sim:orbit"

Objective :: enum u8 {
	Fuel,
	Time,
	Balanced,
	Simplest,
}

Dest_Kind :: enum u8 {
	None,
	Body,
	Station,
	Point, // a waypoint: `point` relative to body `index`
	Npc,   // another ship: `index` in the fleet, with its orbit snapshotted in `orbit` about `primary`
}

Destination :: struct {
	kind:    Dest_Kind,
	index:   int,
	point:   [2]f64,
	label:   string, // what to call it in the UI; falls back to the frame's own name
	orbit:   orbit.Orbit,    // Npc: the target's orbit (refreshed by the game while it coasts)
	primary: gen.Body_Handle, // Npc: the body that orbit is about
}

Candidate :: struct {
	ok:        bool, // solvable
	fits:      bool, // within the propellant budget
	t_depart:  f64,
	t_arrive:  f64,
	v1, v2:    [2]f64, // transfer velocities in the common frame
	dv_depart: f64,
	dv_arrive: f64,
	dv_total:  f64,
	flyby:     bool, // routed via a gravity assist (see flyby.odin)
}

// Everything the search needs, fixed for a (ship, destination) pair.
Geometry :: struct {
	lca:         gen.Body_Handle, // common frame the transfer happens in
	mu:          f64,
	dir:         f64,             // direction of motion in that frame
	dep_body:    gen.Body_Handle, // ship's primary when it is a child of lca; NONE when the ship orbits lca
	park_r:      f64,             // ship's orbit radius and speed about dep_body
	park_v:      f64,
	park_period: f64,
	arr_body:    gen.Body_Handle, // destination body (child of lca), or NONE for a station orbiting lca
	cap_r:       f64,             // capture orbit radius about arr_body
	station:     int,             // destination station index, or -1
	is_point:    bool,            // waypoint in the lca frame
	point:       [2]f64,
	is_npc:      bool,            // rendezvous with another ship on `npc_orbit`
	npc_orbit:   orbit.Orbit,
}

Stage :: enum u8 {
	Idle,
	Depart,  // departure (or escape) burn armed
	Correct, // mid-course correction armed
	Coast,   // waiting for the encounter
	Capture, // capture burn armed
	Flyby,   // inside the assist body's sphere, waiting to come out
	Dock,    // matched with the station; waiting to be close and slow
	Done,
	Failed,
}

Autopilot :: struct {
	active:    bool,
	stage:     Stage,
	objective: Objective,
	dest:      Destination,
	geo:       Geometry,
	cand:      Candidate,
	status:    string, // static text
	attempts:  int,
	last_try:  f64,
	legs:      int,    // sub-plans flown so far (capture, then rendezvous)
	last_check: f64,   // game time of the last (costly) miss check
	fb:        Flyby,  // valid when cand.flyby
	leg:       int,    // 0: to the flyby body (or straight to the target); 1: after the flyby
	direct_only: bool, // the pilot asked for no assists: sub-plans stay direct too
}

// The body the current leg is heading for.
leg_target :: proc(ap: ^Autopilot) -> gen.Body_Handle {
	if ap.cand.flyby && ap.leg == 0 do return ap.fb.via
	return ap.geo.arr_body
}

leg_t_arrive :: proc(ap: ^Autopilot) -> f64 {
	if ap.cand.flyby && ap.leg == 0 do return ap.fb.t_via
	return ap.cand.t_arrive
}

leg_v2 :: proc(ap: ^Autopilot) -> [2]f64 {
	if ap.cand.flyby && ap.leg == 0 do return ap.fb.v_in
	return ap.cand.v2
}

set_leg_arrival :: proc(ap: ^Autopilot, t_a: f64, v2: [2]f64) {
	if ap.cand.flyby && ap.leg == 0 {
		ap.fb.t_via = t_a
		ap.fb.v_in = v2
	} else {
		ap.cand.t_arrive = t_a
		ap.cand.v2 = v2
	}
}

leg_t_start :: proc(ap: ^Autopilot) -> f64 {
	if ap.cand.flyby && ap.leg == 1 do return ap.fb.t_via
	return ap.cand.t_depart
}

CHECK_EVERY :: 900.0 // game seconds between miss checks while coasting

// ---------------------------------------------------------------- geometry

@(private = "file")
depth :: proc(sys: ^gen.System, h: gen.Body_Handle) -> int {
	d := 0
	for x := h; x != gen.NONE; x = sys.bodies[x].parent do d += 1
	return d
}

@(private = "file")
parent_of :: proc(sys: ^gen.System, h: gen.Body_Handle) -> gen.Body_Handle {
	return sys.bodies[h].parent
}

// Capture altitude at a body: same rule as spawn_in_orbit.
capture_radius :: proc(sys: ^gen.System, h: gen.Body_Handle) -> f64 {
	return gen.low_orbit(sys.bodies[h])
}

// Where a trade at market `idx` happens: the station to dock at, or the
// colony's body to orbit.
market_dest :: proc(e: ^econ.Economy, idx: int) -> Destination {
	m := &e.markets[idx]
	if m.station >= 0 do return Destination{kind = .Station, index = m.station}
	return Destination{kind = .Body, index = int(m.body)}
}

// Is the ship close enough to a colony's body for shuttles: coasting in
// its frame inside shuttle range.
at_colony :: proc(sys: ^gen.System, s: ^Ship, body: gen.Body_Handle) -> bool {
	if s.mode != .On_Rails || s.primary != body do return false
	return orbit.length(s.pos) <= gen.shuttle_range(sys.bodies[body])
}

// Work out the common frame and the legs. Unsupported shapes return a reason.
geometry :: proc(sys: ^gen.System, s: ^Ship, dest: Destination) -> (geo: Geometry, ok: bool, reason: string) {
	geo.station = -1
	target: gen.Body_Handle
	switch dest.kind {
	case .Body:
		target = gen.Body_Handle(dest.index)
	case .Station:
		geo.station = dest.index
		target = sys.stations[dest.index].parent
	case .Point:
		target = gen.Body_Handle(dest.index)
		geo.is_point = true
		geo.point = dest.point
	case .Npc:
		target = dest.primary
		geo.is_npc = true
		geo.npc_orbit = dest.orbit
		if dest.orbit.mu <= 0 do return {}, false, "that ship is not coasting on an orbit"
	case .None:
		return {}, false, "no destination"
	}
	if is_dead(s) do return {}, false, "ship is wrecked"

	ship_frame := s.primary
	if dest.kind == .Point {
		// A waypoint is just a place in its frame: in our frame, or one level up.
		if target == ship_frame {
			geo.lca = ship_frame
			geo.dep_body = gen.NONE
			geo.dir = s.orbit.dir
		} else if parent_of(sys, ship_frame) == target {
			geo.lca = target
			geo.dep_body = ship_frame
			geo.park_r = orbit.length(s.pos)
			geo.park_v = orbit.length(s.vel)
			geo.park_period = orbit.period(s.orbit)
			geo.dir = sys.bodies[ship_frame].orbit.dir
		} else {
			return {}, false, "waypoint must be in this frame or the parent's"
		}
		geo.mu = sys.bodies[geo.lca].mu
		geo.arr_body = gen.NONE
		return geo, true, ""
	}
	if dest.kind == .Body && target == ship_frame do return {}, false, "already orbiting it"
	if (dest.kind == .Station || dest.kind == .Npc) && target == ship_frame {
		// Station or ship around our own primary: a transfer within this frame.
		geo.lca = ship_frame
		geo.mu = sys.bodies[geo.lca].mu
		geo.dir = s.orbit.dir
		geo.dep_body = gen.NONE
		geo.arr_body = gen.NONE
		return geo, true, ""
	}

	// Common ancestor.
	a := ship_frame
	b := target
	for depth(sys, a) > depth(sys, b) do a = parent_of(sys, a)
	for depth(sys, b) > depth(sys, a) do b = parent_of(sys, b)
	for a != b {
		a = parent_of(sys, a)
		b = parent_of(sys, b)
	}
	geo.lca = a
	if geo.lca == gen.NONE do return {}, false, "no common frame"
	geo.mu = sys.bodies[geo.lca].mu

	// Departure side: at most one level below the common frame.
	if ship_frame == geo.lca {
		geo.dep_body = gen.NONE
		geo.dir = s.orbit.dir
	} else if parent_of(sys, ship_frame) == geo.lca {
		geo.dep_body = ship_frame
		geo.park_r = orbit.length(s.pos)
		geo.park_v = orbit.length(s.vel)
		geo.park_period = orbit.period(s.orbit)
		geo.dir = sys.bodies[ship_frame].orbit.dir
	} else {
		return {}, false, "escape to the parent body first"
	}

	// Arrival side.
	if dest.kind == .Body {
		if target == geo.lca do return {}, false, "destination is the parent frame; lower the orbit by hand"
		if parent_of(sys, target) != geo.lca do return {}, false, "plan to its parent body first"
		geo.arr_body = target
		geo.cap_r = capture_radius(sys, target)
	} else {
		if target == geo.lca {
			geo.arr_body = gen.NONE
		} else if parent_of(sys, target) == geo.lca {
			geo.arr_body = target
			geo.cap_r = dest.kind == .Npc ? max(orbit.periapsis(dest.orbit), sys.bodies[target].radius * 1.5) : sys.stations[dest.index].orbit.a
		} else {
			return {}, false, dest.kind == .Npc ? "plan to that ship's planet first" : "plan to the station's planet first"
		}
	}
	if geo.dep_body == gen.NONE && geo.dir == 0 do geo.dir = 1
	return geo, true, ""
}

// Ship's state in the common frame at time t. A ship parked around a child
// body is treated as riding that body.
ship_frame_state :: proc(sys: ^gen.System, geo: Geometry, s: ^Ship, t: f64) -> (pos, vel: [2]f64) {
	if geo.dep_body != gen.NONE do return orbit.state_at(sys.bodies[geo.dep_body].orbit, t)
	return orbit.state_at(s.orbit, t)
}

// Destination's state in the common frame at time t.
target_frame_state :: proc(sys: ^gen.System, geo: Geometry, t: f64) -> (pos, vel: [2]f64) {
	if geo.is_point do return geo.point, {}
	if geo.arr_body != gen.NONE do return orbit.state_at(sys.bodies[geo.arr_body].orbit, t)
	if geo.is_npc do return orbit.state_at(geo.npc_orbit, t)
	return orbit.state_at(sys.stations[geo.station].orbit, t)
}

// Δv to leave a parking orbit with hyperbolic excess v_inf (Oberth).
escape_dv :: proc(mu, r, v_now, v_inf: f64) -> f64 {
	return math.sqrt(v_inf * v_inf + 2 * mu / r) - v_now
}

// Δv to capture from excess v_inf into a circular orbit of radius r.
capture_dv :: proc(mu, r, v_inf: f64) -> f64 {
	return math.sqrt(v_inf * v_inf + 2 * mu / r) - math.sqrt(mu / r)
}

// At game scale a sphere of influence is small next to the escape
// hyperbola, so the speed relative to a body at its sphere's edge is well
// above the excess speed. Transfers are solved to the edge, so costs use
// the edge speed: v_edge^2 = v_inf^2 + 2 mu / soi.
excess_from_edge :: proc(mu, soi, v_edge: f64) -> (v_inf: f64, short: f64) {
	esc := math.sqrt(2 * mu / soi)
	if v_edge >= esc do return math.sqrt(v_edge * v_edge - esc * esc), 0
	return 0, esc - v_edge // slower than any escape can leave (or any approach can arrive)
}

// Departure cost from a parking orbit to a required edge speed: escape with
// the matching excess, plus a brake after exit if the plan wants less than
// the minimum an escape can deliver.
depart_dv :: proc(mu, soi, park_r, park_v, v_edge: f64) -> f64 {
	v_inf, short := excess_from_edge(mu, soi, v_edge)
	return escape_dv(mu, park_r, park_v, v_inf) + short
}

arrive_dv :: proc(mu, soi, cap_r, v_edge: f64) -> f64 {
	v_inf, short := excess_from_edge(mu, soi, v_edge)
	return capture_dv(mu, cap_r, v_inf) + short
}

// A transfer conic from `pos` with velocity `v` about `mu` must clear the
// central body: reject anything whose periapsis dips below `min_r`.
clears_body :: proc(pos, v: [2]f64, mu, min_r: f64) -> bool {
	o := orbit.from_state(pos, v, mu, 0)
	return orbit.periapsis(o) > min_r
}

// A transfer flown inside a body's sphere must not bulge out of it: an
// arc that leaves the sphere ends up in the parent frame, not at the target.
stays_in_sphere :: proc(sys: ^gen.System, frame: gen.Body_Handle, pos, v: [2]f64, mu: f64) -> bool {
	if frame == gen.STAR do return true
	o := orbit.from_state(pos, v, mu, 0)
	if o.e >= 1 do return false
	return orbit.apoapsis(o) < sys.bodies[frame].soi * 0.9
}

// Minimum safe periapsis about a body: above the surface with margin.
safe_radius :: proc(sys: ^gen.System, h: gen.Body_Handle) -> f64 {
	b := sys.bodies[h]
	if h == gen.STAR do return max(b.radius * 1.6, sys.star.heat_radius * 1.05, sys.star.wind_radius * 1.05)
	return b.radius * 1.3
}

// Propellant left after spending dv from the current mass.
propellant_after :: proc(s: ^Ship, dv: f64) -> f64 {
	m0 := mass(s)
	m1 := m0 * math.exp(-dv / ve_eff(s))
	return s.propellant - (m0 - m1)
}

// Score one transfer.
evaluate :: proc(sys: ^gen.System, geo: Geometry, s: ^Ship, t_d, tf: f64, budget: f64) -> (c: Candidate) {
	c.t_depart = t_d
	c.t_arrive = t_d + tf
	p1, vs := ship_frame_state(sys, geo, s, t_d)
	p2, vt := target_frame_state(sys, geo, c.t_arrive)
	v1, v2, ok := orbit.lambert(p1, p2, tf, geo.mu, geo.dir)
	if !ok do return
	if !clears_body(p1, v1, geo.mu, safe_radius(sys, geo.lca)) do return
	if geo.arr_body == gen.NONE && !stays_in_sphere(sys, geo.lca, p1, v1, geo.mu) do return
	c.v1, c.v2 = v1, v2
	if geo.dep_body != gen.NONE {
		pb := sys.bodies[geo.dep_body]
		c.dv_depart = depart_dv(pb.mu, pb.soi, geo.park_r, geo.park_v, orbit.length(v1 - vs))
	} else {
		c.dv_depart = orbit.length(v1 - vs)
	}
	if geo.arr_body != gen.NONE {
		ab := sys.bodies[geo.arr_body]
		c.dv_arrive = arrive_dv(ab.mu, ab.soi, geo.cap_r, orbit.length(v2 - vt))
	} else if geo.is_point {
		c.dv_arrive = 0 // a waypoint is passed through, not stopped at
	} else {
		c.dv_arrive = orbit.length(v2 - vt)
	}
	c.dv_total = c.dv_depart + c.dv_arrive
	c.ok = true
	c.fits = c.dv_total <= budget
	return
}

// ---------------------------------------------------------------- search

// One route the player can pick: a candidate transfer, the assist it uses
// (if any), and which objectives it is the best answer for.
Route_Option :: struct {
	cand:      Candidate,
	fb:        Flyby,
	via:       gen.Body_Handle,    // NONE for a direct transfer
	tags:      bit_set[Objective], // objectives this option wins
	objective: Objective,          // scoring used if the route is re-planned mid-flight
}

MAX_OPTIONS :: 4 + 2 * 8

OBJECTIVE_NAMES :: [Objective]string{.Fuel = "cheapest", .Time = "fastest", .Balanced = "balanced", .Simplest = "earliest"}

Search_Result :: struct {
	picks:   [Objective]Candidate, // best overall per objective (flybys included)
	flybys:  [Objective]Flyby,
	direct:  [Objective]Candidate, // best direct transfer per objective
	options: [MAX_OPTIONS]Route_Option, // direct routes first, then per assist body
	n_options: int,
	flyby_best:    Candidate, // cheapest feasible flyby, whether or not an objective chose it
	flyby_best_fb: Flyby,
	dv_best: f64,
	t_best:  f64, // earliest feasible arrival
	reason:  string,
	ok:      bool,
}

better :: proc(obj: Objective, a, b: Candidate, res: Search_Result, now: f64) -> bool {
	// Is a better than b for the objective?
	if !a.ok do return false
	if !b.ok do return true
	switch obj {
	case .Fuel:
		return a.dv_total < b.dv_total
	case .Time:
		if a.fits != b.fits do return a.fits
		return a.t_arrive < b.t_arrive
	case .Balanced:
		if a.fits != b.fits do return a.fits
		k := f64(core.tuning.k_time)
		ca := a.dv_total / res.dv_best + k * (a.t_arrive - now) / (res.t_best - now)
		cb := b.dv_total / res.dv_best + k * (b.t_arrive - now) / (res.t_best - now)
		return ca < cb
	case .Simplest:
		// Fewest burns is a tie today (always two); prefer leaving soon among
		// plans that are not much dearer than the cheapest.
		la := a.dv_total <= 1.3 * res.dv_best
		lb := b.dv_total <= 1.3 * res.dv_best
		if la != lb do return la
		if a.fits != b.fits do return a.fits
		return a.t_depart < b.t_depart
	}
	return false
}

// Grid over departure time and flight time, then a local refinement per
// objective.
// `fast` trades grid density for speed (traders); the player gets the full grid.
search :: proc(sys: ^gen.System, s: ^Ship, geo: Geometry, now: f64, fast := false) -> (res: Search_Result) {
	budget := dv_remaining(s) * 0.95
	p1, _ := ship_frame_state(sys, geo, s, now)
	p2, _ := target_frame_state(sys, geo, now)
	r1 := orbit.length(p1)
	r2 := orbit.length(p2)
	if r1 <= 0 || r2 <= 0 {
		res.reason = "degenerate geometry"
		return
	}
	a_h := (r1 + r2) * 0.5
	t_h := math.PI * math.sqrt(a_h * a_h * a_h / geo.mu) // Hohmann flight time
	n1 := math.sqrt(geo.mu / (r1 * r1 * r1))
	n2 := math.sqrt(geo.mu / (r2 * r2 * r2))
	synodic := abs(n1 - n2) > 1e-12 ? 2 * math.PI / abs(n1 - n2) : 20 * t_h
	window := clamp(synodic, 2 * math.PI / max(n1, n2), 25 * t_h)

	lead := 600.0
	if geo.dep_body != gen.NONE {
		// Need at least one parking orbit to line up the escape, plus the climb out.
		pb := sys.bodies[geo.dep_body]
		lead = geo.park_period * 1.1 + pb.soi / max(math.sqrt(pb.mu / geo.park_r), 1e-6)
	}

	ND_FULL :: 48
	NF_FULL :: 40
	nd := fast ? 16 : ND_FULL
	nf := fast ? 12 : NF_FULL
	res.dv_best = 1e300
	res.t_best = 1e300
	grid: [ND_FULL * NF_FULL]Candidate
	for i in 0 ..< nd {
		t_d := now + lead + window * f64(i) / f64(nd - 1)
		for j in 0 ..< nf {
			tf := t_h * math.exp(math.ln(0.35) + (math.ln(2.5) - math.ln(0.35)) * f64(j) / f64(nf - 1))
			c := evaluate(sys, geo, s, t_d, tf, budget)
			grid[i * nf + j] = c
			if !c.ok do continue
			res.dv_best = min(res.dv_best, c.dv_total)
			if c.fits do res.t_best = min(res.t_best, c.t_arrive)
		}
	}
	if res.dv_best >= 1e300 {
		res.reason = "no transfer found"
		return
	}
	if res.t_best >= 1e300 do res.t_best = now + lead + t_h // nothing fits; keep the scale sane
	res.ok = true

	dt_d := window / f64(nd - 1)
	for obj in Objective {
		best: Candidate
		for c in grid[:nd * nf] do if better(obj, c, best, res, now) do best = c
		// Refine: shrinking 5x5 boxes around the pick.
		step_d := dt_d
		step_f := best.t_arrive - best.t_depart
		for _ in 0 ..< (fast ? 2 : 4) {
			step_d *= 0.5
			step_f *= 0.25
			center := best
			for i in -2 ..= 2 {
				for j in -2 ..= 2 {
					t_d := center.t_depart + f64(i) * step_d
					tf := (center.t_arrive - center.t_depart) + f64(j) * step_f
					if t_d < now + lead || tf <= 0 do continue
					c := evaluate(sys, geo, s, t_d, tf, budget)
					if better(obj, c, best, res, now) do best = c
				}
			}
		}
		res.picks[obj] = best
	}
	res.direct = res.picks
	// Direct options, one per distinct transfer; objectives that land on
	// the same transfer share a row.
	for obj in Objective {
		c := res.direct[obj]
		if !c.ok do continue
		merged := false
		for k in 0 ..< res.n_options {
			o := &res.options[k]
			if abs(o.cand.t_depart - c.t_depart) < 1 && abs(o.cand.t_arrive - c.t_arrive) < 1 {
				o.tags += {obj}
				merged = true
				break
			}
		}
		if !merged do add_option(&res, Route_Option{cand = c, via = gen.NONE, tags = {obj}, objective = obj})
	}
	search_flybys(sys, s, geo, now, &res, &res.flybys, fast)
	return
}

add_option :: proc(res: ^Search_Result, o: Route_Option) {
	if res.n_options >= MAX_OPTIONS do return
	res.options[res.n_options] = o
	res.n_options += 1
}

// ---------------------------------------------------------------- flying

// Both track body scale (core/units.odin): orbits about a body are sized off
// its radius, so a tolerance in world units has to grow with it.
FORMATION_RANGE :: 36.0  // world units: near enough to snap into formation
FORMATION_SPEED :: 0.02  // relative speed the formation snap absorbs

// Park on another ship's orbit a little behind it: same elements, so the
// two keep station without any further burns.
hold_formation :: proc(sys: ^gen.System, s: ^Ship, host: orbit.Orbit, t: f64) {
	s.pos, s.vel = formation_state(host, t)
	s.orbit = orbit.from_state(s.pos, s.vel, sys.bodies[s.primary].mu, t)
	s.throttle = 0
	s.hold = .None
	s.autoburn.active = false
	clear(&s.nodes)
	repredict(sys, s, t)
}

// Aim offset so the arrival hyperbola's periapsis sits at cap_r: the impact
// parameter b, applied perpendicular to the excess velocity on the side that
// gives a prograde capture.
aim_point :: proc(sys: ^gen.System, geo: Geometry, v2: [2]f64, t_a: f64) -> [2]f64 {
	p2, vt := target_frame_state(sys, geo, t_a)
	if geo.arr_body == gen.NONE do return p2
	ab := sys.bodies[geo.arr_body]
	v_rel := v2 - vt
	vr := orbit.length(v_rel)
	if vr < 1e-9 do return p2
	// Angular momentum b*v_rel at the edge must equal r_p*v_p at periapsis,
	// with energy taken from the edge, not from infinity. A slow approach to
	// a light body has negative edge energy; the formula still holds.
	v_p := math.sqrt(max(vr * vr - 2 * ab.mu / ab.soi + 2 * ab.mu / geo.cap_r, 1e-12))
	b := geo.cap_r * v_p / vr
	return p2 + orbit.rotate(v_rel / vr, -ab.orbit.dir * math.PI / 2) * b
}

// Aim point for the current leg: the capture offset at the destination, or
// the flyby offset that produces the planned turn at the assist body.
aim_leg :: proc(sys: ^gen.System, ap: ^Autopilot, v2: [2]f64, t_a: f64) -> [2]f64 {
	if !(ap.cand.flyby && ap.leg == 0) do return aim_point(sys, ap.geo, v2, t_a)
	b := sys.bodies[ap.fb.via]
	pm, vm := orbit.state_at(b.orbit, t_a)
	v_in := v2 - vm
	v_out := ap.fb.v_out - vm
	vr := orbit.length(v_in)
	if vr < 1e-9 do return pm
	r_p := ap.fb.r_p
	if rp, _, ok := flyby_turn(sys, ap.fb.via, v_in, v_out); ok do r_p = rp
	r_p = max(r_p, b.radius * FLYBY_MARGIN)
	v_p := math.sqrt(max(vr * vr - 2 * b.mu / b.soi, 0) + 2 * b.mu / r_p)
	bb := r_p * v_p / vr
	side: f64 = orbit.cross(v_in, v_out) >= 0 ? 1 : -1 // turning left needs the body on the left: pass on its right
	return pm + orbit.rotate(v_in / vr, -side * math.PI / 2) * bb
}

// Start flying a candidate. Creates and arms the first node.
autopilot_start :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, geo: Geometry, dest: Destination, obj: Objective, c: Candidate, t: f64, fb: Flyby = {}) {
	clear(&s.nodes)
	s.autoburn.active = false
	ap^ = Autopilot{active = true, objective = obj, dest = dest, geo = geo, cand = c, stage = .Depart, fb = fb, direct_only = !c.flyby}
	if geo.dep_body != gen.NONE {
		make_escape_node(sys, s, ap, t)
		shoot_node(sys, s, ap, 0, t, .Time_And_Prograde)
	} else {
		make_direct_node(sys, s, ap, t)
		shoot_node(sys, s, ap, 0, t, .Prograde_And_Radial)
	}
	// If the departure alone cannot hit the aim (a plan slower than the
	// minimum escape, or a finite-burn residual), plan the correction now so
	// the drawn path is complete before leaving.
	// Traders skip this: they re-solve the correction on reaching the frame anyway.
	if !s.impulsive {
		if m, ok := miss(sys, s, ap, t); ok && orbit.length(m) > miss_tolerance(sys, ap) {
			plan_correction_from_prediction(sys, s, ap, t)
		}
	}
	ap.status = "departure burn"
	repredict(sys, s, t)
}

// Correction node placed shortly after the departure reaches the transfer
// frame, solved from the predicted state there.
@(private = "file")
plan_correction_from_prediction :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) -> bool {
	segs := make([dynamic]Segment, context.temp_allocator)
	predict(sys, s.primary, s.pos, s.vel, t, &segs, s.nodes[:])
	for seg, i in segs {
		if seg.primary != ap.geo.lca do continue
		if ap.geo.dep_body == gen.NONE && i == 0 do continue // the segment before a direct departure
		t_c := seg.t0 + 300
		pos, vel := orbit.state_at(seg.orbit, t_c)
		return correction_at(sys, s, ap, pos, vel, t_c, t, false)
	}
	return false
}

// ---------------------------------------------------------------- shooting

// Which two node parameters the shooter may move.
Shoot_Params :: enum u8 {
	Time_And_Prograde,   // escape burns: when on the parking orbit, and how hard
	Prograde_And_Radial, // burns already in the transfer frame
}

// Predicted position and velocity in the common frame at the planned arrival
// time, following the plan through the departure. Uses the last predicted
// segment in that frame and extrapolates its conic, so a prediction horizon
// short of the arrival is not a problem.
@(private = "file")
arrival_state :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64, t_a: f64) -> (pos, vel: [2]f64, ok: bool) {
	segs := make([dynamic]Segment, context.temp_allocator)
	predict(sys, s.primary, s.pos, s.vel, t, &segs, s.nodes[:])
	found := -1
	target := leg_target(ap)
	for seg, i in segs {
		if seg.primary != ap.geo.lca do continue
		// The frame segment that comes after the departure node.
		if ap.geo.dep_body == gen.NONE && seg.end == .Node && i == 0 do continue
		if seg.t0 > t_a + 1 do break // a later frame pass (after a flyby) is not this leg
		found = i
		if seg.end == .Enter && seg.target == target do break
	}
	if found < 0 do return {}, {}, false
	pos, vel = orbit.state_at(segs[found].orbit, t_a)
	return pos, vel, true
}

// Miss vector: predicted arrival minus the aim point (which itself depends on
// the predicted arrival velocity).
@(private = "file")
miss :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) -> (m: [2]f64, ok: bool) {
	t_a := leg_t_arrive(ap)
	pos, vel, got := arrival_state(sys, s, ap, t, t_a)
	if !got do return {}, false
	return pos - aim_leg(sys, ap, vel, t_a), true
}

// Newton on two node parameters until the predicted arrival hits the aim.
// Returns the final miss distance.
shoot_node :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, ni: int, t: f64, params: Shoot_Params) -> f64 {
	if ni < 0 || ni >= len(s.nodes) do return 1e300
	get :: proc(n: Node, params: Shoot_Params) -> [2]f64 {
		return params == .Time_And_Prograde ? [2]f64{n.t, n.prograde} : [2]f64{n.prograde, n.radial}
	}
	set :: proc(n: ^Node, x: [2]f64, params: Shoot_Params) {
		if params == .Time_And_Prograde {
			n.t = x[0]
			n.prograde = x[1]
		} else {
			n.prograde = x[0]
			n.radial = x[1]
		}
	}
	steps := params == .Time_And_Prograde ? [2]f64{20, 2e-5} : [2]f64{2e-5, 2e-5}
	// Bounds: the node must stay in the future, and the Δv within reason.
	tol := 0.5
	if lt := leg_target(ap); lt != gen.NONE do tol = max(0.5, 0.02 * sys.bodies[lt].soi)

	// An escape burn must always reach the edge of the sphere.
	dv_floor: f64 = -1e300
	if params == .Time_And_Prograde && ap.geo.dep_body != gen.NONE {
		pb := sys.bodies[ap.geo.dep_body]
		dv_floor = escape_dv(pb.mu, orbit.length(s.pos), orbit.length(s.vel), 1e-4) * 1.001
	}

	was_armed := s.autoburn.active && s.autoburn.node_t == s.nodes[ni].t
	x := get(s.nodes[ni], params)
	best_x := x
	best_m: f64 = 1e300
	pending: [2]f64 // last Newton step, for backtracking
	have_step := false
	max_iter := s.impulsive ? 4 : 14 // traders take a coarser polish; corrections mop up
	for iter in 0 ..< max_iter {
		set(&s.nodes[ni], x, params)
		m0, ok := miss(sys, s, ap, t)
		when SHOOT_DEBUG do fmt.printfln("shoot iter %v x=%v miss=%v ok=%v", iter, x, m0, ok)
		d0 := ok ? orbit.length(m0) : 1e300
		if have_step && d0 >= best_m {
			// Worse than before: halve the last step and retry.
			pending *= 0.5
			x = best_x + pending
			if params == .Time_And_Prograde do x[1] = max(x[1], dv_floor)
			if orbit.length(pending) < 1e-9 do break
			continue
		}
		have_step = false
		if !ok do break
		if d0 < best_m {
			best_m = d0
			best_x = x
		}
		if d0 < tol do break
		// Numerical Jacobian.
		J: [2][2]f64
		for k in 0 ..< 2 {
			xp := x
			xp[k] += steps[k]
			set(&s.nodes[ni], xp, params)
			mk, okk := miss(sys, s, ap, t)
			if !okk { ok = false; break }
			J[k] = (mk - m0) / steps[k] // column k
		}
		if !ok do break
		det := J[0][0] * J[1][1] - J[1][0] * J[0][1]
		if abs(det) < 1e-18 do break
		// Solve J dx = -m0 (J stored column-major: J[k] is d(miss)/dx_k).
		dx := [2]f64 {
			(-m0.x * J[1][1] + m0.y * J[1][0]) / det,
			(-m0.y * J[0][0] + m0.x * J[0][1]) / det,
		}
		// Damp large steps.
		if params == .Time_And_Prograde {
			dx[0] = clamp(dx[0], -900, 900)
			dx[1] = clamp(dx[1], -0.02, 0.02)
		} else {
			dx[0] = clamp(dx[0], -0.02, 0.02)
			dx[1] = clamp(dx[1], -0.02, 0.02)
		}
		pending = dx
		have_step = true
		x = best_x + dx
		if params == .Time_And_Prograde {
			x[0] = max(x[0], t + 60)
			x[1] = max(x[1], dv_floor)
		}
		_ = iter
	}
	set(&s.nodes[ni], best_x, params)
	final_t := s.nodes[ni].t
	nodes_sort(s)
	// Re-arm: the armed burn is identified by its time, which may have moved.
	if was_armed do for n, k in s.nodes do if n.t == final_t { arm_node(s, k); break }
	return best_m
}

autopilot_cancel :: proc(s: ^Ship, ap: ^Autopilot) {
	ap.active = false
	ap.stage = .Idle
	ap.status = "cancelled"
	clear(&s.nodes)
	s.autoburn.active = false
}

// Time from the periapsis burn (radius r_p, excess speed v_inf) out to
// radius R on the escape hyperbola.
@(private = "file")
hyperbolic_climb :: proc(mu, r_p, v_inf, R: f64) -> f64 {
	vi := max(v_inf, 1e-9)
	a := -mu / (vi * vi)
	e := 1 - r_p / a
	ch := (1 - R / a) / e
	if ch < 1 do return 0
	H := math.acosh(ch)
	M := e * math.sinh(H) - H
	n := math.sqrt(mu / (-a * -a * -a))
	return M / n
}

// Escape from the parking orbit: burn at the point whose outgoing asymptote
// points along the required excess velocity. The climb out of the sphere
// can take hours, during which the planet moves, so the transfer is solved
// from the planet's state at the *exit* time and iterated to consistency.
@(private = "file")
make_escape_node :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) {
	geo := ap.geo
	c := ap.cand
	pb := sys.bodies[geo.dep_body]
	r := orbit.length(s.pos)
	v_now := orbit.length(s.vel)
	dir := s.orbit.dir
	period := orbit.period(s.orbit)
	n_park := 2 * math.PI / period
	ang_now := math.atan2(s.pos.y, s.pos.x)

	t_a := leg_t_arrive(ap)
	v2 := leg_v2(ap)
	dv_floor := escape_dv(pb.mu, r, v_now, 1e-4) * 1.001

	// Initial guess from the plan's required edge velocity.
	pp0, pv0 := orbit.state_at(pb.orbit, c.t_depart)
	v_rel := c.v1 - pv0
	vr := orbit.length(v_rel)
	v_inf, _ := excess_from_edge(pb.mu, pb.soi, vr)
	v_inf = max(v_inf, 1e-4)
	dv := max(escape_dv(pb.mu, r, v_now, v_inf), dv_floor)
	d := v_rel / max(vr, 1e-12)
	e_h := 1 + r * v_inf * v_inf / pb.mu
	theta_inf := math.acos(-1 / e_h)
	burn_dir := orbit.rotate(d, -dir * theta_inf)
	ang_burn := math.atan2(burn_dir.y, burn_dir.x)
	dphi := math.mod(dir * (ang_burn - ang_now), 2 * math.PI)
	if dphi < 0 do dphi += 2 * math.PI
	t_first := t + dphi / n_park
	climb := hyperbolic_climb(pb.mu, r, v_inf, pb.soi)
	k := math.floor((c.t_depart - climb - t_first) / period + 0.5)
	t_burn := t_first + max(k, 0) * period
	if t_burn < t + 60 do t_burn += period

	// Gauss-Newton on (t_burn, dv): the heliocentric velocity at the real exit
	// point must equal what Lambert needs from that point to the aim.
	x := [2]f64{t_burn, dv}
	best := x
	best_r: f64 = 1e300
	for _ in 0 ..< 16 {
		r0, ok := escape_residual(sys, s, ap, pb, x, t_a, &v2)
		if !ok do break
		n0 := orbit.length(r0)
		if n0 < best_r {
			best_r = n0
			best = x
		}
		if n0 < 1e-7 do break
		steps := [2]f64{5, 1e-5}
		J: [2][2]f64
		jok := true
		for kk in 0 ..< 2 {
			xp := x
			xp[kk] += steps[kk]
			rk, okk := escape_residual(sys, s, ap, pb, xp, t_a, &v2)
			if !okk { jok = false; break }
			J[kk] = (rk - r0) / steps[kk]
		}
		if !jok do break
		det := J[0][0] * J[1][1] - J[1][0] * J[0][1]
		if abs(det) < 1e-24 do break
		dx := [2]f64 {
			(-r0.x * J[1][1] + r0.y * J[1][0]) / det,
			(-r0.y * J[0][0] + r0.x * J[0][1]) / det,
		}
		dx[0] = clamp(dx[0], -period / 6, period / 6)
		dx[1] = clamp(dx[1], -0.01, 0.01)
		x = best + dx
		x[0] = max(x[0], t + 60)
		x[1] = max(x[1], dv_floor)
	}
	set_leg_arrival(ap, t_a, v2)
	i := node_add(s, Node{t = best[0], prograde = best[1]})
	arm_node(s, i)
}

// Heliocentric velocity mismatch at the sphere's edge for an escape burn of
// `dv` at time `t_burn` on the parking orbit, versus the Lambert velocity
// needed from the exit point to the aim at t_a.
@(private = "file")
escape_residual :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, pb: gen.Body, x: [2]f64, t_a: f64, v2: ^[2]f64) -> ([2]f64, bool) {
	pos_b, vel_b := orbit.state_at(s.orbit, x[0])
	vb := orbit.length(vel_b)
	if vb < 1e-12 do return {}, false
	o := orbit.from_state(pos_b, vel_b + vel_b / vb * x[1], pb.mu, x[0])
	if o.e <= 1 do return {}, false
	ch := (1 - pb.soi / o.a) / o.e
	if ch <= 1 do return {}, false
	H := math.acosh(ch)
	M := o.e * math.sinh(H) - H
	n := orbit.mean_motion(o)
	t_peri := o.t0 - o.M0 / n
	t_exit := t_peri + M / n
	if t_exit >= t_a - 600 do return {}, false
	ep, ev := orbit.state_at(o, t_exit)
	pp, pv := orbit.state_at(pb.orbit, t_exit)
	aim := aim_leg(sys, ap, v2^, t_a)
	v1, nv2, ok := orbit.lambert(pp + ep, aim, t_a - t_exit, ap.geo.mu, ap.geo.dir)
	if !ok do return {}, false
	// The transfer, and the orbit we actually leave on, must both clear the star.
	if !clears_body(pp + ep, v1, ap.geo.mu, safe_radius(sys, ap.geo.lca)) do return {}, false
	if !clears_body(pp + ep, pv + ev, ap.geo.mu, safe_radius(sys, ap.geo.lca)) do return {}, false
	v2^ = nv2
	return pv + ev - v1, true
}

// Direct departure from an orbit about the common body.
@(private = "file")
make_direct_node :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) {
	c := ap.cand
	pos, vel := orbit.state_at(s.orbit, c.t_depart)
	dv := c.v1 - vel
	p, r := local_frame(pos, vel)
	i := node_add(s, Node{t = max(c.t_depart, t + 30), prograde = orbit.dot(dv, p), radial = orbit.dot(dv, r)})
	arm_node(s, i)
}

miss_tolerance :: proc(sys: ^gen.System, ap: ^Autopilot) -> f64 {
	lt := leg_target(ap)
	if lt == gen.NONE do return 1.0
	// Well inside the sphere, and small next to the capture offset so a
	// "good enough" arrival cannot be a surface impact on a tiny moon.
	r_p := ap.cand.flyby && ap.leg == 0 ? ap.fb.r_p : ap.geo.cap_r
	return clamp(0.1 * sys.bodies[lt].soi, 0.2, 0.25 * max(r_p, 0.8))
}

// Mid-course correction from the current common-frame orbit to the aim
// point at the planned arrival time. Returns false if no solution.
@(private = "file")
make_correction_node :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) -> bool {
	t_c := t + 300
	pos, vel := orbit.state_at(s.orbit, t_c)
	return correction_at(sys, s, ap, pos, vel, t_c, t, true)
}

// Lambert from a transfer-frame state at t_c to the aim, as a node at t_c,
// polished against the predictor. Arms it when `arm` is set.
@(private = "file")
correction_at :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, pos, vel: [2]f64, t_c, t: f64, arm: bool) -> bool {
	geo := ap.geo
	base_t := leg_t_arrive(ap)
	span := base_t - leg_t_start(ap)
	// Candidate arrival times: the plan's, stretched a little; then, if the
	// plan is stale or blocked, fresh ones from the current geometry.
	cands := make([dynamic]f64, context.temp_allocator)
	for k in ([?]f64{0, 0.05, 0.1, 0.15, 0.25}) do append(&cands, base_t + k * span)
	tp, _ := target_frame_state(sys, geo, t_c)
	r1 := orbit.length(pos)
	r2 := orbit.length(tp)
	ah := (r1 + r2) * 0.5
	t_h := math.PI * math.sqrt(ah * ah * ah / geo.mu)
	for k in ([?]f64{0.5, 0.7, 1.0, 1.4, 2.0, 3.0}) do append(&cands, t_c + t_h * k)

	best_dv: f64 = 1e300
	best_t: f64
	best_v1, best_v2: [2]f64
	safe := safe_radius(sys, geo.lca)
	for t_a in cands {
		tf := t_a - t_c
		if tf < 600 do continue
		v2 := leg_v2(ap)
		ok := false
		v1: [2]f64
		for _ in 0 ..< 3 {
			aim := aim_leg(sys, ap, v2, t_a)
			nv1, nv2, lok := orbit.lambert(pos, aim, tf, geo.mu, geo.dir)
			if !lok { ok = false; break }
			v1, v2, ok = nv1, nv2, true
		}
		if !ok do continue
		if !clears_body(pos, v1, geo.mu, safe) do continue
		if geo.arr_body == gen.NONE && !stays_in_sphere(sys, geo.lca, pos, v1, geo.mu) do continue
		dv := orbit.length(v1 - vel)
		if dv > dv_remaining(s) do continue
		// Prefer the plan's own timing when it is feasible: cost adds a mild
		// penalty for straying from it.
		score := dv * (1 + 0.1 * abs(t_a - base_t) / max(span, 1))
		if score < best_dv {
			best_dv = score
			best_t = t_a
			best_v1, best_v2 = v1, v2
		}
	}
	if best_dv >= 1e300 {
		when NPC_DEBUG do fmt.printfln("  correction: no feasible arrival among %d candidates (r=%.1f safe=%.1f dv_left=%.4f)", len(cands), r1, safe, dv_remaining(s))
		return false
	}
	dv := best_v1 - vel
	p, r := local_frame(pos, vel)
	i := node_add(s, Node{t = t_c, prograde = orbit.dot(dv, p), radial = orbit.dot(dv, r)})
	set_leg_arrival(ap, best_t, best_v2)
	// An impulsive burn in the transfer frame is exactly what Lambert solved;
	// only a finite burn needs the predictor polish.
	if !s.impulsive do shoot_node(sys, s, ap, i, t, .Prograde_And_Radial)
	if arm do for n, k in s.nodes do if n.t == t_c { arm_node(s, k); break }
	return true
}

// Final approach guard: if the arrival conic's periapsis is below the safe
// radius (or far from the capture radius), a small radial burn shortly
// ahead moves it to cap_r. Solved by secant on the radial component.
@(private = "file")
fix_periapsis :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) -> bool {
	b := sys.bodies[s.primary]
	want := ap.geo.cap_r
	if s.primary != ap.geo.arr_body do want = max(orbit.periapsis(s.orbit), safe_radius(sys, s.primary) * 1.2)
	rp := orbit.periapsis(s.orbit)
	if rp > safe_radius(sys, s.primary) && abs(rp - want) < 0.35 * want do return false
	t_c := t + 60
	pos, vel := orbit.state_at(s.orbit, t_c)
	p, r := local_frame(pos, vel)
	peri_after :: proc(pos, vel, p, r: [2]f64, mu, pro, rad: f64) -> f64 {
		return orbit.periapsis(orbit.from_state(pos, vel + p * pro + r * rad, mu, 0))
	}
	// Secant on the radial component; prograde stays zero.
	x0, x1 := 0.0, 0.002
	f0 := peri_after(pos, vel, p, r, b.mu, 0, x0) - want
	f1 := peri_after(pos, vel, p, r, b.mu, 0, x1) - want
	for _ in 0 ..< 30 {
		if abs(f1) < 1e-3 * want do break
		if abs(f1 - f0) < 1e-15 do break
		x2 := x1 - f1 * (x1 - x0) / (f1 - f0)
		x2 = clamp(x2, -0.05, 0.05)
		x0, f0 = x1, f1
		x1 = x2
		f1 = peri_after(pos, vel, p, r, b.mu, 0, x1) - want
	}
	if abs(f1) > 0.2 * want || abs(x1) > dv_remaining(s) do return false
	arm_node(s, node_add(s, Node{t = t_c, radial = x1}))
	return true
}

// Capture at periapsis of the arrival conic about the destination body.
@(private = "file")
make_capture_node :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) {
	o := s.orbit
	n := orbit.mean_motion(o)
	t_peri: f64
	if o.e >= 1 {
		t_peri = o.t0 - o.M0 / n
	} else {
		M := orbit.mean_anomaly_at(o, t)
		t_peri = t + (2 * math.PI - M) / n
	}
	rp := orbit.periapsis(o)
	v_peri := math.sqrt(o.mu * (2 / rp - 1 / o.a))
	dv := v_peri - math.sqrt(o.mu / rp)
	if t_peri < t + 0.5 * burn_duration(s, dv) do t_peri = t + 0.5 * burn_duration(s, dv) + 1
	i := node_add(s, Node{t = t_peri, prograde = -dv})
	arm_node(s, i)
}

// Velocity match with a station orbiting the common body.
@(private = "file")
make_match_node :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) {
	t_a := max(ap.cand.t_arrive, t + 30)
	pos, vel := orbit.state_at(s.orbit, t_a)
	_, vt := target_frame_state(sys, ap.geo, t_a)
	dv := vt - vel
	p, r := local_frame(pos, vel)
	i := node_add(s, Node{t = t_a, prograde = orbit.dot(dv, p), radial = orbit.dot(dv, r)})
	arm_node(s, i)
}

@(private = "file")
idle_on_rails :: proc(s: ^Ship) -> bool {
	return s.mode == .On_Rails && !s.autoburn.active && len(s.nodes) == 0
}

@(private = "file")
predicts_encounter :: proc(s: ^Ship, target: gen.Body_Handle) -> bool {
	for seg in s.segments do if seg.end == .Enter && seg.target == target do return true
	return false
}

// The next moment worth warping to while the autopilot flies: a burn start,
// a sphere transition, or the planned arrival.
autopilot_wait_until :: proc(s: ^Ship, ap: ^Autopilot, t: f64) -> (f64, bool) {
	if !ap.active || s.mode != .On_Rails do return 0, false
	if start, ok := autoburn_start(s); ok do return start, start > t + 5
	if seg, has := next_event(s); has && seg.t1 > t + 65 do return seg.t1 - 60, true
	#partial switch ap.stage {
	case .Depart, .Correct, .Coast, .Flyby:
		if ta := leg_t_arrive(ap); ta > t + 65 do return ta - 60, true
	case .Dock:
		if ap.last_try + 120 > t + 5 do return ap.last_try + 120, true
	}
	return 0, false
}

// Predicted impact anywhere along the plan?
@(private = "file")
predicts_impact :: proc(segs: []Segment, before: f64 = 1e300) -> (gen.Body_Handle, bool) {
	for seg in segs do if seg.end == .Collide && seg.t1 < before do return seg.primary, true
	return gen.NONE, false
}

DODGE_HORIZON :: 2 * 86400.0

// Is an impact on the predicted path at all?
impact_ahead :: proc(s: ^Ship) -> bool {
	_, hit := predicts_impact(s.segments[:])
	return hit
}

// Emergency dodge: an unplanned pass through some body's sphere ends on its
// surface. Fire the smallest radial burn (either way) that clears every
// impact in the prediction, and let the leg logic re-correct afterwards.
dodge :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) -> bool {
	body, hit := predicts_impact(s.segments[:])
	if !hit do return false
	// An armed burn that comes after the impact cannot save us: drop it.
	if s.autoburn.active {
		impact_t: f64 = 1e300
		for seg in s.segments do if seg.end == .Collide { impact_t = seg.t1; break }
		if s.autoburn.node_t < impact_t do return true // the planned burn changes the path first; re-check after it
		clear(&s.nodes)
		s.autoburn.active = false
		repredict(sys, s, t)
		if _, still := predicts_impact(s.segments[:]); !still do return false
	}
	t_c := t + 60
	segs := make([dynamic]Segment, context.temp_allocator)
	for mag in ([?]f64{0.0004, 0.0008, 0.0016, 0.003, 0.006, 0.012, 0.024}) {
		for sign in ([?]f64{1, -1}) {
			trial := make([dynamic]Node, context.temp_allocator)
			for n in s.nodes do append(&trial, n)
			append(&trial, Node{t = t_c, radial = sign * mag})
			nodes_sort_slice(trial[:])
			predict(sys, s.primary, s.pos, s.vel, t, &segs, trial[:])
			if _, still := predicts_impact(segs[:], t + DODGE_HORIZON); still do continue
			if mag > dv_remaining(s) do return false
			arm_node(s, node_add(s, Node{t = t_c, radial = sign * mag}))
			ap.status = "dodging"
			_ = body
			return true
		}
	}
	return false
}

// Immediate impulsive dodge at time t_now for ships that fly impulsively:
// the smallest radial kick whose prediction shows no impact. Changes the
// orbit directly and charges propellant.
dodge_now :: proc(sys: ^gen.System, s: ^Ship, t_now: f64) -> bool {
	pos, vel := orbit.state_at(s.orbit, t_now)
	p, r := local_frame(pos, vel)
	segs := make([dynamic]Segment, context.temp_allocator)
	mu := sys.bodies[s.primary].mu
	for mag in ([?]f64{0.0004, 0.0008, 0.0016, 0.003, 0.006, 0.012, 0.024, 0.05}) {
		for sign in ([?]f64{1, -1}) {
			nv := vel + r * (sign * mag)
			predict(sys, s.primary, pos, nv, t_now, &segs, nil)
			if _, still := predicts_impact(segs[:], t_now + DODGE_HORIZON); still do continue
			if mag > dv_remaining(s) do return false
			m0 := mass(s)
			s.propellant = max(s.propellant - m0 * (1 - math.exp(-mag / ve_eff(s))), 0)
			s.burned_dv += mag
			s.orbit = orbit.from_state(pos, nv, mu, t_now)
			clear(&s.nodes)
			s.autoburn.active = false
			repredict(sys, s, t_now)
			_ = p
			return true
		}
	}
	return false
}

@(private = "file")
nodes_sort_slice :: proc(a: []Node) {
	for i in 1 ..< len(a) {
		j := i
		for j > 0 && a[j - 1].t > a[j].t {
			a[j - 1], a[j] = a[j], a[j - 1]
			j -= 1
		}
	}
}

// Advance the stage machine. Call each frame after the ship update.
autopilot_update :: proc(sys: ^gen.System, s: ^Ship, ap: ^Autopilot, t: f64) {
	if !ap.active do return
	if is_dead(s) {
		ap.stage = .Failed
		ap.status = s.mode == .Destroyed ? "ship destroyed" : "ship wrecked"
		ap.active = false
		return
	}
	geo := ap.geo
	// Whatever the stage, an impact ahead comes first.
	if s.mode == .On_Rails && ap.stage != .Dock {
		if dodge(sys, s, ap, t) do return
	}
	switch ap.stage {
	case .Depart:
		if s.mode != .On_Rails || s.autoburn.active do return
		if s.primary == geo.lca {
			// In the transfer frame. Drop any pre-planned correction and
			// re-solve from where we really are; skip it if already on target.
			if len(s.nodes) > 0 {
				clear(&s.nodes)
				repredict(sys, s, t)
			}
			if m, ok := miss(sys, s, ap, t); ok && orbit.length(m) < miss_tolerance(sys, ap) {
				ap.stage = .Coast
				ap.status = "coasting to encounter"
				ap.attempts = 0
				ap.last_try = t
				return
			}
			ap.stage = .Correct
			ap.status = "correcting course"
			if !make_correction_node(sys, s, ap, t) {
				ap.stage = .Failed
				ap.status = "no correction found"
				ap.active = false
			}
		} else if s.primary == geo.dep_body {
			if len(s.nodes) > 0 do return // the planned correction still lies ahead
			// Still climbing out; the predictor must show the exit.
			exiting := false
			for seg in s.segments do if seg.end == .Exit do exiting = true
			if !exiting && t - ap.last_try > 60 {
				ap.last_try = t
				ap.attempts += 1
				if ap.attempts > 3 {
					ap.stage = .Failed
					ap.status = "escape burn did not reach the edge"
					ap.active = false
				} else {
					// Top up: burn prograde now to reach escape.
					pb := sys.bodies[s.primary]
					r := orbit.length(s.pos)
					need := math.sqrt(2 * pb.mu / r) * 1.02 - orbit.length(s.vel)
					if need > 0 do arm_node(s, node_add(s, Node{t = t + 30, prograde = need}))
				}
			}
		}
	case .Correct:
		if !idle_on_rails(s) do return
		ap.stage = .Coast
		ap.status = "coasting to encounter"
		ap.attempts = 0
		ap.last_try = t
	case .Coast:
		if geo.is_point {
			if t >= ap.cand.t_arrive - 30 {
				ap.stage = .Done
				ap.status = "reached the waypoint"
				ap.active = false
			}
			return
		}
		if geo.arr_body == gen.NONE {
			// Station in the common frame: match its velocity at arrival.
			if t >= ap.cand.t_arrive - 600 && idle_on_rails(s) {
				make_match_node(sys, s, ap, t)
				ap.stage = .Capture
				ap.status = "matching station orbit"
			}
			return
		}
		target := leg_target(ap)
		if s.primary == target {
			if s.mode != .On_Rails do return
			if ap.cand.flyby && ap.leg == 0 {
				ap.stage = .Flyby
				ap.status = "swinging past the assist body"
				return
			}
			if len(s.nodes) == 0 && !s.autoburn.active && fix_periapsis(sys, s, ap, t) {
				ap.status = "adjusting periapsis"
				return // stays in Coast; the capture follows once the burn is done
			}
			if s.autoburn.active || len(s.nodes) > 0 do return
			make_capture_node(sys, s, ap, t)
			ap.stage = .Capture
			ap.status = "capture burn"
			return
		}
		if s.primary != geo.lca do return
		if predicts_encounter(s, target) do return
		if t - ap.last_check < CHECK_EVERY do return
		ap.last_check = t
		if m, ok := miss(sys, s, ap, t); ok && orbit.length(m) < miss_tolerance(sys, ap) do return // on track, encounter beyond the horizon
		// Drifted off: correct again, a few times, then give up.
		if t > leg_t_arrive(ap) + 0.3 * (leg_t_arrive(ap) - leg_t_start(ap)) {
			ap.stage = .Failed
			ap.status = "missed the encounter"
			ap.active = false
			return
		}
		if idle_on_rails(s) && t - ap.last_try > 1800 {
			ap.last_try = t
			ap.attempts += 1
			if ap.attempts > 4 || !make_correction_node(sys, s, ap, t) {
				ap.stage = .Failed
				ap.status = "could not re-target"
				ap.active = false
			} else {
				ap.stage = .Correct
				ap.status = "re-targeting"
			}
		}
	case .Flyby:
		if s.mode != .On_Rails do return
		if s.primary == geo.lca {
			// Out the other side: re-target the destination from here.
			ap.leg = 1
			clear(&s.nodes)
			repredict(sys, s, t)
			ap.attempts = 0
			ap.last_try = t
			ap.stage = .Correct
			ap.status = "post-flyby correction"
			if !make_correction_node(sys, s, ap, t) {
				ap.stage = .Failed
				ap.status = "lost the target after the flyby"
				ap.active = false
			}
			return
		}
		if s.primary != ap.fb.via do return
		exiting := false
		for seg in s.segments do if seg.end == .Exit do exiting = true
		if !exiting && s.orbit.e < 1 && t - ap.last_try > 600 {
			// Captured by the assist body: burn out along the planned exit.
			ap.last_try = t
			pb := sys.bodies[s.primary]
			need := math.sqrt(2 * pb.mu / orbit.length(s.pos)) * 1.02 - orbit.length(s.vel)
			if need > 0 do arm_node(s, node_add(s, Node{t = t + 30, prograde = need}))
		}
	case .Capture:
		if !idle_on_rails(s) do return
		if ap.dest.kind == .Station || ap.dest.kind == .Npc {
			if geo.arr_body != gen.NONE && ap.legs == 0 {
				// Captured around the target's body: now a rendezvous in this frame.
				ap.legs = 1
				ngeo, ok, _ := geometry(sys, s, ap.dest)
				if ok {
					res := search(sys, s, ngeo, t, s.impulsive)
					c := ap.direct_only ? res.direct[ap.objective] : res.picks[ap.objective]
					if res.ok && c.ok {
						ap.geo = ngeo
						ap.cand = c
						ap.cand.flyby = false
						ap.leg = 0
						ap.stage = .Depart
						make_direct_node(sys, s, ap, t)
						if !s.impulsive do shoot_node(sys, s, ap, 0, t, .Prograde_And_Radial)
						repredict(sys, s, t)
						ap.status = "rendezvous burn"
						return
					}
				}
				ap.stage = .Failed
				ap.status = "no rendezvous found"
				ap.active = false
				return
			}
			ap.stage = .Dock
			ap.status = "closing to dock"
			ap.last_try = t
			ap.attempts = 0
			return
		}
		ap.stage = .Done
		ap.status = "arrived"
		ap.active = false
	case .Dock:
		if s.mode != .On_Rails do return
		if ap.dest.kind == .Npc {
			// Close to the other ship: drop into formation on its orbit, a
			// hair behind, so the two hold together until the pilot asks to dock.
			hp, hv := orbit.state_at(ap.geo.npc_orbit, t)
			if orbit.length(s.pos - hp) < FORMATION_RANGE && orbit.length(s.vel - hv) < FORMATION_SPEED {
				hold_formation(sys, s, ap.geo.npc_orbit, t)
				ap.stage = .Done
				ap.status = "holding formation; ask to dock"
				ap.active = false
				return
			}
			if !idle_on_rails(s) do return
			// Not close enough: a short hop onto the ship's orbit, like a station.
			if t - ap.last_try < 120 do return
			ap.last_try = t
			ap.attempts += 1
			if ap.attempts > 6 {
				ap.stage = .Failed
				ap.status = "could not close on the ship"
				ap.active = false
				return
			}
			hop := max(orbit.period(ap.geo.npc_orbit) * 0.15, 600)
			if ap.geo.npc_orbit.e >= 1 do hop = 1800
			t_c := t + 60
			t_a := t_c + hop
			pos, vel := orbit.state_at(s.orbit, t_c)
			sp, _ := orbit.state_at(ap.geo.npc_orbit, t_a)
			v1, _, lok := orbit.lambert(pos, sp, hop, s.orbit.mu, ap.geo.npc_orbit.dir)
			if !lok || !clears_body(pos, v1, s.orbit.mu, safe_radius(sys, s.primary)) do return
			dv := v1 - vel
			p, r := local_frame(pos, vel)
			arm_node(s, node_add(s, Node{t = t_c, prograde = orbit.dot(dv, p), radial = orbit.dot(dv, r)}))
			ap.cand.t_arrive = t_a
			ap.stage = .Coast
			ap.status = "closing on the ship"
			return
		}
		if idx, ok := dockable_station(sys, s); ok && idx == ap.dest.index {
			dock(sys, s, idx, t)
			ap.stage = .Done
			ap.status = "docked"
			ap.active = false
			return
		}
		if !idle_on_rails(s) do return
		// Not close enough: small Lambert hop to the station within a short time.
		if t - ap.last_try < 120 do return
		ap.last_try = t
		ap.attempts += 1
		if ap.attempts > 6 {
			ap.stage = .Failed
			ap.status = "could not close on the station"
			ap.active = false
			return
		}
		st := sys.stations[ap.dest.index]
		hop := max(orbit.period(st.orbit) * 0.15, 600)
		t_c := t + 60
		t_a := t_c + hop
		pos, vel := orbit.state_at(s.orbit, t_c)
		sp, _ := orbit.state_at(st.orbit, t_a)
		v1, _, lok := orbit.lambert(pos, sp, hop, s.orbit.mu, st.orbit.dir)
		if !lok || !clears_body(pos, v1, s.orbit.mu, safe_radius(sys, s.primary)) do return
		dv := v1 - vel
		p, r := local_frame(pos, vel)
		arm_node(s, node_add(s, Node{t = t_c, prograde = orbit.dot(dv, p), radial = orbit.dot(dv, r)}))
		ap.cand.t_arrive = t_a
		ap.stage = .Coast
		ap.status = "closing to dock"
	case .Idle, .Done, .Failed:
	}
}
