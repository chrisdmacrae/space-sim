package render

// Draws a generated star system: orbits, belts, bodies, stations, labels.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import text "sim:text"
import art "sim:art"
import core "sim:core"
import gen "sim:gen"
import orbit "sim:orbit"

ORBIT_COLOR   :: rl.Color{70, 90, 130, 150}
MOON_ORBIT    :: rl.Color{90, 100, 130, 110}
STATION_ORBIT :: rl.Color{110, 90, 70, 110}
SOI_COLOR     :: rl.Color{60, 140, 120, 70}
LABEL_COLOR   :: rl.Color{170, 180, 200, 220}
BELT_COLOR    :: rl.Color{150, 140, 120, 140}

// Elliptic orbit as a polyline around its parent's current position.
draw_orbit :: proc(cam: ^Camera, o: orbit.Orbit, center: [2]f64, color: rl.Color) {
	if o.e >= 1 do return
	r_px := o.a * cam.zoom
	if r_px < 2 do return
	n := clamp(int(r_px * 0.35), 48, 4096)
	step := 2 * math.PI / f64(n)
	prev := world_to_screen(cam, center + orbit.point_at_E(o, 0))
	prev_in := on_screen(prev, 64)
	for i in 1 ..= n {
		cur := world_to_screen(cam, center + orbit.point_at_E(o, step * f64(i)))
		cur_in := on_screen(cur, 64)
		if prev_in || cur_in do rl.DrawLineV({prev.x, prev.y}, {cur.x, cur.y}, color)
		prev, prev_in = cur, cur_in
	}
}

body_doc_name :: proc(b: gen.Body) -> string {
	if b.is_moon do return fmt.tprintf("moon_%d", b.variant)
	switch b.kind {
	case .Star:        return "star"
	case .Molten:      return fmt.tprintf("molten_%d", b.variant)
	case .Rock:        return fmt.tprintf("rock_%d", b.variant)
	case .Atmospheric: return fmt.tprintf("atmospheric_%d", b.variant)
	case .Gas:         return fmt.tprintf("gas_%d", b.variant)
	case .Ice:         return fmt.tprintf("ice_%d", b.variant)
	}
	return "rock_0"
}

// Where a body's name label sits on screen; shared by drawing and picking.
body_label_rect :: proc(cam: ^Camera, b: gen.Body, pos: [2]f64) -> rl.Rectangle {
	sp := world_to_screen(cam, pos)
	r_px := f32(max(b.radius * cam.zoom, f64(core.tuning.body_min_px)))
	w := f32(text.measure(fmt.ctprintf("%s", b.name), 12))
	return {sp.x + r_px + 5, sp.y - 7, w, 14}
}

// On-screen radius of a station's icon. Drawing floors the document to an icon
// when it is small, so labels and picking have to floor the same way or they
// drift off the art.
station_radius_px :: proc(cam: ^Camera) -> f32 {
	px := max(core.STATION_DOC_SCALE * cam.zoom, station_floor_px_per_unit())
	return f32(px * core.STATION_DOC_HALF)
}

// The floor spread over the envelope every station document fits, so all five
// bottom out at the same size rather than at their own slightly different spans.
station_floor_px_per_unit :: proc() -> f64 {
	return f64(core.tuning.station_min_px) / (2 * core.STATION_DOC_HALF)
}

station_label_rect :: proc(cam: ^Camera, s: gen.Station, pos: [2]f64) -> rl.Rectangle {
	sp := world_to_screen(cam, pos)
	w := f32(text.measure(fmt.ctprintf("%s", s.name), 11))
	return {sp.x + station_radius_px(cam) + 5, sp.y - 7, w, 13}
}

