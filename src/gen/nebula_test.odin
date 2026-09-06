package gen

import "core:math"
import "core:testing"
import core "sim:core"

// The roll must be a pure function of (system seed, star): the galaxy map's
// summary and the full generator both call it and have to agree.
@(test)
nebula_roll_is_deterministic :: proc(t: ^testing.T) {
	for i in 0 ..< 200 {
		seed := system_seed(99, i)
		rs := core.rng_make(core.sub_seed(seed, "star"))
		_ = make_name(&rs)
		star := roll_star(&rs)
		a := roll_nebula(seed, star)
		b := roll_nebula(seed, star)
		testing.expect(t, a == b, "roll_nebula must be pure")
	}
}

// summarize and generate must report the same nebula for the same seed.
@(test)
summary_matches_generated_system :: proc(t: ^testing.T) {
	for i in 0 ..< 120 {
		seed := system_seed(7, i)
		s := summarize(seed)
		sys := generate(seed)
		defer destroy(&sys)
		testing.expectf(t, s.nebula == (len(sys.nebulae) > 0), "system %d: summary nebula %v, generated %d", i, s.nebula, len(sys.nebulae))
		testing.expectf(t, s.is_site == sys.is_site, "system %d: site flag disagrees", i)
		if s.nebula do testing.expectf(t, s.neb_kind == sys.nebulae[0].kind, "system %d: kind disagrees", i)
		if s.is_site {
			testing.expectf(t, len(sys.stations) == 0, "system %d: a site must have no stations", i)
			testing.expectf(t, len(sys.bodies) == 1, "system %d: a site must have no planets", i)
		}
	}
}

// The kind has to follow from the star, or the sky contradicts itself.
@(test)
nebula_kind_follows_the_star :: proc(t: ^testing.T) {
	for i in 0 ..< 400 {
		seed := system_seed(3, i)
		rs := core.rng_make(core.sub_seed(seed, "star"))
		_ = make_name(&rs)
		star := roll_star(&rs)
		n := roll_nebula(seed, star)
		if !n.present do continue
		#partial switch star.kind {
		case .Neutron, .Pulsar:  testing.expect(t, n.kind == .Supernova, "a neutron star leaves a supernova remnant")
		case .White_Dwarf:       testing.expect(t, n.kind == .Planetary, "a white dwarf leaves a planetary nebula")
		}
	}
}

// Geometry: density is zero outside, positive somewhere inside, and a shell
// is hollow at its own centre.
@(test)
nebula_density_shape :: proc(t: ^testing.T) {
	star := Star{radius = 120, heat_radius = 300}
	cloud := make_nebula(Nebula_Roll{present = true, kind = .Emission, density = 0.8, radius_k = 1, seed = 11}, 4000, star)
	testing.expect(t, nebula_density_at(cloud, {cloud.radius * 2, 0}) == 0, "nothing outside the edge")
	peak := 0.0
	for i in 0 ..< 64 {
		a := 2 * math.PI * f64(i) / 64
		for u in ([]f64{0.05, 0.2, 0.4, 0.6, 0.8}) {
			p := cloud.center + {math.cos(a) * cloud.radius * u, math.sin(a) * cloud.radius * u}
			peak = max(peak, nebula_density_at(cloud, p))
		}
	}
	testing.expectf(t, peak > 0.1, "a cloud must be thick somewhere, got %.3f", peak)
	testing.expect(t, peak <= cloud.density + 1e-9, "density never exceeds its peak")

	shell := make_nebula(Nebula_Roll{present = true, kind = .Supernova, density = 0.7, radius_k = 1, hollow_k = 0.5, seed = 12}, 4000, star)
	testing.expect(t, shell.hollow > 0, "a remnant is a shell")
	testing.expect(t, nebula_density_at(shell, shell.center) == 0, "a shell is empty at its middle")
	band := 0.0
	mid := (shell.hollow + shell.radius) * 0.5
	for i in 0 ..< 64 {
		a := 2 * math.PI * f64(i) / 64
		band = max(band, nebula_density_at(shell, shell.center + {math.cos(a) * mid, math.sin(a) * mid}))
	}
	testing.expectf(t, band > 0.1, "the shell band must be thick, got %.3f", band)
}

// A shell must sit clear of the star's own hazards, or there is nowhere safe
// to sit and skim.
@(test)
shell_clears_the_star_hazards :: proc(t: ^testing.T) {
	for i in 0 ..< 300 {
		seed := system_seed(21, i)
		sys := generate(seed)
		defer destroy(&sys)
		for n in sys.nebulae {
			if n.hollow <= 0 do continue
			floor := max(sys.star.heat_radius, sys.star.wind_radius)
			testing.expectf(t, n.hollow > floor, "%s: shell inner edge %.0f inside the hazard at %.0f", n.name, n.hollow, floor)
		}
	}
}
