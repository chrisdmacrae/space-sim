package ui

// Contacts: a tree of everything in the system. Planets hold their moons,
// stations and ships; moons hold theirs; stations hold docked ships. Stray
// objects (heliocentric stations and ships) sit in their own group. Click
// expands or collapses; double-click focuses; the wheel scrolls.

import "core:fmt"
import rl "vendor:raylib"
import core "sim:core"
import text "sim:text"

Contact_Kind :: enum u8 {
	Group,
	Body,
	Station,
	Ship,
	Npc,
}

// One row of the pre-ordered tree the game builds each frame.
Contact :: struct {
	kind:         Contact_Kind,
	index:        int,
	name:         string,
	detail:       string, // short right-hand text (kind, distance)
	depth:        int,
	has_children: bool,
}

Contacts :: struct {
	open:       bool,
	expanded:   map[u64]bool,
	scroll:     f32,
	last_key:   u64,
	last_click: f64,
}

CONTACTS_W :: 330
CONTACT_ROW :: 22

// Horizontal room the other bottom-right panels leave for the contacts
// panel while it is open. Set by contacts_draw each frame.
right_inset: f32

contacts_destroy :: proc(c: ^Contacts) {
	delete(c.expanded)
}

@(private = "file")
key_of :: proc(c: Contact) -> u64 {
	return u64(c.kind) << 48 | u64(c.index)
}

// Draws the panel. Returns the contact to focus (double-click), if any.
contacts_draw :: proc(c: ^Contacts, rows: []Contact) -> (focus: Contact, did: bool, hot: bool) {
	right_inset = c.open ? CONTACTS_W + 16 : 0
	if !c.open do return
	if c.expanded == nil do c.expanded = make(map[u64]bool)
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	ph := min(sh * 0.6, f32(80 + len(rows) * CONTACT_ROW))
	r := rl.Rectangle{sw - CONTACTS_W - 8, sh - ph - 8, CONTACTS_W, ph}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.04, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.04, 6, 1, BAR_LINE)
	text.draw("Contacts", i32(r.x + 14), i32(r.y + 10), 17, TEXT_MAIN)
	text.draw("click expands, double-click focuses", i32(r.x + 110), i32(r.y + 13), 12, TEXT_DIM)
	close := rl.Rectangle{r.x + r.width - 34, r.y + 8, 24, 24}
	over_close := rl.CheckCollisionPointRec(mouse, close)
	rl.DrawRectangleRounded(close, 0.3, 4, over_close ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(close.x + 7), i32(close.y + 3), 16, TEXT_MAIN)
	if over_close && rl.IsMouseButtonPressed(.LEFT) do c.open = false

	// Visible rows: those whose ancestors are all expanded.
	list := rl.Rectangle{r.x + 6, r.y + 40, r.width - 12, r.height - 48}
	visible := make([dynamic]int, context.temp_allocator)
	hidden_below := -1 // depth of a collapsed ancestor, or -1
	for row, i in rows {
		if hidden_below >= 0 && row.depth > hidden_below do continue
		hidden_below = -1
		append(&visible, i)
		if row.has_children && !c.expanded[key_of(row)] do hidden_below = row.depth
	}
	content_h := f32(len(visible)) * CONTACT_ROW
	if hot {
		c.scroll -= rl.GetMouseWheelMove() * CONTACT_ROW * 2
	}
	c.scroll = clamp(c.scroll, 0, max(content_h - list.height, 0))

	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	y := list.y - c.scroll
	now := rl.GetTime()
	for vi in visible {
		row := rows[vi]
		rr := rl.Rectangle{list.x, y, list.width, CONTACT_ROW}
		if y + CONTACT_ROW >= list.y && y <= list.y + list.height {
			over := rl.CheckCollisionPointRec(mouse, rr) && rl.CheckCollisionPointRec(mouse, list)
			if over do rl.DrawRectangleRounded(rr, 0.2, 3, HOVER_BG)
			x := rr.x + 8 + f32(row.depth) * 16
			if row.has_children {
				text.draw(c.expanded[key_of(row)] ? "v" : ">", i32(x), i32(y + 4), 12, TEXT_DIM)
			}
			col := TEXT_MAIN
			#partial switch row.kind {
			case .Group: col = {220, 170, 90, 255}
			case .Station: col = {200, 210, 230, 255}
			case .Ship: col = {150, 230, 170, 255}
			case .Npc: col = {200, 190, 150, 255}
			}
			text.draw(fmt.ctprintf("%s", row.name), i32(x + 14), i32(y + 3), 14, col)
			if row.detail != "" {
				d := fmt.ctprintf("%s", row.detail)
				dw := f32(text.measure(d, 12))
				text.draw(d, i32(rr.x + rr.width - 8 - dw), i32(y + 5), 12, TEXT_DIM)
			}
			if over && rl.IsMouseButtonPressed(.LEFT) {
				k := key_of(row)
				if k == c.last_key && now - c.last_click < 0.4 {
					if row.kind != .Group {
						focus = row
						did = true
					}
					c.last_click = 0
				} else {
					if row.has_children do c.expanded[k] = !c.expanded[k]
					c.last_key = k
					c.last_click = now
				}
			}
		}
		y += CONTACT_ROW
	}
	rl.EndScissorMode()
	if content_h > list.height {
		// Scrollbar.
		frac := list.height / content_h
		bar_h := max(list.height * frac, 20)
		bar_y := list.y + (list.height - bar_h) * (c.scroll / max(content_h - list.height, 1))
		rl.DrawRectangleRounded({list.x + list.width - 4, bar_y, 4, bar_h}, 0.5, 3, {90, 100, 130, 255})
	}
	_ = core.SECONDS_PER_DAY
	return
}
