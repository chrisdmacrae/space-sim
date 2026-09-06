package save

// Persistence (docs/DESIGN.md §8.6): the galaxy seed, the clock, the player,
// and per-market deltas for every system the macro has touched. Bodies,
// stations and NPC fleets are regenerated, never saved.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import econ "sim:econ"
import gen "sim:gen"
import orbit "sim:orbit"
import sim "sim:sim"
import crew "sim:crew"

Market_Save :: struct {
	stock:    [len(econ.Commodity)]f64,
	ships:    [econ.NUM_CLASSES]int,
	progress: [econ.NUM_CLASSES]f64,
}

System_Save :: struct {
	index:   int,
	last_t:  f64,
	markets: []Market_Save,
}

Ship_Save :: struct {
	class:      econ.Class_Id,
	primary:    int,
	mode:       sim.Ship_Mode,
	orbit:      orbit.Orbit,
	pos, vel:   [2]f64,
	heading:    f64,
	propellant: f64,
	cargo:      sim.Cargo,
	dock:       int,
	hull:       f64,
}

// One crew member: who they are and what they have learned. The face and
// the name come back from the seed; the posting and the hours are the delta.
Crew_Save :: struct {
	seed:        u64,
	specialty:   crew.System,
	post:        crew.Post,
	xp:          [len(crew.System)]f64,
}

Save :: struct {
	version: int,
	seed:    u64,
	params:  gen.Galaxy_Params, // zero systems means the default size (older saves)
	t:       f64,
	current: int,
	credits: f64,
	ship:    Ship_Save,
	systems: []System_Save,
	contracts: []econ.Job, // jobs the player holds
	crew:      []Crew_Save, // empty in older saves: the starting crew is rolled again
	// Slot card details, so a listing does not have to rebuild anything.
	system_name: string,
	saved_at:    i64, // unix seconds
}

VERSION :: 1

// Slots: 1..SLOTS are the named slots, 0 is the quick slot.
SLOTS :: 5

slot_path :: proc(slot: int, allocator := context.temp_allocator) -> string {
	if slot <= 0 do return "saves/quick.json"
	return fmt.aprintf("saves/slot%d.json", slot, allocator = allocator)
}

Slot_Info :: struct {
	exists:      bool,
	system_name: string,
	ship:        string,
	credits:     f64,
	t:           f64,
	saved_at:    i64,
	version_ok:  bool,
}

// Read the card details of every slot (quick first).
list_slots :: proc(allocator := context.temp_allocator) -> (out: [SLOTS + 1]Slot_Info) {
	for slot in 0 ..= SLOTS {
		path := slot_path(slot)
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil do continue
		sv: Save
		if json.unmarshal(data, &sv, allocator = context.temp_allocator) != nil do continue
		out[slot] = Slot_Info {
			exists = true, system_name = strings.clone(sv.system_name, allocator), ship = econ.CLASS_NAMES[sv.ship.class],
			credits = sv.credits, t = sv.t, saved_at = sv.saved_at, version_ok = sv.version == VERSION,
		}
	}
	return
}

capture :: proc(seed: u64, t: f64, current: int, credits: f64, s: ^sim.Ship, ge: ^econ.Galaxy_Econ, params: gen.Galaxy_Params = {}, system_name := "", contracts: []econ.Job = nil, roster: ^crew.Roster = nil, allocator := context.temp_allocator) -> Save {
	sv := Save{version = VERSION, seed = seed, params = params, t = t, current = current, credits = credits, system_name = system_name, saved_at = time.time_to_unix(time.now()), contracts = contracts}
	sv.ship = Ship_Save {
		class = s.class, primary = int(s.primary), mode = s.docked_ship ? .On_Rails : s.mode, orbit = s.orbit, pos = s.pos, vel = s.vel,
		heading = s.heading, propellant = s.propellant, cargo = s.cargo, dock = s.dock, hull = s.hull,
	}
	systems := make([dynamic]System_Save, allocator)
	for &se, i in ge.systems {
		if !se.built do continue
		ms := make([]Market_Save, len(se.econ.markets), allocator)
		for &m, k in se.econ.markets {
			for c in econ.Commodity do ms[k].stock[int(c)] = m.stock[c]
			for c in econ.Class_Id {
				ms[k].ships[int(c)] = m.ships[c]
				ms[k].progress[int(c)] = m.progress[c]
			}
		}
		append(&systems, System_Save{index = i, last_t = se.last_t, markets = ms})
	}
	sv.systems = systems[:]
	if roster != nil {
		cs := make([]Crew_Save, len(roster.members), allocator)
		for &m, i in roster.members {
			cs[i] = Crew_Save{seed = m.seed, specialty = m.specialty, post = m.post}
			for sys in crew.System do cs[i].xp[int(sys)] = m.xp[sys]
		}
		sv.crew = cs
	}
	return sv
}

// Bring the saved crew aboard in place of the rolled one. Older saves have
// none; then the starting crew stays.
apply_crew :: proc(sv: Save, roster: ^crew.Roster) {
	if len(sv.crew) == 0 do return
	crew.roster_clear(roster)
	for cs in sv.crew {
		m := crew.make_member(cs.seed, cs.specialty)
		m.post = cs.post
		for sys in crew.System do m.xp[sys] = cs.xp[int(sys)]
		append(&roster.members, m)
	}
}

write :: proc(path: string, sv: Save) -> bool {
	data, err := json.marshal(sv, {pretty = true}, context.temp_allocator)
	if err != nil do return false
	return os.write_entire_file(path, data) == nil
}

read :: proc(path: string, allocator := context.temp_allocator) -> (sv: Save, ok: bool) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return {}, false
	if json.unmarshal(data, &sv, allocator = allocator) != nil do return {}, false
	return sv, sv.version == VERSION
}

// Apply market deltas onto a galaxy economy whose systems are (re)built on demand.
apply_markets :: proc(sv: Save, ge: ^econ.Galaxy_Econ) {
	for ss in sv.systems {
		if ss.index < 0 || ss.index >= len(ge.systems) do continue
		se := econ.ensure(ge, ss.index, sv.t)
		se.last_t = ss.last_t
		se.econ.last_tick = ss.last_t
		for ms, k in ss.markets {
			if k >= len(se.econ.markets) do break
			m := &se.econ.markets[k]
			for c in econ.Commodity do m.stock[c] = ms.stock[int(c)]
			for c in econ.Class_Id {
				m.ships[c] = ms.ships[int(c)]
				m.progress[c] = ms.progress[int(c)]
			}
		}
	}
}

apply_ship :: proc(sv: Save, sys: ^gen.System, s: ^sim.Ship, t: f64) {
	sim.refit(s, sv.ship.class)
	s.primary = gen.Body_Handle(sv.ship.primary)
	s.mode = sv.ship.mode
	s.orbit = sv.ship.orbit
	s.pos, s.vel = sv.ship.pos, sv.ship.vel
	s.heading = sv.ship.heading
	s.propellant = sv.ship.propellant
	s.cargo = sv.ship.cargo
	s.dock = sv.ship.dock
	s.hull = sv.ship.hull > 0 ? sv.ship.hull : 1 // older saves had no hull
	s.name = econ.CLASS_NAMES[s.class]
	if s.mode == .Thrusting do s.mode = .On_Rails
	if s.mode == .On_Rails do sim.repredict(sys, s, t)
	if s.mode == .Docked && s.dock < len(sys.stations) do sim.dock(sys, s, s.dock, t)
}
