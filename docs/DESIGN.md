# Space Sim — Design and Engine Outline

Top-down 2D, "low-space" (thrust-only) ships, Keplerian orbits, a living economy,
sub-light interstellar travel under cryo sleep. Written in Odin.

This document is the working design. It is organised as:

1. Core principles (the rules everything else obeys)
2. World model (galaxy, star systems, bodies)
3. Time
4. Flight model (orbits, patched conics, slingshots, burns)
5. Ships (player and NPC)
6. Economy (micro in the active system, macro everywhere else)
7. Interstellar travel (cryo)
8. Engine architecture in Odin
9. Build phases
10. Decisions
11. Tuning knobs (numbers to turn while playtesting)

---

## 1. Core principles

**Everything is a function of (seed, time).**
Stellar bodies, station placement, planet types, initial market state and NPC
traffic are all derived from a hierarchical seed. Nothing about the base world is
stored. Only *deltas* caused by time passing and the player acting are stored.

**Bodies are on rails.** Planets, moons, stations and asteroid belts follow
closed-form Kepler orbits. Their position at any time `t` is O(1) to evaluate and
never needs integration. This is what makes "only compute when the player is in
the system" and time warp both trivial: a body that is not being looked at costs
nothing, and a body that is looked at after 40 years costs one Kepler solve.

**Ships are on rails when coasting and integrated when thrusting.** (The Kerbal
Space Program model.) A coasting ship is a conic section relative to its dominant
body; its position is also closed-form. Only a ship with its engine lit needs
numerical integration, and only the player ship thrusts in real time. NPC ships
apply their burns as instantaneous impulses at planned times.

**A ship is never "nowhere".** Every ship is always in exactly one of:
orbiting a body (conic), thrusting (integrating), docked (rides its station's
orbit), or in cryo transit between stars (a position on a galaxy edge). There is
no "parked in free space" state.

**Two economies, one truth.** The active star system runs a *micro* economy where
NPC ships physically carry cargo. Every other system runs a *macro* economy where
trade is a set of flows. The macro model is calibrated so that its flows equal
what the micro model would produce on average. Switching a system from macro to
micro (player arrives) or micro to macro (player leaves) must not visibly jump
prices.

**f64 for the simulation, f32 relative to the camera for rendering.** At orbital
scales f32 positions drift. All sim state is f64; the renderer subtracts a
floating origin before converting.

---

## 2. World model

### 2.1 Galaxy

A small graph of star systems (tens to low hundreds), not a continuous field.

```
Galaxy
  seed: u64
  systems: []SystemSummary      // generated from seed; cheap
  edges:   []Edge               // (a, b, distance_ly)
```

`SystemSummary` is the *cheap* view of a system: star class, planet count, tags
("gas giant present", "habitable band occupied"), economic profile. It is enough
to run the macro economy and draw the galaxy map. The full system is only
generated when the player enters it.

Edges are the routes ships take in cryo. Star positions are generated in 2D from
the seed (Poisson-disc scatter, then k-nearest edges with a max distance) so the
map looks like a map and travel graphs are sparse.

### 2.2 Seeding

Hierarchical seeds, so any part of the world can be regenerated in isolation:

```
galaxy_seed
  system_seed[i]      = hash(galaxy_seed, "system", i)
    star_seed         = hash(system_seed, "star")
    planet_seed[j]    = hash(system_seed, "planet", j)
      moon_seed[k]    = hash(planet_seed[j], "moon", k)
      outpost_seed    = hash(planet_seed[j], "outpost")
    station_seed[s]   = hash(system_seed, "station", s)
    economy_seed      = hash(system_seed, "economy")
    traffic_seed      = hash(system_seed, "traffic")
```

`core:math/rand` has PCG and xoshiro generators; make a fresh generator from the
sub-seed and draw. Never share a generator across two things that could be
generated in a different order.

### 2.3 Star variants

The star stream rolls one of seven kinds (`gen.roll_star`, shared by the
generator and the map summary so both agree). Weights: main sequence 70,
giant 8, supergiant 2, white dwarf 7, neutron 3, pulsar 3, brown dwarf 7.

| kind | class | numbers (game scale) | effect on the system |
|---|---|---|---|
| main sequence | O B A F G K M by temperature, M most common | mass by class, L = m^3.5 (capped), colour by class | the normal case |
| giant | K/M red (80%) or B blue | 1–8 Msol, L 60–900, radius 5–24× | planets start far out, the heat line is wide |
| supergiant | M red or B blue | 10–30 Msol, L 1200–3000, radius 14–45× | huge, few planets, heat line thousands of units |
| white dwarf | D | 0.5–1.2 Msol, L 0.002–0.04, radius 0.16× | compact cold system, 1–4 planets |
| neutron star | N | 1.4–2.1 Msol, L ~0.001, radius 0.08× | deep well, hard radiation to 8 radii, 0–3 planets |
| pulsar | P | as neutron plus a wind 500–1100 units, spinning beams | wind zone damages hulls; planets sit outside it |
| brown dwarf | L/T | 0.02–0.08 Msol, L ~1e-4, radius 0.13× | dim ember, 1–3 cold planets |

Every star has a **heat line** (`heat_radius`): the radius where the
equilibrium temperature passes 900 K, never under 1.5 radii. Planets are laid
out beyond it (and beyond any wind), and the first planet is pushed out until
its sphere of influence can hold a station. The autopilot treats the larger of
heat line and wind as the star's safe radius, so NPC transfers keep clear.

### 2.3 Star system

```
StarSystem
  star:      Star                 // mass, luminosity, radius, colour
  bodies:    []Body               // SoA in practice; see §8
  stations:  []Station
  belts:     []Belt
  markets:   []Market             // one per station and per outpost
  npc_ships: []Ship               // only while active
```

`Body` is a planet or moon:

```
Body
  parent:     BodyHandle          // star, or a planet for moons
  mass, radius: f64
  kind:       BodyKind            // Molten, Rock, Atmospheric, Gas, Ice
  orbit:      Orbit               // Kepler elements relative to parent
  soi_radius: f64                 // sphere of influence, precomputed
  outpost:    Maybe(MarketHandle)
```

### 2.4 Planet types from physics, not from a random pick

Type is decided by equilibrium temperature at the planet's distance from the
star, plus mass. This makes systems feel coherent (hot inner rocks, a habitable
band, giants past the frost line, ice at the edge) and gives each type a natural
economic role.

| Kind        | Where                              | Produces                           | Consumes            |
|-------------|------------------------------------|------------------------------------|---------------------|
| Molten      | Inside the inner edge; tidally hot | Rare metals, energy (solar/thermal)| Coolant, machinery  |
| Rock        | Inner to mid                       | Ore, base metals, silicates        | Food, water, parts  |
| Atmospheric | Habitable band, enough mass        | Food, biologics, people, goods     | Metals, fuel, luxury|
| Gas         | Past the frost line, high mass     | Fuel (H2/He3), propellant          | Machinery, food     |
| Ice         | Far out, low mass                  | Water, volatiles, oxygen           | Energy, food        |

