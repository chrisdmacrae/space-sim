package main

// Conversations with pilots and vendors: opening, choosing what to say,
// filling the slots in a line with what is really going on, and trading
// cargo with a pilot from the panel.

import "core:fmt"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"
import people "sim:people"
import render "sim:render"
import sim "sim:sim"
import ui "sim:ui"
import audio "sim:audio"

Talk :: struct {
	open:     bool,
	kind:     Focus_Kind, // .Npc or .Station
	index:    int,
	person:   people.Person,
	avatar:   render.Avatar,
	line:     string, // owned
	trading:  bool,
	haggled:  bool,
	discount: f64, // 0 or the haggled fraction off the pilot's asking price
	conv:     u64, // conversation id: seeds the line picks
	remote:   bool, // over the radio (a hail): talk, no trading
	turn:     int,
	st:       ui.Talk_State,
}

// The person behind a ship or station, and their face.
person_of :: proc(g: ^Game, kind: Focus_Kind, index: int, allocator := context.allocator) -> (people.Person, render.Avatar) {
	p: people.Person
	#partial switch kind {
	case .Npc:     p = people.pilot_for(g.fleet.npcs[index].seed, allocator)
	case .Station: p = people.vendor_for(g.sys.seed, index, allocator)
	case .Body:    p = people.vendor_for(g.sys.seed, 1000 + index, allocator) // colony vendor
	}
	return p, render.avatar_make(p.seed)
}

// What the slots in a line resolve to for this speaker right now.
talk_slots :: proc(g: ^Game, kind: Focus_Kind, index: int, name: string, price: f64) -> []people.Slot {
	slots := make([dynamic]people.Slot, context.temp_allocator)
	add :: proc(slots: ^[dynamic]people.Slot, key, value: string) { append(slots, people.Slot{key, value}) }
	add(&slots, "name", name)
	add(&slots, "system", g.sys.name)
	// Casual lines want "the star", not "the M-type main sequence star".
	add(&slots, "star", g.sys.star.kind == .Main_Sequence ? "star" : gen.star_describe(g.sys.star))
	add(&slots, "hull", econ.CLASS_NAMES[g.ship.class])
	add(&slots, "credits", fmt.tprintf("%.0f", g.credits))
	add(&slots, "price", fmt.tprintf("%.1f", price))
	nearby := "the next system"
	if nb := gen.neighbours(&g.galaxy, g.current); len(nb) > 0 do nearby = g.galaxy.systems[nb[0]].name
	add(&slots, "nearby", nearby)
	market: ^econ.Market
	#partial switch kind {
	case .Npc:
		n := &g.fleet.npcs[index]
		add(&slots, "ship", econ.CLASS_NAMES[n.ship.class])
		c := n.route.commodity
		has_route := n.route.from != n.route.to && n.route.to < len(g.econ.markets)
		// The commodity on the table: the route's, else whatever is aboard.
		if !has_route do for cc in econ.Commodity do if n.ship.cargo[int(cc)] > 0 { c = cc; break }
		add(&slots, "commodity", econ.NAMES[c])
		add(&slots, "units", fmt.tprintf("%.0f", n.ship.cargo[int(c)]))
		if has_route {
			to := &g.econ.markets[n.route.to]
			from := &g.econ.markets[n.route.from]
			add(&slots, "dest", to.name)
			add(&slots, "origin", from.name)
			add(&slots, "dest_price", fmt.tprintf("%.1f", econ.sell_price(to, c)))
			add(&slots, "station", to.name)
			market = to
		} else {
			add(&slots, "dest", "nowhere in particular")
			add(&slots, "origin", "here and there")
			add(&slots, "dest_price", "whatever it fetches")
			add(&slots, "station", len(g.econ.markets) > 0 ? g.econ.markets[0].name : g.sys.name)
			if len(g.econ.markets) > 0 do market = &g.econ.markets[0]
		}
	case .Station, .Body:
		if mi, ok := market_for_key(g, kind, index); ok {
			market = &g.econ.markets[mi]
			add(&slots, "station", market.name)
		} else {
			add(&slots, "station", kind == .Station ? g.sys.stations[index].name : g.sys.bodies[index].name)
		}
		add(&slots, "ship", "station")
		add(&slots, "commodity", "goods")
		add(&slots, "units", "0")
		add(&slots, "dest", g.sys.name)
		add(&slots, "origin", g.sys.name)
		add(&slots, "dest_price", "the board price")
	}
	want, glut := "everything", "nothing"
	if market != nil {
		best_s, best_g := -1.0, -1.0
		for c in econ.Commodity {
			ratio := market.target[c] > 0 ? market.stock[c] / market.target[c] : 1
			if 1 - ratio > best_s { best_s = 1 - ratio; want = econ.NAMES[c] }
			if ratio - 1 > best_g { best_g = ratio - 1; glut = econ.NAMES[c] }
		}
	}
	add(&slots, "want", want)
	add(&slots, "glut", glut)
	return slots[:]
}

