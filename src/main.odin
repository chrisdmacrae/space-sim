package main

// Phase 5 (docs/DESIGN.md §9): the first autopilot. Focus a body or station,
// press G, pick a plan by objective, and the ship flies it as nodes.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import art "sim:art"
import core "sim:core"
import gen "sim:gen"
import orbit "sim:orbit"
import render "sim:render"
import econ "sim:econ"
import save "sim:save"
import sim "sim:sim"
import text "sim:text"
import ui "sim:ui"
import input "sim:input"
import people "sim:people"
import audio "sim:audio"
import settings "sim:settings"

// Dev options: `--screenshot out.png [--frames N] [--panel] [--burn] [--follow]
// [--overview] [--flyby] [--node T,PRO,RAD] [--execute] [--zoom Z] [--seed S] [--focus NAME] [--time T] [--turn ±1]` renders N frames, saves a screenshot
// and exits. `--seed` alone picks the system for a normal run.
Dev_Opts :: struct {
	screenshot: string,
	frames:     int,
	panel:      bool,
	burn:       bool,
	follow:     bool,
	overview:   bool, // start framed on the whole system instead of the ship
	flyby:      bool, // start on a hyperbolic approach to the home planet
	node:       string, // "t,prograde,radial": add a node at start (dev)
	execute:    bool,   // arm that node and warp to it (dev)
	dest:       string, // plan a course to this body/station at start (dev)
	objective:  string, // fuel | time | balanced | simplest (dev, with --dest)
	autowarp:   bool,   // keep warping to the next burn or event while the autopilot flies (dev)
	warpcap:    f64,    // override the thrusting warp cap (dev)
	until_done: bool,   // with --screenshot: capture when the autopilot finishes (dev)
	jump:       bool,   // with --map N: press the map's Jump button (dev)
	play:       bool,   // skip the start menu and begin a default game (dev)
	title:      string, // open this start-menu screen: home|new|load|save|settings|controls (dev)
	avatars:    bool,   // draw a grid of generated NPC faces instead of the menu (dev)
	talk:       string, // open a conversation at start: "vendor" (station 0) or "pilot" (trader 0) (dev)
	angle:      f64,    // initial view rotation in degrees (dev)
	turn:       f64,    // hold the attitude jets this hard, -1 (right) to 1 (left) (dev)
	headlock:   bool,   // start with the view locked to the ship heading (dev)
	ticks:      bool,   // start with the time-step list dropped down (dev)
	colony:     bool,   // park over the first colony, open its market and queue shuttle orders (dev)
	orbit_at:   f64,    // open the orbit-at-altitude card and set it to this altitude (dev)
	orbit_go:   bool,   // with --orbit: issue the order at once (dev)
	jobs:       bool,   // dock at station 0 and open the job board (dev)
	stars:      bool,   // print each system's star kind and exit (dev)
	nebulae:    bool,   // print every system holding a nebula and exit (dev)
	skim:       bool,   // park in the thickest gas of the first nebula and start skimming (dev)
	mapzoom:    f32,    // with --map: initial map zoom (dev)
	doom:       bool,   // drop the ship into the star from four radii (dev)
	until_dead: bool,   // with --screenshot: capture shortly after the ship is destroyed (dev)
	menu:       int,    // open this menu index at start (dev), 0 = none
	trace:      bool,   // print autopilot stage changes (dev)
	perf:       bool,   // print frame-time statistics at exit (dev)
	warp:       int,    // starting warp index (dev)
	zoom:       f64,
	seed:       u64,
	focus:      string,
	time:       f64, // starting game time, seconds
	system:     int, // starting system index (dev)
	cryo:       int, // jump to this system at start, as if arriving (dev)
	map_sel:    int, // open the galaxy map with this system selected (dev)
	contacts:   bool, // open the contacts panel fully expanded (dev)
	routes:     bool, // draw trade routes (dev)
	waypoint:   string, // "dx,dy" from the ship's primary: plan a course there at start (dev)
	hover:      string, // pin this entity's popover open (dev)
	market:     bool,   // open the market window at start (dev)
}

parse_opts :: proc() -> (o: Dev_Opts) {
	o.frames = 30
	o.seed = 1
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "--screenshot": o.screenshot = next; i += 1
		case "--frames":     o.frames, _ = strconv.parse_int(next); i += 1
		case "--zoom":       o.zoom, _ = strconv.parse_f64(next); i += 1
		case "--seed":       o.seed, _ = strconv.parse_u64(next); i += 1
		case "--system":     o.system, _ = strconv.parse_int(next); i += 1
		case "--cryo":
			if next == "near" do o.cryo = -2
			else do o.cryo, _ = strconv.parse_int(next)
			i += 1
		case "--map":
			if next == "near" do o.map_sel = -2 // first linked neighbour of the start system
			else do o.map_sel, _ = strconv.parse_int(next)
			i += 1
		case "--contacts":   o.contacts = true
		case "--routes":     core.debug.show_routes = true
		case "--waypoint":   o.waypoint = next; i += 1
		case "--hover":      o.hover = next; i += 1
		case "--market":     o.market = true
		case "--focus":      o.focus = next; i += 1
		case "--time":       o.time, _ = strconv.parse_f64(next); i += 1
		case "--panel":      o.panel = true
		case "--burn":       o.burn = true
		case "--follow":     o.follow = true // default now; kept for old scripts
		case "--overview":   o.overview = true
		case "--flyby":      o.flyby = true
		case "--node":       o.node = next; i += 1
		case "--execute":    o.execute = true
		case "--dest":       o.dest = next; i += 1
		case "--objective":  o.objective = next; i += 1
		case "--autowarp":   o.autowarp = true
		case "--warpcap":    o.warpcap, _ = strconv.parse_f64(next); i += 1
		case "--until-done": o.until_done = true
		case "--jump":       o.jump = true
		case "--play":       o.play = true
		case "--title":      o.title = next; i += 1
		case "--avatars":    o.avatars = true
		case "--talk":       o.talk = next; i += 1
		case "--angle":      o.angle, _ = strconv.parse_f64(next); i += 1
		case "--turn":       o.turn, _ = strconv.parse_f64(next); i += 1
		case "--headlock":   o.headlock = true
		case "--ticks":      o.ticks = true
		case "--colony":     o.colony = true
		case "--orbit":      o.orbit_at, _ = strconv.parse_f64(next); i += 1
		case "--orbit-go":   o.orbit_go = true
		case "--jobs":       o.jobs = true
		case "--stars":      o.stars = true
		case "--nebulae":    o.nebulae = true
		case "--skim":       o.skim = true
		case "--mapzoom":    z, _ := strconv.parse_f64(next); o.mapzoom = f32(z); i += 1
		case "--doom":       o.doom = true
		case "--until-dead": o.until_dead = true
		case "--menu":       o.menu, _ = strconv.parse_int(next); i += 1
		case "--trace":      o.trace = true
		case "--perf":       o.perf = true
		case "--warp":       o.warp, _ = strconv.parse_int(next); i += 1
		}
	}
	return
}

Focus_Kind :: enum u8 {
	None,
	Body,
	Station,
	Ship,
	Npc,
	Nebula, // a cloud is a place, not a thing: index into sys.nebulae
}

Focus :: struct {
	kind:  Focus_Kind,
	index: int,
}

Request :: enum u8 {
	None,
	Save_Slots,
	Load_Slots,
	Settings,
	Main_Menu,
}

Game :: struct {
	seed:     u64,          // galaxy seed
	galaxy:   gen.Galaxy,
	gecon:    econ.Galaxy_Econ,
	current:  int,          // index of the active system
	map_open: bool,
	map_sel:  int,
	map_st:   ui.Map_State,
	point_mode: bool, // next world click sets a waypoint
	follow_target: Focus, // what the camera follows when cam.follow is on (default: the ship)
	hover:    Focus, // entity under the mouse this frame
	pin:      Focus, // entity whose popover is showing
	pin_rect: rl.Rectangle,
	pin_grace: f64,  // real seconds the popover survives without hover
	cryo_pending: int, // galaxy index we are flying out of the system to jump to, -1 for none
	request:  Request, // a screen change asked for from the System menu, read by the app loop
	dialog:   people.Dialog, // the conversation database
	talk:     Talk,          // the open conversation, if any
	vendor:   people.Person, // the market panel's vendor
	vendor_avatar: render.Avatar,
	vendor_line:   string,
	vendor_station: int,
	clock_t:  f64,     // the sim clock, mirrored each frame for helpers that only get a Game
	heading_lock: bool, // the view turns so the ship always points up
	shuttle:  sim.Shuttle, // the colony shuttle, market -1 when none
	skim:     sim.Skim,    // the nebula scoop, nebula -1 when stowed
	// Pacing: contracts with deadlines, interruptions, and a clock that runs itself.
	contracts: [dynamic]econ.Job,
	notices:   [dynamic]Notice,
	log:       ui.Log,    // the ship's log, bottom left
	log_state: Log_State, // what it has written down already
	jobs_open: bool,
	jobs_board: bool, // the jobs window was opened at a station or colony: show its board
	auto_time: bool, // run time to the next burn or event while the autopilot flies, up to the chosen step
	auto_dock: bool, // dock by itself when in range of a station
	undocked_at: f64, // game time of the last undock: auto-dock waits a while after it
	order:     sim.Order,        // an in-frame move (orbit at altitude)
	orbit_prompt: ui.Orbit_Prompt,
	drag_apsis: int,             // 1 dragging the periapsis marker, 2 the apoapsis, 0 none
	warp_auto: bool, // the current warp-to was started by auto time (obeys the ceiling)
	warp_rate: f64,  // auto time: game seconds per real second for the current leg, paced by its length
	auto_ceiling: int, // index into WARP_LEVELS: the fastest auto time will run
	last_hail: f64,
	prev_hazard: sim.Hazard,
	prev_ap_active: bool,
	start_class: econ.Class_Id, // hull chosen at New game; the ship spawns as this class
	// Cryo transit state.
	cryo:     struct {
		active:   bool,
		dest:     int,
		t_start:  f64,
		t_arrive: f64,
		from:     string,
		notes:    string,
	},
	sys:      gen.System,
	ship:     sim.Ship,
	ship_anim: render.Ship_Anim,        // the pose the hull is drawn in
	npc_anims: [dynamic]render.Ship_Anim, // one per trader, by fleet index
	focus:    Focus,
	selected: int, // selected maneuver node, -1 for none
	dragging: bool,
	warp_to:  f64, // game time to warp to, 0 for none
	ap:       sim.Autopilot,
	planning: bool,              // candidate table open
	plan_geo: sim.Geometry,
	plan_res: sim.Search_Result,
	plan_dest: sim.Destination,
	plan_msg: string,            // static text: why planning failed
	autowarp: bool,
	mb:       ui.Menubar,
	contacts: ui.Contacts,
	econ:     ^econ.Economy, // the active system's markets, owned by gecon
	fleet:    sim.Fleet,
	routes_open: bool,
	credits:  f64,
	market_open: bool,
	yard_open:   bool,
	market_station: int, // station the market window shows, -1 for none
	yard_station:   int,
	was_docked:  bool,
	// Slider-bound copies of the selected node, written back on change.
	np_pro, np_rad, np_lead: f32,
}

// Destination from the current focus.
focus_destination :: proc(g: ^Game) -> sim.Destination {
	switch g.focus.kind {
	case .Body:    return sim.Destination{kind = .Body, index = g.focus.index}
	case .Station: return sim.Destination{kind = .Station, index = g.focus.index}
	case .Nebula:  return nebula_destination(g, g.focus.index)
	case .Ship, .Npc, .None:
	}
	return sim.Destination{}
}

destination_name :: proc(g: ^Game, d: sim.Destination) -> string {
	if d.label != "" do return d.label
	switch d.kind {
	case .Body:    return g.sys.bodies[d.index].name
	case .Station: return g.sys.stations[d.index].name
	case .Point:   return fmt.tprintf("waypoint near %s", g.sys.bodies[d.index].name)
	case .Npc:     if d.index < len(g.fleet.npcs) do return g.fleet.npcs[d.index].name
	case .None:
	}
	return "none"
}

// World position of a destination right now (for markers).
destination_pos :: proc(g: ^Game, d: sim.Destination) -> ([2]f64, bool) {
	switch d.kind {
	case .Body:    return g.sys.pos[d.index], true
	case .Station: return g.sys.station_pos[d.index], true
	case .Point:   return g.sys.pos[d.index] + d.point, true
	case .Npc:
		if d.index < len(g.fleet.npcs) {
			p, _ := sim.npc_state(&g.sys, &g.fleet.npcs[d.index], g.clock_t)
			return p, true
		}
	case .None:
	}
	return {}, false
}

// Plan a course to a clicked world point. The waypoint lives in the frame
// of whichever body's sphere contains it, falling back to the ship's own
// frame and then the star so the planner can always reach it.
plan_to_point :: proc(g: ^Game, world: [2]f64, t: f64) {
	if g.ship.mode == .Docked {
		ask_undock_for(g, sim.Destination{kind = .Point}, world)
		return
	}
	frames := [3]gen.Body_Handle{gen.primary_at(&g.sys, world), g.ship.primary, gen.STAR}
	for f in frames {
		dest := sim.Destination{kind = .Point, index = int(f), point = world - g.sys.pos[f]}
		geo, ok, reason := sim.geometry(&g.sys, &g.ship, dest)
		if !ok {
			when ODIN_DEBUG do fmt.printfln("waypoint frame %s: %s", g.sys.bodies[f].name, reason)
			continue
		}
		res := sim.search(&g.sys, &g.ship, geo, t)
		if !res.ok {
			when ODIN_DEBUG do fmt.printfln("waypoint frame %s: search failed: %s", g.sys.bodies[f].name, res.reason)
			continue
		}
		g.plan_geo = geo
		g.plan_res = res
		g.plan_dest = dest
		g.planning = true
		g.plan_msg = ""
		return
	}
	g.plan_msg = "no transfer to that point from here"
}

// Destination for any entity (ships cannot be destinations).
destination_of :: proc(g: ^Game, f: Focus) -> sim.Destination {
	switch f.kind {
	case .Body:    return sim.Destination{kind = .Body, index = f.index}
	case .Station: return sim.Destination{kind = .Station, index = f.index}
	case .Npc:
		if f.index < len(g.fleet.npcs) {
			n := &g.fleet.npcs[f.index]
			if n.ship.mode == .On_Rails do return sim.Destination{kind = .Npc, index = f.index, orbit = n.ship.orbit, primary = n.ship.primary}
		}
	case .Nebula:  return nebula_destination(g, f.index)
	case .Ship, .None:
	}
	return sim.Destination{}
}

// Open the candidate table for a destination.
begin_planning :: proc(g: ^Game, t: f64, dest: sim.Destination) {
	g.planning = false
	g.plan_msg = ""
	if dest.kind == .None {
		g.plan_msg = "hover a body or station and choose Plot course"
		return
	}
	if g.ship.mode == .Docked {
		ask_undock_for(g, dest, {})
		return
	}
	geo, ok, reason := sim.geometry(&g.sys, &g.ship, dest)
	if !ok {
		g.plan_msg = reason
		return
	}
	res := sim.search(&g.sys, &g.ship, geo, t)
	if !res.ok {
		g.plan_msg = res.reason
		return
	}
	g.plan_geo = geo
	g.plan_res = res
	g.plan_dest = dest
	g.planning = true
}

// Go: plot to the destination and take the balanced direct route without asking.
go_to :: proc(g: ^Game, dest: sim.Destination, t: f64) {
	begin_planning(g, t, dest)
	if !g.planning do return
	choose_plan(g, plan_option_for(g, .Balanced), t)
	if g.ap.active do g.plan_msg = fmt.tprintf("on our way to %s (Orders > Choose a route for other options)", destination_name(g, dest))
}

// Open the orbit-at-altitude card for the body we are orbiting.
open_orbit_prompt :: proc(g: ^Game) {
	if g.ship.mode != .On_Rails { g.plan_msg = "the ship must be coasting to change orbit"; return }
	b := g.sys.bodies[g.ship.primary]
	alt := f32(orbit.length(g.ship.pos) - b.radius)
	g.orbit_prompt = ui.Orbit_Prompt{open = true, body = b.name, altitude = alt, current = alt, lo = f32(b.radius * 0.25), hi = f32(b.soi * 0.9 - b.radius)}
	if b.parent == gen.NONE do g.orbit_prompt.hi = f32(min(g.sys.extent, b.radius * 40))
}

// Fly route option `idx` from the current plan table.
choose_plan :: proc(g: ^Game, idx: int, t: f64) {
	if idx < 0 || idx >= g.plan_res.n_options do return
	o := g.plan_res.options[idx]
	if !o.cand.ok do return
	sim.autopilot_start(&g.sys, &g.ship, &g.ap, g.plan_geo, g.plan_dest, o.objective, o.cand, t, o.fb)
	g.planning = false
	g.selected = -1
}

// The direct route that wins objective `obj`, or the first direct route.
plan_option_for :: proc(g: ^Game, obj: sim.Objective) -> int {
	first := -1
	for k in 0 ..< g.plan_res.n_options {
		o := g.plan_res.options[k]
		if o.via != gen.NONE do continue
		if first < 0 do first = k
		if obj in o.tags do return k
	}
	return first
}

