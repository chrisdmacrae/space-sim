package econ

// What a nebula gives up to a scoop (docs/DESIGN.md §2.6, §6.1). The mix
// follows the kind, because the kind is a statement about where the gas came
// from: a molecular cloud is hydrogen and ices, an emission nebula is
// ionised hydrogen with the oxygen that makes it green, dust reflects
// because it is silicate grains, and a supernova shell is the only place in
// the sky that makes heavy metals by itself.

import gen "sim:gen"

// Units per skim cycle at full density, per commodity.
nebula_yield :: proc(k: gen.Nebula_Kind) -> (y: Rates) {
	switch k {
	case .Nursery:
		y[.Hydrogen] = 5.0
		y[.Volatiles] = 2.6
		y[.Water] = 1.8
	case .Emission:
		y[.Hydrogen] = 5.4
		y[.Oxygen] = 2.2
		y[.Volatiles] = 1.2
	case .Reflection:
		y[.Volatiles] = 2.8
		y[.Ore] = 2.2
		y[.Water] = 1.4
		y[.Hydrogen] = 1.6
	case .Supernova:
		y[.Hydrogen] = 2.4
		y[.Oxygen] = 2.0
		y[.Metals] = 1.5
		y[.Rare_Metals] = 0.55
	case .Planetary:
		y[.Hydrogen] = 4.4
		y[.Oxygen] = 2.4
		y[.Volatiles] = 1.8
		y[.Metals] = 0.6
	}
	return
}

// The one or two commodities worth naming in a summary line.
nebula_yield_names :: proc(k: gen.Nebula_Kind, n := 3) -> []Commodity {
	y := nebula_yield(k)
	out := make([dynamic]Commodity, 0, len(Commodity), context.temp_allocator)
	for _ in 0 ..< n {
		best := Commodity.Ore
		best_v := 0.0
		for c in Commodity {
			if y[c] <= best_v do continue
			seen := false
			for o in out do if o == c do seen = true
			if seen do continue
			best, best_v = c, y[c]
		}
		if best_v <= 0 do break
		append(&out, best)
	}
	return out[:]
}
