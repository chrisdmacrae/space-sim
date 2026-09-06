package ui

// The start menu and its screens: home, new game (galaxy and ship), save
// slots (load or save), and settings with graphics, display, sound and
// rebindable controls. The same screens open from the in-game System menu.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:time"
import rl "vendor:raylib"
import art "sim:art"
import audio "sim:audio"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"
import input "sim:input"
import settings "sim:settings"
import sim "sim:sim"
import text "sim:text"

Title_Screen :: enum u8 {
	Home,
	New_Game,
	Slots,
	Settings,
}

Title_Action :: enum u8 {
	None,
	Resume,       // back to the running game
	Start_Game,   // with the New_Game choices
	Load_Slot,    // slot in the result
	Save_Slot,
	Quit,
	Settings_Live,   // graphics or sound changed: apply now
	Settings_Apply,  // Apply pressed: display too, then persist
	Settings_Closed, // leaving the settings screen: persist
}

Slot_Card :: struct {
	exists:      bool,
	system:      string,
	ship:        string,
	credits:     f64,
	t:           f64,
	saved_at:    i64,
	version_ok:  bool,
}

Title_State :: struct {
	screen:     Title_Screen,
	saving:     bool, // Slots screen saves instead of loads
	// new game
	seed:       Text_Field,
	kind_idx:   int, // 0 = seed decides
	size_idx:   int,
	class_idx:  int,
	// settings
	tab:        int,
	mode_idx:   int,
	res_idx:    int,
	rebinding:  bool,
	rebind:     input.Bind,
	scroll:     f32,
	msg:        string,
	inited:     bool,
}

Title_View :: struct {
	lib:      ^art.Library,
	slots:    []Slot_Card, // quick slot first, then 1..SLOTS
	settings: ^settings.Settings,
	has_game: bool, // a game is running underneath
	seed_hint: u64, // seed shown when the field is empty
}

GALAXY_KINDS :: [?]string{"Let the seed decide", "Spiral", "Elliptical", "Lenticular", "Irregular"}
GALAXY_SIZES :: [?]string{"Small (150 systems)", "Normal (420 systems)", "Large (800 systems)"}
SIZE_COUNTS :: [?]int{gen.SIZE_SMALL, gen.SIZE_NORMAL, gen.SIZE_LARGE}
DISPLAY_MODES :: [?]string{"Windowed", "Borderless", "Fullscreen"}
SETTINGS_TABS :: [?]string{"Graphics", "Display", "Sound", "Controls"}

// What the New game screen chose.
title_new_game_params :: proc(st: ^Title_State, fallback_seed: u64) -> (p: gen.Galaxy_Params, class: econ.Class_Id) {
	p.seed = fallback_seed
	if st.seed.len > 0 do if v, ok := strconv.parse_u64(field_text(&st.seed)); ok do p.seed = v
	counts := SIZE_COUNTS
	p.systems = counts[clamp(st.size_idx, 0, len(counts) - 1)]
	if st.kind_idx > 0 {
		p.kind = gen.Galaxy_Kind(st.kind_idx - 1)
		p.kind_set = true
	}
	class = econ.Class_Id(clamp(st.class_idx, 0, int(econ.NUM_CLASSES) - 1))
	return
}

@(private = "file")
panel :: proc(w, h: f32, title: string) -> rl.Rectangle {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{(sw - w) * 0.5, max((sh - h) * 0.5, BAR_H + 10), w, h}
	rl.DrawRectangleRounded(r, 0.03, 6, {10, 13, 20, 240})
	rl.DrawRectangleRoundedLinesEx(r, 0.03, 6, 1, BAR_LINE)
	text.draw(fmt.ctprintf("%s", title), i32(r.x + 20), i32(r.y + 14), 20, TEXT_MAIN)
	return r
}

