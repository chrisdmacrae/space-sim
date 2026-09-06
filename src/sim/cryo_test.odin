package sim

import "core:testing"
import gen "sim:gen"
import orbit "sim:orbit"

@(test)
arrival_is_a_safe_parking_orbit :: proc(t: ^testing.T) {
	for seed in ([?]u64{1, 4, 7}) {
		sys := gen.generate(seed)
		defer gen.destroy(&sys)
		s := spawn_in_orbit(&sys, gen.STAR, 0.3, 0)
		defer destroy(&s)
		arrive(&sys, &s, 12345678)
		testing.expect(t, s.primary == gen.STAR && s.mode == .On_Rails, "on rails about the star")
		testing.expectf(t, s.orbit.e < 0.01, "circular (e=%v)", s.orbit.e)
		r := orbit.length(s.pos)
		testing.expectf(t, r > sys.extent && r < system_boundary(&sys), "parked outside the planets (r %v, extent %v, boundary %v)", r, sys.extent, system_boundary(&sys))
		for b, i in sys.bodies do if i > 0 && b.parent == gen.STAR {
			testing.expectf(t, r > orbit.apoapsis(b.orbit) + b.soi, "clear of %s's sphere", b.name)
		}
		for seg in s.segments do testing.expectf(t, seg.end != .Collide, "no predicted impact")
		ok, _ := can_jump(&sys, &s)
		testing.expect(t, !ok, "a parked ship must fly out again before it can jump")
	}
}
