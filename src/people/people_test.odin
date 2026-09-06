package people

import "core:testing"
import core "sim:core"

@(test)
dialog_database_covers_every_category_and_mood :: proc(t: ^testing.T) {
	d, ok := dialog_load()
	testing.expect(t, ok, "assets/dialog/lines.json loads")
	if !ok do return
	defer dialog_destroy(&d)
	testing.expectf(t, len(d.lines) >= 250, "hundreds of lines (%d)", len(d.lines))
	cats := [?]string{"greeting", "smalltalk", "rumour", "cargo", "market", "dock_accept", "dock_refuse", "trade_open", "haggle_accept", "haggle_refuse", "deal_done", "no_deal", "farewell"}
	for c in cats do testing.expectf(t, count(&d, c) >= 8, "category %s has lines (%d)", c, count(&d, c))
	// Every personality gets a line of every category that applies to it.
	r := core.rng_make(1)
	for role in Role {
		for mood in Personality {
			p := Person{seed = 7, personality = mood, role = role}
			for c in cats {
				if role == .Vendor && (c == "cargo" || c == "dock_accept" || c == "dock_refuse" || c == "trade_open" || c == "haggle_accept" || c == "haggle_refuse" || c == "deal_done" || c == "no_deal") do continue
				if role == .Pilot && c == "market" do continue
				l := pick_line(&d, c, p, &r)
				testing.expectf(t, l != "", "%v %v has a %s line", role, mood, c)
			}
		}
	}
}

@(test)
slots_fill_and_people_are_deterministic :: proc(t: ^testing.T) {
	s := fill("Hi {name}, {commodity} is {price} at {dest}. {missing}", {{"name", "Ada"}, {"commodity", "ore"}, {"price", "12.5"}, {"dest", "Port"}})
	testing.expectf(t, s == "Hi Ada, ore is 12.5 at Port. {missing}", "filled: %s", s)
	a := pilot_for(99)
	b := pilot_for(99)
	defer person_destroy(&a)
	defer person_destroy(&b)
	testing.expect(t, a.name == b.name && a.personality == b.personality, "same seed, same person")
	testing.expect(t, len(a.name) > 3, "has a name")
	// Refusal is stable within a day and depends on personality.
	cheerful := Person{seed = 5, personality = .Cheerful, role = .Pilot}
	testing.expect(t, !dock_refuses(cheerful, 0) && !dock_refuses(cheerful, 1e6), "cheerful pilots never refuse")
	nervous := Person{seed = 5, personality = .Nervous, role = .Pilot}
	refused := 0
	for day in 0 ..< 100 do if dock_refuses(nervous, f64(day) * core.SECONDS_PER_DAY) do refused += 1
	testing.expectf(t, refused > 40 && refused < 95, "nervous pilots refuse most days (%d/100)", refused)
	testing.expect(t, dock_refuses(nervous, 3600) == dock_refuses(nervous, 7200), "the answer holds within a day")
}
