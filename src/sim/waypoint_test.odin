package sim

import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

// A waypoint in the ship's own frame: the autopilot passes within reach of
// it at the planned time.
@(test)
autopilot_reaches_a_waypoint :: proc(t: ^testing.T) {
	sys: gen.System
	context.allocator = gen.init_empty(&sys, 8)
	append(&sys.bodies, gen.Body{name = "Star", parent = gen.NONE, kind = .Star, mu = 0.3, radius = 60, soi = 1e300})
	append(&sys.bodies, gen.Body{name = "Planet", parent = gen.STAR, kind = .Rock, mu = 0.002, radius = 3.5, orbit = orbit.circular(0.3, 600, 0, 0), soi = orbit.soi_radius(600, 0.002, 0.3)})
	gen.finish(&sys)
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	s.impulsive = true
	point := [2]f64{-30, 20} // relative to the planet, well inside its sphere
	dest := Destination{kind = .Point, index = 1, point = point}
	geo, ok, reason := geometry(&sys, &s, dest)
	testing.expectf(t, ok, "geometry: %s", reason)
	if !ok do return
	res := search(&sys, &s, geo, 0)
	testing.expect(t, res.ok && res.picks[.Fuel].ok, "a transfer exists")
	ap: Autopilot
	autopilot_start(&sys, &s, &ap, geo, dest, .Fuel, res.picks[.Fuel], 0)
	t_a := ap.cand.t_arrive
	tt := 0.0
	closest: f64 = 1e300
	for tt < t_a + 600 && ap.active {
		update(&sys, &s, tt, 20)
		tt += 20
		gen.update(&sys, tt)
		autopilot_update(&sys, &s, &ap, tt)
		if s.primary == gen.Body_Handle(1) do closest = min(closest, orbit.length(s.pos - point))
	}
	testing.expectf(t, ap.stage == .Done, "ended %v (%s)", ap.stage, ap.status)
	testing.expectf(t, closest < 3, "closest approach to the waypoint: %v", closest)
}
