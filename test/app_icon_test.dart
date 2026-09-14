import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/app_icon.dart';
import 'package:raft_rumble/game/characters.dart';

/// The launcher icon.
///
/// Worth testing because nothing else looks at it. An icon is wrong on a
/// phone's home screen and right in every screenshot of the game, so the
/// faults it had lasted: one 192px file copied into all five density
/// buckets, a sticker outline with clear corners that launcher masks cut
/// through, and no adaptive icon at all, which on Android 8 and up is the
/// only kind that gets drawn properly.
///
/// The checks here are the ones a person cannot make by glancing at it:
/// pixel sizes per bucket, and whether the art stays inside the circle
/// Android actually guarantees to show.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const res = 'android/app/src/main/res';

  /// Width and height straight out of a PNG's IHDR, without decoding it.
  (int, int) pngSize(String path) {
    final b = File(path).readAsBytesSync();
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return (d.getUint32(16), d.getUint32(20));
  }

  Future<ui.Image> raster(
      int size, void Function(Canvas, double) paint) async {
    final rec = ui.PictureRecorder();
    paint(Canvas(rec), size.toDouble());
    return rec.endRecording().toImage(size, size);
  }

  group('The icon ships at the right size in every bucket', () {
    // The original fault, and the one most likely to come back: a single
    // 192px file copied everywhere. Android scales it, so it LOOKS fine —
    // it is just four times the bytes it should be on most devices, and
    // blurry on the one bucket it is smaller than.
    const legacy = {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    };
    const adaptive = {
      'mdpi': 108,
      'hdpi': 162,
      'xhdpi': 216,
      'xxhdpi': 324,
      'xxxhdpi': 432,
    };

    test('legacy and round icons', () {
      for (final e in legacy.entries) {
        for (final name in ['ic_launcher', 'ic_launcher_round']) {
          final path = '$res/mipmap-${e.key}/$name.png';
          expect(File(path).existsSync(), true, reason: '$path is missing');
          expect(pngSize(path), (e.value, e.value),
              reason: '$path should be ${e.value}px square for ${e.key}');
        }
      }
    });

    test('adaptive foregrounds, which are 108dp not 48dp', () {
      for (final e in adaptive.entries) {
        final path = '$res/mipmap-${e.key}/ic_launcher_foreground.png';
        expect(File(path).existsSync(), true, reason: '$path is missing');
        expect(pngSize(path), (e.value, e.value),
            reason: '$path should be ${e.value}px square for ${e.key}');
      }
    });

    test('the adaptive descriptors exist and point at both layers', () {
      for (final name in ['ic_launcher', 'ic_launcher_round']) {
        final f = File('$res/mipmap-anydpi-v26/$name.xml');
        expect(f.existsSync(), true,
            reason: '$name has no adaptive icon, so Android 8+ falls back to '
                'the legacy bitmap in a grey shim');
        final xml = f.readAsStringSync();
        expect(xml, contains('@mipmap/ic_launcher_foreground'));
        expect(xml, contains('@color/ic_launcher_background'));
      }
      expect(
          File('$res/values/ic_launcher_background.xml').readAsStringSync(),
          contains('ic_launcher_background'),
          reason: 'the adaptive background colour the descriptors reference '
              'is not defined, so the build fails');
    });
  });

  group('It survives what a launcher does to it', () {
    test('the art stays inside the circle Android guarantees to show',
        () async {
      // Android composites the foreground on a 108dp canvas and promises
      // only the central 66dp circle survives every OEM mask. Art outside
      // that is a coin toss per device.
      const size = 216;
      final img = await raster(size, AppIcon.paintAdaptiveForeground);
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final px = data!.buffer.asUint8List();

      const safe = 66 / 108;
      final rSafe = size * safe / 2;
      final centre = Offset(size / 2, size / 2);
      var outside = 0;
      var drawn = 0;
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          final a = px[(y * size + x) * 4 + 3];
          if (a < 24) continue;
          drawn++;
          if ((Offset(x + 0.5, y + 0.5) - centre).distance > rSafe) outside++;
        }
      }
      expect(drawn, greaterThan(size * size ~/ 12),
          reason: 'the adaptive foreground is nearly empty');
      expect(outside, 0,
          reason: '$outside painted pixels fall outside the 66dp safe circle, '
              'so some launchers will crop them');
    });

    test('the legacy icon fills its tile instead of floating in it',
        () async {
      // The old one was a sticker: art in the middle, clear pixels around
      // it, so a circular mask cut through empty space and left the picture
      // sitting in a notch.
      const size = 192;
      final img = await raster(size, AppIcon.paintLegacy);
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final px = data!.buffer.asUint8List();

      int alphaAt(int x, int y) => px[(y * size + x) * 4 + 3];

      // Solid across the whole middle band, edge to edge: this is what
      // "full bleed" means and what a sticker fails.
      for (final y in [size ~/ 3, size ~/ 2, size * 2 ~/ 3]) {
        for (int x = 2; x < size - 2; x++) {
          expect(alphaAt(x, y), 255,
              reason: 'a hole at ($x,$y) — the icon is not full bleed');
        }
      }
      // Corners are clear, because the tile draws its own rounded shape.
      expect(alphaAt(1, 1), lessThan(40),
          reason: 'the rounded corner is filled, so the tile will look '
              'square inside a rounded mask');
    });
  });

  group('It reads as this game', () {
    test('the character wears something', () {
      // A bare head at 48px is a circle with two dots, which is every other
      // app on the home screen. The hat IS the silhouette.
      expect(Cast.of(AppIcon.look).gear, isNot(HeadGear.none),
          reason: 'the icon character has no headgear, so the tile is an '
              'anonymous smiley');
    });

    test('it is drawn from the roster, not from a copy of it', () {
      // The reason this is code and not a PNG somebody exported: the icon
      // takes its colours from the same [CharacterDef] the battle does, so
      // a change to that character reaches the icon by regenerating rather
      // than by remembering.
      final ch = Cast.of(AppIcon.look);
      expect(ch.playable, true,
          reason: 'the icon wears a character the player can never be');
      expect(ch.skin, isNot(ch.outfit));
    });

    test('small sizes keep more than one colour', () async {
      // The legibility floor. If the 48px tile collapses towards a single
      // average colour it has become a blob, whatever it looks like large.
      final img = await raster(48, AppIcon.paintLegacy);
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final px = data!.buffer.asUint8List();
      final seen = <int>{};
      for (int i = 0; i < 48 * 48; i++) {
        // Quantised hard, so near-identical shades count once.
        seen.add((px[i * 4] >> 5) << 10 |
            (px[i * 4 + 1] >> 5) << 5 |
            (px[i * 4 + 2] >> 5));
      }
      expect(seen.length, greaterThan(8),
          reason: 'at 48px the icon has collapsed to ${seen.length} distinct '
              'tones — it will read as a coloured square');

      // And the darkest and lightest are genuinely far apart, which is what
      // makes a silhouette visible against a wallpaper.
      var lo = 255, hi = 0;
      for (int i = 0; i < 48 * 48; i++) {
        final l = (px[i * 4] * 0.299 + px[i * 4 + 1] * 0.587 + px[i * 4 + 2] * 0.114)
            .round();
        lo = min(lo, l);
        hi = max(hi, l);
      }
      expect(hi - lo, greaterThan(120),
          reason: 'the icon has no contrast range, so nothing in it reads');
    });
  });
}
