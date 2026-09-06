package sim

// Interstellar travel (docs/DESIGN.md §7). A ship on an escape trajectory
// from the star may engage cryo for a linked system. Time passes in years;
// the arrival is a hyperbolic approach the pilot must capture from.

import "core:math"
import core "sim:core"
import gen "sim:gen"
import orbit "sim:orbit"

// Beyond this the star's grip is treated as gone: the system boundary.
system_boundary :: proc(sys: ^gen.System) -> f64 {
	return sys.extent * 2.5
}

// Can the ship engage cryo right now? Escaping the star, or already past the boundary.
can_jump :: proc(sys: ^gen.System, s: ^Ship) -> (ok: bool, reason: string) {
	if s.mode != .On_Rails do return false, "ship must be coasting"
	if s.primary != gen.STAR do return false, "leave the planet's sphere first"
	if s.orbit.e >= 1 || orbit.length(s.pos) > system_boundary(sys) do return true, ""
	return false, "you need an escape trajectory from the star (raise apoapsis past the boundary)"
}

// Years the trip takes.
jump_years :: proc(distance_ly, cryo_speed: f64) -> f64 {
	return distance_ly / max(cryo_speed, 1e-6)
}

// The cryo drive ends its run with the deceleration burn built in: the ship
// wakes in a circular parking orbit about the star, prograde with the
// system and clear of every planet's sphere. Deterministic per (system,
// arrival time).
arrive :: proc(sys: ^gen.System, s: ^Ship, t: f64) {
	r := core.rng_make(core.sub_seed(sys.seed, "arrival", int(t / 3600)))
	star := sys.bodies[0]
	radius := arrival_radius(sys)
	dir := 1.0
	if len(sys.bodies) > 1 do dir = sys.bodies[1].orbit.dir
	ang := core.rng_range(&r, 0, 2 * math.PI)
	s.primary = gen.STAR
	s.mode = .On_Rails
	s.orbit = orbit.circular(star.mu, radius, ang, t, dir)
	s.pos, s.vel = orbit.state_at(s.orbit, t)
	s.heading = math.atan2(s.vel.y, s.vel.x)
	s.throttle = 0
	s.hold = .None
	s.autoburn.active = false
	clear(&s.nodes)
	repredict(sys, s, t)
}

// Parking radius: past the outermost planet's apoapsis and sphere with a
// margin, but well inside the boundary so the system is close at hand.
arrival_radius :: proc(sys: ^gen.System) -> f64 {
	radius := sys.bodies[0].radius * 12
	for b, i in sys.bodies do if i > 0 && b.parent == gen.STAR {
		radius = max(radius, orbit.apoapsis(b.orbit) + b.soi * 3)
	}
	for belt in sys.belts do radius = max(radius, belt.radius + belt.width * 1.5)
	// Wake just outside the gas, not in it: going into a cloud should be a
	// decision, and at a nebula site it is the only one on offer.
	for n in sys.nebulae do radius = max(radius, orbit.length(n.center) + n.radius * 1.05)
	radius = max(radius, sys.star.heat_radius * 2, sys.star.wind_radius * 1.5)
	return min(radius * 1.1, system_boundary(sys) * 0.6)
}
