package sim

// Gravity-assist search (docs/DESIGN.md §5.4): one flyby of a massive body
// between departure and destination. Two Lambert legs meet at the flyby
// body; the incoming and outgoing relative velocities must have (nearly)
// the same magnitude and a turn angle the body can supply above its
// surface. The result is a Candidate carrying the flyby leg.

import "core:fmt"
import "core:math"
import core "sim:core"
import gen "sim:gen"
import orbit "sim:orbit"

// Extra fields a flyby candidate needs to be flown.
Flyby :: struct {
	via:    gen.Body_Handle,
	t_via:  f64,
	v_in:   [2]f64, // common-frame velocity arriving at the flyby body
	v_out:  [2]f64, // common-frame velocity leaving it
	r_p:    f64,    // periapsis of the flyby hyperbola
	dv:     f64,    // powered-flyby cost at periapsis
}

FLYBY_MARGIN :: 1.5 // minimum periapsis in body radii
flyby_solved: int // debug counter

// Turn geometry at the flyby body from the relative velocities at its
// sphere edge. Returns the periapsis radius needed and the powered Δv.
flyby_turn :: proc(sys: ^gen.System, via: gen.Body_Handle, v_in_rel, v_out_rel: [2]f64) -> (r_p, dv: f64, ok: bool) {
	b := sys.bodies[via]
	vi := orbit.length(v_in_rel)
	vo := orbit.length(v_out_rel)
	if vi < 1e-9 || vo < 1e-9 do return 0, 0, false
	v_inf_in, short_in := excess_from_edge(b.mu, b.soi, vi)
	v_inf_out, short_out := excess_from_edge(b.mu, b.soi, vo)
	if short_in > 0 || short_out > 0 do return 0, 0, false // would be captured
	v_inf := min(v_inf_in, v_inf_out)
	if v_inf < 1e-6 do return 0, 0, false
	// Turn angle between the two relative velocities.
	c := orbit.dot(v_in_rel, v_out_rel) / (vi * vo)
	delta := math.acos(clamp(c, -1, 1))
	if delta < 1e-4 do return b.soi, 0, true
	e := 1 / math.sin(delta * 0.5)
	r_p = b.mu * (e - 1) / (v_inf * v_inf)
	if r_p < b.radius * FLYBY_MARGIN do return r_p, 0, false
	// Speed change is bought at periapsis, where it is cheapest.
	vp_in := math.sqrt(v_inf_in * v_inf_in + 2 * b.mu / r_p)
	vp_out := math.sqrt(v_inf_out * v_inf_out + 2 * b.mu / r_p)
	dv = abs(vp_out - vp_in)
	return r_p, dv, true
}

// Score one flyby transfer.
evaluate_flyby :: proc(sys: ^gen.System, geo: Geometry, s: ^Ship, via: gen.Body_Handle, t_d, tf1, tf2, budget: f64) -> (c: Candidate, fb: Flyby) {
	c.t_depart = t_d
	t_via := t_d + tf1
	c.t_arrive = t_via + tf2
	p1, vs := ship_frame_state(sys, geo, s, t_d)
	pm, vm := orbit.state_at(sys.bodies[via].orbit, t_via)
	p2, vt := target_frame_state(sys, geo, c.t_arrive)
	v1, vin, ok1 := orbit.lambert(p1, pm, tf1, geo.mu, geo.dir)
	if !ok1 do return
	vout, v2, ok2 := orbit.lambert(pm, p2, tf2, geo.mu, geo.dir)
	if !ok2 do return
	flyby_solved += 1
	safe := safe_radius(sys, geo.lca)
	if !clears_body(p1, v1, geo.mu, safe) || !clears_body(pm, vout, geo.mu, safe) do return
	r_p, dv_fb, okf := flyby_turn(sys, via, vin - vm, vout - vm)
	if !okf do return
	c.v1, c.v2 = v1, v2
	if geo.dep_body != gen.NONE {
		pb := sys.bodies[geo.dep_body]
		c.dv_depart = depart_dv(pb.mu, pb.soi, geo.park_r, geo.park_v, orbit.length(v1 - vs))
	} else {
		c.dv_depart = orbit.length(v1 - vs)
	}
	if geo.arr_body != gen.NONE {
		ab := sys.bodies[geo.arr_body]
		c.dv_arrive = arrive_dv(ab.mu, ab.soi, geo.cap_r, orbit.length(v2 - vt))
	} else if geo.is_point {
		c.dv_arrive = 0
	} else {
		c.dv_arrive = orbit.length(v2 - vt)
	}
	c.dv_total = c.dv_depart + c.dv_arrive + dv_fb
	c.ok = true
	c.fits = c.dv_total <= budget
	c.flyby = true
	fb = Flyby{via = via, t_via = t_via, v_in = vin, v_out = vout, r_p = r_p, dv = dv_fb}
	return
}

