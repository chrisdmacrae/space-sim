package gen

// The galaxy (docs/DESIGN.md §2.1): a sparse graph of star systems. Only
// the cheap summary of each system is generated here; the full system comes
// from `generate(summary.seed)` when needed. Summaries reproduce the same
// star name, class and planet count as the full generator.

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import core "sim:core"

Summary :: struct {
	seed:     u64,
	name:     string,
	star:     Star,
	planets:  int,
	pos:      [2]f64, // light-years, map plane
	has_gas:  bool,
	has_hab:  bool,
	// Nebulae (gen/nebula.odin). `nebula` means the system holds one;
	// `is_site` means the cloud *is* the destination — no planets, no
	// stations, nothing but gas and the core that lights it.
	nebula:   bool,
	is_site:  bool,
	neb_kind: Nebula_Kind,
}

Edge :: struct {
	a, b:     int,
	distance: f64, // light-years
}

Galaxy_Kind :: enum u8 {
	Spiral,
	Elliptical,
	Lenticular,
	Irregular,
}

// The morphology parameters, kept so the map can sample the same shape
// for its backdrop (thousands of faint field stars, haze, dust).
Shape :: struct {
	R:      f64,
	arms:   int,
	twist:  f64,
	ellip:  f64,
	clumps: [][3]f64, // irregular: x, y, sigma (light-years about the origin)
}

Galaxy :: struct {
	seed:    u64,
	kind:    Galaxy_Kind,
	params:  Galaxy_Params,
	span:    f64, // light-years across the map plane
	shape:   Shape,
	systems: [dynamic]Summary,
	edges:   [dynamic]Edge,
	adj:     [dynamic][dynamic]int, // neighbour lists, parallel to systems
	arena:   virtual.Arena,
}

GALAXY_SYSTEMS :: 420
GALAXY_SPAN    :: 60.0 // light-years across a 420-system map; scales with the square root of the count

// What a new game asks for. `kind_set` false means the seed decides.
Galaxy_Params :: struct {
	seed:     u64,
	systems:  int,
	kind:     Galaxy_Kind,
	kind_set: bool,
}

SIZE_SMALL  :: 150
SIZE_NORMAL :: GALAXY_SYSTEMS
SIZE_LARGE  :: 800
EDGE_MIN       :: 1.0
EDGE_MAX       :: 4.0
MIN_SPACING    :: 0.9

galaxy_destroy :: proc(g: ^Galaxy) {
	virtual.arena_destroy(&g.arena)
	g^ = {}
}

system_seed :: proc(galaxy_seed: u64, index: int) -> u64 {
	return core.sub_seed(galaxy_seed, "system", index)
}

// Cheap summary matching what `generate` would produce.
summarize :: proc(seed: u64) -> (s: Summary) {
	s.seed = seed
	rs := core.rng_make(core.sub_seed(seed, "star"))
	s.name = make_name(&rs)
	s.star = roll_star(&rs)
	L := s.star.luminosity
	// The same roll the full generator makes, on its own seed stream.
	if neb := roll_nebula(seed, s.star); neb.present {
		s.nebula = true
		s.is_site = neb.site
		s.neb_kind = neb.kind
	}
	rp := core.rng_make(core.sub_seed(seed, "planets"))
	s.planets = planet_count(&rp, s.star.kind)
	if s.is_site do s.planets = 0
	// Rough tags from the same layout rule as the generator's first pass.
	a := first_orbit(s.star, core.rng_range(&rp, 0.8, 1.3))
	for i in 0 ..< s.planets {
		T := temperature(L, a)
		if T < core.TEMP_FROST do s.has_gas = true
		if T > core.TEMP_FROST && T <= core.TEMP_ROCK do s.has_hab = true
		ratio := core.rng_range(&rp, 1.45, 2.1)
		if core.rng_chance(&rp, 0.25) do ratio *= 1.45
		a *= ratio
	}
	return
}

