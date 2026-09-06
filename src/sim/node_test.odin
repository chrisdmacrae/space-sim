package sim

import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

@(private = "file")
planet_system :: proc() -> gen.System {
	sys: gen.System
	context.allocator = gen.init_empty(&sys, 2)
	append(&sys.bodies, gen.Body{name = "Star", parent = gen.NONE, kind = .Star, mu = 0.3, radius = 60, soi = 1e300})
	append(&sys.bodies, gen.Body{name = "Planet", parent = gen.STAR, kind = .Rock, mu = 0.002, radius = 3.5, orbit = orbit.circular(0.3, 600, 0, 0), soi = orbit.soi_radius(600, 0.002, 0.3)})
	gen.finish(&sys)
	return sys
}

@(test)
node_in_prediction_raises_apoapsis :: proc(t: ^testing.T) {
	sys := planet_system()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	apo0 := orbit.apoapsis(s.orbit)
	node_add(&s, Node{t = 600, prograde = 0.004})
	repredict(&sys, &s, 0)
	testing.expect(t, len(s.segments) >= 2, "segment before and after the node")
	if len(s.segments) < 2 do return
	testing.expect(t, s.segments[0].end == .Node && s.segments[0].node == 0, "first segment ends at the node")
	testing.expectf(t, abs(s.segments[0].t1 - 600) < 1e-6, "node time %v", s.segments[0].t1)
	testing.expectf(t, orbit.apoapsis(s.segments[1].orbit) > apo0 * 1.2, "apoapsis %v -> %v", apo0, orbit.apoapsis(s.segments[1].orbit))
	testing.expect(t, s.segments[1].primary == gen.Body_Handle(1), "still around the planet")
}

@(test)
autoburn_flies_node_and_matches_prediction :: proc(t: ^testing.T) {
	sys := planet_system()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	node_add(&s, Node{t = 600, prograde = 0.004})
	repredict(&sys, &s, 0)
	planned := s.segments[1].orbit
	arm_node(&s, 0)
	start, ok := autoburn_start(&s)
	testing.expect(t, ok && start < 600 && start > 500, "burn starts shortly before the node")
	tt := 0.0
	lit := false
	for tt < 1500 {
		update(&sys, &s, tt, 0.25)
		tt += 0.25
		gen.update(&sys, tt)
		if s.mode == .Thrusting do lit = true
	}
	testing.expect(t, lit, "engine lit during the window")
	testing.expect(t, s.mode == .On_Rails, "back on rails afterwards")
	testing.expect(t, !s.autoburn.active, "autoburn finished")
	testing.expect(t, len(s.nodes) == 0, "node consumed")
	got := s.orbit
	testing.expectf(t, abs(orbit.apoapsis(got) - orbit.apoapsis(planned)) < 0.05 * orbit.apoapsis(planned), "apoapsis flown %v vs planned %v", orbit.apoapsis(got), orbit.apoapsis(planned))
}

@(test)
stale_nodes_expire :: proc(t: ^testing.T) {
	sys := planet_system()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	node_add(&s, Node{t = 100, prograde = 0.001})
	node_add(&s, Node{t = 5000, prograde = 0.001})
	update(&sys, &s, 0, 200)
	testing.expect(t, len(s.nodes) == 1 && s.nodes[0].t == 5000, "past node dropped, future node kept")
}
