import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/build.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/game_screen.dart';

/// Building on the raft itself, rather than on a diagram of it.
///
/// The build screen used to put a grid panel in the middle of the water and
/// leave the whole battle HUD drawn on top of the overlay — a health bar
/// across the title, walk arrows under the palette, a FIRE button for a turn
/// that had not started. Two pictures of the same raft, and a stray tap
/// could drive the match instead of the deck.
///
/// So what is asserted here is the geometry of the round trip: a tap at a
/// screen point becomes a block in the cell that was actually under the
/// finger, and the two live in the same coordinate system. Everything else
/// about the phase — budgets, supports, commit — is covered in build_test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A landscape phone, the only orientation the game runs in.
  const phone = Size(851, 393);

  setUp(() => SaveService.instance.data = SaveData());

  GameController match() => GameController(
        settings: MatchSettings(
            map: GameMaps.all.first, startHp: 100, buildYourRaft: true),
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
            aiDifficulty: AiDifficulty.easy,
          ),
        ],
        mode: GameMode.vsAi,
        seed: 7,
      );

  Future<GameController> open(WidgetTester tester) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ctrl = match();
    ctrl.skipIntro();
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(
        settings: ctrl.settings,
        players: ctrl.players,
        mode: GameMode.vsAi,
        controller: ctrl,
      ),
    ));
    await tester.pump();
    return ctrl;
  }

  /// The screen point that sits on cell [col]/[row] of [raft], inverting the
  /// painter's transform exactly as the game screen does.
  Offset screenFor(GameController ctrl, Raft raft, int col, int row) {
    final scale = phone.height / BattleConst.worldH;
    final deckTop = raft.waterLine - raft.loadout.deckRise;
    final wx = raft.x + BuildPlan.columnX(col);
    final wy = deckTop -
        row * BuildPlan.cellH -
        BuildPlan.cellH / 2 +
        ctrl.world.bobOf(raft);
    return Offset((wx - ctrl.world.cam) * scale, wy * scale);
  }

  group('The raft is the editor', () {
    testWidgets('a tap on the deck builds in the cell under the finger',
        (tester) async {
      final ctrl = await open(tester);
      expect(ctrl.buildPhase, true, reason: 'the build phase never started');
      final raft = ctrl.world.raftOf(ctrl.localPlayerIndex)!;
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.editingPlan!.set(c, r, null);
        }
      }
      await tester.pump();

      // The bottom row is always legal on a barge, and a block on the deck
      // needs nothing under it.
      const col = 4, row = 0;
      expect(ctrl.editingPlan!.at(col, row), isNull);

      await tester.tapAt(screenFor(ctrl, raft, col, row));
      await tester.pump();

      expect(ctrl.editingPlan!.at(col, row), isNotNull,
          reason: 'tapping the deck put nothing there');
      ctrl.dispose();
    });

    testWidgets('it lands in the RIGHT cell, not merely some cell',
        (tester) async {
      // The whole point of editing on the raft is that the finger and the
      // block agree. An off-by-one column would still "work" and would be
      // maddening to use.
      final ctrl = await open(tester);
      final raft = ctrl.world.raftOf(ctrl.localPlayerIndex)!;
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.editingPlan!.set(c, r, null);
        }
      }
      await tester.pump();

      for (final col in [3, 4, 5]) {
        await tester.tapAt(screenFor(ctrl, raft, col, 0));
        await tester.pump();
      }

      for (int c = 0; c < BuildPlan.cols; c++) {
        final filled = ctrl.editingPlan!.at(c, 0) != null;
        expect(filled, [3, 4, 5].contains(c),
            reason: 'column $c is ${filled ? "filled" : "empty"} and should '
                'not be — the tap landed in the wrong column');
      }
      ctrl.dispose();
    });

    testWidgets('stacking upward works, so walls can be built',
        (tester) async {
      final ctrl = await open(tester);
      final raft = ctrl.world.raftOf(ctrl.localPlayerIndex)!;
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.editingPlan!.set(c, r, null);
        }
      }
      await tester.pump();

      for (int row = 0; row < 3; row++) {
        await tester.tapAt(screenFor(ctrl, raft, 4, row));
        await tester.pump();
      }
      for (int row = 0; row < 3; row++) {
        expect(ctrl.editingPlan!.at(4, row), isNotNull,
            reason: 'row $row of the wall is missing');
      }
      ctrl.dispose();
    });

    testWidgets('tapping a block takes it away again', (tester) async {
      // One gesture both ways, so there is no eraser mode to get stuck in.
      final ctrl = await open(tester);
      final raft = ctrl.world.raftOf(ctrl.localPlayerIndex)!;
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.editingPlan!.set(c, r, null);
        }
      }
      await tester.pump();

      final spot = screenFor(ctrl, raft, 4, 0);
      await tester.tapAt(spot);
      await tester.pump();
      expect(ctrl.editingPlan!.at(4, 0), isNotNull);

      await tester.tapAt(spot);
      await tester.pump();
      expect(ctrl.editingPlan!.at(4, 0), isNull,
          reason: 'tapping a block again did not remove it');
      ctrl.dispose();
    });

    testWidgets('a tap on open water builds nothing', (tester) async {
      final ctrl = await open(tester);
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.editingPlan!.set(c, r, null);
        }
      }
      await tester.pump();
      final before = ctrl.editingPlan!.cost;

      // Well to the right of the player's raft, over the channel.
      await tester.tapAt(const Offset(700, 200));
      await tester.pump();

      expect(ctrl.editingPlan!.cost, before,
          reason: 'a tap on the sea built something');
      ctrl.dispose();
    });
  });

  group('The build screen is not the battle screen', () {
    testWidgets('the battle HUD is not drawn over the build UI',
        (tester) async {
      // The reported symptom, item by item: the health bar sat across the
      // title and the walk arrows sat under the palette.
      final ctrl = await open(tester);
      expect(find.text('BUILD YOUR RAFT'), findsOneWidget);

      for (final gone in ['FIRE', 'TAP A CREW MEMBER TO SWITCH']) {
        expect(find.text(gone), findsNothing,
            reason: '$gone is still on screen during the build phase');
      }
      ctrl.dispose();
    });

    testWidgets('the middle of the screen is left to the raft',
        (tester) async {
      // The overlay keeps to the top and bottom strips. If it ever grows
      // back into the middle it covers the thing being edited, and taps
      // meant for the deck stop arriving.
      final ctrl = await open(tester);
      // One landmark from each bar. The palette is used for the bottom one
      // rather than the sail button, whose label depends on whether the
      // plan happens to be valid.
      final bars = [
        tester.getRect(find.text('BUILD YOUR RAFT').first),
        tester.getRect(find.text('Iron').first),
      ];
      final raft = ctrl.world.raftOf(ctrl.localPlayerIndex)!;
      final deck = screenFor(ctrl, raft, 4, 0);
      for (final b in bars) {
        expect(b.contains(deck), false,
            reason: 'the build UI is sitting on the deck at $deck');
      }
      ctrl.dispose();
    });

    testWidgets('taps on the palette do not also drop blocks on the deck',
        (tester) async {
      // The overlay and the world's pointer listener are in the same
      // hit-test path, so without an explicit exclusion a tap reaches both.
      final ctrl = await open(tester);
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.editingPlan!.set(c, r, null);
        }
      }
      await tester.pump();
      final before = ctrl.editingPlan!.cost;

      await tester.tap(find.text('Iron'));
      await tester.pump();

      expect(ctrl.editingPlan!.cost, before,
          reason: 'picking a material also built a block');
      ctrl.dispose();
    });

    testWidgets('the chosen material is the one that gets built',
        (tester) async {
      final ctrl = await open(tester);
      final raft = ctrl.world.raftOf(ctrl.localPlayerIndex)!;
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.editingPlan!.set(c, r, null);
        }
      }
      await tester.pump();

      await tester.tap(find.text('Thatch'));
      await tester.pump();
      await tester.tapAt(screenFor(ctrl, raft, 4, 0));
      await tester.pump();

      expect(ctrl.editingPlan!.at(4, 0)?.material, BuildMaterial.thatch,
          reason: 'the palette selection was ignored');
      ctrl.dispose();
    });
  });
}