@(private = "file")
gauss :: proc(r: ^core.Rng) -> f64 {
	// Box-Muller
	u1 := max(core.rng_f64(r), 1e-12)
	u2 := core.rng_f64(r)
	return math.sqrt(-2 * math.ln(u1)) * math.cos(2 * math.PI * u2)
}

// One candidate position (light-years, centred on the origin) for the
// galaxy's morphology.
@(private = "file")
sample_position :: proc(r: ^core.Rng, kind: Galaxy_Kind, R: f64, arms: int, twist: f64, ellip: f64, clumps: [][3]f64) -> [2]f64 {
	switch kind {
	case .Spiral:
		if core.rng_chance(r, 0.22) {
			// Bulge.
			return {gauss(r) * R * 0.12, gauss(r) * R * 0.12}
		}
		arm := core.rng_int(r, 0, arms)
		t := math.sqrt(core.rng_range(r, 0.05, 1.0))
		rad := R * t
		theta := twist * math.ln(max(rad / (R * 0.08), 1.0)) + 2 * math.PI * f64(arm) / f64(arms)
		// Scatter widens with radius: tight arms inside, loose outside.
		theta += gauss(r) * (0.10 + 0.22 * t)
		rad *= 1 + gauss(r) * 0.06
		return {rad * math.cos(theta), rad * math.sin(theta)}
	case .Elliptical:
		x := gauss(r) * R * 0.42
		y := gauss(r) * R * 0.42 * (1 - ellip)
		return orbit_rotate({x, y}, twist)
	case .Lenticular:
		if core.rng_chance(r, 0.35) do return {gauss(r) * R * 0.16, gauss(r) * R * 0.16 * 0.8}
		rad := R * math.sqrt(core.rng_range(r, 0.05, 1.0))
		ang := core.rng_range(r, 0, 2 * math.PI)
		return orbit_rotate({rad * math.cos(ang), rad * math.sin(ang) * (1 - ellip * 0.6)}, twist)
	case .Irregular:
		if core.rng_chance(r, 0.15) do return {core.rng_range(r, -R, R), core.rng_range(r, -R, R)}
		c := clumps[core.rng_int(r, 0, len(clumps))]
		return {c[0] + gauss(r) * c[2], c[1] + gauss(r) * c[2]}
	}
	return {}
}

@(private = "file")
orbit_rotate :: proc(v: [2]f64, ang: f64) -> [2]f64 {
	c := math.cos(ang)
	s := math.sin(ang)
	return {c * v.x - s * v.y, s * v.x + c * v.y}
}

galaxy_generate :: proc(seed: u64) -> Galaxy {
	return galaxy_generate_with(Galaxy_Params{seed = seed, systems = GALAXY_SYSTEMS})
}

