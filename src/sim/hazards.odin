package sim

// Ship health and the things that lower it (docs/DESIGN.md §5.7). Hull is a
// 0..1 fraction. Nothing repairs it yet. Two hazards exist so far, both
// from the star: heat inside the star's heat line, and a pulsar's wind.
// Hitting the star, or running the hull to zero, destroys the ship outright.

import gen "sim:gen"
import orbit "sim:orbit"
import core "sim:core"

Hazard :: enum u8 {
	None,
	Heat, // inside Star.heat_radius: flux grows as 1/r^2
	Wind, // inside Star.wind_radius (pulsars)
	Dust, // inside a nebula: grain scour, and worse in a supernova shell
}

HEAT_HULL_HOURS :: 4.0   // hours to lose the whole hull sitting on the heat line
WIND_HULL_HOURS :: 20.0  // hours to lose the whole hull deep in a pulsar's wind
DUST_SHOCKED    :: 4.0   // a supernova remnant is shock-heated: that much worse
// ... and the ordinary-gas rate is a knob (core/tuning.odin: dust_hull_hours).

// Hull loss per second at a world position, and which hazard dominates.
hazard_at :: proc(sys: ^gen.System, world: [2]f64) -> (rate: f64, kind: Hazard) {
	star := sys.star
	r := orbit.length(world - sys.pos[0])
	if r < star.heat_radius {
		flux := (star.heat_radius / max(r, 1e-6))
		rate += flux * flux / (HEAT_HULL_HOURS * core.SECONDS_PER_HOUR)
		kind = .Heat
	}
	if star.wind_radius > 0 && r < star.wind_radius {
		w := (1.2 - r / star.wind_radius) / (WIND_HULL_HOURS * core.SECONDS_PER_HOUR)
		if kind == .None || w > rate do kind = .Wind
		rate += w
	}
	// Gas and grit: slow everywhere, but a supernova shell is still hot.
	if idx, density := gen.nebula_at(sys, world); idx >= 0 {
		mult := sys.nebulae[idx].kind == .Supernova ? DUST_SHOCKED : 1.0
		d := density * mult / (f64(core.tuning.dust_hull_hours) * core.SECONDS_PER_HOUR)
		if kind == .None || d > rate do kind = .Dust
		rate += d
	}
	return
}

// Apply hazard damage over a frame. Docked, sleeping and dead ships are
// left alone (a station shields its guests).
apply_hazards :: proc(sys: ^gen.System, s: ^Ship, t, dt: f64) {
	if s.mode != .On_Rails && s.mode != .Thrusting do return
	world := sys.pos[s.primary] + s.pos
	rate, kind := hazard_at(sys, world)
	if kind == .Dust && s.dust_hardened {
		// A survey hull is built to sit in gas: ablative, and replaced often.
		// It is why survey work is its own trade and not a sideline.
		s.hazard = .None
		s.hazard_rate = 0
		return
	}
	s.hazard = kind
	s.hazard_rate = rate
	if rate <= 0 do return
	s.hull -= rate * dt
	if s.hull <= 0 {
		s.hull = 0
		blow_up(s)
	}
}

// The ship is gone: no model, no engine, no plan. Where it was stays put so
// the effect can play there.
blow_up :: proc(s: ^Ship) {
	s.mode = .Destroyed
	s.throttle = 0
	s.vel = 0
	s.hull = 0
	s.autoburn.active = false
	clear(&s.segments)
	clear(&s.nodes)
}

// Wrecked on a surface or destroyed: either way it is not flying again.
is_dead :: proc(s: ^Ship) -> bool {
	return s.mode == .Wrecked || s.mode == .Destroyed
}
