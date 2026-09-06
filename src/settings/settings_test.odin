package settings

import "core:os"
import "core:testing"
import rl "vendor:raylib"
import input "sim:input"

@(test)
settings_round_trip_through_json :: proc(t: ^testing.T) {
	path := "bin/settings_test.json"
	defer os.remove(path)
	s := defaults()
	defer delete(s.controls)
	s.graphics.star_glow = 1.7
	s.graphics.effects = false
	s.display.mode = .Borderless
	s.display.width = 1920
	s.sound.music = 0.25
	s.controls[input.bind_to_string(.Pause)] = input.key_to_string(rl.KeyboardKey.B)
	testing.expect(t, save(s, path), "written")
	back := load(path)
	defer delete(back.controls)
	testing.expect(t, back.graphics.star_glow == 1.7 && !back.graphics.effects, "graphics restored")
	testing.expect(t, back.display.mode == .Borderless && back.display.width == 1920, "display restored")
	testing.expect(t, back.sound.music == 0.25, "sound restored")
	apply_controls(back)
	defer input.keymap = input.DEFAULTS
	testing.expect(t, input.keymap[.Pause] == .B, "rebound key applied")
	testing.expect(t, input.keymap[.Dock] == input.DEFAULTS[.Dock], "untouched binds keep their defaults")
}

@(test)
missing_settings_file_gives_defaults :: proc(t: ^testing.T) {
	s := load("bin/does_not_exist.json")
	defer delete(s.controls)
	d := defaults()
	defer delete(d.controls)
	testing.expect(t, s.graphics == d.graphics && s.display == d.display && s.sound == d.sound, "defaults")
	testing.expect(t, len(s.controls) == len(input.Bind), "every bind listed")
}