// Bodies worth swinging past: children of the common frame other than the
// endpoints, big enough to bend a path.
flyby_candidates :: proc(sys: ^gen.System, geo: Geometry, allocator := context.temp_allocator) -> []gen.Body_Handle {
	out := make([dynamic]gen.Body_Handle, allocator)
	for &b, i in sys.bodies {
		h := gen.Body_Handle(i)
		if b.parent != geo.lca || h == geo.dep_body || h == geo.arr_body do continue
		if b.mu < 3 * core.MU_EARTH do continue // only bodies heavy enough to bend a path usefully
		append(&out, h)
	}
	return out[:]
}

// Coarse grid over departure, first and second flight times for each
// candidate body; keeps the best per objective. `res` supplies the direct
// search's normalisers for the balanced score.
search_flybys :: proc(sys: ^gen.System, s: ^Ship, geo: Geometry, now: f64, res: ^Search_Result, out_fb: ^[Objective]Flyby, fast := false) {
	budget := dv_remaining(s) * 0.95
	p1, _ := ship_frame_state(sys, geo, s, now)
	p2, _ := target_frame_state(sys, geo, now)
	r1 := orbit.length(p1)
	r2 := orbit.length(p2)
	lead := 600.0
	if geo.dep_body != gen.NONE {
		pb := sys.bodies[geo.dep_body]
		lead = geo.park_period * 1.1 + pb.soi / max(math.sqrt(pb.mu / geo.park_r), 1e-6)
	}
	when SHOOT_DEBUG do fmt.printfln("flyby search: %d candidate bodies, direct best dv=%.4f", len(flyby_candidates(sys, geo)), res.dv_best)
	for via in flyby_candidates(sys, geo) {
		feasible := 0
		flyby_solved = 0
		best_dv: f64 = 1e300
		via_fuel, via_time: Candidate
		via_fuel_fb, via_time_fb: Flyby
		defer when SHOOT_DEBUG do fmt.printfln("  via %s: %d lambert pairs solved, %d feasible flybys, best dv=%.4f", sys.bodies[via].name, flyby_solved, feasible, best_dv)
		rm := sys.bodies[via].orbit.a
		th1 := math.PI * math.sqrt(math.pow((r1 + rm) * 0.5, 3) / geo.mu)
		th2 := math.PI * math.sqrt(math.pow((rm + r2) * 0.5, 3) / geo.mu)
		n_m := math.sqrt(geo.mu / (rm * rm * rm))
		window := 2 * math.PI / n_m * 1.5
		nd := fast ? 6 : 12
		nf := fast ? 5 : 9
		for i in 0 ..< nd {
			t_d := now + lead + window * f64(i) / f64(nd - 1)
			for j in 0 ..< nf {
				tf1 := th1 * math.exp(math.ln(0.4) + (math.ln(2.2) - math.ln(0.4)) * f64(j) / f64(nf - 1))
				for k in 0 ..< nf {
					tf2 := th2 * math.exp(math.ln(0.4) + (math.ln(2.2) - math.ln(0.4)) * f64(k) / f64(nf - 1))
					c, fb := evaluate_flyby(sys, geo, s, via, t_d, tf1, tf2, budget)
					if !c.ok do continue
					feasible += 1
					best_dv = min(best_dv, c.dv_total)
					if better(.Fuel, c, via_fuel, res^, now) { via_fuel = c; via_fuel_fb = fb }
					if better(.Time, c, via_time, res^, now) { via_time = c; via_time_fb = fb }
					if !res.flyby_best.ok || c.dv_total < res.flyby_best.dv_total {
						res.flyby_best = c
						res.flyby_best_fb = fb
					}
					for obj in Objective {
						if obj == .Simplest do continue // never a flyby
						if better(obj, c, res.picks[obj], res^, now) {
							res.picks[obj] = c
							out_fb[obj] = fb
						}
					}
				}
			}
		}
		// This body's own best routes go on the menu, cheapest first; the
		// fastest joins it unless it is the same transfer.
		if via_fuel.ok {
			o := Route_Option{cand = via_fuel, fb = via_fuel_fb, via = via, tags = {.Fuel}, objective = .Fuel}
			if via_time.ok && abs(via_time.t_depart - via_fuel.t_depart) < 1 && abs(via_time.t_arrive - via_fuel.t_arrive) < 1 {
				o.tags += {.Time}
				add_option(res, o)
			} else {
				add_option(res, o)
				if via_time.ok do add_option(res, Route_Option{cand = via_time, fb = via_time_fb, via = via, tags = {.Time}, objective = .Time})
			}
		}
	}
}