@(private = "file")
init_from_settings :: proc(st: ^Title_State, s: ^settings.Settings) {
	st.mode_idx = int(s.display.mode)
	st.res_idx = 0
	res := settings.RESOLUTIONS
	for r, i in res do if r.w == s.display.width && r.h == s.display.height do st.res_idx = i
}

title_draw :: proc(st: ^Title_State, v: Title_View) -> (act: Title_Action, slot: int) {
	slot = -1
	if !st.inited {
		st.inited = true
		st.size_idx = 1
		init_from_settings(st, v.settings)
	}
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	switch st.screen {
	case .Home:
		title := cstring("SPACE SIM")
		tw := f32(text.measure(title, 28))
		text.draw(title, i32((sw - tw) * 0.5), i32(sh * 0.22), 28, TEXT_MAIN)
		sub := cstring("orbits, trade and long sleeps between the stars")
		sw2 := f32(text.measure(sub, 14))
		text.draw(sub, i32((sw - sw2) * 0.5), i32(sh * 0.22 + 40), 14, TEXT_DIM)
		y := sh * 0.42
		bw: f32 = 260
		x := (sw - bw) * 0.5
		if v.has_game {
			if button({x, y, bw, 38}, "Back to game", true, true) do act = .Resume
			y += 48
		}
		if button({x, y, bw, 38}, "New game") { st.screen = .New_Game; audio.play(.Open) }
		y += 48
		if button({x, y, bw, 38}, "Load game") { st.screen = .Slots; st.saving = false; audio.play(.Open) }
		y += 48
		if v.has_game {
			if button({x, y, bw, 38}, "Save game") { st.screen = .Slots; st.saving = true; audio.play(.Open) }
			y += 48
		}
		if button({x, y, bw, 38}, "Settings") { st.screen = .Settings; audio.play(.Open) }
		y += 48
		if button({x, y, bw, 38}, "Quit") do act = .Quit
		if st.msg != "" {
			mw := f32(text.measure(fmt.ctprintf("%s", st.msg), 13))
			text.draw(fmt.ctprintf("%s", st.msg), i32((sw - mw) * 0.5), i32(y + 56), 13, {255, 150, 110, 255})
		}
		if v.has_game && rl.IsKeyPressed(.ESCAPE) do act = .Resume
	case .New_Game:
		r := panel(880, 560, "New game")
		x := r.x + 24
		y := r.y + 56
		text_field({x, y, 420, 28}, "Galaxy seed", &st.seed, true)
		if button({x + 430, y, 90, 28}, "Random") {
			field_set(&st.seed, fmt.tprintf("%d", u64(rl.GetTime() * 1e6) % 1_000_000_007))
		}
		if st.seed.len == 0 do text.draw(fmt.ctprintf("empty: seed %d", v.seed_hint), i32(x + 530), i32(y + 6), 13, TEXT_DIM)
		y += 40
		kinds := GALAXY_KINDS
		cycler({x, y, 520, 28}, "Galaxy shape", kinds[:], &st.kind_idx)
		y += 40
		sizes := GALAXY_SIZES
		cycler({x, y, 520, 28}, "Galaxy size", sizes[:], &st.size_idx)
		y += 48
		text.draw("Starting ship", i32(x), i32(y), 15, TEXT_MAIN)
		text.draw("The ship is free; you start with 5,000 credits either way.", i32(x + 200), i32(y), 13, TEXT_DIM)
		y += 26
		cw: f32 = (r.width - 48 - 4 * 10) / 5
		mouse := rl.GetMousePosition()
		for c in econ.Class_Id {
			i := int(c)
			cr := rl.Rectangle{x + f32(i) * (cw + 10), y, cw, 250}
			over := rl.CheckCollisionPointRec(mouse, cr)
			sel := st.class_idx == i
			rl.DrawRectangleRounded(cr, 0.06, 4, sel ? rl.Color{40, 50, 70, 255} : (over ? rl.Color{30, 36, 50, 255} : rl.Color{18, 22, 32, 255}))
			if sel do rl.DrawRectangleRoundedLinesEx(cr, 0.06, 4, 1, ACCENT)
			cls := sim.CLASSES[c]
			if doc := art.library_get(v.lib, cls.art); doc != nil {
				art.draw_doc(doc, "idle", art.Xform{origin = {cr.x + cr.width * 0.5, cr.y + 52}, px = min(4, 84 / art.doc_length(doc)), rot = -math.PI / 2})
			}
			name := fmt.ctprintf("%s", econ.CLASS_NAMES[c])
			nw := f32(text.measure(name, 16))
			text.draw(name, i32(cr.x + (cr.width - nw) * 0.5), i32(cr.y + 100), 16, TEXT_MAIN)
			st_ := cls.stats
			m0 := st_.mass_dry + st_.propellant_cap
			dv := st_.ve * math.ln(m0 / st_.mass_dry)
			lines := [?]string {
				fmt.tprintf("cargo %.0f units", st_.cargo_cap),
				fmt.tprintf("dv %.3f full", dv),
				fmt.tprintf("accel %.5f", st_.thrust / m0),
				fmt.tprintf("cryo %.2fc", cls.cryo_speed),
			}
			ly := cr.y + 128
			for l in lines {
				text.draw(fmt.ctprintf("%s", l), i32(cr.x + 12), i32(ly), 13, TEXT_DIM)
				ly += 20
			}
			blurb: string
			switch c {
			case .Courier:   blurb = "small and nimble"
			case .Hauler:    blurb = "room for cargo"
			case .Clipper:   blurb = "quick, decent cryo"
			case .Freighter: blurb = "the big hold"
			case .Sleeper:   blurb = "fastest between stars"
			}
			text.draw(fmt.ctprintf("%s", blurb), i32(cr.x + 12), i32(cr.y + 220), 12, {220, 170, 90, 255})
			if over && rl.IsMouseButtonPressed(.LEFT) && !sel {
				st.class_idx = i
				audio.play(.Click)
			}
		}
		by := r.y + r.height - 50
		if button({r.x + 24, by, 120, 34}, "Back") { st.screen = .Home; audio.play(.Close) }
		if button({r.x + r.width - 184, by, 160, 34}, "Start", true, true) {
			act = .Start_Game
			audio.play(.Confirm)
		}
		if rl.IsKeyPressed(.ESCAPE) && !st.seed.focus { st.screen = .Home; audio.play(.Close) }
	case .Slots:
		r := panel(760, 520, st.saving ? "Save game" : "Load game")
		y := r.y + 56
		for card, i in v.slots {
			cr := rl.Rectangle{r.x + 20, y, r.width - 40, 62}
			rl.DrawRectangleRounded(cr, 0.15, 4, {18, 22, 32, 255})
			name := i == 0 ? "Quick slot" : fmt.tprintf("Slot %d", i)
			text.draw(fmt.ctprintf("%s", name), i32(cr.x + 14), i32(cr.y + 10), 15, TEXT_MAIN)
			if card.exists {
				when_ := time.unix(card.saved_at, 0)
				yy, mm, dd := time.date(when_)
				hh, mi, _ := time.clock_from_time(when_)
				text.draw(fmt.ctprintf("%s   %s   %.0f credits", card.system, card.ship, card.credits), i32(cr.x + 14), i32(cr.y + 34), 13, TEXT_DIM)
				text.draw(fmt.ctprintf("%s", core.clock_format(card.t)), i32(cr.x + 330), i32(cr.y + 10), 13, TEXT_DIM)
				if card.saved_at > 0 do text.draw(fmt.ctprintf("saved %04d-%02d-%02d %02d:%02d", yy, mm, dd, hh, mi), i32(cr.x + 330), i32(cr.y + 34), 13, TEXT_DIM)
				else do text.draw("saved by an earlier build", i32(cr.x + 330), i32(cr.y + 34), 13, TEXT_DIM)
				if !card.version_ok do text.draw("old version", i32(cr.x + 330), i32(cr.y + 34), 13, {255, 140, 120, 255})
			} else {
				text.draw("empty", i32(cr.x + 14), i32(cr.y + 34), 13, TEXT_DIM)
			}
			label := st.saving ? (card.exists ? "Overwrite" : "Save here") : "Load"
			enabled := st.saving || (card.exists && card.version_ok)
			if button({cr.x + cr.width - 120, cr.y + 15, 106, 32}, label, enabled, st.saving && !card.exists) {
				act = st.saving ? .Save_Slot : .Load_Slot
				slot = i
				audio.play(.Confirm)
			}
			y += 70
		}
		if st.msg != "" do text.draw(fmt.ctprintf("%s", st.msg), i32(r.x + 20), i32(r.y + r.height - 44), 13, {150, 230, 170, 255})
		if button({r.x + r.width - 144, r.y + r.height - 50, 120, 34}, "Back") { st.screen = .Home; st.msg = ""; audio.play(.Close) }
		if rl.IsKeyPressed(.ESCAPE) { st.screen = .Home; st.msg = ""; audio.play(.Close) }
	case .Settings:
		r := panel(820, 600, "Settings")
		tabs_ := SETTINGS_TABS
		tabs({r.x + 20, r.y + 48, r.width - 40, 30}, tabs_[:], &st.tab)
		s := v.settings
		x := r.x + 28
		y := r.y + 96
		live := false
		switch st.tab {
		case 0:
			live |= slider({x, y, r.width - 56, 20}, "Star glow", &s.graphics.star_glow, 0.3, 2.5, "%.1fx")
			y += 40
			live |= slider({x, y, r.width - 56, 20}, "Background stars", &s.graphics.star_density, 0.25, 2, "%.2fx")
			y += 40
			live |= toggle({x, y, 320, 26}, "Planet lighting and shading", &s.graphics.shading)
			y += 34
			live |= toggle({x, y, 320, 26}, "Explosions and cryo streaks", &s.graphics.effects)
			y += 34
			live |= toggle({x, y, 320, 26}, "Vertical sync", &s.graphics.vsync)
		case 1:
			modes := DISPLAY_MODES
			cycler({x, y, 520, 28}, "Window mode", modes[:], &st.mode_idx)
			s.display.mode = settings.Display_Mode(st.mode_idx)
			y += 40
			res := settings.RESOLUTIONS
			names: [len(res)]string
			for rr, i in res do names[i] = fmt.tprintf("%d x %d", rr.w, rr.h)
			cycler({x, y, 520, 28}, "Window size", names[:], &st.res_idx)
			s.display.width = res[st.res_idx].w
			s.display.height = res[st.res_idx].h
			y += 40
			text.draw("Window size applies in windowed mode. Press Apply to change the window.", i32(x), i32(y), 13, TEXT_DIM)
		case 2:
			live |= slider({x, y, r.width - 56, 20}, "Master volume", &s.sound.master, 0, 1, "%.2f")
			y += 40
			live |= slider({x, y, r.width - 56, 20}, "Music", &s.sound.music, 0, 1, "%.2f")
			y += 40
			live |= slider({x, y, r.width - 56, 20}, "Interface sounds", &s.sound.sfx, 0, 1, "%.2f")
			y += 40
			text.draw("Music loops in the background; interface sounds play on hover and click.", i32(x), i32(y), 13, TEXT_DIM)
		case 3:
			live |= controls_tab(st, {x, y, r.width - 56, r.height - 96 - 70})
		}
		if live do act = .Settings_Live
		by := r.y + r.height - 50
		if button({r.x + 24, by, 120, 34}, "Back") {
			st.screen = .Home
			st.rebinding = false
			act = .Settings_Closed
			audio.play(.Close)
		}
		if button({r.x + r.width - 144, by, 120, 34}, "Apply", true, true) {
			act = .Settings_Apply
			audio.play(.Confirm)
		}
		if rl.IsKeyPressed(.ESCAPE) && !st.rebinding {
			st.screen = .Home
			act = .Settings_Closed
			audio.play(.Close)
		}
	}
	return
}

