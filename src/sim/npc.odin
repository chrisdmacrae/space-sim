package sim

// NPC traders (docs/DESIGN.md §5.3): dock, pick the best route from here,
// load, fly it with the shared autopilot (impulsive burns), sell, repeat.

import "core:fmt"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"

import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"

Npc_State :: enum u8 {
	Trading,   // docked; chooses and loads the next route
	Planning,  // a course search is running on the worker thread
	Flying,
	Dwelling,
	Surveying, // parked in a nebula with the scoop out (skim.odin)
}

// What a ship in the fleet is out here for. Traders run the route table;
// surveyors work a nebula, and exist in systems that have no markets at all.
Npc_Role :: enum u8 {
	Trader,
	Surveyor,
}

// A course search plus node shooting for one trader, run off the main
// thread on a copy of the ship. Planning reads only orbital elements, never
// the per-frame position caches, so it is safe beside the frame update.
Plan_Job :: struct {
	active:  bool,
	done:    bool, // written by the worker, read atomically
	thread:  ^thread.Thread,
	sys:     ^gen.System,
	npc:     int,
	ship:    Ship, // private copy with its own node/segment arrays
	ap:      Autopilot,
	dest:    Destination,
	t:       f64,
	ok:      bool,
	station: int, // where the trader was docked
}

Npc :: struct {
	ship:      Ship,
	ap:        Autopilot,
	state:     Npc_State,
	route:     econ.Route,
	has_route: bool,
	dwell_until: f64,
	credits:   f64,
	failures:  int,
	name:      string, // owned by the fleet arena
	tint:      [4]u8,
	seed:      u64,
	trades:    int,
	reported:  bool,
	exploded:  bool, // the destruction effect has played (render bookkeeping)
	visitor:   bool, // the player is docked to this ship: hold the orbit, no plans
	hailed_at: f64,  // game time this trader last hailed the player, 0 never
	hail_spent: bool, // it has had its hail for this approach: cleared when it drifts out of range
	hail_muted: bool, // the player ignored it: this trader does not call again
	role:      Npc_Role,
	skim:      Skim, // surveyors: the scoop, the same one the player uses
	cloud:     int,  // surveyors: the nebula they work, index into sys.nebulae
	surveyed:  int,  // surveyors: passes made in total, across every patch
	selling:   bool, // surveyors: hold is full, running the haul to a market
}

Fleet :: struct {
	plans_this_frame: int, // planning budget: searches are the expensive part
	job:    Plan_Job,
	npcs:   [dynamic]Npc,
	routes: []econ.Route, // shared route table
	routes_at: f64,       // game time it was computed
	arena_names: [dynamic]string,
}

fleet_destroy :: proc(f: ^Fleet) {
	job_finish(f, nil, 0, nil) // joins a running search first
	for &n in f.npcs do destroy(&n.ship)
	delete(f.npcs)
	delete(f.routes)
	for n in f.arena_names do delete(n)
	delete(f.arena_names)
}

// Spawn traders docked at random markets.
fleet_spawn :: proc(f: ^Fleet, sys: ^gen.System, e: ^econ.Economy, t: f64) {
	fleet_destroy(f)
	f^ = {}
	// Traders need somewhere to dock; surveyors do not, so a nebula site
	// with no stations at all still has ships in it.
	if len(sys.stations) == 0 {
		fleet_spawn_surveyors(f, sys, e, t)
		return
	}
	r := core.rng_make(core.sub_seed(sys.seed, "traffic"))
	count := core.rng_int(&r, 5, 10)
	for i in 0 ..< count {
		st := core.rng_int(&r, 0, len(sys.stations))
		n: Npc
		n.seed = core.sub_seed(sys.seed, "npc", i)
		nr := core.rng_make(n.seed)
		name := fmt.aprintf("%s %s", gen.make_name(&nr), core.rng_pick(&nr, []string{"Hauler", "Trader", "Runner", "Freighter"}))
		append(&f.arena_names, name)
		n.name = name
		// Monochrome hulls: traders differ by shade of grey only.
		v := u8(core.rng_int(&nr, 95, 200))
		n.tint = {v, v, v, 255}
		roll := core.rng_f64(&nr)
		class := econ.Class_Id.Courier
		switch {
		case roll < 0.40: class = .Courier
		case roll < 0.70: class = .Hauler
		case roll < 0.85: class = .Freighter
		case roll < 0.95: class = .Clipper
		case:             class = .Sleeper
		}
		n.ship = spawn_in_orbit(sys, sys.stations[st].parent, 0.3, t, CLASSES[class].stats)
		n.ship.class = class
		n.ship.name = name
		n.ship.impulsive = true
		dock(sys, &n.ship, st, t)
		n.state = .Dwelling
		n.dwell_until = t + core.rng_range(&nr, 0, 6 * core.SECONDS_PER_HOUR)
		n.credits = 20000
		append(&f.npcs, n)
	}
	fleet_spawn_surveyors(f, sys, e, t)
}