// Lighting overlays drawn over a body's document: the night side away from
// the star, a soft terminator, limb darkening, and an atmosphere rim.
draw_body_shading :: proc(cam: ^Camera, b: gen.Body, pos, star_pos: [2]f64, r_px: f32) {
	if r_px < 5 do return
	sp := world_to_screen(cam, pos)
	c := rl.Vector2{sp.x, sp.y}
	d := star_pos - pos
	l := orbit.length(d)
	if l < 1e-9 do return
	// Light direction on screen (y flipped).
	lx := f32(d.x / l)
	ly := f32(-d.y / l)
	ang := math.atan2(ly, lx)
	// Night half: the semicircle facing away from the light.
	N :: 26
	pts: [N + 2]rl.Vector2
	pts[0] = c
	for i in 0 ..= N {
		a := ang + math.PI / 2 + math.PI * f32(i) / N
		pts[i + 1] = {c.x + math.cos(a) * r_px, c.y + math.sin(a) * r_px}
	}
	rl.DrawTriangleFan(&pts[0], N + 2, {0, 0, 8, 150})
	// Soft terminator: a thin lens on the day side of the diameter.
	for k in 1 ..= 3 {
		off := r_px * 0.06 * f32(k)
		lens: [N + 2]rl.Vector2
		for i in 0 ..= N {
			a := ang + math.PI / 2 + math.PI * f32(i) / N
			// points on the diameter, pushed toward the light by `off`
			t := f32(i) / N
			x := c.x + math.cos(ang + math.PI / 2) * r_px * (1 - 2 * t)
			y := c.y + math.sin(ang + math.PI / 2) * r_px * (1 - 2 * t)
			lens[i] = {x + lx * off, y + ly * off}
			_ = a
		}
		lens[N + 1] = lens[0]
		rl.DrawLineStrip(&lens[0], N + 2, {0, 0, 8, u8(70 - 18 * k)})
	}
	// Limb darkening.
	rl.DrawRing(c, r_px * 0.90, r_px * 1.0, 0, 360, 40, {0, 0, 10, 45})
	rl.DrawRing(c, r_px * 0.97, r_px * 1.0, 0, 360, 40, {0, 0, 10, 60})
	// Atmosphere rim.
	#partial switch b.kind {
	case .Atmospheric:
		rl.DrawRing(c, r_px * 1.0, r_px * 1.06, 0, 360, 40, {120, 170, 255, 90})
		rl.DrawRing(c, r_px * 1.06, r_px * 1.14, 0, 360, 40, {120, 170, 255, 35})
		// Day-side sun glint.
		rl.DrawCircleV({c.x + lx * r_px * 0.55, c.y + ly * r_px * 0.55}, r_px * 0.18, {255, 255, 255, 40})
	case .Gas:
		rl.DrawRing(c, r_px * 1.0, r_px * 1.04, 0, 360, 40, {255, 240, 220, 60})
	case .Ice:
		rl.DrawCircleV({c.x + lx * r_px * 0.5, c.y + ly * r_px * 0.5}, r_px * 0.2, {255, 255, 255, 35})
	}
}

