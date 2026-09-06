package ui

// Bottom menu bar: every action the keyboard can do, reachable by mouse,
// with the shortcut shown beside it. Menus return one Action per frame.

import "core:fmt"
import rl "vendor:raylib"
import core "sim:core"
import text "sim:text"
import input "sim:input"
import audio "sim:audio"

Action :: enum u8 {
	None,
	Throttle_Full,
	Cut_Engine,
	Hold_Prograde,
	Hold_Retrograde,
	Hold_Release,
	Node_Add,
	Node_Remove,
	Warp_To_Burn,
	Execute_Burn,
	Plan_Course,
	Go,
	Orbit_At,
	Skim_Nebula,
	Toggle_Auto_Dock,
	Fly_To_Point,
	Cancel_Autopilot,
	Dock,
	Undock,
	Pause,
	Warp_Down,
	Warp_Up,
	Tick_1s,
	Tick_1m,
	Tick_10m,
	Tick_30m,
	Tick_1h,
	Tick_1d,
	Tick_1mo,
	Tick_1y,
	Follow,
	Frame_System,
	Cycle_Focus,
	Toggle_Orbits,
	Toggle_Labels,
	Toggle_SOI,
	Toggle_Belts,
	Toggle_Predict,
	Toggle_Routes,
	Rotate_Reset,
	Toggle_Heading_Lock,
	Regen,
	Seed_Next,
	Seed_Prev,
	Toggle_Debug,
	Market_Window,
	Routes_Window,
	Shipyard_Window,
	Jobs_Window,
	Toggle_Auto_Time,
	Skip_Burn,
	Skip_Arrival,
	Galaxy_Map,
	Ship_Interior,
	Save_Game,
	Load_Game,
	Save_Slots,
	Load_Slots,
	Settings,
	Main_Menu,
}

Item :: struct {
	label:     string,
	bind:      input.Bind, // its key, shown beside the label (from the live keymap)
	has_bind:  bool,
	action:    Action,
	separator: bool,
}

I :: proc "contextless" (label: string, action: Action, bind: input.Bind) -> Item { return Item{label = label, action = action, bind = bind, has_bind = true} }
P :: proc "contextless" (label: string, action: Action) -> Item { return Item{label = label, action = action} }
SEP :: Item{separator = true}

Menu :: struct {
	title: string,
	items: []Item,
}

