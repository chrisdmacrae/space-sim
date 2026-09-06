package ui

// Collapsible debug panel in the top-right corner. Collapsed, it is a square
// button showing the fastart glyph; open, it shows clock, camera, assets and
// the tuning knobs (docs/DESIGN.md §11).

import "core:c"
import "core:fmt"
import rl "vendor:raylib"
import art "sim:art"
import core "sim:core"
import gen "sim:gen"
import text "sim:text"

Debug_Panel :: struct {
	open:   bool,
	styled: bool,
}

// Read-only view of the world the panel reports on, plus pointers it may edit.
Debug_Info :: struct {
	clock:     ^core.Clock,
	cam_zoom:  f64,
	cam_pos:   [2]f64,
	follow:    ^bool,
	lib:       ^art.Library,
	icon:      ^art.Doc,
	ship_mode: string,
	sys:       ^gen.System,
	seed:      ^u64,   // edited by the seed buttons
	regen:     ^bool,  // set when the seed changes
	focus:     string, // name of the focused thing
}

BUTTON    :: 36
MARGIN    :: 8
PANEL_W   :: 300
ROW       :: 24
PAD       :: 10

// Draws the panel. Returns true when the mouse is over it, so the caller can
// keep world input (wheel, drag) from leaking through.
debug_panel_draw :: proc(p: ^Debug_Panel, info: Debug_Info) -> (hot: bool) {
	if !p.styled do apply_style(p)

	sw := f32(rl.GetScreenWidth())
	mouse := rl.GetMousePosition()
	if !p.open do return
	panel := rl.Rectangle{sw - MARGIN - PANEL_W, BAR_H + MARGIN, PANEL_W, 0}
	panel.height = panel_height(info)
	rl.DrawRectangleRounded(panel, 0.04, 6, {14, 18, 26, 235})
	rl.DrawRectangleRoundedLinesEx(panel, 0.04, 6, 1, {60, 70, 90, 255})
	hot = rl.CheckCollisionPointRec(mouse, panel)
	// Close button where the icon used to be.
	btn := rl.Rectangle{panel.x + panel.width - MARGIN - 24, panel.y + MARGIN, 24, 24}
	over := rl.CheckCollisionPointRec(mouse, btn)
	rl.DrawRectangleRounded(btn, 0.3, 4, over ? rl.Color{50, 60, 80, 255} : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(btn.x + 7), i32(btn.y + 3), 16, TEXT_MAIN)
	if over && rl.IsMouseButtonPressed(.LEFT) do p.open = false
	_ = info.icon

	x := panel.x + PAD
	y := panel.y + PAD
	w := panel.width - PAD * 2
	label :: proc(x, y, w: f32, text: string) {
		rl.GuiLabel({x, y, w, ROW}, fmt.ctprintf("%s", text))
	}
	section :: proc(x: ^f32, y: ^f32, w: f32, text: string) {
		rl.GuiLine({x^, y^, w, ROW}, fmt.ctprintf("%s", text))
		y^ += ROW
	}

	label(x, y, w - BUTTON - PAD, "DEBUG")
	y += ROW + 4

	// --- system
	section(&x, &y, w, "system")
	label(x, y, w, fmt.tprintf("%s   %s   %.2f Msol", info.sys.name, gen.star_describe(info.sys.star), info.sys.star.mass))
	y += ROW
	moons := 0
	for b in info.sys.bodies do if b.is_moon do moons += 1
	label(x, y, w, fmt.tprintf("%d planets  %d moons  %d belts  %d stations", len(info.sys.bodies) - 1 - moons, moons, len(info.sys.belts), len(info.sys.stations)))
	y += ROW
	label(x, y, 110, fmt.tprintf("seed %d", info.seed^))
	if rl.GuiButton({x + 120, y, 40, ROW - 2}, "<") { info.seed^ -= 1; info.regen^ = true }
	if rl.GuiButton({x + 164, y, 40, ROW - 2}, ">") { info.seed^ += 1; info.regen^ = true }
	if rl.GuiButton({x + 208, y, 70, ROW - 2}, "regen") do info.regen^ = true
	y += ROW
	toggle(x, y, "orbits", &core.debug.show_orbits)
	toggle(x + 70, y, "labels", &core.debug.show_labels)
	toggle(x + 140, y, "SOI", &core.debug.show_soi)
	toggle(x + 195, y, "belts", &core.debug.show_belts)
	y += ROW
	toggle(x, y, "predicted path", &core.debug.show_predict)
	y += ROW + 2

	// --- camera
	section(&x, &y, w, "camera")
	label(x, y, w, fmt.tprintf("zoom %.4f px/unit   target %.0f, %.0f", info.cam_zoom, info.cam_pos.x, info.cam_pos.y))
	y += ROW
	label(x, y, w, fmt.tprintf("focus %s", info.focus))
	y += ROW
	toggle(x, y, "follow focus", info.follow)
	y += ROW + 2

	// --- ship
	section(&x, &y, w, "ship")
	label(x, y, w, fmt.tprintf("state %s", info.ship_mode))
	y += ROW + 2

	// --- assets
	section(&x, &y, w, "assets (hot reload)")
	ok, failed, reloads := 0, 0, 0
	for name in info.lib.order {
		e := info.lib.entries[name]
		if e.ok do ok += 1
		else do failed += 1
		reloads += e.reloads - 1
	}
	label(x, y, w, fmt.tprintf("%d loaded  %d failed  %d reloads", ok, failed, reloads))
	y += ROW
	for name in info.lib.order {
		e := info.lib.entries[name]
		if e.ok do continue
		label(x, y, w, fmt.tprintf("FAILED %s", e.name))
		y += ROW - 4
	}
	if rl.GuiButton({x, y + 2, 100, ROW - 2}, "reload all") do art.library_reload_all(info.lib)
	if info.lib.message != "" && art.library_message_age(info.lib) < 4 {
		label(x + 110, y, w - 110, info.lib.message)
	}
	y += ROW + 4

	// --- tuning
	section(&x, &y, w, "tuning")
	slider(&y, x, w, "ship icon px", &core.tuning.ship_min_px, 0, 40)
	slider(&y, x, w, "body min px", &core.tuning.body_min_px, 0, 40)
	slider(&y, x, w, "star glow", &core.tuning.star_glow_scale, 0, 3)
	slider(&y, x, w, "label orbit px", &core.tuning.label_min_orbit_px, 0, 300)
	slider(&y, x, w, "station icon px", &core.tuning.station_min_px, 0, 40)
	slider(&y, x, w, "hand burn warp cap", &core.tuning.warp_max_thrusting, 1, 50)
	slider(&y, x, w, "autoburn warp cap", &core.tuning.warp_max_autoburn, 1, 1000)
	slider(&y, x, w, "auto time: real s per leg", &core.tuning.auto_leg_seconds, 2, 60)
	slider(&y, x, w, "price curve k", &core.tuning.price_curve_k, 1.5, 10)
	slider(&y, x, w, "k_time", &core.tuning.k_time, 0, 5)
	slider(&y, x, w, "skim pass, hours", &core.tuning.skim_cycle_hours, 0.25, 12)
	slider(&y, x, w, "dust: hours to kill a hull", &core.tuning.dust_hull_hours, 10, 600)

	label(x, y, w, fmt.tprintf("%d fps", rl.GetFPS()))
	return
}

