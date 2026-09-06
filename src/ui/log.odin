package ui

// The ship's log, bottom left: what has happened, in order, with the time it
// happened at. Warnings stay on the page after the hazard has passed, and
// every orbit the ship settles into is written down, so the instruments can
// stay in the present tense.
//
// Entries own their strings. The panel keeps the last LOG_MAX of them and
// scrolls under the wheel; while it is scrolled back, new entries do not drag
// the view along.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"
import text "sim:text"

LOG_W      :: 348
LOG_H      :: 152
LOG_MAX    :: 200 // entries kept
LOG_WINDOW :: 60  // entries the panel is willing to lay out in one frame
LOG_ROW    :: 15
LOG_STAMP  :: 84  // width of the timestamp column

Log_Kind :: enum u8 {
	Info,
	Good,
	Warn,
	Alarm,
	Orbit,
}

LOG_COLORS := [Log_Kind]rl.Color {
	.Info  = {176, 190, 210, 255},
	.Good  = {150, 230, 170, 255},
	.Warn  = {240, 182,  92, 255},
	.Alarm = {242, 112, 106, 255},
	.Orbit = {120, 198, 232, 255},
}

Log_Entry :: struct {
	stamp: string, // owned
	msg:   string, // owned
	kind:  Log_Kind,
}

Log :: struct {
	entries: [dynamic]Log_Entry,
	scroll:  int, // rows scrolled back from the newest
	dropped: int, // entries pushed out of the back
}

// Append a line. A repeat of the line already at the bottom is dropped, so a
// condition that is checked every frame does not fill the page.
log_push :: proc(l: ^Log, stamp: string, kind: Log_Kind, msg: string) {
	if len(l.entries) > 0 {
		last := l.entries[len(l.entries) - 1]
		if last.kind == kind && last.msg == msg do return
	}
	append(&l.entries, Log_Entry{strings.clone(stamp), strings.clone(msg), kind})
	for len(l.entries) > LOG_MAX {
		e := l.entries[0]
		delete(e.stamp)
		delete(e.msg)
		ordered_remove(&l.entries, 0)
		l.dropped += 1
	}
	if l.scroll > 0 do l.scroll += 1 // hold the reader's place
}

log_clear :: proc(l: ^Log) {
	for e in l.entries {
		delete(e.stamp)
		delete(e.msg)
	}
	clear(&l.entries)
	l.scroll = 0
	l.dropped = 0
}

log_destroy :: proc(l: ^Log) {
	log_clear(l)
	delete(l.entries)
	l.entries = nil
}

@(private = "file")
Log_Row :: struct {
	stamp: string, // only on an entry's first row
	msg:   string,
	kind:  Log_Kind,
}

log_draw :: proc(l: ^Log) -> (hot: bool) {
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{HUD_MARGIN, sh - LOG_H - HUD_MARGIN, LOG_W, LOG_H}
	hot = rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
	hud_panel(r, HUD_EDGE)

	rows_h := LOG_H - 32 - 6
	visible := int(rows_h) / LOG_ROW
	msg_x := r.x + 12 + LOG_STAMP
	msg_w := r.width - 12 - LOG_STAMP - 12

	// Newest first: lay out just enough entries to fill the page.
	rows := make([dynamic]Log_Row, 0, visible + 8, context.temp_allocator)
	first := max(len(l.entries) - LOG_WINDOW, 0)
	for i := len(l.entries) - 1; i >= first; i -= 1 {
		e := l.entries[i]
		wrapped := wrap_text(e.msg, msg_w, 12)
		for j := len(wrapped) - 1; j >= 0; j -= 1 {
			append(&rows, Log_Row{j == 0 ? e.stamp : "", wrapped[j], e.kind})
		}
		if len(rows) >= visible + l.scroll do break
	}
	if hot {
		if w := rl.GetMouseWheelMove(); w != 0 do l.scroll += int(w) * 2
	}
	l.scroll = clamp(l.scroll, 0, max(len(rows) - visible, 0))

	text.draw("SHIP LOG", i32(r.x + 14), i32(r.y + 9), 11, HUD_DIM)
	if l.scroll > 0 {
		back := fmt.ctprintf("^ %d back", l.scroll)
		text.draw(back, i32(r.x + r.width - 14 - f32(text.measure(back, 10))), i32(r.y + 10), 10, HUD_AMBER)
	} else if hot && len(rows) > visible {
		text.draw("wheel to scroll", i32(r.x + r.width - 14 - f32(text.measure("wheel to scroll", 10))), i32(r.y + 10), 10, HUD_DIM)
	} else if len(l.entries) == 0 {
		text.draw("nothing logged yet", i32(r.x + 14), i32(r.y + 34), 12, HUD_DIM)
	}
	rl.DrawLineEx({r.x + 10, r.y + 30}, {r.x + r.width - 10, r.y + 30}, 1, HUD_LINE)

	// Row 0 is the newest and sits at the bottom.
	bottom := r.y + LOG_H - 8
	rl.BeginScissorMode(i32(r.x + 2), i32(r.y + 31), i32(r.width - 4), i32(LOG_H - 39))
	for row, k in rows {
		slot := k - l.scroll
		if slot < 0 do continue
		if slot >= visible do break
		y := bottom - f32(slot + 1) * LOG_ROW
		if row.stamp != "" do text.draw(fmt.ctprintf("%s", row.stamp), i32(r.x + 12), i32(y + 1), 10, HUD_DIM)
		text.draw(fmt.ctprintf("%s", row.msg), i32(msg_x), i32(y), 12, LOG_COLORS[row.kind])
	}
	rl.EndScissorMode()
	// Scrollbar, once there is more than a page.
	if len(rows) > visible {
		trk := rl.Rectangle{r.x + r.width - 5, r.y + 32, 2, f32(visible * LOG_ROW)}
		rl.DrawRectangleRec(trk, HUD_LINE)
		frac := f32(visible) / f32(len(rows))
		th := max(trk.height * frac, 8)
		off := (trk.height - th) * f32(l.scroll) / f32(max(len(rows) - visible, 1))
		rl.DrawRectangleRec({trk.x, trk.y + trk.height - th - off, trk.width, th}, HUD_DIM)
	}
	return
}
