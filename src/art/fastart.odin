package fastart

// Reference Odin loader for the Fast Art Format (.fart). See spec/FORMAT.md.
// Engine-agnostic: no rendering here, just types, IO, palette resolution,
// and triangulation. Rendering is ~50 lines in whatever engine you're in.

import "core:encoding/json"
import "core:math"

V2 :: [2]f32

Shape :: struct {
	kind:   string, // "circle" | "line" | "poly"
	color:  string, // palette token
	at:     V2,
	r:      f32,
	a:      V2,
	b:      V2,
	w:      f32,
	points: [dynamic]V2,
	tris:   [dynamic]u16, // baked triangulation (index triples)
}

Anchor :: struct {
	name:  string,
	at:    V2,
	angle: f32, // 1.2: the direction an attached thing points, radians in rest space; 0 when absent
}

Part :: struct {
	name:    string,
	parent:  string, // 1.1: posed in this part's frame; "" = none
	like:    string, // 1.2: draws that part's shapes and anchors (use shapes_of); "" = its own
	pivot:   V2,
	shapes:  [dynamic]Shape,
	anchors: [dynamic]Anchor,
}

State_Part :: struct {
	part:   string,
	offset: V2,
	rotate: f32,
	scale:  f32, // 0 = 1
	mirror: bool, // 1.2: flipped left-to-right about the pivot, before the turn
}

// 1.2: where a chain should reach in a pose, document space.
Target :: struct {
	chain: string,
	at:    V2,
}

State :: struct {
	name:    string,
	parts:   [dynamic]State_Part,
	targets: [dynamic]Target, // 1.2
}

Tok :: struct {
	name:     string,
	rgb:      [4]u8,
	emissive: f32, // 1.2: light the slot gives off; 0 for none
}

// 1.1: one moment in a clip -- a time, and a pose named or inline.
Clip_Key :: struct {
	t:       f32,
	state:   string,
	parts:   [dynamic]State_Part,
	ease:    string, // "linear" (default) | "in" | "out" | "in-out" | "step"
	curve:   [dynamic]f32, // 1.2: [x1, y1, x2, y2] when four long; wins over ease
	targets: [dynamic]Target, // 1.2
	events:  [dynamic]string, // 1.2: names heard when the playhead crosses this key
}

Clip :: struct {
	name: string,
	loop: bool,
	keys: [dynamic]Clip_Key,
}

// 1.1: an inverse-kinematics chain a runtime may solve live.
Constraint :: struct {
	name:  string,
	chain: [dynamic]string,
	end:   string, // "part/anchor"
	bend:  int,
}

Doc :: struct {
	version:      int,
	name:         string,
	palette_refs: [dynamic]string,
	palette:      [dynamic]Tok,
	parts:        [dynamic]Part,
	states:       [dynamic]State,
	clips:        [dynamic]Clip,
	constraints:  [dynamic]Constraint,
	// optional: shapes an engine may treat as solid (a line is a capsule).
	// Never drawn; rest-space, state-independent.
	collision:    [dynamic]Shape,
	// filled by resolve_palettes; never written
	resolved:     [dynamic]Tok `json:"-"`,
}

// A byte source for palette_refs: engines that embed assets pass their own.
Resolver :: proc(path: string, user: rawptr) -> ([]byte, bool)

// Strings inside the Doc belong to the allocator unmarshal used; destroy
// frees the containers only. Games load into an arena and drop the lot.
load_bytes :: proc(data: []byte) -> (doc: Doc, ok: bool) {
	// the raw tree first: the version gate must not trust unmarshal's
	// coercions ("1" is not 1), and absent offsets are only visible here
	tree, terr := json.parse(data, allocator = context.temp_allocator)
	if terr != nil do return {}, false
	root, is_obj := tree.(json.Object)
	if !is_obj || !version_ok(root["version"]) do return {}, false
	if json.unmarshal(data, &doc) != nil do return {}, false
	normalize_offsets(&doc, root)
	return doc, true
}

