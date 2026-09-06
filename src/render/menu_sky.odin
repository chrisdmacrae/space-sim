package render

// The start menu's sky. Screen space, wall clock and no sim: the menu only
// has to look like somewhere worth flying. Laid out from one seed so it
// always opens on the same view, with the nebula banks kept to the edges so
// the middle stays dark under the buttons — a distant sun, a ringed gas
// giant with its moon, a habitat wheel turning, traffic crossing on its own
// errands, the odd comet, and dust near enough to streak past.
//
// The gas is baked into a texture once (see bake_clouds) and everything else
// is drawn live, in one back-to-front pass: wash, gas, the flat starfield,
// bright stars, sun, far traffic, the planet and its rings, the station,
// near traffic, comets, dust, and a scrim to keep the buttons legible.

import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import art "sim:art"
import core "sim:core"

SKY_SEED    :: 0x5EA0F57A
SKY_CLOUDS  :: 5
SKY_STARS   :: 120
SKY_TRAFFIC :: 8
SKY_MOTES   :: 70
SKY_COMETS  :: 2

// Composition, in fractions of the screen. Everything sits out towards the
// corners; the menu column owns the middle.
SKY_SUN_X     :: 0.845
SKY_SUN_Y     :: 0.150
SKY_PLANET_X  :: 0.150
SKY_PLANET_Y  :: 1.070
SKY_PLANET_R  :: 0.300 // of screen height
SKY_RING_TILT :: -0.28 // radians
SKY_STATION_X :: 0.305
SKY_STATION_Y :: 0.660

SKY_SHIP_DOCS := [?]string{"courier", "hauler", "clipper", "freighter", "sleeper"}

// The gas is baked once into a texture: thousands of soft puffs, filaments
// walked along a curve and dust lanes carved back out of them. Doing that
// every frame would buy nothing — a nebula does not move — and no amount of
// per-frame circles gets the same depth.
@(private = "file")
Cloud_Spec :: struct {
	x, y: f32, // centre, in fractions of the screen
	r:    f32, // radius, in fractions of the screen height
	col:  [3]u8,
	gain: f32, // brightness: the banks carry the colour, the veil stays faint
}

// Kept to the edges and corners: the middle of the screen is the menu's.
@(private = "file")
SKY_CLOUD_SPEC := [SKY_CLOUDS]Cloud_Spec {
	{0.07, 0.47, 0.50, {40, 116, 140}, 1.00}, // teal bank, left
	{0.96, 0.58, 0.46, {128, 60, 106}, 0.85},  // rose bank, right
	{0.52, -0.12, 0.78, {46, 58, 130}, 0.45},  // indigo veil across the top
	{0.81, 0.20, 0.40, {170, 116, 58}, 0.32},  // warm haze around the sun
	{0.74, 1.06, 0.42, {72, 56, 130}, 0.80},   // violet, low right
}

@(private = "file")
Sky_Star :: struct {
	at:    [2]f32, // screen fraction, parallaxed like the flat field
	depth: f32,
	size:  f32,
	rate:  f32,
	phase: f32,
	col:   [3]u8,
	spike: bool,
}

@(private = "file")
Sky_Ship :: struct {
	at:      rl.Vector2,
	dir:     rl.Vector2, // unit
	speed:   f32,        // px per second
	length:  f32,        // on-screen length in px: distance, in effect
	doc:     int,
	shade:   f32,        // hull grey before the distance haze
	burning: bool,
	timer:   f32,        // seconds until the engine changes its mind
	plume:   f32,        // eased 0..1, so the flame does not snap on
	phase:   f32,
}

@(private = "file")
Sky_Comet :: struct {
	at:    rl.Vector2,
	vel:   rl.Vector2,
	life:  f32, // seconds left in the pass
	wait:  f32, // seconds until the next one
	size:  f32,
}

@(private = "file")
Sky_Mote :: struct {
	at:    rl.Vector2,
	speed: f32,
	size:  f32,
	a:     f32,
}

Menu_Sky :: struct {
	inited:  bool,
	t:       f32, // seconds the menu has been up
	w, h:    f32, // the screen the layout was built for
	rng:     core.Rng, // respawns draw from here, so the layout keeps its own seed
	tex:     rl.RenderTexture2D, // the baked nebula field: the screen plus a margin
	has_tex: bool,
	margin:  f32, // how far the field overhangs the screen, for the drift
	stars:   [SKY_STARS]Sky_Star,
	ships:   [SKY_TRAFFIC]Sky_Ship,
	comets:  [SKY_COMETS]Sky_Comet,
	motes:   [SKY_MOTES]Sky_Mote,
}

@(private = "file")
rf :: proc(r: ^core.Rng, lo, hi: f32) -> f32 {
	return f32(core.rng_range(r, f64(lo), f64(hi)))
}

