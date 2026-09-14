import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/build.dart';
import 'package:raft_rumble/game/campaign.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/renderer.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/game_screen.dart';

/// That the world is actually on the screen.
///
/// It stopped being, after a build. Setting sail left the whole match a flat
/// teal void with a working HUD floating on it, and the cause was two
/// separate faults compounding:
///
///  1. The battle [Stack] took its size from its children. During the build
///     phase every child in it is [Positioned] — the scene and the build
///     overlay are both `Positioned.fill`, and the HUD is held back so it
///     cannot cover the raft being edited — and a Stack with nothing but
///     positioned children collapses. When the HUD came back at SET SAIL the
///     stack measured 0x0.
///  2. The renderer divided by that. `viewWidth` is `size.width / scale`
///     with `scale` proportional to the height, so a zero-sized paint is
///     `0 / 0`. The NaN went straight onto the world, the camera clamp
///     picked it up, and every frame after it was NaN — nothing divides its
///     way back to a real number, so the match never recovered.
///
/// Both are fixed, and both are tested: the stack fills on its own account,
/// and the renderer refuses a degenerate canvas instead of dividing by it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const phone = Size(851, 393);

  Future<GameController> openCampaign(WidgetTester tester,
      {required bool build}) async {
    SaveService.instance.data = SaveData()..buildOwnRaft = build;
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final level = Campaign.worlds.first.levels.first;
    final (settings, players) = Campaign.matchFor(level);
    final ctrl = GameController(
        settings: settings, players: players, mode: GameMode.vsAi, seed: 7);
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(
        settings: settings,
        players: players,
        mode: GameMode.vsAi,
        controller: ctrl,
      ),
    ));
    await tester.pump();
    if (ctrl.inIntro) ctrl.skipIntro();
    await tester.pump(const Duration(milliseconds: 16));
    return ctrl;
  }

  /// The size the scene is actually being painted at — found by its painter
  /// rather than by position, because the HUD contains CustomPaints too.
  Size sceneSize(WidgetTester tester) {
    for (final el in find.byType(CustomPaint).evaluate()) {
      final w = el.widget as CustomPaint;
      if (!w.painter.runtimeType.toString().contains('Scene')) continue;
      return (el.findRenderObject() as RenderBox).size;
    }
    return Size.zero;
  }

  group('The world survives the build phase', () {
    testWidgets('the scene fills the screen after SET SAIL', (tester) async {
      final ctrl = await openCampaign(tester, build: true);
      expect(ctrl.buildPhase, true, reason: 'the build phase never started');
      expect(sceneSize(tester), phone,
          reason: 'the scene was already collapsed during the build');

      final plan = ctrl.editingPlan!;
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          plan.set(c, r, null);
        }
      }
      plan.set(4, 0, BuildMaterial.plank);
      await tester.pump();

      await tester.tap(find.text('SET SAIL'));
      await tester.pump();

      expect(sceneSize(tester), phone,
          reason: 'the scene collapsed to ${sceneSize(tester)} when the HUD '
              'came back — the match is a blank void');
      ctrl.dispose();
    });

    testWidgets('the camera stays a real number', (tester) async {
      // The symptom that made it unrecoverable rather than merely ugly.
      final ctrl = await openCampaign(tester, build: true);
      final plan = ctrl.editingPlan!;
      plan.set(4, 0, BuildMaterial.plank);
      await tester.pump();
      await tester.tap(find.text('SET SAIL'));
      await tester.pump();

      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(ctrl.world.cam.isFinite, true,
            reason: 'the camera went NaN on frame $i after setting sail');
        expect(ctrl.world.viewWidth.isFinite, true,
            reason: 'viewWidth went NaN on frame $i');
      }
      ctrl.dispose();
    });

    testWidgets('a match with no build phase is unaffected', (tester) async {
      final ctrl = await openCampaign(tester, build: false);
      expect(ctrl.buildPhase, false);
      expect(sceneSize(tester), phone);
      ctrl.dispose();
    });
  });

  group('A degenerate canvas cannot poison the world', () {
    test('rendering into nothing leaves the camera alone', () {
      // Layout can hand over a zero size for a frame during a route
      // transition. That must cost a frame, not the match.
      SaveService.instance.data = SaveData();
      final map = GameMaps.all.first;
      final ctrl = GameController(
        settings: MatchSettings(map: map, startHp: 100),
        players: [
          PlayerConfig(
              name: 'P1',
              loadout: RaftLoadout.custom(
                  hullId: 'log', sizeId: 'medium', colorIndex: 0)),
          PlayerConfig(
            name: 'P2',
            loadout: RaftLoadout.custom(
                hullId: 'log', sizeId: 'medium', colorIndex: 1),
            isAi: true,
            aiDifficulty: AiDifficulty.easy,
          ),
        ],
        mode: GameMode.vsAi,
        seed: 3,
      );
      ctrl.skipIntro();
      final r = WorldRenderer(ctrl.world, map: map);

      void paint(Size size) {
        final rec = ui.PictureRecorder();
        r.render(Canvas(rec), size, 1.0);
        rec.endRecording().dispose();
      }

      paint(phone);
      final goodWidth = ctrl.world.viewWidth;
      expect(goodWidth.isFinite, true);

      for (final bad in [Size.zero, const Size(851, 0), const Size(0, 393)]) {
        paint(bad);
        expect(ctrl.world.viewWidth, goodWidth,
            reason: 'painting at $bad rewrote viewWidth');
        expect(ctrl.world.viewWidth.isFinite, true);
      }

      // And the world still works afterwards.
      ctrl.stepForTest(1 / 60);
      expect(ctrl.world.cam.isFinite, true);
      paint(phone);
      expect(ctrl.world.viewWidth.isFinite, true);
      ctrl.dispose();
    });
  });
}
