package text

// Readable text: a proper TrueType font rasterised at a few sizes, chosen
// per call so nothing is scaled far from its atlas size. Prefers a font in
// assets/fonts/, then a system font, then raylib's built-in one.

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

SIZES := [?]i32{12, 14, 16, 18, 22, 28}

Fonts :: struct {
	at:     [len(SIZES)]rl.Font,
	loaded: bool,
	path:   string,
}

fonts: Fonts

@(private = "file")
CANDIDATES := [?]string {
	"/System/Library/Fonts/Supplemental/Verdana.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/System/Library/Fonts/Geneva.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"C:/Windows/Fonts/verdana.ttf",
	"C:/Windows/Fonts/arial.ttf",
}

// Call once after the window exists.
load :: proc() {
	path := ""
	// A bundled font wins: any .ttf/.otf in assets/fonts.
	if entries, err := os.read_directory_by_path("assets/fonts", -1, context.temp_allocator); err == nil {
		for e in entries {
			ext := strings.to_lower(filepath.ext(e.name), context.temp_allocator)
			if ext == ".ttf" || ext == ".otf" {
				path = fmt.tprintf("assets/fonts/%s", e.name)
				break
			}
		}
	}
	if path == "" {
		for c in CANDIDATES do if os.exists(c) { path = c; break }
	}
	if path == "" do return
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	for size, i in SIZES {
		f := rl.LoadFontEx(cpath, c.int(size * 2), nil, 0) // 2x for crispness on HiDPI
		if f.texture.id == 0 do return
		rl.SetTextureFilter(f.texture, .BILINEAR)
		fonts.at[i] = f
	}
	fonts.loaded = true
	fonts.path = path
	rl.GuiSetFont(fonts.at[2])
}

unload :: proc() {
	if !fonts.loaded do return
	for f in fonts.at do rl.UnloadFont(f)
	fonts.loaded = false
}

// Font whose atlas size is nearest the requested size.
font_for :: proc(size: i32) -> rl.Font {
	best := 0
	for s, i in SIZES do if abs(s - size) < abs(SIZES[best] - size) do best = i
	return fonts.at[best]
}

// Drop-in for rl.DrawText.
draw :: proc(t: cstring, x, y, size: i32, color: rl.Color) {
	if !fonts.loaded {
		rl.DrawText(t, x, y, size, color)
		return
	}
	rl.DrawTextEx(font_for(size), t, {f32(x), f32(y)}, f32(size), 0.5, color)
}

// Drop-in for rl.MeasureText.
measure :: proc(t: cstring, size: i32) -> i32 {
	if !fonts.loaded do return rl.MeasureText(t, size)
	return i32(rl.MeasureTextEx(font_for(size), t, f32(size), 0.5).x)
}
