package crew

import "core:testing"
import core "sim:core"
import econ "sim:econ"

@(test)
levels_follow_hours_of_duty :: proc(t: ^testing.T) {
	testing.expect(t, level_for(0) == 1, "fresh hands are level 1")
	testing.expect(t, level_for(LEVEL_HOURS[1]) == 2, "level 2 at its threshold")
	testing.expect(t, level_for(LEVEL_HOURS[1] - 1) == 1, "just under stays level 1")
	testing.expect(t, level_for(1e9) == MAX_LEVEL, "levels stop at the top")
}

@(test)
starting_crew_fills_the_bunks_and_stands_its_trades :: proc(t: ^testing.T) {
	ro: Roster
	defer roster_destroy(&ro)
	roster_init(&ro, 7, BUNKS[.Courier])
	testing.expectf(t, len(ro.members) == 2, "a courier carries two (%d)", len(ro.members))
	testing.expect(t, ro.members[0].specialty == .Engineering && ro.members[0].post == .Engineering, "an engineer at engineering")
	testing.expect(t, ro.members[1].specialty == .Navigation && ro.members[1].post == .Navigation, "a navigator on the bridge")
	testing.expect(t, level(&ro.members[0], .Engineering) == 2, "a specialist starts at level 2 in their trade")
	testing.expect(t, level(&ro.members[0], .Comms) == 1, "and level 1 elsewhere")
	testing.expect(t, len(ro.members[0].name) > 3 && ro.members[0].name != ro.members[1].name, "named, and not the same person twice")
	// Deterministic from the seed.
	ro2: Roster
	defer roster_destroy(&ro2)
	roster_init(&ro2, 7, 2)
	testing.expect(t, ro2.members[1].name == ro.members[1].name, "same seed, same crew")
}

@(test)
duty_levels_up_only_the_system_stood_and_only_the_posted :: proc(t: ^testing.T) {
	ro: Roster
	defer roster_destroy(&ro)
	roster_init(&ro, 3, 2)
	ro.members[1].post = .Off_Duty
	// A day of duty: the engineer gains, the idle navigator does not.
	roster_work(&ro, core.SECONDS_PER_DAY)
	e := &ro.members[0]
	testing.expectf(t, e.xp[.Engineering] > LEVEL_HOURS[1] + 30, "a specialist banks a day and a half of hours per day (%.1f)", e.xp[.Engineering])
	testing.expect(t, e.xp[.Navigation] == 0 && e.xp[.Comms] == 0, "nothing on the systems not stood")
	testing.expect(t, ro.members[1].xp[.Navigation] == LEVEL_HOURS[1], "off duty learns nothing")
	// Long enough to level: the event is queued once, with the new level.
	roster_work(&ro, 10 * core.SECONDS_PER_DAY)
	testing.expectf(t, len(ro.levelled) >= 1, "a level-up was queued (%d)", len(ro.levelled))
	if len(ro.levelled) > 0 {
		lu := ro.levelled[0]
		testing.expect(t, lu.member == 0 && lu.system == .Engineering && lu.level == 3, "the engineer reached level 3")
	}
	// Posted out of trade: slower, but it still counts.
	e.post = .Comms
	before := e.xp[.Comms]
	roster_work(&ro, core.SECONDS_PER_DAY)
	testing.expectf(t, abs(e.xp[.Comms] - before - 24) < 1e-6, "24 hours of comms for a day out of trade (%.1f)", e.xp[.Comms] - before)
	// The top level holds.
	roster_work(&ro, 400 * core.SECONDS_PER_DAY)
	testing.expect(t, level(e, .Comms) == MAX_LEVEL && progress(e, .Comms) == 1, "capped at the top")
}

@(test)
effects_grow_with_the_level_stood_and_vanish_unstaffed :: proc(t: ^testing.T) {
	ro: Roster
	defer roster_destroy(&ro)
	roster_init(&ro, 11, 3)
	e0 := effects(&ro)
	testing.expect(t, e0.repair_per_hour > 0 && e0.shield > 0 && e0.ve_bonus > 1 && e0.trade_edge > 0, "every system does something when stood")
	ro.members[0].post = .Off_Duty
	e1 := effects(&ro)
	testing.expect(t, e1.repair_per_hour == 0 && e1.shield == 0, "nobody at engineering: no repairs")
	testing.expect(t, e1.ve_bonus == e0.ve_bonus, "the bridge is unaffected")
	ro.members[0].post = .Engineering
	ro.members[0].xp[.Engineering] = LEVEL_HOURS[3] // level 4
	e2 := effects(&ro)
	testing.expect(t, e2.repair_per_hour > e0.repair_per_hour && e2.shield > e0.shield, "a better engineer repairs faster")
	testing.expect(t, e2.shield < 1, "never immune")
	// Two hands on one system: a little better than the best of them alone.
	ro.members[2].post = .Engineering
	e3 := effects(&ro)
	testing.expect(t, e3.repair_per_hour > e2.repair_per_hour && e3.level[.Engineering] <= MAX_LEVEL, "an extra hand helps, within the cap")
}

