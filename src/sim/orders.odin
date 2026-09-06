package sim

// Orders: moves given as intent rather than throttle. The autopilot covers
// journeys between bodies and stations; this file covers the in-frame
// moves flown with nodes and the autoburn: change to a circular orbit at a
// chosen altitude, and the apsis drag that sets up a single raise/lower burn.

import "core:math"
import gen "sim:gen"
import orbit "sim:orbit"

Order_Kind :: enum u8 {
	None,
	Orbit_Altitude, // circular orbit at `r_target` about the current primary
}

Order_Stage :: enum u8 {
	Idle,
	Transfer,    // first burn armed: puts the far apsis at the target radius
	Circularize, // second burn armed at that apsis
	Trim,        // a small third burn if the result is still eccentric
	Done,
	Failed,
}

Order :: struct {
	kind:     Order_Kind,
	stage:    Order_Stage,
	r_target: f64,
	status:   string,
	trims:    int,
}

ORBIT_TOLERANCE :: 0.02 // eccentricity below which a circularized orbit is accepted

// Time of the next periapsis (which = 0) or apoapsis (which = pi) on an ellipse.
next_apsis_time :: proc(o: orbit.Orbit, t: f64, which: f64) -> f64 {
	M := orbit.mean_anomaly_at(o, t)
	d := math.mod(which - M + 4 * math.PI, 2 * math.PI)
	if d < 30 * orbit.mean_motion(o) do d += 2 * math.PI // too soon to burn: take the next pass
	return t + d / orbit.mean_motion(o)
}

// The prograde burn at a point of radius r_b and speed v_b that makes the
// opposite apsis sit at r_other.
apsis_burn :: proc(mu, r_b, v_b, r_other: f64) -> f64 {
	v_need := math.sqrt(mu * (2 / r_b - 2 / (r_b + r_other)))
	return v_need - v_b
}

// A node at time t_burn on the ship's current orbit that moves the opposite
// apsis to r_other. Returns the node.
raise_lower_node :: proc(sys: ^gen.System, s: ^Ship, t_burn, r_other: f64) -> Node {
	pos, vel := orbit.state_at(s.orbit, t_burn)
	r_b := orbit.length(pos)
	v_b := orbit.length(vel)
	mu := sys.bodies[s.primary].mu
	return Node{t = t_burn, prograde = apsis_burn(mu, r_b, v_b, r_other)}
}

// Begin an orbit-at-altitude order: `r` is the radius from the primary's centre.
order_orbit_at :: proc(sys: ^gen.System, s: ^Ship, o: ^Order, r: f64, t: f64) -> (ok: bool, reason: string) {
	if s.mode != .On_Rails do return false, "the ship must be coasting"
	b := sys.bodies[s.primary]
	if r < b.radius * 1.2 do return false, "that altitude is inside the surface margin"
	if r > b.soi * 0.9 do return false, "that altitude is outside this body's sphere"
	clear(&s.nodes)
	s.autoburn.active = false
	o^ = Order{kind = .Orbit_Altitude, stage = .Transfer, r_target = r}
	// Burn at the apsis nearest in speed to a circular orbit: the periapsis
	// when raising, the apoapsis when lowering; a circular orbit burns now.
	t_burn := t + 60
	if s.orbit.e > 0.01 {
		raising := r > orbit.length(s.pos)
		t_burn = next_apsis_time(s.orbit, t, raising ? 0 : math.PI)
	}
	n := raise_lower_node(sys, s, t_burn, r)
	arm_node(s, node_add(s, n))
	repredict(sys, s, t)
	o.status = "transfer burn"
	return true, ""
}

// Advance the order once the current burn is over.
order_update :: proc(sys: ^gen.System, s: ^Ship, o: ^Order, t: f64) {
	if o.kind == .None || o.stage == .Done || o.stage == .Failed do return
	if is_dead(s) {
		o.stage = .Failed
		o.status = "ship lost"
		return
	}
	if s.autoburn.active || s.mode != .On_Rails || len(s.nodes) > 0 do return
	mu := sys.bodies[s.primary].mu
	switch o.stage {
	case .Transfer:
		// On the transfer ellipse: the far apsis should sit at the target. A
		// finite burn can miss; fix it at the next pass of the burn point.
		at_apo := abs(orbit.apoapsis(s.orbit) - o.r_target) < abs(orbit.periapsis(s.orbit) - o.r_target)
		far := at_apo ? orbit.apoapsis(s.orbit) : orbit.periapsis(s.orbit)
		if abs(far - o.r_target) / o.r_target > 0.05 && o.trims < 3 {
			o.trims += 1
			t_burn := next_apsis_time(s.orbit, t, at_apo ? 0 : math.PI)
			arm_node(s, node_add(s, raise_lower_node(sys, s, t_burn, o.r_target)))
			repredict(sys, s, t)
			o.status = "correcting the transfer"
			return
		}
		t_burn := next_apsis_time(s.orbit, t, at_apo ? math.PI : 0)
		pos, vel := orbit.state_at(s.orbit, t_burn)
		dv := orbit.circular_speed(mu, orbit.length(pos)) - orbit.length(vel)
		arm_node(s, node_add(s, Node{t = t_burn, prograde = dv}))
		repredict(sys, s, t)
		o.stage = .Circularize
		o.status = "circularizing"
		o.trims = 0
	case .Circularize, .Trim:
		if s.orbit.e <= ORBIT_TOLERANCE || o.trims >= 2 {
			o.stage = .Done
			o.status = "in orbit"
			return
		}
		// Still eccentric (finite burns): one more circularize at the target radius apsis.
		o.trims += 1
		at_apo := abs(orbit.apoapsis(s.orbit) - o.r_target) < abs(orbit.periapsis(s.orbit) - o.r_target)
		t_burn := next_apsis_time(s.orbit, t, at_apo ? math.PI : 0)
		pos, vel := orbit.state_at(s.orbit, t_burn)
		dv := orbit.circular_speed(mu, orbit.length(pos)) - orbit.length(vel)
		arm_node(s, node_add(s, Node{t = t_burn, prograde = dv}))
		repredict(sys, s, t)
		o.stage = .Trim
		o.status = "trimming"
	case .Idle, .Done, .Failed:
	}
}

// Is a burn or wait pending for this order (for auto time)?
order_active :: proc(o: ^Order) -> bool {
	return o.kind != .None && o.stage != .Done && o.stage != .Failed && o.stage != .Idle
}

// A small RCS impulse in a world direction: coasting ships only.
rcs_nudge :: proc(sys: ^gen.System, s: ^Ship, dv: [2]f64, t: f64) -> bool {
	if s.mode != .On_Rails || s.propellant <= 0 do return false
	m0 := mass(s)
	s.propellant = max(s.propellant - m0 * (1 - math.exp(-orbit.length(dv) / s.stats.ve)), 0)
	s.vel += dv
	s.orbit = orbit.from_state(s.pos, s.vel, sys.bodies[s.primary].mu, t)
	repredict(sys, s, t)
	return true
}
