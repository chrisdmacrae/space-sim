package sim

// Ship state machine (docs/DESIGN.md §5.1, §4.3). On rails the ship is a
// conic and events from the predictor are applied exactly at their time.
// Thrusting, it is integrated in its primary's frame with sphere-of-
// influence checks every substep, and goes back on rails when the engine
// cuts.

import "core:fmt"
import "core:math"
import econ "sim:econ"
import gen "sim:gen"
import orbit "sim:orbit"

NPC_DEBUG :: #config(NPC_DEBUG, false)

Ship_Mode :: enum u8 {
	On_Rails,
	Thrusting,
	Docked,
	Cryo,
	Wrecked,   // on a surface: the hull is there, the ship is not going anywhere
	Destroyed, // gone: fell into a star or the hull failed
}

Hold :: enum u8 {
	None,
	Prograde,
	Retrograde,
}

// Per-class numbers (docs/DESIGN.md §5.5); the class table arrives in phase 9.
Ship_Stats :: struct {
	mass_dry:       f64,
	propellant_cap: f64,
	thrust:         f64, // force; acceleration = thrust / mass
	ve:             f64, // exhaust velocity: dv = ve * ln(m0 / m1)
	cargo_cap:      f64, // units of cargo
}

COURIER :: Ship_Stats{mass_dry = 10, propellant_cap = 8, thrust = 0.0018, ve = 0.34, cargo_cap = 20}
CARGO_UNIT_MASS :: 0.25

// Cargo is indexed by econ.Commodity; kept as a plain array here so sim does
// not depend on econ.
CARGO_SLOTS :: 15
Cargo :: [CARGO_SLOTS]f64

Ship :: struct {
	name:        string,
	class:       econ.Class_Id,
	stats:       Ship_Stats,
	primary:     gen.Body_Handle,
	mode:        Ship_Mode,
	orbit:       orbit.Orbit, // relative to primary; authoritative on rails
	pos, vel:    [2]f64,      // relative to primary; authoritative when thrusting, mirrored otherwise
	heading:     f64,         // world radians
	throttle:    f64,         // 0..1
	hold:        Hold,
	propellant:  f64,
	segments:    [dynamic]Segment, // prediction from the current state
	predicted_at: f64,             // game time of the last prediction
	transitions: int,              // sphere-of-influence changes so far
	nodes:       [dynamic]Node,    // planned burns, sorted by time
	autoburn:    Autoburn,
	burned_dv:   f64,              // Δv delivered by thrust so far (for autoburn accounting)
	dock:        int,              // station index while Docked
	cargo:       Cargo,
	impulsive:   bool,             // NPCs: armed burns are applied as instant impulses on rails
	hull:        f64,              // 0..1, see hazards.odin
	docked_ship: bool,             // Docked to another ship (`dock` is its fleet index); the game keeps us riding it
	manual_heading: bool,          // the pilot turned the ship by hand: keep that heading instead of facing prograde
	dust_hardened: bool,           // survey hulls shrug off nebula dust (hazards.odin)
	hazard:      Hazard,           // what is hurting the ship right now
	hazard_rate: f64,              // hull lost per second from it
	// What the crew do for the ship (set by the game from crew.effects each frame).
	repair_rate: f64,              // hull restored per second while under way
	shield:      f64,              // fraction of hazard damage headed off, 0..1
	ve_bonus:    f64,              // multiplier on exhaust velocity; 0 means nominal
}

// Exhaust velocity as flown: the engine's, stretched by however well the
// navigator manages the burn (docs/DESIGN.md §5.9).
ve_eff :: proc(s: ^Ship) -> f64 {
	return s.ve_bonus > 0 ? s.stats.ve * s.ve_bonus : s.stats.ve
}

cargo_used :: proc(s: ^Ship) -> f64 {
	total := 0.0
	for u in s.cargo do total += u
	return total
}

cargo_free :: proc(s: ^Ship) -> f64 {
	return max(s.stats.cargo_cap - cargo_used(s), 0)
}

