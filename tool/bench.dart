// A benchmark, not a test: it reaches for the same `@visibleForTesting`
// seams a test would, but lives in tool/ so it never runs with the suite.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/renderer.dart';
import 'package:raft_rumble/game/save.dart';

/// Where the frame time goes.
///
/// Run with: flutter test tool/bench.dart
///
/// Two numbers per scene, because they are spent on different threads and
/// have different fixes:
///
///  * PAINT — building the display list on the UI thread. Every drawRect,
///    every Path, every save/restore. This is what the Dart code costs.
///  * RASTER — turning that display list into pixels. saveLayer, blurs,
///    overdraw and huge paths land here.
///
/// The 60fps budget is 16.7ms for BOTH plus layout, build and the
/// simulation step, so anything over about 6ms in either is a problem.
///
/// Rasterising here is Skia on the CPU, which is slower in absolute terms
/// than a phone's GPU — so read these as RELATIVE costs, and trust the
/// ordering rather than the milliseconds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const size = Size(851, 393);

  GameController match({required MapDef map, int rafts = 2}) {
    SaveService.instance.data = SaveData();
    return GameController(
      settings: MatchSettings(map: map, startHp: 100),
      players: [
        PlayerConfig(
            name: 'P1',
            loadout: RaftLoadout.custom(
                hullId: 'barge', sizeId: 'large', colorIndex: 0)),
        for (int i = 1; i < rafts; i++)
          PlayerConfig(
            name: 'P$i',
            loadout: RaftLoadout.custom(
                hullId: 'barge', sizeId: 'large', colorIndex: i),
            isAi: true,
            aiDifficulty: AiDifficulty.hard,
          ),
      ],
      mode: GameMode.vsAi,
      seed: 7,
    );
  }

  /// Median and p95 of [runs] measurements of [body], in milliseconds.
  (double, double) timeIt(int runs, void Function(int) body) {
    for (int i = 0; i < 12; i++) {
      body(i);
    }
    final ms = <double>[];
    for (int i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      body(i);
      sw.stop();
      ms.add(sw.elapsedMicroseconds / 1000.0);
    }
    ms.sort();
    return (ms[ms.length ~/ 2], ms[(ms.length * 0.95).floor()]);
  }

  String fmt(String label, (double, double) t) =>
      '${label.padRight(30)} med ${t.$1.toStringAsFixed(2)}ms   '
      'p95 ${t.$2.toStringAsFixed(2)}ms'
      '${t.$1 > 6 ? '   <<< OVER BUDGET' : ''}';

  test('layer attribution', () async {
    final map = GameMaps.all.first;
    final ctrl = match(map: map);
    ctrl.skipIntro();
    final renderer = WorldRenderer(ctrl.world, map: map);
    for (int i = 0; i < 120; i++) {
      ctrl.stepForTest(1 / 60);
    }

    double rasterMs(Set<String> skip) {
      renderer.skipLayers = skip;
      ui.Picture? p;
      timeIt(6, (i) {
        final rec = ui.PictureRecorder();
        renderer.render(Canvas(rec), size, i / 60.0,
            currentPlayer: 0, isAiming: true, aimAngleDeg: 45);
        p = rec.endRecording();
      });
      final t = timeIt(20, (_) {
        p!.toImageSync(size.width.round(), size.height.round()).dispose();
      });
      return t.$1;
    }

    double paintMs(Set<String> skip) {
      renderer.skipLayers = skip;
      final t = timeIt(40, (i) {
        final rec = ui.PictureRecorder();
        renderer.render(Canvas(rec), size, i / 60.0,
            currentPlayer: 0, isAiming: true, aimAngleDeg: 45);
        rec.endRecording();
      });
      return t.$1;
    }

    const layers = [
      'sky',
      'clouds',
      'props',
      'water',
      'obstacles',
      'rafts',
      'effects'
    ];
    final fullR = rasterMs(const {});
    final fullP = paintMs(const {});
    final out = StringBuffer(
        'full scene: raster ${fullR.toStringAsFixed(2)}ms  '
        'paint ${fullP.toStringAsFixed(2)}ms\n');
    for (final layer in layers) {
      final r = rasterMs({layer});
      final p = paintMs({layer});
      out.writeln('  ${layer.padRight(10)}'
          ' raster ${(fullR - r).toStringAsFixed(2)}ms'
          '   paint ${(fullP - p).toStringAsFixed(2)}ms');
    }
    renderer.skipLayers = const {};
    // ignore: avoid_print
    print(out);
    ctrl.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('frame cost', () async {
    final out = StringBuffer();

    for (final map in GameMaps.all) {
      final ctrl = match(map: map);
      ctrl.skipIntro();
      final renderer = WorldRenderer(ctrl.world, map: map);
      for (int i = 0; i < 120; i++) {
        ctrl.stepForTest(1 / 60);
      }

      ui.Picture? last;
      final paint = timeIt(60, (i) {
        final rec = ui.PictureRecorder();
        renderer.render(Canvas(rec), size, i / 60.0,
            currentPlayer: 0, isAiming: true, aimAngleDeg: 45);
        last = rec.endRecording();
      });
      final raster = timeIt(30, (_) {
        last!.toImageSync(size.width.round(), size.height.round()).dispose();
      });
      final sim = timeIt(120, (_) => ctrl.stepForTest(1 / 60));

      out.writeln('--- ${map.id} ---');
      out.writeln(fmt('  paint', paint));
      out.writeln(fmt('  raster', raster));
      out.writeln(fmt('  simulate', sim));
      ctrl.dispose();
    }

    // ignore: avoid_print
    print(out);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
