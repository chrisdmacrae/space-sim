package fastart

// raylib renderer for .fart documents. Screen-space only: the caller maps
// world coordinates to a screen origin and pixel scale (see render/camera).
// Document space is y-down, like the screen, so no flip happens here.

import "core:math"
import rl "vendor:raylib"

// Where and how big to draw a document on screen.
Xform :: struct {
	origin: [2]f32, // screen px of document (0,0)
	px:     f32,    // screen px per document unit
	rot:    f32,    // radians, screen space (positive = clockwise on a y-down screen)
}

// Optional per-instance token colours (owner tint, faction, seeded planet
// palette), applied over the document's own palette resolution.
Override :: struct {
	token: string,
	color: [4]u8,
}
Overrides :: []Override

xform_apply :: proc(x: Xform, p: V2) -> rl.Vector2 {
	c := math.cos(x.rot)
	s := math.sin(x.rot)
	return {x.origin.x + x.px * (c * p.x - s * p.y), x.origin.y + x.px * (s * p.x + c * p.y)}
}

to_color :: proc(c: [4]u8) -> rl.Color {
	return rl.Color{c[0], c[1], c[2], c[3]}
}

color_for :: proc(doc: ^Doc, token: string, ov: Overrides) -> rl.Color {
	for o in ov do if o.token == token do return to_color(o.color)
	return to_color(color_of(doc, token))
}

// Draw a document in the named state. Unknown or empty state draws every
// part at rest in file order, as the format specifies.
draw_doc :: proc(doc: ^Doc, state: string, xf: Xform, overrides: Overrides = nil) {
	if st := state_of(doc, state); st != nil {
		draw_poses(doc, st.parts[:], xf, overrides)
		return
	}
	for &part in doc.parts {
		draw_part(doc, &part, world_xf(doc, nil, part.name), xf, overrides)
	}
}

// Draw a pose list: a state's `parts`, or a frame sampled from a clip
// (see anim.odin). List order is paint order; each part is placed by its
// world transform, so parents carry their children and mirrors flip.
draw_poses :: proc(doc: ^Doc, poses: []State_Part, xf: Xform, overrides: Overrides = nil) {
	for sp in poses {
		part := part_of(doc, sp.part)
		if part == nil do continue
		draw_part(doc, part, world_xf(doc, poses, sp.part), xf, overrides)
	}
}

draw_part :: proc(doc: ^Doc, part: ^Part, W: Xf, xf: Xform, ov: Overrides) {
	tp :: proc(W: Xf, xf: Xform, q: V2) -> rl.Vector2 {
		return xform_apply(xf, xf_apply(W, q))
	}
	unit := xf_scale(W) * xf.px // screen px per (posed) document unit

	// `shapes_of`, not `part.shapes`: a part drawn `like` another has none.
	for &sh in shapes_of(doc, part) {
		col := color_for(doc, sh.color, ov)
		switch sh.kind {
		case "circle":
			rl.DrawCircleV(tp(W, xf, sh.at), sh.r * unit, col)
		case "line":
			a := tp(W, xf, sh.a)
			b := tp(W, xf, sh.b)
			w := sh.w * unit
			rl.DrawLineEx(a, b, w, col)
			rl.DrawCircleV(a, w * 0.5, col) // round caps
			rl.DrawCircleV(b, w * 0.5, col)
		case "poly":
			if len(sh.points) < 3 do continue
			if len(sh.tris) < 3 {
				// Editor didn't bake; triangulate once and keep it.
				triangulate(sh.points[:], &sh.tris)
				if len(sh.tris) < 3 do continue
			}
			for i := 0; i + 2 < len(sh.tris); i += 3 {
				a := tp(W, xf, sh.points[sh.tris[i]])
				b := tp(W, xf, sh.points[sh.tris[i + 1]])
				c := tp(W, xf, sh.points[sh.tris[i + 2]])
				// Backface culling is disabled at init, so winding is free.
				rl.DrawTriangle(a, b, c, col)
			}
		}
	}
}

// Extent of every shape in the document (rest pose), for fitting into boxes.
doc_bounds :: proc(doc: ^Doc) -> (lo, hi: V2) {
	lo = {math.F32_MAX, math.F32_MAX}
	hi = {-math.F32_MAX, -math.F32_MAX}
	grow :: proc(lo, hi: ^V2, p: V2, r: f32 = 0) {
		lo^ = {min(lo.x, p.x - r), min(lo.y, p.y - r)}
		hi^ = {max(hi.x, p.x + r), max(hi.y, p.y + r)}
	}
	for &part in doc.parts {
		for &sh in shapes_of(doc, &part) {
			switch sh.kind {
			case "circle":
				grow(&lo, &hi, sh.at, sh.r)
			case "line":
				grow(&lo, &hi, sh.a, sh.w * 0.5)
				grow(&lo, &hi, sh.b, sh.w * 0.5)
			case "poly":
				for p in sh.points do grow(&lo, &hi, p)
			}
		}
	}
	if lo.x > hi.x do return {}, {}
	return
}