@(test)
hiring_respects_bunks_and_candidates_are_seeded :: proc(t: ^testing.T) {
	ro: Roster
	defer roster_destroy(&ro)
	roster_init(&ro, 5, 2)
	a := candidates(&ro, 99, 0, 0)
	b := candidates(&ro, 99, 0, core.SECONDS_PER_DAY)
	testing.expectf(t, len(a) == CANDIDATES_PER_STATION && len(b) == len(a), "a station offers a few faces a week (%d)", len(a))
	testing.expect(t, a[0].seed == b[0].seed && a[0].name == b[0].name, "the same faces wait through the week")
	testing.expect(t, a[0].fee >= HIRE_FEE_BASE && a[0].level >= 1, "each with a fee and a level")
	testing.expect(t, !hire(&ro, a[0], 2), "no bunk, no hire")
	testing.expect(t, hire(&ro, a[0], 3), "a bigger hull takes them")
	testing.expect(t, ro.members[2].post == .Off_Duty && level(&ro.members[2], a[0].specialty) == a[0].level, "aboard, off duty, at the level advertised")
	c := candidates(&ro, 99, 0, 0)
	testing.expect(t, len(c) == CANDIDATES_PER_STATION - 1, "who is aboard is no longer on the dock")
	testing.expect(t, trim(&ro, 2) == 1 && len(ro.members) == 2, "a smaller hull puts the last aboard ashore")
}

@(test)
decks_have_every_room_and_the_crew_can_walk_between_them :: proc(t: ^testing.T) {
	for c in econ.Class_Id {
		d := deck_build(c, BUNKS[c])
		defer deck_destroy(&d)
		for k in ([?]Room_Kind{.Bridge, .Comms, .Engineering, .Quarters, .Galley, .Hold}) {
			testing.expectf(t, room_index(&d, k) >= 0, "%v has a %v", c, k)
		}
		for &r in d.rooms {
			testing.expectf(t, r.x1 > r.x0 + 2 && r.y1 > r.y0 + 2, "%v %v is roomy (%.1f x %.1f)", c, r.kind, r.x1 - r.x0, r.y1 - r.y0)
			testing.expectf(t, len(r.spots) > 0, "%v %v has somewhere to stand", c, r.kind)
			for s in r.spots do testing.expectf(t, room_contains(&r, s.at), "%v %v spot inside the room", c, r.kind)
			testing.expectf(t, abs(hull_half_beam(&d, r.x0)) >= abs(r.y0) - 0.01 && abs(hull_half_beam(&d, r.x1)) >= abs(r.y1) - 0.01, "%v %v inside the hull", c, r.kind)
			testing.expectf(t, abs(r.entry.y) < 1e-6, "%v %v door opens onto the corridor", c, r.kind)
		}
		q := room_index(&d, .Quarters)
		testing.expectf(t, len(d.rooms[q].fixtures) == BUNKS[c], "%v quarters have a bunk per berth (%d)", c, len(d.rooms[q].fixtures))
	}
	// A walker posted to the bridge gets there from the quarters and stops moving.
	ro: Roster
	defer roster_destroy(&ro)
	roster_init(&ro, 1, 2)
	d := deck_build(.Courier, 2)
	defer deck_destroy(&d)
	m := &ro.members[1]
	walker_place(&m.walker, &d, room_index(&d, .Quarters), &ro.rng)
	walker_go(&m.walker, &d, room_index(&d, .Bridge), &ro.rng)
	testing.expect(t, m.walker.path_n == 5 && m.walker.moving, "by the door, the corridor and the far door")
	for _ in 0 ..< 600 do walk_update(&ro, &d, 1.0 / 30)
	br := &d.rooms[room_index(&d, .Bridge)]
	testing.expect(t, room_contains(br, m.walker.pos), "on the bridge after a while")
}