galaxy_generate_with :: proc(params: Galaxy_Params) -> (g: Galaxy) {
	_ = virtual.arena_init_growing(&g.arena)
	context.allocator = virtual.arena_allocator(&g.arena)
	seed := params.seed
	g.seed = seed
	g.params = params
	if g.params.systems <= 0 do g.params.systems = GALAXY_SYSTEMS
	count := g.params.systems
	g.span = GALAXY_SPAN * math.sqrt(f64(count) / f64(GALAXY_SYSTEMS))
	r := core.rng_make(core.sub_seed(seed, "galaxy"))
	roll := core.rng_f64(&r)
	switch {
	case roll < 0.5:  g.kind = .Spiral
	case roll < 0.7:  g.kind = .Elliptical
	case roll < 0.85: g.kind = .Lenticular
	case:             g.kind = .Irregular
	}
	if params.kind_set do g.kind = params.kind
	span := g.span
	R := span * 0.46
	arms := core.rng_int(&r, 2, 5)
	twist := core.rng_range(&r, 2.2, 4.0)
	if g.kind != .Spiral do twist = core.rng_range(&r, 0, math.PI)
	ellip := core.rng_range(&r, 0.2, 0.7)
	clumps := make([dynamic][3]f64)
	for _ in 0 ..< core.rng_int(&r, 3, 7) {
		append(&clumps, [3]f64{core.rng_range(&r, -R * 0.7, R * 0.7), core.rng_range(&r, -R * 0.7, R * 0.7), core.rng_range(&r, R * 0.08, R * 0.25)})
	}
	g.shape = Shape{R = R, arms = arms, twist = twist, ellip = ellip, clumps = clumps[:]}
	// Scatter with a minimum spacing; give up on a point after a few tries.
	tries := 0
	for len(g.systems) < count && tries < count * 40 {
		tries += 1
		p := sample_position(&r, g.kind, R, arms, twist, ellip, clumps[:]) + {span * 0.5, span * 0.5}
		if p.x < 0.5 || p.y < 0.5 || p.x > span - 0.5 || p.y > span - 0.5 do continue
		ok := true
		for s in g.systems {
			d := s.pos - p
			if d.x * d.x + d.y * d.y < MIN_SPACING * MIN_SPACING { ok = false; break }
		}
		if !ok do continue
		s := summarize(system_seed(seed, len(g.systems)))
		s.pos = p
		append(&g.systems, s)
	}
	// Edges: each system links to its nearest few within range.
	resize(&g.adj, len(g.systems))
	for i in 0 ..< len(g.systems) {
		for _ in 0 ..< 3 {
			best := -1
			best_d := EDGE_MAX
			for j in 0 ..< len(g.systems) {
				if i == j || linked(&g, i, j) do continue
				d := distance(&g, i, j)
				if d < best_d {
					best_d = d
					best = j
				}
			}
			if best < 0 do break
			append(&g.edges, Edge{a = min(i, best), b = max(i, best), distance = best_d})
			append(&g.adj[i], best)
			append(&g.adj[best], i)
		}
	}
	// Outliers with nothing in range still get one link, however long: every
	// star must be reachable.
	for i in 0 ..< len(g.systems) {
		if len(g.adj[i]) > 0 do continue
		best := -1
		best_d: f64 = 1e300
		for j in 0 ..< len(g.systems) {
			if i == j do continue
			if d := distance(&g, i, j); d < best_d {
				best_d = d
				best = j
			}
		}
		if best < 0 do continue
		append(&g.edges, Edge{a = min(i, best), b = max(i, best), distance = best_d})
		append(&g.adj[i], best)
		append(&g.adj[best], i)
	}
	return
}

// A random point of the galaxy's shape in map coordinates (light-years,
// origin at the corner like Summary.pos). `dtheta` rotates the pattern about
// the centre, which the map uses to lay dust just inside the arms.
galaxy_sample :: proc(g: ^Galaxy, r: ^core.Rng, dtheta: f64 = 0) -> [2]f64 {
	p := sample_position(r, g.kind, g.shape.R, g.shape.arms, g.shape.twist, g.shape.ellip, g.shape.clumps)
	if dtheta != 0 do p = orbit_rotate(p, dtheta)
	return p + {g.span * 0.5, g.span * 0.5}
}

@(private = "file")
linked :: proc(g: ^Galaxy, i, j: int) -> bool {
	for k in g.adj[i] do if k == j do return true
	return false
}

distance :: proc(g: ^Galaxy, i, j: int) -> f64 {
	d := g.systems[i].pos - g.systems[j].pos
	return math.sqrt(d.x * d.x + d.y * d.y)
}

has_edge :: proc(g: ^Galaxy, i, j: int) -> bool {
	return linked(g, i, j)
}

// Neighbours of a system.
neighbours :: proc(g: ^Galaxy, i: int) -> []int {
	return g.adj[i][:]
}

edge_between :: proc(g: ^Galaxy, i, j: int) -> (Edge, bool) {
	if !linked(g, i, j) do return {}, false
	return Edge{a = min(i, j), b = max(i, j), distance = distance(g, i, j)}, true
}

_ :: fmt
