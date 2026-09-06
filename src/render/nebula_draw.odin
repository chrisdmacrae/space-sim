package render

// Drawing nebulae (docs/DESIGN.md §2.6). A cloud is baked once into a
// texture and drawn as a world-space quad ever after: gas does not move, and
// no amount of per-frame circles buys the depth that a few thousand
// accumulated puffs do. The same trick lights the menu sky and the galaxy
// map backdrop.
//
// The puffs are placed by *rejection sampling the gameplay density field*,
// not by an art routine of their own. That is the point: where the cloud
// looks thick is where the scoop fills fastest and where the hull wears,
// because both read `gen.nebula_density_at`.

import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import core "sim:core"
import gen "sim:gen"

NEB_PX :: 1024 // baked resolution; the cloud's diameter spans this

// One texture per nebula of the active system, rebuilt when the system changes.
Nebula_Art :: struct {
	seed: u64,
	tex:  [dynamic]rl.RenderTexture2D,
	has:  [dynamic]bool,
}

nebula_art_release :: proc(a: ^Nebula_Art) {
	for t, i in a.tex do if a.has[i] do rl.UnloadRenderTexture(t)
	clear(&a.tex)
	clear(&a.has)
	a.seed = 0
}

nebula_art_destroy :: proc(a: ^Nebula_Art) {
	nebula_art_release(a)
	delete(a.tex)
	delete(a.has)
}

@(private = "file")
tint :: proc(c: [4]u8, a: f32) -> rl.Color {
	return {c[0], c[1], c[2], u8(clamp(a, 0, 255))}
}

@(private = "file")
fade :: proc(c: [4]u8) -> rl.Color {
	return {c[0], c[1], c[2], 0}
}

// Cloud-local point (world units from the centre) to a texture pixel.
@(private = "file")
to_tex :: proc(p: [2]f64, radius: f64) -> rl.Vector2 {
	k := f32(NEB_PX) * 0.5
	return {k * f32(1 + p.x / radius), k * f32(1 - p.y / radius)}
}

// A point inside the cloud, drawn from the density field itself so the art
// and the simulation cannot disagree. Returns the point and its density.
@(private = "file")
sample_dense :: proc(n: gen.Nebula, r: ^core.Rng, peak: f64) -> ([2]f64, f64) {
	for _ in 0 ..< 24 {
		ang := core.rng_range(r, 0, 2 * math.PI)
		u := math.sqrt(core.rng_f64(r))
		p := [2]f64{math.cos(ang) * n.radius * u, math.sin(ang) * n.radius * u}
		d := gen.nebula_density_at(n, n.center + p)
		if d > 0 && core.rng_f64(r) < d / peak do return p, d
	}
	return {}, 0
}

@(private = "file")
peak_density :: proc(n: gen.Nebula) -> f64 {
	peak := 1e-6
	for i in 0 ..< 900 {
		a := 2 * math.PI * f64(i) * 0.618034
		u := math.sqrt(f64(i % 30) / 30.0 + 0.01)
		p := [2]f64{math.cos(a) * n.radius * u, math.sin(a) * n.radius * u}
		peak = max(peak, gen.nebula_density_at(n, n.center + p))
	}
	return peak
}