@(private = "file")
tint :: proc(c: [3]u8, a: f32) -> rl.Color {
	return {c[0], c[1], c[2], u8(clamp(a, 0, 255))}
}

@(private = "file")
clear_col :: proc(c: [3]u8) -> rl.Color {
	return {c[0], c[1], c[2], 0}
}

// Scale a colour towards black. Distance is haze in an atmosphere and plain
// dimness in a vacuum, so far ships are drawn darker rather than faded.
@(private = "file")
dim :: proc(c: [4]u8, k: f32) -> [4]u8 {
	return {u8(clamp(f32(c[0]) * k, 0, 255)), u8(clamp(f32(c[1]) * k, 0, 255)), u8(clamp(f32(c[2]) * k, 0, 255)), c[3]}
}

@(private = "file")
unit :: proc(v: rl.Vector2) -> rl.Vector2 {
	l := math.sqrt(v.x * v.x + v.y * v.y)
	if l < 1e-6 do return {1, 0}
	return {v.x / l, v.y / l}
}

// ---------------------------------------------------------------- layout

menu_sky_init :: proc(sky: ^Menu_Sky, seed: u64) {
	w := max(f32(rl.GetScreenWidth()), 1)
	h := max(f32(rl.GetScreenHeight()), 1)
	sky^ = Menu_Sky{inited = true, w = w, h = h}
	sky.rng = core.rng_make(seed ~ 0x51E5CA11)
	sky.margin = w * 0.06
	r := core.rng_make(seed)

	// Bright stars over the flat field: these are the ones that twinkle.
	for &s in sky.stars {
		s.at = {rf(&r, 0, 1), rf(&r, 0, 1)}
		s.depth = rf(&r, 0.25, 1)
		s.size = rf(&r, 0.7, 1.9) * s.depth
		s.rate = rf(&r, 0.6, 2.6)
		s.phase = rf(&r, 0, math.TAU)
		s.spike = core.rng_chance(&r, 0.08)
		switch core.rng_int(&r, 0, 5) {
		case 0:  s.col = {255, 214, 176} // warm
		case 1:  s.col = {198, 216, 255} // blue-white
		case 2:  s.col = {255, 236, 210}
		case:    s.col = {226, 234, 250}
		}
	}

	for &s in sky.ships do sky_ship_spawn(sky, &s, true)
	for &c in sky.comets do c.wait = rf(&sky.rng, 4, 40)
	for &m in sky.motes {
		m.at = {rf(&r, 0, w), rf(&r, 0, h)}
		m.speed = rf(&r, 26, 90)
		m.size = rf(&r, 0.8, 1.8)
		m.a = rf(&r, 22, 70)
	}
}

// A ship enters from one side and crosses. `first` scatters it over the
// screen instead, so the menu opens mid-traffic rather than empty.
@(private = "file")
sky_ship_spawn :: proc(sky: ^Menu_Sky, s: ^Sky_Ship, first := false) {
	r := &sky.rng
	s.doc = core.rng_int(r, 0, len(SKY_SHIP_DOCS))
	s.length = rf(r, 9, 26)
	if core.rng_chance(r, 0.18) do s.length = rf(r, 40, 76) // a close pass
	near := clamp((s.length - 9) / 67, 0, 1)
	s.speed = rf(r, 6, 15) + near * 44
	s.shade = rf(r, 100, 168)
	s.burning = core.rng_chance(r, 0.45)
	s.timer = rf(r, 1.5, 7)
	s.plume = s.burning ? 1 : 0
	s.phase = rf(r, 0, math.TAU)
	from_right := core.rng_chance(r, 0.5)
	a := rf(r, -0.17, 0.17) + (from_right ? f32(math.PI) : 0)
	s.dir = {math.cos(a), math.sin(a)}
	s.at.y = rf(r, 0.04, 0.99) * sky.h
	s.at.x = from_right ? sky.w + s.length * 1.5 : -s.length * 1.5
	if first do s.at.x = rf(r, 0, sky.w)
}

// ---------------------------------------------------------------- update

