// Generates the crew's cartoon voice blips as 16-bit PCM WAV files into
// assets/sfx/. Run once with `dart run tool/gen_voice_sfx.dart` — the
// generated files are committed, so this never needs to run at build time.
//
// Each voice is a tiny synthesized vocalism: a pitched source with a few
// harmonics (so it reads as a mouth, not a beep), shaped by an amplitude
// envelope. Different calibers of grunt/yawn/laugh give the crew audible
// personality without any recorded dialogue.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const int sampleRate = 22050;

void main() {
  Directory('assets/sfx').createSync(recursive: true);
  // Every vocalisation now goes through [voiced], which puts two formant
  // resonances and a little breath behind the raw harmonic stack.
  //
  // This is the single biggest improvement to how the crew sound. The old
  // clips were mathematically vowels — a fundamental plus harmonics — but
  // with no vocal tract behind them, and a vowel with no resonance is a
  // buzzer. Each clip below picks the vowel that matches what the body is
  // doing: an open "ah" for a yelp, a closed "mm" for a hum, a rounded "oo"
  // for a yawn.
  //
  // The two exceptions are deliberate: a whistle has no vocal tract in it by
  // definition, and the weapon-swap clack is a prop, not a person.
  writeVoice('voice_grunt.wav', voiced(grunt(), f1: 620, f2: 1180, breath: 0.08));
  // Four "Awww" variations — every hit yelp is a little different, and each
  // one is placed on a slightly different vowel so they do not stack into
  // one sound when a blast catches a whole crew.
  writeVoice('voice_ouch1.wav',
      voiced(aww(start: 260, end: 140, dur: 0.45, vibrato: 8), f1: 730, f2: 1150));
  writeVoice('voice_ouch2.wav',
      voiced(aww(start: 325, end: 195, dur: 0.38, vibrato: 13), f1: 800, f2: 1300, seed: 12));
  writeVoice('voice_ouch3.wav',
      voiced(aww(start: 200, end: 105, dur: 0.62, vibrato: 6), f1: 640, f2: 1020, seed: 17));
  writeVoice('voice_ouch4.wav', voiced(doubleAww(), f1: 760, f2: 1220, seed: 23));
  writeVoice('voice_laugh.wav', voiced(laugh(), f1: 700, f2: 1400, breath: 0.09));
  writeVoice('voice_yawn.wav', voiced(yawn(), f1: 420, f2: 900, breath: 0.14));
  writeVoice('voice_whistle.wav', whistle());
  writeVoice('voice_chatter.wav', voiced(chatter(), f1: 620, f2: 1600, breath: 0.07));
  writeVoice('voice_hmm.wav', voiced(hmm(), f1: 330, f2: 950, breath: 0.03));
  writeVoice('voice_look.wav', voiced(look(), f1: 560, f2: 1500));
  writeVoice('voice_swap.wav', voiced(hup(), f1: 680, f2: 1150));
  writeVoice('voice_hup.wav', voiced(hup(), f1: 680, f2: 1150));
  writeWav('swap.wav', swapClack());

  // New reactions the crew needed once their bodies started acting too: a
  // whole-body cheer wants a whoop, a status hit wants a gasp, and a boss
  // landing its signature wants something smug to say it with.
  writeVoice('voice_cheer.wav', voiced(cheer(), f1: 780, f2: 1450, breath: 0.1));
  writeVoice('voice_gasp.wav', voiced(gasp(), f1: 600, f2: 1700, breath: 0.22));
  writeVoice('voice_brr.wav', voiced(brr(), f1: 340, f2: 980, breath: 0.05));
  writeVoice('voice_taunt.wav', voiced(taunt(), f1: 700, f2: 1250, breath: 0.06));

  // The activity set grew from eleven things to twenty-three, and a new
  // activity with no clip of its own plays silently — so every one of them
  // gets a voice here.
  writeVoice('voice_tsk.wav', tsk());
  writeVoice('voice_hum.wav', hum());
  writeVoice('voice_sneeze.wav', sneeze());
  writeVoice('voice_count.wav', count());
  writeVoice('voice_blow.wav', blow());

  // ---- Pitch variants -------------------------------------------------
  //
  // A deck used to be a row of people with one identical voice. Every
  // character now carries a [VoiceType], and these are what it selects: the
  // same clip resampled down for the heavies and up for the wiry ones, so a
  // dockhand and a dune runner do not yelp in the same register.
  //
  // Resampling rather than re-synthesising on purpose — it keeps every
  // variant recognisably the *same* vocalism, which is what makes a crew
  // sound like a crew instead of four unrelated cartoons.
  const pitched = [
    'voice_grunt', 'voice_ouch1', 'voice_ouch2', 'voice_ouch3', 'voice_ouch4',
    'voice_laugh', 'voice_yawn', 'voice_chatter', 'voice_hmm', 'voice_look',
    'voice_cheer', 'voice_gasp', 'voice_hup',
    'voice_tsk', 'voice_hum', 'voice_sneeze', 'voice_count', 'voice_blow',
    'voice_taunt', 'voice_brr', 'voice_whistle',
  ];
  for (final name in pitched) {
    final base = readWav('$name.wav');
    writeVoice('${name}_low.wav', resample(base, 1.28));
    writeVoice('${name}_high.wav', resample(base, 0.78));
  }

  stdout.writeln('voice blips written to assets/sfx/');
}

