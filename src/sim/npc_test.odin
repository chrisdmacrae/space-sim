package sim

import "core:testing"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"

// Traders in a generated system complete trades within a few game days.
@(test)
npc_traders_complete_trades :: proc(t: ^testing.T) {
	sys := gen.generate(5)
	defer gen.destroy(&sys)
	e: econ.Economy
	defer econ.destroy(&e)
	econ.build(&e, &sys)
	f: Fleet
	defer fleet_destroy(&f)
	fleet_spawn(&f, &sys, &e, 0)
	testing.expect(t, len(f.npcs) >= 5, "fleet spawned")
	tt := 0.0
	dt := 120.0
	for tt < 6 * core.SECONDS_PER_DAY {
		gen.update(&sys, tt + dt)
		fleet_update(&f, &sys, &e, tt, dt)
		econ.update(&e, tt + dt)
		tt += dt
	}
	trades := 0
	flew := 0
	for n in f.npcs {
		trades += n.trades
		if n.ship.transitions > 0 || n.trades > 0 do flew += 1
		testing.expectf(t, n.ship.mode != .Wrecked, "%s wrecked", n.name)
	}
	testing.expectf(t, trades >= 2, "trades completed: %v", trades)
	testing.expectf(t, flew >= 2, "traders that moved: %v", flew)
}
