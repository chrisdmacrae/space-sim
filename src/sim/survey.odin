package sim

// Survey ships (docs/DESIGN.md §2.6, §5.3). A surveyor is a trader that has
// swapped the route table for a cloud: it parks in the thick of a nebula,
// runs the same scoop the player does, and moves on to a new patch when the
// gas thins or it has sat there long enough. When the hold fills and the
// system has a market, it runs the haul in and comes back out.
//
// Because none of that reads the economy, a nebula site with no stations
// and no markets at all still has ships going about their business.

import "core:fmt"
import "core:math"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"

SURVEY_DWELL_LO :: 8.0  // game hours parked on one patch
SURVEY_DWELL_HI :: 30.0
SURVEY_THIN     :: 0.10 // below this density the patch is not worth the wait

survey_think :: proc(f: ^Fleet, n: ^Npc, sys: ^gen.System, e: ^econ.Economy, t: f64) {
	s := &n.ship
	if n.cloud < 0 || n.cloud >= len(sys.nebulae) {
		n.state = .Dwelling
		n.dwell_until = t + core.SECONDS_PER_DAY
		return
	}
	r := core.rng_make(n.seed ~ u64(t / core.SECONDS_PER_HOUR))
	switch n.state {
	case .Surveying:
		if !skim_active(&n.skim) {
			if ok, _ := skim_start(sys, s, &n.skim, t); !ok {
				// Drifted out of the gas, or nothing left to fill: move.
				n.dwell_until = t
			}
		}
		full := cargo_free(s) <= 0.001
		if t < n.dwell_until && !full && n.skim.density > SURVEY_THIN do return
		n.surveyed += n.skim.cycles
		skim_stop(&n.skim)
		if full && survey_sell_leg(f, n, sys, e, t) do return
		survey_move(f, n, sys, &r, t)
	case .Planning:
		// The worker has it; job_poll moves us on.
	case .Flying:
		if n.ap.active do return
		if n.selling {
			// Arrived at the market: sell the haul and head back out.
			if here, ok := npc_market(sys, e, s); ok {
				m := &e.markets[here]
				for c in econ.Commodity {
					if s.cargo[int(c)] <= 0 do continue
					_, rev := econ.sell(m, c, s.cargo[int(c)])
					n.credits += rev
					s.cargo[int(c)] = 0
					n.trades += 1
				}
				s.propellant = s.stats.propellant_cap
			}
			n.selling = false
			survey_move(f, n, sys, &r, t)
			return
		}
		survey_settle(n, &r, t)
	case .Dwelling:
		if t < n.dwell_until do return
		survey_move(f, n, sys, &r, t)
	case .Trading:
		n.state = .Surveying
	}
}

// Park here and start scooping.
@(private = "file")
survey_settle :: proc(n: ^Npc, r: ^core.Rng, t: f64) {
	n.state = .Surveying
	n.dwell_until = t + core.rng_range(r, SURVEY_DWELL_LO, SURVEY_DWELL_HI) * core.SECONDS_PER_HOUR
	n.failures = 0
}

// Pick a fresh patch of the cloud and fly to it. Failing that, sit still and
// try again later: a surveyor that cannot plan is a surveyor that waits.
@(private = "file")
survey_move :: proc(f: ^Fleet, n: ^Npc, sys: ^gen.System, r: ^core.Rng, t: f64) {
	s := &n.ship
	if s.mode != .On_Rails || !plan_budget(f) {
		n.state = .Dwelling
		n.dwell_until = t + core.SECONDS_PER_HOUR
		return
	}
	world := survey_target(sys, n.cloud, r)
	frame := gen.primary_at(sys, world)
	dest := Destination{kind = .Point, index = int(frame), point = world - sys.pos[frame]}
	if job_start(f, n, sys, dest, t) {
		n.selling = false
		n.state = .Planning
		return
	}
	n.failures += 1
	n.state = .Dwelling
	n.dwell_until = t + core.rng_range(r, 2, 6) * core.SECONDS_PER_HOUR
	// Repeatedly unable to move: settle for where we are rather than idle.
	if n.failures > 3 do survey_settle(n, r, t)
}

