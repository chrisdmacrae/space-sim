package crew

// The inside of a hull: a deck plan per class, in deck units (about half a
// metre), bow to +x, a corridor down the spine at y = 0 with rooms either
// side, engineering at the stern and the bridge at the bow. Every room has
// a door onto the corridor, a few spots the crew stand at, and furniture
// drawn from assets/crew/deck.fart by the item's state name. The plan is
// data; ui/ship_view.odin draws it and walk.odin moves the crew about it.

import "core:math"
import econ "sim:econ"

Room_Kind :: enum u8 {
	Bridge,      // navigation
	Comms,
	Engineering,
	Quarters,
	Galley,
	Hold,
	Airlock,
	Pods,        // cryo pods (sleepers)
}

ROOM_NAMES := [Room_Kind]string {
	.Bridge = "Bridge", .Comms = "Comms", .Engineering = "Engineering", .Quarters = "Quarters",
	.Galley = "Galley", .Hold = "Cargo hold", .Airlock = "Airlock", .Pods = "Cryo bay",
}

// A place to stand, and which way to face while standing there.
Spot :: struct {
	at:   [2]f32,
	face: f32, // radians, screen sense (y down)
}

// A piece of furniture: a state of deck.fart placed on the floor.
Fixture :: struct {
	item:  string,
	at:    [2]f32,
	rot:   f32,
	scale: f32,
}

Room :: struct {
	kind:       Room_Kind,
	x0, y0, x1, y1: f32,
	door:       [2]f32, // on the wall
	entry:      [2]f32, // the corridor point just outside the door
	spots:      [dynamic]Spot,
	fixtures:   [dynamic]Fixture,
	hold_slots: [dynamic][2]f32, // hold only: where crates go, filled in cargo order
}

Deck :: struct {
	class:         econ.Class_Id,
	length, beam:  f32,
	corridor_half: f32,
	wall:          f32, // hull thickness kept clear of rooms
	rooms:         [dynamic]Room,
}

@(private = "file")
Slot :: struct {
	kind: Room_Kind,
	w:    f32, // relative width along the corridor
}

@(private = "file")
Layout :: struct {
	length, beam:      f32,
	bridge_w, eng_w:   f32,
	top, bottom:       []Slot,
}

@(private = "file")
LAYOUTS := [econ.Class_Id]Layout {
	.Courier   = {30, 11, 6, 6, {{.Comms, 6}, {.Quarters, 7}, {.Galley, 5}}, {{.Hold, 11}, {.Airlock, 7}}},
	.Hauler    = {44, 14, 7, 8, {{.Comms, 7}, {.Galley, 8}, {.Quarters, 12}}, {{.Hold, 20}, {.Airlock, 7}}},
	.Clipper   = {36, 11, 7, 7, {{.Comms, 6}, {.Quarters, 9}, {.Galley, 6}}, {{.Airlock, 6}, {.Hold, 15}}},
	.Freighter = {60, 18, 8, 10, {{.Comms, 8}, {.Galley, 10}, {.Quarters, 16}, {.Airlock, 6}}, {{.Hold, 40}}},
	.Sleeper   = {48, 14, 7, 8, {{.Comms, 7}, {.Quarters, 12}, {.Galley, 7}}, {{.Airlock, 6}, {.Pods, 12}, {.Hold, 12}}},
}

// Half the beam at a station x along the hull: full amidships, drawn in
// toward the bow, and a little narrower at the stern block.
hull_half_beam :: proc(d: ^Deck, x: f32) -> f32 {
	h := d.beam * 0.5
	nose := d.length * 0.22
	bow := d.length * 0.5 - nose
	if x > bow {
		u := (x - bow) / nose
		return h * (1 - 0.72 * u * u)
	}
	tail := -d.length * 0.5 + d.length * 0.12
	if x < tail {
		u := (tail - x) / (d.length * 0.12)
		return h * (1 - 0.18 * u)
	}
	return h
}

