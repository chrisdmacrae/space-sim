package audio

// Background music and interface sounds through raylib's audio device.
// Everything degrades to silence: a missing file or no device only means
// nothing plays.

import "core:fmt"
import rl "vendor:raylib"

Sfx :: enum u8 {
	Hover,
	Click,
	Open,
	Close,
	Confirm,
	Error,
}

SFX_FILES :: [Sfx]cstring {
	.Hover = "assets/audio/ui_hover.wav", .Click = "assets/audio/ui_click.wav", .Open = "assets/audio/ui_open.wav",
	.Close = "assets/audio/ui_close.wav", .Confirm = "assets/audio/ui_confirm.wav", .Error = "assets/audio/ui_error.wav",
}
MUSIC_FILE :: "assets/audio/music.wav"

State :: struct {
	ready:     bool,
	music:     rl.Music,
	has_music: bool,
	sounds:    [Sfx]rl.Sound,
	loaded:    bit_set[Sfx],
	master, music_vol, sfx_vol: f32,
	muted_music: bool,
}

state: State

init :: proc() {
	rl.InitAudioDevice()
	state.ready = rl.IsAudioDeviceReady()
	if !state.ready {
		fmt.println("audio: no device, running silent")
		return
	}
	state.master, state.music_vol, state.sfx_vol = 1, 1, 1
	state.music = rl.LoadMusicStream(MUSIC_FILE)
	state.has_music = rl.IsMusicValid(state.music)
	if state.has_music {
		state.music.looping = true
		rl.PlayMusicStream(state.music)
	}
	files := SFX_FILES
	for s in Sfx {
		snd := rl.LoadSound(files[s])
		if rl.IsSoundValid(snd) {
			state.sounds[s] = snd
			state.loaded += {s}
		}
	}
}

shutdown :: proc() {
	if !state.ready do return
	for s in Sfx do if s in state.loaded do rl.UnloadSound(state.sounds[s])
	if state.has_music do rl.UnloadMusicStream(state.music)
	rl.CloseAudioDevice()
	state.ready = false
}

// Call once per frame: keeps the music buffers fed.
update :: proc() {
	if state.ready && state.has_music do rl.UpdateMusicStream(state.music)
}

play :: proc(s: Sfx) {
	if state.ready && s in state.loaded do rl.PlaySound(state.sounds[s])
}

// Volumes are 0..1.
set_volumes :: proc(master, music, sfx: f32) {
	state.master, state.music_vol, state.sfx_vol = master, music, sfx
	if !state.ready do return
	rl.SetMasterVolume(clamp(master, 0, 1))
	if state.has_music do rl.SetMusicVolume(state.music, clamp(music, 0, 1))
	for s in Sfx do if s in state.loaded do rl.SetSoundVolume(state.sounds[s], clamp(sfx, 0, 1))
}
