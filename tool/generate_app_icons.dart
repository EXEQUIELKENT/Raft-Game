import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/app_icon.dart';

/// Writes the Android launcher icons from [AppIcon].
///
/// Run it with:
///
///     flutter test tool/generate_app_icons.dart
///
/// It lives under `tool/` rather than `test/` on purpose: it WRITES to the
/// android resource tree, and something that rewrites checked-in files has
/// no business running on every `flutter test`. The matching check in
/// `test/app_icon_test.dart` is the part that runs with the suite.
///
/// It is a `flutter_test` file because rasterising needs a live engine —
/// `Picture.toImage` is not available from a plain Dart entrypoint.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Density buckets and the pixel size of a 48dp launcher icon in each.
  const legacy = <String, int>{
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  /// Adaptive icons are 108dp, so the foreground is 2.25x the legacy size.
  const adaptive = <String, int>{
    'mdpi': 108,
    'hdpi': 162,
    'xhdpi': 216,
    'xxhdpi': 324,
    'xxxhdpi': 432,
  };

  Future<void> write(
      String path, int size, void Function(Canvas, double) paint) async {
    final rec = ui.PictureRecorder();
    paint(Canvas(rec), size.toDouble());
    final img = await rec.endRecording().toImage(size, size);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path)..createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('wrote $path (${size}px, ${bytes.lengthInBytes ~/ 1024}kb)');
  }

  test('generate', () async {
    const res = 'android/app/src/main/res';

    for (final e in legacy.entries) {
      await write('$res/mipmap-${e.key}/ic_launcher.png', e.value,
          (c, s) => AppIcon.paintLegacy(c, s));
      await write('$res/mipmap-${e.key}/ic_launcher_round.png', e.value,
          (c, s) => AppIcon.paintRound(c, s));
    }
    for (final e in adaptive.entries) {
      await write('$res/mipmap-${e.key}/ic_launcher_foreground.png', e.value,
          (c, s) => AppIcon.paintAdaptiveForeground(c, s));
    }

    // The adaptive icon descriptors, and the background colour they point at.
    const bg = AppIcon.adaptiveBackground;
    final hex = bg.value.toRadixString(16).padLeft(8, '0').toUpperCase();
    File('$res/values/ic_launcher_background.xml')
      ..createSync(recursive: true)
      ..writeAsStringSync('<?xml version="1.0" encoding="utf-8"?>\n'
          '<resources>\n'
          '    <color name="ic_launcher_background">#$hex</color>\n'
          '</resources>\n');

    const xml = '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '</adaptive-icon>\n';
    for (final name in ['ic_launcher', 'ic_launcher_round']) {
      File('$res/mipmap-anydpi-v26/$name.xml')
        ..createSync(recursive: true)
        ..writeAsStringSync(xml);
    }
    // ignore: avoid_print
    print('wrote adaptive-icon descriptors');
  });
}