@(private)
version_ok :: proc(v: json.Value) -> bool {
	#partial switch n in v {
	case json.Integer:
		return n == 1
	case json.Float:
		return n == 1
	}
	return false
}

// A state entry with no offset means "the pivot lands on itself" (rest).
// Unmarshalling can't tell absent from [0, 0], so a second look at the
// raw tree fills the pivot in wherever the field was missing.
@(private)
normalize_offsets :: proc(doc: ^Doc, root: json.Object) {
	fill :: proc(doc: ^Doc, raw: json.Array, parts: []State_Part) {
		for sp_v, j in raw {
			if j >= len(parts) do break
			sp := sp_v.(json.Object) or_continue
			if "offset" in sp do continue
			if part := part_of(doc, parts[j].part); part != nil do parts[j].offset = part.pivot
		}
	}
	states := root["states"].(json.Array) or_else nil
	for st_v, i in states {
		if i >= len(doc.states) do break
		st := st_v.(json.Object) or_continue
		parts := st["parts"].(json.Array) or_continue
		fill(doc, parts, doc.states[i].parts[:])
	}
	clips := root["clips"].(json.Array) or_else nil
	for c_v, i in clips {
		if i >= len(doc.clips) do break
		c := c_v.(json.Object) or_continue
		keys := c["keys"].(json.Array) or_continue
		for k_v, j in keys {
			if j >= len(doc.clips[i].keys) do break
			k := k_v.(json.Object) or_continue
			parts := k["parts"].(json.Array) or_continue
			fill(doc, parts, doc.clips[i].keys[j].parts[:])
		}
	}
}

destroy :: proc(doc: ^Doc) {
	for &p in doc.parts {
		for &s in p.shapes {
			delete(s.points)
			delete(s.tris)
		}
		delete(p.shapes)
		delete(p.anchors)
	}
	delete(doc.parts)
	for &s in doc.collision {
		delete(s.points)
		delete(s.tris)
	}
	delete(doc.collision)
	for &st in doc.states do delete(st.parts)
	for &s in doc.states do delete(s.targets)
	delete(doc.states)
	for &c in doc.clips {
		for &k in c.keys {
			delete(k.parts)
			delete(k.curve)
			delete(k.targets)
			delete(k.events)
		}
		delete(c.keys)
	}
	delete(doc.clips)
	for &c in doc.constraints do delete(c.chain)
	delete(doc.constraints)
	delete(doc.palette)
	delete(doc.palette_refs)
	delete(doc.resolved)
}

// Flatten palette_refs (in order) + local palette into `resolved`.
// Lookup happens back-to-front, so local wins, later refs beat earlier.
resolve_palettes :: proc(doc: ^Doc, resolver: Resolver, user: rawptr) {
	clear(&doc.resolved)
	for ref in doc.palette_refs {
		if data, ok := resolver(ref, user); ok {
			if pal, pok := load_bytes(data); pok {
				for t in pal.palette do append(&doc.resolved, t)
			}
		}
	}
	for t in doc.palette do append(&doc.resolved, t)
}

// A palette swap: lay `palette` over the doc's colours by name. Same
// names take the new colour, new names join. The doc's own palette and
// refs are untouched; only the resolved table changes, so swapping back
// is another apply (or resolve_palettes again). One file, many looks:
//
//     red, _ := fastart.load_bytes(red_bytes)   // a palette file
//     fastart.apply_palette(&slime, red.palette[:])
apply_palette :: proc(doc: ^Doc, palette: []Tok) {
	if len(doc.resolved) == 0 {
		for t in doc.palette do append(&doc.resolved, t)
	}
	for p in palette {
		hit := false
		for i := len(doc.resolved) - 1; i >= 0; i -= 1 {
			if doc.resolved[i].name == p.name {
				doc.resolved[i].rgb = p.rgb
				hit = true
				break
			}
		}
		if !hit do append(&doc.resolved, p)
	}
}