Generation order: pick planet count, lay out semi-major axes (log-spaced with a
minimum ratio between neighbours so orbits don't cross), draw eccentricities
from a low-mean distribution, then assign mass and derive type from temperature
and mass. Gas giants get moons. Belts fill large gaps.

### 2.5 Stations and colonies

* **Colonies** sit on a planet's surface (`Body.colony`); their market rides
  the planet and there is nothing to dock with. Trading happens from a low
  orbit inside `gen.shuttle_range`: orders queue on a shuttle
  (`sim/shuttle.odin`, ten units per trip each way) that flies down, sells
  and buys on the ground, and climbs back, taking a few game hours per round
  trip from a low orbit; it only makes progress while the ship holds that
  orbit. Traders do the same abstractly: a colony is a `Body` destination,
  and a trader parked in its low orbit trades there (`npc_market`).

### 2.6 Nebulae

A nebula is gas and dust with no mass worth integrating: it does not orbit,
nothing orbits it, and it is not a body. It is a **region** — a centre, an
extent, and a density you can evaluate anywhere — which is what lets a ship
sit inside one. `gen/nebula.odin` owns the model; `gen.nebula_density_at`
is the single field that art, hazards, skimming and the NPC survey all read,
so where a cloud *looks* thick is where the scoop fills fastest and where the
hull wears.

**The kind follows the star.** A cloud and the star inside it are the same
fact seen twice, so the kind is derived from `Star.kind` and only the roll for
whether it is there at all is free:

| star | nebula | why |
|---|---|---|
| neutron star, pulsar | supernova remnant | the blast that made it |
| white dwarf | planetary nebula | the envelope it shed |
| O/B main sequence, blue giant/supergiant | emission | gas it has ionised |
| A/F/G/K main sequence, red giant | reflection | dust scattering its light |
| M dwarf, brown dwarf | star nursery | the cloud it is still condensing out of |

About one system in six holds a cloud. The roll is drawn on its own
`"nebula"` seed stream, so adding nebulae left every star, planet and station
of every existing galaxy seed exactly where it was.

**Shape.** Remnants and planetary nebulae are *shells*: `hollow > 0` and the
density peaks in a band between the inner and outer edges, with the star in
the empty middle. The rest are clouds with a smooth falloff, offset to one
side of the system. Both carry a handful of gaussian **lobes** so the gas
gathers around a few centres instead of filling a disc — without them a cloud
reads as a smudge and gives the scoop nowhere better to sit than anywhere
else. A shell's inner edge is pushed clear of the star's heat line and any
pulsar wind, so there is somewhere safe to work.

**Scale.** Star systems here span four orders of magnitude and real nebulae do
not, so the scale a cloud is laid out against is bounded at both ends
(`NEBULA_SCALE_CAP`), and a **site** — a cloud with no planets to be measured
against — gets a fixed one (`NEBULA_SITE_SCALE`).

**Sites: nebulae as their own destination.** Some clouds are large enough that
the system is the cloud. `Summary.is_site` marks them on the galaxy map, where
they are drawn as coloured gas rather than a star point and labelled wherever
they are. A site generates with **no planets and no stations**: the core star,
the cloud, and the survey ships working it. A cryo arrival wakes just outside
the gas (`arrival_radius` takes the cloud into account), so going in is a
decision.

**Skimming** (`sim/skim.odin`). The ship spreads its scoop and waits. Every
pass — `tuning.skim_cycle_hours`, two game hours by default — strains the
kind's mix out of the cloud, scaled by the density where the ship is sitting,
and tops the tank from the raw hydrogen. Like the colony shuttle, the timer
only advances while the ship is actually in the gas: drift out and the pass
stops where it stands and resumes when you come back. The mix is in
`econ/nebula.odin` and follows what the gas is made of — hydrogen and ices
from a molecular cloud, ionised hydrogen and oxygen from an emission nebula,
silicate grains from a reflection nebula, and **heavy metals from a supernova
shell**, which is the only place in the sky that makes them.

The point of skimming is not profit — raw gas is cheap — it is that it is the
only way to refuel with no station in reach.

**Dust is a hazard** (`Hazard.Dust`). Grains scour the hull at
`density / tuning.dust_hull_hours`, four times that in the shock-heated gas of
a supernova remnant. It is slow, so only the thick of a cloud stops the clock
with a notice, and that notice says what the gas yields as well as what it
costs. `Ship.dust_hardened` exempts survey hulls: sitting in gas is what they
are built for, and it is why survey work is its own trade rather than a
sideline.

**Survey ships** (`sim/survey.odin`). A surveyor is a trader that has swapped
the route table for a cloud. It parks in the thick of one, runs the same
`Skim` the player does, and moves to a new patch when the gas thins or it has
sat long enough — an ordinary `.Point` destination through the shared
autopilot. When the hold fills and the system has a market it runs the haul
in and comes back out; when it does not, it keeps working. None of that reads
the economy, which is exactly why a nebula site with no stations and no
markets at all still has ships going about their business.

---

## 3. Time

```
Clock
  t:     f64      // game seconds since epoch
  warp:  f64      // game seconds per real second: 1, 60, 600, 1800, 3600, 1 day, 30 days, 1 year
  epoch: Date     // for display only
```

Rules:

* Bodies and coasting ships cost the same at any warp (closed form).
* Warp is capped while the player ship is thrusting (integration accuracy).
* The economy ticks on a fixed game-time cadence, not per frame:
  micro tick every game hour, macro tick every game day. At high warp, many
  ticks run per frame; at very high warp (cryo) ticks are batched (see §7).
* Fixed-step accumulator for the player's integration, interpolated for render.

Displayed units: game seconds internally; days/years in the UI.

**Decided: game scale.** Distances and masses are compressed so the inner
system fits on screen with a few orbits visible, an inner planet's year is
minutes at 1000×, and a burn of a few minutes is a meaningful fraction of an
orbit. `G`, masses and distances are chosen together and are self-consistent,
so vis-viva, SOI radii, Hohmann Δv and flyby turn angles all hold as written.
Only the constants change, never the formulas. Put them in one file
(`core/units.odin`) with the derivation in comments so retuning is one edit.

---

## 4. Flight model

### 4.1 Kepler orbits (bodies, stations, coasting ships)

2D orbital elements relative to a parent:

```
Orbit
  a:      f64     // semi-major axis (negative for hyperbolic)
  e:      f64     // eccentricity
  w:      f64     // argument of periapsis (angle of periapsis from +x)
  M0:     f64     // mean anomaly at epoch t0
  t0:     f64
  mu:     f64     // G * parent mass, cached
  dir:    i8      // +1 prograde, -1 retrograde
```

Position at `t`:

1. `n = sqrt(mu / |a|^3)`, `M = M0 + n (t - t0)`
2. Solve Kepler's equation for `E` (Newton, 5–8 iterations; hyperbolic variant
   when `e > 1`)
