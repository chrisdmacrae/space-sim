package settings

// Player settings: graphics, display, sound and key bindings, kept in
// settings.json beside the saves. `apply` pushes them into the systems that
// read them; `capture_controls` pulls the live keymap back before saving.

import "core:encoding/json"
import "core:os"
import rl "vendor:raylib"
import audio "sim:audio"
import core "sim:core"
import input "sim:input"

PATH :: "settings.json"

Display_Mode :: enum u8 {
	Windowed,
	Borderless,
	Fullscreen,
}

Resolution :: struct { w, h: int }
RESOLUTIONS :: [?]Resolution{{1280, 800}, {1440, 900}, {1600, 1000}, {1920, 1080}, {2560, 1440}}

Settings :: struct {
	graphics: struct {
		star_glow:    f32,
		effects:      bool,
		shading:      bool,
		star_density: f32,
		vsync:        bool,
	},
	display: struct {
		mode:   Display_Mode,
		width:  int,
		height: int,
	},
	sound: struct {
		master: f32,
		music:  f32,
		sfx:    f32,
	},
	controls: map[string]string, // bind name -> key name
}

defaults :: proc(allocator := context.allocator) -> (s: Settings) {
	s.graphics = {star_glow = 1, effects = true, shading = true, star_density = 1, vsync = true}
	s.display = {mode = .Windowed, width = 1280, height = 800}
	s.sound = {master = 0.8, music = 0.6, sfx = 0.8}
	s.controls = make(map[string]string, allocator)
	d := input.DEFAULTS
	for b in input.Bind do s.controls[input.bind_to_string(b)] = input.key_to_string(d[b])
	return
}

load :: proc(path := PATH, allocator := context.allocator) -> (s: Settings) {
	s = defaults(allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return
	loaded: Settings
	if json.unmarshal(data, &loaded, allocator = allocator) != nil do return
	// Missing numbers come back as zero; keep the defaults for those.
	if loaded.graphics.star_glow > 0 do s.graphics = loaded.graphics
	if loaded.display.width > 0 do s.display = loaded.display
	if loaded.sound.master > 0 || loaded.sound.music > 0 || loaded.sound.sfx > 0 do s.sound = loaded.sound
	for k, v in loaded.controls do s.controls[k] = v
	return
}

save :: proc(s: Settings, path := PATH) -> bool {
	data, err := json.marshal(s, {pretty = true}, context.temp_allocator)
	if err != nil do return false
	return os.write_entire_file(path, data) == nil
}

// ---- pushing settings into the game

apply_controls :: proc(s: Settings) {
	input.keymap = input.DEFAULTS
	for name, keyname in s.controls {
		b, ok1 := input.bind_from_string(name)
		k, ok2 := input.key_from_string(keyname)
		if ok1 && ok2 do input.keymap[b] = k
	}
}

capture_controls :: proc(s: ^Settings) {
	for b in input.Bind do s.controls[input.bind_to_string(b)] = input.key_to_string(input.keymap[b])
}

apply_graphics :: proc(s: Settings) {
	core.tuning.star_glow_scale = s.graphics.star_glow
	core.gfx.effects = s.graphics.effects
	core.gfx.shading = s.graphics.shading
	core.gfx.star_density = s.graphics.star_density
	if s.graphics.vsync do rl.SetWindowState({.VSYNC_HINT})
	else do rl.ClearWindowState({.VSYNC_HINT})
}

apply_sound :: proc(s: Settings) {
	audio.set_volumes(s.sound.master, s.sound.music, s.sound.sfx)
}

// Window mode and size. Fullscreen uses the monitor's mode; borderless
// covers the monitor; windowed takes the chosen size.
apply_display :: proc(s: Settings) {
	borderless := rl.IsWindowState({.BORDERLESS_WINDOWED_MODE})
	full := rl.IsWindowFullscreen()
	switch s.display.mode {
	case .Windowed:
		if full do rl.ToggleFullscreen()
		if borderless do rl.ToggleBorderlessWindowed()
		if s.display.width > 0 && s.display.height > 0 do rl.SetWindowSize(i32(s.display.width), i32(s.display.height))
	case .Borderless:
		if full do rl.ToggleFullscreen()
		if !borderless do rl.ToggleBorderlessWindowed()
	case .Fullscreen:
		if borderless do rl.ToggleBorderlessWindowed()
		if !full do rl.ToggleFullscreen()
	}
}

apply_all :: proc(s: Settings) {
	apply_controls(s)
	apply_graphics(s)
	apply_sound(s)
	apply_display(s)
}
