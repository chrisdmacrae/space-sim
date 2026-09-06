package gen

import "core:fmt"
import "core:strings"
import core "sim:core"

@(private = "file")
ONSETS := [?]string{"k", "r", "v", "t", "s", "m", "n", "l", "d", "h", "th", "br", "kr", "z", "ph", "gr", "sh", "j", "kh", "al"}
@(private = "file")
NUCLEI := [?]string{"a", "e", "i", "o", "u", "ae", "ia", "ei", "ou", "y"}
@(private = "file")
CODAS := [?]string{"", "", "n", "r", "s", "l", "th", "x", "m", "d", "k", "st", "nd", "rn"}

ROMAN := [?]string{"I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"}
LETTERS := "abcdefghijklmnop"

// Two- or three-syllable proper name, capitalised. Allocates with context.allocator.
make_name :: proc(r: ^core.Rng) -> string {
	sb := strings.builder_make(context.temp_allocator)
	n := core.rng_chance(r, 0.6) ? 2 : 3
	for i in 0 ..< n {
		strings.write_string(&sb, core.rng_pick(r, ONSETS[:]))
		strings.write_string(&sb, core.rng_pick(r, NUCLEI[:]))
		if i == n - 1 || core.rng_chance(r, 0.3) do strings.write_string(&sb, core.rng_pick(r, CODAS[:]))
	}
	s := strings.to_string(sb)
	return fmt.aprintf("%s%s", strings.to_upper(s[:1], context.temp_allocator), s[1:])
}

@(private = "file")
FAMILY_ENDS := [?]string{"son", "sen", "ez", "ova", "ski", "wen", "ari", "dal", "ith", "berg", "mar", "oa", "ek", "una", "ric"}

// A person's name: given name plus family name. Allocates with context.allocator.
person_name :: proc(r: ^core.Rng) -> string {
	given := make_name(r)
	defer delete(given)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, core.rng_pick(r, ONSETS[:]))
	strings.write_string(&sb, core.rng_pick(r, NUCLEI[:]))
	if core.rng_chance(r, 0.5) {
		strings.write_string(&sb, core.rng_pick(r, ONSETS[:]))
		strings.write_string(&sb, core.rng_pick(r, NUCLEI[:]))
	}
	strings.write_string(&sb, core.rng_pick(r, FAMILY_ENDS[:]))
	fam := strings.to_string(sb)
	return fmt.aprintf("%s %s%s", given, strings.to_upper(fam[:1], context.temp_allocator), fam[1:])
}
