import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/characters.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/main_menu.dart';

/// The mascot on the main menu.
///
/// It was a hand-assembled stack of [Container]s — a bare circle, two
/// floating eyebrow bars, a nose dot, a rectangle body and an orange pill —
/// built before the crew art settled into its current form and never
/// revisited. By the end it resembled nothing in the game: no hat, no
/// character, no relation to whoever the player had equipped.
///
/// The fix is structural rather than cosmetic, so that is what is tested:
/// the mascot now draws through the same [CharacterArt] the battle and the
/// roster picker use, driven by the saved character. There is no second copy
/// of the art left to fall behind, and the menu shows the person you play.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: child))));
    await tester.pump();
  }

  testWidgets('it draws, for every character the player can wear',
      (tester) async {
    // Every playable look, because the mascot follows the roster and a new
    // character must not be able to break the menu.
    for (final ch in Cast.playable) {
      await pump(tester, MenuMascot(look: ch.look));
      expect(find.byType(MenuMascot), findsOneWidget,
          reason: '${ch.name} broke the mascot');
      expect(tester.takeException(), isNull, reason: '${ch.name} threw');
    }
  });

  testWidgets('it wears whoever is equipped, not a fixed mascot',
      (tester) async {
    // The behaviour the old one could not have: the menu shows your
    // captain. Two different saves have to produce two different paintings.
    // Compared through shouldRepaint rather than by identity or toString:
    // that is the method that encodes what the painter will actually draw,
    // and the only handle a test has on it from outside.
    final painters = <CustomPainter>[];
    for (final look in [CrewLook.player, CrewLook.drifter]) {
      SaveService.instance.data = SaveData()..character = look.name;
      // A distinct key per pump: `const MenuMascot()` is canonicalised, so
      // pumping it twice reuses the element and build never re-runs -- the
      // test would then compare one painter with itself.
      await pump(tester, MenuMascot(key: ValueKey(look)));
      final painter = tester
          .widget<CustomPaint>(find.descendant(
              of: find.byType(MenuMascot), matching: find.byType(CustomPaint)))
          .painter!;
      // Same character, same painting — no needless repaints on the menu.
      expect(painter.shouldRepaint(painter), false);
      painters.add(painter);
    }
    expect(painters.first.shouldRepaint(painters.last), true,
        reason: 'the mascot paints the same thing for two different '
            'characters, so it is not reading the save at all');
  });

  testWidgets('an explicit look overrides the save', (tester) async {
    SaveService.instance.data = SaveData()..character = CrewLook.player.name;
    await pump(tester, const MenuMascot(look: CrewLook.drifter));
    final painter = tester
        .widget<CustomPaint>(find.descendant(
            of: find.byType(MenuMascot), matching: find.byType(CustomPaint)))
        .painter!;
    // Repainting against the saved default must be required, which is only
    // true if the widget honoured the parameter over the save.
    await pump(tester, const MenuMascot());
    final fromSave = tester
        .widget<CustomPaint>(find.descendant(
            of: find.byType(MenuMascot), matching: find.byType(CustomPaint)))
        .painter!;
    expect(painter.shouldRepaint(fromSave), true,
        reason: 'the named look was ignored in favour of the save');
  });

  testWidgets('a save naming an enemy-only character still draws',
      (tester) async {
    // Saves in the wild carry ids that are no longer playable, and the menu
    // is the first thing that runs. It must not be the thing that crashes.
    SaveService.instance.data = SaveData()..character = 'nonsense-id';
    await pump(tester, const MenuMascot());
    expect(tester.takeException(), isNull);
    expect(find.byType(MenuMascot), findsOneWidget);
  });

  testWidgets('the menu itself still builds with the new mascot in it',
      (tester) async {
    tester.view.physicalSize = const Size(851, 460);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: MainMenuScreen()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MenuMascot), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
