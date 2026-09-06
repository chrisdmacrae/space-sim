package sim

import "core:testing"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"

// Coarse frames (like 100,000x warp) for a month: traders must keep trading
// and must not pile up wrecks.
STRESS :: #config(STRESS, false)

@(test)
npc_fleet_survives_coarse_frames :: proc(t: ^testing.T) {
	when !STRESS do return // opt in: -define:STRESS=true (minutes)
	for seed in ([?]u64{1, 5, 9}) {
		sys := gen.generate(seed)
		defer gen.destroy(&sys)
		e: econ.Economy
		defer econ.destroy(&e)
		econ.build(&e, &sys)
		f: Fleet
		defer fleet_destroy(&f)
		fleet_spawn(&f, &sys, &e, 0)
		tt := 0.0
		dt := 800.0
		for tt < 30 * core.SECONDS_PER_DAY {
			gen.update(&sys, tt + dt)
			fleet_update(&f, &sys, &e, tt, dt)
			econ.update(&e, tt + dt)
			tt += dt
		}
		trades := 0
		wrecked := 0
		for n in f.npcs {
			trades += n.trades
			if n.ship.mode == .Wrecked do wrecked += 1
		}
		testing.expectf(t, wrecked == 0, "seed %v: %v wrecked traders", seed, wrecked)
		testing.expectf(t, trades >= len(f.npcs), "seed %v: only %v trades for %v traders in 30 days", seed, trades, len(f.npcs))
	}
}