// Star: a gradient glow in code, then the document's core.
draw_star :: proc(cam: ^Camera, doc: ^art.Doc, sys: ^gen.System, b: gen.Body, pos: [2]f64) {
	sp := world_to_screen(cam, pos)
	glow := f64(core.tuning.star_glow_scale)
	star := sys.star
	r_px := f32(max(b.radius * cam.zoom, f64(core.tuning.body_min_px)))
	col := rl.Color{b.colors[0][0], b.colors[0][1], b.colors[0][2], 255}
	if col.r == 0 && col.g == 0 && col.b == 0 do col = {255, 220, 150, 255}
	// The heat line: a faint warning ring wherever it is bigger than the star.
	heat_px := f32(star.heat_radius * cam.zoom)
	if heat_px > r_px * 1.2 && heat_px < 6000 {
		rl.DrawRing({sp.x, sp.y}, heat_px - 1, heat_px + 1, 0, 360, 96, {255, 90, 60, 55})
	}
	switch star.kind {
	case .Main_Sequence, .Giant, .Supergiant, .White_Dwarf:
		halo := star.kind == .White_Dwarf ? 0.6 : 1.0
		rl.DrawCircleGradient({sp.x, sp.y}, r_px * f32(3.2 * glow * halo), rl.Color{col.r, col.g, col.b, 60}, rl.Color{col.r, col.g, col.b, 0})
		rl.DrawCircleGradient({sp.x, sp.y}, r_px * f32(1.6 * glow), rl.Color{col.r, col.g, col.b, 120}, rl.Color{col.r, col.g, col.b, 0})
		ov := [1]art.Override{{"star_core", b.colors[0]}}
		draw_doc_world(cam, doc, "core_only", pos, 0, b.radius, f64(core.tuning.body_min_px), ov[:])
		rl.DrawCircleV({sp.x, sp.y}, r_px * 0.98, {col.r, col.g, col.b, 110})
		rl.DrawCircleV({sp.x - r_px * 0.2, sp.y - r_px * 0.2}, r_px * 0.5, {255, 255, 255, 70})
	case .Brown_Dwarf:
		// Barely glowing: a dull ember with banded cloud tops.
		rl.DrawCircleGradient({sp.x, sp.y}, r_px * 1.8, rl.Color{col.r, col.g, col.b, 50}, rl.Color{col.r, col.g, col.b, 0})
		rl.DrawCircleV({sp.x, sp.y}, r_px, {110, 45, 60, 255})
		rl.DrawCircleV({sp.x, sp.y}, r_px * 0.92, col)
		rl.DrawCircleV({sp.x, sp.y}, r_px * 0.55, {200, 95, 100, 120})
		rl.DrawCircleV({sp.x - r_px * 0.25, sp.y - r_px * 0.25}, r_px * 0.35, {255, 200, 190, 40})
	case .Neutron, .Pulsar:
		// A pinprick with a hard blue-white glow; the pulsar adds a wind
		// haze and two sweeping beams, turning on the wall clock so warp
		// does not spin them into a blur.
		if star.wind_radius > 0 {
			wind_px := f32(star.wind_radius * cam.zoom)
			if wind_px < 8000 {
				rl.DrawCircleGradient({sp.x, sp.y}, wind_px, {120, 170, 255, 34}, {120, 170, 255, 0})
				rl.DrawRing({sp.x, sp.y}, wind_px - 1, wind_px + 1, 0, 360, 128, {120, 170, 255, 60})
			}
			ang := star.spin * rl.GetTime()
			length := f32(min(star.wind_radius * 0.9 * cam.zoom, 4000))
			half := max(length * 0.045, 2)
			for k in 0 ..< 2 {
				a := ang + f64(k) * math.PI - cam.angle
				dx := f32(math.cos(a))
				dy := f32(math.sin(a))
				tip := rl.Vector2{sp.x + dx * length, sp.y + dy * length}
				l := rl.Vector2{sp.x - dy * half, sp.y + dx * half}
				r := rl.Vector2{sp.x + dy * half, sp.y - dx * half}
				rl.DrawTriangle(l, tip, r, {170, 210, 255, 70})
				rl.DrawTriangle(r, tip, l, {170, 210, 255, 70})
				rl.DrawLineEx({sp.x, sp.y}, tip, 1.5, {220, 240, 255, 120})
			}
		}
		core_px := max(r_px, 3)
		rl.DrawCircleGradient({sp.x, sp.y}, core_px * 9, {150, 190, 255, 90}, {150, 190, 255, 0})
		rl.DrawCircleGradient({sp.x, sp.y}, core_px * 3.5, {210, 230, 255, 170}, {210, 230, 255, 0})
		rl.DrawCircleV({sp.x, sp.y}, core_px, {245, 250, 255, 255})
	}
}

