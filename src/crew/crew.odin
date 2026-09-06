package crew

// The people aboard the player's ship (docs/DESIGN.md §5.9). Each crew
// member has a trade they were hired for and a level in every ship system,
// earned by standing a post on it. Levels only grow during active time: a
// crew asleep in cryo learns nothing. Whoever is posted to a system runs it,
// and how well is a function of their level there.
//
// The three systems so far:
//   Engineering  hull management: repairs wear and softens hazard damage
//   Navigation   propellant management: every burn spends less
//   Comms        talks prices down at markets and with pilots

import core "sim:core"
import econ "sim:econ"
import gen "sim:gen"
import people "sim:people"

System :: enum u8 {
	Engineering,
	Navigation,
	Comms,
}

SYSTEM_NAMES := [System]string{.Engineering = "Engineering", .Navigation = "Navigation", .Comms = "Comms"}
SYSTEM_TRADES := [System]string{.Engineering = "engineer", .Navigation = "navigator", .Comms = "comms officer"}
SYSTEM_BLURBS := [System]string {
	.Engineering = "keeps the hull whole: repairs wear under way and softens heat, wind and dust",
	.Navigation  = "plans burns tightly: every unit of propellant goes further",
	.Comms       = "talks prices down at markets and over the radio",
}

// Where a crew member stands: a system, or nowhere.
Post :: enum u8 {
	Off_Duty,
	Engineering,
	Navigation,
	Comms,
}

POST_NAMES := [Post]string{.Off_Duty = "Off duty", .Engineering = "Engineering", .Navigation = "Navigation", .Comms = "Comms"}

post_of :: proc(s: System) -> Post { return Post(int(s) + 1) }

system_of :: proc(p: Post) -> (System, bool) {
	if p == .Off_Duty do return {}, false
	return System(int(p) - 1), true
}

MAX_LEVEL :: 5

// Hours of duty on a system to hold each level (index = level - 1). A
// specialist earns them half again as fast in their own trade.
LEVEL_HOURS := [MAX_LEVEL]f64{0, 48, 192, 480, 1080}
SPECIALTY_RATE :: 1.5

Member :: struct {
	seed:        u64,
	name:        string, // owned by the roster's allocator
	personality: people.Personality,
	specialty:   System,
	xp:          [System]f64, // hours of duty stood on each system
	post:        Post,
	walker:      Walker, // where they are on the deck; visual only, never saved
}

Level_Up :: struct {
	member: int,
	system: System,
	level:  int,
}

Roster :: struct {
	members:  [dynamic]Member,
	levelled: [dynamic]Level_Up, // since the game last drained them
	rng:      core.Rng,          // for the deck sim
}

// Bunks per hull: how many crew a class carries.
BUNKS := [econ.Class_Id]int{.Courier = 2, .Hauler = 3, .Clipper = 3, .Freighter = 5, .Sleeper = 4}

level_for :: proc(xp: f64) -> int {
	lvl := 1
	for h, i in LEVEL_HOURS do if xp >= h do lvl = i + 1
	return lvl
}

level :: proc(m: ^Member, s: System) -> int { return level_for(m.xp[s]) }

// Progress toward the next level, 0..1; 1 at the top.
progress :: proc(m: ^Member, s: System) -> f64 {
	l := level(m, s)
	if l >= MAX_LEVEL do return 1
	lo := LEVEL_HOURS[l - 1]
	hi := LEVEL_HOURS[l]
	return clamp((m.xp[s] - lo) / (hi - lo), 0, 1)
}

// Hours of duty still to stand for the next level, 0 at the top.
hours_to_next :: proc(m: ^Member, s: System) -> f64 {
	l := level(m, s)
	if l >= MAX_LEVEL do return 0
	rate := m.specialty == s ? SPECIALTY_RATE : 1
	return max(LEVEL_HOURS[l] - m.xp[s], 0) / rate
}

make_member :: proc(seed: u64, specialty: System, allocator := context.allocator) -> (m: Member) {
	r := core.rng_make(seed)
	m.seed = seed
	m.specialty = specialty
	m.personality = people.Personality(core.rng_int(&r, 0, len(people.Personality)))
	m.xp[specialty] = LEVEL_HOURS[1] // a specialist knows their trade: level 2 in it
	context.allocator = allocator
	m.name = gen.person_name(&r)
	return
}

member_destroy :: proc(m: ^Member) {
	delete(m.name)
}

// The starting crew for a galaxy: an engineer and a navigator first, a
// comms officer third, then whatever the seed rolls, each standing their
// own trade. `bunks` is how many the starting hull carries.
roster_init :: proc(ro: ^Roster, galaxy_seed: u64, bunks: int) {
	roster_clear(ro)
	ro.rng = core.rng_make(core.sub_seed(galaxy_seed, "crew_deck"))
	order := [?]System{.Engineering, .Navigation, .Comms}
	for i in 0 ..< max(bunks, 0) {
		seed := core.sub_seed(galaxy_seed, "crew", i)
		spec: System
		if i < len(order) {
			spec = order[i]
		} else {
			r := core.rng_make(core.sub_seed(seed, "trade"))
			spec = System(core.rng_int(&r, 0, len(System)))
		}
		m := make_member(seed, spec)
		m.post = post_of(spec)
		append(&ro.members, m)
	}
}

roster_clear :: proc(ro: ^Roster) {
	for &m in ro.members do member_destroy(&m)
	clear(&ro.members)
	clear(&ro.levelled)
}

roster_destroy :: proc(ro: ^Roster) {
	roster_clear(ro)
	delete(ro.members)
	delete(ro.levelled)
}

