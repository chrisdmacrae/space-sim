package ui

// Hover popover: a picture of the entity, a few facts, and the actions that
// make sense for it right now. Stays open while the mouse is over it.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import art "sim:art"
import core "sim:core"
import text "sim:text"

Pop_Action :: enum u8 {
	None,
	Plot_Course,
	Dock,
	Undock,
	Trade,
	Shipyard,
	Look_At,
	Talk,
	Jobs,
	Go,       // fly there on the balanced route without asking
	Orbit_At, // orbit this body at a chosen altitude
	Skim,     // put the scoop out in this nebula
	Skim_Stop,
	Inside,   // open the deck plan of your own ship
}

Pop_Button :: struct {
	label:   string,
	action:  Pop_Action,
	enabled: bool,
	hint:    string, // shown greyed when disabled
}

Popover_View :: struct {
	title:     string,
	subtitle:  string,
	lines:     []string,
	doc:       ^art.Doc,
	doc_state: string,
	doc_px:    f32, // pixels per document unit for the picture
	doc_rot:   f32,
	overrides: art.Overrides,
	// A nebula has no document to draw: it gets a little painted swatch of
	// its own gas in the picture box instead.
	swatch:      bool,
	swatch_cols: [3][4]u8,
	swatch_seed: u64,
	swatch_ring: bool, // shells are drawn hollow, as they are in the sky
	buttons:   []Pop_Button,
	anchor:    rl.Vector2, // screen point the popover hangs off
}

POP_W :: 280

// Returns the action clicked and the popover rectangle (for hover keeping).
popover_draw :: proc(v: Popover_View) -> (action: Pop_Action, rect: rl.Rectangle, hot: bool) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rows := f32(len(v.lines))
	btn_rows := f32((len(v.buttons) + 1) / 2)
	text_h := max(54 + rows * 17, 84)
	ph := text_h + 4 + btn_rows * 30 + 10
	x := v.anchor.x + 18
	y := v.anchor.y - 30
	if x + POP_W > sw - 8 do x = v.anchor.x - POP_W - 18
	y = clamp(y, BAR_H + 8, sh - ph - 8)
	rect = rl.Rectangle{x, y, POP_W, ph}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, rect)
	rl.DrawRectangleRounded(rect, 0.06, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(rect, 0.06, 6, 1, BAR_LINE)
	// Picture.
	pic := rl.Rectangle{x + 12, y + 12, 64, 64}
	rl.DrawRectangleRounded(pic, 0.15, 4, {8, 10, 16, 255})
	if v.doc != nil {
		rl.BeginScissorMode(i32(pic.x), i32(pic.y), i32(pic.width), i32(pic.height))
		art.draw_doc(v.doc, v.doc_state, art.Xform{origin = {pic.x + 32, pic.y + 32}, px = v.doc_px, rot = v.doc_rot}, v.overrides)
		rl.EndScissorMode()
	} else if v.swatch {
		draw_gas_swatch(pic, v.swatch_cols, v.swatch_seed, v.swatch_ring)
	}
	tx := x + 88
	text.draw(fmt.ctprintf("%s", v.title), i32(tx), i32(y + 12), 16, TEXT_MAIN)
	text.draw(fmt.ctprintf("%s", v.subtitle), i32(tx), i32(y + 34), 12, TEXT_DIM)
	ly := y + 54
	for l in v.lines {
		text.draw(fmt.ctprintf("%s", l), i32(tx), i32(ly), 12, TEXT_DIM)
		ly += 17
	}
	by := max(ly, y + 84) + 4
	bw: f32 = (POP_W - 24 - 8) / 2
	for b, i in v.buttons {
		col := i % 2
		row := i / 2
		br := rl.Rectangle{x + 12 + f32(col) * (bw + 8), by + f32(row) * 30, bw, 24}
		over := rl.CheckCollisionPointRec(mouse, br) && b.enabled
		rl.DrawRectangleRounded(br, 0.3, 4, b.enabled ? (over ? HOVER_BG : rl.Color{30, 36, 50, 255}) : rl.Color{20, 24, 34, 255})
		label := fmt.ctprintf("%s", b.label)
		tw := f32(text.measure(label, 13))
		text.draw(label, i32(br.x + (br.width - tw) * 0.5), i32(br.y + 5), 13, b.enabled ? TEXT_MAIN : TEXT_DIM)
		if !b.enabled && b.hint != "" && rl.CheckCollisionPointRec(mouse, br) {
			text.draw(fmt.ctprintf("%s", b.hint), i32(x + 12), i32(rect.y + rect.height - 16), 11, {255, 200, 120, 255})
		}
		if over && rl.IsMouseButtonPressed(.LEFT) do action = b.action
	}
	return
}

// A thumbnail of a cloud: soft puffs in its own three colours, piled up the
// same way the world renderer piles them, hollow when it is a shell.
@(private = "file")
draw_gas_swatch :: proc(pic: rl.Rectangle, cols: [3][4]u8, seed: u64, ring: bool) {
	r := core.rng_make(seed ~ 0x5EED_C10D)
	cx := pic.x + pic.width * 0.5
	cy := pic.y + pic.height * 0.5
	rad := pic.width * 0.46
	rl.BeginScissorMode(i32(pic.x), i32(pic.y), i32(pic.width), i32(pic.height))
	rl.BeginBlendMode(.ADDITIVE)
	for _ in 0 ..< 90 {
		a := f32(core.rng_range(&r, 0, 2 * math.PI))
		u := ring ? f32(core.rng_range(&r, 0.55, 1)) : f32(math.sqrt(core.rng_f64(&r)))
		p := rl.Vector2{cx + math.cos(a) * rad * u, cy + math.sin(a) * rad * u}
		c := cols[u < 0.4 ? 0 : (u < 0.75 ? 1 : 2)]
		if ring do c = cols[u > 0.85 ? 2 : (u > 0.7 ? 1 : 0)]
		pr := rad * f32(core.rng_range(&r, 0.10, 0.30))
		rl.DrawCircleGradient(p, pr, {c[0], c[1], c[2], u8(core.rng_range(&r, 22, 52))}, {c[0], c[1], c[2], 0})
	}
	rl.EndBlendMode()
	rl.EndScissorMode()
}

// A window with nothing to show yet.
empty_panel_draw :: proc(title, message: string, open: ^bool) -> (hot: bool) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{sw - 420 - 8 - right_inset, sh - 120 - 8, 420, 120}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.05, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.05, 6, 1, BAR_LINE)
	text.draw(fmt.ctprintf("%s", title), i32(r.x + 14), i32(r.y + 10), 17, TEXT_MAIN)
	close := rl.Rectangle{r.x + r.width - 34, r.y + 8, 24, 24}
	over := rl.CheckCollisionPointRec(mouse, close)
	rl.DrawRectangleRounded(close, 0.3, 4, over ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(close.x + 7), i32(close.y + 3), 16, TEXT_MAIN)
	if over && rl.IsMouseButtonPressed(.LEFT) do open^ = false
	ly := r.y + 44
	start := 0
	for i in 0 ..= len(message) {
		if i == len(message) || message[i] == '\n' {
			text.draw(fmt.ctprintf("%s", message[start:i]), i32(r.x + 14), i32(ly), 13, TEXT_DIM)
			ly += 18
			start = i + 1
		}
	}
	return
}
