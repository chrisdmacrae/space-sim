package render

// Trade-route overlay: a line from the buying market to the selling market
// for each known route, weighted by how much it earns, with the commodity
// at the midpoint once there is room.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import econ "sim:econ"
import gen "sim:gen"
import text "sim:text"

ROUTE_COLOR :: rl.Color{255, 200, 90, 255}

// Dashed line in screen space.
draw_dashed :: proc(a, b: rl.Vector2, thick: f32, color: rl.Color, dash: f32 = 8, gap: f32 = 6) {
	dx, dy := b.x - a.x, b.y - a.y
	l := math.sqrt(dx * dx + dy * dy)
	if l < 1 do return
	ux, uy := dx / l, dy / l
	t: f32 = 0
	for t < l {
		e := min(t + dash, l)
		rl.DrawLineEx({a.x + ux * t, a.y + uy * t}, {a.x + ux * e, a.y + uy * e}, thick, color)
		t += dash + gap
	}
}

// Routes are dotted unless they touch the focused station, or a station of
// the focused body; those are solid. Pass -1 for no focus.
draw_routes :: proc(cam: ^Camera, sys: ^gen.System, e: ^econ.Economy, routes: []econ.Route, focus_station: int, focus_body: gen.Body_Handle) {
	if len(routes) == 0 do return
	best := routes[0].rate
	touches :: proc(sys: ^gen.System, m: ^econ.Market, focus_station: int, focus_body: gen.Body_Handle) -> bool {
		if m.station >= 0 && m.station == focus_station do return true
		return focus_body != gen.NONE && econ.market_body(sys, m) == focus_body
	}
	for r, i in routes {
		if i >= 16 do break
		ma := &e.markets[r.from]
		mb := &e.markets[r.to]
		a := world_to_screen(cam, econ.market_pos(sys, ma))
		b := world_to_screen(cam, econ.market_pos(sys, mb))
		if !on_screen(a, 2000) && !on_screen(b, 2000) do continue
		w := f32(clamp(r.rate / max(best, 1e-9), 0.15, 1))
		col := ROUTE_COLOR
		col.a = u8(60 + 160 * w)
		thick := 1 + 2.5 * w
		solid := touches(sys, ma, focus_station, focus_body) || touches(sys, mb, focus_station, focus_body)
		if solid {
			col.a = 255
			rl.DrawLineEx({a.x, a.y}, {b.x, b.y}, thick + 0.5, col)
		} else {
			draw_dashed({a.x, a.y}, {b.x, b.y}, thick, col)
		}
		// Arrow head at the selling end.
		dx, dy := b.x - a.x, b.y - a.y
		l := math.sqrt(dx * dx + dy * dy)
		if l > 30 {
			ux, uy := dx / l, dy / l
			tip := rl.Vector2{b.x - ux * 10, b.y - uy * 10}
			left := rl.Vector2{tip.x - ux * 10 + uy * 6, tip.y - uy * 10 - ux * 6}
			right := rl.Vector2{tip.x - ux * 10 - uy * 6, tip.y - uy * 10 + ux * 6}
			rl.DrawTriangle(tip, left, right, col)
			rl.DrawTriangle(tip, right, left, col)
		}
		if l > 120 {
			mid := rl.Vector2{(a.x + b.x) * 0.5, (a.y + b.y) * 0.5}
			label := fmt.ctprintf("%s  %.0f/day", econ.NAMES[r.commodity], r.rate)
			tw := f32(text.measure(label, 11))
			rl.DrawRectangleRounded({mid.x - tw * 0.5 - 4, mid.y - 8, tw + 8, 16}, 0.4, 3, {10, 12, 18, 200})
			text.draw(label, i32(mid.x - tw * 0.5), i32(mid.y - 6), 11, col)
		}
	}
}

// Legend for every line kind currently drawn, across the top of the screen.
Legend_Entry :: struct {
	label: string,
	color: rl.Color,
	thick: f32,
	on:    bool,
}

draw_legend :: proc(entries: []Legend_Entry) {
	// Compact: small swatches, short labels, tucked under the title line.
	total: f32 = 0
	for en in entries do if en.on do total += 20 + f32(text.measure(fmt.ctprintf("%s", en.label), 11)) + 12
	if total == 0 do return
	x: f32 = 12
	y: f32 = 34 + 10 // just under the toolbar
	rl.DrawRectangleRounded({x - 6, y - 3, total + 6, 18}, 0.4, 4, {10, 12, 18, 150})
	for en in entries {
		if !en.on do continue
		rl.DrawLineEx({x, y + 6}, {x + 14, y + 6}, en.thick, en.color)
		x += 20
		l := fmt.ctprintf("%s", en.label)
		text.draw(l, i32(x), i32(y), 11, {170, 180, 200, 255})
		x += f32(text.measure(l, 11)) + 12
	}
}
