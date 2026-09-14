import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/theme.dart';

/// The typefaces ship with the app.
///
/// They used to be fetched. `google_fonts` pulled Baloo 2 and Nunito from
/// fonts.gstatic.com the first time each weight was asked for, which meant:
/// an HTTP round trip during the first frames that draw text, every label
/// re-laying out when it landed, and — on a device with no internet — a game
/// permanently in the fallback typeface. A raft game whose headline feature
/// is a hotspot match between two phones has no business needing a web
/// server to render its own buttons.
///
/// It showed up in this suite too: five test files had to disable runtime
/// fetching, and one had to swallow the resulting exception, before any of
/// them could render a frame. All of that is gone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Each family and the weights the app actually asks for.
  const families = {
    'Baloo2': ['SemiBold', 'Bold', 'ExtraBold'],
    'Nunito': ['SemiBold', 'Bold', 'ExtraBold'],
  };

  group('The fonts are on disk, not on a CDN', () {
    test('every declared file exists and is a real TrueType font', () {
      for (final e in families.entries) {
        for (final weight in e.value) {
          final path = 'assets/fonts/${e.key}-$weight.ttf';
          final file = File(path);
          expect(file.existsSync(), true, reason: '$path is missing');

          final bytes = file.readAsBytesSync();
          expect(bytes.length, greaterThan(20000),
              reason: '$path is too small to be a font — a failed download '
                  'leaves an error page behind at about this size');
          // sfnt version 0x00010000, which is what a .ttf starts with.
          expect([bytes[0], bytes[1], bytes[2], bytes[3]], [0, 1, 0, 0],
              reason: '$path does not begin with the TrueType magic, so it '
                  'is not the file it claims to be');
        }
      }
    });

    test('the pubspec declares them, with the weights the app uses', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final e in families.entries) {
        expect(pubspec, contains('family: ${e.key}'),
            reason: '${e.key} is not declared, so the asset is shipped but '
                'never registered and every label falls back');
        for (final weight in e.value) {
          expect(pubspec, contains('assets/fonts/${e.key}-$weight.ttf'));
        }
      }
      // The app asks for w600, w700, w800 and w900. Flutter resolves w900 to
      // the nearest available face, so 600/700/800 covers the set.
      for (final w in ['600', '700', '800']) {
        expect(pubspec, contains('weight: $w'));
      }
    });

    test('nothing reaches for the network font package any more', () {
      // Matched as a dependency line, not as a word: the pubspec explains
      // in a comment why the package is gone, and that comment naming it is
      // the point rather than a relapse.
      final declared = File('pubspec.yaml')
          .readAsLinesSync()
          .any((l) => RegExp(r'^\s+google_fonts\s*:').hasMatch(l));
      expect(declared, false,
          reason: 'the dependency is back, and with it the runtime fetch');

      // Assembled rather than written out, so this file does not match
      // itself while looking for calls in every other one.
      final call = '${'Google'}${'Fonts'}.';
      for (final dir in ['lib', 'test']) {
        for (final f in Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) =>
                f.path.endsWith('.dart') &&
                !f.path.endsWith('fonts_bundled_test.dart'))) {
          expect(f.readAsStringSync().contains(call), false,
              reason: '${f.path} still calls into google_fonts');
        }
      }
    });
  });

  group('The styles name the bundled families', () {
    test('chunky is Baloo 2 and body is Nunito', () {
      // Without a family a TextStyle silently uses the platform default,
      // which is exactly what the fetch failure used to produce — and it
      // looks fine enough that nobody notices for a while.
      expect(RT.chunky(size: 18).fontFamily, 'Baloo2');
      expect(RT.body(size: 12).fontFamily, 'Nunito');
    });

    test('they still carry the weights the design asks for', () {
      expect(RT.chunky(size: 18).fontWeight, FontWeight.w800);
      expect(RT.body(size: 12).fontWeight, FontWeight.w700);
      expect(RT.chunky(size: 18, weight: FontWeight.w600).fontWeight,
          FontWeight.w600);
    });

    testWidgets('a label renders without asking the network for anything',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('RAFT RUMBLE', style: RT.chunky(size: 32, outline: 3)),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'rendering one label threw — the old failure mode was a '
              'fetch exception surfacing during paint');
      expect(find.text('RAFT RUMBLE'), findsOneWidget);
    });
  });
}