// Survey ships working the system's nebulae. They need no station and no
// route table, so a nebula site with nothing else in it still has traffic.
SURVEYORS_PER_CLOUD :: 4

@(private = "file")
fleet_spawn_surveyors :: proc(f: ^Fleet, sys: ^gen.System, e: ^econ.Economy, t: f64) {
	for neb, ni in sys.nebulae {
		r := core.rng_make(core.sub_seed(sys.seed, "survey", ni))
		count := core.rng_int(&r, 2, SURVEYORS_PER_CLOUD + 1)
		for i in 0 ..< count {
			n: Npc
			n.role = .Surveyor
			n.cloud = ni
			n.seed = core.sub_seed(neb.seed, "surveyor", i)
			nr := core.rng_make(n.seed)
			name := fmt.aprintf("%s %s", gen.make_name(&nr), core.rng_pick(&nr, []string{"Survey", "Prospector", "Scout", "Sounder"}))
			append(&f.arena_names, name)
			n.name = name
			v := u8(core.rng_int(&nr, 95, 200))
			n.tint = {v, v, v, 255}
			class := core.rng_chance(&nr, 0.6) ? econ.Class_Id.Courier : econ.Class_Id.Hauler
			p := survey_point(sys, ni, &nr)
			n.ship = spawn_at_point(sys, p, t, CLASSES[class].stats)
			n.ship.class = class
			n.ship.name = name
			n.ship.impulsive = true
			n.ship.dust_hardened = true
			skim_stop(&n.skim)
			n.state = .Surveying
			n.dwell_until = t + core.rng_range(&nr, 0, 12) * core.SECONDS_PER_HOUR
			n.credits = 8000
			append(&f.npcs, n)
		}
	}
}

// A place inside a cloud worth sitting in: sampled towards the thick parts.
@(private = "file")
survey_point :: proc(sys: ^gen.System, ni: int, r: ^core.Rng) -> [2]f64 {
	neb := sys.nebulae[ni]
	best: [2]f64
	best_d := -1.0
	for _ in 0 ..< 24 {
		ang := core.rng_range(r, 0, 2 * math.PI)
		u := neb.hollow > 0 ? core.rng_range(r, neb.hollow / neb.radius, 1) : math.sqrt(core.rng_f64(r))
		p := neb.center + {math.cos(ang) * neb.radius * u, math.sin(ang) * neb.radius * u}
		if d := gen.nebula_density_at(neb, p); d > best_d {
			best_d = d
			best = p
		}
	}
	return sys.pos[0] + best
}

ROUTE_REFRESH :: 6 * core.SECONDS_PER_HOUR

// Advance every trader. Route table refreshes periodically.
fleet_update :: proc(f: ^Fleet, sys: ^gen.System, e: ^econ.Economy, t0, dt: f64) {
	t := t0 + dt
	if f.routes == nil || t - f.routes_at > ROUTE_REFRESH {
		delete(f.routes)
		f.routes = econ.route_table(e, sys, 40, 40) // scored for a mid-sized hold
		f.routes_at = t
	}
	f.plans_this_frame = 0
	job_poll(f, sys, e, t)
	for &n in f.npcs {
		when NPC_DEBUG {
			t1 := time.tick_now()
			update(sys, &n.ship, t0, dt)
			d1 := time.tick_since(t1)
			t2 := time.tick_now()
			autopilot_update(sys, &n.ship, &n.ap, t)
			d2 := time.tick_since(t2)
			t3 := time.tick_now()
			npc_think(f, &n, sys, e, t)
			d3 := time.tick_since(t3)
			if time.duration_milliseconds(d1 + d2 + d3) > 15 {
				fmt.printfln("SLOW %s: update %.0fms autopilot %.0fms (stage %v %s) think %.0fms (state %v) primary=%v e=%.3f nodes=%d",
					n.name, time.duration_milliseconds(d1), time.duration_milliseconds(d2), n.ap.stage, n.ap.status, time.duration_milliseconds(d3), n.state, n.ship.primary, n.ship.orbit.e, len(n.ship.nodes))
			}
		} else {
			update(sys, &n.ship, t0, dt)
			autopilot_update(sys, &n.ship, &n.ap, t)
			npc_think(f, &n, sys, e, t)
		}
		if n.role == .Surveyor && n.state == .Surveying do skim_step(sys, &n.ship, &n.skim, dt)
	}
}

