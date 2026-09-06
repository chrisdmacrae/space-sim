package econ

// The job board (docs/DESIGN.md §6.7): contracts posted at markets. Three
// kinds so far: deliver a consignment the market hands you, procure goods
// the market wants, or carry a passenger. Each has a deadline, which is
// what makes the choice between a cheap route and a fast one matter.
//
// Boards are deterministic per (system, market, day) so a save need only
// remember which jobs the player accepted.

import "core:fmt"
import core "sim:core"
import gen "sim:gen"

Job_Kind :: enum u8 {
	Delivery,    // take `units` of `commodity` from `from` to `to`; the goods are handed over on acceptance
	Procurement, // bring `units` of `commodity` to `to` from anywhere
	Passenger,   // carry a person from `from` to `to`; no hold needed
}

Job :: struct {
	id:        u64, // unique across boards; contracts refer to it
	kind:      Job_Kind,
	from, to:  int, // market indices in the system the board belongs to
	commodity: Commodity,
	units:     f64,
	reward:    f64,
	deadline:  f64, // game seconds
	posted:    f64,
	person:    u64, // passenger seed (Passenger only)
}

Board :: struct {
	market: int,
	day:    int, // the day it was generated for
	jobs:   [dynamic]Job,
}

BOARD_MIN :: 3
BOARD_MAX :: 6

// Regenerate every board whose day has passed. Cheap enough to call each frame.
boards_refresh :: proc(e: ^Economy, sys: ^gen.System, t: f64) {
	day := int(t / core.SECONDS_PER_DAY)
	if len(e.boards) != len(e.markets) {
		for &b in e.boards do delete(b.jobs)
		resize(&e.boards, len(e.markets))
		for &b, i in e.boards do b = Board{market = i, day = -1}
	}
	for &b, i in e.boards {
		if b.day == day do continue
		b.day = day
		clear(&b.jobs)
		generate_board(e, sys, i, day, &b.jobs)
	}
}

@(private = "file")
generate_board :: proc(e: ^Economy, sys: ^gen.System, market: int, day: int, out: ^[dynamic]Job) {
	if len(e.markets) < 2 do return
	r := core.rng_make(core.sub_seed(sys.seed, "jobs", market * 100000 + day))
	n := core.rng_int(&r, BOARD_MIN, BOARD_MAX + 1)
	here := &e.markets[market]
	now := f64(day) * core.SECONDS_PER_DAY
	for k in 0 ..< n {
		// A destination other than here, weighted toward nothing in particular.
		to := core.rng_int(&r, 0, len(e.markets) - 1)
		if to >= market do to += 1
		there := &e.markets[to]
		est_t, _ := transfer_estimate(sys, here, there)
		days := est_t / core.SECONDS_PER_DAY
		job := Job{id = core.sub_seed(sys.seed, "job", market * 1000000 + day * 100 + k), from = market, to = to, posted = now}
		roll := core.rng_f64(&r)
		switch {
		case roll < 0.45:
			job.kind = .Delivery
			// Something this market has to spare, wanted over there.
			best, best_v := Commodity.Ore, -1.0
			for c in Commodity {
				v := (here.stock[c] / max(here.target[c], 1)) * sell_price(there, c) * core.rng_range(&r, 0.7, 1.3)
				if v > best_v { best_v = v; best = c }
			}
			job.commodity = best
			job.units = f64(core.rng_int(&r, 2, 5)) * 4
			job.reward = job.units * price(there, best) * core.rng_range(&r, 0.35, 0.6) + days * 40
		case roll < 0.8:
			job.kind = .Procurement
			// What the destination is short of.
			best, best_v := Commodity.Food, -1.0
			for c in Commodity {
				v := (1 - there.stock[c] / max(there.target[c], 1)) * core.rng_range(&r, 0.7, 1.3)
				if v > best_v { best_v = v; best = c }
			}
			job.commodity = best
			job.units = f64(core.rng_int(&r, 2, 5)) * 3
			job.reward = job.units * price(there, best) * core.rng_range(&r, 0.5, 0.9) + days * 40
			job.from = -1 // anywhere
		case:
			job.kind = .Passenger
			job.person = core.sub_seed(job.id, "passenger")
			job.reward = 120 + days * 90 * core.rng_range(&r, 0.8, 1.4)
		}
		// Deadline: comfortably more than the estimated transfer, with slack.
		job.deadline = now + max(est_t * core.rng_range(&r, 1.8, 3.0), 2 * core.SECONDS_PER_DAY) + core.rng_range(&r, 0, core.SECONDS_PER_DAY)
		job.reward = f64(int(job.reward))
		append(out, job)
	}
}

// The job with this id on any board, if it is still posted.
find_job :: proc(e: ^Economy, id: u64) -> (Job, bool) {
	for &b in e.boards do for j in b.jobs do if j.id == id do return j, true
	return {}, false
}

// Pull a job off its board (accepted).
take_job :: proc(e: ^Economy, id: u64) -> (Job, bool) {
	for &b in e.boards do for j, k in b.jobs do if j.id == id {
		ordered_remove(&b.jobs, k)
		return j, true
	}
	return {}, false
}

// Can this job be accepted with `free` units of hold? Deliveries hand over
// their goods on the spot.
job_accept_ok :: proc(j: Job, free: f64) -> (bool, string) {
	if j.kind == .Delivery && free < j.units do return false, fmt.tprintf("needs %.0f free hold", j.units)
	return true, ""
}

// Is the job satisfied at market `at` with this hold?
job_deliverable :: proc(j: Job, at: int, cargo: []f64) -> bool {
	if at != j.to do return false
	switch j.kind {
	case .Delivery, .Procurement: return cargo[int(j.commodity)] >= j.units - 1e-9
	case .Passenger:              return true
	}
	return false
}

// One-line description for boards and contract lists.
job_describe :: proc(e: ^Economy, j: Job) -> string {
	to := j.to < len(e.markets) ? e.markets[j.to].name : "?"
	switch j.kind {
	case .Delivery:    return fmt.tprintf("Deliver %.0f %s to %s", j.units, NAMES[j.commodity], to)
	case .Procurement: return fmt.tprintf("Bring %.0f %s to %s", j.units, NAMES[j.commodity], to)
	case .Passenger:   return fmt.tprintf("Passenger to %s", to)
	}
	return ""
}

boards_destroy :: proc(e: ^Economy) {
	for &b in e.boards do delete(b.jobs)
	delete(e.boards)
}