deck_build :: proc(class: econ.Class_Id, bunks: int) -> (d: Deck) {
	L := LAYOUTS[class]
	d.class = class
	d.length = L.length
	d.beam = L.beam
	d.corridor_half = 1.3
	d.wall = 1.0
	half := d.beam * 0.5 - d.wall
	// Stern: engineering across the whole beam.
	eng := Room{kind = .Engineering, x0 = -d.length * 0.5 + d.wall + 0.6}
	eng.x1 = eng.x0 + L.eng_w
	eh := min(hull_half_beam(&d, eng.x0) - d.wall * 0.6, half)
	eng.y0, eng.y1 = -eh, eh
	eng.door = {eng.x1, 0}
	eng.entry = {eng.x1 + 0.9, 0}
	// Bow: the bridge, narrower where the hull draws in.
	bridge := Room{kind = .Bridge, x1 = d.length * 0.5 - d.wall - 1.2}
	bridge.x0 = bridge.x1 - L.bridge_w
	bh := hull_half_beam(&d, bridge.x1) - d.wall * 0.6
	bridge.y0, bridge.y1 = -bh, bh
	bridge.door = {bridge.x0, 0}
	bridge.entry = {bridge.x0 - 0.9, 0}
	append(&d.rooms, eng)
	// Amidships: the two rows share the run between the end rooms.
	mid0 := eng.x1 + 0.7
	mid1 := bridge.x0 - 0.7
	row :: proc(d: ^Deck, slots: []Slot, x0, x1: f32, top: bool, half: f32) {
		total: f32
		for s in slots do total += s.w
		x := x0
		for s in slots {
			w := (x1 - x0) * s.w / total
			r := Room{kind = s.kind, x0 = x + 0.25, x1 = x + w - 0.25}
			if top {
				r.y0, r.y1 = -half, -d.corridor_half
				r.door = {(r.x0 + r.x1) * 0.5, r.y1}
			} else {
				r.y0, r.y1 = d.corridor_half, half
				r.door = {(r.x0 + r.x1) * 0.5, r.y0}
			}
			r.entry = {r.door.x, 0}
			append(&d.rooms, r)
			x += w
		}
	}
	row(&d, L.top, mid0, mid1, true, half)
	row(&d, L.bottom, mid0, mid1, false, half)
	append(&d.rooms, bridge)
	for &r in d.rooms do furnish(&r, bunks)
	return
}

deck_destroy :: proc(d: ^Deck) {
	for &r in d.rooms {
		delete(r.spots)
		delete(r.fixtures)
		delete(r.hold_slots)
	}
	delete(d.rooms)
	d^ = {}
}

room_index :: proc(d: ^Deck, kind: Room_Kind) -> int {
	for &r, i in d.rooms do if r.kind == kind do return i
	return -1
}

// The room a post is stood in; off duty is the quarters.
room_for_post :: proc(d: ^Deck, p: Post) -> int {
	switch p {
	case .Engineering: return room_index(d, .Engineering)
	case .Navigation:  return room_index(d, .Bridge)
	case .Comms:       return room_index(d, .Comms)
	case .Off_Duty:    return room_index(d, .Quarters)
	}
	return 0
}

