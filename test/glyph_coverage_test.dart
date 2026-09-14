import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every character the UI prints exists in the font it prints with.
///
/// This became possible to get wrong the moment the typefaces started
/// shipping with the app. While google_fonts was fetching Baloo 2 over the
/// network — and usually failing — every label fell back to a system font
/// with the whole of the Geometric Shapes block in it, so `▾` `▴` `▸` `◉`
/// and `★` all drew. Once the real fonts loaded, those became whatever the
/// platform happened to substitute, which is not the same on Android, on
/// the web and on desktop, and on a stripped system is a tofu box.
///
/// Measured: Baloo 2 has U+25C0 and U+25B6 (the walk pads) and nothing else
/// from that block; Nunito has none of it. The marks that are missing are
/// drawn as Material icons now, which ship with the app.
///
/// The check is a width comparison against a codepoint no font has. A
/// missing glyph falls back to the same box, so it comes out the same width.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    for (final family in ['Baloo2', 'Nunito']) {
      final loader = FontLoader(family);
      for (final weight in ['SemiBold', 'Bold', 'ExtraBold']) {
        final bytes =
            File('assets/fonts/$family-$weight.ttf').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
  });

  double widthOf(String s, String family) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: TextStyle(fontFamily: family, fontSize: 40)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  /// U+E123 is in a private use area: nothing has it, so its width is the
  /// width of the fallback box.
  bool missing(String glyph, String family) =>
      (widthOf(glyph, family) - widthOf('\u{E123}', family)).abs() < 0.01;

  group('The fonts can draw what the UI asks them to', () {
    test('the marks still used in text are all present', () {
      // Punctuation the copy genuinely relies on, plus the two triangles the
      // walk pads use — which Baloo 2 does have, and which is why they were
      // left as text.
      const inBaloo = {
        'em dash U+2014': '—',
        'ellipsis U+2026': '…',
        'middle dot U+00B7': '·',
        'minus U+2212': '−',
        'degree U+00B0': '°',
        'multiply U+00D7': '×',
        'infinity U+221E': '∞',
        'left triangle U+25C0': '◀',
        'right triangle U+25B6': '▶',
      };
      for (final e in inBaloo.entries) {
        expect(missing(e.value, 'Baloo2'), false,
            reason: 'Baloo 2 cannot draw ${e.key}, which the UI prints');
      }

      const inNunito = {
        'em dash U+2014': '—',
        'ellipsis U+2026': '…',
        'middle dot U+00B7': '·',
        'degree U+00B0': '°',
        'multiply U+00D7': '×',
        'infinity U+221E': '∞',
      };
      for (final e in inNunito.entries) {
        expect(missing(e.value, 'Nunito'), false,
            reason: 'Nunito cannot draw ${e.key}, which the UI prints');
      }
    });

    test('the marks that are missing are no longer printed anywhere', () {
      // The other half: knowing a glyph is absent is only useful if nothing
      // is still trying to draw it. These are the five that were.
      const absent = {
        '▾': 'small down triangle',
        '▴': 'small up triangle',
        '▸': 'small right triangle',
        '◉': 'fisheye (the coin)',
        '★': 'black star',
      };
      for (final e in absent.entries) {
        expect(missing(e.key, 'Baloo2') || missing(e.key, 'Nunito'), true,
            reason: 'the premise has changed: ${e.value} is now available, '
                'so this test is guarding nothing');
      }

      final offenders = <String>[];
      for (final dir in ['lib']) {
        for (final f in Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
          final src = f.readAsStringSync();
          for (final line in src.split('\n')) {
            // Prose in comments is fine; it is never drawn.
            final code = line.trimLeft();
            if (code.startsWith('//') || code.startsWith('///')) continue;
            for (final e in absent.entries) {
              if (line.contains(e.key)) {
                offenders.add('${f.path}: ${e.value}');
              }
            }
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'these print a character the bundled fonts cannot draw, so '
              'it is left to whatever the platform substitutes:\n'
              '${offenders.join('\n')}');
    });
  });
}
