package econ

// Ship classes as the economy sees them (docs/DESIGN.md §5.5): what a yard
// consumes to build one, and the base price. Flight stats live in sim.

NUM_CLASSES :: 5

Class_Id :: enum u8 {
	Courier,
	Hauler,
	Clipper,
	Freighter,
	Sleeper,
}

CLASS_NAMES := [Class_Id]string{.Courier = "Courier", .Hauler = "Hauler", .Clipper = "Clipper", .Freighter = "Freighter", .Sleeper = "Sleeper"}

CLASS_PRICE := [Class_Id]f64{.Courier = 6000, .Hauler = 14000, .Clipper = 22000, .Freighter = 38000, .Sleeper = 60000}

// Units of each input a yard consumes to build one hull.
CLASS_BUILD_COST := [Class_Id]Rates {
	.Courier   = #partial Rates{.Metals = 40, .Electronics = 8, .Machinery = 6, .Plastics = 10},
	.Hauler    = #partial Rates{.Metals = 90, .Electronics = 12, .Machinery = 14, .Plastics = 20},
	.Clipper   = #partial Rates{.Metals = 70, .Electronics = 30, .Machinery = 16, .Plastics = 14, .Rare_Metals = 6},
	.Freighter = #partial Rates{.Metals = 200, .Electronics = 20, .Machinery = 30, .Plastics = 40},
	.Sleeper   = #partial Rates{.Metals = 120, .Electronics = 50, .Machinery = 24, .Plastics = 20, .Rare_Metals = 20, .Medicine = 10},
}

BUILD_DAYS :: 6.0   // days of full-rate work per hull
YARD_MAX_STOCK :: 2 // hulls of one class a yard keeps

// Price a yard quotes now: scarce stock costs more.
class_price :: proc(m: ^Market, c: Class_Id) -> f64 {
	f := clamp(1.3 - 0.15 * f64(m.ships[c]), 0.9, 1.3)
	return CLASS_PRICE[c] * f
}

// Trade-in value of a hull.
trade_in_value :: proc(c: Class_Id) -> f64 {
	return CLASS_PRICE[c] * 0.55
}
