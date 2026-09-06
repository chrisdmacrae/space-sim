package ui

// Inside the ship: a top-down deck plan with the crew moving about it, and
// a roster down the right-hand side. Click a crew member (on the deck or on
// their card), then a room, to post them there; or use the buttons on the
// card. Docked at a station, the panel also lists who is looking for a
// berth and lets crew go ashore. Covers the whole window, like the map.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import art "sim:art"
import crew "sim:crew"
import render "sim:render"
import text "sim:text"
import audio "sim:audio"
import people "sim:people"

Ship_View_State :: struct {
	selected: int, // member index, -1 for none
	hover:    int, // member under the mouse this frame
	scroll:   f32, // roster panel
}

Ship_View_Action :: enum u8 {
	None,
	Close,
	Assign,  // member, post
	Hire,    // candidate
	Dismiss, // member
}

Ship_View :: struct {
	lib:        ^art.Library,
	roster:     ^crew.Roster,
	deck:       ^crew.Deck,
	avatars:    []render.Avatar, // one per member
	ship_name:  string,
	bunks:      int,
	hull:       f64, // 0..1
	propellant: f64, // 0..1
	cargo_frac: f64, // 0..1 of the hold
	effects:    crew.Effects,
	hazard:     string, // "" when the hull is safe
	docked_at:  string, // station name while docked there, else ""
	candidates: []crew.Candidate,
	credits:    f64,
}

SV_PANEL_W  :: 400
SV_CARD_H   :: 150
SV_BG       :: rl.Color{8, 10, 16, 255}
SV_HULL     :: rl.Color{34, 38, 48, 255}
SV_HULL_EDGE :: rl.Color{120, 130, 150, 255}
SV_FLOOR    :: rl.Color{26, 30, 40, 255}
SV_CORRIDOR :: rl.Color{38, 42, 54, 255}
SV_WALL     :: rl.Color{92, 102, 124, 255}
SV_DOOR     :: rl.Color{160, 172, 196, 255}
SV_GOOD     :: rl.Color{150, 230, 170, 255}
SV_WARN     :: rl.Color{240, 182, 92, 255}
SV_BAD      :: rl.Color{242, 112, 106, 255}
SV_CYAN     :: rl.Color{120, 198, 232, 255}

@(private = "file")
ROOM_TINT := [crew.Room_Kind]rl.Color {
	.Bridge = {28, 36, 52, 255}, .Comms = {30, 34, 50, 255}, .Engineering = {40, 30, 30, 255}, .Quarters = {32, 30, 40, 255},
	.Galley = {36, 32, 28, 255}, .Hold = {30, 30, 30, 255}, .Airlock = {34, 34, 28, 255}, .Pods = {26, 34, 44, 255},
}

@(private = "file")
Plan :: struct {
	origin: rl.Vector2, // screen point of deck (0,0)
	s:      f32,        // px per deck unit
}

@(private = "file")
to_screen :: proc(p: Plan, d: [2]f32) -> rl.Vector2 {
	return {p.origin.x + d.x * p.s, p.origin.y + d.y * p.s}
}

@(private = "file")
to_deck :: proc(p: Plan, m: rl.Vector2) -> [2]f32 {
	return {(m.x - p.origin.x) / p.s, (m.y - p.origin.y) / p.s}
}

