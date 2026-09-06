package core

// Deterministic seeding (docs/DESIGN.md §2.2). Hierarchical: any part of the
// world derives its seed from its parent's seed plus a tag and index, so it can
// be regenerated in isolation and in any order. The generator is splitmix64:
// tiny, fast, and stable across Odin releases.

import "core:math"

Rng :: struct {
	state: u64,
}

mix64 :: proc(x: u64) -> u64 {
	z := x
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// Child seed for (parent, tag, index).
sub_seed :: proc(parent: u64, tag: string, index: int = 0) -> u64 {
	h: u64 = 0xCBF29CE484222325
	for b in transmute([]u8)tag {
		h = (h ~ u64(b)) * 0x100000001B3
	}
	return mix64(parent ~ mix64(h) ~ (u64(index) + 1) * 0x9E3779B97F4A7C15)
}

rng_make :: proc(seed: u64) -> Rng {
	return Rng{state = mix64(seed ~ 0xA0761D6478BD642F)}
}

rng_u64 :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E3779B97F4A7C15
	return mix64(r.state)
}

// Uniform in [0, 1).
rng_f64 :: proc(r: ^Rng) -> f64 {
	return f64(rng_u64(r) >> 11) * (1.0 / 9007199254740992.0)
}

rng_range :: proc(r: ^Rng, lo, hi: f64) -> f64 {
	return lo + (hi - lo) * rng_f64(r)
}

// Log-uniform in [lo, hi]; both must be positive.
rng_log_range :: proc(r: ^Rng, lo, hi: f64) -> f64 {
	return math.exp(rng_range(r, math.ln(lo), math.ln(hi)))
}

// Integer in [lo, hi).
rng_int :: proc(r: ^Rng, lo, hi: int) -> int {
	if hi <= lo do return lo
	return lo + int(rng_u64(r) % u64(hi - lo))
}

rng_chance :: proc(r: ^Rng, p: f64) -> bool {
	return rng_f64(r) < p
}

rng_pick :: proc(r: ^Rng, items: []$T) -> T {
	return items[rng_int(r, 0, len(items))]
}
