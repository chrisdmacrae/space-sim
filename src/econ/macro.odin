package econ

// Macro economy (docs/DESIGN.md §6.3, §6.6): every system's markets keep
// ticking while the player is elsewhere, with NPC traffic replaced by route
// flows and slow trade along galaxy edges. Unobserved systems advance in
// large batched steps.

import "core:math"
import core "sim:core"
import gen "sim:gen"

FLEET_SIZE     :: 8.0   // abstract traders per system, matching fleet_spawn
FLEET_CAPACITY :: 40.0  // their mid-sized hold
INTER_RATE     :: 0.02  // units/day per credit of price gap per light-year, per edge

Flow :: struct {
	route: Route,
	ships: f64, // share of the abstract fleet
}

System_Econ :: struct {
	built:      bool,
	sys:        gen.System,
	econ:       Economy,
	flows:      [dynamic]Flow,
	flows_at:   f64,
	last_t:     f64, // game time the macro has advanced to
}

Galaxy_Econ :: struct {
	systems: [dynamic]System_Econ,
	galaxy:  ^gen.Galaxy,
}

galaxy_econ_init :: proc(ge: ^Galaxy_Econ, galaxy: ^gen.Galaxy, t: f64) {
	ge.galaxy = galaxy
	resize(&ge.systems, len(galaxy.systems))
	for &se in ge.systems do se.last_t = t
}

galaxy_econ_destroy :: proc(ge: ^Galaxy_Econ) {
	for &se in ge.systems {
		if !se.built do continue
		destroy(&se.econ)
		delete(se.flows)
		gen.destroy(&se.sys)
	}
	delete(ge.systems)
}

// Generate a system's markets on first touch.
ensure :: proc(ge: ^Galaxy_Econ, i: int, t: f64) -> ^System_Econ {
	se := &ge.systems[i]
	if !se.built {
		se.sys = gen.generate(ge.galaxy.systems[i].seed)
		build(&se.econ, &se.sys)
		se.econ.last_tick = t
		se.last_t = t
		se.built = true
	}
	return se
}

// Advance one system's macro state to time t in bounded steps. Systems far
// behind take 30-day steps (docs/DESIGN.md §6.6).
macro_advance :: proc(ge: ^Galaxy_Econ, i: int, t: f64) {
	se := ensure(ge, i, t)
	for se.last_t < t {
		gap := t - se.last_t
		step := gap > 60 * core.SECONDS_PER_DAY ? 30 * core.SECONDS_PER_DAY : min(gap, core.SECONDS_PER_DAY)
		macro_step(ge, se, step / core.SECONDS_PER_DAY, se.last_t + step)
		se.last_t += step
	}
	se.econ.last_tick = t
}

@(private = "file")
macro_step :: proc(ge: ^Galaxy_Econ, se: ^System_Econ, dt_days: f64, t: f64) {
	tick(&se.econ, dt_days)
	if se.flows == nil || t - se.flows_at > 7 * core.SECONDS_PER_DAY do rebuild_flows(se, t)
	for fl in se.flows {
		if fl.ships <= 0 do continue
		round_trip := 2 * (fl.route.transfer_t + 4 * core.SECONDS_PER_HOUR) / core.SECONDS_PER_DAY
		flow := FLEET_CAPACITY * fl.ships / max(round_trip, 0.05) * dt_days
		a := &se.econ.markets[fl.route.from]
		b := &se.econ.markets[fl.route.to]
		moved := min(flow, a.stock[fl.route.commodity])
		a.stock[fl.route.commodity] -= moved
		b.stock[fl.route.commodity] += moved
	}
}

@(private = "file")
rebuild_flows :: proc(se: ^System_Econ, t: f64) {
	clear(&se.flows)
	routes := route_table(&se.econ, &se.sys, FLEET_CAPACITY, 12, context.temp_allocator)
	total := 0.0
	for r in routes do total += r.rate
	for r in routes {
		share := total > 0 ? r.rate / total : 0
		append(&se.flows, Flow{route = r, ships = FLEET_SIZE * share})
	}
	se.flows_at = t
}

// Slow trade along an edge: goods drift from where they are cheap to where
// they are dear. Both systems must be built.
@(private = "file")
inter_step :: proc(ge: ^Galaxy_Econ, e: gen.Edge, dt_days: f64) {
	sa := &ge.systems[e.a]
	sb := &ge.systems[e.b]
	if !sa.built || !sb.built do return
	for c in Commodity {
		pa, ia := cheapest(&sa.econ, c)
		pb, ib := cheapest(&sb.econ, c)
		if ia < 0 || ib < 0 do continue
		gap := pb - pa
		src, dst := sa, sb
		si, di := ia, ib
		if gap < 0 {
			gap = -gap
			src, dst = sb, sa
			si, di = ib, ia
		}
		flow := INTER_RATE * gap / e.distance * dt_days
		// Deliver to the dearest market of the destination.
		_, dj := dearest(&dst.econ, c)
		if dj >= 0 do di = dj
		moved := min(flow, src.econ.markets[si].stock[c] * 0.5)
		src.econ.markets[si].stock[c] -= moved
		dst.econ.markets[di].stock[c] += moved
	}
}

@(private = "file")
cheapest :: proc(e: ^Economy, c: Commodity) -> (p: f64, idx: int) {
	idx = -1
	p = 1e300
	for &m, i in e.markets do if pr := price(&m, c); pr < p { p = pr; idx = i }
	return
}

@(private = "file")
dearest :: proc(e: ^Economy, c: Commodity) -> (p: f64, idx: int) {
	idx = -1
	p = -1
	for &m, i in e.markets do if pr := price(&m, c); pr > p { p = pr; idx = i }
	return
}

// Advance every built system and the edges between them to time t. The
// active system's markets are ticked by the micro loop; pass its index to
// skip it here.
galaxy_advance :: proc(ge: ^Galaxy_Econ, t: f64, active: int) {
	for i in 0 ..< len(ge.systems) {
		if i == active || !ge.systems[i].built do continue
		macro_advance(ge, i, t)
	}
	// Edge trade at a daily cadence, driven by the least-advanced built pair.
	for e in ge.galaxy.edges {
		sa := &ge.systems[e.a]
		sb := &ge.systems[e.b]
		if !sa.built || !sb.built do continue
		// Use the active side's clock when one of them is the active system.
		last := min(sa.last_t, sb.last_t)
		if t - last >= core.SECONDS_PER_DAY do inter_step(ge, e, (t - last) / core.SECONDS_PER_DAY)
	}
}

// Ensure and advance all neighbours of a system, so arriving somewhere
// finds a living economy that has been trading with its neighbours.
touch_neighbourhood :: proc(ge: ^Galaxy_Econ, i: int, t: f64) {
	ensure(ge, i, t)
	for j in gen.neighbours(ge.galaxy, i) do ensure(ge, j, t)
}

_ :: math