DOCK_RANGE :: 3.0   // world units from the station
DOCK_SPEED :: 0.0015 // relative speed limit for docking

// A station the ship could dock at right now: same primary, close, slow.
dockable_station :: proc(sys: ^gen.System, s: ^Ship) -> (int, bool) {
	if s.mode != .On_Rails && s.mode != .Thrusting do return -1, false
	best := -1
	best_d := DOCK_RANGE
	for &st, i in sys.stations {
		if st.parent != s.primary do continue
		sp := sys.station_pos[i] - sys.pos[s.primary]
		sv := sys.station_vel[i] - sys.vel[s.primary]
		d := orbit.length(s.pos - sp)
		if d < best_d && orbit.length(s.vel - sv) < DOCK_SPEED {
			best_d = d
			best = i
		}
	}
	return best, best >= 0
}

// Dock: the ship rides the station's orbit (docs/DESIGN.md §4.7).
dock :: proc(sys: ^gen.System, s: ^Ship, station: int, t: f64) {
	s.mode = .Docked
	s.dock = station
	s.throttle = 0
	s.hold = .None
	s.autoburn.active = false
	clear(&s.nodes)
	clear(&s.segments)
	st := sys.stations[station]
	s.primary = st.parent
	s.pos, s.vel = orbit.state_at(st.orbit, t)
}

FORMATION_GAP :: 0.6 // world units behind the host along its orbit

// Where a ship sits when keeping station just behind a host: the same
// orbit, a few seconds earlier in phase, so the pair never drift apart.
formation_state :: proc(host: orbit.Orbit, t: f64) -> (pos, vel: [2]f64) {
	hp, hv := orbit.state_at(host, t)
	speed := orbit.length(hv)
	lag := speed > 1e-9 ? FORMATION_GAP / speed : 0
	if lag == 0 do return hp - {FORMATION_GAP, 0}, hv
	return orbit.state_at(host, t - lag)
}

// Another ship the ship could dock with right now: same primary, close,
// slow, and the host coasting free (not docked itself).
dockable_ship :: proc(sys: ^gen.System, s: ^Ship, hosts: []Ship) -> (int, bool) {
	if s.mode != .On_Rails && s.mode != .Thrusting do return -1, false
	best := -1
	best_d := DOCK_RANGE
	for &h, i in hosts {
		if h.mode != .On_Rails || h.primary != s.primary do continue
		d := orbit.length(s.pos - h.pos)
		if d < best_d && orbit.length(s.vel - h.vel) < DOCK_SPEED {
			best_d = d
			best = i
		}
	}
	return best, best >= 0
}

// Dock to another ship: ride its orbit until undocking.
dock_ship :: proc(s: ^Ship, host: ^Ship, index: int) {
	s.mode = .Docked
	s.docked_ship = true
	s.dock = index
	s.throttle = 0
	s.hold = .None
	s.autoburn.active = false
	clear(&s.nodes)
	clear(&s.segments)
	ride_along(s, host)
}

// Keep a ship docked to another ship at the host's state.
ride_along :: proc(s: ^Ship, host: ^Ship) {
	s.primary = host.primary
	s.pos, s.vel = host.pos, host.vel
	s.orbit = host.orbit
	s.heading = host.heading
}

// Undock onto the station's (or host ship's) orbit, a little outside it.
undock :: proc(sys: ^gen.System, s: ^Ship, t: f64) {
	if s.mode != .Docked do return
	if s.docked_ship {
		// Let go a few seconds behind the host on its own orbit.
		s.docked_ship = false
		s.pos, s.vel = formation_state(s.orbit, t)
		s.orbit = orbit.from_state(s.pos, s.vel, sys.bodies[s.primary].mu, t)
		s.mode = .On_Rails
		repredict(sys, s, t)
		return
	}
	st := sys.stations[s.dock]
	p, v := orbit.state_at(st.orbit, t)
	r := orbit.length(p)
	s.primary = st.parent
	s.pos = p + p / max(r, 1e-9) * 0.5
	s.vel = v
	s.orbit = orbit.from_state(s.pos, s.vel, sys.bodies[s.primary].mu, t)
	s.mode = .On_Rails
	s.heading = math.atan2(v.y, v.x)
	repredict(sys, s, t)
}