color_of :: proc(doc: ^Doc, token: string) -> [4]u8 {
	if len(doc.resolved) > 0 {
		for i := len(doc.resolved) - 1; i >= 0; i -= 1 {
			if doc.resolved[i].name == token do return doc.resolved[i].rgb
		}
	}
	for i := len(doc.palette) - 1; i >= 0; i -= 1 {
		if doc.palette[i].name == token do return doc.palette[i].rgb
	}
	return {255, 0, 255, 255}
}

part_of :: proc(doc: ^Doc, name: string) -> ^Part {
	for &p in doc.parts do if p.name == name do return &p
	return nil
}

// 1.2: the part whose geometry this one draws: itself, or the one it is like.
source_of :: proc(doc: ^Doc, part: ^Part) -> ^Part {
	if part.like != "" {
		if src := part_of(doc, part.like); src != nil && src != part && src.like == "" do return src
	}
	return part
}

// A part's shapes, through `like`. Draw these, never part.shapes.
shapes_of :: proc(doc: ^Doc, part: ^Part) -> []Shape {
	return source_of(doc, part).shapes[:]
}

anchors_of :: proc(doc: ^Doc, part: ^Part) -> []Anchor {
	return source_of(doc, part).anchors[:]
}

anchor_of :: proc(doc: ^Doc, part: ^Part, name: string) -> ^Anchor {
	for &a in anchors_of(doc, part) do if a.name == name do return &a
	return nil
}

constraint_of :: proc(doc: ^Doc, name: string) -> ^Constraint {
	for &c in doc.constraints do if c.name == name do return &c
	return nil
}

state_of :: proc(doc: ^Doc, name: string) -> ^State {
	for &s in doc.states do if s.name == name do return &s
	return nil
}

clip_of :: proc(doc: ^Doc, name: string) -> ^Clip {
	for &c in doc.clips do if c.name == name do return &c
	return nil
}

// ------------------------------------------------------------ posing (1.1)
// A part's pose is an affine map; a child's composes with its parent's.
// Xf is the canvas convention: x' = a x + c y + e, y' = b x + d y + f.

Xf :: [6]f32
XF_ID :: Xf{1, 0, 0, 1, 0, 0}

xf_mul :: proc(A, B: Xf) -> Xf {
	return {
		A[0] * B[0] + A[2] * B[1],
		A[1] * B[0] + A[3] * B[1],
		A[0] * B[2] + A[2] * B[3],
		A[1] * B[2] + A[3] * B[3],
		A[0] * B[4] + A[2] * B[5] + A[4],
		A[1] * B[4] + A[3] * B[5] + A[5],
	}
}

xf_apply :: proc(T: Xf, p: V2) -> V2 {
	return {T[0] * p.x + T[2] * p.y + T[4], T[1] * p.x + T[3] * p.y + T[5]}
}

xf_scale :: proc(T: Xf) -> f32 {
	return math.sqrt(T[0] * T[0] + T[1] * T[1])
}

// Does the transform flip handedness (a mirror somewhere up the chain)?
xf_flipped :: proc(T: Xf) -> bool {
	return T[0] * T[3] - T[1] * T[2] < 0
}

// translate(offset) · rotate · scale · mirror · translate(-pivot). A nil
// pose is rest. The mirror (1.2) reflects x about the pivot before the
// turn, so a mirrored part still turns the way its parent does.
local_xf :: proc(part: ^Part, sp: ^State_Part) -> Xf {
	if sp == nil do return XF_ID
	s := sp.scale == 0 ? f32(1) : sp.scale
	c := math.cos(sp.rotate) * s
	sn := math.sin(sp.rotate) * s
	m: f32 = sp.mirror ? -1 : 1
	a, b, cc, d := c * m, sn * m, -sn, c
	pv := part.pivot
	return {a, b, cc, d, sp.offset.x - (a * pv.x + cc * pv.y), sp.offset.y - (b * pv.x + d * pv.y)}
}