room_center :: proc(r: ^Room) -> [2]f32 {
	return {(r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5}
}

room_contains :: proc(r: ^Room, p: [2]f32) -> bool {
	return p.x >= r.x0 && p.x <= r.x1 && p.y >= r.y0 && p.y <= r.y1
}

// Is the room's outer wall at -y (top of the plan)? End rooms count as neither.
@(private = "file")
outer_sign :: proc(r: ^Room) -> f32 {
	if r.y0 < 0 && r.y1 > 0 do return 0
	return r.y1 <= 0 ? -1 : 1
}

// Lay the furniture and the standing spots out for a room by its kind.
@(private = "file")
furnish :: proc(r: ^Room, bunks: int) {
	cx := (r.x0 + r.x1) * 0.5
	cy := (r.y0 + r.y1) * 0.5
	w := r.x1 - r.x0
	h := r.y1 - r.y0
	side := outer_sign(r) // which way the outer wall is
	switch r.kind {
	case .Bridge:
		// Consoles along the bow wall, a seat behind each; the crew sit and face the bow.
		n := h > 7 ? 3 : 2
		for k in 0 ..< n {
			y := cy + (f32(k) - f32(n - 1) * 0.5) * 2.7
			append(&r.fixtures, Fixture{"console", {r.x1 - 1.3, y}, 0, 1})
			append(&r.fixtures, Fixture{"seat", {r.x1 - 2.9, y}, 0, 1})
			append(&r.spots, Spot{{r.x1 - 2.9, y}, 0})
		}
	case .Comms:
		// The antenna rack against the outer wall, a console beside it.
		append(&r.fixtures, Fixture{"antenna", {cx - 1.2, cy + side * (h * 0.5 - 1.5)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5, 1})
		append(&r.fixtures, Fixture{"console", {cx + 1.4, cy + side * (h * 0.5 - 1.1)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5, 0.85})
		append(&r.fixtures, Fixture{"seat", {cx + 1.4, cy + side * (h * 0.5 - 2.5)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5, 0.9})
		append(&r.spots, Spot{{cx + 1.4, cy + side * (h * 0.5 - 2.5)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5})
		append(&r.spots, Spot{{cx - 1.2, cy - side * 0.8}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5})
	case .Engineering:
		// The reactor in the middle, tanks along the walls, panels at the stern.
		append(&r.fixtures, Fixture{"reactor", {cx + 0.4, cy}, 0, 1})
		append(&r.fixtures, Fixture{"tank", {cx + 0.2, r.y0 + 1.2}, 0, 1})
		append(&r.fixtures, Fixture{"tank", {cx + 0.2, r.y1 - 1.2}, 0, 1})
		np := h > 9 ? 3 : 2
		for k in 0 ..< np {
			y := cy + (f32(k) - f32(np - 1) * 0.5) * 2.9
			append(&r.fixtures, Fixture{"panel", {r.x0 + 0.6, y}, 0, 1})
		}
		append(&r.spots, Spot{{r.x0 + w * 0.3, cy}, 0})
		append(&r.spots, Spot{{r.x0 + 1.6, cy - 1.5}, math.PI})
		append(&r.spots, Spot{{cx + 0.4, cy + side_or(side, 1) * (h * 0.5 - 2.6)}, -math.PI * 0.5})
		append(&r.spots, Spot{{r.x1 - 0.9, cy - 1.0}, math.PI})
	case .Quarters:
		// Bunks head to the outer wall, as many as there are berths, in one row
		// (a second when the berths outnumber the wall).
		n := max(bunks, 1)
		per := max(int((w - 0.4) / 1.95), 1)
		rows := (n + per - 1) / per
		for k in 0 ..< n {
			row := k / per
			col := k % per
			cols := min(n - row * per, per)
			x := cx + (f32(col) - f32(cols - 1) * 0.5) * 1.95
			y := cy + side * (h * 0.5 - 1.7 - f32(row) * 2.0)
			rot: f32 = side < 0 ? -math.PI * 0.5 : math.PI * 0.5 // pillow toward the outer wall
			append(&r.fixtures, Fixture{"bunk", {x, y}, rot, 1})
			if row == rows - 1 do append(&r.spots, Spot{{x, cy - side * (h * 0.5 - 1.0)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5})
		}
		if len(r.spots) == 0 do append(&r.spots, Spot{{cx, cy}, 0})
	case .Galley:
		// A table with a seat at each end, and two more along the sides when the room is deep enough.
		ts: f32 = h < 4.5 ? 0.8 : 1
		append(&r.fixtures, Fixture{"table", {cx, cy}, 0, ts})
		ends := [?]f32{-2.3 * ts - 0.6, 2.3 * ts + 0.6}
		for ex in ends {
			if abs(ex) > w * 0.5 - 0.7 do continue
			append(&r.fixtures, Fixture{"seat", {cx + ex, cy}, ex < 0 ? 0 : math.PI, 0.85})
			append(&r.spots, Spot{{cx + ex, cy}, ex < 0 ? 0 : math.PI})
		}
		sides := [?][2]f32{{-1.0, -1.35 * ts - 0.65}, {1.0, 1.35 * ts + 0.65}}
		for s in sides {
			if abs(s.y) > h * 0.5 - 0.7 do continue
			append(&r.fixtures, Fixture{"seat", {cx + s.x, cy + s.y}, s.y < 0 ? math.PI * 0.5 : -math.PI * 0.5, 0.85})
			append(&r.spots, Spot{{cx + s.x, cy + s.y}, s.y < 0 ? math.PI * 0.5 : -math.PI * 0.5})
		}
		if len(r.spots) == 0 do append(&r.spots, Spot{{cx, cy}, 0})
	case .Hold:
		// Crates fill from the outer wall inward; the aisle by the door stays clear.
		cols := max(int((w - 1.0) / 2.3), 1)
		rows := max(int((h - 2.6) / 2.3), 1)
		for row in 0 ..< rows {
			for col in 0 ..< cols {
				x := r.x0 + 1.4 + f32(col) * 2.3
				y := cy + side * (h * 0.5 - 1.5 - f32(row) * 2.3)
				append(&r.hold_slots, [2]f32{x, y})
			}
		}
		append(&r.spots, Spot{{cx - w * 0.25, cy - side * (h * 0.5 - 1.6)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5})
		append(&r.spots, Spot{{cx + w * 0.25, cy - side * (h * 0.5 - 1.6)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5})
	case .Airlock:
		append(&r.fixtures, Fixture{"hatch", {cx, cy + side * (h * 0.5 - 0.1)}, 0, 1})
		append(&r.fixtures, Fixture{"locker", {r.x0 + 0.8, cy + side * 0.6}, 0, 1})
		append(&r.fixtures, Fixture{"locker", {r.x1 - 0.8, cy + side * 0.6}, 0, 1})
		append(&r.spots, Spot{{cx, cy - side * 0.6}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5})
	case .Pods:
		n := max(int(w / 2.8), 1)
		for k in 0 ..< n {
			x := cx + (f32(k) - f32(n - 1) * 0.5) * 2.8
			append(&r.fixtures, Fixture{"pod", {x, cy + side * (h * 0.5 - 2.9)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5, 1})
		}
		append(&r.spots, Spot{{cx, cy - side * (h * 0.5 - 1.6)}, side < 0 ? -math.PI * 0.5 : math.PI * 0.5})
	}
}

@(private = "file")
side_or :: proc(side, dflt: f32) -> f32 { return side == 0 ? dflt : side }
