package ui

// The conversation panel: a person's face and name, what they just said,
// and the things you can say back. Pilots also trade from here.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"
import art "sim:art"
import audio "sim:audio"
import render "sim:render"
import text "sim:text"

Talk_Choice :: enum u8 {
	None,
	Small_Talk,
	Rumour,
	Cargo,     // pilot: about their cargo; vendor: about the market
	Trade,     // pilot: open the in-panel trade; vendor: open the market window
	Haggle,
	Buy,       // buy `qty` units from the pilot
	Sell,      // sell `qty` units to the pilot
	Leave,
	Work, // vendor: show the jobs posted here
}

Talk_Offer :: struct {
	commodity:  string,
	sell_units: f64, // what the pilot has to sell
	sell_price: f64, // per unit, after any haggle
	buy_price:  f64, // what the pilot pays per unit of the same commodity
	buy_room:   f64, // units the pilot can still take (hold and credits)
	you_have:   f64, // units of that commodity in your hold
	your_room:  f64, // free hold
	credits:    f64,
}

Talk_View :: struct {
	lib:         ^art.Library,
	avatar:      render.Avatar,
	name:        string,
	role:        string, // "pilot of the Hauler Nouzern Runner", "vendor at X"
	mood:        string,
	line:        string, // what they said
	is_pilot:    bool,
	trading:     bool, // the trade rows are open
	can_haggle:  bool,
	can_trade:   bool, // false over the radio: you have to be docked
	offer:       Talk_Offer,
}

Talk_State :: struct {
	qty: int,
}

TALK_W :: 760
TALK_H :: 420

// Wrap `s` into lines that fit `width` at `size`.
wrap_text :: proc(s: string, width: f32, size: i32, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	line := strings.builder_make(allocator)
	for word in strings.split(s, " ", allocator) {
		trial := strings.builder_len(line) == 0 ? word : fmt.tprintf("%s %s", strings.to_string(line), word)
		if f32(text.measure(fmt.ctprintf("%s", trial), size)) > width && strings.builder_len(line) > 0 {
			append(&out, strings.clone(strings.to_string(line), allocator))
			strings.builder_reset(&line)
		}
		if strings.builder_len(line) > 0 do strings.write_byte(&line, ' ')
		strings.write_string(&line, word)
	}
	if strings.builder_len(line) > 0 do append(&out, strings.clone(strings.to_string(line), allocator))
	return out[:]
}

talk_draw :: proc(v: Talk_View, st: ^Talk_State) -> (choice: Talk_Choice, qty: int, hot: bool) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	r := rl.Rectangle{(sw - TALK_W) * 0.5, max((sh - TALK_H) * 0.5, BAR_H + 20), TALK_W, TALK_H}
	mouse := rl.GetMousePosition()
	hot = rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRounded(r, 0.03, 6, MENU_BG)
	rl.DrawRectangleRoundedLinesEx(r, 0.03, 6, 1, BAR_LINE)
	// Left: the face and who they are.
	face := [2]f32{r.x + 90, r.y + 96}
	render.avatar_draw(v.lib, v.avatar, face, 4)
	text.draw(fmt.ctprintf("%s", v.name), i32(r.x + 20), i32(r.y + 176), 16, TEXT_MAIN)
	for l, i in wrap_text(v.role, 150, 12) do text.draw(fmt.ctprintf("%s", l), i32(r.x + 20), i32(r.y + 198 + f32(i) * 15), 12, TEXT_DIM)
	text.draw(fmt.ctprintf("%s", v.mood), i32(r.x + 20), i32(r.y + 240), 12, {220, 170, 90, 255})
	// Right: the line, then the choices.
	x := r.x + 190
	y := r.y + 24
	rl.DrawRectangleRounded({x - 10, y - 10, r.width - 200, 118}, 0.08, 4, {12, 15, 22, 255})
	for l, i in wrap_text(v.line, r.width - 220, 15) {
		if i > 5 do break
		text.draw(fmt.ctprintf("%s", l), i32(x), i32(y + f32(i) * 19), 15, TEXT_MAIN)
	}
	y += 128
	if v.trading {
		o := v.offer
		text.draw(fmt.ctprintf("%s   they sell %.0f at %.1f   they buy at %.1f (room for %.0f)", o.commodity, o.sell_units, o.sell_price, o.buy_price, o.buy_room), i32(x), i32(y), 13, TEXT_DIM)
		y += 22
		text.draw(fmt.ctprintf("you have %.0f, hold free %.0f, credits %.0f", o.you_have, o.your_room, o.credits), i32(x), i32(y), 13, TEXT_DIM)
		y += 26
		if st.qty <= 0 do st.qty = 1
		if button({x, y, 34, 26}, "-10") do st.qty = max(st.qty - 10, 1)
		if button({x + 38, y, 30, 26}, "-1") do st.qty = max(st.qty - 1, 1)
		text.draw(fmt.ctprintf("%d", st.qty), i32(x + 80), i32(y + 5), 15, TEXT_MAIN)
		if button({x + 118, y, 30, 26}, "+1") do st.qty += 1
		if button({x + 152, y, 34, 26}, "+10") do st.qty += 10
		can_buy := o.sell_units >= 1 && o.your_room >= 1 && o.credits >= o.sell_price
		can_sell := o.you_have >= 1 && o.buy_room >= 1
		if button({x + 210, y, 150, 26}, fmt.tprintf("Buy for %.0f", f64(st.qty) * o.sell_price), can_buy) { choice = .Buy; qty = st.qty }
		if button({x + 370, y, 150, 26}, fmt.tprintf("Sell for %.0f", f64(st.qty) * o.buy_price), can_sell) { choice = .Sell; qty = st.qty }
		y += 36
		if button({x, y, 200, 26}, "Ask for a better price", v.can_haggle) do choice = .Haggle
		if button({x + 210, y, 150, 26}, "Enough trading") do choice = .Trade
		y += 36
	} else {
		bw: f32 = 170
		if button({x, y, bw, 28}, "Small talk") do choice = .Small_Talk
		if button({x + bw + 10, y, bw, 28}, "Heard anything?") do choice = .Rumour
		if button({x + 2 * (bw + 10), y, bw, 28}, v.is_pilot ? "About your cargo" : "About the market") do choice = .Cargo
		y += 38
		if button({x, y, bw, 28}, v.is_pilot ? "Let's trade" : "Show me the market", v.can_trade, true) do choice = .Trade
		if !v.is_pilot && button({x + bw + 10, y, bw, 28}, "Any work going?", v.can_trade) do choice = .Work
		if !v.can_trade do text.draw("over the radio: dock to trade", i32(x + (v.is_pilot ? bw + 12 : 2 * (bw + 10) + 2)), i32(y + 6), 12, TEXT_DIM)
		y += 38
	}
	if button({r.x + r.width - 150, r.y + r.height - 44, 130, 30}, "Goodbye") do choice = .Leave
	if rl.IsKeyPressed(.ESCAPE) do choice = .Leave
	if choice != .None && choice != .Leave do audio.play(.Click)
	return
}
