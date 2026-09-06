package ui

// The job board at the market in range, and the player's contracts.

import "core:fmt"
import rl "vendor:raylib"
import core "sim:core"
import econ "sim:econ"
import text "sim:text"

Contract_Row :: struct {
	job:     econ.Job,
	desc:    string,
	status:  string, // "carrying 12 ore", "deliver here", "3.2d left"
	ready:   bool,   // deliverable now
}

Jobs_View :: struct {
	e:         ^econ.Economy,
	market:    int,  // board shown, -1 for none in range
	board:     []econ.Job,
	contracts: []Contract_Row,
	t:         f64,
	free_hold: f64,
	max_active: int,
	show_board: bool, // opened at a station or colony: its board is offered
	place:     string, // the station or colony's name
}

// accept: job id chosen from the board (0 when none); deliver: contract index (-1 when none).
jobs_panel_draw :: proc(v: Jobs_View, open: ^bool) -> (accept: u64, deliver: int, hot: bool) {
	deliver = -1
	if !open^ do return
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rows := (v.show_board ? len(v.board) : 0) + len(v.contracts)
	base := v.show_board ? 120 : 70
	ph := f32(base + rows * 26 + 40)
	r := rl.Rectangle{(sw - 760) * 0.5, BAR_H + 40, 760, ph}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.03, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.03, 6, 1, BAR_LINE)
	x := r.x + 16
	y := r.y + 12
	title := v.show_board ? fmt.tprintf("Jobs at %s", v.place) : "Your contracts"
	text.draw(fmt.ctprintf("%s", title), i32(x), i32(y), 18, TEXT_MAIN)
	close := rl.Rectangle{r.x + r.width - 34, r.y + 10, 24, 24}
	over_close := rl.CheckCollisionPointRec(mouse, close)
	rl.DrawRectangleRounded(close, 0.3, 4, over_close ? HOVER_BG : rl.Color{30, 36, 50, 255})
	text.draw("x", i32(close.x + 7), i32(close.y + 3), 16, TEXT_MAIN)
	if over_close && rl.IsMouseButtonPressed(.LEFT) do open^ = false
	y += 34
	cols := [?]f32{0, 330, 430, 540, 640}
	if v.show_board {
		text.draw("Posted here", i32(x), i32(y), 13, {220, 170, 90, 255})
		y += 20
		if v.market < 0 {
			text.draw("You have drifted out of range; the board is back at the station.", i32(x), i32(y), 13, TEXT_DIM)
			y += 26
		} else if len(v.board) == 0 {
			text.draw("Nothing posted today.", i32(x), i32(y), 13, TEXT_DIM)
			y += 26
		}
	}
	for j in v.board {
		if !v.show_board do break
		left := j.deadline - v.t
		ok, why := econ.job_accept_ok(j, v.free_hold)
		full := len(v.contracts) >= v.max_active
		col := ok && !full ? TEXT_MAIN : TEXT_DIM
		text.draw(fmt.ctprintf("%s", econ.job_describe(v.e, j)), i32(x + cols[0]), i32(y), 14, col)
		text.draw(fmt.ctprintf("%.0f cr", j.reward), i32(x + cols[1]), i32(y), 14, {150, 230, 170, 255})
		text.draw(fmt.ctprintf("%s left", core.clock_duration(left)), i32(x + cols[2]), i32(y), 13, left < core.SECONDS_PER_DAY ? rl.Color{255, 140, 120, 255} : TEXT_DIM)
		if !ok do text.draw(fmt.ctprintf("%s", why), i32(x + cols[3]), i32(y), 12, {255, 140, 120, 255})
		else if full do text.draw("contracts full", i32(x + cols[3]), i32(y), 12, {255, 140, 120, 255})
		if button({x + cols[4], y - 4, 90, 22}, "Accept", ok && !full, false, 13) do accept = j.id
		y += 26
	}
	y += 8
	text.draw(fmt.ctprintf("Your contracts (%d of %d)", len(v.contracts), v.max_active), i32(x), i32(y), 13, {220, 170, 90, 255})
	y += 20
	if len(v.contracts) == 0 {
		text.draw(v.show_board ? "None. Accept a job above; deadlines run on the game clock." : "None. Stations and colonies post jobs; ask at the market or the vendor.", i32(x), i32(y), 13, TEXT_DIM)
		y += 26
	}
	for c, i in v.contracts {
		left := c.job.deadline - v.t
		text.draw(fmt.ctprintf("%s", c.desc), i32(x + cols[0]), i32(y), 14, TEXT_MAIN)
		text.draw(fmt.ctprintf("%.0f cr", c.job.reward), i32(x + cols[1]), i32(y), 14, {150, 230, 170, 255})
		text.draw(fmt.ctprintf("%s left", core.clock_duration(left)), i32(x + cols[2]), i32(y), 13, left < core.SECONDS_PER_DAY ? rl.Color{255, 140, 120, 255} : TEXT_DIM)
		text.draw(fmt.ctprintf("%s", c.status), i32(x + cols[3]), i32(y), 12, TEXT_DIM)
		if c.ready && button({x + cols[4], y - 4, 90, 22}, "Deliver", true, true, 13) do deliver = i
		y += 26
	}
	text.draw("Deliveries hand you the goods now. Arriving at the destination with them aboard completes the job.", i32(x), i32(r.y + ph - 26), 12, TEXT_DIM)
	return
}
