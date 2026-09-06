package main

// The crew as the game sees them (docs/DESIGN.md §5.9): the roster stands
// its posts while the clock runs, what they achieve is pushed onto the ship
// each frame, and the deck plan is rebuilt whenever the hull changes. The
// package `crew` knows nothing about the Game; this file is the glue.

import "core:fmt"
import "core:strings"
import art "sim:art"
import audio "sim:audio"
import core "sim:core"
import crew "sim:crew"
import render "sim:render"
import sim "sim:sim"
import ui "sim:ui"

// Rebuild the deck for the hull and put ashore whoever no longer has a bunk.
crew_refit :: proc(g: ^Game) -> (dropped: int) {
	bunks := crew.BUNKS[g.ship.class]
	crew.deck_destroy(&g.deck)
	g.deck = crew.deck_build(g.ship.class, bunks)
	dropped = crew.trim(&g.roster, bunks)
	for &m in g.roster.members do m.walker.inited = false
	g.inside.selected = -1
	return
}

// Once a frame, after the ship has moved: the crew stand their posts for the
// game time that passed (never in cryo: the loop does not get here then),
// level-ups go in the log, and the ship learns what its crew do for it.
crew_update :: proc(g: ^Game, game_dt, real_dt: f64) {
	if g.ship.mode != .Cryo do crew.roster_work(&g.roster, game_dt)
	for lu in g.roster.levelled {
		if lu.member >= len(g.roster.members) do continue
		names := crew.SYSTEM_NAMES
		log_line(g, g.clock_t, .Good, fmt.tprintf("%s is now level %d at %s", g.roster.members[lu.member].name, lu.level, names[lu.system]))
	}
	clear(&g.roster.levelled)
	g.crew_fx = crew.effects(&g.roster)
	g.ship.repair_rate = g.crew_fx.repair_per_hour / core.SECONDS_PER_HOUR
	g.ship.shield = g.crew_fx.shield
	g.ship.ve_bonus = g.crew_fx.ve_bonus
	if g.inside_open do crew.walk_update(&g.roster, &g.deck, f32(real_dt))
}

// "crew 2/2: Ada Voss (engineering), Bo Quin (bridge)" for the ship's card.
crew_summary :: proc(g: ^Game) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for &m in g.roster.members {
		where_: string
		switch m.post {
		case .Off_Duty:    where_ = "off duty"
		case .Engineering: where_ = "engineering"
		case .Navigation:  where_ = "bridge"
		case .Comms:       where_ = "comms"
		}
		append(&parts, fmt.tprintf("%s (%s)", first_name(m.name), where_))
	}
	return fmt.tprintf("crew %d/%d: %s", len(g.roster.members), crew.BUNKS[g.ship.class], strings.join(parts[:], ", ", context.temp_allocator))
}

first_name :: proc(name: string) -> string {
	for c, i in name do if c == ' ' do return name[:i]
	return name
}

// Post a crew member somewhere. They drop whatever they were doing on the
// deck and head there.
crew_post :: proc(g: ^Game, i: int, p: crew.Post) {
	if i < 0 || i >= len(g.roster.members) do return
	m := &g.roster.members[i]
	if m.post == p do return
	m.post = p
	m.walker.on_break = false
	m.walker.wait = 0
	names := crew.POST_NAMES
	log_line(g, g.clock_t, .Info, p == .Off_Duty ? fmt.tprintf("%s stood down", m.name) : fmt.tprintf("%s posted to %s", m.name, names[p]))
}

// The station the ship is berthed at, if it is at one (not a trader).
crew_station :: proc(g: ^Game) -> (int, bool) {
	if g.ship.mode == .Docked && !g.ship.docked_ship && g.ship.dock < len(g.sys.stations) do return g.ship.dock, true
	return -1, false
}

// The deck view: draw it and act on what was clicked.
inside_draw :: proc(g: ^Game, lib: ^art.Library, t: f64) -> (hot: bool) {
	avatars := make([]render.Avatar, len(g.roster.members), context.temp_allocator)
	for &m, i in g.roster.members do avatars[i] = render.avatar_make(m.seed)
	docked := ""
	cands: []crew.Candidate
	if st, ok := crew_station(g); ok {
		docked = g.sys.stations[st].name
		cands = crew.candidates(&g.roster, g.sys.seed, st, t)
	}
	hazard := ""
	switch g.ship.hazard {
	case .Heat: hazard = "heat: hull cooking"
	case .Wind: hazard = "pulsar wind on the hull"
	case .Dust: hazard = "dust scouring the hull"
	case .None:
	}
	bunks := crew.BUNKS[g.ship.class]
	act, member, post, cand, h := ui.ship_view_draw(ui.Ship_View {
		lib = lib, roster = &g.roster, deck = &g.deck, avatars = avatars,
		ship_name = g.ship.name, bunks = bunks,
		hull = g.ship.hull, propellant = g.ship.stats.propellant_cap > 0 ? g.ship.propellant / g.ship.stats.propellant_cap : 0,
		cargo_frac = g.ship.stats.cargo_cap > 0 ? sim.cargo_used(&g.ship) / g.ship.stats.cargo_cap : 0,
		effects = g.crew_fx, hazard = hazard, docked_at = docked, candidates = cands, credits = g.credits,
	}, &g.inside)
	hot = h
	switch act {
	case .None:
	case .Close:
		g.inside_open = false
		audio.play(.Close)
	case .Assign:
		crew_post(g, member, post)
	case .Hire:
		if cand >= 0 && cand < len(cands) {
			c := cands[cand]
			if g.credits >= c.fee && crew.hire(&g.roster, c, bunks) {
				g.credits -= c.fee
				m := &g.roster.members[len(g.roster.members) - 1]
				trades := crew.SYSTEM_TRADES
				log_line(g, t, .Good, fmt.tprintf("%s signed on at %s: %s, level %d, for %.0f", m.name, docked, trades[c.specialty], c.level, c.fee))
			} else {
				audio.play(.Error)
			}
		}
	case .Dismiss:
		if member >= 0 && member < len(g.roster.members) {
			log_line(g, t, .Info, fmt.tprintf("%s went ashore at %s", g.roster.members[member].name, docked))
			crew.dismiss(&g.roster, member)
			g.inside.selected = -1
		}
	}
	return
}