// An armed node: the ship orients and burns at `start` until `dv` is delivered.
Autoburn :: struct {
	active:   bool,
	node_t:   f64, // identifies the node being flown
	start:    f64,
	dv:       f64,
	dv_start: f64, // burned_dv when the burn began
}

MAX_SUBSTEP   :: 0.5 // game seconds
PREDICT_EVERY :: 0.5 // game seconds between predictions while thrusting

mass :: proc(s: ^Ship) -> f64 {
	return s.stats.mass_dry + s.propellant + cargo_used(s) * CARGO_UNIT_MASS
}

dv_remaining :: proc(s: ^Ship) -> f64 {
	dry := s.stats.mass_dry + cargo_used(s) * CARGO_UNIT_MASS
	return ve_eff(s) * math.ln(mass(s) / dry)
}

// Circular orbit around a body at a fraction of its sphere of influence.
spawn_in_orbit :: proc(sys: ^gen.System, body: gen.Body_Handle, frac, t: f64, stats := COURIER) -> Ship {
	b := sys.bodies[body]
	alt := clamp(b.soi * frac, b.radius * 1.5, b.soi * 0.6)
	if body == gen.STAR do alt = b.radius * 12
	s := Ship {
		name       = "Courier",
		stats      = stats,
		primary    = body,
		mode       = .On_Rails,
		orbit      = orbit.circular(b.mu, alt, 0, t, 1),
		propellant = stats.propellant_cap,
		hull       = 1,
	}
	s.pos, s.vel = orbit.state_at(s.orbit, t)
	s.heading = math.atan2(s.vel.y, s.vel.x)
	repredict(sys, &s, t)
	return s
}

// A ship on a circular orbit about the star that passes through `world`.
// Used to place survey ships inside a nebula, which is a place rather than
// a body: there is nothing there to orbit, so they orbit the star from there.
spawn_at_point :: proc(sys: ^gen.System, world: [2]f64, t: f64, stats := COURIER) -> Ship {
	star := sys.bodies[0]
	rel := world - sys.pos[0]
	rad := max(orbit.length(rel), star.radius * 4)
	dir := 1.0
	if len(sys.bodies) > 1 do dir = sys.bodies[1].orbit.dir
	s := Ship {
		name       = "Courier",
		stats      = stats,
		primary    = gen.STAR,
		mode       = .On_Rails,
		orbit      = orbit.circular(star.mu, rad, math.atan2(rel.y, rel.x), t, dir),
		propellant = stats.propellant_cap,
		hull       = 1,
	}
	s.pos, s.vel = orbit.state_at(s.orbit, t)
	s.heading = math.atan2(s.vel.y, s.vel.x)
	repredict(sys, &s, t)
	return s
}

destroy :: proc(s: ^Ship) {
	delete(s.segments)
	delete(s.nodes)
}

// Estimated burn time for a Δv at full throttle from the current mass.
burn_duration :: proc(s: ^Ship, dv: f64) -> f64 {
	return dv / (s.stats.thrust / mass(s))
}

node_add :: proc(s: ^Ship, n: Node) -> int {
	append(&s.nodes, n)
	nodes_sort(s)
	for m, i in s.nodes do if m.t == n.t do return i
	return len(s.nodes) - 1
}

node_remove :: proc(s: ^Ship, i: int) {
	if i >= 0 && i < len(s.nodes) do ordered_remove(&s.nodes, i)
	if s.autoburn.active && (i >= len(s.nodes) || s.nodes[i].t != s.autoburn.node_t) {
		// Only cancel when the armed node itself went away.
		found := false
		for n in s.nodes do if n.t == s.autoburn.node_t do found = true
		if !found do s.autoburn.active = false
	}
}

