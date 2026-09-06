package econ

import "core:testing"
import core "sim:core"
import gen "sim:gen"

@(test)
job_boards_are_deterministic_and_sane :: proc(t: ^testing.T) {
	sys := gen.generate(3)
	defer gen.destroy(&sys)
	e: Economy
	defer destroy(&e)
	build(&e, &sys)
	boards_refresh(&e, &sys, 0)
	testing.expect(t, len(e.boards) == len(e.markets), "a board per market")
	total := 0
	for b in e.boards {
		testing.expectf(t, len(b.jobs) >= BOARD_MIN && len(b.jobs) <= BOARD_MAX, "board has %d jobs", len(b.jobs))
		for j in b.jobs {
			total += 1
			testing.expect(t, j.to != b.market && j.to >= 0 && j.to < len(e.markets), "goes somewhere else")
			testing.expect(t, j.reward > 0 && j.deadline > 2 * core.SECONDS_PER_DAY - 1, "paid, with a deadline")
			if j.kind == .Delivery do testing.expect(t, j.from == b.market && j.units > 0, "deliveries start here")
			if j.kind == .Procurement do testing.expect(t, j.from < 0 && j.units > 0, "procurement from anywhere")
			if j.kind == .Passenger do testing.expect(t, j.person != 0, "a passenger has a seed")
			testing.expect(t, job_describe(&e, j) != "", "describable")
		}
	}
	// Same day again: identical boards. Next day: fresh ones.
	first := e.boards[0].jobs[0].id
	boards_refresh(&e, &sys, 3600)
	testing.expect(t, e.boards[0].jobs[0].id == first, "stable within the day")
	boards_refresh(&e, &sys, core.SECONDS_PER_DAY + 1)
	testing.expect(t, e.boards[0].jobs[0].id != first, "new jobs the next day")
	// Taking a job removes it; delivery rules hold.
	j := e.boards[0].jobs[0]
	taken, ok := take_job(&e, j.id)
	testing.expect(t, ok && taken.id == j.id, "taken")
	_, still := find_job(&e, j.id)
	testing.expect(t, !still, "gone from the board")
	cargo := make([]f64, len(Commodity))
	defer delete(cargo)
	if taken.kind != .Passenger {
		testing.expect(t, !job_deliverable(taken, taken.to, cargo), "nothing aboard: not deliverable")
		cargo[int(taken.commodity)] = taken.units
		testing.expect(t, job_deliverable(taken, taken.to, cargo), "with the goods at the destination: deliverable")
		testing.expect(t, !job_deliverable(taken, taken.from, cargo), "not at the origin")
	}
	ok2, _ := job_accept_ok(Job{kind = .Delivery, units = 12}, 4)
	testing.expect(t, !ok2, "a delivery needs hold space")
}
