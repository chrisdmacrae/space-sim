package gen

import "core:testing"
import orbit "sim:orbit"

@(test)
every_star_kind_appears_and_summaries_agree :: proc(t: ^testing.T) {
	seen: [Star_Kind]int
	for seed in 1 ..= 300 {
		sys := generate(u64(seed))
		defer destroy(&sys)
		sum := summarize(u64(seed))
		seen[sys.star.kind] += 1
		testing.expectf(t, sum.star == sys.star, "seed %d: summary star matches", seed)
		testing.expectf(t, sum.planets == len(sys.bodies) - 1 - moon_count(&sys), "seed %d: summary planet count %d vs %d", seed, sum.planets, len(sys.bodies) - 1 - moon_count(&sys))
		testing.expect(t, sys.bodies[0].radius == sys.star.radius, "star body radius follows the star")
		testing.expect(t, sys.star.heat_radius >= sys.star.radius, "heat line outside the surface")
		for b, i in sys.bodies do if i > 0 && b.parent == STAR {
			peri := orbit.periapsis(b.orbit)
			testing.expectf(t, peri > sys.star.heat_radius, "seed %d: %s (peri %.0f) outside the heat line %.0f", seed, b.name, peri, sys.star.heat_radius)
			testing.expectf(t, peri > sys.star.wind_radius, "seed %d: %s (peri %.0f) outside the pulsar wind %.0f", seed, b.name, peri, sys.star.wind_radius)
		}
		if sys.star.kind == .Pulsar do testing.expect(t, sys.star.wind_radius > 0 && sys.star.spin > 0, "pulsars have a wind and spin")
		else do testing.expect(t, sys.star.wind_radius == 0, "only pulsars have a wind")
	}
	for k in Star_Kind do testing.expectf(t, seen[k] > 0, "kind %v appears in 300 seeds", k)
	testing.expectf(t, seen[.Main_Sequence] > 150, "main sequence dominates (%d)", seen[.Main_Sequence])
}

@(private = "file")
moon_count :: proc(sys: ^System) -> (n: int) {
	for b in sys.bodies do if b.is_moon do n += 1
	return
}
