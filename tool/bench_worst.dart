// A benchmark, not a test: it reaches for the same `@visibleForTesting`
// seams a test would, but lives in tool/ so it never runs with the suite.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/renderer.dart';
import 'package:raft_rumble/game/save.dart';

/// The frames that actually drop.
///
/// Steady state was never the problem — an idle scene paints in under 2ms.
/// A frame rate falls over on the busy frames, and those are rare enough
/// that an average hides them completely. So this builds the heaviest scene
/// the game can legally produce — every raft slot filled, every berth
/// crewed, a volley of explosives landing at once — and times every frame
/// of the aftermath.
///
/// The first frames are discarded: a cold renderer pays for decor building,
/// gradient construction and JIT, and none of that recurs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const size = Size(851, 393);

  (GameController, WorldRenderer) heavy(MapDef map) {
    SaveService.instance.data = SaveData();
    final ctrl = GameController(
      settings: MatchSettings(map: map, startHp: 100),
      players: [
        PlayerConfig(
            name: 'P1',
            loadout: RaftLoadout.custom(
                hullId: 'barge', sizeId: 'large', colorIndex: 0)),
        // Every enemy slot the battle supports, each on the widest hull with
        // a full crew.
        for (int i = 0; i < BattleConst.enemySlots.length; i++)
          PlayerConfig(
            name: 'E$i',
            loadout: RaftLoadout.custom(
                hullId: 'barge', sizeId: 'large', colorIndex: i + 1),
            isAi: true,
            aiDifficulty: AiDifficulty.hard,
          ),
      ],
      mode: GameMode.vsAi,
      seed: 5,
    );
    ctrl.skipIntro();
    return (ctrl, WorldRenderer(ctrl.world, map: map));
  }

  String pct(List<double> v, double q) {
    final s = [...v]..sort();
    return s[(s.length * q).clamp(0, s.length - 1).toInt()].toStringAsFixed(2);
  }

  test('the heaviest scene the game can make', () async {
    final map = GameMaps.all.first;
    final (ctrl, renderer) = heavy(map);

    void frame(int i) {
      final rec = ui.PictureRecorder();
      renderer.render(Canvas(rec), size, i / 60.0,
          currentPlayer: 0, isAiming: true, aimAngleDeg: 45);
      rec.endRecording().toImageSync(
          size.width.round(), size.height.round())
        ..dispose();
    }

    // Warm up cold caches, then settle the world.
    for (int i = 0; i < 20; i++) {
      ctrl.stepForTest(1 / 60);
      frame(i);
    }

    final crew = ctrl.world.rafts.expand((r) => r.crew).toList();
    // ignore: avoid_print
    print('scene: ${ctrl.world.rafts.length} rafts, ${crew.length} crew');

    // Kill everyone on the far side at once and light the place up: the
    // worst frame in any match is the one right after a volley lands.
    for (final r in ctrl.world.rafts) {
      if (r.playerIndex == 0) continue;
      for (final c in r.crew) {
        c.hp = 0;
      }
    }
    // The full explosive show at every one of them at once: boom, shock
    // ring, fireball and a scatter of sparks, which is what a landed volley
    // actually puts on screen.
    for (final r in ctrl.world.rafts.where((r) => r.playerIndex != 0)) {
      final at = Offset(r.x, r.deckY - 20);
      const hot = Color(0xFFFFC966);
      ctrl.world.effects
        ..add(Fx(pos: at, kind: 'boom', color: hot, size: 90, life: 0.55))
        ..add(Fx(pos: at, kind: 'shock', color: hot, size: 130, life: 0.5))
        ..add(Fx(pos: at, kind: 'fire', color: hot, size: 60, life: 0.32));
      for (int k = 0; k < 5; k++) {
        ctrl.world.effects.add(Fx(
            pos: at + Offset(k * 8.0 - 16, 0),
            kind: 'spark',
            color: hot,
            size: 10,
            life: 0.4));
      }
    }

    final paints = <double>[];
    final rasters = <double>[];
    var peakLayers = 0, peakFx = 0, peakRagdolls = 0;

    for (int i = 0; i < 400; i++) {
      ctrl.stepForTest(1 / 60);
      renderer.bodyLayers = 0;

      final sw = Stopwatch()..start();
      final rec = ui.PictureRecorder();
      renderer.render(Canvas(rec), size, i / 60.0,
          currentPlayer: 0, isAiming: true, aimAngleDeg: 45);
      final pic = rec.endRecording();
      sw.stop();

      final sw2 = Stopwatch()..start();
      pic.toImageSync(size.width.round(), size.height.round()).dispose();
      sw2.stop();

      paints.add(sw.elapsedMicroseconds / 1000.0);
      rasters.add(sw2.elapsedMicroseconds / 1000.0);
      if (renderer.bodyLayers > peakLayers) peakLayers = renderer.bodyLayers;
      if (ctrl.world.effects.length > peakFx) {
        peakFx = ctrl.world.effects.length;
      }
      final rag = crew.where((c) => c.pose != null).length;
      if (rag > peakRagdolls) peakRagdolls = rag;
    }

    final total = [
      for (int i = 0; i < paints.length; i++) paints[i] + rasters[i]
    ];
    // ignore: avoid_print
    print('''
peak: fx=$peakFx ragdolls=$peakRagdolls saveLayers=$peakLayers

paint   med ${pct(paints, .5)}  p95 ${pct(paints, .95)}  max ${pct(paints, 1)}
raster  med ${pct(rasters, .5)}  p95 ${pct(rasters, .95)}  max ${pct(rasters, 1)}
total   med ${pct(total, .5)}  p95 ${pct(total, .95)}  max ${pct(total, 1)}

frames over 16.7ms: ${total.where((v) => v > 16.7).length} of ${total.length}
''');
    ctrl.dispose();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
