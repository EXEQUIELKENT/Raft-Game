import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/hotspot_screen.dart';
import 'package:raft_rumble/widgets/lobby.dart';

/// The two lobby screens, after taking Battleship Blitz's layout.
///
/// Layout only — every colour and font is Raft's. What is worth pinning is
/// the ORDER and the SHAPE, because that is the part that was wrong: both
/// pages used to be a flat stack of equal cards, which reads as a settings
/// page rather than a lobby. Nothing said where to start, and the two
/// screens each invented their own card, field and heading for the same
/// ideas.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SaveService.instance.data = SaveData();
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> pump(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: screen));
    // Past the staggered entrance.
    await tester.pump(const Duration(milliseconds: 900));
  }

  group('Hotspot lobby', () {
    testWidgets('opens on the thing you most often came to do', (tester) async {
      // Somebody arriving here usually has a code being read out to them, so
      // that is the first control on the page — not a wall of explanation,
      // and not HOST, which is the rarer half of the pair.
      await pump(tester, const HotspotScreen());

      expect(find.text('JOIN BY ROOM CODE'), findsOneWidget);
      expect(find.text('HOST A ROOM'), findsOneWidget);
      expect(find.text('FIND A ROOM NEARBY'), findsOneWidget);

      final join = tester.getTopLeft(find.text('JOIN BY ROOM CODE')).dy;
      final host = tester.getTopLeft(find.text('HOST A ROOM')).dy;
      final scan = tester.getTopLeft(find.text('FIND A ROOM NEARBY')).dy;
      expect(join, lessThan(host),
          reason: 'joining should come before hosting');
      expect(host, lessThan(scan),
          reason: 'scanning is the fallback, so it comes last');
    });

    testWidgets('every block says what it is for', (tester) async {
      // A lobby control that does not say what it does is the main way these
      // screens go wrong, so the subtitle is part of the card rather than
      // optional decoration.
      await pump(tester, const HotspotScreen());
      for (final card in tester.widgetList<LobbyCard>(find.byType(LobbyCard))) {
        expect(card.subtitle, isNotNull,
            reason: '"${card.title}" has no line saying what it is for');
        expect(card.subtitle, isNotEmpty);
      }
    });

    testWidgets('the code field accepts a code and an IP', (tester) async {
      // Both go in the same box: a code is looked up over the Wi-Fi, a
      // dotted address connects straight out. Two fields for one job is what
      // the old layout had, and it made the IP look like a separate feature.
      await pump(tester, const HotspotScreen());
      final field = find.byType(TextField);
      expect(field, findsOneWidget,
          reason: 'there should be exactly one thing to type into');

      await tester.enterText(field, 'ab12');
      await tester.pump();
      expect(find.text('AB12'), findsOneWidget,
          reason: 'a code should be upper-cased as it is typed');

      await tester.enterText(field, '192.168.1.5');
      await tester.pump();
      expect(find.text('192.168.1.5'), findsOneWidget,
          reason: 'a dotted IP must still be typeable');
    });
  });

// The ONLINE screen is deliberately not booted in a widget test. It dials  // a server the moment it opens, and with no network that leaves an HTTP  // timeout timer the harness reports as a leak — so the test would be  // asserting the absence of a network rather than the layout. Its pieces  // are covered below, which is where the layout now lives: both screens are  // built from the same furniture, so testing that tests both.

  group('Shared lobby furniture', () {
    testWidgets('a code renders one tile per character', (tester) async {
      // A code has to be read aloud across a table; tiles force the eye to
      // take it one character at a time.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: CodeTiles(code: 'ab12'))),
      ));
      for (final ch in ['A', 'B', '1', '2']) {
        expect(find.text(ch), findsOneWidget,
            reason: '"$ch" is missing from the tiles');
      }
    });

    testWidgets('an empty code renders nothing rather than an empty row',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: CodeTiles(code: '   '))),
      ));
      expect(find.byType(Row), findsNothing);
    });

    testWidgets('a section heading carries its count as a pill',
        (tester) async {
      // So the eye can find how many without reading the heading.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: LobbySection('REQUESTS', count: 3)),
      ));
      expect(find.text('REQUESTS'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('a heading with no count shows no pill', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: LobbySection('WAITING')),
      ));
      expect(find.text('WAITING'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\d+$')), findsNothing);
    });

    testWidgets('staggered items all arrive', (tester) async {
      // A stagger that never finishes leaves rows invisible. PopIn starts
      // its animation on a delay rather than delaying the build, so the
      // list does not reflow as each row appears — which also means a row
      // that never runs its controller stays at zero opacity for ever.
      final pop = PopSequence();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (int i = 0; i < 5; i++) pop.wrap(Text('row $i')),
            ],
          ),
        ),
      ));
      // pumpAndSettle rather than one long pump: PopIn starts its
      // controller from a delayed callback, so a single pump fires the
      // callback but never ticks the controller it started.
      await tester.pumpAndSettle();
      for (int i = 0; i < 5; i++) {
        // `.first` because the ancestor chain has more than one — PopIn
        // nests a SlideTransition inside its FadeTransition, and the app
        // shell adds its own. The nearest one up is PopIn's.
        final opacity = tester.widget<FadeTransition>(
          find
              .ancestor(
                of: find.text('row $i'),
                matching: find.byType(FadeTransition),
              )
              .first,
        );
        expect(opacity.opacity.value, closeTo(1.0, 0.01),
            reason: 'row $i never finished arriving');
      }
    });
  });
}