// Dev flags: "fuel|time|balanced|simplest" pick a direct route, "assist" the
// first gravity assist, a number the row itself.
plan_option_named :: proc(g: ^Game, name: string) -> int {
	switch name {
	case "fuel":     return plan_option_for(g, .Fuel)
	case "time":     return plan_option_for(g, .Time)
	case "balanced": return plan_option_for(g, .Balanced)
	case "simplest": return plan_option_for(g, .Simplest)
	case "assist":
		for k in 0 ..< g.plan_res.n_options do if g.plan_res.options[k].via != gen.NONE do return k
		return -1
	}
	n, ok := strconv.parse_int(name)
	return ok ? n - 1 : -1
}

// Rows for the plan table: direct routes, then a section per assist body.
plan_rows :: proc(g: ^Game, t: f64) -> []ui.Plan_Row {
	rows := make([dynamic]ui.Plan_Row, context.temp_allocator)
	names := sim.OBJECTIVE_NAMES
	last_via := gen.Body_Handle(-2)
	for k in 0 ..< g.plan_res.n_options {
		o := g.plan_res.options[k]
		c := o.cand
		tag := ""
		for obj in sim.Objective do if obj in o.tags do tag = tag == "" ? names[obj] : fmt.tprintf("%s, %s", tag, names[obj])
		row := ui.Plan_Row {
			ok = c.ok, fits = c.fits, dv = c.dv_total, burns = c.flyby ? 3 : 2,
			depart_in = c.t_depart - t, arrive_in = c.t_arrive - t,
			propellant = 100 * sim.propellant_after(&g.ship, c.dv_total) / g.ship.stats.propellant_cap,
		}
		if o.via == gen.NONE {
			row.name = fmt.tprintf("direct, %s", tag)
			if last_via != gen.NONE do row.section = "Direct"
		} else {
			row.name = fmt.tprintf("via %s, %s", g.sys.bodies[o.via].name, tag)
			if last_via == gen.NONE || last_via == -2 do row.section = "Gravity assists"
		}
		last_via = o.via
		append(&rows, row)
	}
	if last_via == gen.NONE || last_via == -2 {
		append(&rows, ui.Plan_Row{section = "Gravity assists", name = "none", note = "no assist body helps from here"})
	}
	return rows[:]
}

// A fresh game from the New game screen: clock reset, chosen hull, chosen galaxy.
start_game :: proc(g: ^Game, clock: ^core.Clock, params: gen.Galaxy_Params, class: econ.Class_Id) {
	ui.galaxy_map_release(&g.map_st)
	g.map_st = {}
	clock.t = 0
	clock.paused = false
	clock.warp_index = 0
	g.credits = 5000
	g.start_class = class
	g.request = .None
	g.market_open, g.yard_open, g.routes_open, g.map_open = false, false, false, false
	game_load_galaxy(g, params, 0)
}

// (Re)build the galaxy for a seed and enter its first system.
game_load_galaxy :: proc(g: ^Game, params: gen.Galaxy_Params, t: f64) {
	econ.galaxy_econ_destroy(&g.gecon)
	gen.galaxy_destroy(&g.galaxy)
	g.seed = params.seed
	g.galaxy = gen.galaxy_generate_with(params)
	g.gecon = {}
	econ.galaxy_econ_init(&g.gecon, &g.galaxy, t)
	g.map_sel = -1
	g.cryo_pending = -1
	ui.log_clear(&g.log)
	g.log_state = {}
	game_enter_system(g, 0, t)
}

// Make system `index` the active one: its markets run micro, its fleet exists.
game_enter_system :: proc(g: ^Game, index: int, t: f64) {
	gen.destroy(&g.sys)
	g.current = index
	econ.touch_neighbourhood(&g.gecon, index, t)
	econ.macro_advance(&g.gecon, index, t)
	se := &g.gecon.systems[index]
	g.sys = gen.generate(g.galaxy.systems[index].seed)
	g.econ = &se.econ
	gen.update(&g.sys, t)
	// Park the ship around the hub's host, or the star if there is no hub.
	host := gen.STAR
	if len(g.sys.stations) > 0 do host = g.sys.stations[0].parent
	sim.destroy(&g.ship)
	g.ship = sim.spawn_in_orbit(&g.sys, host, 0.3, t, sim.CLASSES[g.start_class].stats)
	g.ship.class = g.start_class
	g.ship.name = econ.CLASS_NAMES[g.start_class]
	// Nothing to park beside at a nebula site: start where a cryo arrival
	// would put you, just outside the cloud.
	if len(g.sys.stations) == 0 && len(g.sys.nebulae) > 0 do sim.arrive(&g.sys, &g.ship, t)
	g.focus = Focus{.Ship, 0}
	g.selected = -1
	g.warp_to = 0
	g.ap = {}
	g.planning = false
	g.econ.last_tick = t
	g.market_open = false
	g.shuttle = sim.Shuttle{market = -1}
	sim.skim_stop(&g.skim)
	sim.fleet_spawn(&g.fleet, &g.sys, g.econ, t)
	clear(&g.npc_anims)
}

// Follow an entity with the camera (Look at). Refocus returns to the ship.
look_at :: proc(g: ^Game, cam: ^render.Camera, f: Focus, t: f64) {
	if p, ok := entity_position(g, f, t); ok {
		cam.target = p
		cam.follow = true
		g.follow_target = f
	}
}

follow_ship :: proc(g: ^Game, cam: ^render.Camera) {
	g.follow_target = Focus{.Ship, 0}
	cam.follow = true
}

// Launch view: follow the ship, zoomed so its whole orbit is in frame.
camera_on_ship :: proc(cam: ^render.Camera, g: ^Game, t: f64) {
	g.focus = Focus{.Ship, 0}
	cam.follow = true
	p, _, _ := sim.state(&g.sys, &g.ship, t)
	render.camera_fit(cam, p, g.ship.orbit.a * 2.2)
}

focus_position :: proc(g: ^Game, t: f64) -> ([2]f64, bool) {
	return entity_position(g, g.focus, t)
}

entity_position :: proc(g: ^Game, f: Focus, t: f64) -> ([2]f64, bool) {
	switch f.kind {
	case .Body:    return g.sys.pos[f.index], true
	case .Station: return g.sys.station_pos[f.index], true
	case .Ship:
		p, _, _ := sim.state(&g.sys, &g.ship, t)
		return p, true
	case .Npc:
		if f.index < len(g.fleet.npcs) {
			p, _ := sim.npc_state(&g.sys, &g.fleet.npcs[f.index], t)
			return p, true
		}
	case .Nebula:
		if f.index < len(g.sys.nebulae) do return g.sys.pos[0] + gen.nebula_label_point(g.sys.nebulae[f.index]), true
	case .None:
	}
	return {}, false
}

entity_name :: proc(g: ^Game, f: Focus) -> string {
	switch f.kind {
	case .Body:    return g.sys.bodies[f.index].name
	case .Station: return g.sys.stations[f.index].name
	case .Ship:    return g.ship.name
	case .Npc:     if f.index < len(g.fleet.npcs) do return g.fleet.npcs[f.index].name
	case .Nebula:  if f.index < len(g.sys.nebulae) do return g.sys.nebulae[f.index].name
	case .None:
	}
	return "none"
}

// Flying "to" a cloud means flying into the thick of it, in the frame of
// whichever body's sphere that point falls in.
nebula_destination :: proc(g: ^Game, ni: int) -> sim.Destination {
	if ni < 0 || ni >= len(g.sys.nebulae) do return {}
	world := g.sys.pos[0] + gen.nebula_thickest(g.sys.nebulae[ni])
	frame := gen.primary_at(&g.sys, world)
	return sim.Destination{kind = .Point, index = int(frame), point = world - g.sys.pos[frame], label = g.sys.nebulae[ni].name}
}

// The station you can trade with right now: docked, or within docking range.
// The market you can trade at right now: the station you are docked at or
// within docking range of, or the colony whose body you are parked around.
trade_market :: proc(g: ^Game) -> (int, bool) {
	if g.ship.mode == .Docked && g.ship.docked_ship do return -1, false // a trader has no market
	station := -1
	if g.ship.mode == .Docked do station = g.ship.dock
	else if idx, ok := sim.dockable_station(&g.sys, &g.ship); ok do station = idx
	if station >= 0 {
		for &m, i in g.econ.markets do if m.station == station do return i, true
		return -1, false
	}
	for &m, i in g.econ.markets do if m.station < 0 && sim.at_colony(&g.sys, &g.ship, m.body) do return i, true
	return -1, false
}

focus_name :: proc(g: ^Game) -> string {
	switch g.focus.kind {
	case .Body:    return g.sys.bodies[g.focus.index].name
	case .Station: return g.sys.stations[g.focus.index].name
	case .Ship:    return g.ship.name
	case .Npc:     if g.focus.index < len(g.fleet.npcs) do return g.fleet.npcs[g.focus.index].name
	case .Nebula:  if g.focus.index < len(g.sys.nebulae) do return g.sys.nebulae[g.focus.index].name
	case .None:
	}
	return "none"
}

// Exact name first, then a case-insensitive substring match.
focus_by_name :: proc(g: ^Game, name: string) -> bool {
	for b, i in g.sys.bodies do if b.name == name { g.focus = Focus{.Body, i}; return true }
	for s, i in g.sys.stations do if s.name == name { g.focus = Focus{.Station, i}; return true }
	for n, i in g.sys.nebulae do if n.name == name { g.focus = Focus{.Nebula, i}; return true }
	needle := strings.to_lower(name, context.temp_allocator)
	for n, i in g.sys.nebulae do if strings.contains(strings.to_lower(n.name, context.temp_allocator), needle) { g.focus = Focus{.Nebula, i}; return true }
	for b, i in g.sys.bodies do if strings.contains(strings.to_lower(b.name, context.temp_allocator), needle) { g.focus = Focus{.Body, i}; return true }
	for s, i in g.sys.stations do if strings.contains(strings.to_lower(s.name, context.temp_allocator), needle) { g.focus = Focus{.Station, i}; return true }
	for &n, i in g.fleet.npcs do if strings.contains(strings.to_lower(n.name, context.temp_allocator), needle) { g.focus = Focus{.Npc, i}; return true }
	fmt.printfln("no body or station matches %q; stations are:", name)
	for s in g.sys.stations do fmt.printfln("  %s", s.name)
	return false
}

// Nearest body, station or ship within `px` of a screen point.
pick :: proc(g: ^Game, cam: ^render.Camera, mouse: [2]f32, t: f64, px: f32) -> (Focus, bool) {
	best := Focus{}
	best_d := px
	try :: proc(cam: ^render.Camera, mouse: [2]f32, p: [2]f64, extra: f32, f: Focus, best: ^Focus, best_d: ^f32) {
		s := render.world_to_screen(cam, p)
		d := math.sqrt((s.x - mouse.x) * (s.x - mouse.x) + (s.y - mouse.y) * (s.y - mouse.y)) - extra
		if d < best_d^ {
			best_d^ = d
			best^ = f
		}
	}
	sp, _, _ := sim.state(&g.sys, &g.ship, t)
	try(cam, mouse, sp, 0, Focus{.Ship, 0}, &best, &best_d)
	for &n, i in g.fleet.npcs {
		np, _ := sim.npc_state(&g.sys, &n, t)
		try(cam, mouse, np, 0, Focus{.Npc, i}, &best, &best_d)
	}
	station_px := render.station_radius_px(cam)
	for i in 0 ..< len(g.sys.stations) do try(cam, mouse, g.sys.station_pos[i], station_px, Focus{.Station, i}, &best, &best_d)
	for b, i in g.sys.bodies do try(cam, mouse, g.sys.pos[i], f32(b.radius * cam.zoom), Focus{.Body, i}, &best, &best_d)
	if best.kind != .None do return best, true
	// Labels count as the thing they name.
	m := rl.Vector2{mouse.x, mouse.y}
	if core.debug.show_labels {
		min_orbit := f64(core.tuning.label_min_orbit_px)
		for b, i in g.sys.bodies {
			if i == 0 || b.orbit.a * cam.zoom < min_orbit do continue
			if rl.CheckCollisionPointRec(m, render.body_label_rect(cam, b, g.sys.pos[i])) do return Focus{.Body, i}, true
		}
		for s, i in g.sys.stations {
			if s.parent != gen.STAR && s.orbit.a * cam.zoom < min_orbit do continue
			if rl.CheckCollisionPointRec(m, render.station_label_rect(cam, s, g.sys.station_pos[i])) do return Focus{.Station, i}, true
		}
		for n, i in g.sys.nebulae {
			if n.radius * cam.zoom < 40 do continue
			if rl.CheckCollisionPointRec(m, render.nebula_label_rect(cam, n, g.sys.pos[0])) do return Focus{.Nebula, i}, true
		}
	}
	// Last of all, the gas itself: hovering empty cloud picks the cloud, but
	// only once nothing solid has claimed the cursor.
	if idx, _ := gen.nebula_at(&g.sys, render.screen_to_world(cam, mouse)); idx >= 0 {
		return Focus{.Nebula, idx}, true
	}
	return best, false
}

// Dev: how many systems of the galaxy hold a cloud.
count_nebulae :: proc(g: ^Game) -> (n: int) {
	for s in g.galaxy.systems do if s.nebula do n += 1
	return
}

