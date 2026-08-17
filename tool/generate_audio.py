#!/usr/bin/env python3
"""Generate original synthesized SFX + music for Raft Rumble."""
import numpy as np
import wave
import os

SR = 22050
OUT = "/home/user/flutter_app/assets/sfx"
os.makedirs(OUT, exist_ok=True)

def save_wav(name, data, vol=0.8):
    data = np.asarray(data)
    peak = np.max(np.abs(data))
    if peak > 0:
        data = data / peak * vol
    pcm = (data * 32767).astype(np.int16)
    with wave.open(os.path.join(OUT, name), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"  {name} ({len(data)/SR:.2f}s)")

def noise(n):
    return np.random.uniform(-1, 1, n)

def env_exp(n, decay):
    t = np.arange(n) / SR
    return np.exp(-t * decay)

def sine_sweep(f0, f1, dur):
    n = int(SR * dur)
    t = np.arange(n) / SR
    f = np.linspace(f0, f1, n)
    phase = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(phase)

def square_sweep(f0, f1, dur):
    return np.sign(sine_sweep(f0, f1, dur))

# --- UI ---
n = int(SR * 0.08)
save_wav("click.wav", sine_sweep(880, 660, 0.08) * env_exp(n, 40) * 0.6)

n = int(SR * 0.35)
s = sine_sweep(500, 900, 0.35) * env_exp(n, 8) * 0.5
save_wav("fire.wav", s + noise(n) * env_exp(n, 14) * 0.25)

# --- Explosion ---
n = int(SR * 0.9)
t = np.arange(n) / SR
boom = noise(n) * env_exp(n, 5)
# lowpass via simple moving average
k = 24
boom = np.convolve(boom, np.ones(k)/k, mode='same')
boom += np.sin(2*np.pi*45*t) * env_exp(n, 4) * 0.9
save_wav("explosion.wav", boom)

# --- Bounce (grenade) ---
n = int(SR * 0.09)
save_wav("bounce.wav", sine_sweep(300, 180, 0.09) * env_exp(n, 50) * 0.7)

# --- Breaks ---
for name, dur, dec, tone in [("break_wood", 0.30, 16, 220), ("break_stone", 0.4, 10, 120), ("break_metal", 0.5, 6, 520)]:
    n = int(SR * dur)
    snd = noise(n) * env_exp(n, dec)
    snd = np.convolve(snd, np.ones(6)/6, mode='same')
    if name == "break_metal":
        snd += sine_sweep(tone*3, tone, dur) * env_exp(n, 8) * 0.35
    save_wav(f"{name}.wav", snd)

# glass: high pitched shatter
n = int(SR * 0.35)
g = noise(n) * env_exp(n, 22)
g += sine_sweep(2400, 900, 0.35) * env_exp(n, 25) * 0.4
save_wav("break_glass.wav", g)

# --- Character hit / ouch ---
n = int(SR * 0.25)
save_wav("hit.wav", square_sweep(420, 180, 0.25) * env_exp(n, 14) * 0.5)

n = int(SR * 0.4)
save_wav("eliminate.wav", square_sweep(600, 120, 0.4) * env_exp(n, 7) * 0.5)

# --- Splash ---
n = int(SR * 0.6)
sp = noise(n) * env_exp(n, 6)
sp = np.convolve(sp, np.ones(16)/16, mode='same')
save_wav("splash.wav", sp)

# --- Whoosh (projectile flight) ---
n = int(SR * 0.5)
wh = noise(n) * env_exp(n, 5)
wh = np.convolve(wh, np.ones(10)/10, mode='same')
save_wav("whoosh.wav", wh)

# --- Freeze ---
n = int(SR * 0.5)
save_wav("freeze.wav", sine_sweep(1800, 2600, 0.5) * env_exp(n, 6) * 0.4 + noise(n)*env_exp(n,20)*0.15)

# --- Shockwave ---
n = int(SR * 0.5)
sw = np.sin(2*np.pi*60*np.arange(n)/SR) * env_exp(n, 6)
sw += noise(n) * env_exp(n, 10) * 0.4
save_wav("shockwave.wav", sw)

