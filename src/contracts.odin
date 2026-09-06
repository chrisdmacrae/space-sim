package main

// Contracts the player holds, and the interruptions that pace a flight:
// notices that stop the clock for a decision.

import "core:fmt"
import "core:strings"
import core "sim:core"
import gen "sim:gen"
import econ "sim:econ"
import people "sim:people"
import sim "sim:sim"
import ui "sim:ui"
import audio "sim:audio"

MAX_CONTRACTS :: 3

Notice_Kind :: enum u8 {
	Info,      // one button
	Arrival,   // OK / Trade
	Hazard,    // Continue / Cut autopilot
	Hail,      // Answer / Ignore
	Undock_Plan, // docked when a course was asked for: Undock and plot / Stay
}

Notice :: struct {
	kind:    Notice_Kind,
	title:   string, // owned
	text:    string, // owned
	npc:     int,    // Hail: who
	market:  int,    // Arrival: market in range, -1 if none
	dest:    sim.Destination, // Undock_Plan: the course to plot once free
	point:   [2]f64,          // Undock_Plan: world point when dest is a waypoint
}

// Queue a notice; the clock stops when one shows. Every notice is also
// written to the log, so the card can be dismissed without losing what it said.
notice_push :: proc(g: ^Game, kind: Notice_Kind, title, body: string, npc := -1, market := -1) {
	append(&g.notices, Notice{kind = kind, title = fmt.aprintf("%s", title), text = fmt.aprintf("%s", body), npc = npc, market = market})
	// A hazard writes its own line, with the rate on it, so this one would repeat it.
	if kind != .Hazard {
		log_kind := ui.Log_Kind.Info
		if kind == .Arrival do log_kind = .Good
		log_line(g, g.clock_t, log_kind, title)
	}
	audio.play(.Open)
}

notice_pop :: proc(g: ^Game) {
	if len(g.notices) == 0 do return
	n := g.notices[0]
	delete(n.title)
	delete(n.text)
	ordered_remove(&g.notices, 0)
}

notices_destroy :: proc(g: ^Game) {
	for len(g.notices) > 0 do notice_pop(g)
	delete(g.notices)
}

// ---- contracts

contract_accept :: proc(g: ^Game, id: u64) {
	if len(g.contracts) >= MAX_CONTRACTS { g.plan_msg = "you already hold three contracts"; return }
	j, ok := econ.find_job(g.econ, id)
	if !ok do return
	if ok2, why := econ.job_accept_ok(j, sim.cargo_free(&g.ship)); !ok2 { g.plan_msg = why; return }
	j, _ = econ.take_job(g.econ, id)
	if j.kind == .Delivery do g.ship.cargo[int(j.commodity)] += j.units
	append(&g.contracts, j)
	audio.play(.Confirm)
	if j.kind == .Passenger {
		p := people.make_person(j.person, .Pilot, context.temp_allocator)
		names := people.PERSONALITY_NAMES
		line := talk_line(g, .Station, max(j.from, 0), p, "greeting", j.id, 0)
		notice_push(g, .Info, fmt.tprintf("%s comes aboard", p.name), fmt.tprintf("%s, %s. Bound for %s.\n\n\"%s\"", p.name, names[p.personality], g.econ.markets[j.to].name, line))
	}
}

contract_deliver :: proc(g: ^Game, idx: int) {
	if idx < 0 || idx >= len(g.contracts) do return
	j := g.contracts[idx]
	if j.kind != .Passenger {
		g.ship.cargo[int(j.commodity)] -= j.units
		if j.kind == .Procurement && j.to < len(g.econ.markets) do g.econ.markets[j.to].stock[j.commodity] += j.units
	}
	g.credits += j.reward
	ordered_remove(&g.contracts, idx)
	audio.play(.Confirm)
	body := fmt.tprintf("%s\n\n+%.0f credits.", econ.job_describe(g.econ, j), j.reward)
	if j.kind == .Passenger {
		p := people.make_person(j.person, .Pilot, context.temp_allocator)
		body = fmt.tprintf("%s steps off at %s.\n\n\"%s\"\n\n+%.0f credits.", p.name, g.econ.markets[j.to].name, talk_line(g, .Station, j.to, p, "farewell", j.id, 1), j.reward)
	}
	notice_push(g, .Info, "Contract complete", body)
}

