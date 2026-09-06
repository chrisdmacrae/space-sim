package orbit

import "core:math"
import "core:testing"

close :: proc(a, b, tol: f64) -> bool {
	return abs(a - b) <= tol
}

close2 :: proc(a, b: [2]f64, tol: f64) -> bool {
	return length(a - b) <= tol
}

@(test)
circular_period_and_quadrants :: proc(t: ^testing.T) {
	o := circular(1, 1, 0, 0)
	p := period(o)
	testing.expect(t, close(p, 2 * math.PI, 1e-12), "period of unit circular orbit is 2pi")
	testing.expect(t, close2(position_at(o, p), {1, 0}, 1e-9), "back at start after one period")
	testing.expect(t, close2(position_at(o, p / 4), {0, 1}, 1e-9), "quarter period is +y for prograde")
	pos, vel := state_at(o, 0)
	testing.expect(t, close2(pos, {1, 0}, 1e-12), "starts on +x")
	testing.expect(t, close2(vel, {0, 1}, 1e-9), "circular speed is 1 along +y")
}

@(test)
retrograde_goes_clockwise :: proc(t: ^testing.T) {
	o := circular(1, 1, 0, 0, -1)
	testing.expect(t, close2(position_at(o, period(o) / 4), {0, -1}, 1e-9), "quarter period is -y for retrograde")
}

@(test)
elliptic_round_trip :: proc(t: ^testing.T) {
	cases := [?]Orbit {
		make(0.3, 600, 0.1, 0.4, 1.0, 0),
		make(0.3, 600, 0.6, -2.0, 3.0, 10),
		make(0.002, 20, 0.01, 0, 0, 0),
		make(0.3, 5000, 0.3, 2.5, 5.5, 100, -1),
		make(0.3, 800, 0.0, 0, 1, 0),
	}
	for o in cases {
		sample := 1234.5
		pos, vel := state_at(o, sample)
		o2 := from_state(pos, vel, o.mu, sample)
		testing.expectf(t, close(o2.a, o.a, 1e-6 * o.a), "a: %v vs %v", o2.a, o.a)
		testing.expectf(t, close(o2.e, o.e, 1e-7), "e: %v vs %v", o2.e, o.e)
		testing.expectf(t, o2.dir == o.dir, "dir: %v vs %v", o2.dir, o.dir)
		for k in 0 ..< 8 {
			tt := sample + f64(k) * period(o) * 0.37
			p1, v1 := state_at(o, tt)
			p2, v2 := state_at(o2, tt)
			testing.expectf(t, close2(p1, p2, 1e-6 * o.a), "pos at %v: %v vs %v", tt, p1, p2)
			testing.expectf(t, close2(v1, v2, 1e-8), "vel at %v: %v vs %v", tt, v1, v2)
		}
	}
}

@(test)
hyperbolic_round_trip :: proc(t: ^testing.T) {
	o := make(0.3, -400, 1.4, 0.7, -2.0, 0)
	sample := 50.0
	pos, vel := state_at(o, sample)
	testing.expect(t, dot(vel, vel) * 0.5 - o.mu / length(pos) > 0, "hyperbolic state has positive energy")
	o2 := from_state(pos, vel, o.mu, sample)
	testing.expectf(t, close(o2.a, o.a, 1e-6 * abs(o.a)), "a: %v vs %v", o2.a, o.a)
	testing.expectf(t, close(o2.e, o.e, 1e-7), "e: %v vs %v", o2.e, o.e)
	for k in -4 ..= 4 {
		tt := f64(k) * 300.0
		p1, _ := state_at(o, tt)
		p2, _ := state_at(o2, tt)
		testing.expectf(t, close2(p1, p2, 1e-6 * abs(o.a)), "pos at %v: %v vs %v", tt, p1, p2)
	}
}

@(test)
vis_viva_holds :: proc(t: ^testing.T) {
	o := make(0.3, 900, 0.45, 1.1, 0.2, 0)
	for k in 0 ..< 20 {
		tt := f64(k) * 700.0
		pos, vel := state_at(o, tt)
		r := length(pos)
		want := o.mu * (2 / r - 1 / o.a)
		testing.expectf(t, close(dot(vel, vel), want, 1e-9 * want), "v^2 at %v: %v vs %v", tt, dot(vel, vel), want)
	}
}

@(test)
soi_scales_with_mass_ratio :: proc(t: ^testing.T) {
	testing.expect(t, close(soi_radius(1000, 1, 1), 1000, 1e-12), "equal masses: soi = a")
	testing.expect(t, soi_radius(1000, 0.001, 1) < 100, "small body: soi well under a/10")
}
