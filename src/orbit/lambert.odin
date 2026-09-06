package orbit

// Lambert's problem in 2D (docs/DESIGN.md §5.3): the conic that goes from r1
// to r2 in time tf about mu, travelling in direction `dir`. Universal-
// variable formulation with bisection on z; single revolution only.

import "core:math"

@(private = "file")
stumpff_c :: proc(z: f64) -> f64 {
	switch {
	case z > 1e-9:  return (1 - math.cos(math.sqrt(z))) / z
	case z < -1e-9: return (math.cosh(math.sqrt(-z)) - 1) / -z
	}
	return 0.5
}

@(private = "file")
stumpff_s :: proc(z: f64) -> f64 {
	switch {
	case z > 1e-9:
		s := math.sqrt(z)
		return (s - math.sin(s)) / (s * s * s)
	case z < -1e-9:
		s := math.sqrt(-z)
		return (math.sinh(s) - s) / (s * s * s)
	}
	return 1.0 / 6.0
}

// Velocities at r1 and r2 for the transfer. `dir` is +1 for counter-clockwise
// motion. Fails for near-zero or near-full transfer angles and for times too
// short to be reached on a single revolution.
lambert :: proc(r1, r2: [2]f64, tf, mu, dir: f64) -> (v1, v2: [2]f64, ok: bool) {
	if tf <= 0 do return {}, {}, false
	m1 := length(r1)
	m2 := length(r2)
	if m1 <= 0 || m2 <= 0 do return {}, {}, false
	dtheta := math.atan2(cross(r1, r2), dot(r1, r2))
	if dtheta < 0 do dtheta += 2 * math.PI
	if dir < 0 do dtheta = 2 * math.PI - dtheta
	if dtheta < 0.02 || dtheta > 2 * math.PI - 0.02 do return {}, {}, false
	A := math.sin(dtheta) * math.sqrt(m1 * m2 / (1 - math.cos(dtheta)))
	if abs(A) < 1e-12 do return {}, {}, false

	// F(z) = (y/C)^1.5 S + A sqrt(y) - sqrt(mu) tf is increasing in z.
	y_of :: proc(z, m1, m2, A: f64) -> f64 {
		return m1 + m2 + A * (z * stumpff_s(z) - 1) / math.sqrt(stumpff_c(z))
	}
	F :: proc(z, m1, m2, A, mu, tf: f64) -> (f: f64, y: f64) {
		y = y_of(z, m1, m2, A)
		if y < 0 do return 0, y
		C := stumpff_c(z)
		S := stumpff_s(z)
		x := math.sqrt(y / C)
		return x * x * x * S + A * math.sqrt(y) - math.sqrt(mu) * tf, y
	}

	lo := -4 * math.PI * math.PI * 4
	hi := 4 * math.PI * math.PI - 1e-6
	z := 0.0
	y := 0.0
	for _ in 0 ..< 200 {
		z = (lo + hi) * 0.5
		f, yy := F(z, m1, m2, A, mu, tf)
		if yy < 0 {
			// Outside the admissible region: push z towards where y > 0.
			if A > 0 do lo = z
			else do hi = z
			continue
		}
		y = yy
		if f > 0 do hi = z
		else do lo = z
		if hi - lo < 1e-11 do break
	}
	f_end, y_end := F(z, m1, m2, A, mu, tf)
	if y_end <= 0 || abs(f_end) > 1e-6 * math.sqrt(mu) * tf + 1e-9 do return {}, {}, false
	y = y_end
	f := 1 - y / m1
	g := A * math.sqrt(y / mu)
	gdot := 1 - y / m2
	if abs(g) < 1e-14 do return {}, {}, false
	v1 = (r2 - r1 * f) / g
	v2 = (r2 * gdot - r1) / g
	return v1, v2, true
}
