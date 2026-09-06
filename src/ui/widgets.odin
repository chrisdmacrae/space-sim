package ui

// Small immediate-mode widgets for the menu screens: buttons, toggles,
// sliders, option cyclers and a text field. They play the interface sounds
// themselves so every screen sounds the same.

import "core:fmt"
import rl "vendor:raylib"
import audio "sim:audio"
import text "sim:text"

// Hover sounds fire once per widget; the id is the widget's screen rect.
@(private = "file")
hover_id: rl.Rectangle

@(private = "file")
hover_sound :: proc(r: rl.Rectangle, over: bool) {
	if over {
		if r != hover_id {
			hover_id = r
			audio.play(.Hover)
		}
	} else if r == hover_id {
		hover_id = {}
	}
}

button :: proc(r: rl.Rectangle, label: string, enabled := true, accent := false, size: i32 = 15) -> bool {
	mouse := rl.GetMousePosition()
	over := enabled && rl.CheckCollisionPointRec(mouse, r)
	hover_sound(r, over)
	bg := over ? HOVER_BG : (accent ? rl.Color{60, 44, 32, 255} : rl.Color{30, 36, 50, 255})
	if !enabled do bg = {22, 26, 36, 255}
	rl.DrawRectangleRounded(r, 0.25, 4, bg)
	if accent do rl.DrawRectangleRoundedLinesEx(r, 0.25, 4, 1, ACCENT)
	l := fmt.ctprintf("%s", label)
	tw := f32(text.measure(l, size))
	text.draw(l, i32(r.x + (r.width - tw) * 0.5), i32(r.y + (r.height - f32(size)) * 0.5 - 1), size, enabled ? TEXT_MAIN : TEXT_DIM)
	if over && rl.IsMouseButtonPressed(.LEFT) {
		audio.play(.Click)
		return true
	}
	return false
}

toggle :: proc(r: rl.Rectangle, label: string, value: ^bool) -> (changed: bool) {
	mouse := rl.GetMousePosition()
	over := rl.CheckCollisionPointRec(mouse, r)
	hover_sound(r, over)
	if over do rl.DrawRectangleRounded(r, 0.2, 3, HOVER_BG)
	box := rl.Rectangle{r.x + 8, r.y + (r.height - 14) * 0.5, 14, 14}
	rl.DrawRectangleLinesEx(box, 1, TEXT_DIM)
	if value^ do rl.DrawRectangleRec({box.x + 3, box.y + 3, 8, 8}, ACCENT)
	text.draw(fmt.ctprintf("%s", label), i32(r.x + 30), i32(r.y + (r.height - 15) * 0.5 - 1), 15, TEXT_MAIN)
	if over && rl.IsMouseButtonPressed(.LEFT) {
		value^ = !value^
		audio.play(.Click)
		return true
	}
	return false
}

// A horizontal slider with the value printed on the right.
slider :: proc(r: rl.Rectangle, label: string, value: ^f32, lo, hi: f32, fmt_str := "%.2f") -> (changed: bool) {
	mouse := rl.GetMousePosition()
	text.draw(fmt.ctprintf("%s", label), i32(r.x), i32(r.y), 15, TEXT_MAIN)
	track := rl.Rectangle{r.x + 200, r.y + 8, r.width - 270, 6}
	hit := rl.Rectangle{track.x - 6, r.y - 4, track.width + 12, r.height + 8}
	over := rl.CheckCollisionPointRec(mouse, hit)
	hover_sound(hit, over)
	rl.DrawRectangleRounded(track, 0.5, 3, {24, 30, 44, 255})
	u := clamp((value^ - lo) / (hi - lo), 0, 1)
	rl.DrawRectangleRounded({track.x, track.y, track.width * u, track.height}, 0.5, 3, ACCENT)
	kx := track.x + track.width * u
	rl.DrawCircleV({kx, track.y + 3}, 7, over ? TEXT_MAIN : rl.Color{200, 206, 220, 255})
	text.draw(fmt.ctprintf(fmt_str, value^), i32(track.x + track.width + 14), i32(r.y), 15, TEXT_DIM)
	if over && rl.IsMouseButtonDown(.LEFT) {
		nu := clamp((mouse.x - track.x) / track.width, 0, 1)
		nv := lo + (hi - lo) * nu
		if nv != value^ {
			value^ = nv
			changed = true
		}
	}
	if over && rl.IsMouseButtonReleased(.LEFT) do audio.play(.Click)
	return
}

