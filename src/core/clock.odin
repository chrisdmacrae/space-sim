package core

import "core:fmt"

// Time steps: game time that passes per real second. "1 s" is real time.
WARP_LEVELS := [?]f64{1, SECONDS_PER_MINUTE, 10 * SECONDS_PER_MINUTE, 30 * SECONDS_PER_MINUTE, SECONDS_PER_HOUR, SECONDS_PER_DAY, 30 * SECONDS_PER_DAY, SECONDS_PER_YEAR}
WARP_LABELS := [?]string{"1 s", "1 min", "10 min", "30 min", "1 hour", "1 day", "1 month", "1 year"}

Clock :: struct {
	t:          f64, // game seconds since epoch
	warp_index: int,
	paused:     bool,
}

clock_warp :: proc(c: ^Clock) -> f64 {
	return c.paused ? 0 : WARP_LEVELS[c.warp_index]
}

clock_warp_up :: proc(c: ^Clock) {
	c.warp_index = min(c.warp_index + 1, len(WARP_LEVELS) - 1)
}

clock_warp_down :: proc(c: ^Clock) {
	c.warp_index = max(c.warp_index - 1, 0)
}

// Advance by an explicit warp factor (used by warp-to-node).
clock_advance_warp :: proc(c: ^Clock, real_dt, warp: f64) -> f64 {
	dt := real_dt * warp
	c.t += dt
	return dt
}

// Advance by one real frame. `cap` limits the effective warp (thrusting
// ships integrate, so warp is held down while the engine is lit). Returns the
// game seconds elapsed.
clock_advance :: proc(c: ^Clock, real_dt: f64, cap: f64 = 1e300) -> f64 {
	dt := real_dt * min(clock_warp(c), cap)
	c.t += dt
	return dt
}

Calendar :: struct {
	year, day, hour, minute, second: int,
}

clock_calendar :: proc(t: f64) -> Calendar {
	s := i64(t)
	cal: Calendar
	cal.year = int(s / i64(SECONDS_PER_YEAR)) + 1
	s %= i64(SECONDS_PER_YEAR)
	cal.day = int(s / i64(SECONDS_PER_DAY)) + 1
	s %= i64(SECONDS_PER_DAY)
	cal.hour = int(s / i64(SECONDS_PER_HOUR))
	s %= i64(SECONDS_PER_HOUR)
	cal.minute = int(s / i64(SECONDS_PER_MINUTE))
	cal.second = int(s % i64(SECONDS_PER_MINUTE))
	return cal
}

// Temp-allocated "Y0001 D001 00:00:00".
clock_format :: proc(t: f64) -> string {
	c := clock_calendar(t)
	return fmt.tprintf("Y%04d D%03d %02d:%02d:%02d", c.year, c.day, c.hour, c.minute, c.second)
}

// The current step's label: "1 s", "1 day", or "paused".
clock_warp_label :: proc(c: ^Clock) -> string {
	if c.paused do return "paused"
	return WARP_LABELS[c.warp_index]
}

// "1 day per second"
clock_warp_describe :: proc(c: ^Clock) -> string {
	if c.paused do return "paused"
	return fmt.tprintf("%s per second", WARP_LABELS[c.warp_index])
}

clock_set_index :: proc(c: ^Clock, i: int) {
	c.warp_index = clamp(i, 0, len(WARP_LEVELS) - 1)
}

// Temp-allocated human duration: "3.2d", "5.1h", "42m".
clock_duration :: proc(seconds: f64) -> string {
	switch {
	case seconds < 30:                return "now"
	case seconds >= SECONDS_PER_YEAR: return fmt.tprintf("%.1fy", seconds / SECONDS_PER_YEAR)
	case seconds >= SECONDS_PER_DAY:  return fmt.tprintf("%.1fd", seconds / SECONDS_PER_DAY)
	case seconds >= SECONDS_PER_HOUR: return fmt.tprintf("%.1fh", seconds / SECONDS_PER_HOUR)
	case:                             return fmt.tprintf("%.0fm", seconds / SECONDS_PER_MINUTE)
	}
}
