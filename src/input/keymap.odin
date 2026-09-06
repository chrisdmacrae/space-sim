package input

// Named key bindings. Every keyboard read in the game goes through here so
// the Settings screen can rebind any of them; Escape and Enter stay fixed
// as the universal cancel/confirm keys.

import "core:fmt"
import "core:reflect"
import "core:strings"
import rl "vendor:raylib"

Bind :: enum u8 {
	// flight
	Throttle_Full,
	Cut_Engine,
	Throttle_Up,
	Throttle_Down,
	Turn_Left,
	Turn_Right,
	Hold_Prograde,
	Hold_Retrograde,
	// planning
	Plan_Course,
	Dock,
	Undock,
	// maneuver nodes
	Node_Add,
	Node_Remove,
	Warp_To_Burn,
	Execute_Burn,
	Node_Earlier,
	Node_Later,
	Node_Prograde_Up,
	Node_Prograde_Down,
	Node_Radial_Up,
	Node_Radial_Down,
	// time
	Pause,
	Warp_Down,
	Warp_Up,
	// view
	Follow_Ship,
	Frame_System,
	Cycle_Focus,
	Galaxy_Map,
	Market,
	Shipyard,
	Ship_Interior,
	Pan_Up,
	Pan_Down,
	Pan_Left,
	Pan_Right,
	Rotate_Left,
	Rotate_Right,
	Rotate_Reset,
	Heading_Lock,
	// system
	Quick_Save,
	Quick_Load,
	Regenerate,
	Debug_Panel,
}

Group :: enum u8 {
	Flight,
	Planning,
	Nodes,
	Time,
	View,
	Camera,
	System,
}

Keymap :: [Bind]rl.KeyboardKey

DEFAULTS :: Keymap {
	.Throttle_Full = .Z, .Cut_Engine = .X, .Throttle_Up = .UP, .Throttle_Down = .DOWN,
	.Turn_Left = .LEFT, .Turn_Right = .RIGHT, .Hold_Prograde = .P, .Hold_Retrograde = .O,
	.Plan_Course = .G, .Dock = .K, .Undock = .U,
	.Node_Add = .N, .Node_Remove = .DELETE, .Warp_To_Burn = .T, .Execute_Burn = .B,
	.Node_Earlier = .LEFT_BRACKET, .Node_Later = .RIGHT_BRACKET,
	.Node_Prograde_Up = .EQUAL, .Node_Prograde_Down = .MINUS, .Node_Radial_Up = .APOSTROPHE, .Node_Radial_Down = .SEMICOLON,
	.Pause = .SPACE, .Warp_Down = .COMMA, .Warp_Up = .PERIOD,
	.Follow_Ship = .F, .Frame_System = .H, .Cycle_Focus = .TAB, .Galaxy_Map = .J, .Market = .M, .Shipyard = .Y, .Ship_Interior = .I,
	.Pan_Up = .W, .Pan_Down = .S, .Pan_Left = .A, .Pan_Right = .D,
	.Rotate_Left = .Q, .Rotate_Right = .E, .Rotate_Reset = .HOME, .Heading_Lock = .V,
	.Quick_Save = .F5, .Quick_Load = .F9, .Regenerate = .R, .Debug_Panel = .GRAVE,
}

NAMES :: [Bind]string {
	.Throttle_Full = "Full throttle", .Cut_Engine = "Cut engine", .Throttle_Up = "Throttle up (hold)", .Throttle_Down = "Throttle down (hold)",
	.Turn_Left = "Turn left (hold)", .Turn_Right = "Turn right (hold)", .Hold_Prograde = "Hold prograde", .Hold_Retrograde = "Hold retrograde",
	.Plan_Course = "Plot course / cancel autopilot", .Dock = "Dock", .Undock = "Undock",
	.Node_Add = "Add maneuver node", .Node_Remove = "Remove node", .Warp_To_Burn = "Warp to burn", .Execute_Burn = "Execute burn",
	.Node_Earlier = "Node earlier (hold)", .Node_Later = "Node later (hold)",
	.Node_Prograde_Up = "Node prograde + (hold)", .Node_Prograde_Down = "Node prograde - (hold)", .Node_Radial_Up = "Node radial + (hold)", .Node_Radial_Down = "Node radial - (hold)",
	.Pause = "Pause / resume", .Warp_Down = "Warp slower", .Warp_Up = "Warp faster",
	.Follow_Ship = "Follow ship", .Frame_System = "Frame whole system", .Cycle_Focus = "Cycle focus", .Galaxy_Map = "Galaxy map", .Market = "Market window", .Shipyard = "Shipyard window", .Ship_Interior = "Inside the ship (crew)",
	.Pan_Up = "Pan up (hold)", .Pan_Down = "Pan down (hold)", .Pan_Left = "Pan left (hold)", .Pan_Right = "Pan right (hold)",
	.Rotate_Left = "Rotate view left (hold)", .Rotate_Right = "Rotate view right (hold)", .Rotate_Reset = "Reset view rotation", .Heading_Lock = "Lock view to ship heading",
	.Quick_Save = "Quick save", .Quick_Load = "Quick load", .Regenerate = "Regenerate galaxy", .Debug_Panel = "Debug panel",
}

