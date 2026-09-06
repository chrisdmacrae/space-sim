#+build !js
package fastart

import "core:os"
import "core:encoding/json"

load_file :: proc(path: string) -> (doc: Doc, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false
	return load_bytes(data)
}

save_file :: proc(doc: ^Doc, path: string) -> bool {
	doc.version = 1
	res := doc.resolved
	doc.resolved = nil // never serialize the resolution cache
	data, err := json.marshal(doc^, {pretty = true})
	doc.resolved = res
	if err != nil do return false
	defer delete(data)
	return os.write_entire_file(path, data) == nil
}
