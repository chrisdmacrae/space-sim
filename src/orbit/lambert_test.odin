package orbit

import "core:math"
import "core:testing"

// Two points on a known orbit and the time between them must give back the
// orbit's own velocities, both the short way and the long way round.
@(test)
lambert_reproduces_known_orbit :: proc(t: ^testing.T) {
	cases := [?]Orbit {
		make(0.3, 900, 0.2, 0.7, 0.1, 0),
		make(0.3, 900, 0.2, 0.7, 0.1, 0, -1),
		make(0.3, 2000, 0.6, -1.0, 2.0, 0),
		make(0.002, 20, 0.05, 0, 0, 0),
	}
	for o in cases {
		p := period(o)
		for frac in ([?]f64{0.1, 0.3, 0.45, 0.6, 0.85}) {
			t0 := 100.0
			t1 := t0 + p * frac
			r1, va := state_at(o, t0)
			r2, vb := state_at(o, t1)
			v1, v2, ok := lambert(r1, r2, t1 - t0, o.mu, o.dir)
			testing.expectf(t, ok, "solve failed for a=%v e=%v dir=%v frac=%v", o.a, o.e, o.dir, frac)
			if !ok do continue
			tol := 1e-6 * length(va)
			testing.expectf(t, length(v1 - va) < tol, "v1 %v vs %v (frac %v)", v1, va, frac)
			testing.expectf(t, length(v2 - vb) < tol, "v2 %v vs %v (frac %v)", v2, vb, frac)
		}
	}
}

// Near 180 degrees the Lambert transfer approaches the Hohmann ellipse.
@(test)
lambert_matches_hohmann :: proc(t: ^testing.T) {
	mu := 0.3
	r1 := 600.0
	r2 := 1400.0
	a := (r1 + r2) / 2
	tf := math.PI * math.sqrt(a * a * a / mu)
	ang := math.PI - 0.03
	p1 := [2]f64{r1, 0}
	p2 := [2]f64{r2 * math.cos(ang), r2 * math.sin(ang)}
	v1, _, ok := lambert(p1, p2, tf, mu, 1)
	testing.expect(t, ok, "solve ok")
	v_h := math.sqrt(mu / r1) * math.sqrt(2 * r2 / (r1 + r2))
	testing.expectf(t, abs(length(v1) - v_h) < 0.02 * v_h, "departure speed %v vs Hohmann %v", length(v1), v_h)
}
