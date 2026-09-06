package sim

// Frame changes between spheres of influence (docs/DESIGN.md §4.2). All
// states are relative to a primary body; converting between a body and its
// parent only needs the body's own conic at that instant.

import gen "sim:gen"
import orbit "sim:orbit"

// Absolute position and velocity of a body at any time (walks the parent chain).
body_state_at :: proc(sys: ^gen.System, h: gen.Body_Handle, t: f64) -> (pos, vel: [2]f64) {
	if h == gen.NONE do return {}, {}
	b := &sys.bodies[h]
	if b.parent == gen.NONE do return {}, {}
	p, v := orbit.state_at(b.orbit, t)
	pp, pv := body_state_at(sys, b.parent, t)
	return pp + p, pv + v
}

body_pos_at :: proc(sys: ^gen.System, h: gen.Body_Handle, t: f64) -> [2]f64 {
	p, _ := body_state_at(sys, h, t)
	return p
}

// Relative state in `primary`'s frame → the parent's frame.
to_parent_frame :: proc(sys: ^gen.System, primary: gen.Body_Handle, pos, vel: [2]f64, t: f64) -> (npos, nvel: [2]f64, parent: gen.Body_Handle) {
	b := &sys.bodies[primary]
	p, v := orbit.state_at(b.orbit, t)
	return pos + p, vel + v, b.parent
}

// Relative state in a body's frame → one of its children's frame.
to_child_frame :: proc(sys: ^gen.System, child: gen.Body_Handle, pos, vel: [2]f64, t: f64) -> (npos, nvel: [2]f64) {
	c := &sys.bodies[child]
	p, v := orbit.state_at(c.orbit, t)
	return pos - p, vel - v
}
