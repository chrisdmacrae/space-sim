package core

// Game-scale constants (docs/DESIGN.md §3). Distances are world units, time
// is game seconds, G = 1 so a body's `mu` is its mass. Everything that decides
// scale lives here so retuning is one edit; the formulas never change.
//
// Derivation: a 1-solar-mass star has radius 120 units and an Earth-mass rocky
// world 10.8 units. An Earth-mass planet at a = 600 units has a 2-day year, and
// its low parking orbit (2.5 radii) takes about six hours. Planet/star mass
// ratios are ~1/150 (much larger than reality) so spheres of influence are a
// visible fraction of orbit spacing.
//
// Bodies are deliberately oversized against their orbits — drawn to true scale
// a planet is a sub-pixel speck beside its own orbit — but the ladder
// ship < station < moon < planet < star is held in proportion so that a world
// reads as a world when you are in orbit around it.

SECONDS_PER_MINUTE :: 60.0
SECONDS_PER_HOUR   :: 3600.0
SECONDS_PER_DAY    :: 86400.0
DAYS_PER_YEAR      :: 365.0
SECONDS_PER_YEAR   :: SECONDS_PER_DAY * DAYS_PER_YEAR

MU_SOLAR    :: 0.30   // mu of a 1-solar-mass star
MU_EARTH    :: 0.002  // mu of a 1-earth-mass planet
STAR_RADIUS :: 120.0  // radius of a 1-solar-mass star, world units

// Body radii, world units. Radius grows as mass^0.3, so each constant is the
// radius at the reference mass named beside it (earth masses).
PLANET_R_GAS  :: 33.0 // at 5 earth masses
PLANET_R_ATMO :: 11.4 // at 1 earth mass
PLANET_R_ROCK :: 10.8 // at 1 earth mass; molten worlds share it
PLANET_R_ICE  ::  9.6 // at 1 earth mass
MOON_R        ::  5.4 // at 1 earth mass; moons are a few hundredths of that

// A colony needs a body big enough to orbit and shuttle to.
COLONY_MIN_RADIUS :: 3.0

// Equilibrium temperature: T = TEMP_REF * L^(1/4) * sqrt(TEMP_REF_A / a).
// Thresholds decide planet kind (docs/DESIGN.md §2.4).
TEMP_REF       :: 288.0
TEMP_REF_A     :: 1000.0
TEMP_MOLTEN    :: 450.0
TEMP_ROCK      :: 320.0
TEMP_FROST     :: 210.0

// Ship and station art scale. The two documents are sized differently — a
// courier is 29 units long, a station spans 24 — so the scales are not
// comparable on their own: what matters is the world size they produce. A
// station lands at 1.2 units against a courier's 0.58 and a freighter's 1.22,
// so it reads as roughly a freighter's footprint.
SHIP_DOC_SCALE    :: 0.02 // world units per ship-document unit (a courier is ~0.6 units long)
STATION_DOC_SCALE :: 0.05 // world units per station-document unit (~1.2 units across)
STATION_DOC_HALF  :: 12.0 // the envelope every station document fits (tools/gen_stations.py)
