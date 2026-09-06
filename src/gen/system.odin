package gen

// Seeded star system generation (docs/DESIGN.md §2). Everything here is a
// function of the seed; nothing is stored. Bodies are laid out so parents
// precede children, which lets position updates run in one pass.

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import core "sim:core"
import orbit "sim:orbit"

Body_Handle :: distinct i32
NONE :: Body_Handle(-1)
STAR :: Body_Handle(0)

Body_Kind :: enum u8 {
	Star,
	Molten,
	Rock,
	Atmospheric,
	Gas,
	Ice,
}

Body :: struct {
	name:    string,
	parent:  Body_Handle,
	kind:    Body_Kind,
	mu:      f64, // G * mass (G = 1)
	mass:    f64, // earth masses (solar masses for the star)
	radius:  f64,
	orbit:   orbit.Orbit, // relative to parent; unused for the star
	soi:     f64,
	temp:    f64, // equilibrium temperature
	spin:    f64, // rad per game second, for drawing
	is_moon: bool,
	colony:  bool, // a settlement on the surface with its own market, traded by shuttle
	variant: int,      // which art document of the kind
	colors:  [6][4]u8, // surface, surface2, feature, feature2, accent, highlight
	seed:    u64,
}

VARIANTS := [Body_Kind]int{.Star = 1, .Molten = 2, .Rock = 3, .Atmospheric = 3, .Gas = 3, .Ice = 2}

Belt :: struct {
	name:   string,
	radius: f64,
	width:  f64,
	count:  int,
	seed:   u64,
}

Station_Kind :: enum u8 {
	Hub,
	Shipyard,
	Refinery,
	Depot,
	Habitat,
}

Station :: struct {
	name:   string,
	kind:   Station_Kind,
	parent: Body_Handle,
	orbit:  orbit.Orbit,
}

System :: struct {
	seed:        u64,
	name:        string,
	star:        Star,
	bodies:      [dynamic]Body,
	belts:       [dynamic]Belt,
	stations:    [dynamic]Station,
	nebulae:     [dynamic]Nebula, // gas clouds; no mass, no orbit, see nebula.odin
	is_site:     bool,            // the system *is* a nebula: no planets, no stations
	pos:         [dynamic][2]f64, // per body, absolute; filled by update
	vel:         [dynamic][2]f64,
	station_pos: [dynamic][2]f64,
	station_vel: [dynamic][2]f64,
	extent:      f64, // largest apoapsis, for framing
	arena:       virtual.Arena, // owns every allocation above
}

destroy :: proc(sys: ^System) {
	virtual.arena_destroy(&sys.arena)
	sys^ = {}
}

temperature :: proc(luminosity, a: f64) -> f64 {
	return core.TEMP_REF * math.pow(luminosity, 0.25) * math.sqrt(core.TEMP_REF_A / a)
}

