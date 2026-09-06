#!/usr/bin/env python3
"""Synthesise the game's audio: an ambient music loop and the menu sound
effects, as 16-bit WAV. Pure stdlib so it runs anywhere.

    python3 tools/gen_audio.py        # writes assets/audio/*.wav
"""
import math, random, struct, wave, os

RATE = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")


def write(name, samples, rate=RATE):
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = 0.92 / peak if peak > 0.92 else 1.0
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * scale)) * 32767)) for s in samples))


def env(i, n, attack, release):
    a = min(1.0, i / max(1, attack))
    r = min(1.0, (n - i) / max(1, release))
    return min(a, r)


def tone(freq, seconds, kind="sine", detune=0.0):
    n = int(seconds * RATE)
    out = []
    ph = 0.0
    for i in range(n):
        f = freq * (1 + detune * math.sin(2 * math.pi * 0.13 * i / RATE))
        ph += 2 * math.pi * f / RATE
        if kind == "sine":
            v = math.sin(ph)
        elif kind == "tri":
            v = 2 / math.pi * math.asin(math.sin(ph))
        else:
            v = math.sin(ph) + 0.35 * math.sin(2 * ph) + 0.15 * math.sin(3 * ph)
        out.append(v)
    return out


def lowpass(samples, cutoff):
    rc = 1.0 / (2 * math.pi * cutoff)
    dt = 1.0 / RATE
    a = dt / (rc + dt)
    y = 0.0
    out = []
    for s in samples:
        y += a * (s - y)
        out.append(y)
    return out


def music():
    random.seed(7)
    seconds = 96
    n = seconds * RATE
    mix = [0.0] * n
    # Four slow chords, each held 24 s, crossfaded: a minor-ish drift.
    chords = [
        [55.0, 82.41, 110.0, 164.81, 246.94],   # A2 E3 A3 E4 B4
        [65.41, 98.0, 130.81, 196.0, 293.66],   # C3 G3 C4 G4 D5
        [49.0, 73.42, 98.0, 146.83, 220.0],     # G2 D3 G3 D4 A4
        [58.27, 87.31, 116.54, 174.61, 261.63], # Bb2 F3 Bb3 F4 C5
    ]
    hold = n // len(chords)
    fade = RATE * 6
    for ci, chord in enumerate(chords):
        start = ci * hold
        for k, f in enumerate(chord):
            amp = 0.22 / (1 + k * 0.6)
            det = 0.004 + 0.002 * k
            t = tone(f, hold / RATE + fade / RATE, "rich" if k == 0 else "tri", det)
            for i, v in enumerate(t):
                j = (start + i) % n
                e = env(i, len(t), fade, fade)
                mix[j] += v * amp * e
    # Sparse high sparkles on a pentatonic set, decaying plucks.
    penta = [440.0, 493.88, 554.37, 659.26, 739.99, 880.0, 987.77]
    for _ in range(70):
        at = random.randrange(0, n)
        f = random.choice(penta) * random.choice([1, 2])
        length = int(RATE * random.uniform(1.2, 2.6))
        for i in range(length):
            j = (at + i) % n
            d = math.exp(-3.5 * i / length)
            mix[j] += 0.05 * d * math.sin(2 * math.pi * f * i / RATE) * (1 + 0.3 * math.sin(2 * math.pi * 5 * i / RATE))
    # Slow filter sweep for movement, then a gentle overall lowpass.
    out = []
    y = 0.0
    for i, s in enumerate(mix):
        cutoff = 900 + 500 * math.sin(2 * math.pi * i / (RATE * 31))
        a = (1.0 / RATE) / (1.0 / (2 * math.pi * cutoff) + 1.0 / RATE)
        y += a * (s - y)
        out.append(y)
    # Loop-safe: identical fade at both ends.
    edge = RATE * 3
    return [s * env(i, n, edge, edge) for i, s in enumerate(out)]


def blip(freq_from, freq_to, seconds, amp=0.5, kind="sine", attack=0.004, release=None):
    n = int(seconds * RATE)
    release = release or seconds * 0.6
    out = []
    ph = 0.0
    for i in range(n):
        u = i / n
        f = freq_from + (freq_to - freq_from) * u
        ph += 2 * math.pi * f / RATE
        v = math.sin(ph) if kind == "sine" else (math.sin(ph) + 0.4 * math.sin(2 * ph))
        out.append(v * amp * env(i, n, attack * RATE, release * RATE))
    return out


def concat(*parts, gap=0.0):
    out = []
    for p in parts:
        out += p
        out += [0.0] * int(gap * RATE)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    write("music.wav", music())
    write("ui_hover.wav", blip(900, 1100, 0.05, 0.25))
    write("ui_click.wav", blip(700, 380, 0.07, 0.5, "rich"))
    write("ui_open.wav", concat(blip(420, 620, 0.06, 0.4), blip(620, 880, 0.08, 0.4)))
    write("ui_close.wav", concat(blip(880, 620, 0.06, 0.4), blip(620, 400, 0.08, 0.4)))
    write("ui_confirm.wav", concat(blip(523, 523, 0.07, 0.45, "rich"), blip(784, 784, 0.12, 0.45, "rich")))
    write("ui_error.wav", lowpass(blip(180, 140, 0.16, 0.7, "rich", release=0.1), 900))
    print("wrote", sorted(os.listdir(OUT)))


if __name__ == "__main__":
    main()
