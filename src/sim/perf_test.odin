package sim

import "core:fmt"
import "core:testing"
import "core:time"
import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"

// Frame cost at 10,000x: report the worst and mean frame so regressions show.
@(test)
frame_cost_at_high_warp :: proc(t: ^testing.T) {
	sys := gen.generate(gen.system_seed(1, 0))
	defer gen.destroy(&sys)
	e: econ.Economy
	defer econ.destroy(&e)
	econ.build(&e, &sys)
	f: Fleet
	defer fleet_destroy(&f)
	fleet_spawn(&f, &sys, &e, 0)
	dt := 10000.0 / 60.0
	tt := 0.0
	worst := time.Duration(0)
	total := time.Duration(0)
	frames := 2000
	for _ in 0 ..< frames {
		start := time.tick_now()
		gen.update(&sys, tt + dt)
		fleet_update(&f, &sys, &e, tt, dt)
		econ.update(&e, tt + dt)
		d := time.tick_since(start)
		worst = max(worst, d)
		total += d
		tt += dt
	}
	mean := time.duration_milliseconds(total) / f64(frames)
	fmt.printfln("high-warp frames: mean %.2f ms, worst %.1f ms over %v game days", mean, time.duration_milliseconds(worst), tt / core.SECONDS_PER_DAY)
	testing.expectf(t, mean < 4, "mean frame %.2f ms too slow", mean)
}
