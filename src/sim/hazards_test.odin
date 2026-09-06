package sim

import "core:testing"
import core "sim:core"
import gen "sim:gen"
import orbit "sim:orbit"

@(private = "file")
find_seed :: proc(kind: gen.Star_Kind) -> u64 {
	for seed in 1 ..= 400 {
		s := gen.summarize(u64(seed))
		if s.star.kind == kind do return u64(seed)
	}
	return 0
}

@(test)
hull_is_untouched_away_from_hazards :: proc(t: ^testing.T) {
	seed := find_seed(.Main_Sequence)
	sys := gen.generate(seed)
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.STAR, 0.3, 0)
	defer destroy(&s)
	testing.expect(t, orbit.length(s.pos) > sys.star.heat_radius, "test orbit sits outside the heat line")
	for i in 0 ..< 200 do update(&sys, &s, f64(i) * 3600, 3600)
	testing.expectf(t, s.hull == 1, "hull stays full (%v)", s.hull)
	testing.expect(t, s.hazard == .None, "no hazard reported")
}

@(test)
heat_cooks_the_hull_near_the_star :: proc(t: ^testing.T) {
	seed := find_seed(.Main_Sequence)
	sys := gen.generate(seed)
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.STAR, 0.3, 0)
	defer destroy(&s)
	// Park just inside the heat line.
	r := sys.star.heat_radius * 0.8
	s.orbit = orbit.circular(sys.bodies[0].mu, r, 0, 0, 1)
	s.pos, s.vel = orbit.state_at(s.orbit, 0)
	repredict(&sys, &s, 0)
	update(&sys, &s, 0, 600)
	testing.expect(t, s.hazard == .Heat, "heat hazard reported")
	testing.expectf(t, s.hull < 1 && s.hull > 0.5, "some hull lost in ten minutes (%v)", s.hull)
	// Left there, the ship eventually dies.
	tt := 600.0
	for s.mode != .Destroyed && tt < 40 * core.SECONDS_PER_HOUR {
		update(&sys, &s, tt, 600)
		tt += 600
	}
	testing.expect(t, s.mode == .Destroyed, "hull failure destroys the ship")
	testing.expect(t, s.hull == 0, "hull reads zero")
}

@(test)
falling_into_the_star_destroys_the_ship :: proc(t: ^testing.T) {
	seed := find_seed(.Main_Sequence)
	sys := gen.generate(seed)
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.STAR, 0.3, 0)
	defer destroy(&s)
	// Radial plunge from four radii.
	s.pos = {sys.star.radius * 4, 0}
	s.vel = {0, 1e-6}
	s.orbit = orbit.from_state(s.pos, s.vel, sys.bodies[0].mu, 0)
	repredict(&sys, &s, 0)
	tt := 0.0
	for s.mode == .On_Rails && tt < 30 * core.SECONDS_PER_DAY {
		update(&sys, &s, tt, 300)
		tt += 300
	}
	testing.expectf(t, s.mode == .Destroyed, "the ship is destroyed, not wrecked (mode %v)", s.mode)
	testing.expect(t, len(s.segments) == 0 && s.throttle == 0, "nothing left to fly")
}

@(test)
pulsar_wind_wears_the_hull_slowly :: proc(t: ^testing.T) {
	seed := find_seed(.Pulsar)
	testing.expect(t, seed != 0, "a pulsar exists in the first 400 seeds")
	if seed == 0 do return
	sys := gen.generate(seed)
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.STAR, 0.3, 0)
	defer destroy(&s)
	r := sys.star.wind_radius * 0.5
	testing.expect(t, r > sys.star.heat_radius, "test orbit is in the wind but outside the heat line")
	s.orbit = orbit.circular(sys.bodies[0].mu, r, 0, 0, 1)
	s.pos, s.vel = orbit.state_at(s.orbit, 0)
	repredict(&sys, &s, 0)
	update(&sys, &s, 0, core.SECONDS_PER_HOUR)
	testing.expect(t, s.hazard == .Wind, "wind hazard reported")
	testing.expectf(t, s.hull < 1 && s.hull > 0.9, "an hour in the wind costs a little hull (%v)", s.hull)
	// Docked ships are sheltered: no station in the wind here, so just
	// check the parked-outside case instead.
	s.orbit = orbit.circular(sys.bodies[0].mu, sys.star.wind_radius * 1.2, 0, 0, 1)
	s.pos, s.vel = orbit.state_at(s.orbit, 0)
	repredict(&sys, &s, 0)
	before := s.hull
	update(&sys, &s, 0, core.SECONDS_PER_HOUR)
	testing.expect(t, s.hull == before && s.hazard == .None, "outside the wind nothing happens")
}
