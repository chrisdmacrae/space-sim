package fastart

// Asset table with hot reload. Each document lives in its own arena, so a
// reload is: destroy the arena, load again. Palette refs resolve relative to
// the document's own file.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:time"

Entry :: struct {
	name:    string,
	path:    string, // absolute or root-relative path on disk
	doc:     Doc,
	arena:   virtual.Arena,
	mtime:   i64, // unix nanoseconds at last load
	deps:    [dynamic]Dep, // palette refs; a change to any of them reloads
	ok:      bool,
	reloads: int,
}

Dep :: struct {
	path:  string, // owned
	mtime: i64,
}

Library :: struct {
	root:       string,
	entries:    map[string]^Entry,
	order:      [dynamic]string, // stable listing order for the debug panel
	poll_acc:   f64,
	poll_every: f64,
	message:    string, // last reload message (owned)
	message_t:  f64,    // real seconds since library_init when message was set
	elapsed:    f64,
}

library_init :: proc(lib: ^Library, root: string, poll_every := 0.25) {
	lib.root = root
	lib.poll_every = poll_every
	lib.entries = make(map[string]^Entry)
}

library_destroy :: proc(lib: ^Library) {
	for _, e in lib.entries {
		virtual.arena_destroy(&e.arena)
		deps_clear(e)
		delete(e.deps)
		delete(e.path)
		delete(e.name)
		free(e)
	}
	delete(lib.entries)
	delete(lib.order)
	delete(lib.message)
}

// Register and load a document. `rel` is relative to the library root.
library_load :: proc(lib: ^Library, name, rel: string) -> ^Entry {
	e := new(Entry)
	e.name = fmt.aprintf("%s", name)
	e.path, _ = filepath.join({lib.root, rel})
	e.deps = make([dynamic]Dep)
	entry_load(lib, e)
	lib.entries[e.name] = e
	append(&lib.order, e.name)
	return e
}

library_get :: proc(lib: ^Library, name: string) -> ^Doc {
	if e, found := lib.entries[name]; found && e.ok do return &e.doc
	return nil
}

// Call once per frame with real (not game) seconds. Reloads changed files.
library_poll :: proc(lib: ^Library, real_dt: f64) {
	lib.elapsed += real_dt
	lib.poll_acc += real_dt
	if lib.poll_acc < lib.poll_every do return
	lib.poll_acc = 0
	for _, e in lib.entries {
		if entry_stale(e) do entry_load(lib, e)
	}
}

@(private = "file")
entry_stale :: proc(e: ^Entry) -> bool {
	if m := file_mtime(e.path); m != e.mtime && m != 0 do return true
	for d in e.deps {
		if m := file_mtime(d.path); m != d.mtime && m != 0 do return true
	}
	return false
}

@(private = "file")
deps_clear :: proc(e: ^Entry) {
	for d in e.deps do delete(d.path)
	clear(&e.deps)
}

library_reload_all :: proc(lib: ^Library) {
	for _, e in lib.entries do entry_load(lib, e)
}

// Seconds since the last reload message, for fading it out.
library_message_age :: proc(lib: ^Library) -> f64 {
	return lib.elapsed - lib.message_t
}

@(private = "file")
file_mtime :: proc(path: string) -> i64 {
	t, err := os.modification_time_by_path(path)
	if err != nil do return 0
	return time.time_to_unix_nano(t)
}

@(private = "file")
entry_load :: proc(lib: ^Library, e: ^Entry) {
	// Fresh arena per load; the old document's memory goes with the old arena.
	virtual.arena_destroy(&e.arena)
	if virtual.arena_init_growing(&e.arena) != nil {
		set_message(lib, fmt.tprintf("%s: arena init failed", e.name))
		e.ok = false
		return
	}
	context.allocator = virtual.arena_allocator(&e.arena)

	e.mtime = file_mtime(e.path)
	doc, ok := load_file(e.path)
	if !ok {
		e.ok = false
		set_message(lib, fmt.tprintf("%s: failed to parse %s", e.name, e.path))
		return
	}
	// Palette refs are dependencies: remember their paths and times so an
	// edit to a shared palette reloads every document that uses it.
	deps_clear(e)
	dir := filepath.dir(e.path)
	for ref in doc.palette_refs {
		full, _ := filepath.join({dir, ref}, runtime.default_allocator())
		append(&e.deps, Dep{path = full, mtime = file_mtime(full)})
	}
	resolve_palettes(&doc, palette_resolver, rawptr(&dir))
	e.doc = doc
	e.ok = true
	e.reloads += 1
	if e.reloads > 1 do set_message(lib, fmt.tprintf("reloaded %s", e.name))
}

@(private = "file")
palette_resolver :: proc(ref: string, user: rawptr) -> ([]byte, bool) {
	dir := (^string)(user)^
	full, _ := filepath.join({dir, ref}, context.temp_allocator)
	data, err := os.read_entire_file(full, context.temp_allocator)
	return data, err == nil
}

@(private = "file")
set_message :: proc(lib: ^Library, msg: string) {
	delete(lib.message)
	lib.message = fmt.aprintf("%s", msg)
	lib.message_t = lib.elapsed
}