/// A short rising whoop — the sound of both arms going up.
List<double> cheer() {
  const dur = 0.4;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    // Rises then breaks, like a voice cracking on the way up.
    final f = 240 + 210 * smooth(min(1.0, k * 1.4)) + 14 * sin(2 * pi * 9 * t);
    final s = 0.55 * sin(2 * pi * f * t) +
        0.28 * sin(2 * pi * 2 * f * t) +
        0.12 * sin(2 * pi * 3 * f * t);
    out.add(s * env(k, attack: 0.08, release: 0.4) * 0.9);
  }
  return out;
}

/// A sharp inward gasp — what a status round lands on.
List<double> gasp() {
  const dur = 0.26;
  final out = <double>[];
  final rnd = Random(4242);
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    // Mostly breath: filtered noise with a faint pitched edge climbing.
    final noise = (rnd.nextDouble() * 2 - 1) * 0.5;
    final f = 300 + 260 * smooth(k);
    final s = noise * 0.7 + 0.3 * sin(2 * pi * f * t);
    out.add(s * env(k, attack: 0.25, release: 0.5) * 0.75);
  }
  return out;
}

/// A shivering "brrr" — a low tone chopped by a fast tremolo.
List<double> brr() {
  const dur = 0.5;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final f = 150 - 25 * k;
    // The chatter of teeth: a 22Hz gate over the tone.
    final gate = 0.45 + 0.55 * (sin(2 * pi * 22 * t) > 0 ? 1.0 : 0.25);
    final s = 0.6 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t);
    out.add(s * gate * env(k, attack: 0.06, release: 0.3) * 0.8);
  }
  return out;
}

/// Two smug descending notes — a boss reaching for its signature round.
List<double> taunt() {
  const dur = 0.46;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final first = k < 0.46;
    final p = first ? k / 0.46 : (k - 0.5) / 0.5;
    final f = (first ? 250.0 : 190.0) - 30 * smooth(p);
    final gate = first ? 1.0 : 0.85;
    final s = 0.5 * sin(2 * pi * f * t) +
        0.32 * sin(2 * pi * 2 * f * t) +
        0.18 * sin(2 * pi * 3 * f * t);
    out.add(s * gate * env(k, attack: 0.07, release: 0.3) * 0.85);
  }
  return out;
}

/// Linear-interpolated resample. [factor] > 1 stretches (lower pitch),
/// < 1 compresses (higher pitch).
List<double> resample(List<double> src, double factor) {
  if (src.isEmpty) return src;
  final out = <double>[];
  final n = (src.length * factor).round();
  for (int i = 0; i < n; i++) {
    final pos = i / factor;
    final a = pos.floor();
    final b = min(a + 1, src.length - 1);
    final f = pos - a;
    if (a >= src.length) break;
    out.add(src[a] * (1 - f) + src[b] * f);
  }
  return out;
}

