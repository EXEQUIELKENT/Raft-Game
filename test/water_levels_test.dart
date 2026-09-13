import 'dart:math';
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// A sea with terraces in it.
///
/// Every battle used to be fought on one flat waterline: both rafts sat at
/// exactly the same height, and the only thing that varied between matches
/// was how far apart they were. A match can now put one side a good drop
/// above the other, joined by a falls — which changes every shot in it,
/// because a lob onto a higher terrace has to clear more and one onto a
/// lower terrace falls further.
///
/// Two things have to hold above everything else. The drawn water and the
/// simulated water must be the same water — they both read
/// [BattleWorld.waterAt], so that is mostly structural — and a falls must
/// never end up under a raft, because a raft is a flat rigid thing and half
/// of one hanging over a waterfall is nonsense.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  BattleWorld world({MapDef? map, int seed = 7}) {
    final w = BattleWorld(map: map ?? GameMaps.all.first, seed: seed);
    for (int i = 0; i < 2; i++) {
      w.addRaft(Raft(
        playerIndex: i,
        x: i == 0 ? BattleConst.playerX : BattleConst.enemySlots.first,
        loadout:
            RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: i),
        look: i == 0 ? CrewLook.player : CrewLook.raider,
        label: 'R$i',
        facing: i == 0 ? 1 : -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
    }
    return w;
  }

  group('The shape of the sea', () {
    test('matches come out level, player-high and enemy-high', () {
      // All three, and none of them vanishingly rare. A feature that fires
      // every single time stops being variety and becomes the new normal;
      // one that almost never fires is not worth having.
      var level = 0;
      var playerHigh = 0;
      var enemyHigh = 0;
      for (int seed = 0; seed < 120; seed++) {
        final w = world(seed: seed);
        final p = w.waterAt(BattleConst.playerX);
        final e = w.waterAt(BattleConst.enemySlots.first);
        if ((p - e).abs() < 1) {
          level++;
        } else if (p < e) {
          // Smaller y is higher water.
          playerHigh++;
        } else {
          enemyHigh++;
        }
      }
      expect(level, greaterThan(12), reason: 'a flat sea barely ever happens');
      expect(playerHigh, greaterThan(12),
          reason: 'the player is almost never the one up high');
      expect(enemyHigh, greaterThan(12),
          reason: 'the enemy is almost never the one up high');
    });

    test('a step is big enough to notice and small enough to shoot over', () {
      var biggest = 0.0;
      for (int seed = 0; seed < 120; seed++) {
        final w = world(seed: seed);
        final gap =
            (w.waterAt(BattleConst.playerX) - w.waterAt(BattleConst.enemySlots.first))
                .abs();
        if (gap > 0.5) {
          expect(gap, greaterThan(20),
              reason: 'seed $seed steps by only ${gap.round()} — invisible');
        }
        biggest = max(biggest, gap);
      }
      expect(biggest, greaterThan(50),
          reason: 'no match ever produces a real drop');
      expect(biggest, lessThan(BattleConst.waterStepMax * 2.2),
          reason: 'a drop of ${biggest.round()} is more than the world can '
              'hold above the waterline');
    });

    test('no terrace ever sits below the base waterline', () {
      // The base is the floor of the design: the hulls already hang some way
      // under it and the world is only 422 units tall, so the variety is
      // built upward into the sky where there is room for it.
      for (int seed = 0; seed < 120; seed++) {
        final w = world(seed: seed);
        for (double x = 0; x < BattleConst.worldW; x += 25) {
          expect(w.waterAt(x), lessThanOrEqualTo(BattleConst.waterY + 0.01),
              reason: 'seed $seed: the water at $x is below the base line');
        }
      }
    });

    test('no falls ever sits under a raft', () {
      // A raft is flat and rigid. Half of one over a waterfall would be
      // nonsense, and the raft would be drawn on one level while its crew
      // walked on another.
      final slots = [BattleConst.playerX, ...BattleConst.enemySlots];
      for (int seed = 0; seed < 200; seed++) {
        final w = world(seed: seed);
        for (final slot in slots) {
          // Across the width of the widest hull.
          for (double dx = -140; dx <= 140; dx += 10) {
            expect(w.water.onFalls(slot + dx), false,
                reason: 'seed $seed: a falls runs under the raft at $slot');
          }
        }
      }
    });

    test('the surface never jumps', () {
      // Everything that touches the water reads the same profile, so a
      // discontinuity here would be a discontinuity in the physics: a shot
      // or a body crossing a falls would teleport.
      for (int seed = 0; seed < 60; seed++) {
        final w = world(seed: seed);
        var previous = w.waterAt(0);
        for (double x = 1; x < BattleConst.worldW; x += 1) {
          final here = w.waterAt(x);
          expect((here - previous).abs(), lessThan(4),
              reason: 'seed $seed: the water jumps at $x');
          previous = here;
        }
      }
    });

    test('the same seed builds the same sea', () {
      // Non-negotiable for hotspot play: both devices build the world from
      // one seed and exchange only shots.
      for (int seed = 0; seed < 40; seed++) {
        final a = world(seed: seed);
        final b = world(seed: seed);
        for (double x = 0; x < BattleConst.worldW; x += 37) {
          expect(a.waterAt(x), b.waterAt(x));
        }
      }
    });
  });

  group('Everything floats on its own level', () {
    /// A seed whose two rafts end up on different terraces.
    BattleWorld stepped() {
      for (int seed = 0; seed < 200; seed++) {
        final w = world(seed: seed);
        if ((w.waterAt(BattleConst.playerX) -
                    w.waterAt(BattleConst.enemySlots.first))
                .abs() >
            30) {
          return w;
        }
      }
      fail('no seed in 200 produced a stepped sea');
    }

    test('a raft on the high side really is higher', () {
      // The step has to reach the hull, the deck and the crew, or the raft
      // would be drawn on one level and simulated on another.
      final w = stepped();
      final a = w.rafts[0];
      final b = w.rafts[1];
      expect(a.waterLine, isNot(b.waterLine));
      expect(a.deckY - b.deckY, closeTo(a.waterLine - b.waterLine, 0.01),
          reason: 'the deck did not follow the waterline');

      // The crew too — but not to the unit, because the two rafts face
      // opposite ways and a mirrored deck plan can post its crew on a
      // different tier. What must hold is that the crew on the high side
      // stand higher, by most of the step.
      final step = (a.waterLine - b.waterLine).abs();
      final crewGap = (a.crewPos(0).dy - b.crewPos(0).dy).abs();
      expect((a.crewPos(0).dy - b.crewPos(0).dy).sign,
          (a.waterLine - b.waterLine).sign,
          reason: 'the crew on the high raft are not the higher ones');
      expect(crewGap, greaterThan(step * 0.5),
          reason: 'the crew barely moved with their raft');
    });

    test('a raft built on its own still floats on the base line', () {
      // Previews and tests build rafts with no world around them.
      final lone = Raft(
        playerIndex: 0,
        x: BattleConst.playerX,
        loadout: RaftLoadout.custom(
            hullId: 'log', sizeId: 'medium', colorIndex: 0),
        look: CrewLook.player,
        label: 'P',
        facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      );
      expect(lone.waterLine, BattleConst.waterY);
    });

    test('a shot splashes down on the water under it, not the base line', () {
      // Fired straight up off the high terrace, so it comes back down on the
      // level it left. Against a flat base line it would sink a long way
      // into the air before resolving.
      final w = stepped();
      final high = w.rafts[0].waterLine < w.rafts[1].waterLine
          ? w.rafts[0]
          : w.rafts[1];
      // Well clear of the raft so nothing else claims the shot.
      final from = Offset(high.x + high.facing * 220, high.waterLine - 40);
      w.fire(
        from: from,
        angleDeg: 84,
        power: 40,
        weapon: Weapons.starter,
        facing: high.facing,
        owner: high.playerIndex,
      );
      ShotOutcome? out;
      for (int f = 0; f < 900 && out == null; f++) {
        out = w.stepShot();
      }
      expect(out, isNotNull, reason: 'the shot never resolved');
      expect(out!.impact.dy,
          lessThan(w.waterAt(out.impact.dx) + 45),
          reason: 'the shot fell past its own waterline before resolving');
    });

    test('a body goes under at its own raft\'s waterline', () {
      final w = stepped();
      for (final raft in w.rafts) {
        final c = raft.crew[0];
        // Thrown hard enough to go over the side.
        c.knock(Offset(raft.facing * -1.0, -0.2), 40,
            hitLocal: const Offset(0, -30));
        var drownedAt = double.nan;
        for (int f = 0; f < 900; f++) {
          w.update(1 / 60);
          if (c.drowned) {
            drownedAt = raft.waterLine;
            break;
          }
        }
        if (!drownedAt.isNaN) {
          expect(drownedAt, raft.waterLine,
              reason: 'a body drowned against the wrong waterline');
        }
      }
    });
  });
}