// Bake one cloud. Puffs accumulate as light (colour weighted by alpha, alpha
// summed, so the faint haze does not square itself away), then dust lanes go
// back over the top in near-black so the field is carved and not just piled.
@(private = "file")
bake :: proc(n: gen.Nebula) -> rl.RenderTexture2D {
	tex := rl.LoadRenderTexture(NEB_PX, NEB_PX)
	rl.SetTextureFilter(tex.texture, .BILINEAR)
	r := core.rng_make(core.sub_seed(n.seed, "art"))
	peak := peak_density(n)
	k := f64(NEB_PX) * 0.5 / n.radius // pixels per world unit
	core_c, body_c, rim_c := n.colors[0], n.colors[1], n.colors[2]

	rl.BeginTextureMode(tex)
	rl.ClearBackground(rl.BLANK)
	rlgl.SetBlendFactorsSeparate(rlgl.SRC_ALPHA, rlgl.ONE, rlgl.ONE, rlgl.ONE, rlgl.FUNC_ADD, rlgl.FUNC_ADD)
	rl.BeginBlendMode(.CUSTOM_SEPARATE)

	// Haze, then body: the wide soft glow, then the grain inside it. Colour
	// runs from the rim inward, so the thick middle is the brightest.
	for pass in 0 ..< 2 {
		count := pass == 0 ? 500 : 2000
		for _ in 0 ..< count {
			p, d := sample_dense(n, &r, peak)
			if d <= 0 do continue
			f := d / peak
			col := f > 0.66 ? core_c : (f > 0.33 ? body_c : rim_c)
			pr := f32(n.radius * k) * (pass == 0 ? f32(core.rng_range(&r, 0.10, 0.26)) : f32(core.rng_range(&r, 0.028, 0.10)))
			a := (pass == 0 ? f32(core.rng_range(&r, 2.0, 5.0)) : f32(core.rng_range(&r, 3.5, 9.0))) * f32(0.35 + 0.65 * f)
			rl.DrawCircleGradient(to_tex(p, n.radius), pr, tint(col, a), fade(col))
		}
	}

	// Filaments: a chain of small puffs walked along a curving path, turned
	// back towards the gas whenever the walk wanders out of it.
	filaments := n.hollow > 0 ? 46 : 30 // a remnant is mostly filament
	for _ in 0 ..< filaments {
		start, d0 := sample_dense(n, &r, peak)
		if d0 <= 0 do continue
		walk := start
		ang := core.rng_range(&r, 0, 2 * math.PI)
		step := n.radius * core.rng_range(&r, 0.010, 0.022)
		bright := f32(core.rng_range(&r, 5, 12))
		col := core.rng_chance(&r, 0.5) ? core_c : body_c
		for _ in 0 ..< 40 {
			ang += core.rng_range(&r, -0.24, 0.24)
			nxt := walk + {math.cos(ang) * step, math.sin(ang) * step}
			d := gen.nebula_density_at(n, n.center + nxt)
			if d <= 0 {
				ang += math.PI * core.rng_range(&r, 0.7, 1.3) // turn back inward
				continue
			}
			walk = nxt
			pr := f32(n.radius * k) * f32(core.rng_range(&r, 0.008, 0.020))
			rl.DrawCircleGradient(to_tex(walk, n.radius), pr, tint(col, bright * f32(d / peak)), fade(col))
		}
	}

	// The young stars caught inside, each in its own halo. This is what an
	// emission nebula is *for*: the gas glows because they are in it.
	for _ in 0 ..< n.stars {
		p, d := sample_dense(n, &r, peak)
		if d <= 0 do continue
		q := to_tex(p, n.radius)
		g := f32(core.rng_range(&r, 0.5, 1))
		rl.DrawCircleGradient(q, f32(n.radius * k) * 0.055, tint(core_c, 10 * g), fade(core_c))
		rl.DrawCircleGradient(q, 14 * g, {226, 238, 255, u8(clamp(130 * g, 0, 255))}, {226, 238, 255, 0})
		rl.DrawCircleV(q, 1.6, {242, 248, 255, 255})
	}
	rl.EndBlendMode()

	// Dust lanes. A molecular cloud is opaque with grains and a reflection
	// nebula *is* grains; a blast shell and a shed envelope are not, so they
	// keep their filaments clean.
	#partial switch n.kind {
	case .Nursery, .Reflection, .Emission:
		lanes := n.kind == .Nursery ? 22 : 12
		for _ in 0 ..< lanes {
			start, d0 := sample_dense(n, &r, peak)
			if d0 <= 0 do continue
			walk := start
			ang := core.rng_range(&r, 0, 2 * math.PI)
			step := n.radius * core.rng_range(&r, 0.018, 0.034)
			a := u8(core.rng_range(&r, 24, 58))
			for _ in 0 ..< 44 {
				ang += core.rng_range(&r, -0.2, 0.2)
				walk += {math.cos(ang) * step, math.sin(ang) * step}
				if gen.nebula_density_at(n, n.center + walk) <= 0 do break
				pr := f32(n.radius * k) * f32(core.rng_range(&r, 0.018, 0.048))
				rl.DrawCircleGradient(to_tex(walk, n.radius), pr, {2, 3, 8, a}, {2, 3, 8, 0})
			}
		}
	}
	rl.EndTextureMode()
	return tex
}