3. True anomaly and radius → (x, y) in the orbital frame → rotate by `w`
4. Add parent position (recursively: moon → planet → star)

Velocity is closed-form too, and is needed when a ship leaves rails.

### 4.2 Patched conics

Each body has a sphere of influence `r_soi = a * (m / M_parent)^(2/5)`. A ship
belongs to exactly one body (its *primary*): the deepest body whose SOI contains
it. State (position, velocity) is stored **relative to the primary**.

Transition rules:

* Leaving an SOI: convert state to parent frame (add primary's position and
  velocity), set primary = parent.
* Entering a child's SOI: convert to child frame, set primary = child.
* From the new relative state vector, rebuild the conic (`a` from vis-viva, `e`
  from the eccentricity vector, `w`, `M0`). The ship is back on rails.

This is where slingshots come from for free. A ship on a heliocentric orbit
that crosses a gas giant's SOI follows a hyperbola relative to the giant and
exits with the same speed relative to the giant but a different direction; in
the star's frame its speed has changed. No special-casing.

### 4.3 Thrusting (integration)

While the engine is lit the ship is integrated numerically in its primary's
frame under the primary's gravity plus thrust:

```
a = -mu * r / |r|^3  +  thrust_dir * (thrust / mass)
```

Use a symplectic integrator (velocity Verlet, or RK4 with small substeps).
Mass decreases with propellant burned. Check SOI transitions every step. When
thrust stops, rebuild the conic and return to rails.

Only the player ship integrates in real time. NPC burns are impulsive (see §5).

### 4.4 Trajectory prediction (the key UI element)

The player needs to see where they will go. The predictor:

1. Takes the current state and any planned maneuvers.
2. Walks forward in game time: on rails between events, integrating only across
   a maneuver's burn duration (or treat planned burns as impulses for the
   preview and integrate only the live one).
3. Records SOI transitions and produces a list of conic segments, each tagged
   with its primary and time span.
4. The renderer draws each segment in its primary's frame *at the time the
   ship will be there*, so a flyby around a moving planet is drawn correctly.

Maneuver nodes: (time, Δv prograde, Δv radial). The predictor re-runs when a
node changes. Cache segments; only recompute from the first changed node.

### 4.5 Fuel and Δv

Tsiolkovsky: `Δv = Isp * g0 * ln(m_wet / m_dry)`. Ships carry propellant mass;
the UI shows remaining Δv. Propellant is a commodity (produced by gas and ice
worlds), so fuel is part of the economy, and range is a real constraint that
makes slingshots worth doing.

### 4.6 Travel planning and the autopilot

The primitive is a **maneuver node**: a time plus a Δv split into prograde
and radial components in the ship's local frame at that time. The predictor
runs through nodes as impulses, so the player sees where a planned burn
leads and can drag the node along the path. Warp-to-node jumps time to just
before the burn; autoburn orients the ship, fires for the computed duration,
then replans (a real burn is finite, the plan assumed an impulse).

The **autopilot** is the NPC planner (§5.3–5.4) exposed to the player. Given a
destination it produces candidate plans from the current orbit: Hohmann with
a window wait, direct Lambert for a chosen arrival, gravity assists, plus the
escape and capture legs at either end. Each candidate is a list of legs
(coast, burn, wait), the same structure NPC ships follow. The player picks by
objective; all four are shown side by side with Δv, arrival time, burn count
and propellant left on arrival, and any candidate that does not fit the
remaining propellant is refused before departure.

| Objective   | Picks                                                                 |
|-------------|-----------------------------------------------------------------------|
| Fuel        | Lowest total Δv that fits the tank; accepts the longest window waits    |
| Time        | Earliest arrival that fits the tank; departs now, burns hard           |
| Balanced    | Lowest `Δv · propellant_price + T · time_value` (the NPC cost, §5.4)    |
| Simplest    | Fewest burns, no flybys: a plan the player can follow by hand          |

"Distance" is deliberately not an objective: in orbits the shortest path is
the straight burn, which is the most expensive and rarely the fastest, and
nothing in the sim rewards distance on its own.

The chosen plan becomes nodes on the predictor and stays editable. Execution
is leg by leg: free warp during waits, warp drops to the thrusting cap at a
burn, autoburn fires, the predictor replans, and small correction burns are
added if an encounter drifted.

### 4.7 Arriving and "never idle"

Reaching a destination means matching its orbit: burn into the destination
body's SOI, then circularise or rendezvous with the station's orbit, then dock.
Docked ships inherit the station's orbit. Undocking places the ship on the
station's orbit with a small separation. There is no landed-in-space state.

---

## 5. Ships

### 5.1 Common state

```
Ship
  class:    ShipClassHandle  // stats come from the class (§5.5)
  primary:  BodyHandle
  mode:     enum { OnRails, Thrusting, Docked, Cryo }
  orbit:    Orbit            // valid in OnRails
  pos, vel: [2]f64           // relative to primary; valid in Thrusting
  dock:     StationHandle    // valid in Docked
  propellant: f64            // current; capacity is on the class
  cargo:    []CargoSlot      // capacity is on the class
  owner:    enum { Player, NPC }
  plan:     FlightPlan       // NPC; optional for player (maneuver nodes)
```

#### Hull and hazards (§5.7)

`Ship.hull` is a 0..1 fraction. Nothing repairs it yet; a refit (new class)
gives a new hull. What lowers it, per second, in `sim.apply_hazards`:

- **Heat**: inside the star's heat line, flux `(heat_radius / r)^2` over
  `HEAT_HULL_HOURS` (4 h to lose the whole hull sitting on the line).
- **Pulsar wind**: inside `wind_radius`, `(1.2 - r / wind_radius)` over
  `WIND_HULL_HOURS` (20 h deep in the wind). Slow, but a trader that parks
  there dies.

Docked ships are sheltered. Hull reaching zero, or crossing the star's
surface, calls `blow_up`: mode `Destroyed`, no model drawn, an explosion
effect plays where the ship was (`render.effects`). Surface impacts on
planets remain `Wrecked` (the hull is still there, on the ground). NPC
traders that die are respawned at a port like wrecks. The readout shows the
hull, the active hazard with its rate per hour, and the cause of death.

### 5.2 Flight plans

