package gen

// Star variants (docs/DESIGN.md §2.2). One roll from the "star" stream
// decides the kind and its numbers; `generate` and `summarize` both call
// `roll_star` so the galaxy map agrees with the full system.
//
// Sizes and luminosities are game scale, not astrophysics: a supergiant is
// impressively big and bright without pushing its planets out of reach.

import "core:fmt"
import "core:math"
import core "sim:core"

HEAT_LINE_K :: 900.0 // equilibrium temperature where hull damage starts

Star_Kind :: enum u8 {
	Main_Sequence,
	Giant,       // bloated, cool and bright: a red giant most of the time
	Supergiant,  // the rare monster: blue or red, hugely luminous
	White_Dwarf, // a dense fading ember
	Neutron,     // a city-sized remnant with a savage gravity well
	Pulsar,      // a spinning neutron star whose wind scours the inner system
	Brown_Dwarf, // failed star: barely warm, barely bright
}

Star :: struct {
	kind:        Star_Kind,
	mass:        f64,    // solar masses
	luminosity:  f64,    // solar
	temperature: f64,    // surface, kelvin (for the class letter and colour)
	radius:      f64,    // world units
	class:       string, // spectral letter, or a remnant tag (D, N, P, L)
	color:       [4]u8,
	heat_radius: f64,    // inside this the ship's hull cooks (world units)
	wind_radius: f64,    // pulsar only: wind damage zone, 0 otherwise
	spin:        f64,    // pulsar only: beam rotation, rad/s
}

// How often each kind turns up. Main-sequence stars dominate, as they should.
STAR_KIND_WEIGHTS :: [Star_Kind]f64 {
	.Main_Sequence = 70,
	.Giant         = 8,
	.Supergiant    = 2,
	.White_Dwarf   = 7,
	.Neutron       = 3,
	.Pulsar        = 3,
	.Brown_Dwarf   = 7,
}

// Spectral classes by temperature, hot to cool, and a rough initial-mass
// weighting so M dwarfs are common and O stars are a find.
SPECTRAL :: [7]struct {
	letter:  string,
	t_lo:    f64, // kelvin
	t_hi:    f64,
	m_lo:    f64, // solar masses
	m_hi:    f64,
	weight:  f64,
	color:   [4]u8,
} {
	{"O", 30000, 50000, 16,   40,   1,  {155, 176, 255, 255}},
	{"B", 10000, 30000, 2.5,  16,   4,  {170, 191, 255, 255}},
	{"A", 7500,  10000, 1.5,  2.5,  7,  {202, 215, 255, 255}},
	{"F", 6000,  7500,  1.05, 1.5,  10, {248, 247, 255, 255}},
	{"G", 5200,  6000,  0.8,  1.05, 18, {255, 244, 220, 255}},
	{"K", 3700,  5200,  0.5,  0.8,  20, {255, 210, 161, 255}},
	{"M", 2400,  3700,  0.1,  0.5,  40, {255, 180, 110, 255}},
}

// Pick an index by weight from the rng.
@(private = "file")
pick_weighted :: proc(r: ^core.Rng, weights: []f64) -> int {
	total := 0.0
	for w in weights do total += w
	u := core.rng_f64(r) * total
	for w, i in weights {
		u -= w
		if u < 0 do return i
	}
	return len(weights) - 1
}