// Rows for the panel: what each contract needs right now.
contract_rows :: proc(g: ^Game, at: int, t: f64) -> []ui.Contract_Row {
	rows := make([dynamic]ui.Contract_Row, context.temp_allocator)
	for j in g.contracts {
		row := ui.Contract_Row{job = j, desc = econ.job_describe(g.econ, j)}
		row.ready = at >= 0 && econ.job_deliverable(j, at, g.ship.cargo[:])
		switch j.kind {
		case .Delivery, .Procurement:
			have := g.ship.cargo[int(j.commodity)]
			row.status = row.ready ? "deliver here" : (have >= j.units ? fmt.tprintf("carrying %.0f %s", have, econ.NAMES[j.commodity]) : fmt.tprintf("need %.0f more %s", j.units - have, econ.NAMES[j.commodity]))
		case .Passenger:
			row.status = row.ready ? "disembark here" : "aboard"
		}
		append(&rows, row)
	}
	return rows[:]
}

// Each frame: deliver what can be delivered where we are, fail what ran out
// of time.
contracts_update :: proc(g: ^Game, t: f64) {
	at, has := trade_market(g)
	for i := 0; i < len(g.contracts); {
		j := g.contracts[i]
		if has && econ.job_deliverable(j, at, g.ship.cargo[:]) {
			contract_deliver(g, i)
			continue
		}
		if t > j.deadline {
			ordered_remove(&g.contracts, i)
			audio.play(.Error)
			notice_push(g, .Info, "Contract failed", fmt.tprintf("%s\n\nThe deadline passed. No pay, and the goods are yours to dispose of.", econ.job_describe(g.econ, j)))
			continue
		}
		i += 1
	}
}

// A course was asked for while docked: ask before casting off.
ask_undock_for :: proc(g: ^Game, dest: sim.Destination, point: [2]f64) {
	place := "a station"
	if g.ship.docked_ship {
		if g.ship.dock < len(g.fleet.npcs) do place = g.fleet.npcs[g.ship.dock].name
	} else if g.ship.dock < len(g.sys.stations) {
		place = g.sys.stations[g.ship.dock].name
	}
	what := dest.kind == .Point ? "the waypoint" : destination_name(g, dest)
	append(&g.notices, Notice{kind = .Undock_Plan, title = fmt.aprintf("Still docked"), text = fmt.aprintf("You are docked at %s. Undock and plot a course to %s?", place, what), dest = dest, point = point})
	audio.play(.Open)
}

// ---- interruptions while time runs on its own

HAIL_RANGE :: 40.0
HAIL_GAP   :: 6 * core.SECONDS_PER_HOUR

// A trader passing close by hails, at most once per pass: the hail belongs to the
// approach, not to a cooldown. A trader holding a nearby orbit stays in range for
// days, and at warp a day goes by in a second, so a cooldown alone would have it
// calling again every second until the player left. It gets one hail per approach
// and nothing more until it has drifted back out of range.
hail_check :: proc(g: ^Game, t: f64) {
	// Every trader is looked at, not just up to the one that calls: leaving range is
	// what re-arms the next pass, so those flags have to stay current. One that could
	// not be heard yet - the player is docked, or another call just came in - keeps
	// its turn and speaks up later in the same approach.
	quiet := g.ship.mode != .On_Rails || t < g.last_hail + HAIL_GAP
	for &n, i in g.fleet.npcs {
		near := n.ship.mode == .On_Rails && n.ship.primary == g.ship.primary && !n.visitor
		if near {
			d := g.ship.pos - n.ship.pos
			near = d.x * d.x + d.y * d.y <= HAIL_RANGE * HAIL_RANGE
		}
		if !near {
			n.hail_spent = false // out of range: the next approach may hail
			continue
		}
		if quiet || n.hail_spent || n.hail_muted do continue
		// Two traders drifting across the edge of range still cannot take turns.
		if n.hailed_at > 0 && t - n.hailed_at < core.SECONDS_PER_DAY do continue
		n.hail_spent = true
		n.hailed_at = t
		g.last_hail = t
		quiet = true // one hail at a time; the rest keep their flags for later
		p, _ := person_of(g, .Npc, i, context.temp_allocator)
		names := people.PERSONALITY_NAMES
		line := talk_line(g, .Npc, i, p, "greeting", core.sub_seed(p.seed, "hail", int(t / 60)), 0)
		notice_push(g, .Hail, fmt.tprintf("%s hails you", n.name), fmt.tprintf("%s, %s, on the %s.\n\n\"%s\"", p.name, names[p.personality], econ.CLASS_NAMES[n.ship.class], line), i)
	}
}