/// Reads back one of our own 16-bit mono WAVs, so the pitch variants are
/// generated from exactly the bytes that shipped.
List<double> readWav(String name) {
  final bytes = File('assets/sfx/$name').readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  // Our own writer always emits a 44-byte canonical header.
  const headerBytes = 44;
  final out = <double>[];
  for (int i = headerBytes; i + 1 < bytes.length; i += 2) {
    out.add(data.getInt16(i, Endian.little) / 32767.0);
  }
  return out;
}

/// Effortful "nngh" as the firearm kicks: low nasal grind, falling pitch.
List<double> grunt() {
  const dur = 0.22;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final ph = 2 * pi * (110 * t - 20 * t * t / (2 * dur));
    final s = 0.55 * sin(ph) + 0.30 * sin(2 * ph) + 0.15 * sin(3 * ph);
    out.add(s * env(k, attack: 0.10, release: 0.45) * 0.85);
  }
  return out;
}

/// A mournful "Awww" — a nasal falling glide, longer and sadder than a
/// sharp "ow". [start]/[end] pitch, [dur] length, [vibrato] wobble depth.
List<double> aww({
  required double start,
  required double end,
  required double dur,
  required double vibrato,
}) {
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final f = start + (end - start) * smooth(k) + vibrato * sin(2 * pi * 7 * t);
    // "Aw" timbre: strong fundamental, warm second, small third.
    final s = 0.6 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t) +
        0.1 * sin(2 * pi * 3 * f * t);
    out.add(s * env(k, attack: 0.05, release: 0.35) * 0.9);
  }
  return out;
}

/// A double sob: "aww — aww", the second one weaker and lower.
List<double> doubleAww() {
  const dur = 0.58;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    // Two glide pulses; the second starts lower and trails softer.
    final first = k < 0.52;
    final p = first ? k / 0.52 : (k - 0.55) / 0.45;
    final f = (first ? 270 : 215) - 120 * smooth(p) + 9 * sin(2 * pi * 8 * t);
    final gate = first ? 1.0 : 0.72;
    final s = 0.6 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t) +
        0.1 * sin(2 * pi * 3 * f * t);
    final localEnv = p < 0 ? 0.0 : env(p, attack: 0.08, release: 0.3);
    out.add(s * localEnv * gate * 0.9);
  }
  return out;
}

/// A curious rising "hm?" — the sound of noticing something.
List<double> look() {
  const dur = 0.34;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final f = 150 + 70 * smooth(k);
    final s = 0.55 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t) +
        0.15 * sin(2 * pi * 3 * f * t);
    out.add(s * env(k, attack: 0.15, release: 0.4) * 0.65);
  }
  return out;
}

/// A chirpy little "hup!" as the new firearm swings up into the grip.
List<double> hup() {
  const dur = 0.17;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final f = 195 + 130 * smooth(k);
    final s = 0.55 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t) +
        0.15 * sin(2 * pi * 3 * f * t);
    out.add(s * env(k, attack: 0.05, release: 0.4) * 0.8);
  }
  return out;
}

/// Mechanical slide-clack for the weapon swap: two noise bursts with a
/// metallic ring decaying behind them.
List<double> swapClack() {
  const dur = 0.24;
  final rng = Random(11);
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    var s = 0.0;
    // Slide hiss between the clacks.
    if (t > 0.045 && t < 0.125) {
      s += (rng.nextDouble() * 2 - 1) * 0.18 * sin(pi * (t - 0.045) / 0.08);
    }
    // Two hard clacks, the second the bolt seating home.
    for (final entry in [(0.02, 1.0), (0.135, 0.85)]) {
      final dt = t - entry.$1;
      if (dt >= 0 && dt < 0.05) {
        s += (rng.nextDouble() * 2 - 1) * exp(-dt * 110) * entry.$2;
        s += 0.4 * sin(2 * pi * 820 * t) * exp(-dt * 55) * entry.$2;
      }
    }
    out.add(s * 0.75);
  }
  return out;
}

