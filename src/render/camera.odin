package render

// Floating-origin camera. World is f64 and y-up; the screen is f32 and
// y-down. Every conversion subtracts the camera target first so precision is
// spent near the viewer, never at the origin.

import "core:math"
import rl "vendor:raylib"
import input "sim:input"
import art "sim:art"
import core "sim:core"

Camera :: struct {
	target: [2]f64, // world units
	zoom:   f64,    // screen px per world unit
	follow: bool,
	angle:  f64,    // view rotation, radians: the world is turned by this before projection
}

ROTATE_RATE :: 1.6 // radians per second while a rotate key is held

// World offset from the target, turned by the view angle.
@(private = "file")
turn :: proc(d: [2]f64, a: f64) -> [2]f64 {
	c := math.cos(a)
	s := math.sin(a)
	return {c * d.x - s * d.y, s * d.x + c * d.y}
}

// A screen-space delta (px, y down) as a world delta at the current view.
screen_delta_to_world :: proc(cam: ^Camera, d: [2]f32) -> [2]f64 {
	return turn({f64(d.x) / cam.zoom, -f64(d.y) / cam.zoom}, -cam.angle)
}

// Screen rotation for a world heading under the current view.
screen_rot :: proc(cam: ^Camera, heading: f64) -> f32 {
	return f32(-(heading + cam.angle)) // y-up world to y-down screen flips rotation
}

ZOOM_MIN :: 0.0005
ZOOM_MAX :: 480.0 // a courier (0.42 units) spans ~200 px: a tenth of the screen and more

screen_center :: proc() -> [2]f64 {
	return {f64(rl.GetScreenWidth()) * 0.5, f64(rl.GetScreenHeight()) * 0.5}
}

world_to_screen :: proc(cam: ^Camera, w: [2]f64) -> [2]f32 {
	c := screen_center()
	d := turn(w - cam.target, cam.angle)
	return {f32(c.x + d.x * cam.zoom), f32(c.y - d.y * cam.zoom)}
}

screen_to_world :: proc(cam: ^Camera, s: [2]f32) -> [2]f64 {
	c := screen_center()
	d := [2]f64{(f64(s.x) - c.x) / cam.zoom, -(f64(s.y) - c.y) / cam.zoom}
	return cam.target + turn(d, -cam.angle)
}

// Pan and zoom input. `ui_hot` suppresses input the UI already consumed.
camera_update :: proc(cam: ^Camera, real_dt: f64, ui_hot: bool) {
	if ui_hot do return
	mouse := rl.GetMousePosition()

	if wheel := f64(rl.GetMouseWheelMove()); wheel != 0 {
		before := screen_to_world(cam, {mouse.x, mouse.y})
		cam.zoom = clamp(cam.zoom * math.pow(1.18, wheel), ZOOM_MIN, ZOOM_MAX)
		after := screen_to_world(cam, {mouse.x, mouse.y})
		cam.target += before - after // keep the world point under the cursor fixed
	}

	if rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.MIDDLE) {
		d := rl.GetMouseDelta()
		if d.x != 0 || d.y != 0 {
			cam.target -= screen_delta_to_world(cam, {d.x, d.y})
			cam.follow = false
		}
	}

	// Pan keys move in screen directions, whatever the rotation.
	pan: [2]f64
	if input.down(.Pan_Up) do pan.y += 1
	if input.down(.Pan_Down) do pan.y -= 1
	if input.down(.Pan_Left) do pan.x -= 1
	if input.down(.Pan_Right) do pan.x += 1
	if pan != 0 {
		speed := 700.0 / cam.zoom // px/s in world units
		cam.target += turn(pan, -cam.angle) * speed * real_dt
		cam.follow = false
	}
	if input.down(.Rotate_Left) do cam.angle -= ROTATE_RATE * real_dt
	if input.down(.Rotate_Right) do cam.angle += ROTATE_RATE * real_dt
	if input.pressed(.Rotate_Reset) do cam.angle = 0
	if cam.angle > math.PI do cam.angle -= 2 * math.PI
	if cam.angle < -math.PI do cam.angle += 2 * math.PI
}

// Turn the view so a world heading points up the screen.
camera_face :: proc(cam: ^Camera, heading: f64) {
	cam.angle = math.PI / 2 - heading
}

// Where a document lands on screen. `world_per_unit` is world units per
// document unit; `min_px_per_unit` floors the on-screen size so small things
// stay visible as icons when zoomed out.
doc_xform :: proc(
	cam: ^Camera,
	pos: [2]f64,
	heading: f64, // world radians, counter-clockwise, 0 = +x
	world_per_unit: f64,
	min_px_per_unit: f64 = 0,
) -> art.Xform {
	return {
		origin = world_to_screen(cam, pos),
		px     = f32(max(world_per_unit * cam.zoom, min_px_per_unit)),
		rot    = screen_rot(cam, heading),
	}
}

