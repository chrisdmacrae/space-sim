package people

// The people behind ships and stations: a seeded name, a personality and a
// face, and the conversation database they draw their lines from.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import core "sim:core"
import gen "sim:gen"

Personality :: enum u8 {
	Gruff,
	Cheerful,
	Nervous,
	Formal,
	Sly,
}

PERSONALITY_NAMES :: [Personality]string{.Gruff = "gruff", .Cheerful = "cheerful", .Nervous = "nervous", .Formal = "formal", .Sly = "sly"}

Role :: enum u8 {
	Pilot,
	Vendor,
}

Person :: struct {
	seed:        u64,
	name:        string, // owned by the caller's allocator
	personality: Personality,
	role:        Role,
}

// The pilot of a trader, from the trader's seed.
pilot_for :: proc(npc_seed: u64, allocator := context.allocator) -> Person {
	return make_person(core.sub_seed(npc_seed, "pilot"), .Pilot, allocator)
}

// The vendor of a station, from the system seed and station index.
vendor_for :: proc(system_seed: u64, station: int, allocator := context.allocator) -> Person {
	return make_person(core.sub_seed(system_seed, "vendor", station), .Vendor, allocator)
}

make_person :: proc(seed: u64, role: Role, allocator := context.allocator) -> (p: Person) {
	r := core.rng_make(seed)
	p.seed = seed
	p.role = role
	p.personality = Personality(core.rng_int(&r, 0, len(Personality)))
	context.allocator = allocator
	p.name = gen.person_name(&r)
	return
}

person_destroy :: proc(p: ^Person) {
	delete(p.name)
}

// Does this pilot let the player dock today? Decided once per game day so
// the answer holds while the player is manoeuvring.
dock_refuses :: proc(p: Person, t: f64) -> bool {
	chance: f64
	switch p.personality {
	case .Gruff:    chance = 0.35
	case .Cheerful: chance = 0.0
	case .Nervous:  chance = 0.7
	case .Formal:   chance = 0.1
	case .Sly:      chance = 0.2
	}
	day := int(t / core.SECONDS_PER_DAY)
	r := core.rng_make(core.sub_seed(p.seed, "dock", day))
	return core.rng_chance(&r, chance)
}

// Does the pilot take a lower price when asked? One roll per conversation.
haggle_accepts :: proc(p: Person, conversation: u64) -> bool {
	chance: f64
	switch p.personality {
	case .Gruff:    chance = 0.35
	case .Cheerful: chance = 0.7
	case .Nervous:  chance = 0.6
	case .Formal:   chance = 0.5
	case .Sly:      chance = 0.3
	}
	r := core.rng_make(core.sub_seed(p.seed, "haggle", int(conversation)))
	return core.rng_chance(&r, chance)
}

// ---- dialog database

Line :: struct {
	cat:  string,
	who:  string, // "pilot", "vendor" or "any"
	mood: string, // a personality name or "any"
	text: string,
}

Dialog :: struct {
	lines: []Line,
	data:  []u8, // backing bytes for the strings
}

DIALOG_PATH :: "assets/dialog/lines.json"

dialog_load :: proc(path := DIALOG_PATH) -> (d: Dialog, ok: bool) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil do return {}, false
	d.data = data
	parsed: struct { lines: []Line }
	if json.unmarshal(data, &parsed) != nil do return {}, false
	d.lines = parsed.lines
	return d, true
}

dialog_destroy :: proc(d: ^Dialog) {
	delete(d.lines)
	delete(d.data)
}

// A line of `cat` for this person. Personality-specific lines win when any
// exist; otherwise any-mood lines of the right role, then any role.
// Returns the raw template; fill it with `fill`.
pick_line :: proc(d: ^Dialog, cat: string, p: Person, r: ^core.Rng) -> string {
	role := p.role == .Pilot ? "pilot" : "vendor"
	names := PERSONALITY_NAMES
	mood := names[p.personality]
	best := make([dynamic]string, context.temp_allocator)
	score_best := -1
	for l in d.lines {
		if l.cat != cat do continue
		if l.who != "any" && l.who != role do continue
		if l.mood != "any" && l.mood != mood do continue
		score := (l.mood == mood ? 2 : 0) + (l.who == role ? 1 : 0)
		if score > score_best {
			score_best = score
			clear(&best)
		}
		if score == score_best do append(&best, l.text)
	}
	if len(best) == 0 do return ""
	return best[core.rng_int(r, 0, len(best))]
}

// Replace {slot} tokens from a key/value list.
fill :: proc(template: string, slots: []Slot, allocator := context.temp_allocator) -> string {
	out := strings.builder_make(allocator)
	i := 0
	for i < len(template) {
		if template[i] == '{' {
			if j := strings.index_byte(template[i:], '}'); j > 0 {
				key := template[i + 1:i + j]
				found := false
				for s in slots do if s.key == key {
					strings.write_string(&out, s.value)
					found = true
					break
				}
				if !found do strings.write_string(&out, template[i:i + j + 1])
				i += j + 1
				continue
			}
		}
		strings.write_byte(&out, template[i])
		i += 1
	}
	return strings.to_string(out)
}

Slot :: struct {
	key, value: string,
}

// Count of lines in a category, for tests and tooling.
count :: proc(d: ^Dialog, cat: string) -> (n: int) {
	for l in d.lines do if l.cat == cat do n += 1
	return
}

_ :: fmt
