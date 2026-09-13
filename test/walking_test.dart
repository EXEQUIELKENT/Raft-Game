import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// Taking the helm: tapping a crew member to control them, and walking them
/// around the deck.
///
/// The rules worth defending are about who may be moved and where they may
/// go. A mechanic that let you grab an enemy, steer a body that is still
/// mid-tumble, or walk somebody off their own raft would be worse than not
/// having one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  RaftLoadout lo({String hull = 'galleon', String size = 'large', int c = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: c);

  GameController match({String hull = 'galleon'}) => GameController(
        settings: MatchSettings(map: GameMaps.all.first, startHp: 100),
        players: [
          PlayerConfig(name: 'P1', loadout: lo(hull: hull)),
          PlayerConfig(
            name: 'P2',
            loadout: lo(hull: hull, c: 1),
            isAi: true,
            aiDifficulty: AiDifficulty.easy,
          ),
        ],
        mode: GameMode.vsAi,
        seed: 42,
      );

  /// Walks for [seconds] of frames at the controller's own step.
  void walkFor(GameController ctrl, int dir, double seconds) {
    ctrl.setWalk(dir);
    for (int i = 0; i < (seconds * 60).round(); i++) {
      ctrl.stepForTest(1 / 60);
    }
  }

  group('Taking the helm', () {
    test('tapping your own crew member hands them the turn', () {
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      expect(raft.crew.length, greaterThan(1),
          reason: 'this test needs a crew to switch between');

      final other = raft.activeIndex == 0 ? 1 : 0;
      final at = raft.crewPos(other);
      expect(ctrl.selectCrewAt(at), true, reason: 'the tap should land');
      expect(raft.activeIndex, other,
          reason: 'the tapped crew member takes the shot');
      ctrl.dispose();
    });

    test('tapping open deck or an enemy does nothing', () {
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      final before = raft.activeIndex;

      // Open water, far from anybody.
      expect(ctrl.selectCrewAt(const Offset(-400, 0)), false);
      // An enemy crew member — tapping the other side must never give you
      // control of their raft.
      final foe = ctrl.world.raftOf(1)!;
      expect(ctrl.selectCrewAt(foe.crewPos(0)), false,
          reason: 'you cannot take the helm of the enemy');
      expect(raft.activeIndex, before);
      expect(foe.activeIndex, 0);
      ctrl.dispose();
    });

    test('a body still tumbling cannot be selected or steered', () {
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      for (final c in raft.crew) {
        c.knock(const Offset(1, -0.5), 3, hitLocal: const Offset(0, -30));
      }
      expect(ctrl.canSteer, false,
          reason: 'nobody on this deck is on their feet');
      expect(ctrl.selectCrewAt(raft.crewPos(0)), false);
      ctrl.dispose();
    });

    test('the helm is only yours on your own turn', () {
      final ctrl = match();
      expect(ctrl.canSteer, true, reason: 'it opens on the player turn');
      // Hand the turn to the AI seat.
      ctrl.beginTurnForTest(1);
      expect(ctrl.canSteer, false,
          reason: 'the player must not walk anybody during the AI turn');
      expect(ctrl.selectCrewAt(ctrl.world.raftOf(1)!.crewPos(0)), false);
      ctrl.dispose();
    });
  });

  group('Walking', () {
    test('holding a direction actually moves them along the deck', () {
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      final i = raft.activeIndex;
      final before = raft.stationX(i) + raft.crew[i].offset.dx;

      walkFor(ctrl, 1, 0.5);
      final after = raft.stationX(i) + raft.crew[i].offset.dx;
      expect(after, greaterThan(before + 5),
          reason: 'half a second of walking should cover real ground');

      // …and the other way brings them back.
      walkFor(ctrl, -1, 0.5);
      final back = raft.stationX(i) + raft.crew[i].offset.dx;
      expect(back, lessThan(after));
      ctrl.dispose();
    });

    test('they follow the deck they are walking over, not a flat line', () {
      // The hulls carry real upper levels; a crew member walking onto one has
      // to rise with it or they would sink through the planks.
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      final i = raft.activeIndex;
      // Toward the bow: the active crew member starts on the stern roof, so
      // walking aft just parks them against the rail they are already next
      // to. Crossing the deck is what takes them down through the levels.
      final heights = <double>{};
      for (int step = 0; step < 22; step++) {
        walkFor(ctrl, 1, 0.2);
        final x = raft.stationX(i) + raft.crew[i].offset.dx;
        heights.add((raft.surfaceY(x) ?? 0).roundToDouble());
        // Whatever the surface is under them, that is where they stand.
        expect(raft.crew[i].offset.dy, closeTo(raft.surfaceY(x) ?? 0, 0.01),
            reason: 'the walker is not standing on the deck surface');
      }
      expect(heights.length, greaterThan(1),
          reason: 'walking the length of a galleon should change level');
      ctrl.dispose();
    });

    test('a walker can never step off their own raft', () {
      // The rails are a wall to somebody walking, even though a hard enough
      // hit can still throw them over one.
      for (final hull in RaftHull.all) {
        final ctrl = match(hull: hull.id);
        final raft = ctrl.world.raftOf(0)!;
        final i = raft.activeIndex;
        for (final dir in [1, -1]) {
          // Far longer than it takes to cross the widest deck.
          walkFor(ctrl, dir, 6);
          final x = raft.stationX(i) + raft.crew[i].offset.dx;
          expect(x.abs(), lessThanOrEqualTo(raft.deckHalf),
              reason: '${hull.id}: walked off the deck to $x');
          expect(raft.crew[i].drowned, false, reason: '${hull.id}: walked into the sea');
        }
        ctrl.dispose();
      }
    });

    test('releasing hands the body back to the simulation', () {
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      final i = raft.activeIndex;

      walkFor(ctrl, -1, 0.6);
      expect(raft.crew[i].steering, true, reason: 'still under the helm');

      ctrl.setWalk(0);
      expect(ctrl.walkDir, 0);
      expect(raft.crew[i].steering, false,
          reason: 'letting go must return them to the stepper, or the two '
              'fight over the same body');
      ctrl.dispose();
    });

    test('where you walk them is where they stay', () {
      // The complaint was that walking did nothing you could keep: let go of
      // the controls and the "shuffle back to your berth" stepper marched
      // them straight back to the spot they started from.
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      final i = raft.activeIndex;

      walkFor(ctrl, -1, 0.6);
      ctrl.setWalk(0);
      final stopped = raft.crew[i].offset.dx;
      expect(stopped.abs(), greaterThan(1), reason: 'they did move');

      for (int f = 0; f < 400; f++) {
        ctrl.world.update(1 / 60);
      }
      expect(raft.crew[i].offset.dx, closeTo(stopped, 0.5),
          reason: 'they walked themselves back to their berth, undoing the '
              'move the player just made');
      ctrl.dispose();
    });

    test('but a body that gets knocked down still goes back to its post', () {
      // Parking is a deliberate choice by the player, not a permanent
      // detachment from the raft's berths. Being thrown across the deck is
      // not a choice, so a recovered body still walks home.
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      final i = raft.activeIndex;
      walkFor(ctrl, -1, 0.6);
      ctrl.setWalk(0);
      expect(raft.crew[i].parked, true);

      raft.crew[i].knock(const Offset(1, -0.5), 3, hitLocal: const Offset(0, -30));
      expect(raft.crew[i].parked, false, reason: 'a knockdown un-parks them');
      for (int f = 0; f < 900; f++) {
        ctrl.world.update(1 / 60);
      }
      expect(raft.atStation(i), true,
          reason: 'they should have shuffled back to their berth');
      ctrl.dispose();
    });


    test('the legs cycle with the ground covered, not with the clock', () {
      // "The walk animation is too fast." It was: the phase advanced a flat
      // 0.30 cycles every frame, which is eighteen strides a second no
      // matter how slowly the body was actually moving — the legs scissored
      // while the character crept along.
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      final i = raft.activeIndex;
      final c = raft.crew[i];

      final fromX = raft.stationX(i) + c.offset.dx;
      final phase0 = c.walkPhase;
      walkFor(ctrl, 1, 1.0);
      final moved = (raft.stationX(i) + c.offset.dx - fromX).abs();
      final cycles = c.walkPhase - phase0;

      expect(moved, greaterThan(10), reason: 'this test needs real movement');
      // One cycle per stride of ground, whatever the frame rate or speed.
      expect(cycles, closeTo(moved / BattleConst.walkStride, 0.05),
          reason: 'the stride on screen does not match the ground covered');
      // And a sane cadence: a person walking covers a couple of strides a
      // second, not eighteen.
      expect(cycles, lessThan(4),
          reason: 'still sprinting on the spot: $cycles cycles in one second');
    });

    test('walking into the rail stops the legs too', () {
      // The clamp at the rail used to stop the body but not the phase, so a
      // crew member held against the railing ran on the spot forever.
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      final c = raft.crew[raft.activeIndex];
      walkFor(ctrl, 1, 6);
      final atRail = c.walkPhase;
      walkFor(ctrl, 1, 2);
      expect(c.walkPhase, closeTo(atRail, 0.01),
          reason: 'the legs kept cycling against the rail');
      ctrl.dispose();
    });
    test('a new turn releases the helm', () {
      final ctrl = match();
      final raft = ctrl.world.raftOf(0)!;
      walkFor(ctrl, 1, 0.3);
      expect(ctrl.walkDir, 1);

      ctrl.beginTurnForTest(1);
      expect(ctrl.walkDir, 0, reason: 'the helm does not carry across turns');
      expect(raft.crew.every((c) => !c.steering), true);
      ctrl.dispose();
    });
  });
}
