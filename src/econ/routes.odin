package econ

// Trade routes are derived, not authored (docs/DESIGN.md §6.4): every
// (market, market, commodity) triple is scored by profit per unit of time,
// using a Hohmann-style transfer estimate between the hosts.

import "core:math"
import "core:slice"
import core "sim:core"
import gen "sim:gen"
import orbit "sim:orbit"

Route :: struct {
	from, to:    int, // market indices
	commodity:   Commodity,
	unit_profit: f64, // sell at `to` minus buy at `from`, per unit, now
	transfer_t:  f64, // seconds, estimate
	transfer_dv: f64, // estimate
	rate:        f64, // credits per game day for a full hold
}

// Rough transfer time and Δv between two stations from their host orbits.
transfer_estimate :: proc(sys: ^gen.System, ma, mb: ^Market) -> (t: f64, dv: f64) {
	pa, oa := market_parent(sys, ma)
	pb, ob := market_parent(sys, mb)
	// Radii about the common frame.
	ra, rb, mu: f64
	climb := 0.0
	if pa == pb {
		ra, rb, mu = oa, ob, sys.bodies[pa].mu
	} else {
		host :: proc(sys: ^gen.System, parent: gen.Body_Handle, orbit_r: f64) -> (r: f64, extra_t: f64, extra_dv: f64) {
			if parent == gen.STAR do return orbit_r, 0, 0
			b := sys.bodies[parent]
			// Climb out of the sphere and the escape burn from a low orbit.
			esc := math.sqrt(2 * b.mu / orbit_r) - math.sqrt(b.mu / orbit_r)
			return b.orbit.a, b.soi / max(math.sqrt(b.mu / orbit_r) * 0.5, 1e-6), esc
		}
		ta, tb: f64
		da, db: f64
		ra, ta, da = host(sys, pa, oa)
		rb, tb, db = host(sys, pb, ob)
		mu = sys.bodies[0].mu
		climb = ta + tb
		dv += da + db
	}
	ah := (ra + rb) * 0.5
	t = math.PI * math.sqrt(ah * ah * ah / mu) + climb
	v1 := math.sqrt(mu / ra)
	v2 := math.sqrt(mu / rb)
	vt1 := math.sqrt(mu * (2 / ra - 1 / ah))
	vt2 := math.sqrt(mu * (2 / rb - 1 / ah))
	dv += abs(vt1 - v1) + abs(v2 - vt2)
	// A synodic wait, on average half a period of the slower body.
	t += 0.25 * 2 * math.PI * math.sqrt(max(ra, rb) * max(ra, rb) * max(ra, rb) / mu)
	return
}

// Top routes by rate for a hold of `capacity` units. Allocates with the
// given allocator.
route_table :: proc(e: ^Economy, sys: ^gen.System, capacity: f64, top: int, allocator := context.allocator) -> []Route {
	routes := make([dynamic]Route, allocator)
	dwell := 4 * core.SECONDS_PER_HOUR
	for &a, i in e.markets {
		for &b, j in e.markets {
			if i == j do continue
			t, dv := transfer_estimate(sys, &a, &b)
			for c in Commodity {
				if a.stock[c] < capacity * 0.5 do continue // nothing worth loading
				profit := sell_price(&b, c) - buy_price(&a, c)
				if profit <= 0 do continue
				// Selling a full hold moves the price; charge half the swing.
				after := b.stock[c] + capacity
				k := f64(core.tuning.price_curve_k)
				p_after := BASE_PRICE[c] * b.price_mod[c] * clamp(math.pow(k, 1 - after / max(b.target[c], 1e-9)), 1 / k, k) * 0.95
				profit = (sell_price(&b, c) + p_after) * 0.5 - buy_price(&a, c)
				if profit <= 0 do continue
				days := (t + dwell) / core.SECONDS_PER_DAY
				fuel_cost := dv * 400 // rough propellant valuation
				rate := (profit * capacity - fuel_cost) / max(days, 0.05)
				if rate <= 0 do continue
				append(&routes, Route{from = i, to = j, commodity = c, unit_profit = profit, transfer_t = t, transfer_dv = dv, rate = rate})
			}
		}
	}
	slice.sort_by(routes[:], proc(x, y: Route) -> bool { return x.rate > y.rate })
	if len(routes) > top do resize(&routes, top)
	return routes[:]
}
