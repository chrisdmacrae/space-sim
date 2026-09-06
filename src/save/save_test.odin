package save

import "core:os"
import "core:testing"

@(test)
slot_paths_and_listing :: proc(t: ^testing.T) {
	testing.expect(t, slot_path(0) == "saves/quick.json", "quick slot path")
	testing.expect(t, slot_path(3) == "saves/slot3.json", "numbered slot path")
	// A slot file that is not valid JSON lists as empty rather than crashing.
	os.make_directory("saves")
	path := slot_path(SLOTS)
	had := os.exists(path)
	if !had {
		_ = os.write_entire_file(path, transmute([]u8)string("not json"))
		defer os.remove(path)
		infos := list_slots()
		testing.expect(t, !infos[SLOTS].exists, "garbage slot reads as empty")
	}
	infos := list_slots()
	testing.expect(t, len(infos) == SLOTS + 1, "quick plus five slots")
}

import crew "sim:crew"
import econ "sim:econ"
import sim "sim:sim"

@(test)
crew_round_trips_through_a_save :: proc(t: ^testing.T) {
	ro: crew.Roster
	defer crew.roster_destroy(&ro)
	crew.roster_init(&ro, 21, 3)
	ro.members[2].post = .Off_Duty
	ro.members[0].xp[.Engineering] = 300
	ship := sim.Ship{class = .Hauler, hull = 0.7}
	ge: econ.Galaxy_Econ
	sv := capture(21, 1000, 0, 5000, &ship, &ge, roster = &ro)
	testing.expectf(t, len(sv.crew) == 3, "every member captured (%d)", len(sv.crew))
	// Back into a fresh roster: same people, same posts, same hours.
	back: crew.Roster
	defer crew.roster_destroy(&back)
	crew.roster_init(&back, 99, 2) // a different starting crew, to be replaced
	apply_crew(sv, &back)
	testing.expect(t, len(back.members) == 3, "the saved crew replace the rolled one")
	for &m, i in back.members {
		o := &ro.members[i]
		testing.expectf(t, m.name == o.name && m.seed == o.seed, "member %d is the same person", i)
		testing.expectf(t, m.post == o.post && m.specialty == o.specialty, "member %d keeps their post and trade", i)
		testing.expectf(t, m.xp == o.xp, "member %d keeps their hours", i)
	}
	// An older save with no crew leaves the starting crew alone.
	old := Save{version = VERSION}
	apply_crew(old, &back)
	testing.expect(t, len(back.members) == 3, "no crew in the save: nothing changes")
}