nodes_sort :: proc(s: ^Ship) {
	for i in 1 ..< len(s.nodes) {
		j := i
		for j > 0 && s.nodes[j - 1].t > s.nodes[j].t {
			s.nodes[j - 1], s.nodes[j] = s.nodes[j], s.nodes[j - 1]
			j -= 1
		}
	}
}

// Arm a node: the burn starts half its duration before the node time so the
// impulse is centred where the plan put it.
arm_node :: proc(s: ^Ship, i: int) {
	if i < 0 || i >= len(s.nodes) do return
	n := s.nodes[i]
	dv := node_dv(n)
	s.autoburn = Autoburn{active = true, node_t = n.t, start = n.t - 0.5 * burn_duration(s, dv), dv = dv}
}

// Time the next armed burn begins, if any.
autoburn_start :: proc(s: ^Ship) -> (f64, bool) {
	if !s.autoburn.active do return 0, false
	return s.autoburn.start, true
}

// Absolute position, velocity and facing at the current time. Call after
// `update` and after the system's positions were refreshed for the same t.
state :: proc(sys: ^gen.System, s: ^Ship, t: f64) -> (pos, vel: [2]f64, heading: f64) {
	pos = sys.pos[s.primary] + s.pos
	vel = sys.vel[s.primary] + s.vel
	heading = s.heading
	return
}

repredict :: proc(sys: ^gen.System, s: ^Ship, t: f64) {
	// On rails the conic is the truth; the mirrored state must match `t`.
	if s.mode == .On_Rails do s.pos, s.vel = orbit.state_at(s.orbit, t)
	nodes := s.nodes[:]
	if s.autoburn.active && s.mode == .Thrusting {
		// Mid-burn: the plan should only apply what is still to be delivered.
		done := s.burned_dv - s.autoburn.dv_start
		frac := s.autoburn.dv > 0 ? clamp(1 - done / s.autoburn.dv, 0, 1) : 0
		tmp := make([]Node, len(s.nodes), context.temp_allocator)
		copy(tmp, s.nodes[:])
		for &n in tmp do if n.t == s.autoburn.node_t {
			n.prograde *= frac
			n.radial *= frac
			n.t = max(n.t, t + 1e-3)
		}
		nodes = tmp
	}
	predict(sys, s.primary, s.pos, s.vel, t, &s.segments, nodes)
	s.predicted_at = t
}

// The first pending physical event, if any. A planned node is not physical:
// nothing happens unless a burn is flown.
next_event :: proc(s: ^Ship) -> (Segment, bool) {
	if len(s.segments) == 0 do return {}, false
	seg := s.segments[0]
	return seg, seg.end != .Horizon && seg.end != .Node
}