// Draws the view. Returns what was asked for; `hot` is always true because
// the view covers the window.
ship_view_draw :: proc(v: Ship_View, st: ^Ship_View_State) -> (act: Ship_View_Action, member: int, post: crew.Post, candidate: int, hot: bool) {
	hot = true
	member = -1
	candidate = -1
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	mouse := rl.GetMousePosition()
	clicked := rl.IsMouseButtonPressed(.LEFT)
	rl.DrawRectangleRec({0, 0, sw, sh}, SV_BG)
	// A faint grid, so the plan reads as a drawing.
	for x: f32 = 0; x < sw; x += 40 do rl.DrawLineEx({x, BAR_H}, {x, sh}, 1, {12, 15, 22, 255})
	for y: f32 = BAR_H; y < sh; y += 40 do rl.DrawLineEx({0, y}, {sw, y}, 1, {12, 15, 22, 255})

	// ---- header
	top := f32(BAR_H) + 10
	text.draw(fmt.ctprintf("Inside the %s", v.ship_name), 18, i32(top), 20, TEXT_MAIN)
	text.draw(fmt.ctprintf("%d of %d bunks filled.  Click a crew member, then a room, to post them there.  Esc closes.", len(v.roster.members), v.bunks), 18, i32(top + 26), 12, TEXT_DIM)
	close := rl.Rectangle{sw - 42, top, 30, 26}
	if button(close, "x") do act = .Close
	if st.selected >= len(v.roster.members) do st.selected = -1

	// ---- the deck
	panel := rl.Rectangle{sw - SV_PANEL_W - 12, top + 52, SV_PANEL_W, sh - top - 64}
	area := rl.Rectangle{16, top + 52, panel.x - 32, sh - top - 64}
	d := v.deck
	plan := Plan{s = min((area.width - 60) / d.length, (area.height - 60) / d.beam)}
	plan.origin = {area.x + area.width * 0.5, area.y + area.height * 0.5}
	draw_hull(plan, d)
	// Corridor floor.
	{
		c0 := to_screen(plan, {d.rooms[0].x1, -d.corridor_half})
		c1 := to_screen(plan, {d.rooms[len(d.rooms) - 1].x0, d.corridor_half})
		rl.DrawRectangleRec({c0.x, c0.y, c1.x - c0.x, c1.y - c0.y}, SV_CORRIDOR)
	}
	deck_doc := art.library_get(v.lib, "deck")
	st.hover = -1
	mouse_deck := to_deck(plan, mouse)
	hover_room := -1
	for &r, i in d.rooms {
		draw_room(plan, &r, v, deck_doc, false)
		if crew.room_contains(&r, mouse_deck) do hover_room = i
	}
	// A room lights up while a selected crew member could be sent to it.
	if hover_room >= 0 && st.selected >= 0 {
		r := &d.rooms[hover_room]
		if _, ok := crew.post_for_room(r.kind); ok {
			p0 := to_screen(plan, {r.x0, r.y0})
			p1 := to_screen(plan, {r.x1, r.y1})
			rl.DrawRectangleLinesEx({p0.x, p0.y, p1.x - p0.x, p1.y - p0.y}, 2, ACCENT)
		}
	}
	// Crew on the deck.
	crew_doc := art.library_get(v.lib, "crew")
	for &m, i in v.roster.members {
		w := &m.walker
		if !w.inited do continue
		sp := to_screen(plan, w.pos)
		hit := rl.Vector2Distance(mouse, sp) < plan.s * 1.7
		if hit && st.hover < 0 do st.hover = i
		if i == st.selected {
			rl.DrawRing(sp, plan.s * 1.9, plan.s * 2.2, 0, 360, 32, ACCENT)
		} else if hit {
			rl.DrawRing(sp, plan.s * 1.9, plan.s * 2.1, 0, 360, 32, {120, 130, 160, 255})
		}
		draw_crew(crew_doc, &m, i < len(v.avatars) ? v.avatars[i] : render.Avatar{}, sp, plan.s * 0.5)
		// Name under the feet, and the post beside it.
		label := fmt.ctprintf("%s", first_name(m.name))
		lw := f32(text.measure(label, 10))
		rl.DrawRectangleRec({sp.x - lw * 0.5 - 3, sp.y + plan.s * 2.3 - 1, lw + 6, 13}, {8, 10, 16, 170})
		text.draw(label, i32(sp.x - lw * 0.5), i32(sp.y + plan.s * 2.3), 10, i == st.selected ? TEXT_MAIN : TEXT_DIM)
	}
	if clicked && rl.CheckCollisionPointRec(mouse, area) {
		if st.hover >= 0 {
			st.selected = st.selected == st.hover ? -1 : st.hover
			audio.play(.Click)
		} else if hover_room >= 0 && st.selected >= 0 {
			if p, ok := crew.post_for_room(d.rooms[hover_room].kind); ok {
				act = .Assign
				member = st.selected
				post = p
				audio.play(.Confirm)
			} else {
				audio.play(.Error)
			}
		} else {
			st.selected = -1
		}
	}

	// ---- roster panel
	rl.DrawRectangleRounded(panel, 0.02, 4, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(panel, 0.02, 4, 1, BAR_LINE)
	px := panel.x + 14
	py := panel.y + 10
	text.draw("Crew", i32(px), i32(py), 17, TEXT_MAIN)
	text.draw(fmt.ctprintf("%d / %d bunks", len(v.roster.members), v.bunks), i32(px + 60), i32(py + 3), 13, TEXT_DIM)
	list := rl.Rectangle{panel.x + 4, py + 30, panel.width - 8, panel.height - 40}
	over_list := rl.CheckCollisionPointRec(mouse, list)
	if over_list do st.scroll -= rl.GetMouseWheelMove() * 40
	// Measure the content first so the scroll clamps.
	content_h := f32(len(v.roster.members)) * SV_CARD_H + 150
	if v.docked_at != "" do content_h += 60 + f32(max(len(v.candidates), 1)) * 44
	st.scroll = clamp(st.scroll, 0, max(content_h - list.height, 0))
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	y := list.y - st.scroll
	for &m, i in v.roster.members {
		card := rl.Rectangle{list.x + 6, y, list.width - 12, SV_CARD_H - 8}
		over := over_list && rl.CheckCollisionPointRec(mouse, card)
		rl.DrawRectangleRounded(card, 0.06, 4, i == st.selected ? rl.Color{30, 36, 52, 255} : rl.Color{14, 18, 26, 255})
		rl.DrawRectangleRoundedLinesEx(card, 0.06, 4, 1, i == st.selected ? ACCENT : BAR_LINE)
		if i < len(v.avatars) do render.avatar_draw(v.lib, v.avatars[i], {card.x + 34, card.y + 34}, 1.4)
		tx := card.x + 68
		text.draw(fmt.ctprintf("%s", m.name), i32(tx), i32(card.y + 8), 15, TEXT_MAIN)
		text.draw(fmt.ctprintf("%s by trade, %s", crew.SYSTEM_TRADES[m.specialty], personality_name(m.personality)), i32(tx), i32(card.y + 28), 12, TEXT_DIM)
		post_c := m.post == .Off_Duty ? TEXT_DIM : SV_GOOD
		text.draw(fmt.ctprintf("%s", post_line(&m, v)), i32(tx), i32(card.y + 44), 12, post_c)
		// One row per system: level pips, progress, hours to the next.
		ry := card.y + 66
		for sys in crew.System {
			lvl := crew.level(&m, sys)
			on := m.post == crew.post_of(sys)
			text.draw(fmt.ctprintf("%s", crew.SYSTEM_NAMES[sys]), i32(card.x + 12), i32(ry), 11, on ? TEXT_MAIN : TEXT_DIM)
			for k in 0 ..< crew.MAX_LEVEL {
				pr := rl.Rectangle{card.x + 92 + f32(k) * 13, ry + 2, 10, 8}
				if k < lvl do rl.DrawRectangleRounded(pr, 0.3, 3, sys == m.specialty ? ACCENT : SV_CYAN)
				else do rl.DrawRectangleRoundedLinesEx(pr, 0.3, 3, 1, {70, 78, 96, 255})
			}
			bar := rl.Rectangle{card.x + 162, ry + 3, 70, 6}
			rl.DrawRectangleRounded(bar, 0.5, 3, {24, 30, 44, 255})
			rl.DrawRectangleRounded({bar.x, bar.y, bar.width * f32(crew.progress(&m, sys)), bar.height}, 0.5, 3, on ? SV_GOOD : rl.Color{80, 90, 110, 255})
			if h := crew.hours_to_next(&m, sys); h > 0 {
				text.draw(fmt.ctprintf("L%d  %s to L%d", lvl, hours_text(h), lvl + 1), i32(bar.x + bar.width + 8), i32(ry), 10, TEXT_DIM)
			} else {
				text.draw(fmt.ctprintf("L%d  top", lvl), i32(bar.x + bar.width + 8), i32(ry), 10, TEXT_DIM)
			}
			ry += 15
		}
		// Posting buttons.
		by := card.y + card.height - 26
		bw := (card.width - 24 - 3 * 4) / 4
		for p, k in ([?]crew.Post{.Engineering, .Navigation, .Comms, .Off_Duty}) {
			br := rl.Rectangle{card.x + 12 + f32(k) * (bw + 4), by, bw, 20}
			if small_button(br, crew.POST_NAMES[p], mouse, clicked && over_list, m.post == p) && m.post != p {
				act = .Assign
				member = i
				post = p
				audio.play(.Confirm)
			}
		}
		if v.docked_at != "" {
			if small_button({card.x + card.width - 70, card.y + 8, 60, 18}, "Ashore", mouse, clicked && over_list, false) {
				act = .Dismiss
				member = i
				audio.play(.Close)
			}
		}
		if over && clicked && act == .None && !rl.CheckCollisionPointRec(mouse, {card.x, by, card.width, 22}) {
			st.selected = st.selected == i ? -1 : i
			audio.play(.Click)
		}
		y += SV_CARD_H
	}
	// The systems: what the posted crew do for the ship.
	{
		box := rl.Rectangle{list.x + 6, y, list.width - 12, 130}
		rl.DrawRectangleRounded(box, 0.06, 4, {14, 18, 26, 255})
		rl.DrawRectangleRoundedLinesEx(box, 0.06, 4, 1, BAR_LINE)
		text.draw("Systems", i32(box.x + 12), i32(box.y + 8), 14, TEXT_MAIN)
		e := v.effects
		ly := box.y + 30
		for sys in crew.System {
			on := crew.staffed(e, sys)
			text.draw(fmt.ctprintf("%s", crew.SYSTEM_NAMES[sys]), i32(box.x + 12), i32(ly), 12, on ? SV_GOOD : SV_WARN)
			line: string
			switch sys {
			case .Engineering: line = on ? fmt.tprintf("repairs %.1f%% hull/h, heads off %.0f%% of hazard damage", e.repair_per_hour * 100, e.shield * 100) : "unstaffed: no repairs, no shielding"
			case .Navigation:  line = on ? fmt.tprintf("propellant goes %.0f%% further on every burn", (e.ve_bonus - 1) * 100) : "unstaffed: burns at the engine's nominal rate"
			case .Comms:       line = on ? fmt.tprintf("prices %.0f%% better, buying and selling", e.trade_edge * 100) : "unstaffed: you pay the board price"
			}
			for l, k in wrap_text(line, box.width - 120, 11) {
				if k > 1 do break
				text.draw(fmt.ctprintf("%s", l), i32(box.x + 108), i32(ly + f32(k) * 13), 11, TEXT_DIM)
			}
			ly += 30
		}
		y += 138
	}
	// Hiring, when there is a dock to hire at.
	{
		n := max(len(v.candidates), 1)
		box := rl.Rectangle{list.x + 6, y, list.width - 12, v.docked_at != "" ? f32(50 + n * 44) : 60}
		rl.DrawRectangleRounded(box, 0.06, 4, {14, 18, 26, 255})
		rl.DrawRectangleRoundedLinesEx(box, 0.06, 4, 1, BAR_LINE)
		if v.docked_at == "" {
			text.draw("Hiring", i32(box.x + 12), i32(box.y + 8), 14, TEXT_MAIN)
			text.draw("Dock at a station to hire crew or put crew ashore.", i32(box.x + 12), i32(box.y + 30), 11, TEXT_DIM)
		} else {
			text.draw(fmt.ctprintf("For hire at %s", v.docked_at), i32(box.x + 12), i32(box.y + 8), 14, TEXT_MAIN)
			text.draw(fmt.ctprintf("credits %.0f", v.credits), i32(box.x + box.width - 110), i32(box.y + 10), 12, TEXT_DIM)
			cy := box.y + 32
			if len(v.candidates) == 0 do text.draw("Nobody is looking for a berth here this week.", i32(box.x + 12), i32(cy + 4), 11, TEXT_DIM)
			room := len(v.roster.members) < v.bunks
			for c, k in v.candidates {
				text.draw(fmt.ctprintf("%s", c.name), i32(box.x + 12), i32(cy), 13, TEXT_MAIN)
				text.draw(fmt.ctprintf("%s L%d, %s", crew.SYSTEM_TRADES[c.specialty], c.level, personality_name(c.personality)), i32(box.x + 12), i32(cy + 17), 11, TEXT_DIM)
				can := room && v.credits >= c.fee
				if small_button({box.x + box.width - 96, cy + 4, 84, 22}, fmt.tprintf("Hire %.0f", c.fee), mouse, clicked && over_list && can, false, can) {
					act = .Hire
					candidate = k
					audio.play(.Confirm)
				}
				cy += 44
			}
			if !room do text.draw("No bunk free: put someone ashore first.", i32(box.x + 12), i32(box.y + box.height - 16), 10, SV_WARN)
		}
	}
	rl.EndScissorMode()
	if content_h > list.height {
		frac := list.height / content_h
		bar_h := max(list.height * frac, 20)
		bar_y := list.y + (list.height - bar_h) * (st.scroll / max(content_h - list.height, 1))
		rl.DrawRectangleRounded({list.x + list.width - 4, bar_y, 4, bar_h}, 0.5, 3, {90, 100, 130, 255})
	}
	if rl.IsKeyPressed(.ESCAPE) do act = .Close
	return
}

@(private = "file")
draw_hull :: proc(p: Plan, d: ^crew.Deck) {
	// Outline sampled along the length, top edge bow-ward then back along the bottom.
	N :: 36
	pts: [2 * N + 2]rl.Vector2
	for k in 0 ..= N {
		x := -d.length * 0.5 + d.length * f32(k) / N
		hb := crew.hull_half_beam(d, x)
		pts[k] = to_screen(p, {x, -hb})
		pts[2 * N + 1 - k] = to_screen(p, {x, hb})
	}
	// Engine bells and a bow light before the plating goes over them.
	stern := -d.length * 0.5
	nb := d.beam > 15 ? 3 : 2
	for k in 0 ..< nb {
		y := (f32(k) - f32(nb - 1) * 0.5) * d.beam * 0.36
		b0 := to_screen(p, {stern - 2.2, y - 1.1})
		b1 := to_screen(p, {stern + 0.5, y + 1.1})
		rl.DrawRectangleRounded({b0.x, b0.y, b1.x - b0.x, b1.y - b0.y}, 0.3, 4, {52, 56, 68, 255})
		rl.DrawRectangleRoundedLinesEx({b0.x, b0.y, b1.x - b0.x, b1.y - b0.y}, 0.3, 4, 1, SV_HULL_EDGE)
	}
	center := to_screen(p, {0, 0})
	fan: [2 * N + 3]rl.Vector2
	fan[0] = center
	for k in 0 ..< 2 * N + 2 do fan[k + 1] = pts[k]
	rl.DrawTriangleFan(&fan[0], i32(len(fan)), SV_HULL)
	for k in 0 ..< 2 * N + 2 do rl.DrawLineEx(pts[k], pts[(k + 1) % (2 * N + 2)], 2, SV_HULL_EDGE)
	// Plating seams.
	for k in 1 ..< 6 {
		x := -d.length * 0.5 + d.length * f32(k) / 6
		hb := crew.hull_half_beam(d, x)
		rl.DrawLineEx(to_screen(p, {x, -hb}), to_screen(p, {x, -hb + d.wall * 0.7}), 1, {70, 78, 94, 255})
		rl.DrawLineEx(to_screen(p, {x, hb}), to_screen(p, {x, hb - d.wall * 0.7}), 1, {70, 78, 94, 255})
	}
}

@(private = "file")
draw_room :: proc(p: Plan, r: ^crew.Room, v: Ship_View, deck_doc: ^art.Doc, highlight: bool) {
	p0 := to_screen(p, {r.x0, r.y0})
	p1 := to_screen(p, {r.x1, r.y1})
	rect := rl.Rectangle{p0.x, p0.y, p1.x - p0.x, p1.y - p0.y}
	tint := ROOM_TINT[r.kind]
	rl.DrawRectangleRec(rect, tint)
	// Deck plates.
	step := p.s * 2
	for x := rect.x + step; x < rect.x + rect.width; x += step do rl.DrawLineEx({x, rect.y}, {x, rect.y + rect.height}, 1, {tint.r + 6, tint.g + 6, tint.b + 8, 255})
	for y := rect.y + step; y < rect.y + rect.height; y += step do rl.DrawLineEx({rect.x, y}, {rect.x + rect.width, y}, 1, {tint.r + 6, tint.g + 6, tint.b + 8, 255})
	// Furniture.
	if deck_doc != nil {
		for f in r.fixtures {
			art.draw_doc(deck_doc, f.item, art.Xform{origin = to_screen(p, f.at), px = p.s * f.scale, rot = f.rot})
		}
		if r.kind == .Hold {
			n := int(math.ceil(v.cargo_frac * f64(len(r.hold_slots)) - 1e-6))
			for k in 0 ..< min(n, len(r.hold_slots)) {
				art.draw_doc(deck_doc, "crate", art.Xform{origin = to_screen(p, r.hold_slots[k]), px = p.s, rot = f32(k % 3) * 0.05})
			}
		}
	}
	rl.DrawRectangleLinesEx(rect, 2, SV_WALL)
	// The door: a gap in the corridor wall.
	dp := to_screen(p, r.door)
	if r.kind == .Bridge || r.kind == .Engineering {
		rl.DrawLineEx({dp.x, dp.y - p.s * 1.1}, {dp.x, dp.y + p.s * 1.1}, 3, SV_DOOR)
	} else {
		rl.DrawLineEx({dp.x - p.s * 1.1, dp.y}, {dp.x + p.s * 1.1, dp.y}, 3, SV_DOOR)
	}
	// Label and status, on a plate so they read over the furniture. Rooms
	// off the corridor are labelled on their corridor side, the end rooms
	// at their inboard corner.
	name := fmt.ctprintf("%s", crew.ROOM_NAMES[r.kind])
	post, has_post := crew.post_for_room(r.kind)
	lines: i32 = has_post && post != .Off_Duty ? 2 : 1
	if r.kind == .Engineering && v.hazard != "" do lines = 3
	plate_h := f32(lines) * 12 + 6
	lx := i32(rect.x + 6)
	ly := i32(rect.y + 5)
	if r.kind == .Bridge || r.y1 <= 0 do ly = i32(rect.y + rect.height - plate_h - 1)
	plate_w := f32(text.measure(name, 11)) + 8
	if has_post && post != .Off_Duty do plate_w = max(plate_w, 118)
	rl.DrawRectangleRec({f32(lx) - 3, f32(ly) - 2, plate_w, plate_h}, {8, 10, 16, 200})
	text.draw(name, lx, ly, 11, TEXT_DIM)
	if has_post && post != .Off_Duty {
		sys, _ := crew.system_of(post)
		on := crew.staffed(v.effects, sys)
		status: string
		switch sys {
		case .Engineering: status = on ? fmt.tprintf("hull %.0f%%  +%.1f%%/h", v.hull * 100, v.effects.repair_per_hour * 100) : fmt.tprintf("hull %.0f%%  unstaffed", v.hull * 100)
		case .Navigation:  status = on ? fmt.tprintf("prop %.0f%%  +%.0f%% range", v.propellant * 100, (v.effects.ve_bonus - 1) * 100) : fmt.tprintf("prop %.0f%%  unstaffed", v.propellant * 100)
		case .Comms:       status = on ? fmt.tprintf("prices -%.0f%%", v.effects.trade_edge * 100) : "unstaffed"
		}
		col := on ? SV_GOOD : SV_WARN
		if sys == .Engineering && v.hazard != "" do col = SV_BAD
		sy := ly + 13
		text.draw(fmt.ctprintf("%s", status), lx, sy, 10, col)
		if sys == .Engineering && v.hazard != "" do text.draw(fmt.ctprintf("%s", v.hazard), lx, sy + 12, 10, SV_BAD)
	}
	if highlight do rl.DrawRectangleLinesEx(rect, 2, ACCENT)
}

@(private = "file")
draw_crew :: proc(doc: ^art.Doc, m: ^crew.Member, av: render.Avatar, at: rl.Vector2, px: f32) {
	if doc == nil {
		rl.DrawCircleV(at, px * 1.4, {av.cloth[0], av.cloth[1], av.cloth[2], 255})
		rl.DrawCircleV(at, px * 0.9, {av.skin[0], av.skin[1], av.skin[2], 255})
		return
	}
	ov := [?]art.Override {
		{"skin", av.skin}, {"skin_shade", av.skin_shade}, {"hair", av.hair_col}, {"hair_shade", av.hair_shade},
		{"cloth", av.cloth}, {"cloth2", av.cloth2}, {"accent", av.accent},
	}
	w := &m.walker
	poses := make([dynamic]art.State_Part, 0, 8, context.temp_allocator)
	if c := art.clip_of(doc, w.moving ? "walk" : "idle"); c != nil {
		art.sample_clip(doc, c, w.anim_t, &poses)
	}
	xf := art.Xform{origin = at, px = px, rot = w.facing}
	// A soft shadow under the feet.
	rl.DrawCircleV({at.x + px * 0.3, at.y + px * 0.4}, px * 2.2, {0, 0, 0, 70})
	if len(poses) > 0 do art.draw_poses(doc, poses[:], xf, ov[:])
	else do art.draw_doc(doc, "idle", xf, ov[:])
}

@(private = "file")
post_line :: proc(m: ^crew.Member, v: Ship_View) -> string {
	switch m.post {
	case .Off_Duty:    return "off duty"
	case .Engineering: return fmt.tprintf("at engineering, level %d", crew.level(m, .Engineering))
	case .Navigation:  return fmt.tprintf("on the bridge, level %d", crew.level(m, .Navigation))
	case .Comms:       return fmt.tprintf("at comms, level %d", crew.level(m, .Comms))
	}
	return ""
}

@(private = "file")
first_name :: proc(name: string) -> string {
	for c, i in name do if c == ' ' do return name[:i]
	return name
}

@(private = "file")
personality_name :: proc(p: people.Personality) -> string {
	names := people.PERSONALITY_NAMES
	return names[p]
}

@(private = "file")
hours_text :: proc(h: f64) -> string {
	if h < 48 do return fmt.tprintf("%.0fh", h)
	return fmt.tprintf("%.1fd", h / 24)
}

// A compact button for cards; `on` draws it lit.
@(private = "file")
small_button :: proc(r: rl.Rectangle, label: string, mouse: rl.Vector2, clicked: bool, on: bool, enabled := true) -> bool {
	over := enabled && rl.CheckCollisionPointRec(mouse, r)
	bg := on ? ACCENT : (over ? HOVER_BG : rl.Color{30, 36, 50, 255})
	if !enabled do bg = {22, 26, 36, 255}
	rl.DrawRectangleRounded(r, 0.3, 3, bg)
	l := fmt.ctprintf("%s", label)
	tw := f32(text.measure(l, 11))
	text.draw(l, i32(r.x + (r.width - tw) * 0.5), i32(r.y + (r.height - 11) * 0.5 - 1), 11, on ? rl.Color{20, 20, 20, 255} : (enabled ? TEXT_MAIN : TEXT_DIM))
	return over && clicked
}
