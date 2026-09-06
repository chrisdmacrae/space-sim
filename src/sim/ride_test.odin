package sim

import "core:testing"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"
import orbit "sim:orbit"

// Docked to a trader, the player must sit exactly where the trader is,
// frame after frame, through the game's own update order: player update,
// bodies, fleet update, then the ride.
@(test)
docked_player_tracks_the_trader :: proc(t: ^testing.T) {
	sys := gen.generate(5)
	defer gen.destroy(&sys)
	e: econ.Economy
	defer econ.destroy(&e)
	econ.build(&e, &sys)
	f: Fleet
	defer fleet_destroy(&f)
	fleet_spawn(&f, &sys, &e, 0)
	// Let the fleet get going so at least one trader is coasting between stations.
	tt := 0.0
	dt := 120.0
	host := -1
	for tt < 12 * core.SECONDS_PER_DAY && host < 0 {
		gen.update(&sys, tt + dt)
		fleet_update(&f, &sys, &e, tt, dt)
		tt += dt
		for &n, i in f.npcs do if n.ship.mode == .On_Rails { host = i; break }
	}
	testing.expect(t, host >= 0, "a coasting trader exists")
	if host < 0 do return
	me := spawn_in_orbit(&sys, f.npcs[host].ship.primary, 0.3, tt)
	defer destroy(&me)
	dock_ship(&me, &f.npcs[host].ship, host)
	npc_receive_visitor(&sys, &f.npcs[host], tt)
	worst := 0.0
	for _ in 0 ..< 2000 {
		update(&sys, &me, tt, dt)
		gen.update(&sys, tt + dt)
		fleet_update(&f, &sys, &e, tt, dt)
		tt += dt
		h := &f.npcs[host]
		testing.expect(t, h.visitor && h.ship.mode == .On_Rails && !h.ap.active, "the host holds and keeps no plan while visited")
		ride_along(&me, &h.ship)
		hp, _, _ := state(&sys, &h.ship, tt)
		mp, _, _ := state(&sys, &me, tt)
		worst = max(worst, orbit.length(hp - mp))
	}
	testing.expectf(t, worst < 1e-9, "player stays on the trader (worst gap %v)", worst)
	testing.expect(t, me.mode == .Docked && me.docked_ship, "still docked")
}