# --- Drill ---
n = int(SR * 0.7)
dr = np.sign(np.sin(2*np.pi*90*np.arange(n)/SR)) * env_exp(n, 3)
dr += noise(n) * 0.3 * env_exp(n, 3)
save_wav("drill.wav", dr, vol=0.5)

# --- Turn change chime ---
n = int(SR * 0.4)
t0 = np.arange(n)//2
ch = np.zeros(n)
ch[:n//2] = sine_sweep(660, 660, 0.2)[:n//2] * env_exp(n//2, 10)
ch[n//2:] = sine_sweep(880, 880, 0.2)[:n-n//2] * env_exp(n-n//2, 10)
save_wav("turn.wav", ch * 0.6)

# --- Victory jingle ---
notes = [(523,0.15),(659,0.15),(784,0.15),(1047,0.35)]
data = []
for f, d in notes:
    nn = int(SR*d)
    data.append(sine_sweep(f, f, d) * env_exp(nn, 6))
save_wav("victory.wav", np.concatenate(data) * 0.6)

# --- Defeat jingle ---
notes = [(392,0.25),(330,0.25),(262,0.5)]
data = []
for f, d in notes:
    nn = int(SR*d)
    data.append(sine_sweep(f, f*0.97, d) * env_exp(nn, 4))
save_wav("defeat.wav", np.concatenate(data) * 0.5)

# --- Build place thunk ---
n = int(SR * 0.12)
save_wav("place.wav", sine_sweep(200, 90, 0.12) * env_exp(n, 25) * 0.8)

# --- Fuse/hiss (fire weapon) ---
n = int(SR * 0.5)
hf = noise(n) * env_exp(n, 8)
hf = hf - np.convolve(hf, np.ones(32)/32, mode='same')
save_wav("burn.wav", hf, vol=0.5)

# --- Menu music loop (8 bars, bouncy cartoon) ---
bpm = 132
beat = 60.0 / bpm
melody = [523, 587, 659, 784, 659, 587, 523, 392, 440, 523, 587, 659, 587, 523, 440, 392]
bass =   [131, 131, 165, 165, 175, 175, 196, 196]
music = []
for i, f in enumerate(melody):
    nn = int(SR * beat * 0.5)
    note = np.sin(2*np.pi*f*np.arange(nn)/SR) * env_exp(nn, 5) * 0.5
    note += np.sin(2*np.pi*f*2*np.arange(nn)/SR) * env_exp(nn, 8) * 0.15
    music.append(note)
for rep in range(2):
    for f in bass:
        nn = int(SR * beat)
        music.append(np.sin(2*np.pi*f*np.arange(nn)/SR) * env_exp(nn, 3) * 0.4)
# reorder: interleave properly -> simpler: melody then bass overlay
total_len = int(SR * beat * 0.5 * len(melody))
mix = np.zeros(total_len)
pos = 0
for f in melody:
    nn = int(SR * beat * 0.5)
    mix[pos:pos+nn] += np.sin(2*np.pi*f*np.arange(nn)/SR) * env_exp(nn, 5) * 0.45
    pos += nn
pos = 0
bassline = bass * (len(melody)//len(bass))
for f in bassline:
    nn = int(SR * beat)
    if pos + nn <= total_len:
        mix[pos:pos+nn] += np.sin(2*np.pi*f*np.arange(nn)/SR) * env_exp(nn, 3) * 0.35
    pos += nn
save_wav("music_menu.wav", mix, vol=0.6)

# --- Battle music loop (faster, driving) ---
bpm = 150
beat = 60.0 / bpm
melody = [440, 440, 523, 587, 440, 659, 587, 523, 440, 440, 523, 587, 784, 659, 587, 523]
total_len = int(SR * beat * 0.5 * len(melody))
mix = np.zeros(total_len)
pos = 0
for f in melody:
    nn = int(SR * beat * 0.5)
    mix[pos:pos+nn] += np.sin(2*np.pi*f*np.arange(nn)/SR) * env_exp(nn, 6) * 0.4
    mix[pos:pos+nn] += np.sign(np.sin(2*np.pi*f/2*np.arange(nn)/SR)) * env_exp(nn, 4) * 0.15
    pos += nn
save_wav("music_battle.wav", mix, vol=0.55)

print("All audio generated!")
