package main

import "core:testing"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"
import sim "sim:sim"

// A Game with one trader parked a short hop off the player's bow. Positions are
// set by hand: the hail only reads them, so no orbit needs to be integrated.
hail_fixture :: proc(g: ^Game, e: ^econ.Economy) {
	g.galaxy = gen.galaxy_generate(7)
	g.current = 0
	g.sys = gen.generate(g.galaxy.systems[0].seed)
	econ.build(e, &g.sys)
	g.econ = e
	g.ship.mode = .On_Rails
	g.ship.primary = gen.STAR
	g.ship.class = .Courier
	g.ship.pos = {0, 0}
	n: sim.Npc
	n.name = "Test Hauler"
	n.seed = 42
	n.ship.mode = .On_Rails
	n.ship.primary = gen.STAR
	n.ship.class = .Hauler
	n.ship.pos = {HAIL_RANGE / 2, 0}
	append(&g.fleet.npcs, n)
}

hail_fixture_destroy :: proc(g: ^Game, e: ^econ.Economy) {
	talk_close(g)
	notices_destroy(g)
	delete(g.fleet.npcs)
	econ.destroy(e)
	gen.destroy(&g.sys)
	gen.galaxy_destroy(&g.galaxy)
}

// Run the check over `days` of game time, taking `choice` on every hail it raises.
// Steps are a quarter day, so every cooldown in the check expires many times over.
hail_run :: proc(g: ^Game, t: ^f64, days: int, choice: int) -> (hails: int) {
	for _ in 0 ..< days * 4 {
		t^ += core.SECONDS_PER_DAY / 4
		hail_check(g, t^)
		if len(g.notices) > 0 {
			hails += 1
			notice_choose(g, choice, t^)
		}
	}
	return
}

// Ignoring a trader stops it calling. It used to hail again a game day later, and
// a day at warp is a second of real time, so an ignored ship rang on and on.
@(test)
hail_ignored_trader_stays_quiet :: proc(t: ^testing.T) {
	g: Game
	e: econ.Economy
	hail_fixture(&g, &e)
	defer hail_fixture_destroy(&g, &e)

	tt := 100 * core.SECONDS_PER_DAY
	first := hail_run(&g, &tt, 2, 1) // Ignore
	testing.expectf(t, first == 1, "a trader in range should hail once, got %d", first)

	again := hail_run(&g, &tt, 30, 1)
	testing.expectf(t, again == 0, "an ignored trader should not hail again, got %d", again)

	// Not even after leaving and coming back: ignoring it is an answer.
	g.fleet.npcs[0].ship.pos = {HAIL_RANGE * 4, 0}
	hail_run(&g, &tt, 2, 1)
	g.fleet.npcs[0].ship.pos = {HAIL_RANGE / 2, 0}
	back := hail_run(&g, &tt, 30, 1)
	testing.expectf(t, back == 0, "an ignored trader should stay quiet on a new pass, got %d", back)
}

// Answering is not a licence to call again: one hail belongs to one approach,
// however long the trader keeps station. A later pass may hail once more.
@(test)
hail_is_once_per_approach :: proc(t: ^testing.T) {
	g: Game
	e: econ.Economy
	hail_fixture(&g, &e)
	defer hail_fixture_destroy(&g, &e)

	tt := 100 * core.SECONDS_PER_DAY
	first := hail_run(&g, &tt, 30, 0) // Answer
	testing.expectf(t, first == 1, "one hail for one approach, got %d", first)

	// Out of range and back again: a fresh pass, and a day on from the last hail.
	g.fleet.npcs[0].ship.pos = {HAIL_RANGE * 4, 0}
	hail_run(&g, &tt, 2, 0)
	g.fleet.npcs[0].ship.pos = {HAIL_RANGE / 2, 0}
	second := hail_run(&g, &tt, 30, 0)
	testing.expectf(t, second == 1, "a new approach may hail once, got %d", second)
}

// The player has to be coasting to take a call. A trader that could not be heard
// keeps its turn: it calls once the player is back on rails, and only once.
@(test)
hail_needs_the_player_on_rails :: proc(t: ^testing.T) {
	g: Game
	e: econ.Economy
	hail_fixture(&g, &e)
	defer hail_fixture_destroy(&g, &e)

	g.ship.mode = .Docked
	tt := 100 * core.SECONDS_PER_DAY
	docked := hail_run(&g, &tt, 10, 1)
	testing.expectf(t, docked == 0, "no hails while docked, got %d", docked)

	g.ship.mode = .On_Rails
	casting_off := hail_run(&g, &tt, 30, 1)
	testing.expectf(t, casting_off == 1, "the trader still gets its one hail, got %d", casting_off)
}