menu_sky_update :: proc(sky: ^Menu_Sky, dt: f32) {
	w := max(f32(rl.GetScreenWidth()), 1)
	h := max(f32(rl.GetScreenHeight()), 1)
	if !sky.inited || sky.w != w || sky.h != h {
		menu_sky_release(sky)
		menu_sky_init(sky, SKY_SEED)
	}
	step := clamp(dt, 0, 0.1) // a stall must not teleport the traffic
	sky.t += step

	for &s in sky.ships {
		s.at += s.dir * (s.speed * step)
		s.timer -= step
		if s.timer <= 0 {
			s.burning = !s.burning
			s.timer = s.burning ? rf(&sky.rng, 1.5, 5) : rf(&sky.rng, 3, 11)
		}
		goal: f32 = s.burning ? 1 : 0
		s.plume += (goal - s.plume) * min(step * 2.2, 1)
		m := s.length * 2 + 60
		if s.at.x < -m || s.at.x > w + m || s.at.y < -m || s.at.y > h + m do sky_ship_spawn(sky, &s)
	}

	for &c in sky.comets {
		if c.life > 0 {
			c.at += c.vel * step
			c.life -= step
			continue
		}
		c.wait -= step
		if c.wait > 0 do continue
		// Falls in across a corner, always with some way still to go.
		r := &sky.rng
		down := core.rng_chance(r, 0.6)
		speed := rf(r, 120, 260)
		a := rf(r, 0.25, 0.75) * (down ? 1 : -1)
		c.vel = {-math.cos(a) * speed, math.sin(a) * speed}
		c.at = {w + 80, down ? rf(r, -60, h * 0.35) : rf(r, h * 0.7, h + 60)}
		c.size = rf(r, 1.4, 3.0)
		c.life = (w + 260) / speed
		c.wait = rf(r, 14, 55)
	}

	for &m in sky.motes {
		m.at.x -= m.speed * step
		if m.at.x < -4 {
			m.at = {w + 4, rf(&sky.rng, 0, h)}
			m.speed = rf(&sky.rng, 26, 90)
			m.a = rf(&sky.rng, 22, 70)
		}
	}
}

// ----------------------------------------------------------------- draw

menu_sky_draw :: proc(sky: ^Menu_Sky, sf: ^Starfield, cam: ^Camera, lib: ^art.Library) {
	if !sky.inited do menu_sky_init(sky, SKY_SEED)
	w := sky.w
	h := sky.h
	sun := rl.Vector2{SKY_SUN_X * w, SKY_SUN_Y * h}
	planet := rl.Vector2{SKY_PLANET_X * w, SKY_PLANET_Y * h}
	pr := SKY_PLANET_R * h

	draw_sky_wash(w, h)
	draw_sky_clouds(sky)
	draw_starfield(sf, cam)
	draw_sky_stars(sky, cam)
	draw_sky_sun(sun, sky.t)

	// Far traffic passes behind the planet, near traffic in front of it.
	for &s in sky.ships do if s.length < 20 do draw_sky_ship(&s, sky.t, lib)
	draw_sky_moon(sky, lib, planet, pr, sun, false)
	draw_sky_rings(planet, pr, sun, false)
	draw_sky_planet(sky, lib, planet, pr, sun)
	draw_sky_rings(planet, pr, sun, true)
	draw_sky_moon(sky, lib, planet, pr, sun, true)
	draw_sky_station(sky, lib, {SKY_STATION_X * w, SKY_STATION_Y * h})
	for &s in sky.ships do if s.length >= 20 do draw_sky_ship(&s, sky.t, lib)
	for &c in sky.comets do draw_sky_comet(&c, sun)
	rl.BeginBlendMode(.ADDITIVE)
	for &m in sky.motes {
		rl.DrawCircleV(m.at, m.size, {170, 190, 230, u8(m.a)})
	}
	rl.EndBlendMode()
	draw_sky_scrim(w, h)
}

// The void is not quite black: a cold cast in one corner, a warm one in the
// other, and bands top and bottom to seat the menu.
@(private = "file")
draw_sky_wash :: proc(w, h: f32) {
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawCircleGradient({w * 0.06, h * 0.08}, h * 0.85, {24, 38, 74, 22}, {24, 38, 74, 0})
	rl.DrawCircleGradient({w * 0.97, h * 0.94}, h * 0.75, {56, 30, 60, 20}, {56, 30, 60, 0})
	rl.EndBlendMode()
}