ORDER_ITEMS := [?]Item {
	I("Go to hovered", .Go, .Plan_Course),
	P("Choose a route to hovered...", .Plan_Course),
	P("Fly to a point", .Fly_To_Point),
	P("Orbit here at an altitude...", .Orbit_At),
	P("Skim the nebula / stop skimming", .Skim_Nebula),
	I("Cancel order", .Cancel_Autopilot, .Plan_Course),
	SEP,
	I("Dock", .Dock, .Dock),
	I("Undock", .Undock, .Undock),
	P("Dock automatically when in range", .Toggle_Auto_Dock),
	SEP,
	P("Automatic time while flying", .Toggle_Auto_Time),
	P("Skip to next burn", .Skip_Burn),
	P("Skip to arrival", .Skip_Arrival),
}
MANUAL_ITEMS := [?]Item {
	P("Drag the Pe or Ap marker to raise or lower the orbit", .None),
	P("RCS nudge: Shift + arrows (tiny burns)", .None),
	SEP,
	I("Full throttle", .Throttle_Full, .Throttle_Full),
	I("Cut engine", .Cut_Engine, .Cut_Engine),
	I("Hold prograde", .Hold_Prograde, .Hold_Prograde),
	I("Hold retrograde", .Hold_Retrograde, .Hold_Retrograde),
	P("Release hold", .Hold_Release),
	I("Turn left (hold)", .None, .Turn_Left),
	I("Turn right (hold)", .None, .Turn_Right),
	I("Throttle up (hold)", .None, .Throttle_Up),
	I("Throttle down (hold)", .None, .Throttle_Down),
	SEP,
	I("Add maneuver node", .Node_Add, .Node_Add),
	I("Remove selected node", .Node_Remove, .Node_Remove),
	I("Warp to burn", .Warp_To_Burn, .Warp_To_Burn),
	I("Execute burn", .Execute_Burn, .Execute_Burn),
}
TIME_ITEMS := [?]Item {
	I("Pause / resume", .Pause, .Pause),
	I("Warp slower", .Warp_Down, .Warp_Down),
	I("Warp faster", .Warp_Up, .Warp_Up),
	SEP,
	P("1 second per second", .Tick_1s),
	P("1 minute per second", .Tick_1m),
	P("10 minutes per second", .Tick_10m),
	P("30 minutes per second", .Tick_30m),
	P("1 hour per second", .Tick_1h),
	P("1 day per second", .Tick_1d),
	P("1 month per second", .Tick_1mo),
	P("1 year per second", .Tick_1y),
}
VIEW_ITEMS := [?]Item {
	I("Follow ship", .Follow, .Follow_Ship),
	I("Frame whole system", .Frame_System, .Frame_System),
	I("Cycle focus", .Cycle_Focus, .Cycle_Focus),
	SEP,
	P("Orbits", .Toggle_Orbits),
	P("Labels", .Toggle_Labels),
	P("Spheres of influence", .Toggle_SOI),
	P("Belts", .Toggle_Belts),
	P("Predicted path", .Toggle_Predict),
	P("Trade routes", .Toggle_Routes),
	SEP,
	I("Rotate view left (hold)", .None, .Rotate_Left),
	I("Rotate view right (hold)", .None, .Rotate_Right),
	I("Reset view rotation", .Rotate_Reset, .Rotate_Reset),
	I("Lock view to ship heading", .Toggle_Heading_Lock, .Heading_Lock),
	SEP,
	I("Inside the ship (crew)", .Ship_Interior, .Ship_Interior),
	I("Galaxy map", .Galaxy_Map, .Galaxy_Map),
}
TRADE_ITEMS := [?]Item {
	I("Market", .Market_Window, .Market),
	P("Known trade routes", .Routes_Window),
	I("Shipyard", .Shipyard_Window, .Shipyard),
	P("Your contracts", .Jobs_Window),
}
SYSTEM_ITEMS := [?]Item {
	P("Save game...", .Save_Slots),
	P("Load game...", .Load_Slots),
	I("Quick save", .Save_Game, .Quick_Save),
	I("Quick load", .Load_Game, .Quick_Load),
	SEP,
	I("Regenerate galaxy", .Regen, .Regenerate),
	P("Next seed", .Seed_Next),
	P("Previous seed", .Seed_Prev),
	SEP,
	I("Debug panel", .Toggle_Debug, .Debug_Panel),
	SEP,
	P("Settings", .Settings),
	P("Main menu", .Main_Menu),
}

MENUS := [?]Menu {
	{"Orders", ORDER_ITEMS[:]},
	{"View", VIEW_ITEMS[:]},
	{"Trade", TRADE_ITEMS[:]},
	{"System", SYSTEM_ITEMS[:]},
	{"Manual", MANUAL_ITEMS[:]},
}

BAR_H     :: 34
ITEM_H    :: 26
MENU_W    :: 250
TITLE_PAD :: 18

BAR_BG    :: rl.Color{14, 18, 26, 240}
BAR_LINE  :: rl.Color{60, 70, 90, 255}
MENU_BG   :: rl.Color{18, 22, 32, 250}
HOVER_BG  :: rl.Color{40, 50, 70, 255}
TEXT_MAIN :: rl.Color{220, 226, 240, 255}
TEXT_DIM  :: rl.Color{130, 140, 160, 255}
ACCENT    :: rl.Color{232, 122, 58, 255}

Menubar :: struct {
	open:      int,  // open menu index, -1 for none
	tick_open: bool, // the time-step list is dropped down
}