// Advance the ship from t0 to t0 + dt.
update :: proc(sys: ^gen.System, s: ^Ship, t0, dt: f64) {
	t_end := t0 + dt
	apply_hold(s)
	switch s.mode {
	case .On_Rails:
		// Apply every event that falls inside this frame, exactly at its time.
		for {
			seg, has := next_event(s)
			if !has || seg.t1 > t_end do break
			// Impulsive (NPC) ships get a reflex: an impact inside this frame
			// is dodged right after the transition that revealed it.
			if seg.end == .Collide && s.impulsive && dodge_now(sys, s, max(seg.t0, t0)) do continue
			apply_event(sys, s, seg)
			if is_dead(s) do return
		}
		// Impulsive ships fly armed nodes as instantaneous Δv at the node time.
		if s.impulsive && s.autoburn.active {
			for n, i in s.nodes {
				if n.t != s.autoburn.node_t || n.t > t_end do continue
				pos, vel := orbit.state_at(s.orbit, n.t)
				dv := node_dv_world(n, pos, vel)
				m0 := mass(s)
				s.propellant = max(s.propellant - m0 * (1 - math.exp(-node_dv(n) / ve_eff(s))), 0)
				s.burned_dv += node_dv(n)
				s.orbit = orbit.from_state(pos, vel + dv, sys.bodies[s.primary].mu, n.t)
				ordered_remove(&s.nodes, i)
				s.autoburn.active = false
				repredict(sys, s, n.t)
				// Events after the impulse but before the frame end still apply.
				for {
					seg, has := next_event(s)
					if !has || seg.t1 > t_end do break
					apply_event(sys, s, seg)
					if is_dead(s) do return
				}
				break
			}
		}
		// Nodes whose time passed without a burn are dropped.
		if expire_nodes(s, t_end) do repredict(sys, s, t_end)
		s.pos, s.vel = orbit.state_at(s.orbit, t_end)
		// An armed burn lights the engine at its start time.
		if !s.impulsive && s.autoburn.active && t_end >= s.autoburn.start && s.propellant > 0 {
			dir := [2]f64{}
			for n in s.nodes do if n.t == s.autoburn.node_t { dir = node_dv_world(n, s.pos, s.vel); break }
			s.heading = math.atan2(dir.y, dir.x)
			s.hold = .None
			s.manual_heading = false
			s.throttle = 1
			s.autoburn.dv_start = s.burned_dv
		}
		if s.throttle > 0 && s.propellant > 0 {
			s.mode = .Thrusting
		}
	case .Thrusting:
		integrate(sys, s, t0, t_end)
		if is_dead(s) do return
		if s.autoburn.active && s.autoburn.start <= t_end && s.burned_dv - s.autoburn.dv_start >= s.autoburn.dv {
			// Burn delivered: cut, drop the node, keep the rest of the plan.
			s.throttle = 0
			for n, i in s.nodes do if n.t == s.autoburn.node_t { ordered_remove(&s.nodes, i); break }
			s.autoburn.active = false
		}
		if s.throttle <= 0 || s.propellant <= 0 {
			s.throttle = 0
			s.mode = .On_Rails
			s.orbit = orbit.from_state(s.pos, s.vel, sys.bodies[s.primary].mu, t_end)
			repredict(sys, s, t_end)
		} else if t_end - s.predicted_at >= PREDICT_EVERY {
			repredict(sys, s, t_end)
		}
	case .Docked:
		if s.docked_ship do return // rides the host ship; the game copies its state
		st := sys.stations[s.dock]
		s.pos, s.vel = orbit.state_at(st.orbit, t_end)
	case .Cryo, .Wrecked, .Destroyed:
	}
	apply_hazards(sys, s, t_end, dt)
}

// Drop nodes already in the past that are not being flown. Returns true if
// anything changed.
@(private = "file")
expire_nodes :: proc(s: ^Ship, t: f64) -> bool {
	changed := false
	for i := 0; i < len(s.nodes); {
		n := s.nodes[i]
		flying := s.autoburn.active && s.autoburn.node_t == n.t
		if n.t < t && !flying {
			ordered_remove(&s.nodes, i)
			changed = true
		} else {
			i += 1
		}
	}
	return changed
}

@(private = "file")
// Attitude: a hold points the ship along or against its motion. With no
// hold, a ship faces prograde by itself unless the pilot has turned it by
// hand (`manual_heading`), which lasts until a hold or an autoburn takes over.
apply_hold :: proc(s: ^Ship) {
	switch s.hold {
	case .Prograde:   s.heading = math.atan2(s.vel.y, s.vel.x)
	case .Retrograde: s.heading = math.atan2(-s.vel.y, -s.vel.x)
	case .None:
		if !s.manual_heading && (s.vel.x != 0 || s.vel.y != 0) && s.throttle <= 0 do s.heading = math.atan2(s.vel.y, s.vel.x)
	}
}

