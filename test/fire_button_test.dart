import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/game_screen.dart';

/// The FIRE button.
///
/// Pull-and-release on the world was the only way to shoot, which is
/// expressive but undiscoverable and hard to do precisely. The button fires
/// the shot exactly as the angle/power nudges have it lined up.
///
/// What has to hold: it fires when it looks like it will, it does nothing
/// when it looks like it will not, and — the one that would actually break
/// the game — a press on it must never also be read as an aiming drag on the
/// world behind it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  RaftLoadout lo({int c = 0}) =>
      RaftLoadout.custom(hullId: 'galleon', sizeId: 'large', colorIndex: c);

  GameController match() => GameController(
        settings: MatchSettings(map: GameMaps.all.first, startHp: 100),
        players: [
          PlayerConfig(name: 'P1', loadout: lo()),
          PlayerConfig(
            name: 'P2',
            loadout: lo(c: 1),
            isAi: true,
            aiDifficulty: AiDifficulty.easy,
          ),
        ],
        mode: GameMode.vsAi,
        seed: 42,
      );

  Future<void> pumpGame(WidgetTester tester, GameController ctrl) async {
    await tester.binding.setSurfaceSize(const Size(1280, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: GameScreen(
        settings: ctrl.settings,
        players: ctrl.players,
        mode: GameMode.vsAi,
        seed: 42,
        controller: ctrl,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('The FIRE button', () {
    testWidgets('is on screen on the player turn', (tester) async {
      final ctrl = match();
      await pumpGame(tester, ctrl);
      expect(find.text('FIRE'), findsOneWidget);
      ctrl.dispose();
    });

    testWidgets('pressing it takes the shot', (tester) async {
      final ctrl = match();
      await pumpGame(tester, ctrl);
      expect(ctrl.canFire, true, reason: 'the player should be able to fire');
      expect(ctrl.world.shot, isNull, reason: 'nothing in the air yet');

      await tester.tap(find.text('FIRE'));
      await tester.pump();

      expect(ctrl.world.shot, isNotNull,
          reason: 'pressing FIRE did not loose a shot');
      ctrl.dispose();
    });

    testWidgets('a press on the button is never also an aiming drag',
        (tester) async {
      // The world behind the HUD is one big drag target driven by a root
      // Listener that sees every pointer, so each HUD control has to be cut
      // out of it by rectangle. A live FIRE press hides the problem — firing
      // commits the shot, which closes the drag by itself — so the case that
      // actually exercises the cut-out is a DEAD button while the player can
      // still act: out of ammo, turn still theirs.
      final ctrl = match();
      await pumpGame(tester, ctrl);
      // A weapon that is stocked rather than infinite, with nothing left.
      final limited =
          Weapons.all.firstWhere((w) => !w.infinite, orElse: () => Weapons.starter);
      ctrl.selectedWeaponId = limited.id;
      ctrl.ammo[limited.id] = 0;
      await tester.pump();
      expect(ctrl.canHumanAct, true, reason: 'the turn is still theirs');
      expect(ctrl.canFire, false, reason: 'this test needs a dead button');

      final at = tester.getCenter(find.text('FIRE'));
      final gesture = await tester.startGesture(at);
      await tester.pump();
      expect(ctrl.isCharging, false,
          reason: 'pressing FIRE started an aiming pull on the world behind '
              'it — the button is not cut out of the drag target');
      await gesture.up();
      await tester.pump();
      ctrl.dispose();
    });

    testWidgets('it goes dead once the shot is away', (tester) async {
      final ctrl = match();
      await pumpGame(tester, ctrl);
      ctrl.humanFire();
      await tester.pump();
      expect(ctrl.canFire, false,
          reason: 'the button must not offer a second shot in one turn');

      // …and pressing it anyway does nothing.
      final inFlight = ctrl.world.shot;
      await tester.tap(find.text('FIRE'));
      await tester.pump();
      expect(identical(ctrl.world.shot, inFlight), true,
          reason: 'a second press put a second shot in the air');
      ctrl.dispose();
    });

    testWidgets('it is dead on the opponent turn', (tester) async {
      final ctrl = match();
      await pumpGame(tester, ctrl);
      ctrl.beginTurnForTest(1);
      await tester.pump();
      expect(ctrl.canFire, false,
          reason: 'the player must not be able to fire during the AI turn');
      ctrl.dispose();
    });
  });

  test('canFire never disagrees with what humanFire will do', () {
    // The button reads canFire; the press calls humanFire. If those two ever
    // part company the button lies — either dead-looking but live, or live
    // -looking but inert.
    final ctrl = match();
    for (final setUpCase in <void Function()>[
      () {},
      () => ctrl.beginTurnForTest(1),
      () => ctrl.beginTurnForTest(0),
      () => ctrl.humanFire(),
    ]) {
      setUpCase();
      final expected = ctrl.canFire;
      final before = ctrl.world.shot;
      ctrl.humanFire();
      final fired = !identical(ctrl.world.shot, before);
      expect(fired, expected,
          reason: 'canFire said $expected but humanFire ${fired ? 'did' : 'did not'} fire');
    }
    ctrl.dispose();
  });
}