// Roll the star from the "star" rng stream. The stream must be positioned
// right after the name so generate and summarize stay in step.
roll_star :: proc(r: ^core.Rng) -> (s: Star) {
	weights := STAR_KIND_WEIGHTS
	w_kind: [len(Star_Kind)]f64
	for k in Star_Kind do w_kind[int(k)] = weights[k]
	s.kind = Star_Kind(pick_weighted(r, w_kind[:]))
	switch s.kind {
	case .Main_Sequence:
		sp := SPECTRAL
		w: [7]f64
		for c, i in sp do w[i] = c.weight
		ci := pick_weighted(r, w[:])
		c := sp[ci]
		s.class = c.letter
		s.color = c.color
		s.mass = core.rng_log_range(r, c.m_lo, c.m_hi)
		s.temperature = core.rng_range(r, c.t_lo, c.t_hi)
		s.luminosity = min(math.pow(s.mass, 3.5), 1200)
		s.radius = core.STAR_RADIUS * math.pow(s.mass, 0.8)
	case .Giant:
		s.mass = core.rng_log_range(r, 1.0, 8.0)
		blue := core.rng_chance(r, 0.2)
		if blue {
			s.class = "B"
			s.temperature = core.rng_range(r, 10000, 20000)
			s.color = {190, 205, 255, 255}
			s.luminosity = core.rng_log_range(r, 300, 900)
			s.radius = core.STAR_RADIUS * core.rng_range(r, 5, 9)
		} else {
			s.class = core.rng_chance(r, 0.5) ? "K" : "M"
			s.temperature = core.rng_range(r, 3200, 4800)
			s.color = {255, 150, 90, 255}
			s.luminosity = core.rng_log_range(r, 60, 400)
			s.radius = core.STAR_RADIUS * core.rng_range(r, 10, 24)
		}
	case .Supergiant:
		s.mass = core.rng_log_range(r, 10, 30)
		if core.rng_chance(r, 0.4) {
			s.class = "B"
			s.temperature = core.rng_range(r, 12000, 25000)
			s.color = {175, 195, 255, 255}
			s.radius = core.STAR_RADIUS * core.rng_range(r, 14, 22)
		} else {
			s.class = "M"
			s.temperature = core.rng_range(r, 3000, 4000)
			s.color = {255, 120, 70, 255}
			s.radius = core.STAR_RADIUS * core.rng_range(r, 28, 45)
		}
		s.luminosity = core.rng_log_range(r, 1200, 3000)
	case .White_Dwarf:
		s.class = "D"
		s.mass = core.rng_range(r, 0.5, 1.2)
		s.temperature = core.rng_range(r, 8000, 30000)
		s.color = {225, 238, 255, 255}
		s.luminosity = core.rng_log_range(r, 0.002, 0.04)
		s.radius = core.STAR_RADIUS * 0.16
	case .Neutron, .Pulsar:
		s.class = s.kind == .Pulsar ? "P" : "N"
		s.mass = core.rng_range(r, 1.4, 2.1)
		s.temperature = core.rng_range(r, 300000, 1000000)
		s.color = {200, 225, 255, 255}
		s.luminosity = core.rng_log_range(r, 0.0005, 0.005)
		s.radius = core.STAR_RADIUS * 0.08
		if s.kind == .Pulsar {
			s.wind_radius = core.rng_range(r, 500, 1100)
			s.spin = 2 * math.PI / core.rng_range(r, 2, 9) // one turn every few seconds
		}
	case .Brown_Dwarf:
		s.class = core.rng_chance(r, 0.5) ? "L" : "T"
		s.mass = core.rng_range(r, 0.02, 0.08)
		s.temperature = core.rng_range(r, 700, 2200)
		s.color = {170, 70, 90, 255}
		s.luminosity = core.rng_log_range(r, 0.00002, 0.0003)
		s.radius = core.STAR_RADIUS * 0.13
	}
	// Hull damage begins where the equilibrium temperature passes ~900 K,
	// never closer than a bit above the surface. Remnants are small but
	// their hard radiation reaches out several radii.
	s.heat_radius = max(s.radius * 1.5, core.TEMP_REF_A * math.pow(core.TEMP_REF / HEAT_LINE_K, 2) * math.sqrt(s.luminosity))
	if s.kind == .Neutron || s.kind == .Pulsar do s.heat_radius = max(s.heat_radius, s.radius * 8)
	if s.kind == .White_Dwarf do s.heat_radius = max(s.heat_radius, s.radius * 3)
	return
}

// Planet count per kind, from the "planets" stream (first draw).
planet_count :: proc(r: ^core.Rng, kind: Star_Kind) -> int {
	switch kind {
	case .Main_Sequence: return core.rng_int(r, 3, 10)
	case .Giant:         return core.rng_int(r, 2, 7)
	case .Supergiant:    return core.rng_int(r, 1, 5)
	case .White_Dwarf:   return core.rng_int(r, 1, 5)
	case .Neutron:       return core.rng_int(r, 0, 4)
	case .Pulsar:        return core.rng_int(r, 1, 4)
	case .Brown_Dwarf:   return core.rng_int(r, 1, 4)
	}
	return 3
}

// Innermost planet orbit for a star: outside the surface, the heat and any
// pulsar wind, then scaled by luminosity as before.
first_orbit :: proc(s: Star, jitter: f64) -> f64 {
	a := max(4 * s.radius, 350 * math.sqrt(s.luminosity) * jitter)
	a = max(a, s.heat_radius * 1.8)
	if s.wind_radius > 0 do a = max(a, s.wind_radius * 1.3)
	return a
}

// Short human description: "G-type main sequence", "red giant", "pulsar".
star_describe :: proc(s: Star) -> string {
	switch s.kind {
	case .Main_Sequence: return fmt.tprintf("%s-type main sequence star", s.class)
	case .Giant:         return s.class == "B" ? "blue giant" : "red giant"
	case .Supergiant:    return s.class == "B" ? "blue supergiant" : "red supergiant"
	case .White_Dwarf:   return "white dwarf"
	case .Neutron:       return "neutron star"
	case .Pulsar:        return "pulsar"
	case .Brown_Dwarf:   return "brown dwarf"
	}
	return "star"
}

// One line of what makes it dangerous, or "" when nothing special.
star_hazard_note :: proc(s: Star) -> string {
	switch s.kind {
	case .Pulsar:      return fmt.tprintf("pulsar wind out to %.0f: slow hull damage", s.wind_radius)
	case .Neutron:     return "crushing gravity: hard radiation near the surface"
	case .Supergiant:  return fmt.tprintf("hull cooks inside %.0f", s.heat_radius)
	case .Giant:       return fmt.tprintf("hull cooks inside %.0f", s.heat_radius)
	case .Main_Sequence, .White_Dwarf, .Brown_Dwarf:
	}
	return ""
}