// (Re)bake the active system's clouds. Cheap to call every frame: it only
// does work when the system changed.
nebula_art_build :: proc(a: ^Nebula_Art, sys: ^gen.System) {
	if a.seed == sys.seed && len(a.tex) == len(sys.nebulae) do return
	nebula_art_release(a)
	a.seed = sys.seed
	resize(&a.tex, len(sys.nebulae))
	resize(&a.has, len(sys.nebulae))
	for n, i in sys.nebulae {
		a.tex[i] = bake(n)
		a.has[i] = true
	}
}

// Draw the clouds behind everything else in the system.
draw_nebulae :: proc(cam: ^Camera, sys: ^gen.System, a: ^Nebula_Art) {
	// Built first even when there is nothing to draw, so leaving a cloud
	// system for a clear one frees its texture instead of holding it.
	nebula_art_build(a, sys)
	if len(sys.nebulae) == 0 do return
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	deg := f32(-cam.angle * 180 / math.PI)
	rlgl.SetBlendFactors(rlgl.ONE, rlgl.ONE, rlgl.FUNC_ADD)
	rl.BeginBlendMode(.CUSTOM)
	for n, i in sys.nebulae {
		if i >= len(a.has) || !a.has[i] do continue
		centre := sys.pos[0] + n.center
		sp := world_to_screen(cam, centre)
		side := f32(2 * n.radius * cam.zoom)
		if side < 3 do continue
		// Cull once the quad is entirely off screen. The corners swing with
		// the view angle, so allow the full half-diagonal.
		half := side * 0.7072
		if sp.x + half < 0 || sp.x - half > sw || sp.y + half < 0 || sp.y - half > sh do continue
		src := rl.Rectangle{0, 0, NEB_PX, NEB_PX}
		dst := rl.Rectangle{sp.x, sp.y, side, side}
		rl.DrawTexturePro(a.tex[i].texture, src, dst, {side * 0.5, side * 0.5}, deg, rl.WHITE)
	}
	rl.EndBlendMode()
}

// Inside the gas: a wash in the cloud's colour over the whole view, thicker
// the deeper you are, plus grains streaming past to give the wash a scale.
// Drawn after the system so it sits between the world and the HUD.
draw_nebula_interior :: proc(cam: ^Camera, sys: ^gen.System, world: [2]f64) {
	if !core.gfx.effects do return
	idx, density := gen.nebula_at(sys, world)
	if idx < 0 do return
	n := sys.nebulae[idx]
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	// The wash is additive, so a dark colour at a low alpha contributes
	// almost nothing: it takes the bright token and a real alpha to read.
	c := n.colors[0]
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawRectangleGradientV(0, 0, i32(sw), i32(sh), tint(c, f32(density) * 52), tint(c, f32(density) * 88))
	rl.EndBlendMode()
	// Grains: fixed to the world, so they stream past as the ship moves and
	// the cloud reads as a place rather than a filter over the lens.
	if cam.zoom < 0.02 do return
	spacing := 60.0 / cam.zoom // world units between motes
	origin := [2]f64{math.floor(cam.target.x / spacing), math.floor(cam.target.y / spacing)}
	span := 14
	for iy in -span ..= span {
		for ix in -span ..= span {
			cell := origin + {f64(ix), f64(iy)}
			h := core.mix64(u64(i64(cell.x) * 73856093) ~ u64(i64(cell.y) * 19349663) ~ n.seed)
			jx := f64(h >> 11) * (1.0 / 9007199254740992.0)
			jy := f64(core.mix64(h) >> 11) * (1.0 / 9007199254740992.0)
			p := (cell + {jx, jy}) * spacing
			d := gen.nebula_density_at(n, p - sys.pos[0])
			if d <= gen.NEBULA_EDGE do continue
			s := world_to_screen(cam, p)
			if s.x < -8 || s.y < -8 || s.x > sw + 8 || s.y > sh + 8 do continue
			a := u8(clamp(f64(30 + (h >> 56)) * d * 0.9, 0, 190))
			rl.DrawPixelV({s.x, s.y}, {c[0], c[1], c[2], a})
		}
	}
}