main :: proc() {
	opts := parse_opts()
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(1280, 800, "space-sim")
	defer rl.CloseWindow()
	text.load()
	defer text.unload()
	rl.SetWindowMinSize(640, 400)
	rl.SetTargetFPS(120)
	rl.SetExitKey(.KEY_NULL)
	rlgl.DisableBackfaceCulling() // .fart polys carry no winding guarantee
	audio.init()
	defer audio.shutdown()
	cfg := settings.load()
	settings.apply_all(cfg)

	lib: art.Library
	art.library_init(&lib, "assets")
	defer art.library_destroy(&lib)
	art.library_load(&lib, "star", "bodies/star.fart")
	for kind, n in ([?]struct { name: string, count: int }{{"molten", 2}, {"rock", 3}, {"atmospheric", 3}, {"gas", 3}, {"ice", 2}, {"moon", 2}}) {
		for v in 0 ..< kind.count {
			name := fmt.aprintf("%s_%d", kind.name, v)
			art.library_load(&lib, name, fmt.tprintf("bodies/%s.fart", name))
		}
		_ = n
	}
	for kind in ([?]string{"hub", "shipyard", "refinery", "depot", "habitat"}) {
		name := fmt.aprintf("station_%s", kind)
		art.library_load(&lib, name, fmt.tprintf("stations/%s.fart", name))
	}
	art.library_load(&lib, "courier", "ships/courier.fart")
	art.library_load(&lib, "hauler", "ships/hauler.fart")
	art.library_load(&lib, "clipper", "ships/clipper.fart")
	art.library_load(&lib, "freighter", "ships/freighter.fart")
	art.library_load(&lib, "sleeper", "ships/sleeper.fart")
	art.library_load(&lib, "icon", "ui/fastart_icon.fart")
	render.avatar_load(&lib)

	clock := core.Clock{warp_index = opts.warp > 0 ? min(opts.warp, len(core.WARP_LEVELS) - 1) : 0, t = opts.time}
	g: Game
	g.credits = 5000
	g.vendor_station = -1
	g.auto_time = true
	g.auto_dock = true
	g.auto_ceiling = 5 // one day per second
	defer notices_destroy(&g)
	defer ui.log_destroy(&g.log)
	defer delete(g.contracts)
	if d, ok := people.dialog_load(); ok do g.dialog = d
	else do fmt.println("dialog: assets/dialog/lines.json missing, people will be quiet")
	defer people.dialog_destroy(&g.dialog)
	defer talk_close(&g)
	// Dev flags start straight into a game; otherwise the start menu shows.
	direct := opts.play || opts.screenshot != "" || opts.dest != "" || opts.stars || opts.nebulae || opts.skim || opts.cryo != 0 || opts.map_sel != 0 ||
		opts.waypoint != "" || opts.hover != "" || opts.market || opts.contacts || opts.node != "" || opts.doom || opts.system > 0 || opts.seed != 1
	if opts.title != "" do direct = opts.play // a menu screenshot starts without a game unless asked
	has_game := direct
	if direct do game_load_galaxy(&g, gen.Galaxy_Params{seed = opts.seed, systems = gen.GALAXY_SYSTEMS}, clock.t)
	if opts.stars {
		fmt.printfln("galaxy seed %d: %v, %d systems", g.seed, g.galaxy.kind, len(g.galaxy.systems))
		for s, i in g.galaxy.systems do fmt.printfln("%3d %-14s %-28s %.2f Msol  L %.3g  heat %.0f  wind %.0f", i, s.name, gen.star_describe(s.star), s.star.mass, s.star.luminosity, s.star.heat_radius, s.star.wind_radius)
		return
	}
	if opts.nebulae {
		sites := 0
		fmt.printfln("galaxy seed %d: %v, %d systems", g.seed, g.galaxy.kind, len(g.galaxy.systems))
		for s, i in g.galaxy.systems {
			if !s.nebula do continue
			if s.is_site do sites += 1
			sys := gen.generate(s.seed)
			n := sys.nebulae[0]
			fmt.printfln("%3d %-14s %-20s %-22s radius %8.0f hollow %8.0f density %.2f  %s", i, s.name, gen.star_describe(s.star), gen.nebula_describe(s.neb_kind), n.radius, n.hollow, n.density, s.is_site ? "SITE" : "")
			gen.destroy(&sys)
		}
		fmt.printfln("%d nebulae, %d of them destinations of their own", count_nebulae(&g), sites)
		return
	}
	if opts.system > 0 && opts.system < len(g.galaxy.systems) do game_enter_system(&g, opts.system, clock.t)
	if opts.doom {
		g.ship.primary = gen.STAR
		g.ship.mode = .On_Rails
		g.ship.pos = {g.sys.star.radius * 4, 0}
		g.ship.vel = {0, 1e-6}
		g.ship.orbit = orbit.from_state(g.ship.pos, g.ship.vel, g.sys.bodies[0].mu, clock.t)
		sim.repredict(&g.sys, &g.ship, clock.t)
	}
	if opts.cryo == -2 do opts.cryo = gen.neighbours(&g.galaxy, g.current)[0]
	if opts.cryo > 0 && opts.cryo < len(g.galaxy.systems) {
		g.map_sel = opts.cryo
		g.ship.mode = .On_Rails
		g.ship.primary = gen.STAR
		g.ship.orbit.e = 1.5 // pretend we are escaping
		begin_cryo(&g, &clock, clock.t, true)
	}
	if opts.map_sel > 0 || opts.map_sel == -2 {
		g.map_open = true
		g.map_sel = opts.map_sel == -2 ? gen.neighbours(&g.galaxy, g.current)[0] : opts.map_sel
		if opts.mapzoom > 1 {
			g.map_st.inited = true
			g.map_st.zoom = opts.mapzoom
			g.map_st.center = {f32(g.galaxy.systems[g.current].pos.x), f32(g.galaxy.systems[g.current].pos.y)}
		}
		if opts.jump {
			request_jump(&g, &clock, clock.t)
			if g.planning && opts.objective != "" do choose_plan(&g, plan_option_named(&g, opts.objective), clock.t)
		}
	}
	if opts.waypoint != "" {
		parts := strings.split(opts.waypoint, ",", context.temp_allocator)
		if len(parts) == 2 {
			dx, _ := strconv.parse_f64(parts[0])
			dy, _ := strconv.parse_f64(parts[1])
			when ODIN_DEBUG do fmt.printfln("waypoint flag: %v,%v planning=%v", dx, dy, g.planning)
			plan_to_point(&g, g.sys.pos[g.ship.primary] + {dx, dy}, clock.t)
			when ODIN_DEBUG do fmt.printfln("after plan_to_point: planning=%v msg=%s", g.planning, g.plan_msg)
			if g.planning && opts.objective != "" do choose_plan(&g, plan_option_named(&g, opts.objective), clock.t)
		}
	}
	if opts.hover != "" && focus_by_name(&g, opts.hover) {
		g.pin = g.focus
		g.pin_grace = 1e9
		g.focus = Focus{.Ship, 0}
	}
	if opts.colony {
		for &m, i in g.econ.markets do if econ.is_colony(&m) {
			sim.destroy(&g.ship)
			g.ship = sim.spawn_in_orbit(&g.sys, m.body, 0.15, clock.t, sim.CLASSES[g.start_class].stats)
			g.ship.class = g.start_class
			g.ship.cargo[int(econ.Commodity.Ore)] = 8
			g.market_open = true
			g.market_station = i
			sim.shuttle_reset(&g.shuttle, i, m.body)
			sim.shuttle_order(&g.shuttle, .Ore, -8)
			sim.shuttle_order(&g.shuttle, .Food, 6)
			g.pin = Focus{.Body, int(m.body)}
			g.pin_grace = 1e9
			break
		}
	}
	if opts.skim && len(g.sys.nebulae) > 0 {
		// Drop the ship in the thick of the first cloud with the scoop out.
		world := g.sys.pos[0] + gen.nebula_thickest(g.sys.nebulae[0])
		sim.destroy(&g.ship)
		g.ship = sim.spawn_at_point(&g.sys, world, clock.t, sim.CLASSES[g.start_class].stats)
		g.ship.class = g.start_class
		g.ship.name = econ.CLASS_NAMES[g.start_class]
		if ok, why := sim.skim_start(&g.sys, &g.ship, &g.skim, clock.t); !ok do fmt.printfln("--skim: %s", why)
		g.pin = Focus{.Nebula, 0}
		g.pin_grace = 1e9
	}
	if opts.jobs {
		if len(g.sys.stations) > 0 do sim.dock(&g.sys, &g.ship, 0, clock.t)
		econ.boards_refresh(g.econ, &g.sys, clock.t)
		g.jobs_open = true
		g.jobs_board = true
		// Hold one contract already so the list has something in it.
		if len(g.econ.boards) > 0 && len(g.econ.boards[0].jobs) > 0 do contract_accept(&g, g.econ.boards[0].jobs[0].id)
		notices_destroy(&g)
		g.notices = {}
	}
	if opts.orbit_at > 0 {
		open_orbit_prompt(&g)
		g.orbit_prompt.altitude = f32(opts.orbit_at)
		if opts.orbit_go {
			g.orbit_prompt.open = false
			sim.order_orbit_at(&g.sys, &g.ship, &g.order, opts.orbit_at + g.sys.bodies[g.ship.primary].radius, clock.t)
		}
	}
	if opts.market {
		// Dev: dock at the first station so the market has a vendor to show.
		if len(g.sys.stations) > 0 do sim.dock(&g.sys, &g.ship, 0, clock.t)
		g.market_open = true
	}
	switch opts.talk {
	case "vendor": if len(g.sys.stations) > 0 do talk_open(&g, .Station, 0, "greeting", clock.t)
	case "pilot":  if len(g.fleet.npcs) > 0 do talk_open(&g, .Npc, 0, "greeting", clock.t)
	case "trade":
		// The first trader with cargo aboard, so the trade has something on the table.
		pick := 0
		for &n, i in g.fleet.npcs do if sim.cargo_used(&n.ship) > 0 { pick = i; break }
		if len(g.fleet.npcs) > 0 { talk_open(&g, .Npc, pick, "greeting", clock.t); talk_choose(&g, .Trade, 1, clock.t) }
	}
	if opts.contacts {
		g.contacts.open = true
		g.contacts.expanded = make(map[u64]bool)
		for c in build_contacts(&g, clock.t) do if c.has_children do g.contacts.expanded[u64(c.kind) << 48 | u64(c.index)] = true
	}
	defer if has_game {
		gen.destroy(&g.sys)
		sim.destroy(&g.ship)
		ui.contacts_destroy(&g.contacts)
		econ.galaxy_econ_destroy(&g.gecon)
		gen.galaxy_destroy(&g.galaxy)
		sim.fleet_destroy(&g.fleet)
		delete(g.npc_anims)
	}
	focus_requested := opts.focus != "" && focus_by_name(&g, opts.focus)
	if opts.burn { g.ship.hold = .Prograde; g.ship.throttle = 1 }
	if opts.flyby do stage_flyby(&g, clock.t)
	g.autowarp = opts.autowarp
	if opts.warpcap > 0 do core.tuning.warp_max_thrusting = f32(opts.warpcap)
	done_frames := 0
	if opts.dest != "" && focus_by_name(&g, opts.dest) {
		begin_planning(&g, clock.t, destination_of(&g, g.focus))
		if g.planning && opts.objective != "" do choose_plan(&g, plan_option_named(&g, opts.objective), clock.t)
		g.focus = Focus{.Ship, 0}
	}
	if opts.node != "" {
		parts := strings.split(opts.node, ",", context.temp_allocator)
		if len(parts) == 3 {
			n: sim.Node
			n.t, _ = strconv.parse_f64(parts[0])
			n.prograde, _ = strconv.parse_f64(parts[1])
			n.radial, _ = strconv.parse_f64(parts[2])
			n.t += clock.t
			g.selected = sim.node_add(&g.ship, n)
			sim.repredict(&g.sys, &g.ship, clock.t)
			if opts.execute {
				sim.arm_node(&g.ship, g.selected)
				if start, ok := sim.autoburn_start(&g.ship); ok do g.warp_to = start
			}
		}
	}

	cam := render.Camera{}
	if has_game do camera_on_ship(&cam, &g, clock.t)
	if opts.overview {
		render.camera_fit(&cam, 0, g.sys.extent)
		cam.follow = false
	}
	if focus_requested {
		focus_by_name(&g, opts.focus) // the launch camera reset the focus to the ship
		cam.follow = true
		if p, ok := focus_position(&g, clock.t); ok {
			radius := 200.0
			if g.focus.kind == .Body do radius = g.sys.bodies[g.focus.index].radius * 8
			render.camera_fit(&cam, p, radius)
		}
	}
	if opts.zoom > 0 do cam.zoom = opts.zoom
	if opts.angle != 0 do cam.angle = opts.angle * math.PI / 180
	g.heading_lock = opts.headlock
	sf: render.Starfield
	neb_art: render.Nebula_Art
	defer render.nebula_art_destroy(&neb_art)
	render.starfield_init(&sf, 0xC0FFEE)
	sky: render.Menu_Sky // the start menu's backdrop
	defer render.menu_sky_release(&sky)
	fx: render.Effects
	defer render.effects_destroy(&fx)
	defer ui.galaxy_map_release(&g.map_st)
	ship_alive := true
	// The start menu, shown until a game begins and whenever the System
	// menu asks for it.
	title: ui.Title_State
	app_title := !has_game
	slot_cards: [save.SLOTS + 1]ui.Slot_Card
	slots_dirty := true
	title_cam := render.Camera{zoom = 1}
	quit := false
	random_seed := u64(time.time_to_unix(time.now())) % 1_000_000_007
	switch opts.title {
	case "new":      title.screen = .New_Game
	case "load":     title.screen = .Slots
	case "save":     title.screen = .Slots; title.saving = true
	case "settings": title.screen = .Settings
	case "controls": title.screen = .Settings; title.tab = 3
	case "sound":    title.screen = .Settings; title.tab = 2
	}
	if opts.title != "" || opts.avatars do app_title = true
	if opts.ticks do g.mb.tick_open = true
	panel := ui.Debug_Panel{open = opts.panel}
	g.mb.open = opts.menu - 1
	ui_hot := false
	regen := false
	last_stage := sim.Stage.Idle
	last_status := ""
	perf_worst, perf_total: f64
	perf_over: int
	sim_worst, sim_total, draw_worst, draw_total: f64
	frame_start: time.Tick
	sim_end: time.Tick
	part_worst: [5]f64 // ship, fleet, econ, galaxy, other
	part_names := [5]string{"ship", "fleet", "econ", "galaxy", "other"}
	lap :: proc(mark: ^time.Tick, slot: ^f64) {
		now := time.tick_now()
		ms := time.duration_milliseconds(time.tick_diff(mark^, now))
		slot^ = max(slot^, ms)
		mark^ = now
	}
	frame := 0

	for !rl.WindowShouldClose() && !quit {
		frame += 1
		if app_title && opts.screenshot != "" && frame > opts.frames {
			img := rl.LoadImageFromScreen()
			rl.ExportImage(img, strings.clone_to_cstring(opts.screenshot, context.temp_allocator))
			rl.UnloadImage(img)
			break
		}
		if app_title {
			audio.update()
			// A slow pan under the menu sky: the field should read as drifting,
			// not as travelling.
			title_cam.target.x += 12 * f64(rl.GetFrameTime())
			if slots_dirty {
				for &c in slot_cards do delete(c.system)
				infos := save.list_slots(context.allocator)
				for inf, i in infos do slot_cards[i] = ui.Slot_Card{exists = inf.exists, system = inf.system_name, ship = inf.ship, credits = inf.credits, t = inf.t, saved_at = inf.saved_at, version_ok = inf.version_ok}
				slots_dirty = false
			}
			rl.BeginDrawing()
			rl.ClearBackground({5, 7, 12, 255})
			if opts.avatars {
				render.draw_starfield(&sf, &title_cam)
				// Dev: a sheet of faces, seeds in reading order.
				cols := 8
				for k in 0 ..< 40 {
					av := render.avatar_make(u64(k) + 1000 * u64(opts.seed))
					x := 90 + f32(k % cols) * 140
					y := 90 + f32(k / cols) * 140
					render.avatar_draw(&lib, av, {x, y}, 3.4)
				}
				rl.EndDrawing()
				free_all(context.temp_allocator)
				continue
			}
			render.menu_sky_update(&sky, rl.GetFrameTime())
			render.menu_sky_draw(&sky, &sf, &title_cam, &lib)
			act, slot := ui.title_draw(&title, ui.Title_View{lib = &lib, slots = slot_cards[:], settings = &cfg, has_game = has_game, seed_hint = random_seed})
			switch act {
			case .None:
			case .Resume:
				app_title = false
			case .Start_Game:
				params, class := ui.title_new_game_params(&title, random_seed)
				start_game(&g, &clock, params, class)
				camera_on_ship(&cam, &g, clock.t)
				has_game = true
				app_title = false
				panel.open = false
				title.screen = .Home
			case .Load_Slot:
				if load_game(&g, &clock, slot) {
					camera_on_ship(&cam, &g, clock.t)
					has_game = true
					app_title = false
					title.screen = .Home
				} else {
					title.msg = "that save could not be read"
				}
			case .Save_Slot:
				title.msg = save_game(&g, clock.t, slot) ? fmt.tprintf("saved to %s", slot == 0 ? "the quick slot" : fmt.tprintf("slot %d", slot)) : "save failed"
				slots_dirty = true
			case .Quit:
				quit = true
			case .Settings_Live:
				settings.apply_graphics(cfg)
				settings.apply_sound(cfg)
			case .Settings_Apply:
				settings.capture_controls(&cfg)
				settings.apply_all(cfg)
				settings.save(cfg)
			case .Settings_Closed:
				settings.capture_controls(&cfg)
				settings.apply_graphics(cfg)
				settings.apply_sound(cfg)
				settings.save(cfg)
			}
			rl.EndDrawing()
			free_all(context.temp_allocator)
			continue
		}
		if opts.until_done && !g.ap.active && g.ap.stage != .Idle do done_frames += 1
		if opts.until_done && g.order.kind != .None && !sim.order_active(&g.order) do done_frames += 1
		if opts.until_dead && g.ship.mode == .Destroyed do done_frames += 1
		if opts.screenshot != "" && ((opts.until_done || opts.until_dead) ? done_frames > (opts.until_dead ? 4 : 30) : frame > opts.frames) {
			if opts.perf {
				n := f64(max(frame - 5, 1))
				fmt.printfln("frames: mean %.2f ms, worst %.1f ms, %d frames over 33 ms of %d (includes vsync wait)", perf_total / n, perf_worst, perf_over, frame - 5)
				fmt.printfln("work: sim mean %.2f ms worst %.1f ms | draw mean %.2f ms worst %.1f ms", sim_total / n, sim_worst, draw_total / n, draw_worst)
				for name, k in part_names do fmt.printfln("  worst %s: %.1f ms", name, part_worst[k])
			}
			if opts.trace {
				for &n in g.fleet.npcs {
					fmt.printfln("npc %-28s state=%v mode=%v primary=%s trades=%d transitions=%d ap=%v/%s", n.name, n.state, n.ship.mode, g.sys.bodies[n.ship.primary].name, n.trades, n.ship.transitions, n.ap.stage, n.ap.status)
				}
			}
			img := rl.LoadImageFromScreen()
			rl.ExportImage(img, strings.clone_to_cstring(opts.screenshot, context.temp_allocator))
			rl.UnloadImage(img)
			break
		}
		real_dt := f64(rl.GetFrameTime())
		frame_start = time.tick_now()
		if opts.perf && frame > 5 {
			ms := real_dt * 1000
			perf_total += ms
			perf_worst = max(perf_worst, ms)
			if ms > 33 do perf_over += 1
		}
		art.library_poll(&lib, real_dt)
		audio.update()
		if g.request != .None {
			#partial switch g.request {
			case .Save_Slots: title.screen = .Slots; title.saving = true; slots_dirty = true
			case .Load_Slots: title.screen = .Slots; title.saving = false; slots_dirty = true
			case .Settings:   title.screen = .Settings
			case .Main_Menu:  title.screen = .Home
			}
			title.msg = ""
			g.request = .None
			g.mb.open = -1
			app_title = true
			audio.play(.Open)
		}

		// ---- input
		if input.pressed(.Pause) do clock.paused = !clock.paused
		if input.pressed(.Warp_Up) do core.clock_warp_up(&clock)
		if input.pressed(.Warp_Down) do core.clock_warp_down(&clock)
		if input.pressed(.Follow_Ship) do follow_ship(&g, &cam)
		if input.pressed(.Debug_Panel) do panel.open = !panel.open
		if input.pressed(.Cycle_Focus) do apply_action(&g, &cam, &clock, &panel, &regen, .Cycle_Focus, clock.t)
		if input.pressed(.Frame_System) {
			render.camera_fit(&cam, 0, g.sys.extent)
			cam.follow = false
		}
		if input.pressed(.Regenerate) do regen = true
		if input.pressed(.Dock) do apply_action(&g, &cam, &clock, &panel, &regen, .Dock, clock.t)
		if input.pressed(.Market) do apply_action(&g, &cam, &clock, &panel, &regen, .Market_Window, clock.t)
		if input.pressed(.Shipyard) do apply_action(&g, &cam, &clock, &panel, &regen, .Shipyard_Window, clock.t)
		if input.pressed(.Galaxy_Map) do apply_action(&g, &cam, &clock, &panel, &regen, .Galaxy_Map, clock.t)
		if input.pressed(.Quick_Save) do apply_action(&g, &cam, &clock, &panel, &regen, .Save_Game, clock.t)
		if input.pressed(.Quick_Load) do apply_action(&g, &cam, &clock, &panel, &regen, .Load_Game, clock.t)
		if input.pressed(.Undock) do apply_action(&g, &cam, &clock, &panel, &regen, .Undock, clock.t)
		flight_input(&g.ship, real_dt, opts.turn)
		if !ui_hot do rcs_input(&g, &cam, clock.t)
		node_input(&g, &cam, clock.t, real_dt, ui_hot)
		plan_input(&g, clock.t)
		if !ui_hot && rl.IsMouseButtonPressed(.LEFT) && g.point_mode {
			m := rl.GetMousePosition()
			g.point_mode = false
			plan_to_point(&g, render.screen_to_world(&cam, {m.x, m.y}), clock.t)
		}
		// Hover: the entity under the mouse when no window has it.
		g.hover = Focus{}
		if !ui_hot && !g.point_mode {
			m := rl.GetMousePosition()
			if f, ok := pick(&g, &cam, {m.x, m.y}, clock.t, 14); ok do g.hover = f
		}
		if g.hover.kind != .None {
			g.pin = g.hover
			g.pin_grace = 0.25
		} else if g.pin.kind != .None {
			m := rl.GetMousePosition()
			if rl.CheckCollisionPointRec(m, g.pin_rect) {
				g.pin_grace = 0.25
			} else {
				if opts.screenshot == "" do g.pin_grace -= real_dt
				if g.pin_grace <= 0 do g.pin = Focus{}
			}
		}
		if g.point_mode && rl.IsKeyPressed(.ESCAPE) do g.point_mode = false
		if regen {
			regen = false
			game_load_galaxy(&g, g.galaxy.params, clock.t)
			camera_on_ship(&cam, &g, clock.t)
		}
		if g.cryo.active {
			cryo_step(&g, &clock)
			gen.update(&g.sys, clock.t)
			rl.BeginDrawing()
			rl.ClearBackground({5, 7, 12, 255})
			total := (g.cryo.t_arrive - g.cryo.t_start) / core.SECONDS_PER_YEAR
			done := (clock.t - g.cryo.t_start) / core.SECONDS_PER_YEAR
			dest_name := g.galaxy.systems[g.cryo.dest].name
			ui.cryo_screen_draw(ui.Cryo_View{from = g.cryo.from, to = dest_name, progress = clamp(done / max(total, 1e-9), 0, 1), years = done, total = total, notes = "Every known economy keeps trading while you sleep.\nPrices you remember will not be the prices you find."})
			rl.EndDrawing()
			free_all(context.temp_allocator)
			continue
		}
		cap: f64 = 1e300
		// A predicted impact within reach slows time so the player can react.
		if seg, has := sim.next_event(&g.ship); has && seg.end == .Collide {
			lead := seg.t1 - clock.t
			if lead < 900 do cap = min(cap, max(lead / (real_dt * 120), 1))
		}
		if g.ship.throttle > 0 && !sim.is_dead(&g.ship) {
			// Hand-flown burns need a controllable warp; autoburns only need
			// the integrator to keep up.
			cap = f64(g.ship.autoburn.active ? core.tuning.warp_max_autoburn : core.tuning.warp_max_thrusting)
		}
		t_prev := clock.t
		game_dt: f64
		held := clock.paused || len(g.notices) > 0 // a notice stops the clock until answered
		if g.warp_to > clock.t && !held {
			// Warp-to: as fast as allowed, but never past the target. Auto time
			// treats the chosen step as its ceiling; a deliberate skip goes flat out.
			warp := min(core.WARP_LEVELS[len(core.WARP_LEVELS) - 1], (g.warp_to - clock.t) / max(real_dt, 1e-6))
			if g.warp_auto do warp = min(warp, g.warp_rate)
			game_dt = core.clock_advance_warp(&clock, real_dt, min(warp, cap))
			if clock.t >= g.warp_to - 1e-6 {
				g.warp_to = 0
				g.warp_auto = false
			}
		} else if g.auto_time && g.ap.active && !held {
			// Between warp-tos (burns, docking): auto time still runs as fast as the burn cap allows.
			g.warp_to = 0
			g.warp_auto = false
			game_dt = core.clock_advance_warp(&clock, real_dt, min(core.WARP_LEVELS[clamp(g.auto_ceiling, 0, len(core.WARP_LEVELS) - 1)], cap))
		} else {
			g.warp_to = 0
			g.warp_auto = false
			game_dt = held ? 0 : core.clock_advance(&clock, real_dt, cap)
		}

		// ---- simulate
		mark := time.tick_now()
		g.clock_t = clock.t
		sim.update(&g.sys, &g.ship, t_prev, game_dt)
		gen.update(&g.sys, clock.t)
		sim.autopilot_update(&g.sys, &g.ship, &g.ap, clock.t)
		lap(&mark, &part_worst[0])
		sim.fleet_update(&g.fleet, &g.sys, g.econ, t_prev, game_dt)
		lap(&mark, &part_worst[1])
		ride_host(&g, clock.t)
		sim.shuttle_step(&g.sys, g.econ, &g.ship, &g.shuttle, &g.credits, game_dt)
		sim.skim_step(&g.sys, &g.ship, &g.skim, game_dt)
		{
			was := g.order.stage
			sim.order_update(&g.sys, &g.ship, &g.order, clock.t)
			if was != g.order.stage && g.order.stage == .Done do notice_push(&g, .Info, "In orbit", fmt.tprintf("Circular orbit %.1f above %s.", orbit.length(g.ship.pos) - g.sys.bodies[g.ship.primary].radius, g.sys.bodies[g.ship.primary].name))
			if was != g.order.stage && g.order.stage == .Failed do notice_push(&g, .Info, "Order failed", g.order.status)
		}
		// Automatic docking: in range at matched speed, not just after casting off.
		if g.auto_dock && !g.ap.active && g.ship.mode == .On_Rails && clock.t - g.undocked_at > core.SECONDS_PER_HOUR {
			if idx, ok := sim.dockable_station(&g.sys, &g.ship); ok {
				sim.dock(&g.sys, &g.ship, idx, clock.t)
				g.selected = -1
				g.order = {}
			}
		}
		if g.ap.active && g.ap.dest.kind == .Npc && g.ap.dest.index < len(g.fleet.npcs) {
			// A moving target: keep the plan aimed at where the trader is coasting now.
			if h := &g.fleet.npcs[g.ap.dest.index].ship; h.mode == .On_Rails && h.primary == g.ap.dest.primary {
				g.ap.dest.orbit = h.orbit
				g.ap.geo.npc_orbit = h.orbit
			}
		}
		// Destruction plays once, where the ship was.
		if g.ship.mode == .Destroyed && ship_alive {
			ship_alive = false
			render.explosion_spawn(&fx, g.sys.pos[g.ship.primary] + g.ship.pos, sim.CLASSES[g.ship.class].stats.mass_dry * 0.15)
		} else if g.ship.mode != .Destroyed {
			ship_alive = true
		}
		for &n in g.fleet.npcs {
			if n.ship.mode == .Destroyed && !n.exploded {
				n.exploded = true
				render.explosion_spawn(&fx, g.sys.pos[n.ship.primary] + n.ship.pos, sim.CLASSES[n.ship.class].stats.mass_dry * 0.12)
			} else if n.ship.mode != .Destroyed {
				n.exploded = false
			}
		}
		econ.update(g.econ, clock.t)
		econ.boards_refresh(g.econ, &g.sys, clock.t)
		contracts_update(&g, clock.t)
		hazard_check(&g)
		arrival_check(&g, clock.t)
		hail_check(&g, clock.t)
		log_update(&g, clock.t)
		lap(&mark, &part_worst[2])
		g.gecon.systems[g.current].last_t = clock.t
		econ.galaxy_advance(&g.gecon, clock.t, g.current)
		lap(&mark, &part_worst[3])
		docked_now := g.ship.mode == .Docked
		if docked_now && !g.was_docked do g.market_open = true
		g.was_docked = docked_now
		if opts.trace && (g.ap.stage != last_stage || g.ap.status != last_status || frame % 600 == 0) {
			last_stage, last_status = g.ap.stage, g.ap.status
			fmt.printfln("[t=%s] stage=%v status=%s mode=%v primary=%s nodes=%d armed=%v warp_to=%.0f warp=%v planning=%v msg=%s",
				core.clock_format(clock.t), g.ap.stage, g.ap.status, g.ship.mode, g.sys.bodies[g.ship.primary].name, len(g.ship.nodes), g.ship.autoburn.active, g.warp_to, core.clock_warp_label(&clock), g.planning, g.plan_msg)
		}
		if (g.auto_time || g.autowarp) && g.warp_to == 0 && !clock.paused && len(g.notices) == 0 && (g.ap.active || sim.order_active(&g.order)) {
			until, ok := sim.autopilot_wait_until(&g.ship, &g.ap, clock.t)
			if !ok && sim.order_active(&g.order) {
				if start, has := sim.autoburn_start(&g.ship); has && start > clock.t + 5 do until, ok = start, true
			}
			if ok {
				g.warp_to = until
				g.warp_auto = !g.autowarp
				// Pace the leg by its length: it takes at least auto_leg_seconds of
				// real time, so a short hop is watched rather than skipped, and
				// never faster than the ceiling.
				ceiling := core.WARP_LEVELS[clamp(g.auto_ceiling, 0, len(core.WARP_LEVELS) - 1)]
				g.warp_rate = min(ceiling, max((until - clock.t) / f64(max(core.tuning.auto_leg_seconds, 1)), 1))
			}
		}
		ship_pos, _, ship_heading := sim.state(&g.sys, &g.ship, clock.t)
		if input.pressed(.Heading_Lock) do g.heading_lock = !g.heading_lock
		if g.heading_lock {
			if input.down(.Rotate_Left) || input.down(.Rotate_Right) do g.heading_lock = false // a manual turn takes over
			else do render.camera_face(&cam, ship_heading)
		}
		ship_state := g.ship.mode == .Thrusting ? "burn" : (g.ship.mode == .Docked ? "docked" : "idle")

		if cam.follow {
			if g.follow_target.kind == .None do g.follow_target = Focus{.Ship, 0}
			if p, ok := entity_position(&g, g.follow_target, clock.t); ok do cam.target = p
			else do follow_ship(&g, &cam)
		}
		// Screenshot runs ignore camera input so captures are deterministic.
		render.camera_update(&cam, real_dt, ui_hot || opts.screenshot != "")

		sim_end = time.tick_now()
		if opts.perf && frame > 5 {
			ms := time.duration_milliseconds(time.tick_diff(frame_start, sim_end))
			sim_total += ms
			sim_worst = max(sim_worst, ms)
		}
		// ---- draw
		rl.BeginDrawing()
		rl.ClearBackground({5, 7, 12, 255})
		render.draw_starfield(&sf, &cam)
		render.draw_nebulae(&cam, &g.sys, &neb_art)
		render.draw_system(&cam, &g.sys, &lib, clock.t)
		if core.debug.show_routes {
			focus_station := g.pin.kind == .Station ? g.pin.index : -1
			focus_body := g.pin.kind == .Body ? gen.Body_Handle(g.pin.index) : gen.NONE
			render.draw_routes(&cam, &g.sys, g.econ, g.fleet.routes, focus_station, focus_body)
		}
		if core.debug.show_predict do render.draw_prediction(&cam, &g.sys, g.ship.segments[:], g.ship.nodes[:], g.selected, clock.t)
		if len(g.npc_anims) != len(g.fleet.npcs) do resize(&g.npc_anims, len(g.fleet.npcs))
		for &n, i in g.fleet.npcs {
			hidden := n.ship.mode == .Destroyed ||
				(n.ship.mode == .Docked && !(g.pin.kind == .Npc && g.pin.index == i)) // inside the station
			if hidden {
				g.npc_anims[i].tracking = false // pick its heading up again when it comes back
				continue
			}
			doc := art.library_get(&lib, sim.CLASSES[n.ship.class].art)
			if doc == nil do continue
			np, nh := sim.npc_state(&g.sys, &n, clock.t)
			ov := [1]art.Override{{"hull", n.tint}}
			px := render.doc_min_px_per_unit(doc, f64(core.tuning.ship_min_px) * 0.8)
			anim := &g.npc_anims[i]
			render.ship_anim_update(anim, &n.ship, nh, real_dt)
			if pose := render.ship_anim_pose(doc, anim); pose != nil {
				render.draw_poses_world(&cam, doc, pose, np, nh, core.SHIP_DOC_SCALE, px, ov[:])
			} else {
				render.draw_doc_world(&cam, doc, n.ship.mode == .Thrusting ? "burn" : "idle", np, nh, core.SHIP_DOC_SCALE, px, ov[:])
			}
		}
		if ship := art.library_get(&lib, sim.CLASSES[g.ship.class].art); ship != nil && g.ship.mode != .Destroyed {
			px := render.doc_min_px_per_unit(ship, f64(core.tuning.ship_min_px))
			render.ship_anim_update(&g.ship_anim, &g.ship, ship_heading, real_dt)
			// A hull with no clips (an older document, mid hot-reload) is
			// still drawn, by the state its mode names.
			if pose := render.ship_anim_pose(ship, &g.ship_anim); pose != nil {
				render.draw_poses_world(&cam, ship, pose, ship_pos, ship_heading, core.SHIP_DOC_SCALE, px)
			} else {
				render.draw_doc_world(&cam, ship, ship_state, ship_pos, ship_heading, core.SHIP_DOC_SCALE, px)
			}
		}
		if frac, flying := sim.shuttle_progress(&g.shuttle); flying && int(g.shuttle.body) < len(g.sys.bodies) {
			// The shuttle on the line from the ship down to the surface beneath it.
			bp := g.sys.pos[g.shuttle.body]
			rel := ship_pos - bp
			rr := orbit.length(rel)
			surf := bp + rel / max(rr, 1e-9) * g.sys.bodies[g.shuttle.body].radius
			a := render.world_to_screen(&cam, ship_pos)
			b := render.world_to_screen(&cam, surf)
			render.draw_dashed({a.x, a.y}, {b.x, b.y}, 1, {150, 230, 170, 90})
			p := a + (b - a) * f32(frac)
			size := f32(max(g.sys.bodies[g.shuttle.body].radius * 0.03 * cam.zoom, 2.5))
			rl.DrawRectangleV({p.x - size, p.y - size}, {size * 2, size * 2}, {200, 205, 212, 255})
		}
		render.effects_draw(&fx, &cam)
		if g.pin.kind == .Npc && g.pin.index < len(g.fleet.npcs) && core.debug.show_predict {
			n := &g.fleet.npcs[g.pin.index]
			render.draw_prediction(&cam, &g.sys, n.ship.segments[:], n.ship.nodes[:], -1, clock.t)
		}
		if g.ap.active && g.ap.dest.kind == .Point {
			if wp, ok := destination_pos(&g, g.ap.dest); ok {
				sp := render.world_to_screen(&cam, wp)
				rl.DrawLineEx({sp.x - 10, sp.y}, {sp.x + 10, sp.y}, 2, {255, 220, 120, 255})
				rl.DrawLineEx({sp.x, sp.y - 10}, {sp.x, sp.y + 10}, 2, {255, 220, 120, 255})
				rl.DrawCircleLinesV({sp.x, sp.y}, 7, {255, 220, 120, 255})
				text.draw("waypoint", i32(sp.x + 12), i32(sp.y - 7), 12, {255, 220, 120, 255})
			}
		}
		if g.point_mode {
			m := rl.GetMousePosition()
			rl.DrawCircleLinesV(m, 9, {255, 220, 120, 255})
			text.draw("click to fly here", i32(m.x + 14), i32(m.y - 7), 12, {255, 220, 120, 255})
		}
		if p, ok := entity_position(&g, g.pin, clock.t); ok {
			radius: f32 = 14
			if g.pin.kind == .Body do radius = f32(max(g.sys.bodies[g.pin.index].radius * cam.zoom, f64(core.tuning.body_min_px))) + 6
			render.draw_focus_ring(&cam, p, radius)
		}

		if ship_p, ok := entity_position(&g, Focus{.Ship, 0}, clock.t); ok {
			render.draw_nebula_interior(&cam, &g.sys, ship_p)
		}

		if !g.map_open {
			legend := [?]render.Legend_Entry {
				{"planet", render.ORBIT_COLOR, 1, core.debug.show_orbits},
				{"moon", render.MOON_ORBIT, 1, core.debug.show_orbits},
				{"station", render.STATION_ORBIT, 1, core.debug.show_orbits},
				{"your path", render.SEGMENT_COLORS[0], 2, core.debug.show_predict},
				{"after next event", render.SEGMENT_COLORS[1], 2, core.debug.show_predict && len(g.ship.segments) > 1},
				{"later", render.SEGMENT_COLORS[2], 2, core.debug.show_predict && len(g.ship.segments) > 2},
				{"burn", render.NODE_COLOR, 2, core.debug.show_predict && len(g.ship.nodes) > 0},
				{"SOI", render.SOI_COLOR, 1, core.debug.show_soi},
				{"trade route", render.ROUTE_COLOR, 2, core.debug.show_routes},
			}
			render.draw_legend(legend[:])
		}

		// ---- UI stack; anything hot keeps world input away
		ui_hot = false
		ui.right_inset = 0
		if !g.map_open do ui_hot |= draw_hud(&clock, &g, &lib, !g.market_open && !g.yard_open)
		if sim.skim_active(&g.skim) && !g.map_open && g.skim.nebula < len(g.sys.nebulae) {
			n := g.sys.nebulae[g.skim.nebula]
			rate, _ := sim.hazard_at(&g.sys, ship_world(&g, clock.t))
			stop, hot := ui.skim_panel_draw(ui.Skim_View{
				nebula = n.name, kind = gen.nebula_describe(n.kind), skim = &g.skim,
				tint = n.colors[0], hazard = rate * core.SECONDS_PER_HOUR,
			})
			if stop { sim.skim_stop(&g.skim); audio.play(.Close) }
			ui_hot ||= hot
		}
		if g.contacts.open {
			rows := build_contacts(&g, clock.t)
			pick_c, did, hot := ui.contacts_draw(&g.contacts, rows)
			if did {
				f: Focus
				switch pick_c.kind {
				case .Body:    f = Focus{.Body, pick_c.index}
				case .Station: f = Focus{.Station, pick_c.index}
				case .Ship:    f = Focus{.Ship, 0}
				case .Npc:     f = Focus{.Npc, pick_c.index}
				case .Group:
				}
				look_at(&g, &cam, f, clock.t)
			}
			ui_hot |= hot
		}
		if g.planning {
			chosen, closed, hot := ui.plan_table_draw(destination_name(&g, g.plan_dest), plan_rows(&g, clock.t))
			if chosen >= 0 do choose_plan(&g, chosen, clock.t)
			if closed do g.planning = false
			ui_hot |= hot
		}
		if g.selected >= 0 && g.selected < len(g.ship.nodes) && !sim.is_dead(&g.ship) {
			n := &g.ship.nodes[g.selected]
			g.np_pro = f32(n.prograde)
			g.np_rad = f32(n.radial)
			g.np_lead = f32(n.t - clock.t)
			lead_max := f32(6 * core.SECONDS_PER_HOUR)
			for seg in g.ship.segments do if seg.end == .Node && seg.node == g.selected && seg.orbit.e < 1 { lead_max = f32(orbit.period(seg.orbit)); break }
			action, changed, hot := ui.node_panel_draw(ui.Node_View {
				index = g.selected, count = len(g.ship.nodes),
				prograde = &g.np_pro, radial = &g.np_rad, lead = &g.np_lead, lead_max = max(lead_max, g.np_lead + 60),
				burn_seconds = sim.burn_duration(&g.ship, sim.node_dv(n^)), dv = sim.node_dv(n^),
				armed = g.ship.autoburn.active && g.ship.autoburn.node_t == n.t,
			})
			if changed {
				n.prograde = f64(g.np_pro)
				n.radial = f64(g.np_rad)
				n.t = clock.t + f64(g.np_lead)
				sim.nodes_sort(&g.ship)
				if g.ship.mode == .On_Rails do sim.repredict(&g.sys, &g.ship, clock.t)
			}
			switch action {
			case .Warp:    node_warp(&g, clock.t)
			case .Execute: node_execute(&g, clock.t)
			case .Remove:  node_delete(&g, clock.t)
			case .None:
			}
			ui_hot |= hot
		}
		if g.map_open {
			// The card describes the selection, or where the ship is when
			// nothing is picked; its economy comes with it when known.
			view := ui.Map_View{galaxy = &g.galaxy, lib = &lib, current = g.current, selected = g.map_sel, cryo_speed = sim.CLASSES[g.ship.class].cryo_speed}
			shown := g.map_sel >= 0 ? g.map_sel : g.current
			if g.gecon.systems[shown].built {
				sm := econ.summarize(&g.gecon.systems[shown].econ)
				view.surveyed = true
				view.output = sm.output
				view.wealth = sm.wealth
				view.demand = sm.demand
				view.markets = len(g.gecon.systems[shown].econ.markets)
			}
			can_jump_now, _ := sim.can_jump(&g.sys, &g.ship)
			view.can_jump = can_jump_now
			view.pending = g.cryo_pending == g.map_sel && g.ap.active
			clicked, closed, jump, hot := ui.galaxy_map_draw(view, &g.map_st)
			if clicked >= 0 do g.map_sel = clicked
			if jump do request_jump(&g, &clock, clock.t)
			if closed || rl.IsKeyPressed(.ESCAPE) do g.map_open = false
			ui_hot |= hot
		}
		if g.routes_open {
			closed, hot := ui.routes_panel_draw(g.econ, &g.sys, g.fleet.routes)
			if closed do g.routes_open = false
			ui_hot |= hot
		}
		if g.yard_open {
			if st, ok := trade_market(&g); ok && g.econ.markets[st].is_yard {
				g.yard_station = st
			} else {
				g.yard_station = -1
				ui_hot |= ui.empty_panel_draw("Shipyard", "No shipyard in range.\nDock at one, or come within docking range, to buy hulls.", &g.yard_open)
			}
		}
		if g.yard_open && g.yard_station >= 0 {
			m := &g.econ.markets[g.yard_station]
			rows: [econ.NUM_CLASSES]ui.Yard_Row
			for c, k in econ.Class_Id {
				cs := sim.CLASSES[c]
				tmp := sim.Ship{stats = cs.stats, propellant = cs.stats.propellant_cap}
				rows[k] = ui.Yard_Row {
					class = c, name = econ.CLASS_NAMES[c], stock = m.ships[c], price = econ.class_price(m, c),
					cargo = cs.stats.cargo_cap, dv = sim.dv_remaining(&tmp), cryo = cs.cryo_speed, progress = m.progress[c],
					is_current = c == g.ship.class,
				}
			}
			buy, did, hot := ui.shipyard_panel_draw(ui.Yard_View{name = m.name, rows = rows[:], credits = g.credits, trade_in = econ.trade_in_value(g.ship.class)}, &g.yard_open)
			if did do buy_ship(&g, buy, clock.t)
			ui_hot |= hot
		}
		if g.market_open {
			if st, ok := trade_market(&g); ok {
				g.market_station = st
			} else {
				g.market_station = -1
				ui_hot |= ui.empty_panel_draw("Market", "No market in range.\nDock at a station or come within docking range, or park in a low orbit over a colony.", &g.market_open)
			}
		}
		if g.market_open && g.market_station >= 0 {
			vendor_refresh(&g, g.market_station, clock.t)
			mk := &g.econ.markets[g.market_station]
			shuttle: ^sim.Shuttle
			if econ.is_colony(mk) {
				if g.shuttle.market != g.market_station && !sim.shuttle_busy(&g.shuttle) do sim.shuttle_reset(&g.shuttle, g.market_station, mk.body)
				if g.shuttle.market == g.market_station do shuttle = &g.shuttle
			}
			trade, did, talk, jobs, cancel, hot := ui.market_panel_draw(ui.Market_View {
				market = mk, cargo = g.ship.cargo[:], cargo_cap = g.ship.stats.cargo_cap,
				credits = g.credits, propellant_pct = 100 * g.ship.propellant / g.ship.stats.propellant_cap,
				lib = &lib, vendor = g.vendor_avatar, vendor_name = g.vendor.name, vendor_line = g.vendor_line,
				shuttle = shuttle, round_trip = 2 * sim.shuttle_leg_time(&g.sys, &g.ship) + sim.SHUTTLE_SURFACE_TIME,
			}, &g.market_open)
			if did do apply_trade(&g, trade)
			if cancel do sim.shuttle_cancel(&g.shuttle)
			if jobs { g.jobs_open = true; g.jobs_board = true }
			if talk {
				kind, index := market_key(&g, g.market_station)
				talk_open(&g, kind, index, "greeting", clock.t)
			}
			ui_hot |= hot
		}
		if g.talk.open {
			if g.talk.kind == .Npc && g.talk.index >= len(g.fleet.npcs) do talk_close(&g)
		}
		if g.talk.open {
			names := people.PERSONALITY_NAMES
			v := ui.Talk_View{lib = &lib, avatar = g.talk.avatar, name = g.talk.person.name, mood = names[g.talk.person.personality], line = g.talk.line, is_pilot = g.talk.kind == .Npc, trading = g.talk.trading, can_haggle = !g.talk.haggled, can_trade = !g.talk.remote}
			if g.talk.kind == .Npc {
				n := &g.fleet.npcs[g.talk.index]
				v.role = fmt.tprintf("pilot of the %s %s", econ.CLASS_NAMES[n.ship.class], n.name)
				v.offer, _, _ = pilot_offer(&g, g.talk.index)
			} else if g.talk.kind == .Body {
				name := g.sys.bodies[g.talk.index].name
				if mi, ok := market_for_key(&g, .Body, g.talk.index); ok do name = g.econ.markets[mi].name
				v.role = fmt.tprintf("vendor at %s", name)
			} else {
				v.role = fmt.tprintf("vendor at %s", g.sys.stations[g.talk.index].name)
			}
			choice, qty, hot := ui.talk_draw(v, &g.talk.st)
			talk_choose(&g, choice, qty, clock.t)
			ui_hot |= hot
		}
		if !g.map_open {
			npc_pos := make([dynamic][2]f64, context.temp_allocator)
			for &n in g.fleet.npcs do if n.ship.mode != .Docked { p, _ := sim.npc_state(&g.sys, &n, clock.t); append(&npc_pos, p) }
			half := [2]f64{f64(rl.GetScreenWidth()) * 0.5 / cam.zoom, f64(rl.GetScreenHeight()) * 0.5 / cam.zoom}
			following_ship := cam.follow && g.follow_target.kind == .Ship
			look, clicked, refocus, hot := ui.minimap_draw(ui.Minimap_View {
				sys = &g.sys, ship_pos = ship_pos, cam_center = cam.target, cam_half = half, cam_angle = cam.angle, npc_pos = npc_pos[:], following = following_ship,
				following_name = cam.follow && !following_ship ? entity_name(&g, g.follow_target) : "",
				title = fmt.tprintf("%s system", g.sys.name), subtitle = fmt.tprintf("%s, system %d of %d", gen.star_describe(g.sys.star), g.current + 1, len(g.galaxy.systems)),
			})
			if clicked {
				cam.target = look
				cam.follow = false
			}
			if refocus do follow_ship(&g, &cam)
			ui_hot |= hot
		}
		if g.cryo_pending >= 0 && !g.map_open && !g.ap.active && !g.planning {
			if ok, _ := sim.can_jump(&g.sys, &g.ship); ok {
				e, _ := gen.edge_between(&g.galaxy, g.current, g.cryo_pending)
				years := sim.jump_years(e.distance, sim.CLASSES[g.ship.class].cryo_speed)
				jump, cancel, hot := ui.jump_prompt_draw(g.galaxy.systems[g.cryo_pending].name, years)
				if jump {
					g.map_sel = g.cryo_pending
					g.cryo_pending = -1
					begin_cryo(&g, &clock, clock.t)
				}
				if cancel do g.cryo_pending = -1
				ui_hot |= hot
			}
		}
		if g.orbit_prompt.open {
			go, hot := ui.orbit_prompt_draw(&g.orbit_prompt)
			if go {
				g.orbit_prompt.open = false
				r := f64(g.orbit_prompt.altitude) + g.sys.bodies[g.ship.primary].radius
				if ok, why := sim.order_orbit_at(&g.sys, &g.ship, &g.order, r, clock.t); !ok do g.plan_msg = why
				else do g.selected = -1
			}
			ui_hot |= hot
		}
		if g.jobs_open {
			at, has := trade_market(&g)
			board: []econ.Job
			if has && at < len(g.econ.boards) do board = g.econ.boards[at].jobs[:]
			accept, deliver, hot := ui.jobs_panel_draw(ui.Jobs_View {
				e = g.econ, market = has ? at : -1, board = board, contracts = contract_rows(&g, has ? at : -1, clock.t),
				t = clock.t, free_hold = sim.cargo_free(&g.ship), max_active = MAX_CONTRACTS,
				show_board = g.jobs_board, place = has ? g.econ.markets[at].name : "",
			}, &g.jobs_open)
			if accept != 0 do contract_accept(&g, accept)
			if deliver >= 0 do contract_deliver(&g, deliver)
			ui_hot |= hot
		}
		// Dev runs to completion: answer interruptions with their default while still flying.
		if opts.screenshot != "" && opts.until_done && g.ap.active && len(g.notices) > 0 do notice_choose(&g, g.notices[0].kind == .Hail ? 1 : 0, clock.t)
		if len(g.notices) > 0 {
			n := g.notices[0]
			buttons: []string
			accent := rl.Color{150, 230, 170, 255}
			switch n.kind {
			case .Info:    buttons = {"OK"}
			case .Arrival: buttons = n.market >= 0 && !g.market_open ? []string{"OK", "Open the market"} : []string{"OK"}
			case .Hazard:  buttons = {"Continue", "Cut the autopilot"}; accent = {255, 140, 120, 255}
			case .Hail:    buttons = {"Answer", "Ignore"}; accent = {160, 190, 255, 255}
			case .Undock_Plan: buttons = {"Undock and plot", "Stay docked"}; accent = {255, 220, 120, 255}
			}
			choice, hot := ui.notice_draw(ui.Notice_View{title = n.title, text = n.text, buttons = buttons, accent = accent})
			if choice >= 0 do notice_choose(&g, choice, clock.t)
			ui_hot |= hot
		}
		if g.pin.kind != .None && !g.map_open {
			action, rect, hot := draw_popover(&g, &cam, &lib, clock.t)
			g.pin_rect = rect
			ui_hot |= hot
			apply_popover(&g, &cam, action, clock.t)
		}
		{
			status := ""
			if g.ap.active do status = fmt.tprintf("autopilot -> %s: %s", destination_name(&g, g.ap.dest), g.ap.status)
			else if g.pin.kind != .None do status = entity_name(&g, g.pin)
			// Grey out what does not apply right now.
			disabled: bit_set[ui.Action]
			dockable, can_dock := sim.dockable_station(&g.sys, &g.ship)
			_ = dockable
			tstation, thas := trade_market(&g)
			_, can_dock_ship := sim.dockable_ship(&g.sys, &g.ship, sim.fleet_ships(&g.fleet))
			if !(can_dock || can_dock_ship) || g.ship.mode == .Docked do disabled += {.Dock}
			if g.ship.mode != .Docked do disabled += {.Undock}
			if !thas do disabled += {.Market_Window}
			if !thas || tstation >= len(g.econ.markets) || !g.econ.markets[tstation].is_yard do disabled += {.Shipyard_Window}
			if !g.ap.active do disabled += {.Cancel_Autopilot}
			if destination_of(&g, g.pin).kind == .None do disabled += {.Plan_Course}
			if g.selected < 0 || g.selected >= len(g.ship.nodes) do disabled += {.Node_Remove, .Warp_To_Burn, .Execute_Burn}
			if sim.is_dead(&g.ship) || g.ship.mode == .Docked do disabled += {.Throttle_Full, .Cut_Engine, .Hold_Prograde, .Hold_Retrograde, .Hold_Release, .Node_Add, .Fly_To_Point}
			action, hot := ui.menubar_draw(&g.mb, ui.Bar_Info{clock = &clock, follow = cam.follow, status = status, contacts = &g.contacts.open, heading_lock = g.heading_lock, auto_time = g.auto_time, auto_dock = g.auto_dock, skimming = sim.skim_active(&g.skim), flying = g.ap.active || sim.order_active(&g.order), ceiling = &g.auto_ceiling, disabled = disabled})
			apply_action(&g, &cam, &clock, &panel, &regen, action, clock.t)
			ui_hot |= hot
		}
		ui_hot |= ui.debug_panel_draw(&panel, ui.Debug_Info{
			clock     = &clock,
			cam_zoom  = cam.zoom,
			cam_pos   = cam.target,
			follow    = &cam.follow,
			lib       = &lib,
			icon      = art.library_get(&lib, "icon"),
			ship_mode = ship_state,
			sys       = &g.sys,
			seed      = &g.seed,
			regen     = &regen,
			focus     = focus_name(&g),
		})
		if opts.perf && frame > 5 {
			ms := time.duration_milliseconds(time.tick_since(sim_end))
			draw_total += ms
			draw_worst = max(draw_worst, ms)
		}
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}

