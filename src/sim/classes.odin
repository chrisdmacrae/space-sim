package sim

// Flight stats per ship class (docs/DESIGN.md §5.5). Cargo hold, in-system
// drive and cryo drive are the three purchase axes.

import econ "sim:econ"

Class_Stats :: struct {
	stats:      Ship_Stats,
	cryo_speed: f64,    // fraction of c
	art:        string, // .fart document name
}

CLASSES := [econ.Class_Id]Class_Stats {
	.Courier   = {Ship_Stats{mass_dry = 10, propellant_cap = 8, thrust = 0.0018, ve = 0.34, cargo_cap = 20}, 0.10, "courier"},
	.Hauler    = {Ship_Stats{mass_dry = 26, propellant_cap = 16, thrust = 0.0030, ve = 0.32, cargo_cap = 80}, 0.10, "hauler"},
	.Clipper   = {Ship_Stats{mass_dry = 14, propellant_cap = 14, thrust = 0.0036, ve = 0.40, cargo_cap = 40}, 0.25, "clipper"},
	.Freighter = {Ship_Stats{mass_dry = 60, propellant_cap = 40, thrust = 0.0050, ve = 0.30, cargo_cap = 200}, 0.15, "freighter"},
	.Sleeper   = {Ship_Stats{mass_dry = 20, propellant_cap = 16, thrust = 0.0032, ve = 0.36, cargo_cap = 60}, 0.50, "sleeper"},
}

// Replace the hull: stats change, cargo and propellant carry over as far as
// they fit (the caller settles what does not).
refit :: proc(s: ^Ship, c: econ.Class_Id) {
	s.class = c
	s.stats = CLASSES[c].stats
	s.propellant = min(s.propellant, s.stats.propellant_cap)
	s.hull = 1 // a different hull is a new hull
}
