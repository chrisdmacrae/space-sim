package render

import "core:fmt"
import "core:testing"
import art "sim:art"

// Every feature document the renderer layers must parse, carry the parts
// and states the layering expects, and use only avatar palette tokens.
@(test)
avatar_documents_match_the_renderer :: proc(t: ^testing.T) {
	c := AVATAR_COUNTS
	names := [?]string{"head", "hair", "eyes", "brows", "nose", "mouth", "beard", "collar", "extra"}
	counts := [?]int{c.head, c.hair, c.eyes, c.brows, c.nose, c.mouth, c.beard, c.collar, c.extra}
	tokens := [?]string{"skin", "skin_shade", "hair", "hair_shade", "eye", "sclera", "cloth", "cloth2", "accent", "line", "mouth", "teeth"}
	for name, i in names {
		for k in 0 ..< counts[i] {
			path := fmt.tprintf("assets/avatars/%s_%d.fart", name, k)
			doc, ok := art.load_file(path)
			testing.expectf(t, ok, "%s parses", path)
			if !ok do continue
			defer art.destroy(&doc)
			states := name == "hair" ? []string{"back", "front"} : []string{"idle"}
			for st in states {
				found := false
				for s in doc.states do if s.name == st do found = true
				testing.expectf(t, found, "%s has state %s", path, st)
			}
			for p in doc.parts do for sh in p.shapes {
				known := false
				for tok in tokens do if sh.color == tok do known = true
				testing.expectf(t, known, "%s uses palette token %q", path, sh.color)
				if sh.kind == "poly" do testing.expectf(t, len(sh.tris) >= 3 && len(sh.tris) % 3 == 0, "%s polygon is triangulated", path)
			}
		}
	}
	// Faces roll deterministically and within range.
	a := avatar_make(42)
	b := avatar_make(42)
	testing.expect(t, a == b, "same seed, same face")
	for seed in 0 ..< 200 {
		av := avatar_make(u64(seed))
		testing.expect(t, int(av.head) < c.head && int(av.hair) < c.hair && int(av.extra) < c.extra && int(av.beard) < c.beard, "features in range")
	}
}
