package render

// How a hull is posed, frame by frame, from what the ship is doing
// (docs/DESIGN.md §8.8). The poses themselves live in the .fart document as
// fastart clips; this is only the mapping from ship state to a weight.
//
// Traversal: the exhaust clips -- `burn_min` at a trickle, `burn` at full --
// blended by throttle, and grown out of `burn_off` as the engine lights, so
// the plume swells and dies instead of blinking.
//
// Rotation: `turn_left` or `turn_right` layered over that, weighted by how
// fast the hull is actually turning. The turn is measured from the heading
// itself rather than from the keys, so a hand turn, a prograde hold and the
// autopilot all fire the attitude jets, and NPCs get them for free.

import "core:math"
import art "sim:art"
import sim "sim:sim"

Ship_Anim :: struct {
	t:        f32,  // real seconds of animation played
	lit:      f32,  // 0..1 how far the engine is lit
	power:    f32,  // 0..1 smoothed throttle
	turn:     f32,  // -1..1 smoothed turn; positive turns left (world counter-clockwise)
	heading:  f64,  // last frame's heading, which is what the turn is measured from
	tracking: bool, // heading means something yet
}

LIT_RATE   :: 7.0 // per second, toward the engine's state
POWER_RATE :: 4.0
TURN_SMOOTH :: 9.0
TURN_FULL  :: 1.6            // radians per real second that fires the jets flat out
TURN_JUMP  :: math.PI * 0.5  // more than this in one frame is a teleport, not a turn

// Call once per frame per drawn ship, with real (not game) seconds: the
// animation runs on the wall clock, so time warp does not strobe the plume.
ship_anim_update :: proc(a: ^Ship_Anim, s: ^sim.Ship, heading, real_dt: f64) {
	dt := f32(clamp(real_dt, 0, 0.1))
	a.t += dt
	if a.t > 600 do a.t -= 600 // f32 seconds keep their precision this side of ten minutes

	flying := s.mode == .On_Rails || s.mode == .Thrusting
	turn: f32
	if a.tracking && flying && real_dt > 0 {
		d := wrap_pi(heading - a.heading)
		// A docking, a jump or a load moves the heading by a lot at once:
		// that is not the ship turning, and it must not fire the jets.
		if abs(d) < TURN_JUMP do turn = f32(clamp(d / real_dt / TURN_FULL, -1, 1))
	}
	a.heading = heading
	a.tracking = true

	lit: f32 = s.mode == .Thrusting && s.throttle > 0 && s.propellant > 0 ? 1 : 0
	approach(&a.lit, lit, LIT_RATE * dt)
	approach(&a.power, f32(clamp(s.throttle, 0, 1)), POWER_RATE * dt)
	approach(&a.turn, turn, TURN_SMOOTH * dt)
}

// The pose to draw the hull in, allocated in the temp arena (valid until the
// frame's temp reset). Nil for a document with no clips: draw it by state.
ship_anim_pose :: proc(doc: ^art.Doc, a: ^Ship_Anim) -> []art.State_Part {
	if art.clip_of(doc, "idle") == nil do return nil

	pose: []art.State_Part
	if a.lit > 0.002 {
		fire := mix(doc, pose_of(doc, "burn_min", a.t), pose_of(doc, "burn", a.t), a.power)
		pose = mix(doc, pose_of(doc, "burn_off", 0), fire, a.lit)
	} else {
		pose = pose_of(doc, "idle", a.t)
	}
	if w := abs(a.turn); w > 0.002 {
		jets := pose_of(doc, a.turn > 0 ? "turn_left" : "turn_right", a.t)
		pose = over(doc, pose, jets, w)
	}
	return pose
}

// A clip's frame at t, or the state of that name for a document that only
// has the pose. Empty when it has neither.
@(private = "file")
pose_of :: proc(doc: ^art.Doc, name: string, t: f32) -> []art.State_Part {
	out := make([dynamic]art.State_Part, 0, 12, context.temp_allocator)
	if c := art.clip_of(doc, name); c != nil {
		art.sample_clip(doc, c, t, &out)
	} else if st := art.state_of(doc, name); st != nil {
		append(&out, ..st.parts[:])
	}
	return out[:]
}

@(private = "file")
mix :: proc(doc: ^art.Doc, a, b: []art.State_Part, w: f32) -> []art.State_Part {
	out := make([dynamic]art.State_Part, 0, 12, context.temp_allocator)
	art.blend_poses(doc, a, b, w, &out)
	return out[:]
}

@(private = "file")
over :: proc(doc: ^art.Doc, base, layer: []art.State_Part, w: f32) -> []art.State_Part {
	out := make([dynamic]art.State_Part, 0, 12, context.temp_allocator)
	art.layer_poses(doc, base, layer, w, &out)
	return out[:]
}

@(private = "file")
approach :: proc(v: ^f32, target, rate: f32) {
	v^ += (target - v^) * min(rate, 1)
}

@(private = "file")
wrap_pi :: proc(a: f64) -> f64 {
	x := math.mod(a + math.PI, 2 * math.PI)
	if x < 0 do x += 2 * math.PI
	return x - math.PI
}