// 1.2: the transform that puts an item's anchor onto a host's (positions
// matched; directions too, where both have an angle). Draw the item's
// rest space through it.
attach_xf :: proc(host_xf: Xf, host, item: ^Anchor) -> Xf {
	turn := host.angle - item.angle
	c, s := math.cos(turn), math.sin(turn)
	R := Xf{c, s, -s, c, host.at.x - (c * item.at.x - s * item.at.y), host.at.y - (s * item.at.x + c * item.at.y)}
	return xf_mul(host_xf, R)
}

// The world transform of one part under a pose list: W = W(parent) · L.
// Parts the list leaves out contribute identity; a loop is cut where found.
world_xf :: proc(doc: ^Doc, poses: []State_Part, name: string, depth := 0) -> Xf {
	part := part_of(doc, name)
	if part == nil || depth > 64 do return XF_ID
	sp: ^State_Part
	for &p in poses do if p.part == name {
		sp = &p
		break
	}
	local := local_xf(part, sp)
	if part.parent == "" do return local
	return xf_mul(world_xf(doc, poses, part.parent, depth + 1), local)
}

// ------------------------------------------------------------ clips (1.1)

clip_duration :: proc(c: ^Clip) -> f32 {
	return len(c.keys) > 0 ? c.keys[len(c.keys) - 1].t : 0
}

// 1.2: a CSS-style cubic bezier from (0,0) to (1,1): y at time x.
bezier :: proc(cv: [4]f32, x: f32) -> f32 {
	if x <= 0 do return 0
	if x >= 1 do return 1
	cx := 3 * cv[0]
	bx := 3 * (cv[2] - cv[0]) - cx
	ax := 1 - cx - bx
	cy := 3 * cv[1]
	by := 3 * (cv[3] - cv[1]) - cy
	ay := 1 - cy - by
	sx := #force_inline proc(ax, bx, cx, t: f32) -> f32 {return ((ax * t + bx) * t + cx) * t}
	t := x
	for _ in 0 ..< 8 {
		d := (3 * ax * t + 2 * bx) * t + cx
		if abs(d) < 1e-6 do break
		e := sx(ax, bx, cx, t) - x
		if abs(e) < 1e-6 do break
		t -= e / d
	}
	if t < 0 || t > 1 || abs(sx(ax, bx, cx, t) - x) > 1e-4 {
		lo, hi: f32 = 0, 1
		for _ in 0 ..< 24 {
			t = (lo + hi) / 2
			if sx(ax, bx, cx, t) < x do lo = t
			else do hi = t
		}
	}
	return ((ay * t + by) * t + cy) * t
}

// The eased fraction toward a key: its curve (1.2) wins over its ease.
ease_key :: proc(u: f32, k: ^Clip_Key) -> f32 {
	if len(k.curve) == 4 do return bezier({k.curve[0], k.curve[1], k.curve[2], k.curve[3]}, clamp(u, 0, 1))
	return ease(u, k.ease)
}

ease :: proc(u: f32, kind: string) -> f32 {
	x := clamp(u, 0, 1)
	switch kind {
	case "in":
		return x * x
	case "out":
		return 1 - (1 - x) * (1 - x)
	case "in-out":
		return x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x)
	case "step":
		return x >= 1 ? 1 : 0
	}
	return x
}

key_poses :: proc(doc: ^Doc, k: ^Clip_Key) -> []State_Part {
	if len(k.parts) > 0 || k.state == "" do return k.parts[:]
	if st := state_of(doc, k.state); st != nil do return st.parts[:]
	return nil
}

lerp_angle :: proc(a, b, u: f32) -> f32 {
	d := math.mod(b - a, math.TAU)
	if d > math.PI do d -= math.TAU
	if d < -math.PI do d += math.TAU
	return a + d * u
}

