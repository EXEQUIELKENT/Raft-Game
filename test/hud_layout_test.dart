import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/game_screen.dart';

/// Where the battle HUD sits.
///
/// It is two bars pinned to the edges of the screen: your raft and the
/// readouts across the top, the weapons and the fire button across the
/// bottom. Both are supposed to SPAN the screen, with things held against
/// the left and right edges.
///
/// They stopped doing that. Fixing an overflow, the `Spacer` that pushed
/// each bar's right-hand group to the edge was replaced with a fixed gap,
/// and a flex weight was put on the health pill. Both have the same effect
/// and it only shows up on a wide window: the right-hand controls stop being
/// pushed anywhere and simply sit wherever the left-hand ones happen to end.
/// On a 1577px window the fire button ended up 662px from the right edge,
/// with the whole right half of the screen empty.
///
/// So this measures the gaps rather than the presence, and it measures them
/// at more than one width — because at phone width the bug is invisible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  Future<GameController> open(WidgetTester tester, Size screen) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ctrl = GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100),
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
      seed: 4,
    );
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(
        settings: ctrl.settings,
        players: ctrl.players,
        mode: GameMode.vsAi,
        controller: ctrl,
      ),
    ));
    await tester.pump();
    if (ctrl.inIntro) ctrl.skipIntro();
    await tester.pump(const Duration(milliseconds: 16));
    return ctrl;
  }

  /// A phone in landscape, a tablet, and a desktop browser window — the last
  /// being where the fault actually showed.
  const widths = [
    Size(720, 360),
    Size(851, 393),
    Size(1180, 600),
    Size(1577, 840),
  ];

  group('The HUD spans the screen at every width', () {
    testWidgets('the fire button stays against the right edge',
        (tester) async {
      // The loudest symptom: the button you press every turn, stranded in
      // the middle of the screen.
      for (final screen in widths) {
        final ctrl = await open(tester, screen);
        final r = tester.getRect(find.text('FIRE').first);
        final gap = screen.width - r.right;
        expect(gap, lessThan(40),
            reason: 'at ${screen.width.toInt()}px the fire button is '
                '${gap.toInt()}px from the right edge');
        ctrl.dispose();
      }
    });

    testWidgets('the top-bar readouts stay against the right edge',
        (tester) async {
      for (final screen in widths) {
        final ctrl = await open(tester, screen);
        // The crew-count chip is the last readout before the purse, so its
        // right edge is a fixed short distance from the screen edge.
        final r = tester.getRect(find.textContaining('CREW LEFT').first);
        final gap = screen.width - r.right;
        expect(gap, lessThan(140),
            reason: 'at ${screen.width.toInt()}px the readouts stop '
                '${gap.toInt()}px short of the right edge');
        ctrl.dispose();
      }
    });

    testWidgets('the weapons stay against the left edge', (tester) async {
      // The other half of "spans the screen": the left group must not drift
      // inward either.
      for (final screen in widths) {
        final ctrl = await open(tester, screen);
        final r = tester.getRect(find.text('TENNIS').first);
        expect(r.left, lessThan(90),
            reason: 'at ${screen.width.toInt()}px the weapon bar starts '
                '${r.left.toInt()}px in from the left');
        ctrl.dispose();
      }
    });

    testWidgets('the gap to the right edge does not grow with the screen',
        (tester) async {
      // The property that actually distinguishes a pinned layout from one
      // that merely looks right on the device it was built on.
      final gaps = <double, double>{};
      for (final screen in widths) {
        final ctrl = await open(tester, screen);
        final r = tester.getRect(find.text('FIRE').first);
        gaps[screen.width] = screen.width - r.right;
        ctrl.dispose();
      }
      final spread = gaps.values.reduce((a, b) => a > b ? a : b) -
          gaps.values.reduce((a, b) => a < b ? a : b);
      expect(spread, lessThan(8),
          reason: 'the right-hand gap varies by ${spread.toInt()}px across '
              'screen widths ($gaps) — the controls are being positioned by '
              'what is to their left instead of by the edge');
    });

    testWidgets('nothing overflows at any of them', (tester) async {
      for (final screen in widths) {
        final ctrl = await open(tester, screen);
        expect(tester.takeException(), isNull,
            reason: 'the HUD overflowed at ${screen.width.toInt()}px');
        ctrl.dispose();
      }
    });
  });
}