// Instruments bottom centre, the log bottom left. Both report the mouse so
// the world does not get clicked or dragged through them. The market and the
// shipyard fill the bottom right corner over the instruments, so those stand
// down while one of them is up; the log is clear of both and stays.
draw_hud :: proc(clock: ^core.Clock, g: ^Game, lib: ^art.Library, instruments: bool) -> (hot: bool) {
	if instruments do hot = draw_flight_readout(g, clock)
	hot |= ui.log_draw(&g.log)
	if lib.message != "" && art.library_message_age(lib) < 3 {
		text.draw(fmt.ctprintf("%s", lib.message), 12, ui.BAR_H + 32, 16, {122, 204, 240, 255})
	}
	return
}

// Dev scenario: park the ship in the star's frame just outside the home
// planet's sphere of influence, moving inward fast enough to swing past.
stage_flyby :: proc(g: ^Game, t: f64) {
	planet := g.ship.primary
	if planet == gen.STAR do return
	b := g.sys.bodies[planet]
	pp, pv := sim.body_state_at(&g.sys, planet, t)
	v := 1.4 * math.sqrt(2 * b.mu / b.soi)
	g.ship.primary = gen.STAR
	g.ship.pos = pp + {b.soi * 1.3, 0}
	g.ship.vel = pv + {-v, 0.35 * v}
	g.ship.orbit = orbit.from_state(g.ship.pos, g.ship.vel, g.sys.bodies[0].mu, t)
	g.ship.mode = .On_Rails
	sim.repredict(&g.sys, &g.ship, t)
}