// The frame at time t, into `out` (cleared first): membership and order
// from the outgoing key, poses tweened toward the incoming one.
sample_clip :: proc(doc: ^Doc, c: ^Clip, t: f32, out: ^[dynamic]State_Part) {
	clear(out)
	n := len(c.keys)
	if n == 0 do return
	dur := clip_duration(c)
	time := t
	if c.loop && dur > 0 do time = math.mod(math.mod(t, dur) + dur, dur)
	if time <= c.keys[0].t {
		append(out, ..key_poses(doc, &c.keys[0]))
		return
	}
	if time >= c.keys[n - 1].t {
		append(out, ..key_poses(doc, &c.keys[n - 1]))
		return
	}
	i := 0
	for i + 1 < n && c.keys[i + 1].t <= time do i += 1
	A, B := &c.keys[i], &c.keys[i + 1]
	span := B.t - A.t
	u := ease_key(span > 0 ? (time - A.t) / span : 1, B)
	to := key_poses(doc, B)
	for a in key_poses(doc, A) {
		b: ^State_Part
		for &q in to do if q.part == a.part {
			b = &q
			break
		}
		if b == nil {
			append(out, a)
			continue
		}
		sa := a.scale == 0 ? f32(1) : a.scale
		sb := b.scale == 0 ? f32(1) : b.scale
		append(out, State_Part{
			part   = a.part,
			offset = a.offset + (b.offset - a.offset) * u,
			rotate = lerp_angle(a.rotate, b.rotate, u),
			scale  = sa + (sb - sa) * u,
			mirror = a.mirror, // a flip does not tween: the outgoing key's
		})
	}
}

// ------------------------------------------------------------ 1.2: targets, events, blending

// The targets a key carries: its own, else its state's.
key_targets :: proc(doc: ^Doc, k: ^Clip_Key) -> []Target {
	if len(k.targets) > 0 || k.state == "" do return k.targets[:]
	if st := state_of(doc, k.state); st != nil do return st.targets[:]
	return nil
}

// Where the chains should reach at time t, into `out`: tweened where
// both keys name a chain, else the outgoing key's.
sample_targets :: proc(doc: ^Doc, c: ^Clip, t: f32, out: ^[dynamic]Target) {
	clear(out)
	n := len(c.keys)
	if n == 0 do return
	dur := clip_duration(c)
	time := t
	if c.loop && dur > 0 do time = math.mod(math.mod(t, dur) + dur, dur)
	if time <= c.keys[0].t {
		append(out, ..key_targets(doc, &c.keys[0]))
		return
	}
	if time >= c.keys[n - 1].t {
		append(out, ..key_targets(doc, &c.keys[n - 1]))
		return
	}
	i := 0
	for i + 1 < n && c.keys[i + 1].t <= time do i += 1
	A, B := &c.keys[i], &c.keys[i + 1]
	span := B.t - A.t
	u := ease_key(span > 0 ? (time - A.t) / span : 1, B)
	to := key_targets(doc, B)
	for a in key_targets(doc, A) {
		b: ^Target
		for &q in to do if q.chain == a.chain {
			b = &q
			break
		}
		if b == nil {
			append(out, a)
			continue
		}
		append(out, Target{chain = a.chain, at = a.at + (b.at - a.at) * u})
	}
}

// The events the playhead crossed from t0 to t1, appended to `out`: keys
// with a time in (t0, t1]. On a loop the interval may wrap; the wrap key
// (the last one) never fires, since the first key at 0 stands for it.
clip_events :: proc(c: ^Clip, t0, t1: f32, out: ^[dynamic]string) {
	dur := clip_duration(c)
	if len(c.keys) == 0 do return
	fire :: proc(c: ^Clip, lo, hi: f32, wrap_end: bool, out: ^[dynamic]string) {
		for &k in c.keys {
			if len(k.events) == 0 do continue
			if k.t > lo && (wrap_end ? k.t < hi : k.t <= hi) do append(out, ..k.events[:])
		}
	}
	if !c.loop || dur <= 0 {
		fire(c, t0, t1, false, out)
		return
	}
	if t1 - t0 >= dur {
		fire(c, -1e30, dur, true, out)
		return
	}
	a := math.mod(math.mod(t0, dur) + dur, dur)
	b := math.mod(math.mod(t1, dur) + dur, dur)
	if b >= a {
		fire(c, a, b, false, out)
	} else {
		fire(c, a, dur, true, out)
		fire(c, -1, b, false, out)
	}
}