```
FlightPlan
  legs: []Leg
Leg
  kind:  enum { Coast(orbit, until t), Burn(t, dv vector), Dock(station), Undock, Wait(until t) }
```

A plan is a list of conic segments joined by impulsive burns. Given a plan, a
ship's position at any `t` is closed-form (find the leg, evaluate its conic).
That means an NPC ship costs nothing per frame; it's a lookup.

### 5.3 NPC planner

NPC ships in the active system are real entities with real plans. Their logic is
a small state machine driven by events (docked, arrived, plan finished):

1. **Choose a job.** Ask the economy for the best route from here
   (profit per unit of Δv-and-time, see §6.4). Buy cargo.
2. **Plan a transfer.** The planner produces *candidate* plans and picks the
   cheapest by a cost that mixes Δv (propellant is money) and time (cargo
   depreciates, crews are paid). Candidates, in 2D coplanar space:
   - **Direct Hohmann** (planet → planet around the star). Compute the phase
     angle needed; if the window isn't now, add a `Wait` leg in the current
     orbit until it is. Ships waiting for a window are "always in orbit" by
     construction.
   - **Direct Lambert.** Same endpoints, but a chosen departure and arrival
     time. Costs more Δv than Hohmann, arrives sooner. Lets the planner trade
     propellant for time when a route's price gap is closing.
   - **Gravity-assist Lambert** (§5.4). One or two flybys of massive bodies.
   - Moon → other planet: escape burn from the moon's SOI timed to align with
     the planet's departure direction, then one of the above.
   - Arrival: capture burn at the destination's SOI edge (or a capture flyby
     off a moon), then circularise to the station's altitude and a phasing
     wait to rendezvous.
3. **Execute.** Plans are just legs; the ship follows them. Arrival fires the
   next decision.

### 5.4 NPC slingshots

**Decided: NPCs slingshot.** Watching a freighter swing past a gas giant on the
way inward is worth the planner cost, and the same code serves the player's
autopilot later.

The problem is the classic multiple-gravity-assist search, and in 2D with a
handful of massive bodies it is small:

1. **Candidates.** Bodies with a large SOI (gas giants first, then the star's
   biggest rocks) whose orbit lies between or just beyond the endpoints.
   Precompute this list per (origin, destination) pair when the route table is
   refreshed; it rarely changes.
2. **Search.** For each candidate `M`, grid over departure time `t0` and flyby
   time `t1` (and `t2` for the second leg). Solve Lambert `A(t0) → M(t1)` and
   `M(t1) → B(t2)`. At `M` the incoming and outgoing hyperbolic excess
   velocities `v∞_in`, `v∞_out` must satisfy:
   - `|v∞_in| ≈ |v∞_out|` (an unpowered flyby can only turn the vector), and
   - the turn angle `δ` between them is achievable:
     `δ_max = 2·asin(1 / (1 + r_p·|v∞|² / μ_M))` with `r_p ≥ radius + margin`.
   A mismatch in magnitude is charged as a powered-flyby burn at periapsis;
   if that burn is small the candidate stays, otherwise it's dropped.
3. **Cost.** `Δv_total · propellant_price + T_total · time_value`, compared
   against the direct candidates. `time_value` is derived per trip:
   `time_value = margin_decay_per_day(route) · cargo_capacity · k_time`, where
   `margin_decay_per_day` is how fast the route's price gap is closing and
   `k_time` is a global knob (`tuning.odin`, exposed in the debug panel) turned
   during playtesting. The grid is coarse (a few dozen samples per
   axis), refined once around the best cell. Cache results per route; a
   flyby plan is re-solved only when the route table changes or when the
   phase geometry has drifted past the cached window.
4. **Legs.** The chosen plan becomes ordinary legs: `Burn` at A, `Coast` on the
   heliocentric arc, `Coast` on the hyperbola inside `M`'s SOI (the patched-
   conic transition does the frame change, exactly as for the player), `Coast`
   out, `Burn` to capture at B.

Because the route table stores the canonical plan for spawning traffic (§5.6),
a route that goes by way of a giant spawns ships already mid-flyby. That is the
immersion payoff: the system looks like it has been doing this for years.

Economic side effect, deliberate: routes that can use a gas giant get cheaper,
so the giant's *position* raises the value of trade around it and its fuel
depot sees more traffic. Systems with a well-placed giant become hubs.

Lambert solver: implement a universal-variable or Izzo-style solver in
`orbit/lambert.odin`; 2D removes the plane-choice ambiguity, leaving only the
short/long-way choice. Test against Hohmann in the limiting case.

### 5.5 Ship classes

Ships are bought, and the class decides what a ship can do. Three axes,
each a separate progression:

```
ShipClass
  name:            string
  art:             AssetHandle       // .fart document
  cargo_capacity:  f64               // units of cargo
  mass_dry:        f64
  propellant_cap:  f64
  thrust:          f64               // in-system acceleration = thrust / mass
  isp:             f64               // Δv per propellant mass
  cryo_speed:      f64               // interstellar cruise, fraction of c
  price:           f64               // base; shipyard market adjusts
  build_cost:      [Commodity]f64    // what a shipyard consumes to build one
```

| Axis            | What it buys                                                  | Trade-off                                  |
|-----------------|---------------------------------------------------------------|--------------------------------------------|
| Cargo hold      | Profit per trip                                               | Mass; slower burns, more propellant per Δv |
| In-system drive | Thrust and Isp: shorter burns, more Δv, shorter transfers     | Price; heavy drives eat cargo mass         |
| Cryo drive      | Interstellar cruise fraction of c: fewer years per jump       | Price; the big-ticket upgrade              |

Starter ship: small hold, modest thrust, **0.1c cryo drive**. Ladder sketch
(numbers are placeholders to tune):

| Class      | Cargo | Accel (rel.) | Δv (rel.) | Cryo   |
|------------|-------|--------------|-----------|--------|
| Courier    | 1×    | 1.0          | 1.0       | 0.10c  |
| Hauler     | 4×    | 0.6          | 0.9       | 0.10c  |
| Clipper    | 2×    | 1.4          | 1.3       | 0.25c  |
| Freighter  | 10×   | 0.4          | 0.8       | 0.15c  |
| Sleeper    | 3×    | 1.0          | 1.1       | 0.50c  |

Buying: shipyard stations list classes in stock. A yard builds ships from its
own market's inputs (metals, electronics, machinery), so ship availability and
price are part of the economy: a metal-starved system has no freighters for
sale. Trade-in values the old hull at a fraction of class price. Cargo and
propellant transfer on purchase if they fit; the rest is sold to the yard's
market at its prices.

NPC fleets use the same classes. Route ship counts (§6.4) are in units of
cargo capacity, so a route may be served by many couriers or a few freighters;
the traffic seed picks a mix weighted by what the system's yards can build.

