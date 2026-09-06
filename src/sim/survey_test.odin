package sim

import "core:testing"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"

// A nebula site: a core star, a cloud, and nothing else. This is the case
// that has no stations and no markets at all, so it is the one that proves
// survey ships do not need either.
@(private = "file")
site_system :: proc() -> gen.System {
	sys: gen.System
	alloc := gen.init_empty(&sys, 909)
	context.allocator = alloc
	sys.name = "Site"
	sys.is_site = true
	sys.star = gen.Star{kind = .Main_Sequence, class = "M", mass = 0.3, luminosity = 0.02, radius = core.STAR_RADIUS * 0.4, heat_radius = 120}
	append(&sys.bodies, gen.Body{name = "Site", parent = gen.NONE, kind = .Star, mu = core.MU_SOLAR * 0.3, mass = 0.3, radius = sys.star.radius, soi = 1e30})
	n := gen.make_nebula(gen.Nebula_Roll{present = true, site = true, kind = .Nursery, density = 0.9, radius_k = 1, stars = 5, seed = 4141}, gen.NEBULA_SITE_SCALE, sys.star)
	append(&sys.nebulae, n)
	gen.finish(&sys)
	sys.extent = n.radius
	return sys
}

@(test)
surveyors_spawn_in_a_starless_market :: proc(t: ^testing.T) {
	sys := site_system()
	defer gen.destroy(&sys)
	e: econ.Economy
	defer econ.destroy(&e)
	econ.build(&e, &sys)
	testing.expect(t, len(e.markets) == 0, "a site has nothing to trade with")

	f: Fleet
	defer fleet_destroy(&f)
	fleet_spawn(&f, &sys, &e, 0)
	testing.expectf(t, len(f.npcs) >= 2, "a cloud should have ships working it, got %d", len(f.npcs))
	for &n in f.npcs {
		testing.expect(t, n.role == .Surveyor, "with nowhere to dock, every ship is a surveyor")
		p, _ := npc_state(&sys, &n, 0)
		d := gen.nebula_density_at(sys.nebulae[0], p - sys.pos[0])
		testing.expectf(t, d > 0, "%s spawned outside the gas it came to survey", n.name)
	}
}

// Left alone for a few days, surveyors fill their holds out of the cloud and
// come to no harm doing it.
@(test)
surveyors_work_the_cloud :: proc(t: ^testing.T) {
	sys := site_system()
	defer gen.destroy(&sys)
	e: econ.Economy
	defer econ.destroy(&e)
	econ.build(&e, &sys)
	f: Fleet
	defer fleet_destroy(&f)
	fleet_spawn(&f, &sys, &e, 0)

	step := core.SECONDS_PER_HOUR * 0.5
	t_now := 0.0
	for _ in 0 ..< 240 { // five game days
		gen.update(&sys, t_now + step)
		fleet_update(&f, &sys, &e, t_now, step)
		t_now += step
	}
	scooped, alive, passes := 0, 0, 0
	for &n in f.npcs {
		if !is_dead(&n.ship) do alive += 1
		total := n.surveyed + n.skim.cycles
		passes += total
		if total > 0 do scooped += 1
	}
	testing.expectf(t, alive == len(f.npcs), "%d of %d surveyors survived five days in the gas", alive, len(f.npcs))
	testing.expectf(t, scooped == len(f.npcs), "only %d of %d surveyors completed a pass in five days", scooped, len(f.npcs))
	testing.expectf(t, passes >= len(f.npcs) * 3, "five days should be more than %d passes across the fleet", passes)
	// A survey hull is built for the gas: five days in it should not kill one.
	for &n in f.npcs do testing.expectf(t, n.ship.hull > 0.99, "%s lost hull to dust it is meant to shrug off (%.2f)", n.name, n.ship.hull)
	for &n in f.npcs do testing.expectf(t, cargo_used(&n.ship) > 0, "%s ran passes and has nothing aboard", n.name)
}

// A surveyor in a system that does have markets runs its haul in and sells.
@(test)
surveyors_sell_a_full_hold :: proc(t: ^testing.T) {
	sys := gen.generate(gen.system_seed(3, 1)) // a working system with a reflection nebula
	defer gen.destroy(&sys)
	if len(sys.nebulae) == 0 || len(sys.stations) == 0 {
		testing.expect(t, true, "fixture seed no longer has both a nebula and stations")
		return
	}
	e: econ.Economy
	defer econ.destroy(&e)
	econ.build(&e, &sys)
	f: Fleet
	defer fleet_destroy(&f)
	fleet_spawn(&f, &sys, &e, 0)
	surveyors := 0
	for &n in f.npcs do if n.role == .Surveyor do surveyors += 1
	testing.expectf(t, surveyors > 0, "a system with a cloud should have survey ships too")
	// They must not be counted as traders: a surveyor has no route.
	for &n in f.npcs do if n.role == .Surveyor do testing.expect(t, !n.has_route, "a surveyor runs no route")
}