@(private = "file")
apply_event :: proc(sys: ^gen.System, s: ^Ship, seg: Segment) {
	te := seg.t1
	pos, vel := orbit.state_at(s.orbit, te)
	switch seg.end {
	case .Collide:
		when NPC_DEBUG do fmt.printfln("WRECK %s on %s at t=%.0f: ship orbit a=%.2f e=%.3f peri=%.2f | segment a=%.2f e=%.3f peri=%.2f t0=%.0f | r=%.2f radius %.2f mode=%v", s.name, sys.bodies[s.primary].name, te, s.orbit.a, s.orbit.e, orbit.periapsis(s.orbit), seg.orbit.a, seg.orbit.e, orbit.periapsis(seg.orbit), seg.t0, orbit.length(pos), sys.bodies[s.primary].radius, s.mode)
		s.pos, s.vel = pos, {}
		if s.primary == gen.STAR {
			blow_up(s)
			return
		}
		s.mode = .Wrecked
		s.throttle = 0
		clear(&s.segments)
		return
	case .Exit:
		pos, vel, s.primary = to_parent_frame(sys, s.primary, pos, vel, te)
	case .Enter:
		pos, vel = to_child_frame(sys, seg.target, pos, vel, te)
		s.primary = seg.target
	case .Horizon, .Node:
		return
	}
	s.transitions += 1
	s.pos, s.vel = pos, vel
	s.orbit = orbit.from_state(pos, vel, sys.bodies[s.primary].mu, te)
	repredict(sys, s, te)
}

// Velocity-Verlet under the primary's gravity plus thrust, with sphere-of-
// influence checks each substep (docs/DESIGN.md §4.3).
@(private = "file")
integrate :: proc(sys: ^gen.System, s: ^Ship, t0, t_end: f64) {
	t := t0
	for t < t_end {
		h := min(MAX_SUBSTEP, t_end - t)
		mu := sys.bodies[s.primary].mu
		if s.propellant <= 0 do s.throttle = 0
		acc_mag := s.throttle * s.stats.thrust / mass(s)
		acc_t := [2]f64{math.cos(s.heading), math.sin(s.heading)} * acc_mag
		s.burned_dv += acc_mag * h
		a0 := gravity(s.pos, mu) + acc_t
		s.pos += s.vel * h + a0 * (0.5 * h * h)
		a1 := gravity(s.pos, mu) + acc_t
		s.vel += (a0 + a1) * (0.5 * h)
		s.propellant = max(s.propellant - s.throttle * s.stats.thrust / ve_eff(s) * h, 0)
		t += h
		if check_transitions(sys, s, t) do return
	}
}

@(private = "file")
gravity :: proc(pos: [2]f64, mu: f64) -> [2]f64 {
	r := orbit.length(pos)
	return pos * (-mu / (r * r * r))
}

// Geometric sphere-of-influence checks at time t for the integrating ship.
// Returns true when the ship was wrecked.
@(private = "file")
check_transitions :: proc(sys: ^gen.System, s: ^Ship, t: f64) -> bool {
	b := &sys.bodies[s.primary]
	r := orbit.length(s.pos)
	if r < b.radius {
		if s.primary == gen.STAR {
			blow_up(s)
			return true
		}
		s.mode = .Wrecked
		s.throttle = 0
		s.vel = 0
		clear(&s.segments)
		return true
	}
	if s.primary != gen.STAR && r > b.soi && orbit.dot(s.pos, s.vel) > 0 {
		s.pos, s.vel, s.primary = to_parent_frame(sys, s.primary, s.pos, s.vel, t)
		s.transitions += 1
		return false
	}
	for &cb, ci in sys.bodies {
		if cb.parent != s.primary do continue
		cp, cv := orbit.state_at(cb.orbit, t)
		d := s.pos - cp
		if orbit.length(d) < cb.soi && orbit.dot(d, s.vel - cv) < 0 {
			s.pos, s.vel = d, s.vel - cv
			s.primary = gen.Body_Handle(ci)
			s.transitions += 1
			return false
		}
	}
	return false
}