// One course search per frame across the fleet keeps frames smooth.
// Package-visible: survey.odin plans its moves through the same budget.
@(private)
plan_budget :: proc(f: ^Fleet) -> bool {
	if f.plans_this_frame >= 1 do return false
	f.plans_this_frame += 1
	return true
}

@(private = "file")
npc_think :: proc(f: ^Fleet, n: ^Npc, sys: ^gen.System, e: ^econ.Economy, t: f64) {
	s := &n.ship
	if is_dead(s) {
		when NPC_DEBUG {
			if !n.reported {
				n.reported = true
				fmt.printfln("%s wrecked while state=%v ap.active=%v stage=%v status=%s", n.name, n.state, n.ap.active, n.ap.stage, n.ap.status)
			}
		}
		// Traffic is abstract: a lost ship is replaced. A trader comes back
		// at a port; a surveyor comes back in the cloud it was working,
		// which is the only place a nebula site has to put it.
		n.reported = false
		n.failures = 99
		n.ap.active = false
		if n.role == .Surveyor do survey_respawn(n, sys, t)
		else do strand(f, n, sys, e, t)
		return
	}
	// Whatever it is doing, an impact ahead comes first. If no burn it can
	// afford clears it, the trader is abstracted back to a port.
	if s.mode == .On_Rails && impact_ahead(s) {
		if dodge(sys, s, &n.ap, t) do return
		n.ap.active = false
		n.failures = 99
		if n.role == .Surveyor do survey_respawn(n, sys, t)
		else do strand(f, n, sys, e, t)
		return
	}
	if n.visitor do return
	if n.role == .Surveyor {
		survey_think(f, n, sys, e, t)
		return
	}
	switch n.state {
	case .Dwelling:
		if t < n.dwell_until do return
		n.state = .Trading
	case .Trading:
		if !plan_budget(f) do return
		here, at_market := npc_market(sys, e, s)
		if !at_market {
			// Stranded off-station: try to fly to the nearest reachable station;
			// after repeated failures the trader is abstracted back to a port.
			strand(f, n, sys, e, t)
			return
		}
		// Sell whatever is aboard, then pick a route from here.
		m := &e.markets[here]
		for c in econ.Commodity {
			slot := int(c)
			if s.cargo[slot] > 0 {
				_, rev := econ.sell(m, c, s.cargo[slot])
				n.credits += rev
				s.cargo[slot] = 0
				n.trades += 1
			}
		}
		if !pick_route(f, n, sys, e, here, t) {
			n.dwell_until = t + 2 * core.SECONDS_PER_HOUR
			n.state = .Dwelling
			return
		}
		// Load.
		r := n.route
		want := cargo_free(s)
		moved, cost := econ.buy(&e.markets[r.from], r.commodity, want, n.credits)
		s.cargo[int(r.commodity)] += moved
		n.credits -= cost
		// Refuel. Traders always leave full: buy what the market has and
		// top up abstractly, so a dry market never strands the fleet.
		need := s.stats.propellant_cap - s.propellant
		if need > 0.01 {
			fm := &e.markets[here]
			got, fuel_cost := econ.buy(fm, .Propellant, need * 10, n.credits) // 10 units of propellant per mass unit
			n.credits -= fuel_cost
			_ = got
			s.propellant = s.stats.propellant_cap
		}
		dest := market_dest(e, r.to)
		if job_start(f, n, sys, dest, t) {
			n.state = .Planning
		} else {
			n.dwell_until = t + core.SECONDS_PER_HOUR
			n.state = .Dwelling
		}
	case .Planning:
		// Waiting for the worker; job_poll moves us on.
	case .Surveying:
		n.state = .Dwelling // a trader has no business sitting in the gas
	case .Flying:
		if n.ap.active do return
		if _, ok := npc_market(sys, e, s); n.ap.stage == .Done && ok {
			n.state = .Dwelling
			n.dwell_until = t + core.rng_range(&(core.Rng{state = n.seed ~ u64(t)}), 2, 6) * core.SECONDS_PER_HOUR
			return
		}
		// Failed: try again from wherever we are, or give up and park.
		if !plan_budget(f) do return
		when NPC_DEBUG do fmt.printfln("%s: autopilot %v (%s) mode=%v primary=%v transitions=%d", n.name, n.ap.stage, n.ap.status, s.mode, s.primary, s.transitions)
		n.failures += 1
		if n.failures <= 3 && s.mode == .On_Rails {
			dest := market_dest(e, n.route.to)
			if job_start(f, n, sys, dest, t) {
				n.state = .Planning
				return
			}
		}
		// Park: nearest station of the current primary, or just orbit.
		if idx, ok := dockable_station(sys, s); ok {
			dock(sys, s, idx, t)
			n.state = .Dwelling
			n.dwell_until = t + core.SECONDS_PER_HOUR
		} else {
			n.state = .Dwelling
			n.dwell_until = t + 2 * core.SECONDS_PER_HOUR
		}
	}
}

