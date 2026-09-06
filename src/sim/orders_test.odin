package sim

import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

@(test)
orbit_at_altitude_order_reaches_a_circular_orbit :: proc(t: ^testing.T) {
	sys := gen.generate(3)
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.25, 0)
	defer destroy(&s)
	b := sys.bodies[1]
	target := orbit.length(s.pos) * 1.6
	testing.expect(t, target < b.soi * 0.9, "target inside the sphere")
	o: Order
	ok, reason := order_orbit_at(&sys, &s, &o, target, 0)
	testing.expectf(t, ok, "order accepted: %s", reason)
	tt := 0.0
	dt := 2.0 // near the game's burn-time step; coarse steps overshoot burns
	for order_active(&o) && tt < 40 * orbit.period(s.orbit) + 2e5 {
		update(&sys, &s, tt, dt)
		tt += dt
		gen.update(&sys, tt)
		order_update(&sys, &s, &o, tt)
	}
	testing.expectf(t, o.stage == .Done, "order done (%v: %s)", o.stage, o.status)
	testing.expectf(t, abs(orbit.length(s.pos) - target) / target < 0.05, "radius near the target (%v vs %v)", orbit.length(s.pos), target)
	testing.expectf(t, s.orbit.e < ORBIT_TOLERANCE * 1.5, "near-circular (e=%v)", s.orbit.e)
	// Lowering works too.
	o2: Order
	low := target * 0.6
	ok2, _ := order_orbit_at(&sys, &s, &o2, low, tt)
	testing.expect(t, ok2, "lowering order accepted")
	for order_active(&o2) && tt < 80 * orbit.period(s.orbit) + 1e6 {
		update(&sys, &s, tt, dt)
		tt += dt
		gen.update(&sys, tt)
		order_update(&sys, &s, &o2, tt)
	}
	testing.expectf(t, o2.stage == .Done && abs(orbit.length(s.pos) - low) / low < 0.05, "lowered to %v (got %v, %v)", low, orbit.length(s.pos), o2.status)
	// Refusals.
	o3: Order
	bad, _ := order_orbit_at(&sys, &s, &o3, b.radius * 0.5, tt)
	testing.expect(t, !bad, "inside the surface margin is refused")
}

@(test)
apsis_burn_and_rcs_nudge :: proc(t: ^testing.T) {
	sys := gen.generate(3)
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.25, 0)
	defer destroy(&s)
	mu := sys.bodies[1].mu
	r := orbit.length(s.pos)
	// A prograde burn now that puts the apoapsis at 2r.
	n := raise_lower_node(&sys, &s, 60, 2 * r)
	testing.expect(t, n.prograde > 0, "raising burns prograde")
	pos, vel := orbit.state_at(s.orbit, 60)
	p, _ := local_frame(pos, vel)
	after := orbit.from_state(pos, vel + p * n.prograde, mu, 60)
	testing.expectf(t, abs(orbit.apoapsis(after) - 2 * r) / r < 1e-6, "apoapsis lands at 2r (%v)", orbit.apoapsis(after))
	// An RCS nudge changes velocity by exactly the impulse and costs a little propellant.
	before := s.vel
	prop := s.propellant
	testing.expect(t, rcs_nudge(&sys, &s, {0.0003, 0}, 0), "nudge applied")
	testing.expect(t, abs(s.vel.x - before.x - 0.0003) < 1e-12 && s.propellant < prop, "velocity and propellant changed")
}
