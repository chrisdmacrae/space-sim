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