generate :: proc(seed: u64) -> (sys: System) {
	_ = virtual.arena_init_growing(&sys.arena)
	context.allocator = virtual.arena_allocator(&sys.arena)
	sys.seed = seed

	// ---- star
	rs := core.rng_make(core.sub_seed(seed, "star"))
	sys.name = make_name(&rs)
	sys.star = roll_star(&rs)
	m := sys.star.mass
	L := sys.star.luminosity
	star_mu := core.MU_SOLAR * m
	star_radius := sys.star.radius
	append(&sys.bodies, Body {
		name   = sys.name,
		parent = NONE,
		kind   = .Star,
		mu     = star_mu,
		mass   = m,
		radius = star_radius,
		soi    = math.inf_f64(1),
		seed   = core.sub_seed(seed, "star"),
		colors = {sys.star.color, sys.star.color, sys.star.color, sys.star.color, sys.star.color, sys.star.color},
	})

	// ---- nebula. Rolled before anything is laid out because a site nebula
	// replaces the system: the cloud and its core star are all there is.
	neb := roll_nebula(seed, sys.star)
	sys.is_site = neb.site

	// ---- planets: lay out semi-major axes, then type by temperature and mass
	rp := core.rng_make(core.sub_seed(seed, "planets"))
	count := planet_count(&rp, sys.star.kind)
	if neb.site do count = 0
	a := first_orbit(sys.star, core.rng_range(&rp, 0.8, 1.3))
	prev_apo := star_radius * 3
	prev_soi := 0.0
	for i in 0 ..< count {
		pseed := core.sub_seed(seed, "planet", i)
		r := core.rng_make(pseed)
		T := temperature(L, a)
		kind, mass := classify(&r, T)
		mu := mass * core.MU_EARTH
		soi := orbit.soi_radius(a, mu, star_mu)
		// Close-in worlds of dim stars can have spheres smaller than a low
		// orbit; push them out until a station fits (sphere grows with a).
		if rad := body_radius(kind, mass); soi < rad * 4.5 {
			a *= rad * 4.5 / soi
			soi = rad * 4.5
		}
		// Eccentricity, clamped so this orbit clears the previous one's apoapsis
		// plus both spheres of influence.
		u := core.rng_f64(&r)
		e := 0.25 * u * u
		need := prev_apo * 1.08 + prev_soi + soi
		e_max := 1 - need / a
		if e_max < 0.01 {
			a = need / 0.99
			e_max = 0.01
		}
		e = min(e, e_max)
		dir: f64 = core.rng_chance(&r, 0.04) ? -1 : 1
		b := Body {
			name    = fmt.aprintf("%s %s", sys.name, ROMAN[i]),
			parent  = STAR,
			kind    = kind,
			mu      = mu,
			mass    = mass,
			radius  = body_radius(kind, mass),
			orbit   = orbit.make(star_mu, a, e, core.rng_range(&r, 0, 2 * math.PI), core.rng_range(&r, 0, 2 * math.PI), 0, dir),
			soi     = soi,
			temp    = T,
			spin    = 2 * math.PI / core.rng_range(&r, 6, 40) / core.SECONDS_PER_HOUR,
			colony  = core.rng_chance(&r, colony_chance(kind)),
			seed    = pseed,
		}
		b.colors = body_colors(&r, kind)
		b.variant = core.rng_int(&r, 0, VARIANTS[kind])
		append(&sys.bodies, b)
		prev_apo = a * (1 + e)
		prev_soi = soi
		ratio := core.rng_range(&rp, 1.45, 2.1)
		if core.rng_chance(&rp, 0.25) do ratio *= 1.45 // leave a gap for a belt
		a *= ratio
	}

	// ---- moons (appended after all planets so parents precede children)
	planet_count := len(sys.bodies)
	for pi in 1 ..< planet_count {
		p := sys.bodies[pi]
		r := core.rng_make(core.sub_seed(p.seed, "moons"))
		n: int
		switch p.kind {
		case .Gas:
			n = core.rng_int(&r, 1, 5)
		case .Rock, .Atmospheric:
			n = core.rng_chance(&r, 0.35) ? 1 : 0
		case .Ice:
			n = core.rng_chance(&r, 0.25) ? 1 : 0
		case .Molten, .Star:
			n = 0
		}
		lo := p.radius * 2.0
		hi := p.soi * 0.45
		if hi < lo * 1.2 do n = 0
		am := lo
		for k in 0 ..< n {
			mseed := core.sub_seed(p.seed, "moon", k)
			mr := core.rng_make(mseed)
			am = am * core.rng_range(&mr, 1.4, 1.9)
			if am > hi do break
			mass := core.rng_log_range(&mr, 0.004, p.kind == .Gas ? 0.12 : 0.03)
			kind: Body_Kind = p.temp < core.TEMP_FROST ? .Ice : .Rock
			mu := mass * core.MU_EARTH
			b := Body {
				name    = fmt.aprintf("%s %c", p.name, LETTERS[k]),
				parent  = Body_Handle(pi),
				kind    = kind,
				mu      = mu,
				mass    = mass,
				radius  = core.MOON_R * math.pow(mass, 0.3),
				orbit   = orbit.make(p.mu, am, 0.1 * core.rng_f64(&mr) * core.rng_f64(&mr), core.rng_range(&mr, 0, 2 * math.PI), core.rng_range(&mr, 0, 2 * math.PI), 0, p.orbit.dir),
				soi     = orbit.soi_radius(am, mu, p.mu),
				temp    = p.temp,
				spin    = 2 * math.PI / core.rng_range(&mr, 20, 200) / core.SECONDS_PER_HOUR,
				is_moon = true,
				colony  = core.rng_chance(&mr, 0.15),
				seed    = mseed,
			}
			b.colors = body_colors(&mr, kind)
			b.variant = core.rng_int(&mr, 0, 2) // moon documents
			append(&sys.bodies, b)
		}
	}

	// ---- belts in wide gaps, and sometimes one past the last planet
	rb := core.rng_make(core.sub_seed(seed, "belts"))
	for i in 1 ..< planet_count - 1 {
		a0 := sys.bodies[i].orbit.a
		a1 := sys.bodies[i + 1].orbit.a
		if a1 / a0 > 2.3 {
			rad := math.sqrt(a0 * a1)
			append(&sys.belts, Belt{name = fmt.aprintf("%s Belt", make_name(&rb)), radius = rad, width = rad * 0.07, count = 500, seed = core.sub_seed(seed, "belt", i)})
		}
	}
	if planet_count > 1 && core.rng_chance(&rb, 0.4) {
		rad := sys.bodies[planet_count - 1].orbit.a * 1.7
		append(&sys.belts, Belt{name = fmt.aprintf("%s Belt", make_name(&rb)), radius = rad, width = rad * 0.08, count = 700, seed = core.sub_seed(seed, "belt", 99)})
	}

	// ---- stations
	place_stations(&sys)

	// ---- extent, then the nebula measured against it
	for b, i in sys.bodies do if i > 0 && b.parent == STAR do sys.extent = max(sys.extent, orbit.apoapsis(b.orbit))
	for belt in sys.belts do sys.extent = max(sys.extent, belt.radius + belt.width)
	if neb.present {
		// A site has no planets to be scaled against, so it gets the fixed
		// scale rather than one that swings with the star's luminosity.
		scale := neb.site || sys.extent <= 0 ? NEBULA_SITE_SCALE : sys.extent
		n := make_nebula(neb, scale, sys.star)
		append(&sys.nebulae, n)
		// The cloud is part of the system: frame it, and let a ship jumping
		// in arrive outside it rather than in the middle of the gas.
		sys.extent = max(sys.extent, orbit.length(n.center) + n.radius)
	}

	// ---- caches
	resize(&sys.pos, len(sys.bodies))
	resize(&sys.vel, len(sys.bodies))
	resize(&sys.station_pos, len(sys.stations))
	resize(&sys.station_vel, len(sys.stations))
	update(&sys, 0)
	return
}