// A filled line of `cat` from the current speaker.
talk_line :: proc(g: ^Game, kind: Focus_Kind, index: int, p: people.Person, cat: string, conv: u64, turn: int, price: f64 = 0) -> string {
	r := core.rng_make(core.sub_seed(conv, cat, turn))
	tmpl := people.pick_line(&g.dialog, cat, p, &r)
	if tmpl == "" do tmpl = "..."
	return people.fill(tmpl, talk_slots(g, kind, index, p.name, price))
}

talk_say :: proc(g: ^Game, cat: string, price: f64 = 0) {
	g.talk.turn += 1
	delete(g.talk.line)
	g.talk.line = fmt.aprintf("%s", talk_line(g, g.talk.kind, g.talk.index, g.talk.person, cat, g.talk.conv, g.talk.turn, price))
}

talk_open :: proc(g: ^Game, kind: Focus_Kind, index: int, opening: string, t: f64) {
	talk_close(g)
	g.talk.open = true
	g.talk.kind = kind
	g.talk.index = index
	g.talk.person, g.talk.avatar = person_of(g, kind, index)
	g.talk.conv = core.sub_seed(g.talk.person.seed, "conv", int(t / 60))
	g.talk.turn = 0
	g.talk.trading = false
	g.talk.haggled = false
	g.talk.discount = 0
	g.talk.st.qty = 1
	talk_say(g, opening)
	audio.play(.Open)
}

talk_close :: proc(g: ^Game) {
	if !g.talk.open do return
	people.person_destroy(&g.talk.person)
	delete(g.talk.line)
	g.talk = {}
}

// What a pilot will sell and buy right now.
pilot_offer :: proc(g: ^Game, index: int) -> (o: ui.Talk_Offer, c: econ.Commodity, ok: bool) {
	n := &g.fleet.npcs[index]
	c = n.route.commodity
	has_route := n.route.from != n.route.to && n.route.to < len(g.econ.markets) && n.route.from < len(g.econ.markets)
	if !has_route {
		// No route: sell whatever is aboard at the nearest market's price.
		for cc in econ.Commodity do if n.ship.cargo[int(cc)] > 0 { c = cc; break }
		if len(g.econ.markets) == 0 do return {}, c, false
	}
	base := 0.0
	buy := 0.0
	if has_route {
		to := &g.econ.markets[n.route.to]
		from := &g.econ.markets[n.route.from]
		base = max(econ.sell_price(to, c) * 0.9, econ.buy_price(from, c) * 1.05)
		buy = econ.buy_price(from, c) * 1.03
	} else {
		m := &g.econ.markets[0]
		base = econ.price(m, c)
		buy = econ.sell_price(m, c)
	}
	o.commodity = econ.NAMES[c]
	o.sell_units = n.ship.cargo[int(c)]
	// A comms officer on the radio shaves the pilot's price and lifts their offer.
	o.sell_price = base * (1 - g.talk.discount) * (1 - g.crew_fx.trade_edge)
	o.buy_price = buy * (1 + g.crew_fx.trade_edge)
	o.buy_room = min(sim.cargo_free(&n.ship), buy > 0 ? n.credits / buy : 0)
	o.you_have = g.ship.cargo[int(c)]
	o.your_room = sim.cargo_free(&g.ship)
	o.credits = g.credits
	return o, c, true
}