// "< option >" chooser.
cycler :: proc(r: rl.Rectangle, label: string, options: []string, index: ^int) -> (changed: bool) {
	text.draw(fmt.ctprintf("%s", label), i32(r.x), i32(r.y + 4), 15, TEXT_MAIN)
	left := rl.Rectangle{r.x + 200, r.y, 28, r.height}
	right := rl.Rectangle{r.x + r.width - 28, r.y, 28, r.height}
	if button(left, "<", len(options) > 1) {
		index^ = (index^ + len(options) - 1) % len(options)
		changed = true
	}
	if button(right, ">", len(options) > 1) {
		index^ = (index^ + 1) % len(options)
		changed = true
	}
	name := index^ >= 0 && index^ < len(options) ? options[index^] : ""
	l := fmt.ctprintf("%s", name)
	mid := left.x + left.width + (right.x - left.x - left.width) * 0.5
	tw := f32(text.measure(l, 15))
	text.draw(l, i32(mid - tw * 0.5), i32(r.y + 4), 15, TEXT_MAIN)
	return
}

Text_Field :: struct {
	buf:   [40]u8,
	len:   int,
	focus: bool,
}

field_text :: proc(f: ^Text_Field) -> string { return string(f.buf[:f.len]) }

field_set :: proc(f: ^Text_Field, s: string) {
	f.len = min(len(s), len(f.buf))
	copy(f.buf[:f.len], s[:f.len])
}

// Single-line text entry. `digits` restricts input to 0-9.
text_field :: proc(r: rl.Rectangle, label: string, f: ^Text_Field, digits := false) -> (changed: bool) {
	mouse := rl.GetMousePosition()
	text.draw(fmt.ctprintf("%s", label), i32(r.x), i32(r.y + 4), 15, TEXT_MAIN)
	box := rl.Rectangle{r.x + 200, r.y, r.width - 200, r.height}
	over := rl.CheckCollisionPointRec(mouse, box)
	if rl.IsMouseButtonPressed(.LEFT) {
		if over && !f.focus do audio.play(.Click)
		f.focus = over
	}
	rl.DrawRectangleRounded(box, 0.2, 3, {14, 18, 26, 255})
	rl.DrawRectangleRoundedLinesEx(box, 0.2, 3, 1, f.focus ? ACCENT : BAR_LINE)
	if f.focus {
		for {
			ch := rl.GetCharPressed()
			if ch == 0 do break
			if ch < 32 || ch > 126 do continue
			if digits && (ch < '0' || ch > '9') do continue
			if f.len < len(f.buf) {
				f.buf[f.len] = u8(ch)
				f.len += 1
				changed = true
			}
		}
		if rl.IsKeyPressed(.BACKSPACE) && f.len > 0 {
			f.len -= 1
			changed = true
		}
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.ESCAPE) do f.focus = false
	}
	shown := fmt.ctprintf("%s%s", field_text(f), f.focus && (int(rl.GetTime() * 2) % 2 == 0) ? "_" : "")
	text.draw(shown, i32(box.x + 8), i32(box.y + 4), 15, TEXT_MAIN)
	return
}

// A row of tab buttons; returns true when the selection changed.
tabs :: proc(r: rl.Rectangle, names: []string, index: ^int) -> (changed: bool) {
	w := r.width / f32(max(len(names), 1))
	mouse := rl.GetMousePosition()
	for name, i in names {
		tr := rl.Rectangle{r.x + w * f32(i), r.y, w - 4, r.height}
		over := rl.CheckCollisionPointRec(mouse, tr)
		hover_sound(tr, over)
		active := i == index^
		rl.DrawRectangleRounded(tr, 0.2, 3, active ? HOVER_BG : (over ? rl.Color{30, 36, 50, 255} : rl.Color{22, 26, 36, 255}))
		if active do rl.DrawRectangleRec({tr.x + 8, tr.y + tr.height - 3, tr.width - 16, 2}, ACCENT)
		l := fmt.ctprintf("%s", name)
		tw := f32(text.measure(l, 15))
		text.draw(l, i32(tr.x + (tr.width - tw) * 0.5), i32(tr.y + (tr.height - 15) * 0.5 - 1), 15, active ? TEXT_MAIN : TEXT_DIM)
		if over && rl.IsMouseButtonPressed(.LEFT) && !active {
			index^ = i
			changed = true
			audio.play(.Click)
		}
	}
	return
}
