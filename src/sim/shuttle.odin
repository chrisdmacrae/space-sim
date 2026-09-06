package sim

// Trading with a colony: nothing docks, a shuttle flies goods down and up
// a few units at a time. Orders queue up; the shuttle works through them
// trip by trip, and only while the ship stays in shuttle range of the body.

import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"
import orbit "sim:orbit"

SHUTTLE_CAP          :: 10.0  // units per trip, each way
SHUTTLE_SURFACE_TIME :: 900.0 // seconds on the ground per trip
SHUTTLE_BASE_LEG     :: 900.0 // seconds per leg before the altitude term
SHUTTLE_LEG_PER_UNIT :: 180.0 // seconds per world unit of altitude, each way

Shuttle_Phase :: enum u8 {
	Idle,
	Down,
	Surface,
	Up,
	Waiting, // back at the ship with goods that do not fit the hold
}

Shuttle :: struct {
	market:   int,            // colony market, -1 when not set up
	body:     gen.Body_Handle,
	orders:   Cargo,          // +units to buy, -units to sell, per commodity
	carrying: Cargo,          // aboard the shuttle right now
	phase:    Shuttle_Phase,
	elapsed:  f64,            // seconds into the phase, counted only in range
	duration: f64,
	trips:    int,
	spent, earned: f64,       // running totals for the panel
}

shuttle_reset :: proc(sh: ^Shuttle, market: int, body: gen.Body_Handle) {
	sh^ = Shuttle{market = market, body = body}
}

// Add to the queue: positive buys, negative sells. A buy cancels a pending
// sell of the same commodity first, and vice versa.
shuttle_order :: proc(sh: ^Shuttle, c: econ.Commodity, units: f64) {
	sh.orders[int(c)] += units
}

shuttle_cancel :: proc(sh: ^Shuttle) {
	sh.orders = {}
}

shuttle_pending :: proc(sh: ^Shuttle) -> (buys, sells: f64) {
	for u in sh.orders {
		if u > 0 do buys += u
		else do sells -= u
	}
	return
}

shuttle_busy :: proc(sh: ^Shuttle) -> bool {
	if sh.phase != .Idle do return true
	b, s := shuttle_pending(sh)
	return b > 0 || s > 0
}

// One leg's flight time from the ship's current altitude.
shuttle_leg_time :: proc(sys: ^gen.System, s: ^Ship) -> f64 {
	alt := max(orbit.length(s.pos) - sys.bodies[s.primary].radius, 0)
	return SHUTTLE_BASE_LEG + alt * SHUTTLE_LEG_PER_UNIT
}

// Fraction of the way down (0 at the ship, 1 on the surface), for drawing.
shuttle_progress :: proc(sh: ^Shuttle) -> (f64, bool) {
	switch sh.phase {
	case .Down:    return clamp(sh.elapsed / max(sh.duration, 1), 0, 1), true
	case .Surface: return 1, true
	case .Up:      return 1 - clamp(sh.elapsed / max(sh.duration, 1), 0, 1), true
	case .Idle, .Waiting:
	}
	return 0, false
}

@(private = "file")
cargo_total :: proc(c: Cargo) -> (n: f64) {
	for u in c do n += u
	return
}

// Advance the shuttle. Time only passes while the ship is in range; away
// from the body the shuttle waits where it is.
// `edge` is the comms officer's: a fraction off what the colony charges and
// onto what it pays (crew, docs/DESIGN.md §5.9).
shuttle_step :: proc(sys: ^gen.System, e: ^econ.Economy, s: ^Ship, sh: ^Shuttle, credits: ^f64, dt: f64, edge: f64 = 0) {
	if sh.market < 0 || sh.market >= len(e.markets) do return
	if !at_colony(sys, s, sh.body) do return
	m := &e.markets[sh.market]
	switch sh.phase {
	case .Idle:
		// Load what is to be sold, up to the cap, and go if there is anything to do.
		room := SHUTTLE_CAP
		for c in econ.Commodity {
			i := int(c)
			if sh.orders[i] >= 0 do continue
			take := min(-sh.orders[i], s.cargo[i], room)
			if take <= 0 {
				sh.orders[i] = 0 // nothing aboard to sell
				continue
			}
			s.cargo[i] -= take
			sh.carrying[i] += take
			sh.orders[i] += take
			room -= take
		}
		buys, _ := shuttle_pending(sh)
		if cargo_total(sh.carrying) <= 0 && buys <= 0 do return
		sh.phase = .Down
		sh.elapsed = 0
		sh.duration = shuttle_leg_time(sys, s)
	case .Down:
		sh.elapsed += dt
		if sh.elapsed < sh.duration do return
		// On the ground: sell the load, then buy what was ordered.
		for c in econ.Commodity {
			i := int(c)
			if sh.carrying[i] <= 0 do continue
			_, rev := econ.sell(m, c, sh.carrying[i])
			rev *= 1 + edge
			credits^ += rev
			sh.earned += rev
			sh.carrying[i] = 0
		}
		room := SHUTTLE_CAP
		for c in econ.Commodity {
			i := int(c)
			if sh.orders[i] <= 0 || room <= 0 do continue
			want := min(sh.orders[i], room)
			moved, cost := econ.buy(m, c, want, credits^ / (1 - edge))
			cost *= 1 - edge
			if moved <= 0 {
				sh.orders[i] = 0 // out of stock or out of credits: drop it
				continue
			}
			credits^ -= cost
			sh.spent += cost
			sh.carrying[i] += moved
			sh.orders[i] -= moved
			room -= moved
		}
		sh.phase = .Surface
		sh.elapsed = 0
		sh.duration = SHUTTLE_SURFACE_TIME
	case .Surface:
		sh.elapsed += dt
		if sh.elapsed < sh.duration do return
		sh.phase = .Up
		sh.elapsed = 0
		sh.duration = shuttle_leg_time(sys, s)
	case .Up, .Waiting:
		if sh.phase == .Up {
			sh.elapsed += dt
			if sh.elapsed < sh.duration do return
		}
		// Back at the ship: unload what fits.
		for c in econ.Commodity {
			i := int(c)
			if sh.carrying[i] <= 0 do continue
			fit := min(sh.carrying[i], cargo_free(s))
			s.cargo[i] += fit
			sh.carrying[i] -= fit
		}
		if cargo_total(sh.carrying) > 0.001 {
			sh.phase = .Waiting
			return
		}
		sh.trips += 1
		sh.phase = .Idle
		sh.elapsed = 0
	}
}

// A short status line for the panel.
shuttle_status :: proc(sh: ^Shuttle) -> string {
	buys, sells := shuttle_pending(sh)
	switch sh.phase {
	case .Idle:    return buys + sells > 0 ? "loading" : (sh.trips > 0 ? "done" : "ready")
	case .Down:    return "descending"
	case .Surface: return "on the ground"
	case .Up:      return "climbing back"
	case .Waiting: return "waiting for hold space"
	}
	return ""
}

_ :: core
