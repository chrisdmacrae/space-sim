package sim

import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

// Inner planet, a heavy middle planet to swing past, and an outer target.
@(private = "file")
three_planets :: proc() -> gen.System {
	sys: gen.System
	context.allocator = gen.init_empty(&sys, 6)
	star_mu := 0.3
	append(&sys.bodies, gen.Body{name = "Star", parent = gen.NONE, kind = .Star, mu = star_mu, radius = 60, soi = 1e300})
	specs := [?]struct { name: string, a, mu, radius, phase: f64 } {
		{"Inner", 600, 0.002, 3.5, 0.0},
		{"Giant", 1300, 0.012, 12, 1.0},
		{"Outer", 2600, 0.002, 3.5, 2.2},
	}
	for sp in specs {
		append(&sys.bodies, gen.Body{name = sp.name, parent = gen.STAR, kind = .Rock, mu = sp.mu, radius = sp.radius,
			orbit = orbit.circular(star_mu, sp.a, sp.phase, 0), soi = orbit.soi_radius(sp.a, sp.mu, star_mu)})
	}
	gen.finish(&sys)
	return sys
}

@(test)
flyby_search_finds_feasible_assists :: proc(t: ^testing.T) {
	sys := three_planets()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	geo, ok, _ := geometry(&sys, &s, Destination{kind = .Body, index = 3})
	testing.expect(t, ok, "geometry ok")
	res := search(&sys, &s, geo, 0)
	testing.expect(t, res.ok, "search ok")
	testing.expect(t, res.flyby_best.ok, "a feasible flyby exists")
	if !res.flyby_best.ok do return
	fb := res.flyby_best_fb
	testing.expectf(t, fb.via == gen.Body_Handle(2), "via the giant, got body %v", fb.via)
	testing.expectf(t, fb.r_p >= sys.bodies[2].radius * FLYBY_MARGIN, "periapsis %v above the surface", fb.r_p)
	testing.expectf(t, res.flyby_best.dv_total < 1.6 * res.dv_best, "flyby dv %v within reach of direct %v", res.flyby_best.dv_total, res.dv_best)
}

@(test)
autopilot_flies_a_flyby_plan :: proc(t: ^testing.T) {
	sys := three_planets()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	s.impulsive = true
	geo, ok, _ := geometry(&sys, &s, Destination{kind = .Body, index = 3})
	testing.expect(t, ok, "geometry ok")
	res := search(&sys, &s, geo, 0)
	testing.expect(t, res.flyby_best.ok, "flyby available")
	if !res.flyby_best.ok do return
	ap: Autopilot
	autopilot_start(&sys, &s, &ap, geo, Destination{kind = .Body, index = 3}, .Balanced, res.flyby_best, 0, res.flyby_best_fb)
	seen_giant := false
	tt := 0.0
	limit := res.flyby_best.t_arrive * 2 + 400000
	for tt < limit && ap.active {
		dt := 300.0
		update(&sys, &s, tt, dt)
		tt += dt
		gen.update(&sys, tt)
		autopilot_update(&sys, &s, &ap, tt)
		if s.primary == gen.Body_Handle(2) do seen_giant = true
	}
	testing.expect(t, seen_giant, "passed through the giant's sphere")
	testing.expectf(t, ap.stage == .Done, "autopilot ended in %v: %s", ap.stage, ap.status)
	testing.expectf(t, s.primary == gen.Body_Handle(3), "around body %v", s.primary)
	testing.expectf(t, s.orbit.e < 0.3, "captured e=%v", s.orbit.e)
}

@(test)
route_options_list_direct_then_assists :: proc(t: ^testing.T) {
	sys := three_planets()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	geo, ok, _ := geometry(&sys, &s, Destination{kind = .Body, index = 3})
	testing.expect(t, ok, "geometry ok")
	res := search(&sys, &s, geo, 0)
	testing.expect(t, res.ok && res.n_options > 0, "options exist")
	if res.n_options == 0 do return
	first := res.options[0]
	testing.expect(t, first.via == gen.NONE && !first.cand.flyby, "the first option is a direct transfer")
	seen_assist := false
	for k in 0 ..< res.n_options {
		o := res.options[k]
		testing.expect(t, o.cand.ok, "every listed option is solvable")
		testing.expect(t, o.tags != {}, "every option wins at least one objective")
		if o.via == gen.NONE {
			testing.expect(t, !o.cand.flyby, "direct options carry no assist")
			testing.expect(t, !seen_assist, "direct options come before assists")
		} else {
			seen_assist = true
			testing.expect(t, o.cand.flyby && o.fb.via == o.via, "assist options name their body")
		}
	}
	testing.expect(t, seen_assist == res.flyby_best.ok, "assists are listed exactly when one is feasible")
	// Every direct objective winner appears among the direct options.
	for obj in Objective {
		c := res.direct[obj]
		if !c.ok do continue
		found := false
		for k in 0 ..< res.n_options do if res.options[k].via == gen.NONE && obj in res.options[k].tags do found = true
		testing.expectf(t, found, "direct %v winner is listed", obj)
	}
}
