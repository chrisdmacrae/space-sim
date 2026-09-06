package sim

import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

@(private = "file")
planet_with_station :: proc() -> gen.System {
	sys: gen.System
	context.allocator = gen.init_empty(&sys, 4)
	append(&sys.bodies, gen.Body{name = "Star", parent = gen.NONE, kind = .Star, mu = 0.3, radius = 60, soi = 1e300})
	append(&sys.bodies, gen.Body{name = "Planet", parent = gen.STAR, kind = .Rock, mu = 0.002, radius = 3.5, orbit = orbit.circular(0.3, 600, 0, 0), soi = orbit.soi_radius(600, 0.002, 0.3)})
	append(&sys.stations, gen.Station{name = "Hub", kind = .Hub, parent = gen.Body_Handle(1), orbit = orbit.circular(0.002, 20, 2.0, 0)})
	gen.finish(&sys)
	return sys
}

@(test)
dock_and_undock_ride_the_station :: proc(t: ^testing.T) {
	sys := planet_with_station()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	dock(&sys, &s, 0, 0)
	testing.expect(t, s.mode == .Docked, "docked")
	update(&sys, &s, 0, 5000)
	gen.update(&sys, 5000)
	pos, _, _ := state(&sys, &s, 5000)
	testing.expectf(t, orbit.length(pos - sys.station_pos[0]) < 1e-6, "docked ship follows the station: off by %v", orbit.length(pos - sys.station_pos[0]))
	undock(&sys, &s, 5000)
	testing.expect(t, s.mode == .On_Rails, "back on rails")
	testing.expectf(t, abs(orbit.length(s.pos) - 20.5) < 0.01, "undocked just outside the station orbit: r=%v", orbit.length(s.pos))
	idx, ok := dockable_station(&sys, &s)
	testing.expect(t, ok && idx == 0, "still within docking range right after undocking")
}

@(test)
autopilot_rendezvous_docks_at_station :: proc(t: ^testing.T) {
	sys := planet_with_station()
	defer gen.destroy(&sys)
	s := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.15, 0)
	defer destroy(&s)
	dest := Destination{kind = .Station, index = 0}
	geo, ok, reason := geometry(&sys, &s, dest)
	testing.expectf(t, ok, "geometry: %s", reason)
	if !ok do return
	res := search(&sys, &s, geo, 0)
	testing.expect(t, res.ok, "search ok")
	ap: Autopilot
	autopilot_start(&sys, &s, &ap, geo, dest, .Fuel, res.picks[.Fuel], 0)
	tt := 0.0
	for tt < 400000 && ap.active {
		dt := s.mode == .Thrusting || s.autoburn.active && tt > s.autoburn.start - 10 ? 0.25 : 30.0
		update(&sys, &s, tt, dt)
		tt += dt
		gen.update(&sys, tt)
		autopilot_update(&sys, &s, &ap, tt)
	}
	testing.expectf(t, ap.stage == .Done && s.mode == .Docked, "ended %v (%s), mode %v", ap.stage, ap.status, s.mode)
}
