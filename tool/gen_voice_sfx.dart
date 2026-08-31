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

const int sampleRate = 22050;

void main() {
  Directory('assets/sfx').createSync(recursive: true);
  writeWav('voice_grunt.wav', grunt());
  // Four "Awww" variations — every hit yelp is a little different.
  writeWav('voice_ouch1.wav', aww(start: 260, end: 140, dur: 0.45, vibrato: 8));
  writeWav('voice_ouch2.wav', aww(start: 325, end: 195, dur: 0.38, vibrato: 13));
  writeWav('voice_ouch3.wav', aww(start: 200, end: 105, dur: 0.62, vibrato: 6));
  writeWav('voice_ouch4.wav', doubleAww());
  writeWav('voice_laugh.wav', laugh());
  writeWav('voice_yawn.wav', yawn());
  writeWav('voice_whistle.wav', whistle());
  writeWav('voice_chatter.wav', chatter());
  writeWav('voice_hmm.wav', hmm());
  writeWav('voice_look.wav', look());
  writeWav('voice_swap.wav', hup());
  writeWav('swap.wav', swapClack());
  stdout.writeln('voice blips written to assets/sfx/');
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

double smooth(double k) {
  final c = k.clamp(0.0, 1.0);
  return c * c * (3 - 2 * c);
}

double env(double k, {required double attack, required double release}) {
  if (k < attack) return k / attack;
  if (k > 1 - release) return max(0.0, (1 - k) / release);
  return 1.0;
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