// Fill absolute positions and velocities at time t. One pass; parents first.
update :: proc(sys: ^System, t: f64) {
	for &b, i in sys.bodies {
		if b.parent == NONE {
			sys.pos[i] = 0
			sys.vel[i] = 0
			continue
		}
		p, v := orbit.state_at(b.orbit, t)
		sys.pos[i] = sys.pos[b.parent] + p
		sys.vel[i] = sys.vel[b.parent] + v
	}
	for &s, i in sys.stations {
		p, v := orbit.state_at(s.orbit, t)
		sys.station_pos[i] = sys.pos[s.parent] + p
		sys.station_vel[i] = sys.vel[s.parent] + v
	}
}

// Deepest body whose sphere of influence contains the absolute point.
primary_at :: proc(sys: ^System, point: [2]f64) -> Body_Handle {
	best := STAR
	for &b, i in sys.bodies {
		if i == 0 do continue
		if orbit.length(point - sys.pos[i]) < b.soi {
			// Moons are listed after planets, so a later hit is deeper.
			if b.parent == best || best == STAR do best = Body_Handle(i)
		}
	}
	return best
}

@(private = "file")
classify :: proc(r: ^core.Rng, T: f64) -> (kind: Body_Kind, mass: f64) {
	switch {
	case T > core.TEMP_MOLTEN:
		kind = core.rng_chance(r, 0.15) ? .Rock : .Molten
		mass = core.rng_log_range(r, 0.1, 1.5)
	case T > core.TEMP_ROCK:
		kind = .Rock
		mass = core.rng_log_range(r, 0.1, 2.0)
	case T > core.TEMP_FROST:
		mass = core.rng_log_range(r, 0.1, 3.0)
		kind = mass >= 0.4 ? .Atmospheric : .Rock
	case:
		gas_p := T < 90 ? 0.35 : 0.55
		if core.rng_chance(r, gas_p) {
			kind = .Gas
			mass = core.rng_log_range(r, 3.0, 7.0)
		} else {
			kind = .Ice
			mass = core.rng_log_range(r, 0.05, 1.0)
		}
	}
	return
}

