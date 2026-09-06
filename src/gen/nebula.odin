package gen

// Nebulae (docs/DESIGN.md §2.6). A nebula is a cloud of gas and dust with no
// mass worth integrating: it does not orbit and nothing orbits it. It is a
// *region* — a centre, an extent and a density you can evaluate anywhere —
// which is what lets a ship sit inside one and skim it.
//
// Which kind a system can host is decided by its star, not by a free roll,
// because in the sky the two are the same fact seen twice:
//
//   neutron star, pulsar  the shell of the supernova that made it
//   white dwarf           the envelope it shed on the way down
//   hot O/B star          gas it has ionised into an emission nebula
//   A/F star              dust reflecting its light, blue, making none of its own
//   cool dwarf            the molecular cloud it is still condensing out of
//
// A roll on top of that decides whether the nebula is there at all, and
// whether it is big enough to be a destination of its own on the galaxy map
// (a "site": no planets, no stations, nothing but the cloud and its core).

import "core:fmt"
import "core:math"
import core "sim:core"

Nebula_Kind :: enum u8 {
	Nursery,   // cold molecular cloud still collapsing into stars
	Emission,  // gas ionised by the hot stars inside it; makes its own light
	Reflection, // dust scattering a neighbour's light; blue, dark of itself
	Supernova, // the blast shell of a star that died loudly
	Planetary, // the envelope a dying low-mass star let go of
}

NEBULA_LOBES :: 7

Nebula :: struct {
	name:    string,
	kind:    Nebula_Kind,
	center:  [2]f64, // relative to the star, which never moves
	label:   [2]f64, // where the name hangs, relative to the star (see below)
	radius:  f64,    // outer edge, world units
	hollow:  f64,    // inner edge of a shell; 0 for a cloud
	density: f64,    // peak, 0..1
	colors:  [3][4]u8, // core, body, rim
	lobes:   [NEBULA_LOBES][4]f64, // x, y as fractions of radius, weight, and width squared
	stars:   int,    // young stars caught inside, drawn but not simulated
	seed:    u64,
}

// What a system's star implies. `ok` is false for stars that light nothing.
nebula_kind_for :: proc(s: Star) -> (kind: Nebula_Kind, ok: bool) {
	switch s.kind {
	case .Neutron, .Pulsar:
		return .Supernova, true
	case .White_Dwarf:
		return .Planetary, true
	case .Main_Sequence:
		switch s.class {
		case "O", "B": return .Emission, true
		case "A", "F": return .Reflection, true
		case "G", "K": return .Reflection, true
		case:          return .Nursery, true // M dwarfs: young and still swaddled
		}
	case .Giant, .Supergiant:
		return s.class == "B" ? .Emission : .Reflection, true
	case .Brown_Dwarf:
		return .Nursery, true
	}
	return .Nursery, false
}

// How often each kind actually turns up around a star that could host it,
// and how often such a nebula is large enough to be its own map destination.
@(private = "file")
NEBULA_CHANCE := [Nebula_Kind]f64 {
	.Nursery    = 0.14,
	.Emission   = 0.45,
	.Reflection = 0.05,
	.Supernova  = 0.62,
	.Planetary  = 0.45,
}

@(private = "file")
SITE_CHANCE := [Nebula_Kind]f64 {
	.Nursery    = 0.72, // a cloud this big has no room for a settled system
	.Emission   = 0.30,
	.Reflection = 0.12,
	.Supernova  = 0.22,
	.Planetary  = 0.14,
}

// The roll, drawn on its own seed stream so adding nebulae left every star,
// planet and station of every existing seed exactly where it was. Geometry
// comes back as fractions: the system's own scale is not known yet, and a
// site has no planets to be scaled against.
Nebula_Roll :: struct {
	present:  bool,
	site:     bool,        // the cloud *is* the destination: no planets, no stations
	kind:     Nebula_Kind,
	density:  f64,
	radius_k: f64,         // of the system extent (cloud) or of first_orbit (site)
	hollow_k: f64,         // of the outer radius; 0 for a cloud
	offset:   [2]f64,      // centre away from the star, in system extents
	stars:    int,
	seed:     u64,
}