// Bake the gas. Thousands of soft puffs accumulate as light (colour weighted
// by alpha, alpha summed, exactly as the galaxy map does it), then dust lanes
// are drawn back over them in near-black so the field is carved rather than
// merely piled up. The result is one texture, drawn additively ever after.
@(private = "file")
bake_clouds :: proc(sky: ^Menu_Sky) {
	w := sky.w
	h := sky.h
	m := sky.margin
	sky.tex = rl.LoadRenderTexture(i32(w + m * 2), i32(h + m * 2))
	rl.SetTextureFilter(sky.tex.texture, .BILINEAR)
	sky.has_tex = true
	r := core.rng_make(SKY_SEED ~ 0xC10D5)

	// Local cloud coordinates: turned by the cloud's own angle, stretched
	// along it, and scaled by its radius.
	put :: proc(cx, cy, rad, ca, sa, lx, ly: f32) -> rl.Vector2 {
		return {cx + (lx * ca - ly * sa) * rad, cy + (lx * sa + ly * ca) * rad}
	}

	rl.BeginTextureMode(sky.tex)
	rl.ClearBackground(rl.BLANK)
	rlgl.SetBlendFactorsSeparate(rlgl.SRC_ALPHA, rlgl.ONE, rlgl.ONE, rlgl.ONE, rlgl.FUNC_ADD, rlgl.FUNC_ADD)
	rl.BeginBlendMode(.CUSTOM_SEPARATE)
	for spec in SKY_CLOUD_SPEC {
		cx := m + spec.x * w
		cy := m + spec.y * h
		rad := spec.r * h
		ang := rf(&r, 0, math.TAU)
		ca := math.cos(ang)
		sa := math.sin(ang)
		long := rf(&r, 1.15, 1.9)
		col := spec.col
		// Lobes: the gas gathers around a handful of centres instead of
		// filling a disc, which is what stops it reading as a smudge.
		LOBES :: 9
		lobes: [LOBES][3]f32
		for &l in lobes {
			u := rf(&r, 0, math.TAU)
			d := rf(&r, 0, 0.85)
			l = {math.cos(u) * d * long, math.sin(u) * d * 0.58, rf(&r, 0.45, 1)}
		}
		// Haze, then body: the wide soft glow and the grain inside it.
		for pass in 0 ..< 2 {
			n := pass == 0 ? 260 : 1100
			for _ in 0 ..< n {
				l := lobes[core.rng_int(&r, 0, LOBES)]
				u := rf(&r, 0, math.TAU)
				d := rf(&r, 0, 1) * rf(&r, 0, 1) * (pass == 0 ? f32(0.75) : 0.55)
				lx := l.x + math.cos(u) * d * long
				ly := l.y + math.sin(u) * d * 0.58
				pr := rad * (pass == 0 ? rf(&r, 0.18, 0.46) : rf(&r, 0.055, 0.19))
				a := (pass == 0 ? rf(&r, 2.5, 6) : rf(&r, 4, 10)) * spec.gain * l.z
				rl.DrawCircleGradient(put(cx, cy, rad, ca, sa, lx, ly), pr, tint(col, a), clear_col(col))
			}
		}
		// Filaments: a chain of small puffs walked along a curving path.
		for _ in 0 ..< 26 {
			l := lobes[core.rng_int(&r, 0, LOBES)]
			u := rf(&r, 0, math.TAU)
			d := rf(&r, 0, 0.5)
			walk := [2]f32{l.x + math.cos(u) * d * long, l.y + math.sin(u) * d * 0.58}
			a2 := rf(&r, 0, math.TAU)
			sl := rf(&r, 0.020, 0.038)
			step := [2]f32{math.cos(a2) * sl, math.sin(a2) * sl}
			bright := rf(&r, 7, 15) * spec.gain * l.z
			for _ in 0 ..< 34 {
				turn := rf(&r, -0.22, 0.22)
				cs := math.cos(turn)
				sn := math.sin(turn)
				step = {step.x * cs - step.y * sn, step.x * sn + step.y * cs}
				walk += step
				pr := rad * rf(&r, 0.012, 0.030)
				rl.DrawCircleGradient(put(cx, cy, rad, ca, sa, walk.x, walk.y), pr, tint(col, bright), clear_col(col))
			}
		}
		// A few young stars caught inside the gas, each in its own halo.
		for _ in 0 ..< 6 {
			l := lobes[core.rng_int(&r, 0, LOBES)]
			u := rf(&r, 0, math.TAU)
			d := rf(&r, 0, 0.45)
			p := put(cx, cy, rad, ca, sa, l.x + math.cos(u) * d * long, l.y + math.sin(u) * d * 0.58)
			k := rf(&r, 0.4, 1) * spec.gain
			rl.DrawCircleGradient(p, rad * 0.05, tint(col, 11 * k), clear_col(col))
			rl.DrawCircleGradient(p, 8, {226, 238, 255, u8(clamp(120 * k, 0, 255))}, {226, 238, 255, 0})
			rl.DrawCircleV(p, 1.3, {242, 248, 255, 255})
		}
	}
	rl.EndBlendMode()
	// Dust lanes: drawn over the light in near-black, so the gas behind them
	// adds less. Walked like the filaments, and a little wider.
	for spec in SKY_CLOUD_SPEC {
		cx := m + spec.x * w
		cy := m + spec.y * h
		rad := spec.r * h
		ang := rf(&r, 0, math.TAU)
		ca := math.cos(ang)
		sa := math.sin(ang)
		for _ in 0 ..< 13 {
			u := rf(&r, 0, math.TAU)
			d := rf(&r, 0, 0.7)
			walk := [2]f32{math.cos(u) * d, math.sin(u) * d * 0.6}
			a2 := rf(&r, 0, math.TAU)
			sl := rf(&r, 0.030, 0.055)
			step := [2]f32{math.cos(a2) * sl, math.sin(a2) * sl}
			a := rf(&r, 26, 60)
			for _ in 0 ..< 40 {
				turn := rf(&r, -0.2, 0.2)
				cs := math.cos(turn)
				sn := math.sin(turn)
				step = {step.x * cs - step.y * sn, step.x * sn + step.y * cs}
				walk += step
				pr := rad * rf(&r, 0.025, 0.065)
				rl.DrawCircleGradient(put(cx, cy, rad, ca, sa, walk.x, walk.y), pr, {2, 3, 8, u8(a)}, {2, 3, 8, 0})
			}
		}
	}
	rl.EndTextureMode()
}