// Ship controls: arrows turn and throttle, Z/X full/cut, P/O toggle a
// prograde/retrograde hold.
RCS_DV :: 0.0003 // one nudge, world units per second

// Shift + arrows: small impulses in screen directions, for the last few units.
rcs_input :: proc(g: ^Game, cam: ^render.Camera, t: f64) {
	if !(rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)) do return
	d: [2]f32
	if input.pressed(.Pan_Up) || rl.IsKeyPressed(.UP) do d.y -= 1
	if input.pressed(.Pan_Down) || rl.IsKeyPressed(.DOWN) do d.y += 1
	if input.pressed(.Pan_Left) || rl.IsKeyPressed(.LEFT) do d.x -= 1
	if input.pressed(.Pan_Right) || rl.IsKeyPressed(.RIGHT) do d.x += 1
	if d == 0 do return
	w := render.screen_delta_to_world(cam, d)
	l := orbit.length(w)
	if l > 0 do sim.rcs_nudge(&g.sys, &g.ship, w / l * RCS_DV, t)
}

flight_input :: proc(ship: ^sim.Ship, real_dt: f64, dev_turn := 0.0) {
	if sim.is_dead(ship) do return
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do return // Shift + arrows are RCS nudges
	turn := dev_turn // --turn holds the stick for a screenshot
	if input.down(.Turn_Left) do turn += 1
	if input.down(.Turn_Right) do turn -= 1
	if turn != 0 {
		ship.manual_heading = true // the pilot has the stick: keep this heading
		ship.hold = .None
	}
	if turn != 0 {
		ship.hold = .None
		ship.heading += turn * f64(core.tuning.turn_rate) * real_dt
	}
	if input.down(.Throttle_Up) do ship.throttle = min(ship.throttle + 0.8 * real_dt, 1)
	if input.down(.Throttle_Down) do ship.throttle = max(ship.throttle - 0.8 * real_dt, 0)
	if input.pressed(.Throttle_Full) do ship.throttle = 1
	if input.pressed(.Cut_Engine) do ship.throttle = 0
	if input.pressed(.Hold_Prograde) { ship.hold = ship.hold == .Prograde ? .None : .Prograde; ship.manual_heading = false }
	if input.pressed(.Hold_Retrograde) { ship.hold = ship.hold == .Retrograde ? .None : .Retrograde; ship.manual_heading = false }
}