roll_nebula :: proc(system_seed: u64, star: Star) -> (n: Nebula_Roll) {
	kind, ok := nebula_kind_for(star)
	if !ok do return
	n.seed = core.sub_seed(system_seed, "nebula")
	r := core.rng_make(n.seed)
	if !core.rng_chance(&r, NEBULA_CHANCE[kind]) do return
	n.present = true
	n.kind = kind
	n.site = core.rng_chance(&r, SITE_CHANCE[kind])
	switch kind {
	case .Supernova:
		// A shell that has already swept past the planets: you fly out to it.
		n.density = core.rng_range(&r, 0.45, 0.85)
		n.radius_k = core.rng_range(&r, 1.9, 3.4)
		n.hollow_k = core.rng_range(&r, 0.42, 0.66)
		n.stars = 0
	case .Planetary:
		n.density = core.rng_range(&r, 0.35, 0.7)
		n.radius_k = core.rng_range(&r, 1.4, 2.4)
		n.hollow_k = core.rng_range(&r, 0.35, 0.60)
		n.stars = 0
	case .Emission:
		n.density = core.rng_range(&r, 0.5, 0.95)
		n.radius_k = core.rng_range(&r, 0.45, 0.9)
		n.stars = core.rng_int(&r, 4, 10)
	case .Nursery:
		n.density = core.rng_range(&r, 0.6, 1.0)
		n.radius_k = core.rng_range(&r, 0.5, 1.0)
		n.stars = core.rng_int(&r, 2, 7)
	case .Reflection:
		n.density = core.rng_range(&r, 0.25, 0.55)
		n.radius_k = core.rng_range(&r, 0.3, 0.65)
		n.stars = core.rng_int(&r, 0, 3)
	}
	if n.site {
		// Nothing to sit beside: the cloud takes the middle and grows.
		n.density = min(n.density * 1.25, 1)
		n.radius_k *= core.rng_range(&r, 1.5, 2.6)
		n.stars = int(f64(n.stars) * 1.8) + (n.kind == .Nursery ? 4 : 0)
	} else if n.hollow_k == 0 {
		// A cloud in a working system sits off to one side of it.
		ang := core.rng_range(&r, 0, 2 * math.PI)
		d := core.rng_range(&r, 0.55, 1.35)
		n.offset = {math.cos(ang) * d, math.sin(ang) * d}
	}
	return
}

// A cloud is measured against the system it sits in, but star systems here
// span four orders of magnitude and a nebula does not: real ones are much
// the same size whatever is inside them. So the scale a cloud is built
// against is bounded at both ends — a site gets a fixed one, since it has no
// planets to be measured against at all.
NEBULA_SITE_SCALE :: 6000.0   // world units: a site's cloud is built off this
NEBULA_SCALE_CAP  :: 200000.0 // no cloud is laid out against more than this
NEBULA_MIN_RADIUS :: 400.0

// Build the nebula itself once the system's scale is known.
make_nebula :: proc(roll: Nebula_Roll, scale_in: f64, star: Star) -> (n: Nebula) {
	scale := min(scale_in, NEBULA_SCALE_CAP)
	r := core.rng_make(core.sub_seed(roll.seed, "shape"))
	n.name = nebula_name(&r, roll.kind)
	n.kind = roll.kind
	n.density = roll.density
	n.seed = roll.seed
	n.stars = roll.stars
	n.radius = max(scale * roll.radius_k, star.heat_radius * 2.5, NEBULA_MIN_RADIUS)
	if roll.hollow_k > 0 {
		n.hollow = n.radius * roll.hollow_k
		// A shell must clear the heat line and any wind, or it would be a
		// hazard laid over a hazard with no room to sit between them.
		floor := max(star.heat_radius, star.wind_radius) * 1.6
		if n.hollow < floor {
			n.hollow = floor
			n.radius = max(n.radius, n.hollow / max(roll.hollow_k, 0.3))
		}
	}
	n.center = roll.offset * scale
	n.colors = nebula_colors(&r, roll.kind)
	// Lobes: the gas gathers around a few centres rather than filling a disc,
	// which is what stops it reading as a smudge and gives skimming somewhere
	// richer to sit.
	for &l in n.lobes {
		u := core.rng_range(&r, 0, 2 * math.PI)
		w := core.rng_range(&r, 0.35, 1)
		if roll.hollow_k > 0 {
			// Shell lobes ride the band, not the middle: a shell is bright in
			// knots around its rim and empty through the centre.
			mid := (roll.hollow_k + 1) * 0.5
			sig := (1 - roll.hollow_k) * core.rng_range(&r, 0.16, 0.34)
			l = {math.cos(u) * mid, math.sin(u) * mid, w, sig * sig}
			continue
		}
		d := core.rng_range(&r, 0, 0.72)
		sig := core.rng_range(&r, 0.13, 0.30)
		l = {math.cos(u) * d, math.sin(u) * d, w, sig * sig}
	}
	// The name hangs where the cloud actually is. A shell is empty in the
	// middle — that is where its own star sits — so its label rides the band;
	// a cloud centred on its star would put the name on top of the star, so
	// it takes the thickest point instead.
	if n.hollow > 0 {
		mid := (n.hollow + n.radius) * 0.5
		a := f64(core.mix64(n.seed) >> 11) * (1.0 / 9007199254740992.0) * 2 * math.PI
		n.label = n.center + {math.cos(a) * mid, math.sin(a) * mid}
	} else {
		n.label = nebula_thickest(n)
	}
	return
}

