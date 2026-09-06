package econ

// Micro economy (docs/DESIGN.md §6.1–6.2): a market per station and per
// outpost with stock, targets, production and consumption, and a price that
// falls as stock rises. Ticks once per game hour.

import "core:fmt"
import "core:math"
import core "sim:core"
import gen "sim:gen"

Commodity :: enum u8 {
	Ore,
	Water,
	Volatiles,
	Hydrogen,
	Biomass,
	Rare_Metals,
	Metals,
	Propellant,
	Oxygen,
	Food,
	Plastics,
	Machinery,
	Electronics,
	Medicine,
	Luxuries,
}

NAMES := [Commodity]string {
	.Ore = "ore", .Water = "water", .Volatiles = "volatiles", .Hydrogen = "hydrogen", .Biomass = "biomass",
	.Rare_Metals = "rare metals", .Metals = "metals", .Propellant = "propellant", .Oxygen = "oxygen",
	.Food = "food", .Plastics = "plastics", .Machinery = "machinery", .Electronics = "electronics",
	.Medicine = "medicine", .Luxuries = "luxuries",
}

// Credits per unit at a balanced market.
BASE_PRICE := [Commodity]f64 {
	.Ore = 8, .Water = 5, .Volatiles = 9, .Hydrogen = 6, .Biomass = 7,
	.Rare_Metals = 60, .Metals = 20, .Propellant = 12, .Oxygen = 10,
	.Food = 14, .Plastics = 18, .Machinery = 55, .Electronics = 70,
	.Medicine = 80, .Luxuries = 90,
}

Rates :: [Commodity]f64

Host_Kind :: enum u8 {
	Station,
	Outpost,
}

Market :: struct {
	name:      string,
	station:   int,             // index into sys.stations, or -1 for a colony
	body:      gen.Body_Handle, // the colony's body, or NONE for a station
	stock:     Rates,
	target:    Rates,
	produce:   Rates, // units per game day
	consume:   Rates, // units per game day
	price_mod: Rates, // local modifier around 1
	size:      f64,
	is_yard:   bool,
	ships:     [Class_Id]int, // hulls in stock (yards only)
	progress:  [Class_Id]f64, // build progress 0..1 (yards only)
}

Economy :: struct {
	markets:  [dynamic]Market,
	boards:   [dynamic]Board, // job boards, one per market (jobs.odin)
	last_tick: f64, // game time of the last hourly tick
	ticks:    int,
}

TICK :: core.SECONDS_PER_HOUR

destroy :: proc(e: ^Economy) {
	delete(e.markets)
	boards_destroy(e)
}

// Price the market quotes for one unit right now.
price :: proc(m: ^Market, c: Commodity) -> f64 {
	k := f64(core.tuning.price_curve_k)
	x := m.target[c] > 0 ? m.stock[c] / m.target[c] : 1
	f := clamp(math.pow(k, 1 - x), 1 / k, k)
	return BASE_PRICE[c] * m.price_mod[c] * f
}

buy_price :: proc(m: ^Market, c: Commodity) -> f64 {
	return price(m, c) * 1.05 // what you pay the market
}

sell_price :: proc(m: ^Market, c: Commodity) -> f64 {
	return price(m, c) * 0.95 // what the market pays you
}

// Build markets for every station in the system.
build :: proc(e: ^Economy, sys: ^gen.System) {
	clear(&e.markets)
	for &st, i in sys.stations {
		r := core.rng_make(core.sub_seed(sys.seed, "market", i))
		m := Market{name = st.name, station = i, body = gen.NONE, size = core.rng_log_range(&r, 0.6, 1.8)}
		for c in Commodity do m.price_mod[c] = core.rng_range(&r, 0.85, 1.15)
		station_profile(&m, st.kind)
		if st.kind == .Shipyard {
			m.is_yard = true
			for c in Class_Id do m.ships[c] = core.rng_int(&r, 0, c == .Courier ? 3 : 2)
		}
		finish_market(&m, &r)
		append(&e.markets, m)
	}
	// Colonies: a market on the surface of every settled body.
	for &b, i in sys.bodies {
		if !b.colony do continue
		r := core.rng_make(core.sub_seed(sys.seed, "colony", i))
		m := Market{name = fmt.aprintf("%s Colony", b.name), station = -1, body = gen.Body_Handle(i), size = core.rng_log_range(&r, 0.8, 2.2)}
		for c in Commodity do m.price_mod[c] = core.rng_range(&r, 0.85, 1.15)
		colony_profile(&m, b.kind)
		finish_market(&m, &r)
		append(&e.markets, m)
	}
	e.last_tick = 0
}

