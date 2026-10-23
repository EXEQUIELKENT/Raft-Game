import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/game_screen.dart';

/// How much of the screen the battle HUD is allowed to be.
///
/// The HUD is chrome around the game, and the game is the water and the
/// rafts on it. These tests pin that the chrome stays a modest slice of a
/// short screen, and that the information which used to be printed twice
/// (or printed forever) is really gone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
  });

  /// Builds the battle screen at [size] and returns the controller plus a
  /// teardown that shuts it down.
  ///
  /// The controller runs on the display's own frame callback, so it has to
  /// be disposed inside the test body — a teardown runs after the framework
  /// has already checked for callbacks left pending.
  Future<({GameController ctrl, Future<void> Function() done})> battle(
      WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
      players: [
        PlayerConfig(
            name: 'P1',
            loadout: RaftLoadout.custom(
                hullId: 'tube', sizeId: 'medium', colorIndex: 0)),
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

    await tester.pumpWidget(MaterialApp(
      home: GameScreen(
        settings: ctrl.settings,
        players: ctrl.players,
        mode: GameMode.vsAi,
        controller: ctrl,
      ),
    ));
    await tester.pump();
    // The opening sweep holds the turn: skip it, or nothing can be fired.
    if (ctrl.inIntro) ctrl.skipIntro();
    await tester.pump();
    return (
      ctrl: ctrl,
      done: () async {
        ctrl.dispose();
        await tester.pump();
      },
    );
  }

  testWidgets('The HUD takes a modest slice of a short landscape screen',
      (tester) async {
    // A phone in landscape at the short end: 640x360 logical.
    const size = Size(640, 360);
    final b = await battle(tester, size);
    final done = b.done;
    try {
      // The chrome is the top bar plus the bottom bar — the rows themselves,
      // not the gap of water between them, which is the game.
      final topBar = find
          .ancestor(
              of: find.byIcon(Icons.arrow_back_ios_new),
              matching: find.byType(Row))
          .first;
      final bottomBar =
          find.ancestor(of: find.text('FIRE'), matching: find.byType(Row)).first;
      expect(topBar, findsOneWidget);
      expect(bottomBar, findsOneWidget);

      final chrome =
          tester.getSize(topBar).height + tester.getSize(bottomBar).height;
      final fraction = chrome / size.height;

      expect(fraction, lessThan(0.36),
          reason: 'the HUD took ${(fraction * 100).toStringAsFixed(0)}% of a '
              '${size.height.toInt()}px screen — the water is the game');
    } finally {
      await done();
    }
  });

  testWidgets('The aim readout and the purse are not in the top bar',
      (tester) async {
    final b = await battle(tester, const Size(640, 360));
    final done = b.done;
    try {
      // The angle/power readout lives on the floating card above the shooter
      // while aiming, so the permanent chip was a duplicate.
      expect(find.textContaining('PWR'), findsNothing,
          reason: 'the aim readout belongs on the pull card, not in the bar');
      // The purse is a between-battles number.
      expect(find.textContaining('DOUBLOONS'), findsNothing);
    } finally {
      await done();
    }
  });

  testWidgets('The idle prompt and the walk hint are gone', (tester) async {
    final b = await battle(tester, const Size(640, 360));
    final done = b.done;
    try {
      expect(find.text('Pull back and release'), findsNothing,
          reason: 'the status line is a toast now, and idle prompts never raise it');
      expect(find.text('TAP A CREW MEMBER TO SWITCH'), findsNothing);
    } finally {
      await done();
    }
  });

  testWidgets('The crew chip carries the crew count in one pill',
      (tester) async {
    final b = await battle(tester, const Size(640, 360));
    final done = b.done;
    try {
      // One merged chip: crew left, opponents over the horizon, and — in a
      // survival level — the round.
      expect(find.textContaining('CREW LEFT'), findsOneWidget);
      expect(find.textContaining('QUICK'), findsNothing,
          reason: 'QUICK told the player nothing');
    } finally {
      await done();
    }
  });

  testWidgets('Only the selected weapon wears its name', (tester) async {
    final b = await battle(tester, const Size(640, 360));
    final done = b.done;
    try {
      // The starter is equipped, so its chip is the one with a name on it.
      expect(find.text('TENNIS'), findsOneWidget);
      // Every other round is a colour and a count.
      expect(find.text('GRENADE'), findsNothing);
    } finally {
      await done();
    }
  });

  testWidgets('A real event raises a toast and an idle prompt does not',
      (tester) async {
    final b = await battle(tester, const Size(640, 360));
    final done = b.done;
    try {
      // The turn prompt is the board speaking, not an event.
      expect(find.text('Your turn'), findsNothing);

      expect(b.ctrl.canHumanAct, true, reason: 'the turn is the player\'s');
      b.ctrl.humanFire();
      expect(b.ctrl.statusMessage, 'Shot away!');
      // The controller runs on the display's own clock, so the pumps have to
      // advance it — a pump with no duration leaves it standing still — and
      // the rebuild it asks for lands a frame after the announcement.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Shot away!'), findsOneWidget,
          reason: 'a shot away is worth saying, and saying it once');

      // And it fades rather than sitting there for the rest of the match.
      for (int i = 0; i < 160; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Shot away!'), findsNothing);
    } finally {
      await done();
    }
  });
}