// State the bar displays.
Bar_Info :: struct {
	clock:    ^core.Clock,
	follow:   bool,
	status:   string, // right-hand status text (autopilot etc.)
	contacts: ^bool,  // contacts panel open/closed
	heading_lock: bool, // the view turns with the ship
	auto_time:    bool, // the clock runs itself while the autopilot flies
	auto_dock:    bool, // dock by itself when in range of a station
	skimming:     bool, // the scoop is out in a nebula
	flying:       bool, // an autopilot plan is active (skips apply)
	ceiling:      ^int, // auto time's fastest step; the step control edits this while flying on auto
	disabled: bit_set[Action], // greyed out: not applicable right now
}

checked :: proc(a: Action, info: Bar_Info) -> (is_toggle, on: bool) {
	switch a {
	case .Toggle_Orbits:  return true, core.debug.show_orbits
	case .Toggle_Labels:  return true, core.debug.show_labels
	case .Toggle_SOI:     return true, core.debug.show_soi
	case .Toggle_Belts:   return true, core.debug.show_belts
	case .Toggle_Predict: return true, core.debug.show_predict
	case .Toggle_Routes:  return true, core.debug.show_routes
	case .Follow:         return true, info.follow
	case .Toggle_Heading_Lock: return true, info.heading_lock
	case .Toggle_Auto_Time: return true, info.auto_time
	case .Toggle_Auto_Dock: return true, info.auto_dock
	case .Skim_Nebula:    return true, info.skimming
	case .Pause:          return true, info.clock.paused
	case .None, .Throttle_Full, .Cut_Engine, .Hold_Prograde, .Hold_Retrograde, .Hold_Release,
	     .Node_Add, .Node_Remove, .Warp_To_Burn, .Execute_Burn, .Plan_Course, .Fly_To_Point, .Cancel_Autopilot, .Dock, .Undock,
	     .Warp_Down, .Warp_Up, .Tick_1s, .Tick_1m, .Tick_10m, .Tick_30m, .Tick_1h, .Tick_1d, .Tick_1mo, .Tick_1y,
	     .Frame_System, .Cycle_Focus, .Regen, .Seed_Next, .Seed_Prev, .Toggle_Debug, .Market_Window, .Routes_Window, .Shipyard_Window, .Galaxy_Map, .Ship_Interior, .Save_Game, .Load_Game, .Save_Slots, .Load_Slots, .Settings, .Main_Menu, .Rotate_Reset, .Jobs_Window, .Skip_Burn, .Skip_Arrival, .Go, .Orbit_At:
	}
	return false, false
}