@(private)
mix_pose :: proc(doc: ^Doc, a, b: ^State_Part, u: f32, mirror: bool) -> State_Part {
	sa := a.scale == 0 ? f32(1) : a.scale
	sb := b.scale == 0 ? f32(1) : b.scale
	return {
		part   = a.part,
		offset = a.offset + (b.offset - a.offset) * u,
		rotate = lerp_angle(a.rotate, b.rotate, u),
		scale  = sa + (sb - sa) * u,
		mirror = mirror,
	}
}

// Two poses at once: parts in both tween by w; membership and paint
// order come from the heavier side (b once w reaches 0.5). A crossfade
// is this with a ramping w.
blend_poses :: proc(doc: ^Doc, a, b: []State_Part, w: f32, out: ^[dynamic]State_Part) {
	clear(out)
	u := clamp(w, 0, 1)
	lead, other := a, b
	if u >= 0.5 do lead, other = b, a
	for &sp in lead {
		o: ^State_Part
		for &q in other do if q.part == sp.part {
			o = &q
			break
		}
		if o == nil {
			append(out, sp)
			continue
		}
		if u < 0.5 do append(out, mix_pose(doc, &sp, o, u, sp.mirror))
		else do append(out, mix_pose(doc, o, &sp, u, sp.mirror))
	}
}

// A layer over a base: parts the layer names tween toward it by w, the
// rest keep the base pose; the base's order stands, and a part only the
// layer has joins the end once w reaches 0.5.
layer_poses :: proc(doc: ^Doc, base, over: []State_Part, w: f32, out: ^[dynamic]State_Part) {
	clear(out)
	u := clamp(w, 0, 1)
	for &sp in base {
		o: ^State_Part
		for &q in over do if q.part == sp.part {
			o = &q
			break
		}
		if o == nil do append(out, sp)
		else do append(out, mix_pose(doc, &sp, o, u, u < 0.5 ? sp.mirror : o.mirror))
	}
	if u >= 0.5 {
		for &q in over {
			have := false
			for &sp in base do if sp.part == q.part {
				have = true
				break
			}
			if !have do append(out, q)
		}
	}
}

// ------------------------------------------------------------ 1.2: solving chains
// Cyclic coordinate descent on the chain parts' rotations, the same
// algorithm as @fastart/core, so a target solved here lands where the
// studio put it.

// The anchor a constraint reaches with.
chain_end :: proc(doc: ^Doc, c: ^Constraint) -> (part: ^Part, at: V2, ok: bool) {
	slash := -1
	for ch, i in c.end do if ch == '/' {
		slash = i
		break
	}
	if slash < 0 || len(c.chain) == 0 do return
	pname, aname := c.end[:slash], c.end[slash + 1:]
	if c.chain[len(c.chain) - 1] != pname do return
	part = part_of(doc, pname)
	if part == nil do return
	a := anchor_of(doc, part, aname)
	if a == nil do return
	return part, a.at, true
}

// Where a chain's end anchor sits in the world under a pose list.
chain_end_world :: proc(doc: ^Doc, poses: []State_Part, c: ^Constraint) -> (V2, bool) {
	part, at, ok := chain_end(doc, c)
	if !ok do return {}, false
	return xf_apply(world_xf(doc, poses, part.name), at), true
}

@(private)
wrap_angle :: proc(a: f32) -> f32 {
	r := math.mod(a, math.TAU)
	if r > math.PI do r -= math.TAU
	if r < -math.PI do r += math.TAU
	return r
}