// A trader that is not docked when it wants to trade. Wrecked or repeatedly
// failed ships are re-spawned docked at a port: NPC traffic is abstract, and
// a stuck ship is worse than a quietly replaced one.
@(private = "file")
strand :: proc(f: ^Fleet, n: ^Npc, sys: ^gen.System, e: ^econ.Economy, t: f64) {
	s := &n.ship
	if s.mode == .On_Rails && n.failures < 6 {
		best := -1
		for st, i in sys.stations do if st.parent == s.primary { best = i; break }
		if best < 0 && len(sys.stations) > 0 do best = int(core.mix64(n.seed ~ u64(t)) % u64(len(sys.stations)))
		if best < 0 { survey_hold(n, t); return }
		if best >= 0 {
			dest := Destination{kind = .Station, index = best}
			n.route = econ.Route{from = best, to = best}
			if job_start(f, n, sys, dest, t) {
				n.state = .Planning
				return
			}
		}
		n.failures += 1
		n.dwell_until = t + 2 * core.SECONDS_PER_HOUR
		n.state = .Dwelling
		return
	}
	if len(sys.stations) == 0 {
		// Nowhere to put it: hold where it is and try again later.
		n.failures = 0
		n.state = .Dwelling
		n.dwell_until = t + core.SECONDS_PER_DAY
		return
	}
	when NPC_DEBUG do fmt.printfln("%s: respawned at a port after %d failures (mode %v)", n.name, n.failures, s.mode)
	r := core.rng_make(n.seed ~ u64(t))
	st := core.rng_int(&r, 0, len(sys.stations))
	cargo := s.cargo
	prop := s.stats.propellant_cap
	destroy(s)
	class := s.class
	s^ = spawn_in_orbit(sys, sys.stations[st].parent, 0.3, t, CLASSES[class].stats)
	s.class = class
	s.name = n.name
	s.impulsive = true
	s.cargo = cargo
	s.propellant = prop
	dock(sys, s, st, t)
	n.failures = 0
	n.ap = {}
	n.state = .Dwelling
	n.dwell_until = t + core.SECONDS_PER_HOUR
}

// Best route starting at the docked market, with a little seeded noise so
// traders spread over the table.
@(private = "file")
pick_route :: proc(f: ^Fleet, n: ^Npc, sys: ^gen.System, e: ^econ.Economy, here: int, t: f64) -> bool {
	best := -1
	best_score := 0.0
	rr := core.rng_make(n.seed ~ u64(t / 3600))
	for r, i in f.routes {
		if r.from != here do continue
		// Only routes the planner can actually fly from this frame.
		if _, ok, _ := geometry(sys, &n.ship, market_dest(e, r.to)); !ok do continue
		score := r.rate * core.rng_range(&rr, 0.7, 1.3)
		if score > best_score {
			best_score = score
			best = i
		}
	}
	if best < 0 do return false
	n.route = f.routes[best]
	n.has_route = true
	return true
}

// Absolute position/heading for drawing.
// The player docks: the trader holds its orbit and drops any plan.
npc_receive_visitor :: proc(sys: ^gen.System, n: ^Npc, t: f64) {
	n.visitor = true
	n.ap.active = false
	n.ship.autoburn.active = false
	clear(&n.ship.nodes)
	if n.ship.mode == .On_Rails do repredict(sys, &n.ship, t)
}

// The player leaves: resume the route from here (the Flying branch replans).
npc_visitor_left :: proc(n: ^Npc, t: f64) {
	n.visitor = false
	n.failures = 0
	n.ap.active = false
	n.ap.stage = .Failed
	n.state = .Flying
	n.dwell_until = t
}

