package sim

import "core:math"
import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

// Star plus one planet on a circular orbit.
@(private = "file")
test_system :: proc() -> gen.System {
	sys: gen.System
	context.allocator = gen.init_empty(&sys, 1)
	star_mu := 0.3
	append(&sys.bodies, gen.Body{name = "Star", parent = gen.NONE, kind = .Star, mu = star_mu, radius = 60, soi = math.inf_f64(1)})
	a := 600.0
	mu := 0.002
	append(&sys.bodies, gen.Body {
		name = "Planet", parent = gen.STAR, kind = .Rock, mu = mu, radius = 3.5,
		orbit = orbit.circular(star_mu, a, 0, 0),
		soi = orbit.soi_radius(a, mu, star_mu),
	})
	gen.finish(&sys)
	return sys
}

@(test)
predictor_finds_flyby_and_exit :: proc(t: ^testing.T) {
	sys := test_system()
	defer gen.destroy(&sys)
	planet := gen.Body_Handle(1)
	soi := sys.bodies[planet].soi
	// Ship just outside the planet's sphere, moving inward fast enough to escape again.
	pp, pv := orbit.state_at(sys.bodies[planet].orbit, 0)
	pos := pp + {soi * 1.2, 0}
	vel := pv + {-0.012, 0.004}
	segs: [dynamic]Segment
	defer delete(segs)
	predict(&sys, gen.STAR, pos, vel, 0, &segs)
	testing.expect(t, len(segs) >= 3, "star -> planet -> star")
	if len(segs) < 3 do return
	testing.expect(t, segs[0].end == .Enter && segs[0].target == planet, "first segment ends entering the planet")
	testing.expect(t, segs[1].primary == planet && segs[1].orbit.e > 1, "flyby is a hyperbola about the planet")
	testing.expect(t, segs[1].end == .Exit, "flyby ends leaving the sphere")
	testing.expect(t, segs[2].primary == gen.STAR, "back in the star's frame")
	// Excess speed in and out matches; heliocentric speed does not (slingshot).
	v_in := orbit.length(segs[1].orbit.mu * 0 + vel_rel_at(&sys, segs[1], segs[1].t0))
	v_out := orbit.length(vel_rel_at(&sys, segs[1], segs[1].t1))
	testing.expectf(t, abs(v_in - v_out) < 1e-6, "flyby speed in %v vs out %v", v_in, v_out)
	_, hv_out := orbit.state_at(segs[2].orbit, segs[2].t0)
	testing.expectf(t, abs(orbit.length(hv_out) - orbit.length(vel)) > 1e-4, "heliocentric speed changed: %v -> %v", orbit.length(vel), orbit.length(hv_out))
}

@(private = "file")
vel_rel_at :: proc(sys: ^gen.System, seg: Segment, t: f64) -> [2]f64 {
	_, v := orbit.state_at(seg.orbit, t)
	return v
}

@(test)
rails_ship_transitions_through_flyby :: proc(t: ^testing.T) {
	sys := test_system()
	defer gen.destroy(&sys)
	planet := gen.Body_Handle(1)
	soi := sys.bodies[planet].soi
	pp, pv := orbit.state_at(sys.bodies[planet].orbit, 0)
	s := Ship{stats = COURIER, primary = gen.STAR, mode = .On_Rails, propellant = COURIER.propellant_cap}
	defer destroy(&s)
	s.pos = pp + {soi * 1.2, 0}
	s.vel = pv + {-0.012, 0.004}
	s.orbit = orbit.from_state(s.pos, s.vel, 0.3, 0)
	repredict(&sys, &s, 0)
	seen_planet := false
	tt := 0.0
	for tt < 60000 {
		update(&sys, &s, tt, 2000) // coarse frames: events must still be applied exactly
		tt += 2000
		gen.update(&sys, tt)
		if s.primary == planet do seen_planet = true
	}
	testing.expect(t, seen_planet, "ship spent time in the planet's frame")
	testing.expect(t, s.primary == gen.STAR, "ship is back in the star's frame")
	testing.expect(t, s.transitions == 2, "exactly two transitions")
	testing.expect(t, s.mode == .On_Rails, "still on rails")
}

@(test)
thrust_raises_orbit_and_burns_propellant :: proc(t: ^testing.T) {
	sys := test_system()
	defer gen.destroy(&sys)
	planet := gen.Body_Handle(1)
	s := spawn_in_orbit(&sys, planet, 0.15, 0)
	defer destroy(&s)
	apo0 := orbit.apoapsis(s.orbit)
	fuel0 := s.propellant
	s.hold = .Prograde
	s.throttle = 1
	tt := 0.0
	for tt < 120 {
		update(&sys, &s, tt, 1.0 / 60.0)
		tt += 1.0 / 60.0
	}
	testing.expect(t, s.mode == .Thrusting, "engine lit")
	s.throttle = 0
	update(&sys, &s, tt, 1.0 / 60.0)
	testing.expect(t, s.mode == .On_Rails, "back on rails after cut")
	testing.expectf(t, orbit.apoapsis(s.orbit) > apo0 * 1.05, "apoapsis %v -> %v", apo0, orbit.apoapsis(s.orbit))
	testing.expect(t, s.propellant < fuel0, "propellant spent")
	testing.expect(t, s.primary == planet, "still around the planet")
	testing.expect(t, len(s.segments) > 0, "prediction available")
}
