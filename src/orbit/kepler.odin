package orbit

// 2D Kepler orbits (docs/DESIGN.md §4.1). A body or coasting ship is a conic
// relative to its parent; position and velocity at any time are closed-form.
// Elliptic (e < 1, a > 0) and hyperbolic (e > 1, a < 0) are both supported.

import "core:math"

Orbit :: struct {
	a:   f64, // semi-major axis; negative for hyperbolic
	e:   f64, // eccentricity
	w:   f64, // argument of periapsis: angle of periapsis from +x, radians
	M0:  f64, // mean anomaly at t0
	t0:  f64,
	mu:  f64, // G * parent mass
	dir: f64, // +1 counter-clockwise (prograde), -1 clockwise
}

length :: proc(v: [2]f64) -> f64 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

dot :: proc(a, b: [2]f64) -> f64 {
	return a.x * b.x + a.y * b.y
}

cross :: proc(a, b: [2]f64) -> f64 {
	return a.x * b.y - a.y * b.x
}

rotate :: proc(v: [2]f64, ang: f64) -> [2]f64 {
	c := math.cos(ang)
	s := math.sin(ang)
	return {c * v.x - s * v.y, s * v.x + c * v.y}
}

make :: proc(mu, a, e, w, M0, t0: f64, dir: f64 = 1) -> Orbit {
	return Orbit{a = a, e = e, w = w, M0 = M0, t0 = t0, mu = mu, dir = dir}
}

// Circular orbit of radius r, at position angle `phase` at t0.
circular :: proc(mu, r, phase, t0: f64, dir: f64 = 1) -> Orbit {
	return Orbit{a = r, e = 0, w = 0, M0 = dir * phase, t0 = t0, mu = mu, dir = dir}
}

mean_motion :: proc(o: Orbit) -> f64 {
	a := abs(o.a)
	return math.sqrt(o.mu / (a * a * a))
}

period :: proc(o: Orbit) -> f64 {
	if o.e >= 1 do return math.inf_f64(1)
	return 2 * math.PI / mean_motion(o)
}

periapsis :: proc(o: Orbit) -> f64 {
	return abs(o.a) * (o.e < 1 ? 1 - o.e : o.e - 1)
}

apoapsis :: proc(o: Orbit) -> f64 {
	if o.e >= 1 do return math.inf_f64(1)
	return o.a * (1 + o.e)
}

mean_anomaly_at :: proc(o: Orbit, t: f64) -> f64 {
	M := o.M0 + mean_motion(o) * (t - o.t0)
	if o.e < 1 {
		M = math.mod(M, 2 * math.PI)
		if M < 0 do M += 2 * math.PI
	}
	return M
}

// Newton on E - e sin E = M.
solve_elliptic :: proc(M, e: f64) -> f64 {
	// Starting guess: one Newton-like term for moderate e, pi near parabolic.
	E := e < 0.8 ? M + e * math.sin(M) : math.PI
	for _ in 0 ..< 30 {
		f := E - e * math.sin(E) - M
		fp := 1 - e * math.cos(E)
		d := f / fp
		E -= d
		if abs(d) < 1e-14 do break
	}
	return E
}

// Newton on e sinh H - H = M.
solve_hyperbolic :: proc(M, e: f64) -> f64 {
	H := math.asinh(M / e)
	for _ in 0 ..< 60 {
		f := e * math.sinh(H) - H - M
		fp := e * math.cosh(H) - 1
		d := f / fp
		H -= d
		if abs(d) < 1e-14 do break
	}
	return H
}

