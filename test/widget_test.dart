import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/main.dart';
import 'package:raft_rumble/screens/raft_preview.dart';

void main() {
  testWidgets('Raft Rumble boots to main menu', (WidgetTester tester) async {
    await tester.pumpWidget(const RaftRumbleApp());
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('RAFT'), findsOneWidget);
    expect(find.text('RUMBLE'), findsOneWidget);
  });

  testWidgets('RaftPreview survives being laid out at a degenerate size', (tester) async {
    // A page transition can hand a CustomPaint a zero-width box for a frame.
    // Painting one used to assert (scaling by zero, and laying text out at a
    // negative maxWidth), which threw on every frame of the shop transition.
    for (final size in [
      const Size(0, 96),
      const Size(1, 96),
      const Size(240, 0),
      const Size(240, 96),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: RaftPreview(
                loadout: RaftLoadout.custom(hullId: 'sloop', sizeId: 'large', colorIndex: 2),
                height: size.height,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'RaftPreview threw at $size');
    }
  });

  testWidgets('RaftPreview fills the width it is given inside a start-aligned column', (tester) async {
    // It has no intrinsic width of its own, so in a CrossAxisAlignment.start
    // column (which is how both the shop and match setup lay it out) it
    // collapses to nothing unless it stretches deliberately.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RaftPreview(
                  loadout: RaftLoadout.custom(hullId: 'tube', sizeId: 'medium', colorIndex: 0),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(RaftPreview)).width, 400,
        reason: 'the preview must fill its column, not collapse to zero width');
  });

  testWidgets('A pull-back drag updates aim angle and power', (tester) async {
    // End-to-end smoke: a Listener that drives a real GameController and a
    // pull-back drag changes the angle/power on the controller.
    SaveService.instance.data = SaveData();
    final ctrl = GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
      players: [
        PlayerConfig(name: 'P1', loadout: RaftLoadout.custom(hullId: 'tube', sizeId: 'medium', colorIndex: 0)),
        PlayerConfig(name: 'P2', loadout: RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 1), isAi: true, aiDifficulty: AiDifficulty.easy),
      ],
      mode: GameMode.vsAi,
      seed: 1,
    );

    final startAngle = ctrl.aimAngle;
    final startPower = ctrl.aimPower;
    // Simulate a deliberate pull back and down — about 200px back, 100px down.
    ctrl.applyPullAim(200, 100);

    expect(ctrl.aimAngle, isNot(startAngle),
        reason: 'a directional drag must change the angle');
    expect(ctrl.aimPower, greaterThan(startPower),
        reason: 'a longer pull must increase power');

    ctrl.dispose();
  });
}
