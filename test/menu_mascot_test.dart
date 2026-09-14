import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/characters.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/main_menu.dart';
import 'package:raft_rumble/widgets/menu_mascot.dart';

/// The character on the main menu.
///
/// It has been three things. A hand-assembled stack of [Container]s — a bare
/// circle, two floating eyebrow bars, a nose dot, a rectangle body and an
/// orange pill — which resembled nothing in the game. Then a painter that
/// borrowed the roster's hats and approximated the rest: stick arms, no legs,
/// no boots, no weapon, none of the shading the real crew have.
///
/// Now it renders an actual one-raft world through the actual
/// [WorldRenderer], with every layer but the rafts held out. That is the
/// only version that can be right by construction, because there is no
/// second drawing of a character left anywhere to drift from the first.
///
/// So the tests are about that property rather than about pixels: the menu
/// shows whoever is equipped, it survives every character on the roster, and
/// what it draws is detailed enough to be the real rig rather than a
/// stand-in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  Future<ui.Image> render(WidgetTester tester, Widget mascot) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: Container(
          color: const Color(0xFF9FC8D8),
          child: Center(child: mascot),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    return (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
        .toImageSync(pixelRatio: 1.0);
  }

  Future<List<int>> pixels(WidgetTester tester, ui.Image img) async {
    late List<int> out;
    await tester.runAsync(() async {
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      out = bd!.buffer.asUint8List().toList();
    });
    return out;
  }

  group('It is the crew rig, not a lookalike', () {
    testWidgets('it draws every character the player can wear',
        (tester) async {
      for (final ch in Cast.playable) {
        await render(tester, MenuMascot(look: ch.look));
        expect(tester.takeException(), isNull, reason: '${ch.name} threw');
        expect(find.byType(MenuMascot), findsOneWidget);
      }
    });

    testWidgets('what it draws is detailed, not a flat stand-in',
        (tester) async {
      // The old mascot was five flat shapes. The real rig has skin, outfit,
      // accent, boots, a hull, railings and a firearm, each with its own
      // shading — so a low tone count means the renderer is not actually
      // being used.
      final px = await pixels(
          tester, await render(tester, const MenuMascot(look: CrewLook.drifter)));
      final tones = <int>{};
      for (int i = 0; i < px.length ~/ 4; i++) {
        if (px[i * 4 + 3] < 8) continue;
        tones.add((px[i * 4] >> 4) << 8 |
            (px[i * 4 + 1] >> 4) << 4 |
            (px[i * 4 + 2] >> 4));
      }
      expect(tones.length, greaterThan(14),
          reason: 'only ${tones.length} distinct tones — this is not the '
              'crew rig, it is a handful of flat shapes');
    });

    testWidgets('two characters do not paint the same picture',
        (tester) async {
      final a = await pixels(
          tester, await render(tester, const MenuMascot(look: CrewLook.player)));
      final b = await pixels(tester,
          await render(tester, const MenuMascot(look: CrewLook.nomad)));
      var differing = 0;
      for (int i = 0; i < a.length; i += 4) {
        if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) {
          differing++;
        }
      }
      expect(differing, greaterThan(200),
          reason: 'two different characters painted near-identical pictures, '
              'so the look is not reaching the drawing');
    });
  });

  group('It shows whoever is equipped', () {
    testWidgets('the saved character is the one drawn', (tester) async {
      // The whole reason it is on the menu: it is YOUR captain.
      SaveService.instance.data.character = CrewLook.player.name;
      final fromSave = await pixels(tester, await render(tester, const MenuMascot()));
      final asPlayer = await pixels(
          tester, await render(tester, const MenuMascot(look: CrewLook.player)));
      final asNomad = await pixels(
          tester, await render(tester, const MenuMascot(look: CrewLook.nomad)));

      int diff(List<int> x, List<int> y) {
        var n = 0;
        for (int i = 0; i < x.length; i += 4) {
          if (x[i] != y[i] || x[i + 1] != y[i + 1]) n++;
        }
        return n;
      }

      expect(diff(fromSave, asPlayer), lessThan(diff(fromSave, asNomad)),
          reason: 'the default save drew something closer to a character it '
              'has not equipped');
    });

    testWidgets('a named look overrides the save', (tester) async {
      SaveService.instance.data.character = CrewLook.player.name;
      final named = await pixels(tester,
          await render(tester, const MenuMascot(look: CrewLook.nomad)));
      final saved = await pixels(tester, await render(tester, const MenuMascot()));
      var differing = 0;
      for (int i = 0; i < named.length; i += 4) {
        if (named[i] != saved[i]) differing++;
      }
      expect(differing, greaterThan(100),
          reason: 'the named look was ignored in favour of the save');
    });

    testWidgets('a save naming an unknown character still draws',
        (tester) async {
      // Saves in the wild carry ids that are no longer playable, and the
      // menu is the first thing that runs. It must not be what crashes.
      SaveService.instance.data.character = 'nonsense-id';
      await render(tester, const MenuMascot());
      expect(tester.takeException(), isNull);
      expect(find.byType(MenuMascot), findsOneWidget);
    });
  });

  testWidgets('the menu itself still builds with it in', (tester) async {
    tester.view.physicalSize = const Size(851, 460);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: MainMenuScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MenuMascot), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