// Entering a star's heat or wind stops the clock once, so the player can decide.
hazard_check :: proc(g: ^Game) {
	h := g.ship.hazard
	per_hour := g.ship.hazard_rate * core.SECONDS_PER_HOUR
	flying := g.ship.mode == .On_Rails || g.ship.mode == .Thrusting
	if h != .None && g.prev_hazard == .None && flying {
		if h == .Dust {
			// Gas is slow, and a cloud is wide enough to clip the edge of
			// often. Only the thick of it is worth stopping the clock for,
			// and then the news is as much what it yields as what it costs.
			if per_hour > 0.002 {
				if idx, density := gen.nebula_at(&g.sys, g.sys.pos[g.ship.primary] + g.ship.pos); idx >= 0 {
					n := g.sys.nebulae[idx]
					names := make([dynamic]string, context.temp_allocator)
					for c in econ.nebula_yield_names(n.kind) do append(&names, econ.NAMES[c])
					notice_push(g, .Hazard, fmt.tprintf("Into %s", n.name),
						fmt.tprintf("A %s, %.0f%% thick here. Dust costs the hull %.2f%% an hour; the scoop would pull %s out of it (Orders > Skim).",
							gen.nebula_describe(n.kind), density * 100, per_hour * 100, strings.join(names[:], ", ", context.temp_allocator)))
				}
			}
		} else {
			what := h == .Heat ? "the heat line" : "the pulsar wind"
			notice_push(g, .Hazard, "Hull taking damage", fmt.tprintf("You are inside %s of %s: hull -%.1f%% per hour. Continue on the plan, or cut the autopilot and coast?", what, g.sys.bodies[0].name, per_hour * 100))
		}
	}
	g.prev_hazard = h
}

// The autopilot finished: say so and offer the market.
arrival_check :: proc(g: ^Game, t: f64) {
	active := g.ap.active
	if g.prev_ap_active && !active && g.ap.stage == .Done {
		at, has := trade_market(g)
		name := destination_name(g, g.ap.dest)
		// Docking already opened the market; only offer it when it is not up.
		notice_push(g, .Arrival, "Arrived", fmt.tprintf("%s: %s.", name, g.ap.status), -1, has && !g.market_open ? at : -1)
	}
	g.prev_ap_active = active
}

// What the player chose on the notice at the front of the queue.
notice_choose :: proc(g: ^Game, choice: int, t: f64) {
	if len(g.notices) == 0 || choice < 0 do return
	n := g.notices[0]
	switch n.kind {
	case .Info:
	case .Arrival:
		if choice == 1 && n.market >= 0 do g.market_open = true
	case .Hazard:
		if choice == 1 {
			g.ap.active = false
			g.ap.stage = .Idle
			g.ship.autoburn.active = false
			g.ship.throttle = 0
		}
	case .Hail:
		if n.npc >= 0 && n.npc < len(g.fleet.npcs) {
			if choice == 0 {
				talk_open(g, .Npc, n.npc, "greeting", t)
				g.talk.remote = true
			} else {
				g.fleet.npcs[n.npc].hail_muted = true // ignored once: it stops calling
			}
		}
	case .Undock_Plan:
		if choice == 0 {
			undock_player(g, t)
			notice_pop(g)
			if n.dest.kind == .Point do plan_to_point(g, n.point, t)
			else do begin_planning(g, t, n.dest)
			return
		}
	}
	notice_pop(g)
}
