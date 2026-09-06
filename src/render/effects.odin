package render

// Transient visual effects. Driven by the wall clock so they play at the
// same pace whatever the sim warp, and anchored in world space so the
// camera can move while they run.

import "core:math"
import rl "vendor:raylib"
import core "sim:core"

Explosion :: struct {
	world:   [2]f64,
	size:    f64, // world units of the thing that blew up
	started: f64, // rl.GetTime()
	seed:    u32,
}

EXPLOSION_LIFE :: 1.6 // seconds
EXPLOSION_SPARKS :: 42

Effects :: struct {
	explosions: [dynamic]Explosion,
}

explosion_spawn :: proc(fx: ^Effects, world: [2]f64, size: f64) {
	append(&fx.explosions, Explosion{world = world, size = size, started = rl.GetTime(), seed = u32(len(fx.explosions) * 7919 + 17)})
}

effects_destroy :: proc(fx: ^Effects) {
	delete(fx.explosions)
}

@(private = "file")
hash01 :: proc(seed: u32, i: int, salt: u32) -> f32 {
	h := seed ~ u32(i) * 0x9E3779B1 ~ salt * 0x85EBCA77
	h ~= h >> 15
	h *= 0x2C1B3C6D
	h ~= h >> 12
	return f32(h & 0xFFFFFF) / f32(0xFFFFFF)
}

effects_draw :: proc(fx: ^Effects, cam: ^Camera) {
	if !core.gfx.effects {
		clear(&fx.explosions)
		return
	}
	now := rl.GetTime()
	for i := 0; i < len(fx.explosions); {
		e := fx.explosions[i]
		age := now - e.started
		if age > EXPLOSION_LIFE {
			unordered_remove(&fx.explosions, i)
			continue
		}
		i += 1
		u := f32(age / EXPLOSION_LIFE)
		sp := world_to_screen(cam, e.world)
		// On-screen scale: the ship's size, but never so small it is missed.
		px := f32(max(e.size * cam.zoom * 6, 46))
		// Flash, then a fading fireball and an expanding thin ring.
		if u < 0.18 {
			rl.DrawCircleV({sp.x, sp.y}, px * (0.4 + u * 4), {255, 250, 230, u8(230 * (1 - u / 0.18))})
		}
		ball := px * (0.35 + 0.65 * math.sqrt(u))
		fade := u8(clamp(220 * (1 - u), 0, 255))
		rl.DrawCircleGradient({sp.x, sp.y}, ball, {255, 200, 90, fade}, {255, 90, 30, 0})
		ring := px * (0.2 + 1.9 * u)
		rl.DrawRing({sp.x, sp.y}, ring, ring + 1.5 + 2 * (1 - u), 0, 360, 48, {255, 180, 120, u8(clamp(180 * (1 - u), 0, 255))})
		// Sparks fly out and slow down; a few are ember-red and last longer.
		for k in 0 ..< EXPLOSION_SPARKS {
			ang := hash01(e.seed, k, 1) * 2 * math.PI
			speed := 0.5 + hash01(e.seed, k, 2) * 1.2
			life := 0.5 + hash01(e.seed, k, 3) * 0.5
			if u > life do continue
			d := px * 2.2 * speed * (1 - math.pow(1 - u / life, 2))
			x := sp.x + math.cos(ang) * d
			y := sp.y + math.sin(ang) * d
			a := u8(clamp(255 * (1 - u / life), 0, 255))
			col := hash01(e.seed, k, 4) < 0.3 ? rl.Color{255, 120, 60, a} : rl.Color{255, 230, 170, a}
			rl.DrawCircleV({x, y}, 1 + 1.5 * (1 - u), col)
		}
	}
}