// One document per kind, so a yard reads as a yard at a glance and not as a
// recoloured marker (tools/gen_stations.py).
station_doc_name :: proc(k: gen.Station_Kind) -> string {
	switch k {
	case .Hub:      return "station_hub"
	case .Shipyard: return "station_shipyard"
	case .Refinery: return "station_refinery"
	case .Depot:    return "station_depot"
	case .Habitat:  return "station_habitat"
	}
	return "station_hub"
}

station_color :: proc(k: gen.Station_Kind) -> [4]u8 {
	switch k {
	case .Hub:      return {232, 122, 58, 255}
	case .Shipyard: return {122, 204, 240, 255}
	case .Refinery: return {200, 160, 80, 255}
	case .Depot:    return {120, 220, 140, 255}
	case .Habitat:  return {220, 140, 220, 255}
	}
	return {255, 255, 255, 255}
}

draw_system :: proc(cam: ^Camera, sys: ^gen.System, lib: ^art.Library, t: f64) {
	flags := core.debug
	star_pos := sys.pos[0]

	// ---- orbits
	if flags.show_orbits {
		for &b, i in sys.bodies {
			if i == 0 do continue
			color := b.is_moon ? MOON_ORBIT : ORBIT_COLOR
			draw_orbit(cam, b.orbit, sys.pos[b.parent], color)
		}
		for &s in sys.stations {
			if s.orbit.a * cam.zoom > 20 do draw_orbit(cam, s.orbit, sys.pos[s.parent], STATION_ORBIT)
		}
	}

	// ---- belts: each chunk on its own circular orbit, hashed from the belt seed
	if flags.show_belts {
		for &belt in sys.belts {
			r_px := belt.radius * cam.zoom
			if r_px < 4 do continue
			mu := sys.bodies[0].mu
			for k in 0 ..< belt.count {
				h1 := core.mix64(belt.seed ~ u64(k) * 0x9E3779B97F4A7C15)
				h2 := core.mix64(h1)
				u1 := f64(h1 >> 11) * (1.0 / 9007199254740992.0)
				u2 := f64(h2 >> 11) * (1.0 / 9007199254740992.0)
				rad := belt.radius + (u2 - 0.5) * belt.width * 2
				n := math.sqrt(mu / (rad * rad * rad))
				ang := u1 * 2 * math.PI + n * t
				p := world_to_screen(cam, star_pos + {rad * math.cos(ang), rad * math.sin(ang)})
				if !on_screen(p, 4) do continue
				if r_px > 3000 {
					rl.DrawCircleV({p.x, p.y}, 1.5, BELT_COLOR)
				} else {
					rl.DrawPixelV({p.x, p.y}, BELT_COLOR)
				}
			}
		}
	}

	// ---- SOI rings
	if flags.show_soi {
		for &b, i in sys.bodies {
			if i == 0 do continue
			if b.soi * cam.zoom > 6 do draw_orbit_circle(cam, sys.pos[i], b.soi, SOI_COLOR)
		}
	}

	// ---- bodies
	for &b, i in sys.bodies {
		p := sys.pos[i]
		sp := world_to_screen(cam, p)
		if !on_screen(sp, f32(b.radius * cam.zoom) + 64) do continue
		doc := art.library_get(lib, body_doc_name(b))
		if doc == nil do continue
		ov := [6]art.Override {
			{"surface", b.colors[0]},
			{"surface2", b.colors[1]},
			{"feature", b.colors[2]},
			{"feature2", b.colors[3]},
			{"accent", b.colors[4]},
			{"highlight", b.colors[5]},
		}
		if b.kind == .Star {
			draw_star(cam, doc, sys, b, p)
		} else {
			r_px := f32(max(b.radius * cam.zoom, f64(core.tuning.body_min_px)))
			if r_px < 6 {
				// Too small for detail: a disc in the surface colour is all that shows.
				rl.DrawCircleV({sp.x, sp.y}, r_px, art.to_color(b.colors[0]))
				continue
			}
			draw_doc_world(cam, doc, "", p, b.spin * t, b.radius, f64(core.tuning.body_min_px), ov[:])
			if core.gfx.shading do draw_body_shading(cam, b, p, star_pos, r_px)
		}
	}

	// ---- stations
	for &s, i in sys.stations {
		p := sys.station_pos[i]
		sp := world_to_screen(cam, p)
		if !on_screen(sp, station_radius_px(cam) + 32) do continue
		// Stations are only worth drawing once their orbit separates from the host.
		if s.parent != gen.STAR && s.orbit.a * cam.zoom < 6 do continue
		station_doc := art.library_get(lib, station_doc_name(s.kind))
		if station_doc == nil do continue
		ov := [1]art.Override{{"station_accent", station_color(s.kind)}}
		draw_doc_world(cam, station_doc, "", p, 0, core.STATION_DOC_SCALE, station_floor_px_per_unit(), ov[:])
	}

	// ---- nebula names, set at the middle of the cloud. A cloud has no
	// surface to hang a label off, so the name sits in the gas itself.
	if flags.show_labels {
		for &n in sys.nebulae {
			if n.radius * cam.zoom < 40 do continue
			p := world_to_screen(cam, star_pos + gen.nebula_label_point(n))
			if !on_screen(p, 0) do continue
			// Lifted off the gas: a name in the cloud's own colour over the
			// cloud's own colour is unreadable without a plate behind it.
			c := rl.Color{n.colors[0][0], n.colors[0][1], n.colors[0][2], 255}
			lr := nebula_label_rect(cam, n, star_pos)
			kind := fmt.ctprintf("%s", gen.nebula_describe(n.kind))
			w := max(lr.width, f32(text.measure(kind, 11)))
			rl.DrawRectangleRounded({lr.x - 6, lr.y - 4, w + 12, 36}, 0.25, 4, {3, 4, 8, 190})
			text.draw(fmt.ctprintf("%s", n.name), i32(lr.x), i32(lr.y), 13, c)
			text.draw(kind, i32(lr.x), i32(lr.y + 16), 11, {c.r, c.g, c.b, 170})
		}
	}

	// ---- labels
	if flags.show_labels {
		min_orbit := f64(core.tuning.label_min_orbit_px)
		for &b, i in sys.bodies {
			if i == 0 do continue
			if b.orbit.a * cam.zoom < min_orbit do continue
			sp := world_to_screen(cam, sys.pos[i])
			if !on_screen(sp, 0) do continue
			lr := body_label_rect(cam, b, sys.pos[i])
			text.draw(fmt.ctprintf("%s", b.name), i32(lr.x), i32(lr.y), 12, LABEL_COLOR)
		}
		for &s, i in sys.stations {
			if s.parent != gen.STAR && s.orbit.a * cam.zoom < min_orbit do continue
			sp := world_to_screen(cam, sys.station_pos[i])
			if !on_screen(sp, 0) do continue
			lr := station_label_rect(cam, s, sys.station_pos[i])
			text.draw(fmt.ctprintf("%s", s.name), i32(lr.x), i32(lr.y), 11, art.to_color(station_color(s.kind)))
		}
	}
}

// Where a nebula's name sits on screen; shared by drawing and picking.
nebula_label_rect :: proc(cam: ^Camera, n: gen.Nebula, star_pos: [2]f64) -> rl.Rectangle {
	p := world_to_screen(cam, star_pos + gen.nebula_label_point(n))
	w := f32(text.measure(fmt.ctprintf("%s", n.name), 13))
	return {p.x - w * 0.5, p.y - 8, w, 15}
}

// Highlight ring around a focused point.
draw_focus_ring :: proc(cam: ^Camera, pos: [2]f64, radius_px: f32) {
	p := world_to_screen(cam, pos)
	rl.DrawCircleLinesV({p.x, p.y}, radius_px, {122, 204, 240, 200})
}
