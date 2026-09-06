package render

// Draws the predicted path (docs/DESIGN.md §4.4). Each segment is drawn in
// its primary's frame placed where that primary will be when the ship gets
// there, so a flyby appears around the planet's future position.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import text "sim:text"
import core "sim:core"
import gen "sim:gen"
import orbit "sim:orbit"
import sim "sim:sim"

SEGMENT_COLORS := [?]rl.Color {
	{150, 190, 255, 230},
	{220, 170, 90, 210},
	{150, 230, 170, 190},
	{230, 130, 200, 170},
	{200, 200, 200, 150},
}

NODE_COLOR     :: rl.Color{255, 220, 120, 230}
NODE_SELECTED  :: rl.Color{255, 250, 200, 255}

// Base position for a segment: the primary where it is now for the current
// segment, else where it will be when the segment starts.
// A segment around the body the ship is orbiting now is drawn around that
// body's present position, so a planned burn shows the new orbit where the
// player is looking. Only a segment around a different body (an encounter)
// is drawn where that body will be when the ship arrives.
segment_base :: proc(sys: ^gen.System, segs: []sim.Segment, i: int) -> [2]f64 {
	seg := segs[i]
	if i == 0 || seg.primary == segs[0].primary do return sys.pos[seg.primary]
	return sim.body_pos_at(sys, seg.primary, seg.t0)
}

// World position of the node that ends segment i.
node_world_pos :: proc(sys: ^gen.System, segs: []sim.Segment, i: int) -> [2]f64 {
	return segment_base(sys, segs, i) + orbit.position_at(segs[i].orbit, segs[i].t1)
}

draw_prediction :: proc(cam: ^Camera, sys: ^gen.System, segs: []sim.Segment, nodes: []sim.Node, selected: int, t_now: f64) {
	for seg, i in segs {
		color := SEGMENT_COLORS[min(i, len(SEGMENT_COLORS) - 1)]
		base := segment_base(sys, segs, i)
		draw_arc(cam, seg.orbit, base, seg.t0, seg.t1, color)

		switch seg.end {
		case .Node:
			if seg.node < 0 || seg.node >= len(nodes) do continue
			n := nodes[seg.node]
			rp, rv := orbit.state_at(seg.orbit, seg.t1)
			sp := world_to_screen(cam, base + rp)
			if !on_screen(sp, 20) do continue
			is_sel := seg.node == selected
			c := is_sel ? NODE_SELECTED : NODE_COLOR
			rl.DrawCircleLinesV({sp.x, sp.y}, is_sel ? 9 : 7, c)
			rl.DrawCircleV({sp.x, sp.y}, 2.5, c)
			// Burn direction arrow (screen y is down).
			dv := sim.node_dv_world(n, rp, rv)
			if l := orbit.length(dv); l > 0 {
				d := dv / l
				rl.DrawLineEx({sp.x, sp.y}, {sp.x + f32(d.x) * 22, sp.y - f32(d.y) * 22}, 2, c)
			}
			text.draw(fmt.ctprintf("dv %.4f in %s", sim.node_dv(n), core.clock_duration(seg.t1 - t_now)), i32(sp.x + 12), i32(sp.y - 16), 12, c)
		case .Enter:
			// Ghost of the target where the encounter happens.
			tb := sys.bodies[seg.target]
			gp := sim.body_pos_at(sys, seg.target, seg.t1)
			sp := world_to_screen(cam, gp)
			r := f32(max(tb.radius * cam.zoom, 3))
			rl.DrawCircleLinesV({sp.x, sp.y}, r, color)
			if tb.soi * cam.zoom > 8 do draw_orbit_circle(cam, gp, tb.soi, {color.r, color.g, color.b, 70})
			text.draw(fmt.ctprintf("%s in %s", tb.name, core.clock_duration(seg.t1 - t_now)), i32(sp.x + r + 6), i32(sp.y + 8), 12, color)
		case .Exit:
			ep := base + orbit.position_at(seg.orbit, seg.t1)
			sp := world_to_screen(cam, ep)
			rl.DrawCircleLinesV({sp.x, sp.y}, 4, color)
			text.draw(fmt.ctprintf("exit in %s", core.clock_duration(seg.t1 - t_now)), i32(sp.x + 8), i32(sp.y + 4), 12, color)
		case .Collide:
			cp := base + orbit.position_at(seg.orbit, seg.t1)
			sp := world_to_screen(cam, cp)
			rl.DrawLineEx({sp.x - 6, sp.y - 6}, {sp.x + 6, sp.y + 6}, 2, {255, 80, 80, 255})
			rl.DrawLineEx({sp.x - 6, sp.y + 6}, {sp.x + 6, sp.y - 6}, 2, {255, 80, 80, 255})
			text.draw(fmt.ctprintf("impact in %s", core.clock_duration(seg.t1 - t_now)), i32(sp.x + 10), i32(sp.y + 4), 12, {255, 120, 120, 255})
		case .Horizon:
		}
	}
	// Periapsis/apoapsis of the current conic.
	if len(segs) > 0 {
		seg := segs[0]
		base := sys.pos[seg.primary]
		pe := base + orbit.point_at_anomaly(seg.orbit, 0)
		sp := world_to_screen(cam, pe)
		if on_screen(sp, 0) {
			rl.DrawCircleV({sp.x, sp.y}, 2.5, {150, 190, 255, 255})
			text.draw(fmt.ctprintf("Pe %.0f", orbit.periapsis(seg.orbit) - sys.bodies[seg.primary].radius), i32(sp.x + 5), i32(sp.y - 14), 11, {150, 190, 255, 220})
		}
		if seg.orbit.e < 1 {
			ap := base + orbit.point_at_anomaly(seg.orbit, math.PI)
			sp = world_to_screen(cam, ap)
			if on_screen(sp, 0) {
				rl.DrawCircleV({sp.x, sp.y}, 2.5, {150, 190, 255, 255})
				text.draw(fmt.ctprintf("Ap %.0f", orbit.apoapsis(seg.orbit) - sys.bodies[seg.primary].radius), i32(sp.x + 5), i32(sp.y - 14), 11, {150, 190, 255, 220})
			}
		}
	}
}

// Arc of a conic between two times, sampled uniformly in anomaly so the fast
// periapsis pass gets as many points as the slow apoapsis drift.
draw_arc :: proc(cam: ^Camera, o: orbit.Orbit, base: [2]f64, t0, t1: f64, color: rl.Color) {
	x0 := orbit.anomaly_at(o, t0)
	x1 := orbit.anomaly_at(o, t1)
	if x1 < x0 do return
	size_px := abs(o.a) * cam.zoom
	n := clamp(int(size_px * 0.3 * (x1 - x0) / (2 * math.PI)) + 16, 16, 2000)
	prev := world_to_screen(cam, base + orbit.point_at_anomaly(o, x0))
	prev_in := on_screen(prev, 64)
	for i in 1 ..= n {
		x := x0 + (x1 - x0) * f64(i) / f64(n)
		cur := world_to_screen(cam, base + orbit.point_at_anomaly(o, x))
		cur_in := on_screen(cur, 64)
		if prev_in || cur_in do rl.DrawLineV({prev.x, prev.y}, {cur.x, cur.y}, color)
		prev, prev_in = cur, cur_in
	}
}
