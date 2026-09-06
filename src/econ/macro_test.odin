package econ

import "core:math"
import "core:testing"
import core "sim:core"
import gen "sim:gen"

@(test)
macro_advances_systems_and_neighbours :: proc(t: ^testing.T) {
	g := gen.galaxy_generate(3)
	defer gen.galaxy_destroy(&g)
	ge: Galaxy_Econ
	defer galaxy_econ_destroy(&ge)
	galaxy_econ_init(&ge, &g, 0)
	touch_neighbourhood(&ge, 0, 0)
	built := 0
	for se in ge.systems do if se.built do built += 1
	testing.expect(t, built >= 2, "home and at least one neighbour built")
	// A year passes; nothing may go negative or non-finite, and the batched
	// path (30-day steps) must be taken.
	galaxy_advance(&ge, 365 * core.SECONDS_PER_DAY, -1)
	for se in ge.systems {
		if !se.built do continue
		testing.expect(t, se.last_t >= 365 * core.SECONDS_PER_DAY - 1, "advanced to now")
		for m in se.econ.markets {
			for c in Commodity {
				testing.expect(t, m.stock[c] >= 0 && !math.is_nan(m.stock[c]) && !math.is_inf(m.stock[c]), "stock sane")
			}
		}
		testing.expect(t, len(se.flows) > 0, "route flows exist")
	}
}