// The instruments across the bottom centre, and the live status lines above
// them. What has already happened goes to the ship's log on the left, so this
// only ever says what is true right now.
draw_flight_readout :: proc(g: ^Game, clock: ^core.Clock) -> (hot: bool) {
	s := &g.ship
	b := g.sys.bodies[s.primary]
	r := orbit.length(s.pos)
	o := s.mode == .On_Rails ? s.orbit : (len(s.segments) > 0 ? s.segments[0].orbit : s.orbit)
	dry := s.stats.mass_dry + sim.cargo_used(s) * sim.CARGO_UNIT_MASS
	mode := "COASTING"
	switch s.mode {
	case .On_Rails:  mode = "COASTING"
	case .Thrusting: mode = "BURN"
	case .Docked:    mode = s.docked_ship ? "DOCKED (SHIP)" : "DOCKED"
	case .Cryo:      mode = "CRYO"
	case .Wrecked:   mode = "WRECKED"
	case .Destroyed: mode = "DESTROYED"
	}
	hazard := ""
	switch s.hazard {
	case .Heat: hazard = "HEAT"
	case .Wind: hazard = "PULSAR WIND"
	case .Dust: hazard = "DUST"
	case .None:
	}
	// The star holds the whole system, so its altitude scale is the boundary
	// a cryo jump needs rather than an infinite sphere of influence.
	ceiling := b.soi
	if b.parent == gen.NONE || math.is_inf(ceiling) do ceiling = sim.system_boundary(&g.sys)
	hot = ui.hud_draw(ui.Hud_View {
		mode       = mode,
		primary    = b.name,
		throttle   = s.throttle,
		hold       = s.hold == .Prograde ? "PRO" : (s.hold == .Retrograde ? "RET" : ""),
		autoburn   = s.autoburn.active && s.throttle > 0,
		armed      = s.autoburn.active,
		propellant = s.stats.propellant_cap > 0 ? s.propellant / s.stats.propellant_cap : 0,
		dv         = sim.dv_remaining(s),
		dv_full    = s.stats.ve * math.ln((dry + s.stats.propellant_cap) / dry),
		alt        = r - b.radius,
		alt_max    = max(ceiling - b.radius, b.radius),
		speed      = orbit.length(s.vel),
		v_circ     = math.sqrt(b.mu / max(r, 1e-9)),
		v_esc      = math.sqrt(2 * b.mu / max(r, 1e-9)),
		pe         = orbit.periapsis(o) - b.radius,
		ap         = o.e < 1 ? orbit.apoapsis(o) - b.radius : 0,
		conic      = o,
		radius     = b.radius,
		soi        = b.soi,
		pos        = s.pos,
		vel        = s.vel,
		hull       = s.hull,
		hazard     = hazard,
		dead       = sim.is_dead(s),
	})
	draw_status_lines(g, clock)
	return
}

// How many status lines fit above the instruments before the stack gets in
// the way of the view; the least important are dropped first.
MAX_STATUS :: 7

// Prompts, running operations and whatever the pilot needs to answer, stacked
// just above the instruments. Appended least important first, so the line that
// matters most ends up nearest the panel.
draw_status_lines :: proc(g: ^Game, clock: ^core.Clock) {
	s := &g.ship
	b := g.sys.bodies[s.primary]
	col := rl.Color{190, 200, 220, 255}
	dim := rl.Color{140, 150, 172, 255}
	good := rl.Color{150, 230, 170, 255}
	warn := rl.Color{255, 200, 120, 255}
	alarm := rl.Color{255, 120, 120, 255}
	Status_Line :: struct {
		msg: string,
		col: rl.Color,
	}
	lines := make([dynamic]Status_Line, context.temp_allocator)
	line :: proc(lines: ^[dynamic]Status_Line, msg: string, col: rl.Color) {
		append(lines, Status_Line{msg, col})
	}
	if len(g.contracts) > 0 do line(&lines, fmt.tprintf("%d contract%s held   Trade > Your contracts", len(g.contracts), len(g.contracts) == 1 ? "" : "s"), dim)
	if g.focus.kind == .Npc && g.focus.index < len(g.fleet.npcs) {
		n := &g.fleet.npcs[g.focus.index]
		what := "idle"
		if n.role == .Surveyor {
			what = sim.survey_status(n, &g.sys)
		} else {
			switch n.state {
			case .Trading:   what = "trading"
			case .Planning:  what = "plotting a course"
			case .Dwelling:  what = n.ship.mode == .Docked ? fmt.tprintf("docked at %s", g.sys.stations[n.ship.dock].name) : "parked"
			case .Flying:    what = fmt.tprintf("%s -> %s (%s)", n.ap.status, g.econ.markets[n.route.to].name, econ.NAMES[n.route.commodity])
			case .Surveying: what = "parked in the gas"
			}
		}
		line(&lines, fmt.tprintf("%s: %s   hold %.0f   credits %.0f   trades %d", n.name, what, sim.cargo_used(&n.ship), n.credits, n.trades), {200, 190, 150, 255})
	}
	if s.throttle > 0 && !sim.is_dead(s) {
		if s.autoburn.active do line(&lines, fmt.tprintf("autoburn: time held to %.0f s per second", core.tuning.warp_max_autoburn), dim)
		else do line(&lines, fmt.tprintf("hand-flown burn: time held to %.0f s per second", core.tuning.warp_max_thrusting), dim)
	}
	if g.ap.active {
		next := ""
		if start, ok := sim.autoburn_start(s); ok && start > g.clock_t do next = fmt.tprintf("next burn in %s", core.clock_duration(start - g.clock_t))
		if g.ap.cand.t_arrive > g.clock_t do next = next == "" ? fmt.tprintf("arrival in %s", core.clock_duration(g.ap.cand.t_arrive - g.clock_t)) : fmt.tprintf("%s, arrival in %s", next, core.clock_duration(g.ap.cand.t_arrive - g.clock_t))
		line(&lines, fmt.tprintf("time %s, up to %s per second   %s", g.auto_time ? "runs itself" : "manual", core.WARP_LABELS[g.auto_time ? g.auto_ceiling : clock.warp_index], next), dim)
	}
	if g.selected >= 0 && g.selected < len(s.nodes) {
		n := s.nodes[g.selected]
		armed := s.autoburn.active && s.autoburn.node_t == n.t ? "   ARMED" : ""
		line(&lines, fmt.tprintf("node %d/%d: in %s   dv %.4f (pro %+.4f  rad %+.4f)   burn %s%s", g.selected + 1, len(s.nodes), core.clock_duration(n.t - clock.t), sim.node_dv(n), n.prograde, n.radial, core.clock_duration(sim.burn_duration(s, sim.node_dv(n))), armed), {255, 220, 120, 255})
	}
	if g.warp_to > 0 do line(&lines, fmt.tprintf("warping to burn: %s", core.clock_duration(g.warp_to - clock.t)), {150, 190, 255, 255})
	if sim.order_active(&g.order) do line(&lines, fmt.tprintf("order: orbit at %.1f above %s: %s", g.order.r_target - b.radius, b.name, g.order.status), good)
	if seg, has := sim.next_event(s); has {
		what: string
		switch seg.end {
		case .Enter:   what = fmt.tprintf("encounter %s", g.sys.bodies[seg.target].name)
		case .Exit:    what = fmt.tprintf("leave %s", b.name)
		case .Collide: what = "IMPACT"
		case .Horizon, .Node:
		}
		line(&lines, fmt.tprintf("next: %s in %s", what, core.clock_duration(seg.t1 - clock.t)), seg.end == .Collide ? alarm : dim)
	}
	if tm, ok := trade_market(g); ok && econ.is_colony(&g.econ.markets[tm]) {
		status := g.shuttle.market == tm ? fmt.tprintf("   shuttle %s", sim.shuttle_status(&g.shuttle)) : ""
		line(&lines, fmt.tprintf("in shuttle range of %s   Trade > Market (M)%s", g.econ.markets[tm].name, status), good)
	}
	if idx, ok := sim.dockable_station(&g.sys, s); ok {
		line(&lines, fmt.tprintf("in docking range of %s   Plan > Dock (K)", g.sys.stations[idx].name), good)
	}
	if ok, _ := sim.can_jump(&g.sys, s); ok && s.mode == .On_Rails {
		line(&lines, "cryo jump available: View > Galaxy map, pick a linked system, Jump", good)
	}
	if g.ap.active {
		via := g.ap.cand.flyby ? fmt.tprintf(" via %s", g.sys.bodies[g.ap.fb.via].name) : ""
		line(&lines, fmt.tprintf("AUTOPILOT -> %s%s   %v   %s   arrive in %s   (G cancels)", destination_name(g, g.ap.dest), via, g.ap.objective, g.ap.status, core.clock_duration(g.ap.cand.t_arrive - clock.t)), good)
	} else if g.ap.stage == .Done || g.ap.stage == .Failed {
		line(&lines, fmt.tprintf("autopilot: %s", g.ap.status), g.ap.stage == .Done ? good : alarm)
	} else if g.plan_msg != "" {
		line(&lines, g.plan_msg, warn)
	}
	if s.mode == .Docked {
		hold := fmt.tprintf("hull %.0f%%   credits %.0f   hold %.0f/%.0f", 100 * s.hull, g.credits, sim.cargo_used(s), s.stats.cargo_cap)
		if s.docked_ship {
			host := s.dock < len(g.fleet.npcs) ? g.fleet.npcs[s.dock].name : "a ship"
			line(&lines, fmt.tprintf("%s   %s", hold, econ.CLASS_NAMES[s.class]), col)
			line(&lines, fmt.tprintf("docked with %s   hover the ship for Talk   Plan > Undock (U)", host), good)
		} else {
			yard := s.dock < len(g.econ.markets) && g.econ.markets[s.dock].is_yard ? "   Trade > Shipyard (Y)" : ""
			line(&lines, fmt.tprintf("%s   %s", hold, econ.CLASS_NAMES[s.class]), col)
			line(&lines, fmt.tprintf("docked at %s   Trade > Market window (M)   Plan > Undock (U)%s", g.sys.stations[s.dock].name, yard), good)
		}
	}
	switch s.hazard {
	case .Heat: line(&lines, fmt.tprintf("HEAT: too close to %s, hull -%.1f%%/h", g.sys.bodies[0].name, s.hazard_rate * 100 * core.SECONDS_PER_HOUR), alarm)
	case .Wind: line(&lines, fmt.tprintf("PULSAR WIND: hull -%.1f%%/h", s.hazard_rate * 100 * core.SECONDS_PER_HOUR), {160, 190, 255, 255})
	case .Dust:
		neb := "the gas"
		if idx, _ := gen.nebula_at(&g.sys, g.sys.pos[s.primary] + s.pos); idx >= 0 do neb = g.sys.nebulae[idx].name
		line(&lines, fmt.tprintf("DUST: %s scours the hull, -%.2f%%/h   Orders > Skim the nebula", neb, s.hazard_rate * 100 * core.SECONDS_PER_HOUR), {220, 170, 140, 255})
	case .None:
	}
	if s.mode == .Wrecked do line(&lines, fmt.tprintf("WRECKED on %s   (R to start over)", b.name), alarm)
	if s.mode == .Destroyed {
		cause: string
		switch s.hazard {
		case .Heat: cause = fmt.tprintf("hull cooked by %s", g.sys.bodies[0].name)
		case .Wind: cause = "hull shredded by the pulsar wind"
		case .Dust: cause = "hull scoured away in the gas"
		case .None: cause = fmt.tprintf("fell into %s", g.sys.bodies[0].name)
		}
		line(&lines, fmt.tprintf("DESTROYED: %s   (R to start over)", cause), alarm)
	}

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	y := sh - ui.HUD_H - ui.HUD_MARGIN - 24
	for i := len(lines) - 1; i >= max(len(lines) - MAX_STATUS, 0); i -= 1 {
		l := fmt.ctprintf("%s", lines[i].msg)
		tw := f32(text.measure(l, 13))
		x := f32(i32((sw - tw) * 0.5))
		rl.DrawRectangleRounded({x - 9, y - 2, tw + 18, 19}, 0.5, 4, {8, 11, 17, 180})
		text.draw(l, i32(x), i32(y), 13, lines[i].col)
		y -= 20
	}
}

// G plans a course to the focused body or station (or cancels a running
// autopilot); 1-4 pick an objective from the table; Esc closes it.
plan_input :: proc(g: ^Game, t: f64) {
	if input.pressed(.Plan_Course) {
		if g.ap.active {
			sim.autopilot_cancel(&g.ship, &g.ap)
			sim.repredict(&g.sys, &g.ship, t)
		} else if g.planning {
			g.planning = false
		} else {
			begin_planning(g, t, destination_of(g, g.pin))
		}
	}
	if !g.planning do return
	if rl.IsKeyPressed(.ESCAPE) do g.planning = false
	keys := [?]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE}
	for k, i in keys do if rl.IsKeyPressed(k) do choose_plan(g, i, t)
}


node_add_ahead :: proc(g: ^Game, t: f64) {
	s := &g.ship
	if sim.is_dead(s) || len(s.segments) == 0 do return
	seg := s.segments[0]
	lead := seg.orbit.e < 1 ? max(orbit.period(seg.orbit) * 0.05, 60) : 300
	g.selected = sim.node_add(s, sim.Node{t = t + lead})
	if s.mode == .On_Rails do sim.repredict(&g.sys, s, t)
}

node_delete :: proc(g: ^Game, t: f64) {
	if g.selected < 0 || g.selected >= len(g.ship.nodes) do return
	sim.node_remove(&g.ship, g.selected)
	g.selected = -1
	if g.ship.mode == .On_Rails do sim.repredict(&g.sys, &g.ship, t)
}

node_warp :: proc(g: ^Game, t: f64) {
	if g.selected < 0 || g.selected >= len(g.ship.nodes) do return
	n := g.ship.nodes[g.selected]
	start := n.t - 0.5 * sim.burn_duration(&g.ship, sim.node_dv(n))
	if start > t do g.warp_to = start
}

node_execute :: proc(g: ^Game, t: f64) {
	if g.selected < 0 || g.selected >= len(g.ship.nodes) do return
	sim.arm_node(&g.ship, g.selected)
	if start, ok := sim.autoburn_start(&g.ship); ok && start > t do g.warp_to = start
}

