package crew

// Crew about the deck. Visual only: nothing here touches levels or effects.
// A crew member on duty stands their system's room, drifting between its
// spots, and now and then takes a break in the galley or the quarters before
// going back. Off duty they wander between the two. Runs on real seconds so
// the deck stays lively whatever the time step is doing.

import "core:math"
import core "sim:core"

Walker :: struct {
	inited:   bool,
	pos:      [2]f32,
	facing:   f32,  // radians, screen sense
	moving:   bool,
	anim_t:   f32,  // seconds of walk cycle played
	path:     [6][2]f32,
	path_n:   int,
	path_i:   int,
	room:     int,  // room the walker is in or heading for
	face_at:  f32,  // facing to settle into on arrival
	wait:     f32,  // seconds until the next decision
	break_in: f32,  // seconds of duty left before a break
	on_break: bool,
	target_room: int,
}

WALK_SPEED   :: 2.6 // deck units per real second
TURN_RATE    :: 9.0 // radians per second toward the way of travel
BREAK_EVERY  :: [2]f32{70, 140}
BREAK_LENGTH :: [2]f32{10, 22}
LINGER       :: [2]f32{4, 11}

// Advance every crew member by `real_dt` seconds.
walk_update :: proc(ro: ^Roster, d: ^Deck, real_dt: f32) {
	if len(d.rooms) == 0 do return
	dt := clamp(real_dt, 0, 0.1)
	for &m in ro.members {
		w := &m.walker
		if !w.inited do walker_place(w, d, room_for_post(d, m.post), &ro.rng)
		if w.moving {
			walker_step(w, dt)
			if !w.moving do w.wait = f32(core.rng_range(&ro.rng, f64(LINGER[0]), f64(LINGER[1])))
			continue
		}
		w.anim_t += dt
		// Settle the facing toward the spot's own.
		w.facing = approach_angle(w.facing, w.face_at, f32(TURN_RATE) * dt)
		w.wait -= dt
		duty := room_for_post(d, m.post)
		if m.post != .Off_Duty && !w.on_break {
			w.break_in -= dt
			if w.break_in <= 0 {
				w.on_break = true
				w.wait = f32(core.rng_range(&ro.rng, f64(BREAK_LENGTH[0]), f64(BREAK_LENGTH[1])))
				walker_go(w, d, pick_rest_room(d, &ro.rng), &ro.rng)
				continue
			}
		}
		if w.wait > 0 do continue
		// Decision time.
		if w.on_break {
			w.on_break = false
			w.break_in = f32(core.rng_range(&ro.rng, f64(BREAK_EVERY[0]), f64(BREAK_EVERY[1])))
			walker_go(w, d, duty, &ro.rng)
		} else if m.post == .Off_Duty {
			walker_go(w, d, core.rng_chance(&ro.rng, 0.6) ? pick_rest_room(d, &ro.rng) : w.room, &ro.rng)
		} else if w.room != duty {
			walker_go(w, d, duty, &ro.rng)
		} else {
			walker_go(w, d, w.room, &ro.rng) // another spot in the same room
		}
	}
}

// Put a walker down at a spot in a room, standing still.
walker_place :: proc(w: ^Walker, d: ^Deck, room: int, r: ^core.Rng) {
	room := clamp(room, 0, len(d.rooms) - 1)
	s := pick_spot(&d.rooms[room], r)
	w^ = Walker{inited = true, pos = s.at, facing = s.face, face_at = s.face, room = room, target_room = room}
	w.wait = f32(core.rng_range(r, 1, 6))
	w.break_in = f32(core.rng_range(r, f64(BREAK_EVERY[0]) * 0.5, f64(BREAK_EVERY[1])))
}

// Walk to a spot in `room`, by the corridor if it is another room.
walker_go :: proc(w: ^Walker, d: ^Deck, room: int, r: ^core.Rng) {
	room := clamp(room, 0, len(d.rooms) - 1)
	to := &d.rooms[room]
	s := pick_spot(to, r)
	// Avoid re-choosing the spot we stand on when there is any other.
	if len(to.spots) > 1 && room == w.room {
		for _ in 0 ..< 3 {
			if orbit_len(s.at - w.pos) > 0.3 do break
			s = pick_spot(to, r)
		}
	}
	w.path_n = 0
	if room != w.room {
		from := &d.rooms[clamp(w.room, 0, len(d.rooms) - 1)]
		w.path[w.path_n] = from.door; w.path_n += 1
		w.path[w.path_n] = from.entry; w.path_n += 1
		w.path[w.path_n] = to.entry; w.path_n += 1
		w.path[w.path_n] = to.door; w.path_n += 1
	}
	w.path[w.path_n] = s.at
	w.path_n += 1
	w.path_i = 0
	w.face_at = s.face
	w.target_room = room
	w.room = room
	w.moving = true
}

@(private = "file")
walker_step :: proc(w: ^Walker, dt: f32) {
	left := WALK_SPEED * dt
	for left > 0 && w.path_i < w.path_n {
		goal := w.path[w.path_i]
		d := goal - w.pos
		dist := orbit_len(d)
		if dist < 1e-4 {
			w.path_i += 1
			continue
		}
		want := math.atan2(d.y, d.x)
		w.facing = approach_angle(w.facing, want, f32(TURN_RATE) * dt)
		step := min(left, dist)
		w.pos += d / dist * step
		left -= step
		if step >= dist - 1e-4 do w.path_i += 1
	}
	w.anim_t += dt
	if w.path_i >= w.path_n {
		w.moving = false
		w.anim_t = 0
	}
}

@(private = "file")
pick_spot :: proc(r: ^Room, rng: ^core.Rng) -> Spot {
	if len(r.spots) == 0 do return Spot{room_center(r), 0}
	return r.spots[core.rng_int(rng, 0, len(r.spots))]
}

@(private = "file")
pick_rest_room :: proc(d: ^Deck, r: ^core.Rng) -> int {
	g := room_index(d, .Galley)
	q := room_index(d, .Quarters)
	if g < 0 do return max(q, 0)
	if q < 0 do return g
	return core.rng_chance(r, 0.55) ? g : q
}

@(private = "file")
approach_angle :: proc(a, target, rate: f32) -> f32 {
	d := target - a
	for d > math.PI do d -= 2 * math.PI
	for d < -math.PI do d += 2 * math.PI
	if abs(d) <= rate do return target
	return a + (d > 0 ? rate : -rate)
}

@(private = "file")
orbit_len :: proc(v: [2]f32) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y) }
