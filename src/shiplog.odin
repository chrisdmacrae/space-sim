package main

// What goes in the ship's log. The panel in src/ui/log.odin only draws; this
// decides what is worth writing down and when. Everything is edge-triggered
// off a snapshot of last frame's state, so a condition that holds for an hour
// is logged once, when it starts.

import "core:fmt"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"
import orbit "sim:orbit"
import sim "sim:sim"
import ui "sim:ui"

// Last frame's world, for the edges.
Log_State :: struct {
	inited:     bool,
	mode:       sim.Ship_Mode,
	hazard:     sim.Hazard,
	primary:    gen.Body_Handle,
	dock:       int,
	system:     int,
	stage:      sim.Stage,
	prop_step:  int, // 0 above a quarter, 1 below a quarter, 2 below a tenth
	hull_step:  int, // 0 above half, 1 below half, 2 below a quarter
	jump_ready: bool,
}

// "Y1 D003 04:12" - short enough to leave the line to the message.
log_stamp :: proc(t: f64) -> string {
	c := core.clock_calendar(t)
	return fmt.tprintf("Y%d D%03d %02d:%02d", c.year, c.day, c.hour, c.minute)
}

log_line :: proc(g: ^Game, t: f64, kind: ui.Log_Kind, msg: string) {
	ui.log_push(&g.log, log_stamp(t), kind, msg)
}

// The orbit the ship has settled into, and what settled it.
log_orbit :: proc(g: ^Game, t: f64, why: string) {
	s := &g.ship
	b := g.sys.bodies[s.primary]
	o := s.mode == .On_Rails ? s.orbit : (len(s.segments) > 0 ? s.segments[0].orbit : s.orbit)
	if o.e < 1 {
		log_line(g, t, .Orbit, fmt.tprintf("%s, %s: Pe %.2f  Ap %.2f  e %.3f  T %s", why, b.name,
			orbit.periapsis(o) - b.radius, orbit.apoapsis(o) - b.radius, o.e, core.clock_duration(orbit.period(o))))
	} else {
		log_line(g, t, .Orbit, fmt.tprintf("%s, %s: Pe %.2f  escape  e %.3f", why, b.name,
			orbit.periapsis(o) - b.radius, o.e))
	}
}

// Called once a frame: everything that changed since the last one.
log_update :: proc(g: ^Game, t: f64) {
	s := &g.ship
	st := &g.log_state
	if !st.inited {
		st^ = Log_State{inited = true, mode = s.mode, hazard = s.hazard, primary = s.primary, dock = s.dock, system = g.current, stage = g.ap.stage}
		log_line(g, t, .Info, fmt.tprintf("Log opened: %s, %s system", econ.CLASS_NAMES[s.class], g.sys.name))
		log_orbit(g, t, "holding")
	}
	if g.current != st.system {
		st.system = g.current
		log_line(g, t, .Good, fmt.tprintf("Arrived in the %s system", g.sys.name))
		log_orbit(g, t, "holding")
		// A jump resets everything the flags below track.
		st.mode, st.hazard, st.primary, st.dock = s.mode, s.hazard, s.primary, s.dock
		st.prop_step, st.hull_step, st.jump_ready = 0, 0, false
	}

	// ---- hull and hazards
	if s.hazard != st.hazard {
		switch s.hazard {
		case .Heat: log_line(g, t, .Alarm, fmt.tprintf("HEAT: inside the heat line of %s, hull -%.1f%%/h", g.sys.bodies[0].name, s.hazard_rate * 100 * core.SECONDS_PER_HOUR))
		case .Wind: log_line(g, t, .Alarm, fmt.tprintf("PULSAR WIND: hull -%.1f%%/h", s.hazard_rate * 100 * core.SECONDS_PER_HOUR))
		case .Dust:
			neb := ""
			if idx, _ := gen.nebula_at(&g.sys, g.sys.pos[s.primary] + s.pos); idx >= 0 do neb = g.sys.nebulae[idx].name
			log_line(g, t, .Warn, fmt.tprintf("Into the gas of %s: dust scours the hull, -%.2f%%/h", neb, s.hazard_rate * 100 * core.SECONDS_PER_HOUR))
		case .None: if !sim.is_dead(s) do log_line(g, t, .Good, "Clear of the hazard, hull holding")
		}
		st.hazard = s.hazard
	}
	hull_step := s.hull < 0.25 ? 2 : (s.hull < 0.5 ? 1 : 0)
	if hull_step > st.hull_step && !sim.is_dead(s) {
		log_line(g, t, hull_step == 2 ? .Alarm : .Warn, fmt.tprintf("Hull at %.0f%%", s.hull * 100))
	}
	st.hull_step = hull_step

	// ---- tanks
	pf := s.stats.propellant_cap > 0 ? s.propellant / s.stats.propellant_cap : 0
	prop_step := pf < 0.1 ? 2 : (pf < 0.25 ? 1 : 0)
	if prop_step > st.prop_step {
		log_line(g, t, prop_step == 2 ? .Alarm : .Warn, fmt.tprintf("Propellant at %.0f%%, dv %.4f left", pf * 100, sim.dv_remaining(s)))
	}
	st.prop_step = prop_step

	// ---- what the ship is doing
	if s.mode != st.mode {
		was := st.mode
		st.mode = s.mode
		b := g.sys.bodies[s.primary]
		switch s.mode {
		case .Thrusting:
			log_line(g, t, .Info, s.autoburn.active ? fmt.tprintf("Burn started, dv %.4f", s.autoburn.dv) : "Engine lit")
		case .On_Rails:
			if was == .Thrusting do log_orbit(g, t, "burn complete")
			else if was == .Docked do log_line(g, t, .Info, "Cast off")
			else do log_orbit(g, t, "coasting")
		case .Docked:
			where_: string
			if s.docked_ship do where_ = s.dock < len(g.fleet.npcs) ? g.fleet.npcs[s.dock].name : "another ship"
			else do where_ = s.dock < len(g.sys.stations) ? g.sys.stations[s.dock].name : "a station"
			log_line(g, t, .Good, fmt.tprintf("Docked with %s, riding its orbit of %s", where_, b.name))
		case .Wrecked:
			log_line(g, t, .Alarm, fmt.tprintf("WRECKED on %s", b.name))
		case .Destroyed:
			cause: string
			switch s.hazard {
			case .Heat: cause = fmt.tprintf("hull cooked by %s", g.sys.bodies[0].name)
			case .Wind: cause = "hull shredded by the pulsar wind"
			case .Dust: cause = "hull scoured away in the gas"
			case .None: cause = fmt.tprintf("fell into %s", g.sys.bodies[0].name)
			}
			log_line(g, t, .Alarm, fmt.tprintf("DESTROYED: %s", cause))
		case .Cryo:
			log_line(g, t, .Info, "Cryo engaged")
		}
	}
	if s.primary != st.primary {
		st.primary = s.primary
		if !sim.is_dead(s) do log_orbit(g, t, "sphere of influence changed")
	}

	// ---- autopilot
	if g.ap.stage != st.stage {
		st.stage = g.ap.stage
		if g.ap.stage == .Failed do log_line(g, t, .Warn, fmt.tprintf("Autopilot gave up: %s", g.ap.status))
	}

	// ---- the way out of the system
	ready, _ := sim.can_jump(&g.sys, s)
	if ready != st.jump_ready {
		st.jump_ready = ready
		if ready do log_line(g, t, .Good, "Escape trajectory: cryo jump available from here")
	}
}