// Menu bar actions. Keyboard shortcuts call the same helpers.
apply_action :: proc(g: ^Game, cam: ^render.Camera, clock: ^core.Clock, panel: ^ui.Debug_Panel, regen: ^bool, a: ui.Action, t: f64) {
	s := &g.ship
	set_warp :: proc(clock: ^core.Clock, level: int) {
		core.clock_set_index(clock, level)
		clock.paused = false
	}
	switch a {
	case .None:
	case .Skim_Nebula:     start_skim(g, t)
	case .Throttle_Full:   if !sim.is_dead(s) do s.throttle = 1
	case .Cut_Engine:      s.throttle = 0
	case .Hold_Prograde:   s.hold = .Prograde; s.manual_heading = false
	case .Hold_Retrograde: s.hold = .Retrograde; s.manual_heading = false
	case .Hold_Release:    s.hold = .None; s.manual_heading = false // back to facing the way it flies
	case .Node_Add:        node_add_ahead(g, t)
	case .Node_Remove:     node_delete(g, t)
	case .Warp_To_Burn:    node_warp(g, t)
	case .Execute_Burn:    node_execute(g, t)
	case .Plan_Course:     begin_planning(g, t, destination_of(g, g.pin))
	case .Fly_To_Point:
		g.point_mode = !g.point_mode
		g.plan_msg = g.point_mode ? "click where you want to go (Esc cancels)" : ""
	case .Go:              go_to(g, destination_of(g, g.pin), t)
	case .Orbit_At:        open_orbit_prompt(g)
	case .Toggle_Auto_Dock: g.auto_dock = !g.auto_dock
	case .Cancel_Autopilot:
		if g.ap.active {
			sim.autopilot_cancel(s, &g.ap)
			sim.repredict(&g.sys, s, t)
		}
		if sim.order_active(&g.order) {
			g.order = {}
			clear(&s.nodes)
			s.autoburn.active = false
			sim.repredict(&g.sys, s, t)
		}
	case .Dock:
		if idx, ok := sim.dockable_station(&g.sys, s); ok {
			sim.dock(&g.sys, s, idx, t)
			g.selected = -1
		} else if idx, ok := sim.dockable_ship(&g.sys, s, sim.fleet_ships(&g.fleet)); ok {
			request_ship_dock(g, idx, t)
		} else {
			g.plan_msg = "nothing within docking range (get within 3 units at matched speed)"
		}
	case .Undock:
		undock_player(g, t)
	case .Pause:           clock.paused = !clock.paused
	case .Warp_Down:       core.clock_warp_down(clock)
	case .Warp_Up:         core.clock_warp_up(clock)
	case .Tick_1s:         set_warp(clock, 0)
	case .Tick_1m:         set_warp(clock, 1)
	case .Tick_10m:        set_warp(clock, 2)
	case .Tick_30m:        set_warp(clock, 3)
	case .Tick_1h:         set_warp(clock, 4)
	case .Tick_1d:         set_warp(clock, 5)
	case .Tick_1mo:        set_warp(clock, 6)
	case .Tick_1y:         set_warp(clock, 7)
	case .Follow:          follow_ship(g, cam)
	case .Frame_System:
		render.camera_fit(cam, 0, g.sys.extent)
		cam.follow = false
	case .Cycle_Focus:
		n := len(g.sys.bodies)
		i := g.focus.kind == .Body ? (g.focus.index + 1) % n : 0
		g.focus = Focus{.Body, i}
		cam.follow = true
	case .Toggle_Orbits:   core.debug.show_orbits = !core.debug.show_orbits
	case .Toggle_Labels:   core.debug.show_labels = !core.debug.show_labels
	case .Toggle_SOI:      core.debug.show_soi = !core.debug.show_soi
	case .Toggle_Belts:    core.debug.show_belts = !core.debug.show_belts
	case .Toggle_Predict:  core.debug.show_predict = !core.debug.show_predict
	case .Toggle_Routes:   core.debug.show_routes = !core.debug.show_routes
	case .Rotate_Reset:    cam.angle = 0; g.heading_lock = false
	case .Jobs_Window:     g.jobs_open = !g.jobs_open; g.jobs_board = false
	case .Toggle_Auto_Time: g.auto_time = !g.auto_time
	case .Skip_Burn:
		if start, ok := sim.autoburn_start(s); ok && start > t { g.warp_to = start; g.warp_auto = false }
		else if until, ok2 := sim.autopilot_wait_until(s, &g.ap, t); ok2 { g.warp_to = until; g.warp_auto = false }
	case .Skip_Arrival:
		if g.ap.active && g.ap.cand.t_arrive > t + 60 { g.warp_to = g.ap.cand.t_arrive - 60; g.warp_auto = false }
	case .Toggle_Heading_Lock: g.heading_lock = !g.heading_lock
	case .Regen:           regen^ = true
	case .Seed_Next:       g.seed += 1; regen^ = true
	case .Seed_Prev:       g.seed -= 1; regen^ = true
	case .Toggle_Debug:    panel.open = !panel.open
	case .Market_Window:
		if s.mode == .Docked do g.market_open = !g.market_open
		else do g.plan_msg = "dock at a station to trade"
	case .Routes_Window:   g.routes_open = !g.routes_open
	case .Galaxy_Map:      g.map_open = !g.map_open
	case .Save_Game:       g.plan_msg = save_game(g, t, 0) ? "quick saved" : "save failed"
	case .Load_Game:       load_game(g, clock, 0)
	case .Save_Slots:      g.request = .Save_Slots
	case .Load_Slots:      g.request = .Load_Slots
	case .Settings:        g.request = .Settings
	case .Main_Menu:       g.request = .Main_Menu
	case .Shipyard_Window:
		if s.mode == .Docked && !s.docked_ship && s.dock < len(g.econ.markets) && g.econ.markets[s.dock].is_yard do g.yard_open = !g.yard_open
		else do g.plan_msg = "dock at a shipyard to buy ships"
	}
}

save_game :: proc(g: ^Game, t: f64, slot: int) -> bool {
	os.make_directory("saves")
	sv := save.capture(g.seed, t, g.current, g.credits, &g.ship, &g.gecon, g.galaxy.params, g.sys.name, g.contracts[:])
	return save.write(save.slot_path(slot), sv)
}

load_game :: proc(g: ^Game, clock: ^core.Clock, slot: int) -> bool {
	sv, ok := save.read(save.slot_path(slot))
	if !ok {
		g.plan_msg = "no save to load (or an old version)"
		return false
	}
	clock.t = sv.t
	g.credits = sv.credits
	g.start_class = sv.ship.class
	params := sv.params
	params.seed = sv.seed
	if params.systems <= 0 do params.systems = gen.GALAXY_SYSTEMS
	game_load_galaxy(g, params, sv.t)
	save.apply_markets(sv, &g.gecon)
	game_enter_system(g, sv.current, sv.t)
	save.apply_ship(sv, &g.sys, &g.ship, sv.t)
	clear(&g.contracts)
	for j in sv.contracts do append(&g.contracts, j)
	g.focus = Focus{.Ship, 0}
	g.plan_msg = "loaded"
	return true
}

// The contacts tree, pre-ordered with depths: planets > moons/stations/
// ships > stations' docked ships, then a group of heliocentric strays.
build_contacts :: proc(g: ^Game, t: f64) -> []ui.Contact {
	rows := make([dynamic]ui.Contact, context.temp_allocator)
	ship_pos, _, _ := sim.state(&g.sys, &g.ship, t)
	dist :: proc(a, b: [2]f64) -> string {
		return fmt.tprintf("%.0f", orbit.length(a - b))
	}
	add_ships_at :: proc(g: ^Game, rows: ^[dynamic]ui.Contact, primary: gen.Body_Handle, station: int, depth: int, t: f64, ship_pos: [2]f64) {
		// Player.
		if station >= 0 ? (g.ship.mode == .Docked && g.ship.dock == station) : (g.ship.mode != .Docked && g.ship.primary == primary) {
			append(rows, ui.Contact{kind = .Ship, index = 0, name = fmt.tprintf("%s (you)", g.ship.name), detail = econ.CLASS_NAMES[g.ship.class], depth = depth})
		}
		for &n, i in g.fleet.npcs {
			s := &n.ship
			at := station >= 0 ? (s.mode == .Docked && s.dock == station) : (s.mode != .Docked && s.primary == primary)
			if !at do continue
			p, _ := sim.npc_state(&g.sys, &n, t)
			append(rows, ui.Contact{kind = .Npc, index = i, name = n.name, detail = fmt.tprintf("%s  %s", econ.CLASS_NAMES[s.class], dist(p, ship_pos)), depth = depth})
		}
	}
	add_stations_at :: proc(g: ^Game, rows: ^[dynamic]ui.Contact, parent: gen.Body_Handle, depth: int, t: f64, ship_pos: [2]f64) {
		for st, i in g.sys.stations {
			if st.parent != parent do continue
			start := len(rows)
			append(rows, ui.Contact{kind = .Station, index = i, name = st.name, detail = fmt.tprintf("%v  %s", st.kind, dist(g.sys.station_pos[i], ship_pos)), depth = depth})
			add_ships_at(g, rows, parent, i, depth + 1, t, ship_pos)
			rows[start].has_children = len(rows) > start + 1
		}
	}
	add_body :: proc(g: ^Game, rows: ^[dynamic]ui.Contact, h: gen.Body_Handle, depth: int, t: f64, ship_pos: [2]f64) {
		b := g.sys.bodies[h]
		start := len(rows)
		append(rows, ui.Contact{kind = .Body, index = int(h), name = b.name, detail = fmt.tprintf("%v  %s", b.kind, dist(g.sys.pos[h], ship_pos)), depth = depth})
		for &m, i in g.sys.bodies do if m.parent == h do add_body(g, rows, gen.Body_Handle(i), depth + 1, t, ship_pos)
		add_stations_at(g, rows, h, depth + 1, t, ship_pos)
		add_ships_at(g, rows, h, -1, depth + 1, t, ship_pos)
		rows[start].has_children = len(rows) > start + 1
	}
	for &b, i in g.sys.bodies do if i > 0 && b.parent == gen.STAR do add_body(g, &rows, gen.Body_Handle(i), 0, t, ship_pos)
	// Strays: anything orbiting the star directly.
	start := len(rows)
	append(&rows, ui.Contact{kind = .Group, index = 0, name = "Stray objects", detail = "heliocentric", depth = 0})
	add_stations_at(g, &rows, gen.STAR, 1, t, ship_pos)
	add_ships_at(g, &rows, gen.STAR, -1, 1, t, ship_pos)
	rows[start].has_children = len(rows) > start + 1
	return rows[:]
}

// Jump requested from the map. Already clear of the star: go. Otherwise fly
// out past the boundary first and ask again on arrival.
request_jump :: proc(g: ^Game, clock: ^core.Clock, t: f64) {
	if g.map_sel < 0 || !gen.has_edge(&g.galaxy, g.current, g.map_sel) do return
	if ok, _ := sim.can_jump(&g.sys, &g.ship); ok {
		begin_cryo(g, clock, t)
		return
	}
	// Waypoint past the boundary, outward along the ship's heliocentric direction.
	world, _, _ := sim.state(&g.sys, &g.ship, t)
	r := orbit.length(world)
	dir := r > 1e-6 ? world / r : [2]f64{1, 0}
	g.cryo_pending = g.map_sel
	g.map_open = false
	plan_to_point(g, dir * sim.system_boundary(&g.sys) * 1.1, t)
	if !g.planning {
		g.plan_msg = "could not plan a way out of the system from here"
		g.cryo_pending = -1
	}
}

// Engage cryo for the map selection: the clock will run to the arrival
// time while the transit screen shows, then the ship arrives inbound.
begin_cryo :: proc(g: ^Game, clock: ^core.Clock, t: f64, force := false) {
	if g.map_sel < 0 || g.map_sel == g.current {
		g.plan_msg = "pick a destination on the galaxy map first (View > Galaxy map)"
		return
	}
	e, linked := gen.edge_between(&g.galaxy, g.current, g.map_sel)
	if !linked {
		if !force {
			g.plan_msg = "that system is not linked from here"
			return
		}
		e = gen.Edge{a = g.current, b = g.map_sel, distance = gen.distance(&g.galaxy, g.current, g.map_sel)}
	}
	if ok, reason := sim.can_jump(&g.sys, &g.ship); !ok {
		g.plan_msg = reason
		return
	}
	years := sim.jump_years(e.distance, sim.CLASSES[g.ship.class].cryo_speed)
	g.cryo.active = true
	g.cryo.dest = g.map_sel
	g.cryo.t_start = t
	g.cryo.t_arrive = t + years * core.SECONDS_PER_YEAR
	g.cryo.from = g.sys.name
	g.cryo.notes = ""
	g.ship.mode = .Cryo
	g.ship.autoburn.active = false
	clear(&g.ship.nodes)
	g.ap = {}
	g.map_open = false
	g.planning = false
	g.cryo_pending = -1
	clock.paused = false
	g.warp_to = 0
}

// One frame of transit: advance up to 30 game days, catching the galaxy up.
cryo_step :: proc(g: ^Game, clock: ^core.Clock) {
	step := min(30 * core.SECONDS_PER_DAY, g.cryo.t_arrive - clock.t)
	clock.t += step
	g.gecon.systems[g.current].last_t = clock.t
	econ.galaxy_advance(&g.gecon, clock.t, -1)
	if clock.t >= g.cryo.t_arrive - 1e-6 {
		clock.t = g.cryo.t_arrive
		years := (g.cryo.t_arrive - g.cryo.t_start) / core.SECONDS_PER_YEAR
		game_enter_system(g, g.cryo.dest, clock.t)
		sim.arrive(&g.sys, &g.ship, clock.t)
		g.focus = Focus{.Ship, 0}
		g.cryo.active = false
		g.plan_msg = fmt.tprintf("arrived after %.1f years: parked in orbit outside the planets, plot a course inward", years)
		g.map_sel = -1
	}
}

// Trade the current hull for a new class at the docked yard.
buy_ship :: proc(g: ^Game, c: econ.Class_Id, t: f64) {
	if g.yard_station < 0 || g.yard_station >= len(g.econ.markets) do return
	m := &g.econ.markets[g.yard_station]
	if m.ships[c] <= 0 do return
	price := econ.class_price(m, c)
	credit := econ.trade_in_value(g.ship.class)
	if g.credits + credit < price do return
	g.credits += credit - price
	m.ships[c] -= 1
	old_cap := g.ship.stats.cargo_cap
	sim.refit(&g.ship, c)
	// Cargo that no longer fits is sold to the market.
	over := sim.cargo_used(&g.ship) - g.ship.stats.cargo_cap
	for slot in 0 ..< sim.CARGO_SLOTS {
		if over <= 0 do break
		take := min(over, g.ship.cargo[slot])
		if take <= 0 do continue
		_, rev := econ.sell(m, econ.Commodity(slot), take)
		g.ship.cargo[slot] -= take
		g.credits += rev
		over -= take
	}
	_ = old_cap
	g.ship.propellant = max(g.ship.propellant, g.ship.stats.propellant_cap * 0.5)
	g.ship.name = econ.CLASS_NAMES[c]
	_ = t
}

// Buy (positive units) or sell (negative) at the docked market.
apply_trade :: proc(g: ^Game, tr: ui.Trade) {
	if g.market_station < 0 || g.market_station >= len(g.econ.markets) do return
	m := &g.econ.markets[g.market_station]
	slot := int(tr.commodity)
	if econ.is_colony(m) {
		// No dock: the order joins the shuttle's queue.
		if g.shuttle.market != g.market_station {
			g.plan_msg = "the shuttle is still working another colony"
			return
		}
		sim.shuttle_order(&g.shuttle, tr.commodity, tr.units)
		return
	}
	if tr.units > 0 {
		want := min(tr.units, sim.cargo_free(&g.ship))
		moved, cost := econ.buy(m, tr.commodity, want, g.credits)
		g.ship.cargo[slot] += moved
		g.credits -= cost
	} else {
		want := min(-tr.units, g.ship.cargo[slot])
		moved, revenue := econ.sell(m, tr.commodity, want)
		g.ship.cargo[slot] -= moved
		g.credits += revenue
	}
}

// Maneuver-node editing: N adds, [ ] retime, = - ' ; change Δv, drag a node
// along its path, T warps to the burn, B arms the autoburn, Delete removes.
node_input :: proc(g: ^Game, cam: ^render.Camera, t: f64, real_dt: f64, ui_hot: bool) {
	s := &g.ship
	if sim.is_dead(s) do return
	changed := false
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	mult := shift ? 5.0 : 1.0

	if input.pressed(.Node_Add) do node_add_ahead(g, t)
	if g.selected >= len(s.nodes) do g.selected = len(s.nodes) - 1
	if g.selected >= 0 {
		n := &s.nodes[g.selected]
		seg_period := 3600.0
		for seg in s.segments do if seg.end == .Node && seg.node == g.selected && seg.orbit.e < 1 { seg_period = orbit.period(seg.orbit); break }
		dt_rate := seg_period * 0.05 * mult * real_dt
		if input.down(.Node_Earlier) { n.t = max(n.t - dt_rate, t + 1); changed = true }
		if input.down(.Node_Later) { n.t += dt_rate; changed = true }
		dv_rate := 0.002 * mult * real_dt
		if input.down(.Node_Prograde_Up) { n.prograde += dv_rate; changed = true }
		if input.down(.Node_Prograde_Down) { n.prograde -= dv_rate; changed = true }
		if input.down(.Node_Radial_Up) { n.radial += dv_rate; changed = true }
		if input.down(.Node_Radial_Down) { n.radial -= dv_rate; changed = true }
		if input.pressed(.Node_Remove) || rl.IsKeyPressed(.BACKSPACE) do node_delete(g, t)
		if g.selected >= 0 {
			if input.pressed(.Warp_To_Burn) do node_warp(g, t)
			if input.pressed(.Execute_Burn) do node_execute(g, t)
		}
	}

	// Mouse: drag the Pe or Ap marker to raise or lower the orbit (a burn at
	// the opposite apsis, armed on release); click a node to select it, drag
	// it along its segment to retime.
	if !ui_hot {
		m := rl.GetMousePosition()
		if rl.IsMouseButtonPressed(.LEFT) && g.drag_apsis == 0 && s.mode == .On_Rails && len(s.segments) > 0 && s.orbit.e < 1 && !g.ap.active {
			base := g.sys.pos[s.primary]
			pe := render.world_to_screen(cam, base + orbit.point_at_anomaly(s.orbit, 0))
			ap := render.world_to_screen(cam, base + orbit.point_at_anomaly(s.orbit, math.PI))
			near :: proc(p: [2]f32, m: rl.Vector2) -> bool { return abs(p.x - m.x) < 12 && abs(p.y - m.y) < 12 }
			if near(pe, m) do g.drag_apsis = 1
			else if near(ap, m) do g.drag_apsis = 2
			if g.drag_apsis != 0 {
				// The burn happens at the other apsis; start with no change.
				t_burn := s.orbit.e < 0.01 ? t + 60 : sim.next_apsis_time(s.orbit, t, g.drag_apsis == 1 ? math.PI : 0)
				clear(&s.nodes)
				s.autoburn.active = false
				g.selected = sim.node_add(s, sim.Node{t = t_burn})
				changed = true
			}
		}
		if g.drag_apsis != 0 {
			if rl.IsMouseButtonDown(.LEFT) && g.selected >= 0 && g.selected < len(s.nodes) {
				n := &s.nodes[g.selected]
				b := g.sys.bodies[s.primary]
				base := g.sys.pos[s.primary]
				mw := render.screen_to_world(cam, {m.x, m.y})
				lo := s.primary == gen.STAR ? b.radius * 1.6 : b.radius * 1.2
				hi := s.primary == gen.STAR ? max(g.sys.extent * 2, lo * 2) : b.soi * 0.9
				r_new := clamp(orbit.length(mw - base), lo, hi)
				pos, vel := orbit.state_at(s.orbit, n.t)
				n.prograde = sim.apsis_burn(b.mu, orbit.length(pos), orbit.length(vel), r_new)
				changed = true
			}
			if rl.IsMouseButtonReleased(.LEFT) {
				if g.selected >= 0 && g.selected < len(s.nodes) && abs(s.nodes[g.selected].prograde) > 1e-6 do sim.arm_node(s, g.selected)
				else do node_delete(g, t)
				g.drag_apsis = 0
			}
		} else if rl.IsMouseButtonPressed(.LEFT) {
			for seg, i in s.segments {
				if seg.end != .Node do continue
				sp := render.world_to_screen(cam, render.node_world_pos(&g.sys, s.segments[:], i))
				if abs(sp.x - m.x) < 12 && abs(sp.y - m.y) < 12 {
					g.selected = seg.node
					g.dragging = true
				}
			}
		}
		if g.dragging && rl.IsMouseButtonDown(.LEFT) && g.selected >= 0 && g.selected < len(s.nodes) {
			// Nearest time on the segment that leads to this node.
			for seg, i in s.segments {
				if seg.end != .Node || seg.node != g.selected do continue
				base := render.segment_base(&g.sys, s.segments[:], i)
				span := seg.orbit.e < 1 ? orbit.period(seg.orbit) : sim.HORIZON_MAX / 4
				best_t := s.nodes[g.selected].t
				best_d: f64 = 1e300
				for k in 1 ..= 400 {
					tt := seg.t0 + span * f64(k) / 400
					sp := render.world_to_screen(cam, base + orbit.position_at(seg.orbit, tt))
					d := f64((sp.x - m.x) * (sp.x - m.x) + (sp.y - m.y) * (sp.y - m.y))
					if d < best_d { best_d = d; best_t = tt }
				}
				s.nodes[g.selected].t = max(best_t, t + 1)
				changed = true
				break
			}
		}
		if rl.IsMouseButtonReleased(.LEFT) do g.dragging = false
	} else {
		g.dragging = false
	}

	if changed {
		sim.nodes_sort(s)
		if s.mode == .On_Rails do sim.repredict(&g.sys, s, t)
	}
}

