package input

import "core:testing"
import rl "vendor:raylib"

@(test)
keys_round_trip_through_names :: proc(t: ^testing.T) {
	d := DEFAULTS
	for b in Bind {
		name := key_to_string(d[b])
		back, ok := key_from_string(name)
		testing.expectf(t, ok && back == d[b], "%v: %s -> %v", b, name, back)
		bn := bind_to_string(b)
		bb, ok2 := bind_from_string(bn)
		testing.expect(t, ok2 && bb == b, "bind name round trip")
		testing.expect(t, key_label(d[b]) != "", "every default has a label")
	}
	testing.expect(t, key_label(.LEFT_BRACKET) == "[" && key_label(.F5) == "F5" && key_label(.ONE) == "1" && key_label(.SPACE) == "Space", "labels read naturally")
	testing.expect(t, !rebindable(.ESCAPE) && !rebindable(.ENTER) && rebindable(.Q), "escape and enter stay fixed")
}

@(test)
conflicts_are_detected :: proc(t: ^testing.T) {
	keymap = DEFAULTS
	defer keymap = DEFAULTS
	for b in Bind do testing.expectf(t, !conflicts(b), "defaults do not clash: %v", b)
	keymap[.Dock] = rl.KeyboardKey.V
	keymap[.Pause] = rl.KeyboardKey.V
	testing.expect(t, conflicts(.Dock) && conflicts(.Pause), "a new clash is reported on both binds")
}