@(private = "file")
finish_market :: proc(m: ^Market, r: ^core.Rng) {
	for c in Commodity {
		m.produce[c] *= m.size
		m.consume[c] *= m.size
		// Targets: a couple of weeks of throughput; a modest float for everything else.
		m.target[c] = max(m.produce[c], m.consume[c]) * 14
		if m.target[c] == 0 do m.target[c] = 8 * m.size
		m.stock[c] = m.target[c] * core.rng_range(r, 0.5, 1.4)
	}
}

is_colony :: proc(m: ^Market) -> bool { return m.station < 0 }

// World position of a market: its station, or its body.
market_pos :: proc(sys: ^gen.System, m: ^Market) -> [2]f64 {
	if m.station >= 0 do return sys.station_pos[m.station]
	return sys.pos[m.body]
}

// The frame a market sits in and its orbit radius there: a station's own
// orbit, or the low parking orbit over a colony's body.
market_parent :: proc(sys: ^gen.System, m: ^Market) -> (parent: gen.Body_Handle, r: f64) {
	if m.station >= 0 {
		st := sys.stations[m.station]
		return st.parent, st.orbit.a
	}
	return m.body, gen.low_orbit(sys.bodies[m.body])
}

// The body a market belongs to (the station's parent, or the colony's body).
market_body :: proc(sys: ^gen.System, m: ^Market) -> gen.Body_Handle {
	if m.station >= 0 do return sys.stations[m.station].parent
	return m.body
}

@(private = "file")
station_profile :: proc(m: ^Market, kind: gen.Station_Kind) {
	switch kind {
	case .Hub:
		m.consume[.Food] = 6; m.consume[.Luxuries] = 2; m.consume[.Medicine] = 1.5
		m.produce[.Electronics] = 2
		m.consume[.Metals] = 2; m.consume[.Plastics] = 2
	case .Shipyard:
		m.consume[.Metals] = 6; m.consume[.Electronics] = 2; m.consume[.Machinery] = 2; m.consume[.Plastics] = 3
		m.produce[.Machinery] = 1.5
	case .Refinery:
		m.consume[.Ore] = 10; m.consume[.Volatiles] = 4; m.consume[.Rare_Metals] = 1
		m.produce[.Metals] = 8; m.produce[.Plastics] = 3; m.produce[.Machinery] = 1
		m.consume[.Food] = 2
	case .Depot:
		m.consume[.Hydrogen] = 8; m.consume[.Water] = 4
		m.produce[.Propellant] = 10; m.produce[.Oxygen] = 3
		m.consume[.Food] = 1
	case .Habitat:
		m.consume[.Food] = 8; m.consume[.Oxygen] = 4; m.consume[.Water] = 4; m.consume[.Medicine] = 2; m.consume[.Luxuries] = 3
		m.produce[.Medicine] = 2; m.produce[.Luxuries] = 1.5; m.produce[.Electronics] = 1
	}
}

