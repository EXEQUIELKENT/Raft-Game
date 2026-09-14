import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/campaign.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/campaign_upgrades_screen.dart';
import 'package:raft_rumble/screens/match_setup_screen.dart';

/// Whether a player can FIND the raft-building mode and the newest map.
///
/// Both were fully implemented and neither could be found, which is a fault
/// of exactly the same weight as not having written them: the build toggle
/// sat about two screens below the fold of a scrolling setup page, and The
/// Open Blue was seventh of seven tiles in a horizontal strip, a sliver past
/// the right edge behind four greyed-out locked maps.
///
/// So these are geometry assertions against a real phone-sized viewport
/// rather than "is the widget in the tree" — the widget was always in the
/// tree. What matters is whether it is on the screen a player is looking at.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A landscape phone, which is the only orientation this game runs in.
  const phone = Size(851, 393);

  setUp(() => SaveService.instance.data = SaveData());

  Future<void> openSetup(WidgetTester tester) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        const MaterialApp(home: MatchSetupScreen(mode: 'ai')));
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('You can find it without scrolling or hunting', () {
    testWidgets('the build toggle is on the first screen of match setup',
        (tester) async {
      await openSetup(tester);

      for (final label in ['PREFAB', 'BUILD IT']) {
        final f = find.text(label);
        expect(f, findsOneWidget, reason: '$label is not on the setup screen');
        final r = tester.getRect(f.first);
        expect(r.bottom, lessThan(phone.height),
            reason: '$label sits ${r.top.round()}px down a '
                '${phone.height.round()}px screen, so it is only found by '
                'someone already scrolling for it');
        expect(r.top, greaterThan(0));
      }
    });

    testWidgets('it is above the hull pickers it is an alternative to',
        (tester) async {
      // Order carries meaning here. BUILD IT replaces the prefab deck rather
      // than decorating it, so a player has to meet the choice before they
      // spend time choosing a hull, not after.
      await openSetup(tester);
      final deck = tester.getRect(find.text('RAFT DECK').first);
      final hull = tester.getRect(find.text('YOUR RAFT').first);
      expect(deck.top, lessThan(hull.top),
          reason: 'the deck choice is offered after the hull it overrides');
    });

    testWidgets('it says what it does', (tester) async {
      // Two words on a chip cannot carry a whole alternative way to play.
      await openSetup(tester);
      expect(find.textContaining('hull you picked'), findsOneWidget,
          reason: 'PREFAB is unexplained');

      await tester.tap(find.text('BUILD IT'));
      await tester.pump();
      expect(find.textContaining('Lay out your own deck'), findsOneWidget,
          reason: 'BUILD IT is unexplained');
    });

    testWidgets('every map you can actually play is on screen',
        (tester) async {
      // The specific failure: the newest map unlocks at level 1 and was
      // still invisible, because the tiles ahead of it were ones you cannot
      // pick. A strip whose visible run ends in a padlock reads as a strip
      // that has ended.
      await openSetup(tester);
      final save = SaveService.instance.data;
      final screen = Rect.fromLTWH(0, 0, phone.width, phone.height);

      for (final m in GameMaps.all.where((m) => m.levelLock <= save.level)) {
        final r = tester.getRect(find.text(m.name).first);
        expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight),
            true,
            reason: '${m.name} is playable at level ${save.level} but sits at '
                'x=${r.left.round()}..${r.right.round()} on a '
                '${phone.width.round()}px screen');
      }
    });

    testWidgets('The Open Blue in particular', (tester) async {
      // Named outright, because it is the map the request was about.
      await openSetup(tester);
      final blue = GameMaps.all.firstWhere((m) => m.id == 'openwater');
      expect(blue.levelLock, lessThanOrEqualTo(1),
          reason: 'the new map is locked behind a level, so a new player '
              'cannot reach it at all');
      final r = tester.getRect(find.text(blue.name).first);
      expect(r.right, lessThan(phone.width),
          reason: 'The Open Blue is off the right edge again');
    });
  });

  group('Building is reachable from the campaign too', () {
    testWidgets('the shipyard offers it', (tester) async {
      // Campaign launches battles straight off the map with no setup screen
      // in between, so without a home in the shipyard the mechanic simply
      // does not exist for a campaign player.
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: CampaignUpgradesScreen()));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('BUILD IT'), findsOneWidget,
          reason: 'the shipyard has no way to choose a built deck');
      expect(find.text('PREFAB'), findsOneWidget);
    });

    testWidgets('choosing it there carries into campaign battles',
        (tester) async {
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: CampaignUpgradesScreen()));
      await tester.pump(const Duration(milliseconds: 300));

      final level = Campaign.worlds.first.levels.first;
      expect(Campaign.matchFor(level).$1.buildYourRaft, false,
          reason: 'a prefab captain was put into the build phase');

      await tester.tap(find.text('BUILD IT'));
      await tester.pump();

      expect(SaveService.instance.data.buildOwnRaft, true);
      expect(Campaign.matchFor(level).$1.buildYourRaft, true,
          reason: 'the shipyard says the captain builds their own deck and '
              'the campaign still hands them a prefab');
    });

    testWidgets('and the skirmish screen agrees with it', (tester) async {
      // One preference behind both, so the two screens can never disagree
      // about what you are sailing.
      SaveService.instance.data.buildOwnRaft = true;
      await openSetup(tester);
      expect(find.textContaining('Lay out your own deck'), findsOneWidget,
          reason: 'the skirmish screen ignored the saved choice');
    });
  });
}