@(private = "file")
body_radius :: proc(kind: Body_Kind, mass: f64) -> f64 {
	switch kind {
	case .Gas:
		return core.PLANET_R_GAS * math.pow(mass / 5, 0.3)
	case .Atmospheric:
		return core.PLANET_R_ATMO * math.pow(mass, 0.3)
	case .Ice:
		return core.PLANET_R_ICE * math.pow(mass, 0.3)
	case .Molten, .Rock:
		return core.PLANET_R_ROCK * math.pow(mass, 0.3)
	case .Star:
		return core.STAR_RADIUS
	}
	return core.PLANET_R_ROCK
}

@(private = "file")
colony_chance :: proc(kind: Body_Kind) -> f64 {
	switch kind {
	case .Atmospheric: return 0.9
	case .Rock:        return 0.6
	case .Ice:         return 0.5
	case .Molten:      return 0.4
	case .Gas:         return 0.3
	case .Star:        return 0
	}
	return 0
}

@(private = "file")
jitter :: proc(r: ^core.Rng, c: [4]u8, amount: f64) -> [4]u8 {
	out := c
	for i in 0 ..< 3 {
		v := f64(c[i]) + core.rng_range(r, -amount, amount)
		out[i] = u8(clamp(v, 0, 255))
	}
	return out
}

// Token colours (surface, surface2, feature, feature2, accent, highlight)
// for the kind's body documents, jittered per planet. Gas giants also get a
// hue shift so not every giant is tan.
@(private = "file")
body_colors :: proc(r: ^core.Rng, kind: Body_Kind) -> [6][4]u8 {
	switch kind {
	case .Molten:
		return {jitter(r, {70, 42, 38, 255}, 15), jitter(r, {54, 32, 30, 255}, 12), jitter(r, {255, 120, 30, 255}, 30),
			jitter(r, {190, 60, 20, 255}, 30), jitter(r, {120, 40, 30, 255}, 20), {255, 230, 150, 255}}
	case .Rock:
		base := jitter(r, {152, 132, 108, 255}, 35)
		return {base, jitter(r, base, 18), jitter(r, {112, 96, 78, 255}, 25), jitter(r, {168, 150, 124, 255}, 25),
			jitter(r, {90, 78, 64, 255}, 20), {190, 176, 156, 90}}
	case .Atmospheric:
		ocean := jitter(r, {36, 88, 170, 255}, 25)
		land := jitter(r, {72, 142, 68, 255}, 35)
		return {ocean, jitter(r, {150, 140, 90, 255}, 30), land, jitter(r, {54, 110, 150, 255}, 20),
			{255, 255, 255, 150}, {240, 246, 255, 230}}
	case .Gas:
		// Hue families: tan, blue, rust, pale green.
		fam := core.rng_int(r, 0, 4)
		base: [4]u8
		switch fam {
		case 0: base = {204, 172, 122, 255}
		case 1: base = {140, 170, 210, 255}
		case 2: base = {196, 120, 90, 255}
		case:   base = {170, 190, 160, 255}
		}
		dark := [4]u8{u8(f64(base[0]) * 0.72), u8(f64(base[1]) * 0.72), u8(f64(base[2]) * 0.72), 255}
		light := [4]u8{u8(min(f64(base[0]) * 1.15, 255)), u8(min(f64(base[1]) * 1.15, 255)), u8(min(f64(base[2]) * 1.15, 255)), 255}
		return {jitter(r, base, 12), jitter(r, dark, 12), jitter(r, {u8(f64(dark[0]) * 0.85), u8(f64(dark[1]) * 0.85), u8(f64(dark[2]) * 0.85), 255}, 12),
			jitter(r, light, 10), {light[0], light[1], light[2], 200}, {255, 250, 235, 120}}
	case .Ice:
		return {jitter(r, {204, 222, 236, 255}, 15), jitter(r, {186, 206, 224, 255}, 15), jitter(r, {146, 178, 208, 255}, 20),
			jitter(r, {214, 230, 240, 255}, 10), {255, 255, 255, 200}, {236, 244, 250, 200}}
	case .Star:
		return {}
	}
	return {}
}