### 5.6 NPC traffic when the system is inactive

There are no NPC entities in inactive systems. Their effect exists only as macro
flows. When the player enters a system, the traffic seed and the current route
table spawn a fleet:

* Each route has a `ship_count` proportional to its macro flow.
* Each ship gets a phase `φ = hash(traffic_seed, route, i) / u64_max`, and is
  placed at `phase = (φ + t / route_period) mod 1` along a canonical plan for
  that route (outbound leg, dock, return leg). Some are at stations, some in
  transfer, some waiting for a window.

This is deterministic, cheap, and looks like a system that has been running
without you. When the player leaves, the fleet is discarded; cargo they were
carrying is folded back into macro flows.

### 5.7 People and conversations

Every trader has a pilot and every station a vendor (`people/people.odin`):
a `Person` rolled from a seed (the trader's seed, or the system seed plus the
station index) with a name, one of five personalities (gruff, cheerful,
nervous, formal, sly) and a face composed from fastart feature documents
(`render/avatar.odin`, generated by `tools/gen_avatars.py`). The same person
is there every time.

**Docking with ships.** A coasting trader is a destination like a station
(`Dest_Kind.Npc` snapshots its orbit; the game refreshes the snapshot each
frame). The autopilot holds alongside; within docking range the player asks
to dock and the pilot answers from their personality, decided once per game
day. Docked, the player's ship rides the host (`Ship.docked_ship`,
`ride_along`) and the trader pauses (`Npc.visitor`); undocking lets it replan
its route. Saves record a ship-docked player as coasting on the host orbit.

**Talking.** Lines live in `assets/dialog/lines.json`, hand-written in
`tools/dialog_lines.py`: categories greeting, small talk, rumour, cargo,
market, dock accept/refuse, trade open, haggle accept/refuse, deal done, no
deal, farewell; each line is for a role (pilot, vendor, any) and a mood.
Personality-specific lines win when they exist. Slots such as {dest_price},
{want}, {glut} and {nearby} are filled from the real economy, so rumours are
information, not flavour.

**Trading with a pilot.** They sell their cargo at the larger of 90% of what
it fetches at their destination and 105% of what they paid, and buy the same
commodity at 103% of their origin price, within their hold and credits. One
haggle per conversation takes 8% off if the personality allows. The market
window shows the station vendor with a greeting and a Talk button.

### 5.7b Orders: movement by intent

`sim/orders.odin`: an `Order` runs in-frame moves on nodes and the autoburn.
`order_orbit_at` plans the raise/lower burn at the right apsis, then
`order_update` circularizes at the target, corrects a missed transfer at the
next pass of the burn point, and trims residual eccentricity (finite burns
overshoot slightly). `raise_lower_node`/`apsis_burn` also back the apsis
drag in the game: grabbing the Pe or Ap marker creates a node at the
opposite apsis whose prograde Δv is solved from the dragged radius, armed on
release. `rcs_nudge` applies small impulses (Shift + arrows). The Orders
menu and popovers expose Go (balanced route, no table), Go and dock,
Rendezvous, Orbit here at..., and automatic docking in range; throttle,
holds and nodes live under Manual.

### 5.8 Pacing: automatic time, interruptions, contracts

The player should decide about cargo, routes and risk, not drive the
clock. While the autopilot flies, `auto_time` runs the clock to the next
burn or event (`autopilot_wait_until`) at up to the chosen step, and burns
cap it as before; "skip to burn" and "skip to arrival" go flat out.
Interruptions (`contracts.odin`: `Notice`) stop the clock for a choice:
arrival (open the market), entering a heat line or pulsar wind (continue or
cut the autopilot), a trader hailing within `HAIL_RANGE` (a radio
conversation, no trading), a contract completing or failing.