@(private = "file")
bind_name :: proc(b: input.Bind) -> string {
	names := input.NAMES
	return names[b]
}

// The bindings list: grouped rows, click a key to rebind it, conflicts in
// red, reset to defaults at the bottom. Returns true when a bind changed.
@(private = "file")
controls_tab :: proc(st: ^Title_State, r: rl.Rectangle) -> (changed: bool) {
	mouse := rl.GetMousePosition()
	if st.rebinding {
		text.draw(fmt.ctprintf("Press a key for \"%s\"   (Esc cancels)", bind_name(st.rebind)), i32(r.x), i32(r.y), 15, {255, 220, 120, 255})
		if rl.IsKeyPressed(.ESCAPE) {
			st.rebinding = false
		} else {
			k := rl.GetKeyPressed()
			if k != .KEY_NULL && input.rebindable(k) {
				input.keymap[st.rebind] = k
				st.rebinding = false
				changed = true
				audio.play(.Confirm)
			}
		}
	} else {
		text.draw("Click a key to change it. Esc and Enter always cancel and confirm.", i32(r.x), i32(r.y), 13, TEXT_DIM)
	}
	list := rl.Rectangle{r.x, r.y + 24, r.width, r.height - 60}
	if rl.CheckCollisionPointRec(mouse, list) do st.scroll = clamp(st.scroll - rl.GetMouseWheelMove() * 40, 0, 900)
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	y := list.y - st.scroll
	last := input.Group.System
	first := true
	for b in input.Bind {
		g := input.group_of(b)
		if first || g != last {
			text.draw(fmt.ctprintf("%v", g), i32(list.x), i32(y + 6), 13, {220, 170, 90, 255})
			y += 26
			first = false
			last = g
		}
		row := rl.Rectangle{list.x, y, list.width, 24}
		if y + 24 >= list.y && y <= list.y + list.height {
			conflict := input.conflicts(b)
			text.draw(fmt.ctprintf("%s", bind_name(b)), i32(row.x + 8), i32(row.y + 4), 14, TEXT_MAIN)
			kb := rl.Rectangle{row.x + row.width - 170, row.y, 150, 24}
			label := st.rebinding && st.rebind == b ? "..." : input.label(b)
			over := rl.CheckCollisionPointRec(mouse, kb) && rl.CheckCollisionPointRec(mouse, list)
			rl.DrawRectangleRounded(kb, 0.25, 3, over ? HOVER_BG : rl.Color{22, 26, 36, 255})
			if conflict do rl.DrawRectangleRoundedLinesEx(kb, 0.25, 3, 1, {255, 120, 100, 255})
			l := fmt.ctprintf("%s", label)
			lw := f32(text.measure(l, 14))
			text.draw(l, i32(kb.x + (kb.width - lw) * 0.5), i32(kb.y + 4), 14, conflict ? rl.Color{255, 140, 120, 255} : TEXT_MAIN)
			if over && rl.IsMouseButtonPressed(.LEFT) && !st.rebinding {
				st.rebinding = true
				st.rebind = b
				audio.play(.Click)
			}
		}
		y += 26
	}
	rl.EndScissorMode()
	if button({r.x, r.y + r.height - 30, 170, 28}, "Reset to defaults") {
		input.keymap = input.DEFAULTS
		changed = true
	}
	any_conflict := false
	for b in input.Bind do if input.conflicts(b) { any_conflict = true; break }
	if any_conflict do text.draw("Two actions share a key: both will fire.", i32(r.x + 190), i32(r.y + r.height - 24), 13, {255, 140, 120, 255})
	return
}