// Station placement (docs/DESIGN.md §2.5). Orbits are circular around the
// parent at a fraction of its sphere of influence, clamped above the surface.
@(private = "file")
place_stations :: proc(sys: ^System) {
	r := core.rng_make(core.sub_seed(sys.seed, "stations"))
	planets := len(sys.bodies)
	for b, i in sys.bodies do if b.is_moon { planets = i; break }
	if planets < 2 do return

	// Pick hosts.
	habitable := -1
	best_score := -1.0
	giant := -1
	rock := -1
	biggest := 1
	for i in 1 ..< planets {
		b := sys.bodies[i]
		score: f64
		switch b.kind {
		case .Atmospheric: score = 3 + b.mass
		case .Rock:        score = 1 + (b.temp > 240 && b.temp < 420 ? 1 : 0)
		case .Ice:         score = 0.5
		case .Molten:      score = 0.3
		case .Gas:         score = 0.1
		case .Star:        score = 0
		}
		if score > best_score { best_score = score; habitable = i }
		if b.kind == .Gas && giant < 0 do giant = i
		if (b.kind == .Rock || b.kind == .Molten) && rock < 0 && i != habitable do rock = i
		if b.mass > sys.bodies[biggest].mass do biggest = i
	}
	if rock == habitable do rock = -1

	add :: proc(sys: ^System, r: ^core.Rng, kind: Station_Kind, host: int, frac: f64, suffix: string) {
		b := sys.bodies[host]
		alt := clamp(b.soi * frac, b.radius * 1.5, b.soi * 0.5)
		o := orbit.circular(b.mu, alt, core.rng_range(r, 0, 2 * math.PI), 0, b.orbit.dir)
		append(&sys.stations, Station{name = fmt.aprintf("%s %s", make_name(r), suffix), kind = kind, parent = Body_Handle(host), orbit = o})
	}

	add(sys, &r, .Hub, habitable, 0.12, "Exchange")
	add(sys, &r, .Shipyard, habitable, 0.22, "Yards")
	if rock >= 0 {
		add(sys, &r, .Refinery, rock, 0.15, "Works")
	} else if len(sys.belts) > 0 {
		belt := sys.belts[0]
		o := orbit.circular(sys.bodies[0].mu, belt.radius, core.rng_range(&r, 0, 2 * math.PI), 0)
		append(&sys.stations, Station{name = fmt.aprintf("%s Works", make_name(&r)), kind = .Refinery, parent = STAR, orbit = o})
	}
	if giant >= 0 {
		add(sys, &r, .Depot, giant, 0.1, "Depot")
	} else {
		for i in 1 ..< planets do if sys.bodies[i].kind == .Ice { add(sys, &r, .Depot, i, 0.15, "Depot"); break }
	}
	// Habitat at the biggest planet's leading Lagrange point: same orbit, +60 degrees.
	big := sys.bodies[biggest]
	o := big.orbit
	o.M0 += math.PI / 3
	append(&sys.stations, Station{name = fmt.aprintf("%s Haven", make_name(&r)), kind = .Habitat, parent = STAR, orbit = o})

	// Colonies need a body big enough to orbit and shuttle to.
	for &b in sys.bodies do if b.colony && (b.kind == .Star || b.radius < core.COLONY_MIN_RADIUS || b.soi < 4.0) do b.colony = false
}

// A low parking orbit about a body: where captures end and shuttles fly from.
low_orbit :: proc(b: Body) -> f64 {
	return clamp(b.soi * 0.15, b.radius * 1.5, b.soi * 0.6)
}

// How far out a shuttle will fly to a ship in orbit.
shuttle_range :: proc(b: Body) -> f64 {
	return min(max(low_orbit(b) * 1.8, b.radius * 2.5), b.soi * 0.85)
}

// Prepare an empty system that owns its allocations, for hand-built systems
// in tests. Call `finish` after appending bodies.
init_empty :: proc(sys: ^System, seed: u64) -> mem.Allocator {
	_ = virtual.arena_init_growing(&sys.arena)
	sys.seed = seed
	return virtual.arena_allocator(&sys.arena)
}

finish :: proc(sys: ^System) {
	context.allocator = virtual.arena_allocator(&sys.arena)
	resize(&sys.pos, len(sys.bodies))
	resize(&sys.vel, len(sys.bodies))
	resize(&sys.station_pos, len(sys.stations))
	resize(&sys.station_vel, len(sys.stations))
	for b, i in sys.bodies do if i > 0 && b.parent == STAR do sys.extent = max(sys.extent, orbit.apoapsis(b.orbit))
	update(sys, 0)
}