// Give back the baked field. The menu is long-lived, so this only matters on
// a resize and at shutdown.
menu_sky_release :: proc(sky: ^Menu_Sky) {
	if !sky.has_tex do return
	rl.UnloadRenderTexture(sky.tex)
	sky.has_tex = false
}

// The field itself: baked on first sight, then drifted a fraction of its
// margin and swelled a little, so it breathes without ever showing an edge.
@(private = "file")
draw_sky_clouds :: proc(sky: ^Menu_Sky) {
	if !sky.has_tex do bake_clouds(sky)
	m := sky.margin
	dx := math.sin(sky.t * 0.017) * m * 0.55
	dy := math.sin(sky.t * 0.011 + 1.3) * m * 0.35
	swell := u8(clamp(138 + 18 * math.sin(sky.t * 0.06), 0, 255))
	tw := f32(sky.tex.texture.width)
	th := f32(sky.tex.texture.height)
	src := rl.Rectangle{0, 0, tw, -th} // render textures come out bottom-up
	dst := rl.Rectangle{-m + dx, -m + dy, tw, th}
	rlgl.SetBlendFactors(rlgl.ONE, rlgl.ONE, rlgl.FUNC_ADD)
	rl.BeginBlendMode(.CUSTOM)
	rl.DrawTexturePro(sky.tex.texture, src, dst, {0, 0}, 0, {swell, swell, swell, 255})
	rl.EndBlendMode()
}

@(private = "file")
draw_sky_stars :: proc(sky: ^Menu_Sky, cam: ^Camera) {
	w := sky.w
	h := sky.h
	// The same parallax basis as the flat field, so the two move together.
	ox := f32(math.mod(cam.target.x * 0.002, 1.0))
	oy := f32(math.mod(-cam.target.y * 0.002, 1.0))
	limit := int(clamp(f32(SKY_STARS) * core.gfx.star_density, 0, SKY_STARS))
	rl.BeginBlendMode(.ADDITIVE)
	for s, i in sky.stars {
		if i >= limit do break
		x := math.mod(s.at.x + ox * s.depth + 2, 1) * w
		y := math.mod(s.at.y + oy * s.depth + 2, 1) * h
		k := 0.55 + 0.45 * math.sin(sky.t * s.rate + s.phase)
		p := rl.Vector2{x, y}
		rl.DrawCircleGradient(p, s.size * 5, tint(s.col, 40 * k * s.depth), clear_col(s.col))
		rl.DrawCircleV(p, s.size * 0.75, tint(s.col, 130 + 110 * k))
		if s.spike {
			l := s.size * 5 * k
			rl.DrawLineEx({x - l, y}, {x + l, y}, 1, tint(s.col, 30 * k))
			rl.DrawLineEx({x, y - l * 0.45}, {x, y + l * 0.45}, 1, tint(s.col, 22 * k))
		}
	}
	rl.EndBlendMode()
}

// The system's star, far enough off that it is a bright point with a halo
// and a little flare down the diagonal.
@(private = "file")
draw_sky_sun :: proc(at: rl.Vector2, t: f32) {
	g := clamp(core.tuning.star_glow_scale, 0.3, 2.5)
	pulse := 1 + 0.03 * math.sin(t * 0.9)
	warm := [3]u8{255, 206, 148}
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawCircleGradient(at, 150 * g * pulse, tint(warm, 34), clear_col(warm))
	rl.DrawCircleGradient(at, 62 * g * pulse, tint(warm, 70), clear_col(warm))
	rl.DrawCircleGradient(at, 22 * g * pulse, {255, 240, 214, 190}, {255, 240, 214, 0})
	// Diffraction: a long horizontal spike and a short vertical one.
	for k in 0 ..< 2 {
		l := (k == 0 ? f32(190) : 70) * g * pulse
		wdt := k == 0 ? f32(1.6) : 1.2
		if k == 0 {
			rl.DrawLineEx({at.x - l, at.y}, {at.x + l, at.y}, wdt, tint(warm, 26))
		} else {
			rl.DrawLineEx({at.x, at.y - l}, {at.x, at.y + l}, wdt, tint(warm, 22))
		}
	}
	rl.DrawCircleV(at, 5.5, {255, 250, 238, 235})
	rl.EndBlendMode()
}