// Stand the posts for `game_dt` seconds of active time. Cryo is not active
// time: the caller does not call this while the crew sleep. Level-ups are
// queued in `levelled` for the game to announce.
roster_work :: proc(ro: ^Roster, game_dt: f64) {
	if game_dt <= 0 do return
	hours := game_dt / core.SECONDS_PER_HOUR * f64(core.tuning.crew_xp_rate)
	top := LEVEL_HOURS[MAX_LEVEL - 1]
	for &m, i in ro.members {
		s, on := system_of(m.post)
		if !on do continue
		before := level(&m, s)
		m.xp[s] = min(m.xp[s] + hours * (m.specialty == s ? SPECIALTY_RATE : 1), top)
		after := level(&m, s)
		if after > before do append(&ro.levelled, Level_Up{i, s, after})
	}
}

// Who stands a system and how well: the best level posted to it, plus half
// a level for every extra hand, capped at the top. Zero when nobody does.
staff_level :: proc(ro: ^Roster, s: System) -> f64 {
	best := 0
	hands := 0
	for &m in ro.members {
		if ms, on := system_of(m.post); on && ms == s {
			hands += 1
			best = max(best, level(&m, s))
		}
	}
	if hands == 0 do return 0
	return min(f64(best) + 0.5 * f64(hands - 1), MAX_LEVEL)
}

// What the crew do for the ship right now.
Effects :: struct {
	level:           [System]f64, // effective level per system, 0 when unstaffed
	repair_per_hour: f64,         // hull fraction restored per hour under way
	shield:          f64,         // fraction of hazard damage the engineers head off
	ve_bonus:        f64,         // multiplier on exhaust velocity (1 = nominal)
	trade_edge:      f64,         // fraction off what you pay and onto what you are paid
}

REPAIR_PER_LEVEL :: 0.01 // hull per hour per level: a level-5 engineer rebuilds a hull in 20 hours
SHIELD_PER_LEVEL :: 0.08 // 40% of hazard damage headed off at level 5
VE_PER_LEVEL     :: 0.05 // 25% more Δv from the same tank at level 5
EDGE_PER_LEVEL   :: 0.02 // 10% better prices at level 5

effects :: proc(ro: ^Roster) -> (e: Effects) {
	for s in System do e.level[s] = staff_level(ro, s)
	e.repair_per_hour = REPAIR_PER_LEVEL * e.level[.Engineering]
	e.shield = SHIELD_PER_LEVEL * e.level[.Engineering]
	e.ve_bonus = 1 + VE_PER_LEVEL * e.level[.Navigation]
	e.trade_edge = EDGE_PER_LEVEL * e.level[.Comms]
	return
}

staffed :: proc(e: Effects, s: System) -> bool { return e.level[s] > 0 }

// ---- hiring

Candidate :: struct {
	seed:        u64,
	name:        string, // temp-allocated by `candidates`
	personality: people.Personality,
	specialty:   System,
	level:       int, // in their trade
	fee:         f64,
}

HIRE_FEE_BASE  :: 300.0
HIRE_FEE_LEVEL :: 450.0
CANDIDATES_PER_STATION :: 3

hire_fee :: proc(level: int) -> f64 {
	return HIRE_FEE_BASE + HIRE_FEE_LEVEL * f64(max(level - 1, 0))
}

// Who is looking for a berth at a station this week. Seeded, so the same
// faces wait through the week; anyone already aboard is left out.
candidates :: proc(ro: ^Roster, system_seed: u64, station: int, t: f64, allocator := context.temp_allocator) -> []Candidate {
	week := int(t / (7 * core.SECONDS_PER_DAY))
	out := make([dynamic]Candidate, allocator)
	for k in 0 ..< CANDIDATES_PER_STATION {
		seed := core.sub_seed(core.sub_seed(system_seed, "hire", station), "week", week * CANDIDATES_PER_STATION + k)
		aboard := false
		for &m in ro.members do if m.seed == seed do aboard = true
		if aboard do continue
		r := core.rng_make(core.sub_seed(seed, "cv"))
		spec := System(core.rng_int(&r, 0, len(System)))
		lvl := 1 + core.rng_int(&r, 0, 3) // 1..3
		m := make_member(seed, spec, allocator)
		append(&out, Candidate{seed = seed, name = m.name, personality = m.personality, specialty = spec, level = lvl, fee = hire_fee(lvl)})
	}
	return out[:]
}

// Take a candidate aboard, off duty until posted. False when the bunks are full.
hire :: proc(ro: ^Roster, c: Candidate, bunks: int) -> bool {
	if len(ro.members) >= bunks do return false
	m := make_member(c.seed, c.specialty)
	m.xp[c.specialty] = LEVEL_HOURS[clamp(c.level, 1, MAX_LEVEL) - 1]
	m.post = .Off_Duty
	append(&ro.members, m)
	return true
}

dismiss :: proc(ro: ^Roster, i: int) {
	if i < 0 || i >= len(ro.members) do return
	member_destroy(&ro.members[i])
	ordered_remove(&ro.members, i)
}

// A smaller hull has fewer bunks: the last aboard are the first ashore.
// Returns how many were put off.
trim :: proc(ro: ^Roster, bunks: int) -> (dropped: int) {
	for len(ro.members) > max(bunks, 0) {
		dismiss(ro, len(ro.members) - 1)
		dropped += 1
	}
	return
}

// The system a room serves, if any (deck.odin decides the rooms).
post_for_room :: proc(kind: Room_Kind) -> (Post, bool) {
	#partial switch kind {
	case .Engineering: return .Engineering, true
	case .Bridge:      return .Navigation, true
	case .Comms:       return .Comms, true
	case .Quarters, .Galley: return .Off_Duty, true
	}
	return .Off_Duty, false
}