// Density at a point given relative to the star, 0 outside the cloud. Cheap
// and closed-form: hazards, skimming and the NPC survey all call it per frame.
nebula_density_at :: proc(n: Nebula, rel: [2]f64) -> f64 {
	d := rel - n.center
	rr := math.sqrt(d.x * d.x + d.y * d.y)
	if rr >= n.radius do return 0
	u := rr / n.radius
	shape: f64
	if n.hollow > 0 {
		// A shell: a band peaking between the inner and outer edges.
		h := n.hollow / n.radius
		if u <= h do return 0
		mid := (h + 1) * 0.5
		w := max((1 - h) * 0.32, 1e-4)
		x := (u - mid) / w
		shape = math.exp(-x * x)
	} else {
		s := 1 - u * u
		shape = s * s
	}
	if shape <= 0 do return 0
	// Lobes, in units of the radius. They carry most of the weight: a cloud
	// with an even falloff reads as a smudge, and gives the scoop nowhere
	// better to sit than anywhere else.
	lob := 0.0
	for l in n.lobes {
		dx := d.x / n.radius - l.x
		dy := d.y / n.radius - l.y
		q := (dx * dx + dy * dy) / max(l.w, 1e-6)
		if q < 12 do lob += l.z * math.exp(-q)
	}
	lob = min(lob, 1)
	return n.density * shape * (0.22 + 0.78 * lob)
}

// Inside the cloud at all? Used for "can I skim here" and for picking.
NEBULA_EDGE :: 0.04 // density below this is thin enough to ignore

in_nebula :: proc(n: Nebula, rel: [2]f64) -> bool {
	return nebula_density_at(n, rel) > NEBULA_EDGE
}

// The densest nebula of the system at a world point, and how thick it is there.
nebula_at :: proc(sys: ^System, world: [2]f64) -> (index: int, density: f64) {
	index = -1
	rel := world - sys.pos[0]
	for &n, i in sys.nebulae {
		if d := nebula_density_at(n, rel); d > density {
			density = d
			index = i
		}
	}
	if density <= NEBULA_EDGE do return -1, 0
	return
}

// The thickest place in the cloud. Deterministic: it is where "go to the
// nebula" takes you, where the scoop fills fastest, and it must not wander
// between frames. Sampled on a golden-angle spiral, which covers a disc
// evenly without a generator.
nebula_thickest :: proc(n: Nebula) -> [2]f64 {
	best := n.center
	best_d := -1.0
	SAMPLES :: 360
	for i in 0 ..< SAMPLES {
		a := 2 * math.PI * f64(i) * 0.6180339887
		u := math.sqrt((f64(i) + 0.5) / SAMPLES)
		if n.hollow > 0 do u = n.hollow / n.radius + (1 - n.hollow / n.radius) * u
		p := n.center + {math.cos(a) * n.radius * u, math.sin(a) * n.radius * u}
		if d := nebula_density_at(n, p); d > best_d {
			best_d = d
			best = p
		}
	}
	return best
}