// The hover popover for the pinned entity.
draw_popover :: proc(g: ^Game, cam: ^render.Camera, lib: ^art.Library, t: f64) -> (ui.Pop_Action, rl.Rectangle, bool) {
	f := g.pin
	pos, _ := entity_position(g, f, t)
	anchor := render.world_to_screen(cam, pos)
	v := ui.Popover_View{anchor = {anchor.x, anchor.y}}
	lines := make([dynamic]string, context.temp_allocator)
	buttons := make([dynamic]ui.Pop_Button, context.temp_allocator)
	dockable, _ := sim.dockable_station(&g.sys, &g.ship)
	tstation, thas := trade_market(g)
	here := thas ? &g.econ.markets[tstation] : nil
	switch f.kind {
	case .Body:
		b := g.sys.bodies[f.index]
		v.title = b.name
		v.subtitle = b.is_moon ? fmt.tprintf("%v moon of %s", b.kind, g.sys.bodies[b.parent].name) : fmt.tprintf("%v planet", b.kind)
		v.doc = art.library_get(lib, render.body_doc_name(b))
		v.doc_px = 30
		v.doc_rot = f32(b.spin * t)
		ov := make([]art.Override, 6, context.temp_allocator)
		toks := [6]string{"surface", "surface2", "feature", "feature2", "accent", "highlight"}
		for k in 0 ..< 6 do ov[k] = {toks[k], b.colors[k]}
		v.overrides = ov
		if b.kind == .Star {
			v.doc_state = "core_only"
			ov[0] = {"star_core", b.colors[0]}
			v.subtitle = gen.star_describe(g.sys.star)
			append(&lines, fmt.tprintf("%.2f solar masses, %.0f K, %.3g L", g.sys.star.mass, g.sys.star.temperature, g.sys.star.luminosity))
			if note := gen.star_hazard_note(g.sys.star); note != "" do append(&lines, note)
			else do append(&lines, fmt.tprintf("hull cooks inside %.0f", g.sys.star.heat_radius))
		} else {
			append(&lines, fmt.tprintf("%.2f Earth masses, %.0f K", b.mass, b.temp))
			append(&lines, fmt.tprintf("orbit %.0f, period %s", b.orbit.a, core.clock_duration(orbit.period(b.orbit))))
			append(&lines, fmt.tprintf("sphere of influence %.0f", b.soi))
		}
		if b.colony {
			if mi, ok := market_for_key(g, .Body, f.index); ok {
				m := &g.econ.markets[mi]
				best_s, best_g := -1.0, -1.0
				scarce, glut := "", ""
				for c in econ.Commodity {
					ratio := m.target[c] > 0 ? m.stock[c] / m.target[c] : 1
					if 1 - ratio > best_s { best_s = 1 - ratio; scarce = econ.NAMES[c] }
					if ratio - 1 > best_g { best_g = ratio - 1; glut = econ.NAMES[c] }
				}
				append(&lines, fmt.tprintf("%s: wants %s, surplus %s", m.name, scarce, glut))
				append(&lines, fmt.tprintf("shuttle range %.0f from the centre", gen.shuttle_range(b)))
			}
		}
		if b.kind != .Star {
			append(&buttons, ui.Pop_Button{"Go", .Go, !sim.is_dead(&g.ship), ""})
			append(&buttons, ui.Pop_Button{"Choose route...", .Plot_Course, !sim.is_dead(&g.ship), ""})
		}
		if int(g.ship.primary) == f.index do append(&buttons, ui.Pop_Button{"Orbit here at...", .Orbit_At, g.ship.mode == .On_Rails, "coast first"})
		if b.colony {
			at := here != nil && int(here.body) == f.index && here.station < 0
			append(&buttons, ui.Pop_Button{"Trade", .Trade, at, "park in a low orbit; a shuttle carries the goods"})
			append(&buttons, ui.Pop_Button{"Talk to vendor", .Talk, at, "talk from a low orbit"})
			append(&buttons, ui.Pop_Button{"Jobs", .Jobs, at, "see what the colony posts, from a low orbit"})
		}
	case .Station:
		st := g.sys.stations[f.index]
		v.title = st.name
		v.subtitle = fmt.tprintf("%v, orbiting %s", st.kind, g.sys.bodies[st.parent].name)
		v.doc = art.library_get(lib, render.station_doc_name(st.kind))
		v.doc_px = 10
		ov := make([]art.Override, 1, context.temp_allocator)
		ov[0] = {"station_accent", render.station_color(st.kind)}
		v.overrides = ov
		if f.index < len(g.econ.markets) {
			m := &g.econ.markets[f.index]
			best_s, best_g := -1.0, -1.0
			scarce, glut := "", ""
			for c in econ.Commodity {
				ratio := m.target[c] > 0 ? m.stock[c] / m.target[c] : 1
				if 1 - ratio > best_s { best_s = 1 - ratio; scarce = econ.NAMES[c] }
				if ratio - 1 > best_g { best_g = ratio - 1; glut = econ.NAMES[c] }
			}
			append(&lines, fmt.tprintf("wants: %s", scarce))
			append(&lines, fmt.tprintf("surplus: %s", glut))
			if m.is_yard do append(&lines, "sells ships")
		}
		docked_here := g.ship.mode == .Docked && g.ship.dock == f.index
		in_range := dockable == f.index
		append(&buttons, ui.Pop_Button{"Go and dock", .Go, !docked_here && !sim.is_dead(&g.ship), ""})
		append(&buttons, ui.Pop_Button{"Choose route...", .Plot_Course, !docked_here && !sim.is_dead(&g.ship), ""})
		if docked_here {
			append(&buttons, ui.Pop_Button{"Undock", .Undock, true, ""})
		} else {
			append(&buttons, ui.Pop_Button{"Dock", .Dock, in_range, "get within docking range at matched speed"})
		}
		at_station := here != nil && here.station == f.index
		append(&buttons, ui.Pop_Button{"Trade", .Trade, at_station, "trade once docked or within range"})
		append(&buttons, ui.Pop_Button{"Talk to vendor", .Talk, at_station, "talk once docked or within range"})
		append(&buttons, ui.Pop_Button{"Jobs", .Jobs, at_station, "see what the station posts, once docked or within range"})
		if f.index < len(g.econ.markets) && g.econ.markets[f.index].is_yard {
			append(&buttons, ui.Pop_Button{"Shipyard", .Shipyard, at_station, "buy hulls once docked or within range"})
		}
	case .Npc:
		n := &g.fleet.npcs[f.index]
		v.title = n.name
		v.subtitle = fmt.tprintf("%s trader", econ.CLASS_NAMES[n.ship.class])
		v.doc = art.library_get(lib, sim.CLASSES[n.ship.class].art)
		v.doc_state = "idle"
		v.doc_px = v.doc != nil ? min(2.4, 54 / art.doc_length(v.doc)) : 2.4
		ov := make([]art.Override, 1, context.temp_allocator)
		ov[0] = {"hull", n.tint}
		v.overrides = ov
		if n.role == .Surveyor {
			v.subtitle = fmt.tprintf("%s survey ship", econ.CLASS_NAMES[n.ship.class])
			append(&lines, sim.survey_status(n, &g.sys))
			if passes := n.surveyed + n.skim.cycles; passes > 0 {
				append(&lines, fmt.tprintf("%d passes made, gas at %.0f%%", passes, n.skim.density * 100))
			}
			append(&lines, "survey hull: built to sit in the dust")
		} else {
			switch n.state {
			case .Flying:   append(&lines, fmt.tprintf("%s -> %s", n.ap.status, g.econ.markets[n.route.to].name))
			case .Planning: append(&lines, "plotting a course")
			case .Surveying, .Trading, .Dwelling: append(&lines, n.ship.mode == .Docked ? fmt.tprintf("docked at %s", g.sys.stations[n.ship.dock].name) : "parked in orbit")
			}
		}
		append(&lines, npc_cargo_line(n))
		pilot, _ := person_of(g, .Npc, f.index, context.temp_allocator)
		names := people.PERSONALITY_NAMES
		append(&lines, fmt.tprintf("pilot %s, %s", pilot.name, names[pilot.personality]))
		docked_here := g.ship.mode == .Docked && g.ship.docked_ship && g.ship.dock == f.index
		near_idx, near := sim.dockable_ship(&g.sys, &g.ship, sim.fleet_ships(&g.fleet))
		append(&buttons, ui.Pop_Button{"Rendezvous", .Go, n.ship.mode == .On_Rails && !docked_here && !sim.is_dead(&g.ship), "the trader must be coasting"})
		append(&buttons, ui.Pop_Button{"Choose route...", .Plot_Course, n.ship.mode == .On_Rails && !docked_here && !sim.is_dead(&g.ship), "the trader must be coasting"})
		if docked_here {
			append(&buttons, ui.Pop_Button{"Undock", .Undock, true, ""})
			append(&buttons, ui.Pop_Button{"Talk", .Talk, true, ""})
		} else {
			append(&buttons, ui.Pop_Button{"Ask to dock", .Dock, near && near_idx == f.index, "get within docking range at matched speed"})
		}
	case .Nebula:
		n := g.sys.nebulae[f.index]
		v.title = n.name
		v.subtitle = gen.nebula_describe(n.kind)
		v.swatch = true
		v.swatch_cols = n.colors
		v.swatch_seed = n.seed
		v.swatch_ring = n.hollow > 0
		append(&lines, gen.nebula_note(n.kind))
		if n.hollow > 0 {
			append(&lines, fmt.tprintf("a shell from %.0f out to %.0f", n.hollow, n.radius))
		} else {
			append(&lines, fmt.tprintf("%.0f across", n.radius * 2))
		}
		yields := econ.nebula_yield_names(n.kind)
		names := make([dynamic]string, context.temp_allocator)
		for c in yields do append(&names, econ.NAMES[c])
		append(&lines, fmt.tprintf("yields %s", strings.join(names[:], ", ", context.temp_allocator)))
		here, density := sim.skim_here(&g.sys, &g.ship)
		inside := here == f.index
		if inside {
			rate, _ := sim.hazard_at(&g.sys, ship_world(g, t))
			append(&lines, fmt.tprintf("you are in it: gas %.0f%%, hull -%.2f%%/h", density * 100, rate * 100 * core.SECONDS_PER_HOUR))
		}
		append(&buttons, ui.Pop_Button{"Go", .Go, !sim.is_dead(&g.ship), ""})
		append(&buttons, ui.Pop_Button{"Choose route...", .Plot_Course, !sim.is_dead(&g.ship), ""})
		if sim.skim_active(&g.skim) && g.skim.nebula == f.index {
			append(&buttons, ui.Pop_Button{"Stop skimming", .Skim_Stop, true, ""})
		} else {
			append(&buttons, ui.Pop_Button{"Skim gas", .Skim, inside && g.ship.mode != .Docked, "fly into the cloud first"})
		}
	case .Ship:
		v.title = g.ship.name
		v.subtitle = "your ship"
		v.doc = art.library_get(lib, sim.CLASSES[g.ship.class].art)
		v.doc_state = "idle"
		v.doc_px = v.doc != nil ? min(2.4, 54 / art.doc_length(v.doc)) : 2.4
		append(&lines, fmt.tprintf("%v around %s", g.ship.mode, g.sys.bodies[g.ship.primary].name))
		append(&lines, fmt.tprintf("hull %.0f%%, propellant %.0f%%, hold %.0f/%.0f", 100 * g.ship.hull, 100 * g.ship.propellant / g.ship.stats.propellant_cap, sim.cargo_used(&g.ship), g.ship.stats.cargo_cap))
	case .None:
	}
	append(&buttons, ui.Pop_Button{"Look at", .Look_At, true, ""})
	v.lines = lines[:]
	v.buttons = buttons[:]
	return ui.popover_draw(v)
}

// What an NPC is carrying. A trader carries its route's commodity; a
// surveyor carries whatever its scoop has pulled out of the cloud.
npc_cargo_line :: proc(n: ^sim.Npc) -> string {
	used := sim.cargo_used(&n.ship)
	if used <= 0.05 do return "carrying nothing"
	if n.role == .Trader && n.route.from != n.route.to {
		return fmt.tprintf("carrying %s, %.0f units", econ.NAMES[n.route.commodity], used)
	}
	best, best_v := econ.Commodity.Ore, 0.0
	for c in econ.Commodity do if n.ship.cargo[int(c)] > best_v { best, best_v = c, n.ship.cargo[int(c)] }
	return fmt.tprintf("carrying %s, %.0f units", econ.NAMES[best], used)
}

apply_popover :: proc(g: ^Game, cam: ^render.Camera, a: ui.Pop_Action, t: f64) {
	switch a {
	case .None:
	case .Plot_Course: begin_planning(g, t, destination_of(g, g.pin))
	case .Go:          go_to(g, destination_of(g, g.pin), t)
	case .Orbit_At:    open_orbit_prompt(g)
	case .Dock:
		if g.pin.kind == .Npc {
			if idx, ok := sim.dockable_ship(&g.sys, &g.ship, sim.fleet_ships(&g.fleet)); ok && idx == g.pin.index do request_ship_dock(g, idx, t)
		} else if idx, ok := sim.dockable_station(&g.sys, &g.ship); ok && idx == g.pin.index {
			sim.dock(&g.sys, &g.ship, idx, t)
		}
	case .Undock:      undock_player(g, t)
	case .Jobs:
		g.jobs_open = true
		g.jobs_board = true
	case .Talk:
		if g.pin.kind == .Npc do talk_open(g, .Npc, g.pin.index, "greeting", t)
		else if g.pin.kind == .Station do talk_open(g, .Station, g.pin.index, "greeting", t)
		else if g.pin.kind == .Body && g.sys.bodies[g.pin.index].colony do talk_open(g, .Body, g.pin.index, "greeting", t)
	case .Trade:       g.market_open = true
	case .Shipyard:    g.yard_open = true
	case .Skim:        start_skim(g, t)
	case .Skim_Stop:   sim.skim_stop(&g.skim)
	case .Look_At:     look_at(g, cam, g.pin, t)
	}
}

// The ship's absolute position right now; a few callers want it without the
// heading and velocity that `sim.state` also hands back.
ship_world :: proc(g: ^Game, t: f64) -> [2]f64 {
	p, _, _ := sim.state(&g.sys, &g.ship, t)
	return p
}

// Put the scoop out, or say why not.
start_skim :: proc(g: ^Game, t: f64) {
	if sim.skim_active(&g.skim) {
		sim.skim_stop(&g.skim)
		return
	}
	ok, why := sim.skim_start(&g.sys, &g.ship, &g.skim, t)
	if !ok {
		g.plan_msg = why
		audio.play(.Error)
		return
	}
	audio.play(.Confirm)
}