@(private = "file")
slider :: proc(y: ^f32, x, w: f32, name: string, v: ^f32, lo, hi: f32) {
	rl.GuiLabel({x, y^, 130, ROW - 6}, fmt.ctprintf("%s", name))
	rl.GuiSlider({x + 130, y^ + 2, w - 130 - 50, ROW - 10}, "", fmt.ctprintf("%.2f", v^), v, lo, hi)
	y^ += ROW - 2
}

// Small checkbox drawn by hand (raygui's does not show its state with our style).
@(private = "file")
toggle :: proc(x, y: f32, name: string, v: ^bool) {
	box := rl.Rectangle{x, y + 4, 14, 14}
	rl.DrawRectangleLinesEx(box, 1, {130, 140, 160, 255})
	if v^ do rl.DrawRectangleRec({x + 3, y + 7, 8, 8}, {232, 122, 58, 255})
	rl.GuiLabel({x + 20, y, 200, ROW - 4}, fmt.ctprintf("%s", name))
	hit := rl.Rectangle{x, y, 20 + f32(len(name)) * 8, ROW - 4}
	if rl.CheckCollisionPointRec(rl.GetMousePosition(), hit) && rl.IsMouseButtonPressed(.LEFT) do v^ = !v^
}

@(private = "file")
panel_height :: proc(info: Debug_Info) -> f32 {
	h: f32 = PAD + ROW + 4
	h += ROW + ROW * 5 + 2                  // system
	h += ROW + ROW * 3 + 2                  // camera
	h += ROW + ROW + 2                      // ship
	failed := 0
	for name in info.lib.order do if !info.lib.entries[name].ok do failed += 1
	h += ROW + ROW + f32(failed) * (ROW - 4) + ROW + 4 // assets
	h += ROW + 9 * (ROW - 2)                // tuning
	h += ROW + PAD                          // fps
	return h
}

@(private = "file")
apply_style :: proc(p: ^Debug_Panel) {
	p.styled = true
	set :: proc(ctl: rl.GuiControl, prop: c.int, v: u32) {
		rl.GuiSetStyle(ctl, prop, c.int(v))
	}
	set(.DEFAULT, c.int(rl.GuiDefaultProperty.TEXT_SIZE), 13)
	set(.DEFAULT, c.int(rl.GuiDefaultProperty.BACKGROUND_COLOR), 0x0E121Aff)
	set(.DEFAULT, c.int(rl.GuiDefaultProperty.LINE_COLOR), 0x3C4658ff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.TEXT_COLOR_NORMAL), 0xD8DEE9ff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.TEXT_COLOR_FOCUSED), 0xFFFFFFff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.TEXT_COLOR_PRESSED), 0xFFFFFFff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.BASE_COLOR_NORMAL), 0x1E2432ff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.BASE_COLOR_FOCUSED), 0x323C50ff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.BASE_COLOR_PRESSED), 0xE87A3Aff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.BORDER_COLOR_NORMAL), 0x5A6482ff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.BORDER_COLOR_FOCUSED), 0x7ACCF0ff)
	set(.DEFAULT, c.int(rl.GuiControlProperty.BORDER_COLOR_PRESSED), 0xE87A3Aff)
}