// Run the haul to the best market for what is aboard. False when the system
// has nowhere to sell, which is the usual case at a nebula site.
@(private = "file")
survey_sell_leg :: proc(f: ^Fleet, n: ^Npc, sys: ^gen.System, e: ^econ.Economy, t: f64) -> bool {
	if len(e.markets) == 0 || !plan_budget(f) do return false
	best, best_v := -1, 0.0
	for &m, i in e.markets {
		v := 0.0
		for c in econ.Commodity do v += n.ship.cargo[int(c)] * econ.sell_price(&m, c)
		if v > best_v {
			best_v = v
			best = i
		}
	}
	if best < 0 do return false
	if job_start(f, n, sys, market_dest(e, best), t) {
		n.selling = true
		n.state = .Planning
		return true
	}
	return false
}

// A patch worth moving to: thick, and not the one we are already sitting in.
@(private)
survey_target :: proc(sys: ^gen.System, ni: int, r: ^core.Rng) -> [2]f64 {
	neb := sys.nebulae[ni]
	best: [2]f64
	best_score := -1.0
	for _ in 0 ..< 20 {
		ang := core.rng_range(r, 0, 2 * math.PI)
		u := neb.hollow > 0 ? core.rng_range(r, neb.hollow / neb.radius, 1) : math.sqrt(core.rng_f64(r))
		p := neb.center + {math.cos(ang) * neb.radius * u, math.sin(ang) * neb.radius * u}
		score := gen.nebula_density_at(neb, p) * core.rng_range(r, 0.7, 1.3)
		if score > best_score {
			best_score = score
			best = p
		}
	}
	return sys.pos[0] + best
}

// A lost surveyor comes back in its cloud. Survey traffic is as abstract as
// trade traffic: the replacement carries the same name and the same job.
survey_respawn :: proc(n: ^Npc, sys: ^gen.System, t: f64) {
	if n.cloud < 0 || n.cloud >= len(sys.nebulae) {
		survey_hold(n, t)
		return
	}
	r := core.rng_make(n.seed ~ u64(t))
	class := n.ship.class
	name := n.ship.name
	destroy(&n.ship)
	n.ship = spawn_at_point(sys, survey_target(sys, n.cloud, &r), t, CLASSES[class].stats)
	n.ship.class = class
	n.ship.name = name
	n.ship.impulsive = true
	n.ship.dust_hardened = true
	n.surveyed += n.skim.cycles
	skim_stop(&n.skim)
	n.ap = {}
	n.failures = 0
	n.selling = false
	n.state = .Surveying
	n.dwell_until = t + core.rng_range(&r, SURVEY_DWELL_LO, SURVEY_DWELL_HI) * core.SECONDS_PER_HOUR
}

// Nothing to be done right now: sit still and look again tomorrow.
survey_hold :: proc(n: ^Npc, t: f64) {
	n.failures = 0
	n.state = .Dwelling
	n.dwell_until = t + core.SECONDS_PER_DAY
}

// What a surveyor is doing, for the popover and the contacts list.
survey_status :: proc(n: ^Npc, sys: ^gen.System) -> string {
	name := n.cloud >= 0 && n.cloud < len(sys.nebulae) ? sys.nebulae[n.cloud].name : "the cloud"
	switch n.state {
	case .Surveying:
		if n.skim.stalled != "" do return n.skim.stalled
		return fmt.tprintf("scooping gas in %s", name)
	case .Planning: return "plotting a new patch"
	case .Flying:   return n.selling ? "running the haul in" : fmt.tprintf("crossing %s", name)
	case .Dwelling: return fmt.tprintf("holding station in %s", name)
	case .Trading:  return "surveying"
	}
	return "surveying"
}