// Draws the bar and any open menu. Returns the action clicked this frame and
// whether the mouse is over bar or menu.
menubar_draw :: proc(mb: ^Menubar, info: Bar_Info) -> (action: Action, hot: bool) {
	if mb.open != -2 && mb.open < -1 do mb.open = -1
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	mouse := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(.LEFT)
	bar := rl.Rectangle{0, 0, sw, BAR_H}
	rl.DrawRectangleRec(bar, BAR_BG)
	rl.DrawLineEx({0, bar.y + BAR_H}, {sw, bar.y + BAR_H}, 1, BAR_LINE)
	_ = sh
	hot = rl.CheckCollisionPointRec(mouse, bar)

	// ---- titles
	x: f32 = 8
	title_rects: [len(MENUS)]rl.Rectangle
	for m, i in MENUS {
		ct := fmt.ctprintf("%s", m.title)
		w := f32(text.measure(ct, 16)) + TITLE_PAD * 2
		r := rl.Rectangle{x, bar.y + 1, w, BAR_H - 1}
		title_rects[i] = r
		over := rl.CheckCollisionPointRec(mouse, r)
		if over && mb.open >= 0 && mb.open != i do mb.open = i // slide between open menus
		if over && clicked {
			mb.open = mb.open == i ? -1 : i
			audio.play(mb.open >= 0 ? .Open : .Close)
		}
		if mb.open == i || over do rl.DrawRectangleRec(r, mb.open == i ? HOVER_BG : rl.Color{28, 34, 48, 255})
		text.draw(ct, i32(x + TITLE_PAD), i32(bar.y + 8), 16, TEXT_MAIN)
		x += w + 2
	}

	// ---- right side: clock, warp controls, status
	rx := sw - 12
	clock_s := fmt.ctprintf("%s", core.clock_format(info.clock.t))
	cw := f32(text.measure(clock_s, 16))
	rx -= cw
	text.draw(clock_s, i32(rx), i32(bar.y + 8), 16, TEXT_MAIN)
	rx -= 14
	// [-] warp [+] pause
	btn :: proc(r: rl.Rectangle, label: cstring, mouse: rl.Vector2, clicked: bool, on: bool = false) -> bool {
		over := rl.CheckCollisionPointRec(mouse, r)
		rl.DrawRectangleRounded(r, 0.25, 4, on ? ACCENT : (over ? HOVER_BG : rl.Color{30, 36, 50, 255}))
		w := f32(text.measure(label, 14))
		text.draw(label, i32(r.x + (r.width - w) * 0.5), i32(r.y + 4), 14, on ? rl.Color{20, 20, 20, 255} : TEXT_MAIN)
		return over && clicked
	}
	pr := rl.Rectangle{rx - 60, bar.y + 5, 60, BAR_H - 10}
	if btn(pr, info.clock.paused ? "resume" : "pause", mouse, clicked, info.clock.paused) do action = .Pause
	rx -= 68
	auto_flying := info.auto_time && info.flying && info.ceiling != nil
	plus := rl.Rectangle{rx - 26, bar.y + 5, 26, BAR_H - 10}
	if btn(plus, "+", mouse, clicked) {
		if auto_flying do info.ceiling^ = min(info.ceiling^ + 1, len(core.WARP_LEVELS) - 1)
		else do action = .Warp_Up
	}
	rx -= 30
	// The step itself is a button: click for the full list. On auto it shows the ceiling.
	warp_s := auto_flying ? fmt.ctprintf("auto <= %s / s", core.WARP_LABELS[info.ceiling^]) : fmt.ctprintf("%s / s", core.clock_warp_label(info.clock))
	ww := f32(text.measure(warp_s, 15)) + 16
	rx -= ww
	tick_r := rl.Rectangle{rx, bar.y + 5, ww, BAR_H - 10}
	{
		over := rl.CheckCollisionPointRec(mouse, tick_r)
		rl.DrawRectangleRounded(tick_r, 0.25, 4, over || mb.tick_open ? HOVER_BG : rl.Color{30, 36, 50, 255})
		text.draw(warp_s, i32(tick_r.x + 8), i32(tick_r.y + 4), 15, ACCENT)
		if over && clicked do mb.tick_open = !mb.tick_open
	}
	rx -= 6
	minus := rl.Rectangle{rx - 26, bar.y + 5, 26, BAR_H - 10}
	if btn(minus, "-", mouse, clicked) {
		if auto_flying do info.ceiling^ = max(info.ceiling^ - 1, 0)
		else do action = .Warp_Down
	}
	rx -= 40
	if info.contacts != nil {
		cr := rl.Rectangle{rx - 78, bar.y + 5, 78, BAR_H - 10}
		if btn(cr, "Contacts", mouse, clicked, info.contacts^) do info.contacts^ = !info.contacts^
		rx -= 90
	}
	// Time runs itself while flying; the skips jump to the next burn or the arrival.
	{
		ar := rl.Rectangle{rx - 92, bar.y + 5, 92, BAR_H - 10}
		if btn(ar, "> arrival", mouse, clicked && info.flying) do action = .Skip_Arrival
		rx -= 98
		br := rl.Rectangle{rx - 76, bar.y + 5, 76, BAR_H - 10}
		if btn(br, "> burn", mouse, clicked && info.flying) do action = .Skip_Burn
		rx -= 82
		au := rl.Rectangle{rx - 56, bar.y + 5, 56, BAR_H - 10}
		if btn(au, "auto", mouse, clicked, info.auto_time) do action = .Toggle_Auto_Time
		rx -= 68
	}
	rx -= 28
	if info.status != "" {
		st := fmt.ctprintf("%s", info.status)
		stw := f32(text.measure(st, 14))
		text.draw(st, i32(rx - stw), i32(bar.y + 10), 14, TEXT_DIM)
	}

	// ---- time-step list under its button
	if mb.tick_open {
		labels := core.WARP_LABELS
		lw: f32 = 190
		lh := f32(len(labels)) * ITEM_H + 8
		lr := rl.Rectangle{tick_r.x + tick_r.width - lw, bar.y + BAR_H, lw, lh}
		rl.DrawRectangleRounded(lr, 0.06, 4, MENU_BG)
		rl.DrawRectangleRoundedLinesEx(lr, 0.06, 4, 1, BAR_LINE)
		hot = hot || rl.CheckCollisionPointRec(mouse, lr) || rl.CheckCollisionPointRec(mouse, tick_r)
		y := lr.y + 4
		for l, i in labels {
			ir := rl.Rectangle{lr.x + 4, y, lr.width - 8, ITEM_H}
			over := rl.CheckCollisionPointRec(mouse, ir)
			on := auto_flying ? i == info.ceiling^ : i == info.clock.warp_index
			if over || on do rl.DrawRectangleRounded(ir, 0.2, 3, over ? HOVER_BG : rl.Color{28, 34, 48, 255})
			text.draw(fmt.ctprintf("%s per second", l), i32(ir.x + 10), i32(ir.y + 5), 15, on ? ACCENT : TEXT_MAIN)
			if over && clicked {
				if auto_flying do info.ceiling^ = i
				else do core.clock_set_index(info.clock, i)
				mb.tick_open = false
			}
			y += ITEM_H
		}
		if clicked && !rl.CheckCollisionPointRec(mouse, lr) && !rl.CheckCollisionPointRec(mouse, tick_r) do mb.tick_open = false
	}

	// ---- open menu
	if mb.open >= 0 {
		m := MENUS[mb.open]
		h := f32(0)
		for it in m.items do h += it.separator ? 8 : ITEM_H
		r := rl.Rectangle{title_rects[mb.open].x, bar.y + BAR_H + 2, MENU_W, h + 6}
		rl.DrawRectangleRounded(r, 0.06, 4, MENU_BG)
		rl.DrawRectangleRoundedLinesEx(r, 0.06, 4, 1, BAR_LINE)
		if rl.CheckCollisionPointRec(mouse, r) do hot = true
		y := r.y + 3
		for it in m.items {
			if it.separator {
				rl.DrawLineEx({r.x + 10, y + 4}, {r.x + r.width - 10, y + 4}, 1, BAR_LINE)
				y += 8
				continue
			}
			ir := rl.Rectangle{r.x + 3, y, r.width - 6, ITEM_H}
			usable := it.action != .None && it.action not_in info.disabled
			over := rl.CheckCollisionPointRec(mouse, ir) && usable
			if over do rl.DrawRectangleRounded(ir, 0.2, 3, HOVER_BG)
			is_toggle, on := checked(it.action, info)
			label_x := ir.x + 12
			if is_toggle {
				rl.DrawRectangleLinesEx({ir.x + 10, ir.y + 7, 12, 12}, 1, TEXT_DIM)
				if on do rl.DrawRectangleRec({ir.x + 13, ir.y + 10, 6, 6}, ACCENT)
				label_x += 20
			}
			text.draw(fmt.ctprintf("%s", it.label), i32(label_x), i32(ir.y + 5), 15, usable ? TEXT_MAIN : TEXT_DIM)
			if it.has_bind {
				k := fmt.ctprintf("%s", input.label(it.bind))
				kw := f32(text.measure(k, 13))
				text.draw(k, i32(ir.x + ir.width - 10 - kw), i32(ir.y + 6), 13, TEXT_DIM)
			}
			if over && clicked {
				action = it.action
				mb.open = -1
				audio.play(.Click)
			}
			y += ITEM_H
		}
		// Click anywhere else closes.
		if clicked && !hot do mb.open = -1
	}
	return
}
