// A benchmark, not a test: it reaches for the same `@visibleForTesting`
// seams a test would, but lives in tool/ so it never runs with the suite.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/game_screen.dart';
import 'package:raft_rumble/theme.dart';

/// The whole UI thread frame, not just the scene.
///
/// `tool/bench.dart` times the scene painter in isolation. That leaves out
/// everything Flutter does around it — rebuilding the widget tree, laying it
/// out, and painting the HUD on top — and all of that lands on the same
/// thread and the same 16.7ms budget. A game can have a cheap painter and
/// still miss frames because the tree above it rebuilds too much.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String pct(List<double> v, double q) {
    final s = [...v]..sort();
    return s[(s.length * q).clamp(0, s.length - 1).toInt()].toStringAsFixed(2);
  }

  testWidgets('a whole frame, tree and all', (tester) async {
    SaveService.instance.data = SaveData();
    tester.view.physicalSize = const Size(851, 393);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100),
      players: [
        PlayerConfig(
            name: 'P1',
            loadout: RaftLoadout.custom(
                hullId: 'barge', sizeId: 'large', colorIndex: 0)),
        PlayerConfig(
          name: 'P2',
          loadout: RaftLoadout.custom(
              hullId: 'barge', sizeId: 'large', colorIndex: 1),
          isAi: true,
          aiDifficulty: AiDifficulty.hard,
        ),
      ],
      mode: GameMode.vsAi,
      seed: 7,
    );

    await tester.pumpWidget(MaterialApp(
      home: GameScreen(
        settings: ctrl.settings,
        players: ctrl.players,
        mode: GameMode.vsAi,
        controller: ctrl,
      ),
    ));
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final frames = <double>[];
    for (int i = 0; i < 300; i++) {
      final sw = Stopwatch()..start();
      await tester.pump(const Duration(microseconds: 16667));
      sw.stop();
      frames.add(sw.elapsedMicroseconds / 1000.0);
    }

    // And the text styles, which every HUD rebuild constructs from scratch.
    final sw = Stopwatch()..start();
    for (int i = 0; i < 2000; i++) {
      RT.chunky(size: 16, outline: 3);
      RT.body(size: 11);
    }
    sw.stop();

    // ignore: avoid_print
    print('''
full UI frame (build + layout + paint, HUD included)
  med ${pct(frames, .5)}ms  p95 ${pct(frames, .95)}ms  p99 ${pct(frames, .99)}ms  max ${pct(frames, 1)}ms
  over 16.7ms: ${frames.where((v) => v > 16.7).length} of ${frames.length}

RT.chunky + RT.body x2000: ${sw.elapsedMilliseconds}ms
  (${(sw.elapsedMicroseconds / 2000).toStringAsFixed(1)}us per pair)
''');
    ctrl.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