// Draw a document at a world position, in a named state.
draw_doc_world :: proc(
	cam: ^Camera,
	doc: ^art.Doc,
	state: string,
	pos: [2]f64,
	heading: f64,
	world_per_unit: f64,
	min_px_per_unit: f64 = 0,
	overrides: art.Overrides = nil,
) {
	art.draw_doc(doc, state, doc_xform(cam, pos, heading, world_per_unit, min_px_per_unit), overrides)
}

// The same, in a pose sampled from a clip (see render/ship_anim.odin).
draw_poses_world :: proc(
	cam: ^Camera,
	doc: ^art.Doc,
	poses: []art.State_Part,
	pos: [2]f64,
	heading: f64,
	world_per_unit: f64,
	min_px_per_unit: f64 = 0,
	overrides: art.Overrides = nil,
) {
	art.draw_poses(doc, poses, doc_xform(cam, pos, heading, world_per_unit, min_px_per_unit), overrides)
}

// A finished on-screen size expressed as the per-document-unit floor that
// draw_doc_world takes. Documents differ in size — a courier spans 29 units, a
// freighter 61 — so a floor only means the same thing across them once it is
// divided through by the document's own extent.
doc_min_px_per_unit :: proc(doc: ^art.Doc, want_px: f64) -> f64 {
	lo, hi := art.doc_bounds(doc)
	span := f64(max(hi.x - lo.x, hi.y - lo.y))
	return span > 0 ? want_px / span : 0
}

// Screen-space visibility test with a margin, for culling.
on_screen :: proc(p: [2]f32, margin: f32) -> bool {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	return p.x > -margin && p.x < w + margin && p.y > -margin && p.y < h + margin
}

// Frame a radius around a point.
camera_fit :: proc(cam: ^Camera, center: [2]f64, radius: f64) {
	c := screen_center()
	cam.target = center
	cam.zoom = clamp(min(c.x, c.y) / (radius * 1.08), ZOOM_MIN, ZOOM_MAX)
}

// Circle as a polyline whose segment count follows the on-screen radius, so
// it stays smooth when zoomed in. Segments entirely off-screen are skipped.
draw_orbit_circle :: proc(cam: ^Camera, center: [2]f64, radius: f64, color: rl.Color) {
	r_px := radius * cam.zoom
	n := clamp(int(r_px * 0.35), 48, 4096)
	w := f64(rl.GetScreenWidth())
	h := f64(rl.GetScreenHeight())
	margin := 64.0
	on_screen :: proc(p: [2]f32, w, h, m: f64) -> bool {
		return f64(p.x) > -m && f64(p.x) < w + m && f64(p.y) > -m && f64(p.y) < h + m
	}
	step := 2 * math.PI / f64(n)
	prev := world_to_screen(cam, center + {radius, 0})
	prev_in := on_screen(prev, w, h, margin)
	for i in 1 ..= n {
		a := step * f64(i)
		cur := world_to_screen(cam, center + {radius * math.cos(a), radius * math.sin(a)})
		cur_in := on_screen(cur, w, h, margin)
		if prev_in || cur_in {
			rl.DrawLineV({prev.x, prev.y}, {cur.x, cur.y}, color)
		}
		prev, prev_in = cur, cur_in
	}
}

// Static background stars with a touch of parallax. Seeded once.
STARFIELD_N :: 600

Starfield :: struct {
	pts: [STARFIELD_N][3]f32, // x, y in [0,1), depth in (0,1]
}

starfield_init :: proc(sf: ^Starfield, seed: u64) {
	s := seed
	next :: proc(s: ^u64) -> f32 {
		s^ += 0x9E3779B97F4A7C15
		z := s^
		z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
		z = (z ~ (z >> 27)) * 0x94D049BB133111EB
		z = z ~ (z >> 31)
		return f32(z >> 40) / f32(1 << 24)
	}
	for &p in sf.pts {
		p = {next(&s), next(&s), 0.2 + 0.8 * next(&s)}
	}
}

draw_starfield :: proc(sf: ^Starfield, cam: ^Camera) {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	// Parallax is a tiny fraction of the pan so the field reads as distant.
	ox := f32(math.mod(cam.target.x * 0.002, 1.0))
	oy := f32(math.mod(-cam.target.y * 0.002, 1.0))
	limit := int(clamp(f32(STARFIELD_N) * core.gfx.star_density, 0, STARFIELD_N))
	for p, i in sf.pts {
		if i >= limit do break
		x := math.mod(p.x + ox * p.z + 2, 1) * w
		y := math.mod(p.y + oy * p.z + 2, 1) * h
		a := u8(60 + 160 * p.z)
		if p.z > 0.85 {
			rl.DrawCircleV({x, y}, 1.2, {220, 228, 255, a})
		} else {
			rl.DrawPixelV({x, y}, {200, 210, 240, a})
		}
	}
}

_ :: core