// Ghostly reflections of the sun down the lens, plus a soft darkening in the
// middle so the buttons keep their contrast over a bright cloud.
@(private = "file")
draw_sky_scrim :: proc(w, h: f32) {
	c := rl.Vector2{w * 0.5, h * 0.5}
	sun := rl.Vector2{SKY_SUN_X * w, SKY_SUN_Y * h}
	d := rl.Vector2{c.x - sun.x, c.y - sun.y}
	rl.BeginBlendMode(.ADDITIVE)
	for k in 1 ..= 3 {
		f := f32(k) * 0.62
		p := rl.Vector2{sun.x + d.x * f * 2, sun.y + d.y * f * 2}
		rl.DrawCircleGradient(p, 26 - f32(k) * 5, {255, 190, 130, u8(16 - k * 3)}, {255, 190, 130, 0})
	}
	rl.EndBlendMode()
	rl.DrawCircleGradient(c, h * 0.52, {4, 6, 12, 62}, {4, 6, 12, 0})
	rl.DrawRectangleGradientV(0, 0, i32(w), i32(h * 0.18), {4, 6, 12, 120}, {4, 6, 12, 0})
	rl.DrawRectangleGradientV(0, i32(h * 0.80), i32(w), i32(h * 0.20) + 1, {4, 6, 12, 0}, {4, 6, 12, 130})
}

// ------------------------------------------------------------- the planet

@(private = "file")
draw_sky_planet :: proc(sky: ^Menu_Sky, lib: ^art.Library, at: rl.Vector2, r: f32, sun: rl.Vector2) {
	doc := art.library_get(lib, "gas_1")
	// A tan giant, banded and lit from the sun's side.
	ov := [6]art.Override {
		{"surface", {188, 150, 100, 255}},
		{"surface2", {128, 98, 64, 255}},
		{"feature", {92, 68, 46, 255}},
		{"feature2", {216, 184, 132, 255}},
		{"accent", {232, 200, 148, 200}},
		{"highlight", {255, 246, 226, 120}},
	}
	if doc != nil {
		art.draw_doc(doc, "", art.Xform{origin = {at.x, at.y}, px = r, rot = sky.t * 0.012}, ov[:])
	} else {
		rl.DrawCircleV(at, r, {170, 142, 102, 255})
	}
	if core.gfx.shading do shade_globe(at, r, unit({sun.x - at.x, sun.y - at.y}), {255, 226, 190})
	// Atmosphere: a bright rim on the sunward limb and a haze all round.
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawCircleGradient(at, r * 1.16, {180, 150, 110, 26}, {180, 150, 110, 0})
	rl.EndBlendMode()
}

// Night side, a soft terminator, limb darkening and a rim of sunlight.
// `light` points from the globe towards the sun in screen space.
@(private = "file")
shade_globe :: proc(c: rl.Vector2, r: f32, light: rl.Vector2, rim: [3]u8) {
	ang := math.atan2(light.y, light.x)
	// The night side in nine caps, their chords stepping from just inside
	// the terminator out towards the dark limb. Where they overlap they
	// darken, so the shadow deepens away from the light instead of ending
	// at a line. Each cap is bounded by the disc's own arc, so none of it
	// spills past the limb.
	N :: 30
	for k in 0 ..< 9 {
		off := r * (0.10 - 0.048 * f32(k))
		phi := math.acos(clamp(off / r, -1, 1))
		span := 2 * (math.PI - phi)
		pts: [N + 2]rl.Vector2
		pts[0] = {c.x + light.x * off, c.y + light.y * off} // on the chord
		for i in 0 ..= N {
			a := ang + phi + span * f32(i) / f32(N)
			pts[i + 1] = {c.x + math.cos(a) * r, c.y + math.sin(a) * r}
		}
		rl.DrawTriangleFan(&pts[0], N + 2, {2, 3, 9, 60})
	}
	// Limb darkening: the disc curves away long before the edge.
	for k in 0 ..< 5 {
		u := f32(k) / 5
		rl.DrawRing(c, r * (0.74 + 0.26 * u), r * 1.002, 0, 360, 64, {1, 2, 8, u8(14 + 12 * u)})
	}
	// The lit edge.
	deg := ang * 180 / math.PI
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawRing(c, r * 0.955, r * 1.005, deg - 66, deg + 66, 64, {rim[0], rim[1], rim[2], 60})
	rl.DrawRing(c, r * 0.985, r * 1.01, deg - 42, deg + 42, 48, {rim[0], rim[1], rim[2], 70})
	rl.EndBlendMode()
}

