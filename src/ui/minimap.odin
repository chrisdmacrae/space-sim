package ui

// Minimap of the whole system in the top right, with the camera's view box
// and a Refocus button. Clicking the map looks there.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import gen "sim:gen"
import text "sim:text"

MINIMAP :: 200

Minimap_View :: struct {
	sys:        ^gen.System,
	ship_pos:   [2]f64,
	cam_center: [2]f64,
	cam_half:   [2]f64, // half the view size in world units
	cam_angle:  f64,    // view rotation
	npc_pos:    [][2]f64,
	following:  bool,
	title:      string, // system name
	subtitle:   string, // seed and index
	following_name: string, // entity being followed when it is not the ship
}

minimap_draw :: proc(v: Minimap_View) -> (look: [2]f64, clicked: bool, refocus: bool, hot: bool) {
	sw := f32(rl.GetScreenWidth())
	r := rl.Rectangle{sw - MINIMAP - 8, BAR_H + 8, MINIMAP, MINIMAP}
	mouse := rl.GetMousePosition()
	btn := rl.Rectangle{r.x, r.y + r.height + 6, r.width, 24}
	hot = rl.CheckCollisionPointRec(mouse, r) || rl.CheckCollisionPointRec(mouse, btn)
	rl.DrawRectangleRounded(r, 0.04, 4, {8, 10, 16, 220})
	rl.DrawRectangleRoundedLinesEx(r, 0.04, 4, 1, BAR_LINE)
	// Caption: the system this map shows.
	text.draw(fmt.ctprintf("%s", v.title), i32(r.x + 8), i32(r.y + 6), 14, TEXT_MAIN)
	text.draw(fmt.ctprintf("%s", v.subtitle), i32(r.x + 8), i32(r.y + 24), 11, TEXT_DIM)
	extent := max(v.sys.extent, 1)
	scale := f32((MINIMAP - 40) * 0.48 / extent)
	cx := r.x + r.width * 0.5
	cy := r.y + 40 + (r.height - 40) * 0.5
	to := proc(cx, cy, scale: f32, p: [2]f64) -> rl.Vector2 {
		return {cx + f32(p.x) * scale, cy - f32(p.y) * scale}
	}
	rl.BeginScissorMode(i32(r.x), i32(r.y + 40), i32(r.width), i32(r.height - 40))
	for &b, i in v.sys.bodies {
		if i == 0 || b.parent != gen.STAR do continue
		rl.DrawCircleLinesV({cx, cy}, f32(b.orbit.a) * scale, {50, 60, 85, 255})
	}
	for &b, i in v.sys.bodies {
		p := to(cx, cy, scale, v.sys.pos[i])
		if i == 0 {
			rl.DrawCircleV(p, 3, {255, 220, 150, 255})
			continue
		}
		if b.is_moon do continue
		rl.DrawCircleV(p, 2, {b.colors[0][0], b.colors[0][1], b.colors[0][2], 255})
	}
	for i in 0 ..< len(v.sys.stations) {
		p := to(cx, cy, scale, v.sys.station_pos[i])
		rl.DrawPixelV(p, {180, 190, 210, 255})
	}
	for np in v.npc_pos do rl.DrawPixelV(to(cx, cy, scale, np), {200, 190, 150, 200})
	// Camera view box.
	{
		hw := max(f32(v.cam_half.x) * scale, 1)
		hh := max(f32(v.cam_half.y) * scale, 1)
		cs := f32(math.cos(v.cam_angle))
		sn := f32(math.sin(v.cam_angle))
		corners := [4][2]f32{{-hw, -hh}, {hw, -hh}, {hw, hh}, {-hw, hh}}
		pts: [4]rl.Vector2
		for k in 0 ..< 4 {
			// The map is y-down like the screen; undo the view turn so the box shows what the view covers.
			x := corners[k].x
			y := corners[k].y
			wx := cs * x + sn * y
			wy := -sn * x + cs * y
			p := to(cx, cy, scale, v.cam_center)
			pts[k] = {p.x + wx, p.y + wy}
		}
		for k in 0 ..< 4 do rl.DrawLineV(pts[k], pts[(k + 1) % 4], {120, 160, 255, 160})
	}
	// Ship.
	s := to(cx, cy, scale, v.ship_pos)
	rl.DrawCircleLinesV(s, 4, {150, 230, 170, 255})
	rl.DrawCircleV(s, 1.5, {150, 230, 170, 255})
	rl.EndScissorMode()
	if rl.CheckCollisionPointRec(mouse, r) && rl.IsMouseButtonPressed(.LEFT) {
		look = {f64((mouse.x - cx) / scale), f64(-(mouse.y - cy) / scale)}
		clicked = true
	}
	// Refocus button.
	over := rl.CheckCollisionPointRec(mouse, btn)
	rl.DrawRectangleRounded(btn, 0.3, 4, v.following ? rl.Color{22, 26, 36, 255} : (over ? HOVER_BG : rl.Color{30, 36, 50, 255}))
	label: cstring = v.following ? "Following ship" : (v.following_name != "" ? fmt.ctprintf("Following %s   (F: ship)", v.following_name) : "Refocus ship  (F)")
	tw := f32(text.measure(label, 13))
	text.draw(label, i32(btn.x + (btn.width - tw) * 0.5), i32(btn.y + 5), 13, v.following ? TEXT_DIM : TEXT_MAIN)
	if over && rl.IsMouseButtonPressed(.LEFT) && !v.following do refocus = true
	_ = math.PI
	return
}
