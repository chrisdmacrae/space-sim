package sim

import "core:testing"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"

// A one-body system with a cloud centred on the star, for the scoop tests.
@(private = "file")
cloud_system :: proc(kind: gen.Nebula_Kind = .Nursery, density: f64 = 1.0) -> gen.System {
	sys: gen.System
	alloc := gen.init_empty(&sys, 4242)
	context.allocator = alloc
	sys.name = "Test"
	sys.star = gen.Star{kind = .Main_Sequence, class = "G", mass = 1, luminosity = 1, radius = core.STAR_RADIUS, heat_radius = 200}
	append(&sys.bodies, gen.Body{name = "Test", parent = gen.NONE, kind = .Star, mu = core.MU_SOLAR, mass = 1, radius = core.STAR_RADIUS, soi = 1e30})
	n := gen.make_nebula(gen.Nebula_Roll{present = true, kind = kind, density = density, radius_k = 1, seed = 77}, 4000, sys.star)
	append(&sys.nebulae, n)
	gen.finish(&sys)
	return sys
}

// Put a ship on a circular orbit through the thickest gas.
@(private = "file")
ship_in_cloud :: proc(sys: ^gen.System) -> Ship {
	world := sys.pos[0] + gen.nebula_thickest(sys.nebulae[0])
	return spawn_at_point(sys, world, 0)
}

@(test)
skim_needs_gas :: proc(t: ^testing.T) {
	sys := cloud_system()
	defer gen.destroy(&sys)
	s := ship_in_cloud(&sys)
	defer destroy(&s)
	sk: Skim
	skim_stop(&sk)
	ok, _ := skim_start(&sys, &s, &sk, 0)
	testing.expect(t, ok, "the scoop goes out in thick gas")

	// Well outside the cloud there is nothing to scoop.
	out := Ship{}
	out.stats = COURIER
	out.mode = .On_Rails
	out.primary = gen.STAR
	out.hull = 1
	out.pos = {sys.nebulae[0].radius * 3, 0}
	sk2: Skim
	skim_stop(&sk2)
	ok2, why := skim_start(&sys, &out, &sk2, 0)
	testing.expect(t, !ok2, "no gas, no scoop")
	testing.expect(t, why != "", "and a reason why")
}

// A pass delivers the kind's mix and tops the tank.
@(test)
skim_cycle_fills_hold_and_tank :: proc(t: ^testing.T) {
	sys := cloud_system(.Supernova)
	defer gen.destroy(&sys)
	s := ship_in_cloud(&sys)
	defer destroy(&s)
	s.propellant = s.stats.propellant_cap * 0.5
	sk: Skim
	skim_stop(&sk)
	ok, why := skim_start(&sys, &s, &sk, 0)
	testing.expectf(t, ok, "start: %s", why)

	// Just short of a cycle: nothing yet. The wait is the point.
	skim_step(&sys, &s, &sk, skim_cycle() * 0.9)
	testing.expect(t, cargo_used(&s) == 0, "a part-finished pass yields nothing")
	testing.expect(t, sk.cycles == 0, "and does not count")

	before_fuel := s.propellant
	skim_step(&sys, &s, &sk, skim_cycle() * 0.2)
	testing.expect(t, sk.cycles == 1, "the pass completes")
	testing.expect(t, cargo_used(&s) > 0, "and lands cargo")
	testing.expect(t, s.propellant > before_fuel, "and fuel")
	// A supernova remnant is the one place heavy metals come from.
	testing.expect(t, s.cargo[int(econ.Commodity.Rare_Metals)] > 0, "a remnant yields rare metals")
	testing.expect(t, s.cargo[int(econ.Commodity.Biomass)] == 0, "and no biomass")
}

// Thicker gas is worth more per pass than thin gas.
@(test)
skim_yield_follows_density :: proc(t: ^testing.T) {
	haul :: proc(density: f64) -> f64 {
		sys := cloud_system(.Emission, density)
		defer gen.destroy(&sys)
		s := ship_in_cloud(&sys)
		defer destroy(&s)
		sk: Skim
		skim_stop(&sk)
		if ok, _ := skim_start(&sys, &s, &sk, 0); !ok do return 0
		skim_step(&sys, &s, &sk, skim_cycle() * 1.01)
		return cargo_used(&s)
	}
	thick := haul(1.0)
	thin := haul(0.3)
	testing.expectf(t, thick > thin, "thick gas (%.2f) must beat thin (%.2f)", thick, thin)
	testing.expect(t, thin > 0, "thin gas still yields something")
}

