import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// What the enemy is standing on.
///
/// Every opponent used to be a raft — the same floating hull as the player's
/// in a different colour — so however much the hulls varied, the far side of
/// the water always read as "another one of me".
///
/// The variety that matters is the DECK PLAN rather than the picture: where
/// the crew can stand, what they can hide behind, and which of them a flat
/// shot can reach. All of that is the height-field the crew-walking, the
/// ragdoll settling and the shot collision already share, so what has to be
/// tested is that each kind produces a sound one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  Raft build(Emplacement kind, {String hull = 'sloop', String size = 'large'}) {
    final w = BattleWorld(map: GameMaps.all.first, seed: 5);
    final raft = Raft(
      playerIndex: 1,
      x: BattleConst.enemySlots.first,
      loadout: RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: 2),
      look: CrewLook.raider,
      label: 'FOE',
      facing: -1,
      emplacement: kind,
      crew: [for (int k = 0; k < 4; k++) Crew(hp: 100, maxHp: 100)],
    );
    w.addRaft(raft);
    return raft;
  }

  group('Every emplacement is a sound place to stand', () {
    test('the floor is continuous, on every kind and every hull', () {
      // The structural-integrity guarantee the deck profile exists to give:
      // a tumbling body can slide from the top tier to the bottom without
      // ever finding a crack. A new plan that breaks it would drop bodies
      // through the floor.
      for (final kind in Emplacement.values) {
        for (final hull in RaftHull.all) {
          for (final size in ['small', 'medium', 'large']) {
            final raft = build(kind, hull: hull.id, size: size);
            expect(raft.profile.isValid, true,
                reason: '${kind.name}/${hull.id}/$size has a gap in its deck');

            // And sampled across the whole width: no step the height-field
            // cannot express.
            double? previous;
            for (double x = -raft.deckHalf; x <= raft.deckHalf; x += 2) {
              final y = raft.surfaceY(x);
              expect(y, isNotNull,
                  reason: '${kind.name}: no surface at $x, inside the deck');
              if (previous != null) {
                expect((y! - previous).abs(), lessThan(26),
                    reason: '${kind.name}/${hull.id}/$size: the floor jumps '
                        'at $x — a body would fall through');
              }
              previous = y;
            }
          }
        }
      }
    });

    test('every crew member has somewhere to stand', () {
      for (final kind in Emplacement.values) {
        final raft = build(kind);
        for (int i = 0; i < raft.crew.length; i++) {
          final x = raft.stationX(i);
          expect(x.abs(), lessThanOrEqualTo(raft.deckHalf),
              reason: '${kind.name}: berth $i is over the side');
          expect(raft.surfaceY(x), isNotNull,
              reason: '${kind.name}: berth $i has no floor');
        }
      }
    });

    test('they genuinely differ in how much room and height they give', () {
      // If they all came out the same shape there would be no point to them.
      final widths = <double>{};
      final peaks = <double>{};
      for (final kind in Emplacement.values) {
        final raft = build(kind);
        widths.add(raft.deckHalf.roundToDouble());
        var peak = 0.0;
        for (double x = -raft.deckHalf; x <= raft.deckHalf; x += 3) {
          peak = max(peak, -(raft.surfaceY(x) ?? 0));
        }
        peaks.add(peak.roundToDouble());
      }
      expect(widths.length, greaterThan(3),
          reason: 'the emplacements are nearly all the same width');
      expect(peaks.length, greaterThan(3),
          reason: 'the emplacements are nearly all the same height');
    });

    test('more than one level to stand on, on the ones that promise it', () {
      // The point of an island, a ledge, a flotilla or a cove is that the
      // crew are NOT all on one plane.
      for (final kind in [
        Emplacement.island,
        Emplacement.ledge,
        Emplacement.flotilla,
        Emplacement.bay,
      ]) {
        final raft = build(kind);
        final levels = <int>{};
        for (double x = -raft.deckHalf; x <= raft.deckHalf; x += 3) {
          levels.add((-(raft.surfaceY(x) ?? 0) / 8).round());
        }
        expect(levels.length, greaterThan(2),
            reason: '${kind.name} is effectively one flat floor');
      }
    });

    test('land does not bob, and rafts do', () {
      final w = BattleWorld(map: GameMaps.all.first, seed: 5);
      for (final kind in Emplacement.values) {
        final raft = build(kind);
        w.elapsed = 1.7;
        final bob = w.bobOf(raft);
        if (EmplacementDef.of(kind).floats) {
          // Sampled across a cycle, because any one instant can be zero.
          var moved = false;
          for (final t in [0.3, 0.9, 1.5, 2.1]) {
            w.elapsed = t;
            if (w.bobOf(raft).abs() > 0.01) moved = true;
          }
          expect(moved, true, reason: '${kind.name} floats but never moves');
        } else {
          expect(bob, 0,
              reason: '${kind.name} is rooted to the seabed and should not '
                  'rise and fall on the swell');
        }
      }
    });
  });

  group('The opposition varies', () {
    GameController match(int seed) => GameController(
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
          seed: seed,
        );

    test('across a run of matches the enemy is not always a raft', () {
      final seen = <Emplacement>{};
      for (int seed = 0; seed < 60; seed++) {
        final ctrl = match(seed);
        seen.add(ctrl.world.raftOf(1)!.emplacement);
        ctrl.dispose();
      }
      expect(seen.length, greaterThan(2),
          reason: 'the enemy turned up on only ${seen.length} kind(s) of '
              'ground across sixty matches');
    });

    test('but a plain raft is still the common case', () {
      // The unusual ones have to stay unusual, or they stop reading as a
      // change of scene and become the norm.
      var rafts = 0;
      const runs = 120;
      for (int seed = 0; seed < runs; seed++) {
        final ctrl = match(seed);
        if (ctrl.world.raftOf(1)!.emplacement == Emplacement.raft) rafts++;
        ctrl.dispose();
      }
      expect(rafts / runs, greaterThan(0.25),
          reason: 'only ${(rafts / runs * 100).round()}% of enemies are on a '
              'raft — the variants have become the default');
      expect(rafts / runs, lessThan(0.75),
          reason: 'the enemy is on a plain raft '
              '${(rafts / runs * 100).round()}% of the time, so the variety '
              'barely shows');
    });

    test('the player is always on their own raft', () {
      // It is the one they chose, and the one they may have built on.
      for (int seed = 0; seed < 40; seed++) {
        final ctrl = match(seed);
        expect(ctrl.world.raftOf(0)!.emplacement, Emplacement.raft,
            reason: 'the player was put on an island they did not pick');
        ctrl.dispose();
      }
    });

    test('the same seed builds the same opposition', () {
      // Both devices in a hotspot match build the world from one seed, so a
      // different enemy on each would be two different matches.
      for (int seed = 0; seed < 30; seed++) {
        final a = match(seed);
        final b = match(seed);
        expect(a.world.raftOf(1)!.emplacement, b.world.raftOf(1)!.emplacement);
        a.dispose();
        b.dispose();
      }
    });
  });
}
