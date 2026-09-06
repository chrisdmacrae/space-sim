package econ

import "core:testing"
import gen "sim:gen"

@(test)
prices_fall_with_stock_and_trades_move_them :: proc(t: ^testing.T) {
	sys := gen.generate(3)
	defer gen.destroy(&sys)
	e: Economy
	defer destroy(&e)
	build(&e, &sys)
	testing.expect(t, len(e.markets) >= len(sys.stations), "a market per station, plus colonies")
	for st, i in sys.stations do testing.expect(t, e.markets[i].station == i && e.markets[i].name == st.name, "station markets come first, in order")
	for &m in e.markets[len(sys.stations):] do testing.expect(t, is_colony(&m) && sys.bodies[m.body].colony, "the rest are colonies")
	if len(e.markets) == 0 do return
	m := &e.markets[0]
	c := Commodity.Food
	m.stock[c] = m.target[c]
	p_balanced := price(m, c)
	m.stock[c] = 0
	p_empty := price(m, c)
	m.stock[c] = m.target[c] * 3
	p_full := price(m, c)
	testing.expectf(t, p_empty > p_balanced && p_balanced > p_full, "prices %v > %v > %v", p_empty, p_balanced, p_full)
	m.stock[c] = m.target[c]
	before := price(m, c)
	moved, cost := buy(m, c, 5, 1e9)
	testing.expect(t, moved == 5 && cost > 0, "bought five")
	testing.expect(t, price(m, c) > before, "buying raised the price")
}

@(test)
tick_stalls_without_inputs_and_stays_non_negative :: proc(t: ^testing.T) {
	sys := gen.generate(3)
	defer gen.destroy(&sys)
	e: Economy
	defer destroy(&e)
	build(&e, &sys)
	// Find a refinery-like market with consumption; starve it.
	for &m in e.markets {
		has_input := false
		for c in Commodity do if m.consume[c] > 0 do has_input = true
		if !has_input do continue
		for c in Commodity do if m.consume[c] > 0 do m.stock[c] = 0
		out_before: Rates = m.stock
		tick(&e, 1)
		for c in Commodity {
			testing.expect(t, m.stock[c] >= 0, "stock never negative")
			if m.produce[c] > 0 && m.consume[c] == 0 do testing.expectf(t, m.stock[c] <= out_before[c] + 1e-9, "%v produced without inputs", c)
		}
		break
	}
	update(&e, 10 * 86400)
	testing.expect(t, e.ticks >= 240, "hourly ticks over ten days")
}