// Brightness across the ring span, 0 at the division and fading at both
// edges; the ripple is the usual banding.
@(private = "file")
sky_ring_alpha :: proc(u: f32) -> f32 {
	if u > 0.44 && u < 0.54 do return 0
	edge := min(u / 0.10, (1 - u) / 0.13)
	return (36 + 24 * math.sin(u * 27)) * clamp(edge, 0, 1)
}

// The ring plane, seen from a little above it: an ellipse turned by the
// planet's tilt. The near half is drawn after the globe, so call this twice.
@(private = "file")
draw_sky_rings :: proc(c: rl.Vector2, r: f32, sun: rl.Vector2, front: bool) {
	SQUASH :: 0.20
	INNER  :: 1.30
	OUTER  :: 2.05
	BANDS  :: 24
	SEGS   :: 72
	ct := math.cos(f32(SKY_RING_TILT))
	st := math.sin(f32(SKY_RING_TILT))
	l := unit({sun.x - c.x, sun.y - c.y})
	for b in 0 ..< BANDS {
		u := (f32(b) + 0.5) / BANDS
		a := sky_ring_alpha(u)
		if a <= 0 do continue
		rad := r * (INNER + (OUTER - INNER) * u)
		prev: rl.Vector2
		for k in 0 ..= SEGS {
			th := f32(front ? 0 : math.PI) + math.PI * f32(k) / SEGS
			ex := math.cos(th) * rad
			ey := math.sin(th) * rad * SQUASH
			p := rl.Vector2{c.x + ex * ct - ey * st, c.y + ex * st + ey * ct}
			if k > 0 {
				m := rl.Vector2{(p.x + prev.x) * 0.5, (p.y + prev.y) * 0.5}
				aa := a
				// The globe's shadow, where it stands between ring and sun.
				dx := m.x - c.x
				dy := m.y - c.y
				along := dx * l.x + dy * l.y
				perp := abs(dx * l.y - dy * l.x)
				if along < 0 && perp < r * 0.98 do aa *= 0.20
				rl.DrawLineEx(prev, p, r * 0.010 + 0.8, {214, 199, 172, u8(clamp(aa, 0, 255))})
			}
			prev = p
		}
	}
}

// A moon on the ring plane, going round in a couple of minutes.
@(private = "file")
draw_sky_moon :: proc(sky: ^Menu_Sky, lib: ^art.Library, c: rl.Vector2, r: f32, sun: rl.Vector2, front: bool) {
	th := sky.t * 0.055 - 0.5 // starts in frame: the menu should open on its best view
	if (math.sin(th) > 0) != front do return
	ct := math.cos(f32(SKY_RING_TILT))
	st := math.sin(f32(SKY_RING_TILT))
	rad := r * 2.35
	ex := math.cos(th) * rad
	ey := math.sin(th) * rad * 0.20
	at := rl.Vector2{c.x + ex * ct - ey * st, c.y + ex * st + ey * ct}
	mr := r * 0.075
	if doc := art.library_get(lib, "moon_0"); doc != nil {
		ov := [4]art.Override {
			{"surface", {138, 134, 128, 255}},
			{"surface2", {112, 108, 104, 255}},
			{"feature", {92, 89, 86, 255}},
			{"feature2", {150, 146, 140, 255}},
		}
		art.draw_doc(doc, "", art.Xform{origin = {at.x, at.y}, px = mr, rot = th * 0.5}, ov[:])
	} else {
		rl.DrawCircleV(at, mr, {138, 134, 128, 255})
	}
	if core.gfx.shading do shade_globe(at, mr, unit({sun.x - at.x, sun.y - at.y}), {255, 238, 214})
}

// A habitat on station-keeping: a wheel, turning for its gravity, its beacon
// marking the hour. The document comes from the same table the system view
// uses, so it follows whatever the art pipeline makes of a habitat.
@(private = "file")
draw_sky_station :: proc(sky: ^Menu_Sky, lib: ^art.Library, at: rl.Vector2) {
	doc := art.library_get(lib, station_doc_name(.Habitat))
	if doc == nil do return
	bob := math.sin(sky.t * 0.11) * 3
	o := rl.Vector2{at.x, at.y + bob}
	// Its own palette, taken well down: it is a long way off.
	accent := dim(station_color(.Habitat), 0.55)
	ov := [5]art.Override {
		{"station", {88, 92, 100, 255}},
		{"station_dark", {44, 47, 53, 255}},
		{"station_light", {126, 131, 140, 255}},
		{"station_line", {28, 30, 34, 255}},
		{"station_accent", accent},
	}
	art.draw_doc(doc, "", art.Xform{origin = {o.x, o.y}, px = 3.1, rot = sky.t * 0.09}, ov[:])
	blink := math.sin(sky.t * 1.7)
	if blink > 0.6 {
		rl.BeginBlendMode(.ADDITIVE)
		rl.DrawCircleGradient(o, 14, {255, 140, 70, u8(170 * (blink - 0.6) / 0.4)}, {255, 140, 70, 0})
		rl.EndBlendMode()
	}
}