group_of :: proc(b: Bind) -> Group {
	switch b {
	case .Throttle_Full, .Cut_Engine, .Throttle_Up, .Throttle_Down, .Turn_Left, .Turn_Right, .Hold_Prograde, .Hold_Retrograde: return .Flight
	case .Plan_Course, .Dock, .Undock: return .Planning
	case .Node_Add, .Node_Remove, .Warp_To_Burn, .Execute_Burn, .Node_Earlier, .Node_Later, .Node_Prograde_Up, .Node_Prograde_Down, .Node_Radial_Up, .Node_Radial_Down: return .Nodes
	case .Pause, .Warp_Down, .Warp_Up: return .Time
	case .Follow_Ship, .Frame_System, .Cycle_Focus, .Galaxy_Map, .Market, .Shipyard, .Ship_Interior: return .View
	case .Pan_Up, .Pan_Down, .Pan_Left, .Pan_Right, .Rotate_Left, .Rotate_Right, .Rotate_Reset, .Heading_Lock: return .Camera
	case .Quick_Save, .Quick_Load, .Regenerate, .Debug_Panel: return .System
	}
	return .System
}

// The live map. Settings load into it at startup.
keymap := DEFAULTS

pressed :: proc(b: Bind) -> bool { return rl.IsKeyPressed(keymap[b]) }
down    :: proc(b: Bind) -> bool { return rl.IsKeyDown(keymap[b]) }

// Short label for a key, as shown beside menu items and in the bindings list.
key_label :: proc(k: rl.KeyboardKey) -> string {
	#partial switch k {
	case .KEY_NULL:       return "-"
	case .SPACE:         return "Space"
	case .COMMA:         return ","
	case .PERIOD:        return "."
	case .GRAVE:         return "`"
	case .LEFT_BRACKET:  return "["
	case .RIGHT_BRACKET: return "]"
	case .SEMICOLON:     return ";"
	case .APOSTROPHE:    return "'"
	case .SLASH:         return "/"
	case .BACKSLASH:     return "\\"
	case .MINUS:         return "-"
	case .EQUAL:         return "="
	case .DELETE:        return "Del"
	case .BACKSPACE:     return "Backspace"
	case .TAB:           return "Tab"
	case .ENTER:         return "Enter"
	case .ESCAPE:        return "Esc"
	case .UP:            return "Up"
	case .DOWN:          return "Down"
	case .LEFT:          return "Left"
	case .RIGHT:         return "Right"
	case .LEFT_SHIFT:    return "L Shift"
	case .RIGHT_SHIFT:   return "R Shift"
	case .LEFT_CONTROL:  return "L Ctrl"
	case .RIGHT_CONTROL: return "R Ctrl"
	case .LEFT_ALT:      return "L Alt"
	case .RIGHT_ALT:     return "R Alt"
	case .PAGE_UP:       return "PgUp"
	case .PAGE_DOWN:     return "PgDn"
	case .HOME:          return "Home"
	case .END:           return "End"
	case .INSERT:        return "Ins"
	case .KP_0, .KP_1, .KP_2, .KP_3, .KP_4, .KP_5, .KP_6, .KP_7, .KP_8, .KP_9:
		return fmt.tprintf("Num %d", int(k) - int(rl.KeyboardKey.KP_0))
	case .KP_ADD:       return "Num +"
	case .KP_SUBTRACT:  return "Num -"
	case .KP_MULTIPLY:  return "Num *"
	case .KP_DIVIDE:    return "Num /"
	case .KP_ENTER:     return "Num Enter"
	case .KP_DECIMAL:   return "Num ."
	}
	name := fmt.tprint(k)
	// Enum names are upper case: ZERO..NINE are digits, F1..F12 keep their case.
	digits := [?]string{"ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"}
	for d, i in digits do if name == d do return fmt.tprintf("%d", i)
	if len(name) == 1 || (len(name) <= 3 && name[0] == 'F') do return name
	// "CAPS_LOCK" -> "Caps lock"
	lower := strings.to_lower(name, context.temp_allocator)
	out := strings.builder_make(context.temp_allocator)
	for ch, i in lower {
		if i == 0 do strings.write_rune(&out, ch - 32)
		else if ch == '_' do strings.write_rune(&out, ' ')
		else do strings.write_rune(&out, ch)
	}
	return strings.to_string(out)
}

label :: proc(b: Bind) -> string { return key_label(keymap[b]) }

// Other binds sharing the key of `b`, if any.
conflicts :: proc(b: Bind) -> bool {
	k := keymap[b]
	if k == .KEY_NULL do return false
	for other in Bind do if other != b && keymap[other] == k do return true
	return false
}

// Keys the rebinder refuses: the fixed cancel/confirm keys and mouse-only names.
rebindable :: proc(k: rl.KeyboardKey) -> bool {
	#partial switch k {
	case .KEY_NULL, .ESCAPE, .ENTER, .KP_ENTER: return false
	}
	return true
}

// Persistence: enum names on both sides, so a settings file stays readable.
key_to_string :: proc(k: rl.KeyboardKey) -> string { return fmt.tprint(k) }
key_from_string :: proc(s: string) -> (rl.KeyboardKey, bool) {
	v, ok := reflect.enum_from_name(rl.KeyboardKey, s)
	return v, ok
}
bind_to_string :: proc(b: Bind) -> string { return fmt.tprint(b) }
bind_from_string :: proc(s: string) -> (Bind, bool) {
	v, ok := reflect.enum_from_name(Bind, s)
	return v, ok
}
