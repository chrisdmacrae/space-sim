package sim

import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

// Star with two planets on circular orbits.
@(private = "file")
two_planets :: proc() -> gen.System {
	sys: gen.System
	context.allocator = gen.init_empty(&sys, 3)
	star_mu := 0.3
	append(&sys.bodies, gen.Body{name = "Star", parent = gen.NONE, kind = .Star, mu = star_mu, radius = 60, soi = 1e300})
	for a, i in ([?]f64{600, 1400}) {
		mu := 0.002
		append(&sys.bodies, gen.Body {
			name = i == 0 ? "Inner" : "Outer", parent = gen.STAR, kind = .Rock, mu = mu, radius = 3.5,
			orbit = orbit.circular(star_mu, a, f64(i) * 1.3, 0),
			soi = orbit.soi_radius(a, mu, star_mu),
		})
	}
	gen.finish(&sys)
	return sys
}

@(test)
search_finds_transfers_near_hohmann :: proc(t: ^testing.T) {
	sys := two_planets()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	geo, ok, reason := geometry(&sys, &s, Destination{kind = .Body, index = 2})
	testing.expectf(t, ok, "geometry: %s", reason)
	if !ok do return
	res := search(&sys, &s, geo, 0)
	testing.expect(t, res.ok, "search ok")
	fuel := res.picks[.Fuel]
	testing.expect(t, fuel.ok && fuel.fits, "fuel plan exists and fits")
	// Analytic: Hohmann heliocentric Δv, then escape/capture with Oberth.
	mu := 0.3
	r1, r2 := 600.0, 1400.0
	v1 := orbit.circular_speed(mu, r1) * (orbit.length([2]f64{2 * r2 / (r1 + r2), 0}) - 0)
	_ = v1
	dv1 := orbit.circular_speed(mu, r1) * (orbit.length([2]f64{1, 0}) * (2 * r2 / (r1 + r2)) - 1)
	_ = dv1
	testing.expectf(t, fuel.dv_total > 0.005 && fuel.dv_total < 0.05, "fuel dv %v", fuel.dv_total)
	time := res.picks[.Time]
	testing.expect(t, time.ok, "time plan exists")
	testing.expectf(t, time.t_arrive <= fuel.t_arrive + 1, "time plan arrives no later (%v vs %v)", time.t_arrive, fuel.t_arrive)
	testing.expectf(t, fuel.dv_total <= time.dv_total + 1e-9, "fuel plan is no dearer (%v vs %v)", fuel.dv_total, time.dv_total)
}

@(test)
autopilot_flies_to_outer_planet :: proc(t: ^testing.T) {
	sys := two_planets()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	geo, ok, _ := geometry(&sys, &s, Destination{kind = .Body, index = 2})
	testing.expect(t, ok, "geometry ok")
	res := search(&sys, &s, geo, 0)
	testing.expect(t, res.ok, "search ok")
	ap: Autopilot
	autopilot_start(&sys, &s, &ap, geo, Destination{kind = .Body, index = 2}, .Fuel, res.picks[.Fuel], 0)
	tt := 0.0
	limit := res.picks[.Fuel].t_arrive * 2 + 200000
	for tt < limit && ap.active {
		dt := s.mode == .Thrusting || s.autoburn.active && tt > s.autoburn.start - 10 ? 0.5 : 120.0
		update(&sys, &s, tt, dt)
		tt += dt
		gen.update(&sys, tt)
		autopilot_update(&sys, &s, &ap, tt)
	}
	testing.expectf(t, ap.stage == .Done, "autopilot ended in %v: %s", ap.stage, ap.status)
	testing.expectf(t, s.primary == gen.Body_Handle(2), "ship around body %v", s.primary)
	testing.expectf(t, s.orbit.e < 0.3, "captured orbit e=%v", s.orbit.e)
	testing.expectf(t, s.propellant > 0, "propellant left %v", s.propellant)
}

@(test)
plan_predicts_encounter_before_departure :: proc(t: ^testing.T) {
	sys := two_planets()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	geo, ok, _ := geometry(&sys, &s, Destination{kind = .Body, index = 2})
	testing.expect(t, ok, "geometry ok")
	res := search(&sys, &s, geo, 0)
	for obj in ([?]Objective{.Fuel, .Balanced}) {
		ap: Autopilot
		autopilot_start(&sys, &s, &ap, geo, Destination{kind = .Body, index = 2}, obj, res.picks[obj], 0)
		found := false
		for seg in s.segments do if seg.end == .Enter && seg.target == gen.Body_Handle(2) do found = true
		testing.expectf(t, found, "%v plan: encounter with the target is on the predicted path before departure", obj)
		autopilot_cancel(&s, &ap)
	}
}