@(private = "file")
colony_profile :: proc(m: ^Market, kind: gen.Body_Kind) {
	switch kind {
	case .Molten:
		m.produce[.Rare_Metals] = 3
		m.consume[.Machinery] = 1; m.consume[.Food] = 2; m.consume[.Water] = 2
	case .Rock:
		m.produce[.Ore] = 12
		m.consume[.Food] = 3; m.consume[.Water] = 2; m.consume[.Machinery] = 1
	case .Atmospheric:
		m.produce[.Food] = 14; m.produce[.Biomass] = 6; m.produce[.Luxuries] = 1
		m.consume[.Metals] = 3; m.consume[.Propellant] = 2; m.consume[.Machinery] = 1.5; m.consume[.Electronics] = 1
	case .Gas:
		m.produce[.Hydrogen] = 14
		m.consume[.Machinery] = 1; m.consume[.Food] = 2
	case .Ice:
		m.produce[.Water] = 10; m.produce[.Volatiles] = 6; m.produce[.Oxygen] = 4
		m.consume[.Food] = 2; m.consume[.Machinery] = 1
	case .Star:
	}
}

// Advance to game time t, one hourly tick at a time (bounded).
update :: proc(e: ^Economy, t: f64) {
	steps := 0
	for e.last_tick + TICK <= t && steps < 24 * 60 {
		tick(e, TICK / core.SECONDS_PER_DAY)
		e.last_tick += TICK
		steps += 1
	}
	if e.last_tick + TICK <= t do e.last_tick = t // fell too far behind: skip (macro catch-up lives in phase 11)
}

// One step of dt days. A market runs at the efficiency of its scarcest input.
tick :: proc(e: ^Economy, dt: f64) {
	e.ticks += 1
	for &m in e.markets {
		eff := 1.0
		for c in Commodity {
			if m.consume[c] <= 0 do continue
			need := m.consume[c] * dt
			eff = min(eff, clamp(m.stock[c] / max(need, 1e-9), 0, 1))
		}
		for c in Commodity {
			m.stock[c] += (m.produce[c] - m.consume[c]) * eff * dt
			// Overstock leaks (spoilage, dumping) so runaway producers stay bounded.
			if m.stock[c] > 3 * m.target[c] do m.stock[c] -= (m.stock[c] - 3 * m.target[c]) * 0.1 * dt
			if m.stock[c] < 0 do m.stock[c] = 0
		}
		if m.is_yard do build_ships(&m, dt)
	}
}

// A yard works on every class below its stock cap, at the rate its scarcest
// input allows, consuming inputs as it goes.
@(private = "file")
build_ships :: proc(m: ^Market, dt: f64) {
	for c in Class_Id {
		if m.ships[c] >= YARD_MAX_STOCK do continue
		cost := CLASS_BUILD_COST[c]
		step := dt / BUILD_DAYS
		eff := 1.0
		for k in Commodity {
			if cost[k] <= 0 do continue
			need := cost[k] * step
			eff = min(eff, clamp(m.stock[k] / max(need, 1e-9), 0, 1))
		}
		if eff <= 0 do continue
		for k in Commodity do if cost[k] > 0 do m.stock[k] -= cost[k] * step * eff
		m.progress[c] += step * eff
		if m.progress[c] >= 1 {
			m.progress[c] = 0
			m.ships[c] += 1
		}
	}
}

// Trade helpers: return the units actually moved and the credits delta for the trader.
buy :: proc(m: ^Market, c: Commodity, units: f64, credits: f64) -> (moved: f64, cost: f64) {
	if units <= 0 do return 0, 0
	p := buy_price(m, c)
	can := min(units, m.stock[c], credits / p)
	if can <= 0 do return 0, 0
	m.stock[c] -= can
	return can, can * p
}

sell :: proc(m: ^Market, c: Commodity, units: f64) -> (moved: f64, revenue: f64) {
	if units <= 0 do return 0, 0
	p := sell_price(m, c)
	m.stock[c] += units
	return units, units * p
}

// System-level values (docs/DESIGN.md §6.5).
Summary :: struct {
	output, wealth, demand: f64,
}

summarize :: proc(e: ^Economy) -> (s: Summary) {
	n := 0.0
	for &m in e.markets {
		for c in Commodity {
			s.output += m.produce[c] * BASE_PRICE[c]
			s.wealth += m.stock[c] * price(&m, c)
			if m.consume[c] > 0 {
				s.demand += clamp(1 - m.stock[c] / max(m.target[c], 1e-9), 0, 1)
				n += 1
			}
		}
	}
	if n > 0 do s.demand /= n
	return
}
