import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/game_screen.dart';
import 'package:raft_rumble/theme.dart';

/// How the game gets its frames.
///
/// The frames themselves were never expensive — an idle scene builds its
/// display list in about 1ms against a 16.7ms budget, and a scene with five
/// rafts, fifteen crew, twelve ragdolls and thirty-two effects on it barely
/// costs more. What stopped it holding 60fps was when the frames arrived.
///
/// It ran on `Timer.periodic(Duration(milliseconds: 16))`. Measured over 300
/// ticks in a real VM that delivered 62.4Hz — beating continuously against a
/// 60Hz display — with gaps anywhere from 0.00ms to 31.64ms (p95 23.84ms),
/// and a dt truncated to whole milliseconds by `inMilliseconds`. Ticks that
/// fell inside one refresh interval did work nobody ever saw; ticks that
/// straddled two showed their work a frame late.
///
/// So what is tested here is the pacing rather than the cost: that the world
/// advances once per rendered frame, by the amount of time that frame
/// represents, and that it neither stalls nor fast-forwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  GameController match() => GameController(
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

  group('The world runs on the display clock', () {
    testWidgets('it advances once per frame, not on a timer of its own',
        (tester) async {
      // The heart of it. Under the old loop the world advanced on wall-clock
      // ticks that had no relationship to the frames being drawn; now the
      // only thing that moves it is a frame.
      tester.view.physicalSize = const Size(851, 393);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = match();
      await tester.pumpWidget(MaterialApp(
        home: GameScreen(
          settings: ctrl.settings,
          players: ctrl.players,
          mode: GameMode.vsAi,
          controller: ctrl,
        ),
      ));
      await tester.pump();

      final before = ctrl.time;
      // Sixteen frames of sixteen milliseconds.
      for (int i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final advanced = ctrl.time - before;

      expect(advanced, greaterThan(0.2),
          reason: 'the world did not move with the frames at all — the loop '
              'is not being driven by the display');
      expect(advanced, lessThan(0.36),
          reason: 'the world advanced ${advanced.toStringAsFixed(3)}s across '
              '0.256s of frames, so it is stepping more than once per frame');
      ctrl.dispose();
    });

    testWidgets('it keeps asking for frames, so nothing ever stalls',
        (tester) async {
      // A game is never idle: water moves, crew breathe, the turn clock
      // runs. The loop therefore has to request the next frame itself rather
      // than wait for something else to mark the tree dirty.
      final ctrl = match();
      await tester.pumpWidget(MaterialApp(
        home: GameScreen(
          settings: ctrl.settings,
          players: ctrl.players,
          mode: GameMode.vsAi,
          controller: ctrl,
        ),
      ));
      await tester.pump();

      var moved = 0;
      var last = ctrl.time;
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (ctrl.time > last) moved++;
        last = ctrl.time;
      }
      expect(moved, greaterThan(25),
          reason: 'only $moved of 30 frames advanced the world, so the loop '
              'is dropping frames it was handed');
      ctrl.dispose();
    });

    testWidgets('a long stall does not teleport the world', (tester) async {
      // Coming back from a garbage collection, a route transition or the
      // app being backgrounded hands over an enormous elapsed time. Applied
      // whole it would fast-forward the turn clock and jump shots straight
      // through rafts, so the backlog is dropped instead.
      final ctrl = match();
      await tester.pumpWidget(MaterialApp(
        home: GameScreen(
          settings: ctrl.settings,
          players: ctrl.players,
          mode: GameMode.vsAi,
          controller: ctrl,
        ),
      ));
      await tester.pump();

      final before = ctrl.time;
      await tester.pump(const Duration(seconds: 4));
      final jumped = ctrl.time - before;

      expect(jumped, lessThan(0.2),
          reason: 'a four second stall moved the world '
              '${jumped.toStringAsFixed(2)}s in one step');
      expect(jumped, greaterThan(0),
          reason: 'the world stopped entirely instead of taking a short step');
      ctrl.dispose();
    });

    testWidgets('disposing the controller stops the loop', (tester) async {
      // The old timer was cancelled on dispose; a self-rescheduling frame
      // callback has to stop just as definitely, or a finished match keeps
      // simulating behind whatever screen replaced it.
      final ctrl = match();
      await tester.pumpWidget(MaterialApp(
        home: GameScreen(
          settings: ctrl.settings,
          players: ctrl.players,
          mode: GameMode.vsAi,
          controller: ctrl,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 16));

      ctrl.dispose();
      final after = ctrl.time;
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(ctrl.time, after,
          reason: 'the world kept running after the controller was disposed');
    });
  });

  group('Text styles are built once, not per label per frame', () {
    // These came from the google_fonts package, which measured at 30us a
    // call against 0.36us for a plain TextStyle — eighty times over, and
    // fetched the typeface over HTTP besides. The fonts are bundled now,
    // but there is still no reason to build the same style twice: the
    // outlined variants carry eight Shadow objects apiece.
    test('the same arguments give back the very same object', () {
      final a = RT.chunky(size: 16, color: RT.cream, outline: 3);
      final b = RT.chunky(size: 16, color: RT.cream, outline: 3);
      expect(identical(a, b), true,
          reason: 'the style was rebuilt from scratch, so every label on '
              'every rebuild is paying the full font lookup again');

      final c = RT.body(size: 11, color: RT.ink);
      expect(identical(c, RT.body(size: 11, color: RT.ink)), true);
    });

    test('different arguments still give different styles', () {
      // The risk a cache introduces: two styles colliding onto one entry and
      // silently drawing the wrong thing. The key is a record of every
      // argument, so this is exact rather than probabilistic.
      final styles = <TextStyle>[
        RT.chunky(size: 16),
        RT.chunky(size: 17),
        RT.chunky(size: 16, color: RT.red),
        RT.chunky(size: 16, outline: 2),
        RT.chunky(size: 16, weight: FontWeight.w600),
        RT.chunky(size: 16, letterSpacing: 1.4),
      ];
      for (int i = 0; i < styles.length; i++) {
        for (int j = i + 1; j < styles.length; j++) {
          expect(styles[i] == styles[j], false,
              reason: 'styles $i and $j came back identical, so the cache is '
                  'ignoring one of the arguments');
        }
      }
    });

    test('the cached style is the one it would have built anyway', () {
      // A cache that returns something subtly different is worse than none.
      final cached = RT.chunky(size: 21, color: RT.yellow, outline: 4);
      expect(cached.fontSize, 21);
      expect(cached.color, RT.yellow);
      expect(cached.shadows?.length, 8,
          reason: 'the 8-direction ink outline did not survive caching');
      expect(RT.chunky(size: 21, color: RT.yellow).shadows?.length, 1,
          reason: 'an unoutlined style should keep its single soft shadow');
    });
  });

  group('The step is the time the frame represents', () {
    testWidgets('a 60Hz frame advances about a sixtieth of a second',
        (tester) async {
      // Precision, not just presence. The old dt came from
      // `Duration.inMilliseconds`, so a 16.6ms frame described 16ms of
      // motion and threw the other 0.6ms away — unevenly, every frame.
      final ctrl = match();
      await tester.pumpWidget(MaterialApp(
        home: GameScreen(
          settings: ctrl.settings,
          players: ctrl.players,
          mode: GameMode.vsAi,
          controller: ctrl,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final before = ctrl.time;
      // A frame at the real 60Hz interval, which is NOT a whole number of
      // milliseconds — precisely the case truncation used to mangle.
      await tester.pump(const Duration(microseconds: 16667));
      final step = ctrl.time - before;

      expect(step, closeTo(1 / 60, 0.0005),
          reason: 'a 16.667ms frame advanced the world by '
              '${(step * 1000).toStringAsFixed(2)}ms');
      ctrl.dispose();
    });

    testWidgets('a faster display steps smaller, not further',
        (tester) async {
      // On a 120Hz panel the frames are half as long, and the world must
      // advance half as far per frame rather than run at double speed.
      final ctrl = match();
      await tester.pumpWidget(MaterialApp(
        home: GameScreen(
          settings: ctrl.settings,
          players: ctrl.players,
          mode: GameMode.vsAi,
          controller: ctrl,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 8));

      final before = ctrl.time;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
      final advanced = ctrl.time - before;

      expect(advanced, closeTo(1.0, 0.02),
          reason: '120 frames of a 120Hz display advanced the world '
              '${advanced.toStringAsFixed(3)}s instead of one second — the '
              'game runs at a different speed depending on the panel');
      ctrl.dispose();
    });
  });
}
