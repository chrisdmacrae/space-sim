package gen

import "core:math"
import "core:testing"

@(test)
galaxy_is_dense_spaced_and_linked :: proc(t: ^testing.T) {
	kinds: [Galaxy_Kind]int
	for seed in 1 ..= 8 {
		g := galaxy_generate(u64(seed))
		defer galaxy_destroy(&g)
		kinds[g.kind] += 1
		testing.expectf(t, len(g.systems) >= GALAXY_SYSTEMS * 8 / 10, "seed %v: %v systems", seed, len(g.systems))
		for a, i in g.systems {
			for b, j in g.systems {
				if j <= i do continue
				d := a.pos - b.pos
				testing.expectf(t, math.sqrt(d.x * d.x + d.y * d.y) >= MIN_SPACING - 1e-9, "seed %v: %s and %s too close", seed, a.name, b.name)
			}
			testing.expectf(t, len(neighbours(&g, i)) >= 1, "seed %v: %s has no link", seed, a.name)
		}
		long := 0
		for e in g.edges do if e.distance > EDGE_MAX + 1e-9 do long += 1
		testing.expectf(t, long <= len(g.systems) / 20, "seed %v: %v over-long rescue links", seed, long)
		// The summary agrees with the full generator.
		full := generate(g.systems[3].seed)
		defer destroy(&full)
		testing.expect(t, full.name == g.systems[3].name, "summary name matches")
	}
	seen := 0
	for k in kinds do if k > 0 do seen += 1
	testing.expectf(t, seen >= 2, "morphologies vary across seeds (%v kinds)", seen)
}

@(test)
galaxy_is_deterministic :: proc(t: ^testing.T) {
	a := galaxy_generate(11)
	defer galaxy_destroy(&a)
	b := galaxy_generate(11)
	defer galaxy_destroy(&b)
	testing.expect(t, len(a.systems) == len(b.systems) && a.kind == b.kind, "same shape")
	for i in 0 ..< len(a.systems) do testing.expect(t, a.systems[i].pos == b.systems[i].pos, "same positions")
}

@(test)
galaxy_params_set_size_and_kind :: proc(t: ^testing.T) {
	small := galaxy_generate_with(Galaxy_Params{seed = 3, systems = SIZE_SMALL, kind = .Elliptical, kind_set = true})
	defer galaxy_destroy(&small)
	large := galaxy_generate_with(Galaxy_Params{seed = 3, systems = SIZE_LARGE, kind = .Irregular, kind_set = true})
	defer galaxy_destroy(&large)
	testing.expectf(t, len(small.systems) >= SIZE_SMALL * 8 / 10 && len(small.systems) <= SIZE_SMALL, "small has ~%d systems (%d)", SIZE_SMALL, len(small.systems))
	testing.expectf(t, len(large.systems) >= SIZE_LARGE * 8 / 10 && len(large.systems) <= SIZE_LARGE, "large has ~%d systems (%d)", SIZE_LARGE, len(large.systems))
	testing.expect(t, small.kind == .Elliptical && large.kind == .Irregular, "forced kinds")
	testing.expect(t, large.span > small.span, "a bigger galaxy spans more light-years")
	for s in large.systems do testing.expect(t, s.pos.x >= 0 && s.pos.x <= large.span && s.pos.y >= 0 && s.pos.y <= large.span, "systems inside the span")
	for i in 0 ..< len(large.systems) do testing.expect(t, len(neighbours(&large, i)) > 0, "every system is linked")
	plain := galaxy_generate(3)
	defer galaxy_destroy(&plain)
	testing.expect(t, plain.params.systems == GALAXY_SYSTEMS && plain.span == GALAXY_SPAN, "the plain generator is the normal size")
}
