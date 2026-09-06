package sim

// Skimming a nebula (docs/DESIGN.md §2.6). The ship spreads its scoop and
// waits: every cycle it strains a cargo's worth of gas out of the cloud and
// tops the tank from the hydrogen. Like the colony shuttle, the timer only
// advances while the ship is actually where the work is — drift out of the
// gas and the cycle stops where it stands.
//
// There is no separate rig to buy. Skimming is slow, it wears the hull
// (hazards.odin), and it is the only way to refuel with no station in reach.

import econ "sim:econ"
import gen "sim:gen"
import core "sim:core"

SKIM_PROPELLANT :: 1.6 // tank units per cycle at full density

// One pass through the scoop. A knob (core/tuning.odin) rather than a
// constant: how long the wait feels is the whole shape of the mechanic.
skim_cycle :: proc() -> f64 {
	return f64(core.tuning.skim_cycle_hours) * core.SECONDS_PER_HOUR
}

Skim_Phase :: enum u8 {
	Idle,
	Running,
	Full, // the hold has no room for another pass
}

Skim :: struct {
	nebula:   int, // index into sys.nebulae, -1 when not skimming
	phase:    Skim_Phase,
	elapsed:  f64,
	density:  f64, // where the ship is sitting right now, 0 when outside
	cycles:   int,
	gathered: econ.Rates, // running total, for the panel
	fuelled:  f64,
	stalled:  string, // why nothing is happening, "" when it is
}

skim_stop :: proc(sk: ^Skim) {
	sk^ = Skim{nebula = -1}
}

skim_active :: proc(sk: ^Skim) -> bool {
	return sk.nebula >= 0 && sk.phase != .Idle
}

// Start skimming whichever cloud the ship is in. Fails with a reason when
// there is nothing to skim or the ship is in no state to do it.
skim_start :: proc(sys: ^gen.System, s: ^Ship, sk: ^Skim, t: f64) -> (ok: bool, reason: string) {
	if is_dead(s) do return false, "the ship is wrecked"
	if s.mode == .Docked do return false, "undock first"
	idx, density := skim_here(sys, s)
	if idx < 0 do return false, "no gas thick enough to skim here"
	if cargo_free(s) <= 0 && s.propellant >= s.stats.propellant_cap do return false, "the hold and the tank are both full"
	sk^ = Skim{nebula = idx, phase = .Running, density = density}
	return true, ""
}

// The cloud the ship is sitting in and how thick it is, or -1.
skim_here :: proc(sys: ^gen.System, s: ^Ship) -> (int, f64) {
	if s.mode != .On_Rails && s.mode != .Thrusting do return -1, 0
	return gen.nebula_at(sys, sys.pos[s.primary] + s.pos)
}

// Advance the scoop. Time only counts while the ship is still in the gas.
skim_step :: proc(sys: ^gen.System, s: ^Ship, sk: ^Skim, dt: f64) {
	if sk.nebula < 0 || sk.phase == .Idle do return
	if sk.nebula >= len(sys.nebulae) { skim_stop(sk); return }
	idx, density := skim_here(sys, s)
	sk.density = idx == sk.nebula ? density : 0
	if sk.density <= 0 {
		sk.stalled = s.mode == .Docked ? "docked" : "out of the cloud"
		return
	}
	room := cargo_free(s)
	tank := s.stats.propellant_cap - s.propellant
	if room <= 0 && tank <= 0.001 {
		sk.phase = .Full
		sk.stalled = "hold and tank full"
		return
	}
	sk.phase = .Running
	sk.stalled = ""
	cycle := skim_cycle()
	sk.elapsed += dt
	if sk.elapsed < cycle do return
	sk.elapsed -= cycle
	skim_collect(sys, s, sk)
}

// One cycle's haul: the kind's mix scaled by how thick the gas is, poured
// into whatever hold space there is, then the tank from the hydrogen.
@(private = "file")
skim_collect :: proc(sys: ^gen.System, s: ^Ship, sk: ^Skim) {
	n := sys.nebulae[sk.nebula]
	mix := econ.nebula_yield(n.kind)
	room := cargo_free(s)
	// Everything shares the hold in proportion when it will not all fit.
	want := 0.0
	for c in econ.Commodity do want += mix[c] * sk.density
	if want > 0 && room > 0 {
		scale := min(1, room / want)
		for c in econ.Commodity {
			take := mix[c] * sk.density * scale
			if take <= 0 do continue
			s.cargo[int(c)] += take
			sk.gathered[c] += take
		}
	}
	// The tank takes raw hydrogen straight from the stream, hold or no hold.
	if fuel := min(SKIM_PROPELLANT * sk.density, s.stats.propellant_cap - s.propellant); fuel > 0 {
		s.propellant += fuel
		sk.fuelled += fuel
	}
	sk.cycles += 1
}

// Fraction of the way through the current cycle, for the panel.
skim_progress :: proc(sk: ^Skim) -> f64 {
	return clamp(sk.elapsed / skim_cycle(), 0, 1)
}

skim_status :: proc(sk: ^Skim) -> string {
	if sk.nebula < 0 || sk.phase == .Idle do return "idle"
	if sk.stalled != "" do return sk.stalled
	switch sk.phase {
	case .Running: return "scooping"
	case .Full:    return "hold and tank full"
	case .Idle:
	}
	return "idle"
}