// Handle a choice from the conversation panel.
talk_choose :: proc(g: ^Game, choice: ui.Talk_Choice, qty: int, t: f64) {
	switch choice {
	case .None:
	case .Small_Talk: talk_say(g, "smalltalk")
	case .Rumour:     talk_say(g, "rumour")
	case .Cargo:      talk_say(g, g.talk.kind == .Npc ? "cargo" : "market")
	case .Trade:
		if g.talk.kind == .Station || g.talk.kind == .Body {
			g.market_open = true
			talk_close(g)
			return
		}
		g.talk.trading = !g.talk.trading
		if g.talk.trading {
			o, _, ok := pilot_offer(g, g.talk.index)
			if ok && o.sell_units > 0 do talk_say(g, "trade_open", o.sell_price)
			else if ok && o.buy_room > 0 do talk_say(g, "trade_open_buy", o.buy_price)
			else do talk_say(g, "no_deal")
		} else {
			talk_say(g, "smalltalk")
		}
	case .Haggle:
		if g.talk.haggled do return
		g.talk.haggled = true
		if people.haggle_accepts(g.talk.person, g.talk.conv) {
			g.talk.discount = 0.08
			o, _, _ := pilot_offer(g, g.talk.index)
			talk_say(g, "haggle_accept", o.sell_price)
			audio.play(.Confirm)
		} else {
			o, _, _ := pilot_offer(g, g.talk.index)
			talk_say(g, "haggle_refuse", o.sell_price)
			audio.play(.Error)
		}
	case .Buy, .Sell:
		o, c, ok := pilot_offer(g, g.talk.index)
		if !ok do return
		n := &g.fleet.npcs[g.talk.index]
		slot := int(c)
		units := f64(qty)
		if choice == .Buy {
			units = min(units, o.sell_units, o.your_room, o.sell_price > 0 ? g.credits / o.sell_price : 0)
			if units < 1 { talk_say(g, "no_deal"); return }
			cost := units * o.sell_price
			g.ship.cargo[slot] += units
			n.ship.cargo[slot] -= units
			g.credits -= cost
			n.credits += cost
		} else {
			units = min(units, o.you_have, o.buy_room)
			if units < 1 { talk_say(g, "no_deal"); return }
			pay := units * o.buy_price
			g.ship.cargo[slot] -= units
			n.ship.cargo[slot] += units
			g.credits += pay
			n.credits -= pay
		}
		talk_say(g, "deal_done", o.sell_price)
		audio.play(.Confirm)
	case .Leave:
		talk_close(g)
		audio.play(.Close)
	case .Work:
		g.jobs_open = true
		g.jobs_board = true
		talk_close(g)
	}
}

// Ask a pilot to dock. Refusals come from their personality and the day.
request_ship_dock :: proc(g: ^Game, index: int, t: f64) {
	n := &g.fleet.npcs[index]
	p, _ := person_of(g, .Npc, index, context.temp_allocator)
	conv := core.sub_seed(p.seed, "dock", int(t / 60))
	if people.dock_refuses(p, t) {
		g.plan_msg = fmt.tprintf("%s: \"%s\"", p.name, talk_line(g, .Npc, index, p, "dock_refuse", conv, 0))
		audio.play(.Error)
		return
	}
	sim.dock_ship(&g.ship, &n.ship, index)
	sim.npc_receive_visitor(&g.sys, n, t)
	g.selected = -1
	g.ap.active = false
	talk_open(g, .Npc, index, "dock_accept", t)
}

// Undock from whatever we are docked to; a trader resumes its route.
undock_player :: proc(g: ^Game, t: f64) {
	if g.ship.mode != .Docked do return
	g.undocked_at = t
	if g.ship.docked_ship {
		host := g.ship.dock
		if g.talk.open && g.talk.kind == .Npc && g.talk.index == host do talk_close(g)
		sim.undock(&g.sys, &g.ship, t)
		if host < len(g.fleet.npcs) do sim.npc_visitor_left(&g.fleet.npcs[host], t)
		return
	}
	sim.undock(&g.sys, &g.ship, t)
}

// Each frame while docked to a trader: ride it, or let go if it is gone.
ride_host :: proc(g: ^Game, t: f64) {
	if g.ship.mode != .Docked || !g.ship.docked_ship do return
	host := g.ship.dock
	if host >= len(g.fleet.npcs) || g.fleet.npcs[host].ship.mode != .On_Rails || !g.fleet.npcs[host].visitor {
		g.plan_msg = "the ship you were docked to has moved on"
		g.ship.docked_ship = false
		g.ship.mode = .On_Rails
		sim.repredict(&g.sys, &g.ship, t)
		if g.talk.open && g.talk.kind == .Npc do talk_close(g)
		return
	}
	sim.ride_along(&g.ship, &g.fleet.npcs[host].ship)
}

// The market for a station or a colony body.
market_for_key :: proc(g: ^Game, kind: Focus_Kind, index: int) -> (int, bool) {
	for &m, i in g.econ.markets {
		if kind == .Station && m.station == index do return i, true
		if kind == .Body && m.station < 0 && int(m.body) == index do return i, true
	}
	return -1, false
}

// Who to talk to at a market: the station's vendor or the colony's.
market_key :: proc(g: ^Game, market: int) -> (Focus_Kind, int) {
	m := &g.econ.markets[market]
	if m.station >= 0 do return .Station, m.station
	return .Body, int(m.body)
}

// The vendor shown on the market panel: refreshed when the market changes.
vendor_refresh :: proc(g: ^Game, market: int, t: f64) {
	if g.vendor_station == market do return
	people.person_destroy(&g.vendor)
	delete(g.vendor_line)
	g.vendor_station = market
	kind, index := market_key(g, market)
	g.vendor, g.vendor_avatar = person_of(g, kind, index)
	conv := core.sub_seed(g.vendor.seed, "visit", int(t / 3600))
	g.vendor_line = fmt.aprintf("%s", talk_line(g, kind, index, g.vendor, "greeting", conv, 0))
}