Contracts (`econ/jobs.odin`): every station and colony posts a deterministic
daily board of 3–6 jobs, read only on the spot (popover, market window, or
the vendor's "Any work going?"); the Trade menu lists held contracts: deliveries (goods handed over on acceptance),
procurement (bring what the destination is short of) and passengers (a
seeded person with a line on boarding and leaving). Rewards scale with the
goods' value at the destination and the estimated transfer time; deadlines
are 1.8–3× that estimate. The player holds at most three; arriving at the
destination with the goods completes a job; a passed deadline fails it.
Held contracts are saved; boards regenerate from (system, market, day).

### 5.9 Crew and ship systems

The ship carries people, and the people run it (`src/crew`). Each hull has
a number of bunks (`crew.BUNKS`: Courier 2, Hauler 3, Clipper 3, Sleeper 4,
Freighter 5) and each crew member has a trade they were hired for and a
level, 1 to 5, in every ship system. Three systems exist so far, each with
a room on the deck:

| system | room | what the post does |
|---|---|---|
| Engineering | engineering, at the stern | hull management: restores hull under way (1%/h per level) and heads off part of hazard damage (8% per level) |
| Navigation | the bridge | propellant management: exhaust velocity is stretched 5% per level, so every burn spends less |
| Comms | the comms room | talks prices down: 2% per level off what you pay and onto what you are paid, at markets, over the shuttle and with pilots |

Levels come from **hours of duty** on a system (`Member.xp`), not from
anything else. `roster_work` adds the game seconds that passed each frame
to whoever is posted; thresholds sit at 0, 48, 192, 480 and 1080 hours
(`LEVEL_HOURS`), a specialist earns them half again as fast in their own
trade and starts at level 2 there. Cryo is not active time: the transit
loop never calls `roster_work`, so nobody learns anything asleep. The
knob `crew_xp_rate` scales the whole thing.

Staffing (`staff_level`): the best level posted to a system, plus half a
level for every extra hand, capped at 5; an unstaffed system does nothing.
`effects` turns that into the numbers the ship uses each frame:
`Ship.repair_rate`, `Ship.shield` and `Ship.ve_bonus` are written by
`crew_update` (crew_game.odin) and read by `hazards.odin` and `ve_eff`;
the trade edge is applied in `apply_trade`, the shuttle and `pilot_offer`.

Crew are hired at stations (`candidates`: three seeded faces per station
per week, a fee by level) and put ashore there; a refit to a hull with
fewer bunks puts the last aboard ashore. The roster is saved as seeds,
postings and hours (`save.Crew_Save`); names and faces come back from the
seed. The deck plan (`deck.odin`) is data per class: a corridor down the
spine, engineering at the stern, the bridge at the bow, the rest either
side, each room with a door, standing spots and furniture drawn from
`assets/crew/deck.fart`. `walk.odin` moves the crew about it on the wall
clock: the posted stand their room and take breaks in the galley or the
quarters; the off-duty wander. It is a diorama, nothing in it feeds back
into the sim. `ui/ship_view.odin` draws it (View > Inside the ship, `I`,
or Go inside on the ship's card).

---

## 6. Economy

### 6.1 Commodities

Keep the set small and connected. A dependency graph of roughly a dozen:

```
raw:      ore, water, volatiles, hydrogen, biomass, rare_metals
refined:  metals, propellant, oxygen, food, plastics
goods:    machinery, electronics, medicine, luxuries
```

Plus `propellant` is what ships burn, so the flight model and the economy share a
resource.

### 6.2 Markets

```
Market
  host:      Station or Outpost
  stock:     [Commodity]f64
  target:    [Commodity]f64     // desired inventory
  produce:   [Commodity]f64     // per game-day, from host profile
  consume:   [Commodity]f64     // per game-day
  base_price:[Commodity]f64     // system-wide baseline * local modifier
  price(c) = base_price[c] * f(stock[c] / target[c])
```

`f` is a decreasing curve, e.g. `f(x) = clamp(k^(1 - x), 0.25, 4)` so an empty
market pays up to 4× and a flooded one pays down to a quarter. Player and NPC
trades move stock, which moves price. Production and consumption run each tick
and are damped when inputs are missing (a refinery with no ore produces nothing
and its metal price climbs).

Micro tick (active system, each game hour):

```
for each market: stock += (produce - consume) * dt, scaled by input availability
```

### 6.3 Macro model (all systems, each game day)

Same market state, but ships are replaced by flows. For each route
`(market_a, market_b, commodity)` in the system's route table:

```
flow = capacity * ship_count / round_trip_time
stock_a -= flow * dt ; stock_b += flow * dt
```

`round_trip_time` is computed from the same transfer maths the NPC planner uses
(Hohmann time both ways plus dwell), so macro throughput equals what the
spawned micro fleet would carry. That is the calibration that makes the
micro/macro switch invisible.

Between systems: the galaxy graph carries slow inter-system flows on its edges,
proportional to the two systems' price gap and inversely to distance. These are
what make the whole galaxy drift rather than every system being an island.

### 6.4 Trade routes are derived, not authored

Every `N` game days (and on demand for NPCs), compute for each ordered pair of
markets in a system and each commodity:

```
profit_rate = (sell_price_b - buy_price_a) * capacity / (transfer_time + dwell)
             - propellant_cost(Δv)
```

`transfer_time` and `Δv` come from the NPC planner's best candidate for that
pair (§5.3–5.4), so a route that benefits from a flyby is scored with the
flyby. The route table stores that canonical plan; macro flows (§6.3) and
traffic spawning (§5.6) both read it.

Keep the top `k` positive routes as the system's route table. Ship counts on a
route follow the route's share of total profit, with a slow relaxation so
fleets don't teleport between routes. Routes with negative profit drain to zero
ships. The player sees the same table as "known trade routes" in the UI and can
undercut it.

### 6.5 System-level values

Derived, never stored as inputs:

* **Output**: Σ production × base price across markets.
* **Wealth**: Σ stock × price.
* **Demand pressure**: mean of `1 - stock/target` over consumed commodities.
* **Traffic**: Σ ship_count over routes.

These drive the galaxy map colouring, the summary screen, and inter-system
flow weights.

### 6.6 Catch-up after long absences

Macro ticks are cheap but a 30-year cryo trip is ~11k daily ticks per system.
Options, in order of preference:

1. **Batch ticks with a larger dt** when nothing is observed: a 30-day macro dt
   is fine for an unobserved system. The equations are smooth.
2. **Relaxation shortcut**: with no external shocks, each stock converges
   toward an equilibrium `stock*` where production+inflow = consumption+outflow.
   Compute `stock(t) = stock* + (stock(t0) - stock*) * exp(-(t - t0)/τ)` and
   skip the ticks entirely.
3. Run catch-up during the cryo loading animation, a few hundred ticks per
   frame, so the wait is the actual work.

Use 1 for the general case, 2 for systems the player has never visited (no
deltas to preserve), 3 to hide whatever cost remains.

---

## 7. Interstellar travel (cryo)

1. The player raises their orbit to escape the star (hyperbolic conic relative
   to the star, `e > 1`). At the system's outer boundary the "engage cryo"
   action becomes available for any galaxy edge from this system.
2. Travel time = `distance_ly / class.cryo_speed` in years. The mode switches
   to `Cryo`; the ship is a point on the edge. The starter drive is 0.1c;
   better classes go to 0.5c (§5.5).
3. Loading animation: the clock advances in chunks; each chunk runs macro ticks
   for every system (§6.6). Show the years counting up, prices drifting on a
   ticker, that sort of thing. It is real work, not fake progress.
4. Arrival: the cryo drive's run ends with its own deceleration, so the ship
   wakes in a **circular parking orbit** about the star, prograde with the
   system, just outside the outermost planet's orbit and sphere (`sim.arrive`).
   Nothing is on fire; the player plots a course inward at leisure. (An
   earlier design dropped the ship on an inbound hyperbola that had to be
   captured; it killed players who woke up distracted, so it went.)
5. The destination becomes the active system: generate it (or load its deltas),
   spawn NPC traffic from the route table (§5.6), switch its economy to micro.

**Decided: galaxy edge lengths of 1–4 ly.** With 0.1c as the floor, a dense
cluster with edges of 1–4 ly means the starter ship spends 10–40 years per
jump and a 0.5c sleeper spends 2–8. Long enough that a jump is a life decision
and the economy has visibly moved; short enough that a career spans many
jumps. The constants live alongside the scale constants.

**Time is the interstellar cost.** A cheap hull with a slow cryo drive pays in
years, not credits; goods that hold value across decades (rare metals,
machinery) are the interstellar trade, perishables are in-system only. The
faster cryo drive is the upgrade that opens inter-system arbitrage before the
price gap closes.

---

## 8. Engine architecture in Odin

### 8.1 Dependencies

* `vendor:raylib` for window, 2D camera, primitives, text, input, audio. Already
  bundled with the Odin install here, including raygui for debug UI.
* `vendor:microui` if a more immediate-mode debug/inspector UI is wanted.
* `core:math/rand` (PCG/xoshiro), `core:math/linalg`, `core:hash` (xxhash for
  seed derivation), `core:encoding/json` or `core:encoding/cbor` for saves.

No ECS framework. Plain SoA structs and handle arrays are enough and are
idiomatic Odin.

### 8.2 Package layout

```
space-sim/
  src/
    main.odin              // entry, main loop, mode dispatch
    core/                  // seeds, hashing, clock, units, handles
    orbit/                 // Kepler solver, conics, patched-conic transitions, predictor, Lambert
    gen/                   // galaxy, star system, planet typing, station placement
    sim/                   // Ship state machine, integration, NPC planner (Hohmann/Lambert/flyby), flight plans, ship classes
    econ/                  // commodities, markets, routes, micro/macro ticks, catch-up
    galaxy/                // galaxy graph, cryo travel, system activation
    save/                  // delta serialisation
    art/                   // vendored fastart loader + raylib draw_doc + asset library
    render/                // floating-origin camera, body/ship/trajectory drawing
    ui/                    // HUD, maneuver nodes, market screens, galaxy map
  assets/
  docs/
  tests/                   // Odin's `odin test`; orbit and econ are pure and testable
```

Dependency direction: `render`/`ui` depend on everything; `sim` depends on
`orbit` and `econ`; `econ` depends on `orbit` only for transfer-time estimates;
`gen` depends on `core` and `orbit`; `core` depends on nothing.

### 8.3 Data layout

Bodies as SoA, indexed by handle:

```
Bodies
  count:     int
  parent:    []BodyHandle
  mass:      []f64
  orbit:     []Orbit
  pos_cache: [][2]f64        // filled once per frame for the active system
  kind:      []BodyKind
  ...
```

Handles are `distinct u32` indices; never store pointers into dynamic arrays.

Positions of all bodies in the active system are computed once per frame into
`pos_cache` (parents before children, so the array is kept in topological
order at generation time). Ships read from the cache.

### 8.4 Main loop

```
for !should_close:
    real_dt = frame time
    game_dt = real_dt * clock.warp        // capped when player is thrusting

    // 1. advance clock; run economy ticks that fall inside [t, t+game_dt]
    // 2. player ship: integrate (if thrusting) with fixed substeps; check SOI
    // 3. NPC ships: advance plan cursors; fire arrival/dock events
    // 4. NPC decisions for ships that raised events
    // 5. bodies: fill pos_cache at t
    // 6. render with floating origin at the camera target
    // 7. UI
```

Everything in 1–5 is deterministic given the input log, which makes replays and
tests easy.

### 8.5 Game modes

```
Mode: enum { MainMenu, InSystem, GalaxyMap, Docked, CryoTransit }
```

Each mode owns its input handling and draws over the same world state.

The start menu (`ui/title.odin`) is the MainMenu mode: home, New game
(galaxy seed / shape / size via `gen.Galaxy_Params`, starting hull), save
slots (`save.SLOTS` named slots plus the quick slot, cards read by
`save.list_slots`), and Settings. The same screens open over a running game
from System > Main menu; the game is simply not stepped while they show.

Settings (`settings/settings.odin`, persisted to settings.json) cover
graphics (`core.gfx` switches plus star glow and vsync), display (window mode
and size), sound (`audio` volumes) and controls. Every keyboard read goes
through `input.keymap` (`input.pressed/down`), a table from named `Bind`s
to keys, so the Controls tab can rebind anything; Escape and Enter are the
fixed cancel/confirm keys. Menu items show their key from the live map.

Audio (`audio/audio.odin`) streams a looping ambient track and plays
interface sounds (hover, click, open, close, confirm, error); the files are
synthesised by `tools/gen_audio.py`. No device or missing files mean silence,
never an error.

### 8.6 Persistence

Save = `galaxy_seed` + `clock.t` + player ship + player-owned state (money,
cargo, reputation) + for each system ever touched by the macro sim: market
stocks and route table. Market state is small (systems × markets × commodities
floats). Bodies, stations and NPC fleets are never saved; they are regenerated.

### 8.7 Testing

`orbit` and `econ` are pure functions of numbers and are where the bugs will
be. Tests to write early:

* Kepler solve round-trip: elements → state vector → elements.
* Energy conservation on rails over many orbits.
* SOI transition symmetry: enter then immediately leave returns the original
  heliocentric state within tolerance.
* A flyby of a massive body changes heliocentric speed (slingshot sanity).
* Hohmann transfer time and Δv match the analytic formulas.
* Lambert solve reproduces Hohmann when given the Hohmann endpoints and time.
* A flyby plan's exit heliocentric velocity, evaluated through the patched
  conics, matches the planner's `v∞_out` within tolerance.
* Macro flow over a day equals what a spawned micro fleet moves in a day.

---

### 8.8 Art pipeline: fastart (.fart)

All art is authored in the fastart editor (https://github.com/jhuggett/fart) and
shipped as `.fart` files: JSON vector documents of circles, round-capped lines
and pre-triangulated polygons, grouped into *parts* with pivots and anchors,
recoloured through *palette tokens*, and re-posed through named *states*.
The reference Odin loader (`loaders/odin`, package `fastart`) is engine-agnostic:
it gives types, JSON IO, palette resolution (`resolve_palettes`, `color_of`) and
ear-clip triangulation. Rendering is ours, and is about fifty lines of raylib.

Why vector is the right fit here:

* **Infinite zoom.** The camera goes from a docking port to a whole star system.
  Vector art has no mip levels to manage and no pixel snapping; a ship is the
  same file at every zoom.
* **Recolouring is free.** One hull file, many owners: palette tokens map to
  faction, owner, or cargo. Planets by `BodyKind` are one document each with a
  palette per system seed (a rock world's `crust`/`ocean`/`cloud` tokens are
  drawn from the system's economy seed).
* **States are poses, not sprites.** `engine_off`/`engine_on`, `gear_down`,
  `docked`, `cargo_full`. The runtime picks the state; no sprite sheets.
* **Clips are states in time.** A hull's exhaust and attitude jets are keys
  in the document, sampled, blended and layered at runtime (`sample_clip`,
  `blend_poses`, `layer_poses`), so a burn and a turn compose without either
  one being drawn twice.
* **Anchors are gameplay points.** `thrust` anchors are where the flame and
  the exhaust particles come from; `dock` anchors are what rendezvous aligns
  to; `rcs_*` anchors give attitude-thruster puffs. The loader exposes them by
  name, so tuning a ship's look in the editor moves its gameplay points too.

Vendor the two loader files into `src/art/` (they depend only on
`core:encoding/json`). Add on top:

```
art/
  fastart.odin, fastart_io.odin   // vendored reference loader (format 1.2)
  draw.odin                       // draw_doc / draw_poses(doc, pose, transform, overrides)
  library.odin                    // asset table: name -> Doc, hot reload
render/
  ship_anim.odin                  // ship state -> the clips and weights a hull is drawn with
```

`draw_doc` resolves a state name to its part list; `draw_poses` takes a pose
list directly, which is what a sampled clip is. Either way the list is paint
order, each part is placed by `world_xf` (its own `offset`/`rotate`/`scale`
about its pivot, composed with its parent's, mirrored if the pose says so) on
top of the caller's world transform, and the shapes emit raylib calls:
`DrawCircleV` for circles, `DrawLineEx` plus two end circles for capsule
lines, and `DrawTriangle` over the baked `tris` for polys. Colours come from
`color_of` with an optional per-instance override table (owner tint) applied
on top. Unknown tokens render magenta, which is the desired failure mode.

`render/ship_anim.odin` is the only place that knows what a ship's clips mean:
the exhaust clips (`burn_min`, `burn`) blended by throttle and grown out of
`burn_off` as the engine lights, with `turn_left`/`turn_right` layered over
that by how fast the hull is turning. The turn is measured from the heading
between frames rather than from the keys, so a hand turn, a hold and the
autopilot all fire the jets, and NPC traders animate with no extra code.
Animation runs on the wall clock, not the game clock, so time warp does not
strobe the plume.

Coordinate note: the format is **y-down**; raylib's 2D camera is also y-down,
but the sim's orbital maths is y-up. The renderer flips once (scale y by -1 on
the world→screen transform) so sim code never sees the convention. Art is
authored at a canonical size (a ship is ~1 document unit per metre); the draw
transform scales to world units, and the renderer clamps a minimum on-screen
size so ships stay visible as icons when zoomed out to system scale.

Collision shapes in the docs (`collision` list, rest-space) are used only for
docking: a station's approach capsule is the volume a ship must enter at low
relative velocity for docking to succeed.

Hot reload: `library.odin` watches file modification times in debug builds and
reloads changed documents in place, so the editor's `--serve` tablet workflow
works against the running game.

Asset list for the first playable:

* `ships/`: one document per hull class. States: `idle`, `docked`, `burn`,
  and the poses the clips move between (`burn_off`/`min_*`/`burn_*` for the
  exhaust, `turn_l_*`/`turn_r_*` for the jets). Clips: `idle`, `burn_min`,
  `burn`, `turn_left`, `turn_right`. Anchors: `thrust`, `dock`, `rcs_bow`,
  `rcs_stern`, each with the direction it points.
* `bodies/`: one document per `BodyKind` plus `star`, `moon`, `belt_chunk`.
  Tokens sized so a system palette can recolour all of them.
* `stations/`: `hub`, `refinery`, `depot`, `shipyard`. Anchor `dock_0..n`.
* `palettes/`: `base.fart` shared tokens; per-faction palettes layered on top.
* `ui/`: maneuver node glyphs, SOI ring, marker icons.

---

## 9. Build phases

Each phase ends with something visible and testable.

1. **Window and clock.** Raylib window, 2D camera with pan/zoom, floating
   origin, game clock with warp. Vendor the fastart loader, write `draw_doc`,
   draw a star and a ship from `.fart` files with hot reload.
2. **System generation and rails.** Seeded system with typed planets, moons,
   belts and stations. Kepler solver. Warp to 10,000× and watch it turn.
   Orbit tests pass.
3. **Player ship.** Spawn in orbit. Throttle and rotate. Integration under
   thrust; back to rails when coasting. SOI transitions. Trajectory predictor
   drawn correctly through a moving planet's SOI. First slingshot.
4. **Maneuver nodes and Δv.** Plan burns, predictor through nodes, drag to
   retime, warp-to-node, autoburn with replanning.
5. **Autopilot, part one.** Hohmann and Lambert planners with escape and
   capture legs; the four objectives (§4.6) as a candidate table; plans load
   as nodes. Pulled ahead of the economy because the player planner and the
   NPC planner are the same code.
6. **Stations and docking.** Rendezvous, dock, undock. "Never idle" rule
   enforced by the state machine.
7. **Micro economy.** Markets, production/consumption, buy/sell UI, prices
   responding to trades.
8. **NPC ships.** Route derivation, fleets on the phase-5 planner that trade
   and replan. Watch prices settle.
9. **Flybys.** Gravity-assist search added to the shared planner; the player
   gets it in the autopilot, NPCs pick it when cheaper. Routes rescored.
10. **Ship classes and shipyards.** Class table, starter Courier, shipyard
    stock built from market inputs, buy and trade-in, NPC fleets mixed by class.
11. **Galaxy and macro.** Galaxy graph, summaries, macro ticks, calibration
    test against micro. Galaxy map screen.
12. **Cryo.** Escape, transit with catch-up at the class's cryo speed, arrival
    on a hyperbolic approach, capture. Traffic spawning from route table.
13. **Persistence and polish.** Saves, audio, feedback, tuning.

---

## 10. Decisions

All design questions are settled (see the sections for detail):

* **Game scale**, self-consistent constants in one file (§3).
* **Starter cryo speed 0.1c**, with faster cryo drives as a purchasable axis
  alongside cargo hold and in-system drive (§5.5, §7).
* **NPCs slingshot**, via a Lambert-based gravity-assist search that also
  rescores trade routes (§5.4).
* **Galaxy edges 1–4 ly**, giving 10–40 years per starter jump (§7).
* **Autopilot objectives: fuel, time, balanced, simplest** (§4.6). No
  distance objective.
* **NPC time value is derived, with a knob.** The planner compares candidate
  plans by `Δv · propellant_price + T · time_value`. `time_value` is derived
  per trip from the route's price-gap closing rate times cargo capacity, so
  urgent cargo flies fast and bulk cargo drifts, and multiplied by a global
  `k_time` factor (§5.4) that is turned during playtesting.

Later, not in scope for the first playable:

**Combat, factions, missions.** Not in scope here. The economy and NPC planner
give a foundation for cargo missions and piracy without changes to the flight
model.

**Aerobraking at atmospheric worlds.** Natural extension of capture and
free Δv; makes atmospheric planets more valuable as arrival points.

---

## 11. Tuning knobs

Everything below is a number, not a design question. All live in
`core/tuning.odin` and are shown as sliders in the debug panel so they can be
turned while the sim runs.

| Knob                    | Default (placeholder) | What it changes                                              |
|-------------------------|-----------------------|--------------------------------------------------------------|
| `k_time`                | 1.0                   | How hard NPCs burn to save a day; how often flybys win        |
| `price_curve_k`         | 4.0                   | Max price swing between empty and flooded markets (§6.2)     |
| `route_relax_days`      | 30                    | How fast fleets migrate between routes (§6.4)                |
| `route_refresh_days`    | 7                     | How often the route table is recomputed                      |
| `macro_dt_unobserved`   | 30 days               | Batch step for unobserved systems (§6.6)                     |
| `edge_ly_min/max`       | 1 / 4                 | Galaxy edge lengths (§7)                                     |
| `flyby_grid_n`          | 32                    | Samples per axis in the gravity-assist search (§5.4)         |
| `flyby_margin`          | 1.5 × radius          | Minimum periapsis in a flyby                                 |
| `warp_max_thrusting`    | 4                     | Warp cap while the player is integrating (§3)                |
