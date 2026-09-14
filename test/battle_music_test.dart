import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/audio.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/game_screen.dart';

/// Which track is playing, across a campaign's level-to-level handover.
///
/// The battle screen asks for the battle theme when it opens and hands the
/// music back to the menu when it closes, which is right for entering and
/// leaving a match. It is wrong for the one transition that is BOTH at once:
/// "next level" is a [Navigator.pushReplacement], and Flutter builds the
/// incoming route before it disposes the outgoing one. So the new level
/// started the battle theme and the old level's dispose then handed the
/// music to the menu on top of it — and the menu theme played over the whole
/// of every level after the first.
///
/// The order is the entire bug, so the order is what is tested.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
    AudioService.instance.lastMusicRequest = null;
  });

  /// A landscape phone. The battle HUD is laid out for one, and the test
  /// binding's default surface is neither that shape nor that size.
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(851, 393);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  List<PlayerConfig> players() => [
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
      ];

  Widget battle(MapDef map) => GameScreen(
        settings: MatchSettings(map: map, startHp: 100),
        players: players(),
        mode: GameMode.vsAi,
        seed: 3,
      );

  testWidgets('a battle asks for the battle theme', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: battle(GameMaps.all.first)));
    await tester.pump();
    expect(AudioService.instance.lastMusicRequest, 'music_battle');
  });

  testWidgets('advancing to the next level keeps the battle theme',
      (tester) async {
    phone(tester);
    // The reported bug, reproduced through the navigation that causes it.
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: battle(GameMaps.all.first),
    ));
    await tester.pump();

    nav.currentState!.pushReplacement(
      MaterialPageRoute(builder: (_) => battle(GameMaps.all[1])),
    );
    // Long enough for the outgoing route to be disposed, which is the half
    // of the transition that used to overwrite the music.
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(AudioService.instance.lastMusicRequest, 'music_battle',
        reason: 'the outgoing level handed the music back to the menu over '
            'the top of the level that had just started');
  });

  testWidgets('leaving the last battle does give the music back',
      (tester) async {
    phone(tester);
    // gets its own theme back.
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Text('menu')),
    ));
    nav.currentState!.push(
      MaterialPageRoute(builder: (_) => battle(GameMaps.all.first)),
    );
    await tester.pumpAndSettle();
    expect(AudioService.instance.lastMusicRequest, 'music_battle');

    nav.currentState!.pop();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(AudioService.instance.lastMusicRequest, 'music_menu',
        reason: 'the battle theme kept playing back on the menu');
  });

  testWidgets('a whole run of levels never falls back to the menu theme',
      (tester) async {
    phone(tester);
    // single transition and fails on the next.
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: battle(GameMaps.all.first),
    ));
    await tester.pump();

    for (int i = 1; i < 4; i++) {
      nav.currentState!.pushReplacement(
        MaterialPageRoute(
            builder: (_) => battle(GameMaps.all[i % GameMaps.all.length])),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(AudioService.instance.lastMusicRequest, 'music_battle',
          reason: 'the menu theme came back on level ${i + 1}');
    }
  });
}