// Where the cloud's name hangs, relative to the star. Settled once, at
// generation, by make_nebula.
nebula_label_point :: proc(n: Nebula) -> [2]f64 {
	return n.label
}

@(private = "file")
NEBULA_SUFFIX := [Nebula_Kind][3]string {
	.Nursery    = {"Nursery", "Cradle", "Nebula"},
	.Emission   = {"Nebula", "Glow", "Lantern"},
	.Reflection = {"Veil", "Mirror", "Shroud"},
	.Supernova  = {"Remnant", "Wreath", "Scar"},
	.Planetary  = {"Ring", "Shell", "Halo"},
}

nebula_name :: proc(r: ^core.Rng, kind: Nebula_Kind) -> string {
	sfx := NEBULA_SUFFIX
	return fmt.aprintf("%s %s", make_name(r), core.rng_pick(r, sfx[kind][:]))
}

nebula_describe :: proc(k: Nebula_Kind) -> string {
	switch k {
	case .Nursery:    return "star nursery"
	case .Emission:   return "emission nebula"
	case .Reflection: return "reflection nebula"
	case .Supernova:  return "supernova remnant"
	case .Planetary:  return "planetary nebula"
	}
	return "nebula"
}

// One line on what the cloud is, for the map and the popover.
nebula_note :: proc(k: Nebula_Kind) -> string {
	switch k {
	case .Nursery:    return "cold hydrogen, collapsing into stars"
	case .Emission:   return "hydrogen lit by the hot stars in it"
	case .Reflection: return "dust, blue with borrowed starlight"
	case .Supernova:  return "a dead star's shell, rich in metals"
	case .Planetary:  return "an envelope a dying star let go of"
	}
	return ""
}

// The canonical colour of a kind, with no roll behind it: for the galaxy
// map and anywhere else that has a Summary but no generated cloud.
nebula_kind_color :: proc(k: Nebula_Kind) -> [4]u8 {
	switch k {
	case .Nursery:    return {186, 122, 92, 255}
	case .Emission:   return {255, 118, 138, 255}
	case .Reflection: return {132, 178, 255, 255}
	case .Supernova:  return {120, 226, 214, 255}
	case .Planetary:  return {118, 214, 208, 255}
	}
	return {170, 170, 200, 255}
}

@(private = "file")
jitter_col :: proc(r: ^core.Rng, c: [4]u8, amount: f64) -> [4]u8 {
	out := c
	for i in 0 ..< 3 {
		v := f64(c[i]) + core.rng_range(r, -amount, amount)
		out[i] = u8(clamp(v, 0, 255))
	}
	return out
}

// Core, body and rim. The palettes are the real ones: H-alpha red for
// emission, scattered blue for reflection, dusty browns for a nursery,
// shocked teal and gold for a remnant, teal-and-rose for a planetary shell.
nebula_colors :: proc(r: ^core.Rng, k: Nebula_Kind) -> [3][4]u8 {
	switch k {
	case .Nursery:
		return {jitter_col(r, {150, 96, 74, 255}, 18), jitter_col(r, {96, 64, 62, 255}, 16), jitter_col(r, {58, 46, 62, 255}, 14)}
	case .Emission:
		return {jitter_col(r, {255, 120, 132, 255}, 20), jitter_col(r, {196, 62, 92, 255}, 22), jitter_col(r, {96, 40, 92, 255}, 18)}
	case .Reflection:
		return {jitter_col(r, {150, 190, 255, 255}, 18), jitter_col(r, {92, 130, 214, 255}, 20), jitter_col(r, {48, 66, 132, 255}, 16)}
	case .Supernova:
		return {jitter_col(r, {120, 226, 214, 255}, 22), jitter_col(r, {214, 150, 92, 255}, 24), jitter_col(r, {96, 70, 130, 255}, 18)}
	case .Planetary:
		return {jitter_col(r, {110, 224, 200, 255}, 20), jitter_col(r, {96, 150, 230, 255}, 20), jitter_col(r, {210, 110, 150, 255}, 22)}
	}
	return {{160, 160, 190, 255}, {110, 110, 150, 255}, {60, 60, 90, 255}}
}