// Turn the chain's parts so the end anchor reaches `target` (document
// space), editing `poses` in place: entries are added for chain parts
// the list lacks, and only `rotate` changes. Returns the distance left.
solve_chain :: proc(doc: ^Doc, poses: ^[dynamic]State_Part, c: ^Constraint, target: V2, iterations := 16, tolerance: f32 = 0.01) -> f32 {
	end_part, end_at, ok := chain_end(doc, c)
	if !ok do return 1e30
	for name in c.chain {
		found := false
		for &sp in poses do if sp.part == name {
			found = true
			break
		}
		if !found {
			part := part_of(doc, name)
			append(poses, State_Part{part = name, offset = part == nil ? V2{} : part.pivot})
		}
	}
	// a nudge toward the preferred bend, so a straight elbow knows which way to fold
	if c.bend != 0 && len(c.chain) >= 2 {
		last := c.chain[len(c.chain) - 1]
		for &sp in poses do if sp.part == last && sp.rotate == 0 {
			sp.rotate = 0.02 * f32(c.bend)
		}
	}
	dist: f32 = 1e30
	for _ in 0 ..< iterations {
		for i := len(c.chain) - 1; i >= 0; i -= 1 {
			part := part_of(doc, c.chain[i])
			if part == nil do continue
			e := xf_apply(world_xf(doc, poses[:], end_part.name), end_at)
			j := xf_apply(world_xf(doc, poses[:], part.name), part.pivot)
			a1 := math.atan2(e.y - j.y, e.x - j.x)
			a2 := math.atan2(target.y - j.y, target.x - j.x)
			// under a mirrored ancestor a turn in the parent's frame reads backwards
			sign: f32 = 1
			if part.parent != "" && xf_flipped(world_xf(doc, poses[:], part.parent)) do sign = -1
			for &sp in poses do if sp.part == part.name {
				sp.rotate = wrap_angle(sp.rotate + sign * (a2 - a1))
				break
			}
		}
		e, eok := chain_end_world(doc, poses[:], c)
		if !eok do return 1e30
		d := e - target
		dist = math.sqrt(d.x * d.x + d.y * d.y)
		if dist < tolerance do break
	}
	return dist
}

// Reach every target a pose carries, in place. A runtime that solves
// live calls this after sample_clip, with sample_targets' output.
solve_targets :: proc(doc: ^Doc, poses: ^[dynamic]State_Part, targets: []Target) {
	for tg in targets {
		if c := constraint_of(doc, tg.chain); c != nil do solve_chain(doc, poses, c, tg.at)
	}
}

// ------------------------------------------------------------ triangulation
// Ear clipping, O(n^2): editors bake this into `tris` on save.

triangulate :: proc(pts: []V2, out: ^[dynamic]u16) {
	clear(out)
	n := len(pts)
	if n < 3 do return
	idx := make([dynamic]u16, 0, n, context.temp_allocator)
	// winding: signed area
	area: f32
	for i in 0 ..< n {
		j := (i + 1) % n
		area += pts[i].x * pts[j].y - pts[j].x * pts[i].y
	}
	if area < 0 {
		for i := n - 1; i >= 0; i -= 1 do append(&idx, u16(i))
	} else {
		for i in 0 ..< n do append(&idx, u16(i))
	}
	cross :: proc(o, a, b: V2) -> f32 {
		return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
	}
	inside :: proc(a, b, c, p: V2) -> bool {
		return cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
	}
	guard := 0
	for len(idx) > 3 && guard < 10000 {
		guard += 1
		clipped := false
		m := len(idx)
		for i in 0 ..< m {
			i0 := idx[(i + m - 1) % m]
			i1 := idx[i]
			i2 := idx[(i + 1) % m]
			a, b, c := pts[i0], pts[i1], pts[i2]
			if cross(a, b, c) <= 0 do continue // reflex
			ear := true
			for k in 0 ..< m {
				kk := idx[k]
				if kk == i0 || kk == i1 || kk == i2 do continue
				if inside(a, b, c, pts[kk]) {
					ear = false
					break
				}
			}
			if !ear do continue
			append(out, i0, i1, i2)
			ordered_remove(&idx, i)
			clipped = true
			break
		}
		if !clipped do break // degenerate; caller may fan
	}
	if len(idx) == 3 do append(out, idx[0], idx[1], idx[2])
}

// ------------------------------------------------------------ game helpers
// Length of a document along x from its collision capsule, or a guess.
doc_length :: proc(doc: ^Doc) -> f32 {
	for c in doc.collision do if c.kind == "line" do return abs(c.b.x - c.a.x)
	return 20
}