/// Smug "ha-ha-ha" — three rising-falling pulses.
List<double> laugh() {
  const dur = 0.66;
  const pulses = 3;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final pulse = (k * pulses) % 1;
    final idx = (k * pulses).floor();
    final f = 165 + idx * 14 - 40 * pulse;
    final amp = sin(pi * pulse) * (1 - 0.18 * idx);
    final s = 0.5 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t) +
        0.2 * sin(2 * pi * 2.7 * f * t);
    out.add(s * amp * 0.8);
  }
  return out;
}

/// Long tired "aaahh" — slow slide from awake to asleep.
List<double> yawn() {
  const dur = 1.05;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final f = 235 - 150 * smooth(k) + 6 * sin(2 * pi * 5 * t);
    final s = 0.55 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t) +
        0.15 * sin(2 * pi * 3 * f * t);
    out.add(s * env(k, attack: 0.18, release: 0.3) * 0.75);
  }
  return out;
}

/// Cheery tuneless whistle: pure tone, rising then settling, with vibrato.
List<double> whistle() {
  const dur = 0.72;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final f = k < 0.45
        ? 780 + 720 * smooth(k / 0.45)
        : 1500 - 260 * smooth((k - 0.45) / 0.55);
    final s = sin(2 * pi * f * t + 0.9 * sin(2 * pi * 6.5 * t)) +
        0.06 * sin(2 * pi * 2 * f * t);
    out.add(s * env(k, attack: 0.08, release: 0.25) * 0.55);
  }
  return out;
}

/// Mumbled "brr-mhm-muh" chatter — short tonal blips, wandering pitch.
List<double> chatter() {
  const dur = 0.62;
  final rng = Random(7);
  final blips = List.generate(6, (i) => 105.0 + rng.nextInt(70));
  const blipDur = 0.055;
  const gap = 0.045;
  final out = <double>[];
  var tBlip = 0.0;
  var bi = 0;
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final local = t - tBlip;
    var amp = 0.0;
    var f = 120.0;
    if (bi < blips.length && local >= 0 && local < blipDur) {
      f = blips[bi] + 25 * sin(2 * pi * 11 * local);
      amp = sin(pi * local / blipDur);
      if (local + 1 / sampleRate >= blipDur) {
        bi++;
        tBlip += blipDur + gap;
      }
    }
    final s = 0.5 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t) +
        0.2 * sin(2 * pi * 3 * f * t);
    out.add(s * amp * 0.7);
  }
  return out;
}

/// Thoughtful "hmmm" — rise and fall around a comfortable hum.
List<double> hmm() {
  const dur = 0.52;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final f = 128 + 62 * sin(pi * k);
    final s = 0.55 * sin(2 * pi * f * t) + 0.3 * sin(2 * pi * 2 * f * t) +
        0.15 * sin(2 * pi * 3 * f * t);
    out.add(s * env(k, attack: 0.12, release: 0.35) * 0.7);
  }
  return out;
}

// --- helpers ---------------------------------------------------------------


// ---------------------------------------------------------------------------
// Voices for the wider activity set
// ---------------------------------------------------------------------------
//
// Every clip below is built the same way as the originals — a handful of
// harmonics over a pitch contour, shaped by an envelope — but they all run
// through [voiced], which gives each one a throat rather than a buzzer.
//
// The old blips were pure harmonic stacks: mathematically a vowel, but with
// no resonance, which is what made the crew sound like a synthesiser rather
// than like people. [voiced] adds two formant resonances and a touch of
// breath, which is most of the difference between "beep" and "oi".

