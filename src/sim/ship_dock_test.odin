package sim

import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

@(test)
ships_dock_ride_and_undock :: proc(t: ^testing.T) {
	sys := gen.generate(3)
	defer gen.destroy(&sys)
	host := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.3, 0)
	defer destroy(&host)
	me := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.3, 0)
	defer destroy(&me)
	// Same orbit, a hair behind: within range and matched speed.
	me.pos += {0.5, 0}
	hosts := []Ship{host}
	idx, ok := dockable_ship(&sys, &me, hosts)
	testing.expect(t, ok && idx == 0, "the host is dockable")
	far := me
	far.pos += {50, 0}
	_, ok2 := dockable_ship(&sys, &far, hosts)
	testing.expect(t, !ok2, "too far to dock")
	dock_ship(&me, &host, 0)
	testing.expect(t, me.mode == .Docked && me.docked_ship && me.dock == 0, "docked to the ship")
	update(&sys, &host, 0, 3600)
	ride_along(&me, &host)
	testing.expect(t, me.pos == host.pos && me.vel == host.vel, "rides the host")
	update(&sys, &me, 0, 3600) // must not touch a station
	testing.expect(t, me.pos == host.pos, "update leaves a ship-docked ship alone")
	undock(&sys, &me, 3600)
	testing.expect(t, me.mode == .On_Rails && !me.docked_ship, "coasting again")
	testing.expect(t, orbit.length(me.pos - host.pos) > 0.1 && orbit.length(me.pos - host.pos) < 2, "released just outside the host")
	// A plan to a coasting ship is a plain rendezvous.
	other := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.5, 0)
	defer destroy(&other)
	dest := Destination{kind = .Npc, index = 0, orbit = other.orbit, primary = other.primary}
	geo, gok, reason := geometry(&sys, &me, dest)
	testing.expectf(t, gok, "geometry to a ship: %s", reason)
	if gok {
		testing.expect(t, geo.is_npc && geo.arr_body == gen.NONE, "rendezvous in the shared frame")
		p, _ := target_frame_state(&sys, geo, 1000)
		q, _ := orbit.state_at(other.orbit, 1000)
		testing.expect(t, p == q, "the target moves on its orbit")
	}
}

@(test)
a_visited_trader_waits_then_resumes :: proc(t: ^testing.T) {
	sys := gen.generate(3)
	defer gen.destroy(&sys)
	f: Fleet
	defer fleet_destroy(&f)
	n: Npc
	n.ship = spawn_in_orbit(&sys, gen.Body_Handle(1), 0.3, 0)
	n.ship.impulsive = true
	n.state = .Flying
	n.route = {from = 0, to = 1}
	npc_receive_visitor(&sys, &n, 0)
	testing.expect(t, n.visitor && !n.ap.active && len(n.ship.nodes) == 0, "plans dropped, holding")
	npc_visitor_left(&n, 100)
	testing.expect(t, !n.visitor && n.state == .Flying && n.ap.stage == .Failed && n.failures == 0, "resumes by replanning its route")
	destroy(&n.ship)
}

// Flying to a coasting ship ends in formation on its orbit: same period, a
// fraction of a unit behind, no relative speed.
@(test)
autopilot_to_a_ship_ends_in_formation :: proc(t: ^testing.T) {
	sys := gen.generate(3)
	defer gen.destroy(&sys)
	host := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.5, 0)
	defer destroy(&host)
	// The host on its own orbit, higher and ahead, so this is a real rendezvous.
	// Half the sphere is as far out as anything is placed (see place_stations).
	host.orbit = orbit.circular(sys.bodies[1].mu, sys.bodies[1].soi * 0.5, 2.0, 0, 1)
	host.pos, host.vel = orbit.state_at(host.orbit, 0)
	repredict(&sys, &host, 0)
	me := spawn_in_orbit(&sys, gen.Body_Handle(1), 0.25, 0)
	defer destroy(&me)
	dest := Destination{kind = .Npc, index = 0, orbit = host.orbit, primary = host.primary}
	geo, gok, reason := geometry(&sys, &me, dest)
	testing.expectf(t, gok, "geometry: %s", reason)
	if !gok do return
	res := search(&sys, &me, geo, 0)
	testing.expect(t, res.ok && res.picks[.Balanced].ok, "a transfer exists")
	if !res.ok do return
	ap: Autopilot
	autopilot_start(&sys, &me, &ap, geo, dest, .Balanced, res.picks[.Balanced], 0)
	tt := 0.0
	dt := 30.0
	limit := res.picks[.Balanced].t_arrive * 3 + 200000
	for ap.active && tt < limit {
		update(&sys, &host, tt, dt)
		update(&sys, &me, tt, dt)
		tt += dt
		gen.update(&sys, tt)
		autopilot_update(&sys, &me, &ap, tt)
	}
	testing.expectf(t, ap.stage == .Done, "arrived in formation (stage %v: %s)", ap.stage, ap.status)
	if ap.stage != .Done do return
	hp, hv := orbit.state_at(host.orbit, tt)
	testing.expectf(t, orbit.length(me.pos - hp) < 1.5, "a hair behind the host (%v)", orbit.length(me.pos - hp))
	testing.expectf(t, orbit.length(me.vel - hv) < DOCK_SPEED, "relative speed within docking tolerance (%v)", orbit.length(me.vel - hv))
	testing.expectf(t, abs(orbit.period(me.orbit) - orbit.period(host.orbit)) < 1, "same period")
	hosts := []Ship{host}
	_, ok := dockable_ship(&sys, &me, hosts)
	testing.expect(t, ok, "dockable straight away")
	// And they stay together: a day later the gap is unchanged.
	gap0 := orbit.length(me.pos - hp)
	for _ in 0 ..< 2880 {
		update(&sys, &host, tt, dt)
		update(&sys, &me, tt, dt)
		tt += dt
	}
	hp2, _ := orbit.state_at(host.orbit, tt)
	testing.expectf(t, abs(orbit.length(me.pos - hp2) - gap0) < 0.05, "formation holds (gap %v -> %v)", gap0, orbit.length(me.pos - hp2))
}