// Position and velocity relative to the parent at time t.
state_at :: proc(o: Orbit, t: f64) -> (pos, vel: [2]f64) {
	n := mean_motion(o)
	M := mean_anomaly_at(o, t)
	x, y, vx, vy: f64
	if o.e < 1 {
		E := solve_elliptic(M, o.e)
		cE := math.cos(E)
		sE := math.sin(E)
		b := o.a * math.sqrt(1 - o.e * o.e)
		x = o.a * (cE - o.e)
		y = b * sE
		Edot := n / (1 - o.e * cE)
		vx = -o.a * sE * Edot
		vy = b * cE * Edot
	} else {
		H := solve_hyperbolic(M, o.e)
		cH := math.cosh(H)
		sH := math.sinh(H)
		k := -o.a * math.sqrt(o.e * o.e - 1) // positive
		x = o.a * (cH - o.e)
		y = k * sH
		Hdot := n / (o.e * cH - 1)
		vx = o.a * sH * Hdot
		vy = k * cH * Hdot
	}
	// Mirror for retrograde, then rotate the periapsis into place.
	pos = rotate({x, o.dir * y}, o.w)
	vel = rotate({vx, o.dir * vy}, o.w)
	return
}

position_at :: proc(o: Orbit, t: f64) -> [2]f64 {
	p, _ := state_at(o, t)
	return p
}

// Point on an elliptic orbit at eccentric anomaly E (for drawing).
point_at_E :: proc(o: Orbit, E: f64) -> [2]f64 {
	b := o.a * math.sqrt(1 - o.e * o.e)
	return rotate({o.a * (math.cos(E) - o.e), o.dir * b * math.sin(E)}, o.w)
}

// Rebuild elements from a relative state vector at time t.
from_state :: proc(pos, vel: [2]f64, mu, t: f64) -> Orbit {
	r := length(pos)
	v2 := dot(vel, vel)
	h := cross(pos, vel)
	dir: f64 = h >= 0 ? 1 : -1
	energy := v2 * 0.5 - mu / r
	if abs(energy) < 1e-12 do energy = -1e-12 // parabolic: nudge to a huge ellipse
	a := -mu / (2 * energy)
	rv := dot(pos, vel)
	evec := ((v2 - mu / r) * pos - rv * vel) / mu
	e := length(evec)
	w := e > 1e-10 ? math.atan2(evec.y, evec.x) : 0
	theta := math.atan2(pos.y, pos.x)
	nu := dir * (theta - w)
	M: f64
	if e < 1 {
		E := 2 * math.atan2(math.sqrt(1 - e) * math.sin(nu * 0.5), math.sqrt(1 + e) * math.cos(nu * 0.5))
		M = E - e * math.sin(E)
	} else {
		H := math.asinh(math.sqrt(e * e - 1) * math.sin(nu) / (1 + e * math.cos(nu)))
		M = e * math.sinh(H) - H
	}
	return Orbit{a = a, e = e, w = w, M0 = M, t0 = t, mu = mu, dir = dir}
}

// Sphere of influence of a body of mass mu_body orbiting mu_parent at a.
soi_radius :: proc(a, mu_body, mu_parent: f64) -> f64 {
	return a * math.pow(mu_body / mu_parent, 0.4)
}

// Speed on a circular orbit of radius r.
circular_speed :: proc(mu, r: f64) -> f64 {
	return math.sqrt(mu / r)
}

// Unwrapped eccentric (or hyperbolic) anomaly at t: monotonic in time, so a
// path from t0 to t1 can be sampled uniformly in anomaly.
anomaly_at :: proc(o: Orbit, t: f64) -> f64 {
	M := o.M0 + mean_motion(o) * (t - o.t0)
	if o.e < 1 {
		k := math.floor(M / (2 * math.PI))
		return solve_elliptic(M - 2 * math.PI * k, o.e) + 2 * math.PI * k
	}
	return solve_hyperbolic(M, o.e)
}

// Point at an anomaly from anomaly_at (relative to the parent).
point_at_anomaly :: proc(o: Orbit, x: f64) -> [2]f64 {
	if o.e < 1 do return point_at_E(o, x)
	k := -o.a * math.sqrt(o.e * o.e - 1)
	return rotate({o.a * (math.cosh(x) - o.e), o.dir * k * math.sinh(x)}, o.w)
}