// --------------------------------------------------------------- traffic

@(private = "file")
draw_sky_ship :: proc(s: ^Sky_Ship, t: f32, lib: ^art.Library) {
	doc := art.library_get(lib, SKY_SHIP_DOCS[s.doc])
	if doc == nil do return
	dl := art.doc_length(doc)
	if dl <= 0 do return
	// Distance shows as dimness: the far ones are barely lit hulls.
	near := clamp((s.length - 9) / 67, 0, 1)
	k := 0.42 + 0.58 * near
	v := s.shade
	ov := [4]art.Override {
		{"hull", dim({u8(v), u8(v), u8(v), 255}, k)},
		{"hull_dark", dim({u8(v * 0.6), u8(v * 0.6), u8(v * 0.62), 255}, k)},
		{"hull_light", dim({u8(min(v * 1.32, 255)), u8(min(v * 1.32, 255)), u8(min(v * 1.34, 255)), 255}, k)},
		{"line", dim({u8(v * 0.26), u8(v * 0.26), u8(v * 0.28), 255}, k)},
	}
	rot := math.atan2(s.dir.y, s.dir.x)
	if s.plume > 0.02 {
		// The plume: a tapered blue-white streak off the tail, guttering.
		flick := 0.82 + 0.18 * math.sin(t * 19 + s.phase)
		tail := s.at - s.dir * (s.length * 0.5)
		plume_len := s.length * (0.7 + 1.15 * flick) * s.plume
		rl.BeginBlendMode(.ADDITIVE)
		N :: 9
		for i in 0 ..< N {
			u0 := f32(i) / N
			u1 := f32(i + 1) / N
			p0 := tail - s.dir * (plume_len * u0)
			p1 := tail - s.dir * (plume_len * u1)
			a := (1 - u0) * (1 - u0) * 78 * s.plume * k
			rl.DrawLineEx(p0, p1, s.length * 0.085 * (1 - u0) + 0.6, {110, 172, 255, u8(clamp(a, 0, 255))})
		}
		rl.DrawCircleGradient(tail, s.length * 0.32 * s.plume * flick, {150, 200, 255, u8(clamp(70 * s.plume * k, 0, 255))}, {150, 200, 255, 0})
		rl.EndBlendMode()
	}
	art.draw_doc(doc, s.burning ? "burn" : "idle", art.Xform{origin = {s.at.x, s.at.y}, px = s.length / dl, rot = rot}, ov[:])
}

@(private = "file")
draw_sky_comet :: proc(c: ^Sky_Comet, sun: rl.Vector2) {
	if c.life <= 0 do return
	// Fades in and out of the pass so it never pops.
	fade := clamp(min(c.life, 1.2) / 1.2, 0, 1)
	away := unit({c.at.x - sun.x, c.at.y - sun.y})
	back := unit({-c.vel.x, -c.vel.y})
	rl.BeginBlendMode(.ADDITIVE)
	// Ion tail straight away from the sun; dust tail trailing the path.
	for pass in 0 ..< 2 {
		d := pass == 0 ? away : back
		l := pass == 0 ? f32(150) : f32(90)
		col := pass == 0 ? [3]u8{150, 200, 255} : [3]u8{225, 214, 190}
		N :: 12
		for i in 0 ..< N {
			u0 := f32(i) / N
			u1 := f32(i + 1) / N
			p0 := rl.Vector2{c.at.x + d.x * l * u0, c.at.y + d.y * l * u0}
			p1 := rl.Vector2{c.at.x + d.x * l * u1, c.at.y + d.y * l * u1}
			a := (1 - u0) * (1 - u0) * (pass == 0 ? 90 : 60) * fade
			rl.DrawLineEx(p0, p1, c.size * (1.4 - u0) + 0.5, tint(col, a))
		}
	}
	rl.DrawCircleGradient(c.at, c.size * 6, {200, 230, 255, u8(90 * fade)}, {200, 230, 255, 0})
	rl.DrawCircleV(c.at, c.size, {245, 250, 255, u8(230 * fade)})
	rl.EndBlendMode()
}