// Leaving the cloud stops the timer where it stands, and coming back resumes.
@(test)
skim_pauses_outside_the_cloud :: proc(t: ^testing.T) {
	sys := cloud_system()
	defer gen.destroy(&sys)
	s := ship_in_cloud(&sys)
	defer destroy(&s)
	sk: Skim
	skim_stop(&sk)
	ok, _ := skim_start(&sys, &s, &sk, 0)
	testing.expect(t, ok, "started")
	skim_step(&sys, &s, &sk, skim_cycle() * 0.4)
	held := sk.elapsed
	testing.expect(t, held > 0, "the timer runs in the gas")

	// Out into the clear: the timer holds and says why.
	s.mode = .On_Rails
	s.pos = {sys.nebulae[0].radius * 4, 0}
	skim_step(&sys, &s, &sk, skim_cycle() * 2)
	testing.expectf(t, sk.elapsed == held, "the timer must hold outside: %.0f vs %.0f", sk.elapsed, held)
	testing.expect(t, sk.stalled != "", "and say so")
	testing.expect(t, cargo_used(&s) == 0, "and land nothing")

	// Back in: it picks up where it left off.
	s2 := ship_in_cloud(&sys)
	defer destroy(&s2)
	s.pos, s.vel, s.orbit, s.primary = s2.pos, s2.vel, s2.orbit, s2.primary
	skim_step(&sys, &s, &sk, skim_cycle() * 0.7)
	testing.expect(t, sk.cycles == 1, "the pass finishes after the interruption")
}

// A full hold and a full tank stop the scoop rather than throwing gas away.
@(test)
skim_stops_when_full :: proc(t: ^testing.T) {
	sys := cloud_system()
	defer gen.destroy(&sys)
	s := ship_in_cloud(&sys)
	defer destroy(&s)
	s.cargo[int(econ.Commodity.Ore)] = s.stats.cargo_cap
	s.propellant = s.stats.propellant_cap
	sk: Skim
	skim_stop(&sk)
	ok, _ := skim_start(&sys, &s, &sk, 0)
	testing.expect(t, !ok, "nowhere to put it, so no scoop")

	// With room only in the tank it still runs, and only fuels.
	s.propellant = 0
	ok2, why := skim_start(&sys, &s, &sk, 0)
	testing.expectf(t, ok2, "an empty tank is reason enough: %s", why)
	skim_step(&sys, &s, &sk, skim_cycle() * 1.01)
	testing.expect(t, s.propellant > 0, "the tank fills from the stream")
	testing.expect(t, cargo_used(&s) <= s.stats.cargo_cap + 1e-9, "the hold never overfills")
}

// The gas wears the hull, and a supernova shell wears it faster.
@(test)
nebula_is_a_hazard :: proc(t: ^testing.T) {
	quiet := cloud_system(.Nursery)
	defer gen.destroy(&quiet)
	shocked := cloud_system(.Supernova)
	defer gen.destroy(&shocked)
	pq := quiet.pos[0] + gen.nebula_thickest(quiet.nebulae[0])
	ps := shocked.pos[0] + gen.nebula_thickest(shocked.nebulae[0])
	rq, kq := hazard_at(&quiet, pq)
	rs, ks := hazard_at(&shocked, ps)
	testing.expect(t, kq == .Dust && ks == .Dust, "gas is a dust hazard")
	testing.expectf(t, rs > rq, "a remnant (%.3g/s) must bite harder than a nursery (%.3g/s)", rs, rq)
	// Slow enough to sit in for a working day, not a whole career.
	hours := 1 / (rq * core.SECONDS_PER_HOUR)
	testing.expectf(t, hours > 40 && hours < 400, "a nursery should take %v hours to kill a hull", hours)
}
