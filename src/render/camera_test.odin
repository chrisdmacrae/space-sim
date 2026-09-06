package render

import "core:math"
import "core:testing"

@(test)
rotated_camera_round_trips_and_turns_headings :: proc(t: ^testing.T) {
	cam := Camera{target = {100, 50}, zoom = 2, angle = 0.7}
	// screen_center needs a window; test the pure pieces around it instead.
	d := screen_delta_to_world(&cam, {10, 0})
	testing.expectf(t, math.abs(math.sqrt(d.x * d.x + d.y * d.y) - 5) < 1e-9, "a 10 px screen move is 5 world units at zoom 2 (%v)", d)
	testing.expectf(t, math.abs(math.atan2(d.y, d.x) + 0.7) < 1e-9, "the move is turned back by the view angle (%v)", math.atan2(d.y, d.x))
	testing.expectf(t, math.abs(f64(screen_rot(&cam, 0.3)) + 1.0) < 1e-6, "screen rotation adds the view angle (%v)", screen_rot(&cam, 0.3))
	camera_face(&cam, 0.3)
	testing.expectf(t, math.abs(f64(screen_rot(&cam, 0.3)) + math.PI / 2) < 1e-6, "facing a heading puts it straight up on screen")
}