/// One resonant band, applied as a simple two-pole ringing filter.
///
/// Cheap on purpose: a proper vocal tract model would be many times the code
/// for a difference nobody would hear through a phone speaker under an
/// explosion. Two of these in parallel is enough to place a vowel.
List<double> _formant(List<double> src, double freq, double q, double gain) {
  final out = List<double>.filled(src.length, 0);
  final w = 2 * pi * freq / sampleRate;
  final r = exp(-w / (2 * q));
  final a1 = 2 * r * cos(w);
  final a2 = -r * r;
  var y1 = 0.0;
  var y2 = 0.0;
  for (int i = 0; i < src.length; i++) {
    final y = src[i] * (1 - r) + a1 * y1 + a2 * y2;
    y2 = y1;
    y1 = y;
    out[i] = y * gain;
  }
  return out;
}

/// Puts a voice behind a raw tone: two formants for the vowel, a little
/// breath for the throat, and a gentle soft-clip so it stays warm rather
/// than harsh when several fire at once.
///
/// [f1]/[f2] pick the vowel — roughly (700, 1150) for "ah", (400, 2000) for
/// "ee", (350, 800) for "oo".
List<double> voiced(
  List<double> tone, {
  double f1 = 700,
  double f2 = 1150,
  double breath = 0.05,
  int seed = 9,
}) {
  final a = _formant(tone, f1, 5.5, 1.35);
  final b = _formant(tone, f2, 7.0, 0.65);
  final rnd = Random(seed);
  final out = List<double>.filled(tone.length, 0);
  for (int i = 0; i < tone.length; i++) {
    final dry = tone[i] * 0.35;
    final air = (rnd.nextDouble() * 2 - 1) * breath * tone[i].abs();
    final s = dry + a[i] + b[i] + air;
    // Soft clip: tanh-ish without the cost of tanh.
    out[i] = s / (1 + s.abs() * 0.55);
  }
  return out;
}

/// A tongue-click "tsk" — a dismissive little noise, mostly transient.
List<double> tsk() {
  const dur = 0.12;
  final out = <double>[];
  final rnd = Random(77);
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    // A sharp burst that dies almost at once, with a short tonal tail.
    final click = (rnd.nextDouble() * 2 - 1) * exp(-k * 42);
    final tail = 0.3 * sin(2 * pi * 420 * t) * exp(-k * 12);
    out.add((click + tail) * 0.7);
  }
  return voiced(out, f1: 520, f2: 1700, breath: 0.12, seed: 3);
}

/// A closed-mouth hum, two notes, contented.
List<double> hum() {
  const dur = 0.62;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final f = (k < 0.5 ? 196.0 : 233.0) + 3 * sin(2 * pi * 5.5 * t);
    // Humming is nearly all fundamental — the mouth is shut.
    final s = 0.7 * sin(2 * pi * f * t) + 0.16 * sin(2 * pi * 2 * f * t);
    out.add(s * env(k, attack: 0.1, release: 0.25) * 0.7);
  }
  // "Mm": a dark, closed vowel.
  return voiced(out, f1: 300, f2: 900, breath: 0.02, seed: 11);
}

/// A sneeze: a sharp intake, a beat, then the burst.
List<double> sneeze() {
  const dur = 0.5;
  final out = <double>[];
  final rnd = Random(1313);
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    double s;
    if (k < 0.34) {
      // The intake: rising breath, barely pitched.
      final u = k / 0.34;
      final noise = (rnd.nextDouble() * 2 - 1) * 0.55;
      s = (noise + 0.25 * sin(2 * pi * (240 + 200 * u) * t)) * u * 0.6;
    } else if (k < 0.42) {
      // The held beat before it goes.
      s = 0;
    } else {
      // The burst: loud, falling, and mostly air.
      final u = (k - 0.42) / 0.58;
      final f = 420 - 260 * smooth(u);
      final noise = (rnd.nextDouble() * 2 - 1) * 0.5;
      s = (0.65 * sin(2 * pi * f * t) + noise) * exp(-u * 4.5);
    }
    out.add(s * 0.9);
  }
  return voiced(out, f1: 760, f2: 1300, breath: 0.16, seed: 5);
}

