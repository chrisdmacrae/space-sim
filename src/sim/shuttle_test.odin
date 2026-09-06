package sim

import "core:testing"
import econ "sim:econ"
import gen "sim:gen"

@(test)
shuttle_ferries_goods_to_and_from_a_colony :: proc(t: ^testing.T) {
	// Find a system with a colony.
	seed: u64
	for s in 1 ..= 60 {
		sys := gen.generate(u64(s))
		has := false
		for b in sys.bodies do if b.colony do has = true
		gen.destroy(&sys)
		if has { seed = u64(s); break }
	}
	testing.expect(t, seed != 0, "some system has a colony")
	if seed == 0 do return
	sys := gen.generate(seed)
	defer gen.destroy(&sys)
	e: econ.Economy
	defer econ.destroy(&e)
	econ.build(&e, &sys)
	market := -1
	for &m, i in e.markets do if econ.is_colony(&m) { market = i; break }
	testing.expect(t, market >= 0, "the colony has a market")
	if market < 0 do return
	m := &e.markets[market]
	body := m.body
	s := spawn_in_orbit(&sys, body, 0.15, 0)
	defer destroy(&s)
	testing.expect(t, at_colony(&sys, &s, body), "a low orbit is in shuttle range")
	credits := 5000.0
	sh: Shuttle
	shuttle_reset(&sh, market, body)
	// Sell 12 ore we carry (two trips' worth is capped per trip), buy 4 food.
	s.cargo[int(econ.Commodity.Ore)] = 12
	shuttle_order(&sh, .Ore, -12)
	shuttle_order(&sh, .Food, 4)
	stock_ore := m.stock[.Ore]
	tt := 0.0
	for _ in 0 ..< 4000 {
		shuttle_step(&sys, &e, &s, &sh, &credits, 60)
		tt += 60
		if !shuttle_busy(&sh) do break
	}
	testing.expectf(t, !shuttle_busy(&sh), "orders complete (phase %v)", sh.phase)
	testing.expectf(t, sh.trips == 2, "two trips for 12 units at 10 per trip (%d)", sh.trips)
	testing.expectf(t, s.cargo[int(econ.Commodity.Ore)] == 0 && m.stock[.Ore] > stock_ore, "ore delivered to the colony")
	testing.expectf(t, s.cargo[int(econ.Commodity.Food)] == 4, "food came back up (%v)", s.cargo[int(econ.Commodity.Food)])
	testing.expect(t, credits != 5000 && sh.earned > 0 && sh.spent > 0, "money moved both ways")
	// Out of range the shuttle waits.
	shuttle_order(&sh, .Food, 2)
	far := s
	far.pos *= 50
	before := sh.phase
	shuttle_step(&sys, &e, &far, &sh, &credits, 3600)
	testing.expect(t, sh.phase == before, "no progress out of range")
}

@(test)
routes_reach_colonies :: proc(t: ^testing.T) {
	seed: u64
	for s in 1 ..= 60 {
		sys := gen.generate(u64(s))
		has := false
		for b in sys.bodies do if b.colony do has = true
		gen.destroy(&sys)
		if has { seed = u64(s); break }
	}
	if seed == 0 do return
	sys := gen.generate(seed)
	defer gen.destroy(&sys)
	e: econ.Economy
	defer econ.destroy(&e)
	econ.build(&e, &sys)
	routes := econ.route_table(&e, &sys, 40, 200)
	defer delete(routes)
	touches := 0
	for r in routes do if econ.is_colony(&e.markets[r.from]) || econ.is_colony(&e.markets[r.to]) do touches += 1
	testing.expectf(t, touches > 0, "the route table trades with colonies (%d of %d)", touches, len(routes))
	for r in routes do testing.expect(t, market_dest(&e, r.to).kind != .None, "every route has a flyable destination")
}
