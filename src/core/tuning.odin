package core

// Knobs (docs/DESIGN.md §11): numbers turned while playtesting, exposed as
// sliders in the debug panel. Add a field here and a slider in ui/debug_panel
// when a new knob appears; never bury a tunable in a package.

// Player-facing graphics switches (Settings > Graphics).
Gfx :: struct {
	effects:      bool, // explosions, cryo streaks
	shading:      bool, // planet lighting overlays
	star_density: f32,  // background starfield, 0.25..2 of the default count
}

gfx := Gfx{effects = true, shading = true, star_density = 1}

Tuning :: struct {
	// Icon floors: the size a thing stops shrinking at, so it does not vanish
	// when the view pulls back. Each is a finished on-screen size in px, not a
	// per-document-unit rate, so the three rank directly against one another and
	// a freighter's longer document no longer floors it bigger than a station.
	// Keep them small: a floor that binds over a wide zoom band stops the scene
	// scaling with the camera, which reads worse than a few tiny marks.
	ship_min_px:          f32, // shortest a hull draws, any class, in px
	body_min_px:          f32, // smallest on-screen body radius in px
	star_glow_scale:      f32, // multiplies the star doc's halo (1 = as authored)
	label_min_orbit_px:   f32, // draw a body's label once its orbit radius exceeds this
	station_min_px:       f32, // smallest a station draws, across, in px
	warp_max_thrusting:   f32, // warp cap while the player is thrusting by hand (§3)
	warp_max_autoburn:    f32, // warp cap during an automatic burn (no hand on the stick)
	auto_leg_seconds:     f32, // auto time: the least real seconds a coast to the next burn or event takes
	turn_rate:            f32, // ship rotation, radians per real second
	k_time:               f32, // balanced objective: weight of time against Δv (§5.4, §11)
	price_curve_k:        f32, // max price swing between empty and flooded markets (§6.2)
	skim_cycle_hours:     f32, // game hours the scoop takes per pass through a nebula (§2.6)
	dust_hull_hours:      f32, // hours to lose a whole hull in the thickest ordinary gas
	crew_xp_rate:         f32, // multiplier on how fast crew level up at their posts (§5.9)
}

tuning := Tuning {
	ship_min_px          = 6,
	body_min_px          = 5,
	star_glow_scale      = 1,
	label_min_orbit_px   = 60,
	station_min_px       = 8,
	warp_max_thrusting   = 4,
	warp_max_autoburn    = 50,
	auto_leg_seconds     = 12,
	turn_rate            = 2.5,
	k_time               = 1,
	price_curve_k        = 4,
	skim_cycle_hours     = 2,
	dust_hull_hours      = 150,
	crew_xp_rate         = 1,
}

// Debug draw toggles; not gameplay.
Debug_Flags :: struct {
	show_orbits: bool,
	show_labels: bool,
	show_soi:    bool,
	show_belts:  bool,
	show_predict: bool,
	show_routes: bool,
}

debug := Debug_Flags {
	show_orbits = true,
	show_labels = true,
	show_soi    = false,
	show_belts  = true,
	show_predict = true,
	show_routes = false,
}