/// Counting under the breath — four short, flat, muttered syllables.
List<double> count() {
  const dur = 0.72;
  final out = <double>[];
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final t = i / sampleRate;
    final k = t / dur;
    final syl = (k * 4).floor().clamp(0, 3);
    final u = (k * 4) - syl;
    // Each syllable a slightly different pitch, all of them low and bored.
    const notes = [180.0, 196.0, 186.0, 208.0];
    final f = notes[syl];
    final s = 0.5 * sin(2 * pi * f * t) + 0.24 * sin(2 * pi * 2 * f * t);
    // Gate between syllables so they read as separate words.
    final gate = u < 0.62 ? env(u / 0.62, attack: 0.2, release: 0.35) : 0.0;
    out.add(s * gate * 0.62);
  }
  return voiced(out, f1: 480, f2: 1500, breath: 0.06, seed: 21);
}

/// Blowing smoke off the barrel: a short puff of air, no pitch at all.
List<double> blow() {
  const dur = 0.34;
  final out = <double>[];
  final rnd = Random(808);
  var lp = 0.0;
  for (int i = 0; i < (dur * sampleRate).round(); i++) {
    final k = i / (dur * sampleRate);
    // Low-passed noise: a puff rather than a hiss.
    lp += ((rnd.nextDouble() * 2 - 1) - lp) * 0.12;
    out.add(lp * env(k, attack: 0.18, release: 0.55) * 1.6);
  }
  // "Oo": the shape a mouth makes to blow.
  return voiced(out, f1: 340, f2: 820, breath: 0.2, seed: 31);
}
double smooth(double k) {
  final c = k.clamp(0.0, 1.0);
  return c * c * (3 - 2 * c);
}

double env(double k, {required double attack, required double release}) {
  if (k < attack) return k / attack;
  if (k > 1 - release) return max(0.0, (1 - k) / release);
  return 1.0;
}


/// Writes a voice clip at a consistent level.
///
/// Left to themselves the synths came out anywhere from an inaudible click
/// to a clip that ran into the rails for six hundred samples — a factor of
/// eighty in power across the set — because each one is a different shape of
/// maths and nobody was watching the output. A crew whose yelp is drowned by
/// their own hum is not a crew you can hear.
///
/// Peak-normalised first so nothing ever clips, then trimmed further if the
/// clip is still carrying more sustained energy than the rest of the set.
/// Both limits, because peak alone lets a long held tone sit far louder than
/// a short one that reaches the same peak.
void writeVoice(String name, List<double> samples) {
  var peak = 0.0;
  for (final s in samples) {
    if (s.abs() > peak) peak = s.abs();
  }
  if (peak <= 1e-6) {
    writeWav(name, samples);
    return;
  }
  var gain = 0.88 / peak;

  var meanSquare = 0.0;
  for (final s in samples) {
    meanSquare += s * s * gain * gain;
  }
  meanSquare /= samples.length;
  // Ceiling on sustained energy, in mean square. 0.115 is about where the
  // hand-tuned clips already sat, so this pulls the outliers down to the set
  // rather than flattening the set to a new level.
  const ceiling = 0.115;
  if (meanSquare > ceiling) gain *= sqrt(ceiling / meanSquare);

  writeWav(name, [for (final s in samples) s * gain]);
}
void writeWav(String name, List<double> samples) {
  final data = BytesBuilder();
  for (final s in samples) {
    final v = (s.clamp(-1.0, 1.0) * 32767).round();
    data.addByte(v & 0xFF);
    data.addByte((v >> 8) & 0xFF);
  }
  final bytes = data.toBytes();
  final header = BytesBuilder();
  void str(String s) => header.add(s.codeUnits);
  void u32(int v) => header
    ..addByte(v & 0xFF)
    ..addByte((v >> 8) & 0xFF)
    ..addByte((v >> 16) & 0xFF)
    ..addByte((v >> 24) & 0xFF);
  void u16(int v) => header
    ..addByte(v & 0xFF)
    ..addByte((v >> 8) & 0xFF);
  str('RIFF');
  u32(36 + bytes.length);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits per sample
  str('data');
  u32(bytes.length);
  header.add(bytes);
  File('assets/sfx/$name').writeAsBytesSync(header.toBytes());
}