// The market a trader can trade at right now: the station it is docked
// at, or the colony whose body it is parked around.
npc_market :: proc(sys: ^gen.System, e: ^econ.Economy, s: ^Ship) -> (int, bool) {
	if s.mode == .Docked && !s.docked_ship {
		for &m, i in e.markets do if m.station == s.dock do return i, true
		return -1, false
	}
	for &m, i in e.markets do if m.station < 0 && at_colony(sys, s, m.body) do return i, true
	return -1, false
}

// Ships of the fleet as a slice, for docking checks.
fleet_ships :: proc(f: ^Fleet, allocator := context.temp_allocator) -> []Ship {
	out := make([]Ship, len(f.npcs), allocator)
	for &n, i in f.npcs do out[i] = n.ship
	return out
}

npc_state :: proc(sys: ^gen.System, n: ^Npc, t: f64) -> (pos: [2]f64, heading: f64) {
	p, v, h := state(sys, &n.ship, t)
	_ = v
	return p, h
}

_ :: math

// ---------------------------------------------------------------- planning job

// Copy a ship for the worker: the arrays must be private.
@(private = "file")
ship_copy :: proc(s: ^Ship) -> Ship {
	c := s^
	c.segments = make([dynamic]Segment)
	c.nodes = make([dynamic]Node)
	for seg in s.segments do append(&c.segments, seg)
	for n in s.nodes do append(&c.nodes, n)
	return c
}

@(private = "file")
job_worker :: proc(job: ^Plan_Job) {
	defer sync.atomic_store(&job.done, true)
	s := &job.ship
	if s.mode == .Docked do undock(job.sys, s, job.t)
	geo, ok, _ := geometry(job.sys, s, job.dest)
	if !ok do return
	res := search(job.sys, s, geo, job.t, true)
	c := res.picks[.Balanced]
	if !res.ok || !c.ok || !c.fits do return
	autopilot_start(job.sys, s, &job.ap, geo, job.dest, .Balanced, c, job.t, res.flybys[.Balanced])
	job.ok = true
	free_all(context.temp_allocator)
}

// Start a search for one ship of the fleet. Only one runs at a time; returns
// false if busy. Shared with survey.odin.
@(private)
job_start :: proc(f: ^Fleet, n: ^Npc, sys: ^gen.System, dest: Destination, t: f64) -> bool {
	if f.job.active do return false
	idx := -1
	for &m, i in f.npcs do if &m == n { idx = i; break }
	if idx < 0 do return false
	f.job = Plan_Job{active = true, sys = sys, npc = idx, ship = ship_copy(&n.ship), dest = dest, t = t, station = n.ship.mode == .Docked ? n.ship.dock : -1}
	f.job.thread = thread.create_and_start_with_poly_data(&f.job, job_worker)
	return f.job.thread != nil
}

// Collect a finished job: undock the real ship and hand it the plan.
@(private = "file")
job_poll :: proc(f: ^Fleet, sys: ^gen.System, e: ^econ.Economy, t: f64) {
	if !f.job.active || !sync.atomic_load(&f.job.done) do return
	job_finish(f, sys, t, e)
}

@(private = "file")
job_finish :: proc(f: ^Fleet, sys: ^gen.System, t: f64, e: ^econ.Economy) {
	if !f.job.active do return
	thread.join(f.job.thread)
	thread.destroy(f.job.thread)
	f.job.thread = nil
	f.job.active = false
	if sys == nil || f.job.npc >= len(f.npcs) {
		destroy(&f.job.ship)
		return
	}
	n := &f.npcs[f.job.npc]
	s := &n.ship
	if f.job.ok {
		if s.mode == .Docked do undock(sys, s, t)
		delete(s.nodes)
		delete(s.segments)
		s.nodes = f.job.ship.nodes
		s.segments = f.job.ship.segments
		f.job.ship.nodes = nil
		f.job.ship.segments = nil
		s.autoburn = f.job.ship.autoburn
		n.ap = f.job.ap
		repredict(sys, s, t)
		n.state = .Flying
		n.failures = 0
	} else {
		when NPC_DEBUG do fmt.printfln("%s: no plan to station %d", n.name, f.job.dest.index)
		n.failures += 1
		if s.mode != .Docked {
			if idx, ok := dockable_station(sys, s); ok do dock(sys, s, idx, t)
		}
		n.dwell_until = t + 3 * core.SECONDS_PER_HOUR
		n.state = .Dwelling
	}
	destroy(&f.job.ship)
	_ = e
}
