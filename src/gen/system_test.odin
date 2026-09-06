package gen

import "core:testing"
import orbit "sim:orbit"

@(test)
generation_is_deterministic :: proc(t: ^testing.T) {
	a := generate(42)
	defer destroy(&a)
	b := generate(42)
	defer destroy(&b)
	testing.expect(t, len(a.bodies) == len(b.bodies), "same body count")
	testing.expect(t, a.name == b.name, "same star name")
	for i in 0 ..< len(a.bodies) {
		testing.expect(t, a.bodies[i].orbit == b.bodies[i].orbit, "same orbits")
		testing.expect(t, a.bodies[i].kind == b.bodies[i].kind, "same kinds")
	}
	c := generate(43)
	defer destroy(&c)
	testing.expect(t, c.name != a.name || len(c.bodies) != len(a.bodies), "different seed differs")
}

@(test)
parents_precede_children_and_orbits_do_not_cross :: proc(t: ^testing.T) {
	for seed in 1 ..= 40 {
		sys := generate(u64(seed))
		defer destroy(&sys)
		testing.expect(t, sys.bodies[0].kind == .Star, "body 0 is the star")
		prev_apo := 0.0
		for b, i in sys.bodies {
			if i == 0 do continue
			testing.expectf(t, int(b.parent) < i, "seed %v body %v: parent %v precedes", seed, i, b.parent)
			testing.expect(t, b.orbit.e >= 0 && b.orbit.e < 1, "bound orbit")
			if b.parent == STAR {
				peri := orbit.periapsis(b.orbit)
				testing.expectf(t, peri > prev_apo, "seed %v %s: periapsis %v inside previous apoapsis %v", seed, b.name, peri, prev_apo)
				prev_apo = orbit.apoapsis(b.orbit)
			} else {
				p := sys.bodies[b.parent]
				testing.expectf(t, orbit.apoapsis(b.orbit) < p.soi * 0.5, "seed %v %s: moon outside half the parent SOI", seed, b.name)
				testing.expectf(t, orbit.periapsis(b.orbit) > p.radius * 2, "seed %v %s: moon inside parent", seed, b.name)
			}
		}
	}
}

@(test)
kinds_follow_temperature :: proc(t: ^testing.T) {
	for seed in 1 ..= 40 {
		sys := generate(u64(seed))
		defer destroy(&sys)
		for b in sys.bodies {
			if b.is_moon || b.kind == .Star do continue
			#partial switch b.kind {
			case .Gas, .Ice:
				testing.expectf(t, b.temp < 210, "seed %v %s: %v at %v K", seed, b.name, b.kind, b.temp)
			case .Molten:
				testing.expectf(t, b.temp > 450, "seed %v %s: molten at %v K", seed, b.name, b.temp)
			case .Atmospheric:
				testing.expectf(t, b.temp > 210 && b.temp <= 320, "seed %v %s: atmospheric at %v K", seed, b.name, b.temp)
			}
		}
	}
}

@(test)
stations_sit_inside_their_host :: proc(t: ^testing.T) {
	for seed in 1 ..= 40 {
		sys := generate(u64(seed))
		defer destroy(&sys)
		// A nebula site is gas and a core star: nothing to berth at.
		if sys.is_site {
			testing.expect(t, len(sys.stations) == 0, "a nebula site has no stations")
			continue
		}
		testing.expect(t, len(sys.stations) >= 3, "at least hub, yards, habitat")
		for s in sys.stations {
			host := sys.bodies[s.parent]
			if s.parent == STAR do continue
			testing.expectf(t, s.orbit.a >= host.radius * 1.5 && s.orbit.a <= host.soi * 0.5, "seed %v %s: bad altitude %v (r %v soi %v)", seed, s.name, s.orbit.a, host.radius, host.soi)
		}
	}
}

@(test)
update_places_moons_near_parents :: proc(t: ^testing.T) {
	sys := generate(7)
	defer destroy(&sys)
	update(&sys, 123456)
	for b, i in sys.bodies {
		if !b.is_moon do continue
		d := orbit.length(sys.pos[i] - sys.pos[b.parent])
		testing.expectf(t, d < sys.bodies[b.parent].soi, "%s is %v from parent", b.name, d)
	}
}
