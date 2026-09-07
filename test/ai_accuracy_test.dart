import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';

/// How straight the enemies actually shoot.
///
/// These tests fly the planner's answer through the *real* simulation
/// integrator and measure where the ball crosses the target's plane, rather
/// than trusting the planner's own arithmetic. That is the only way to catch
/// the class of bug this suite was written for: a solver whose refinement
/// step diverges still returns a confident-looking answer, it is just wrong.
void main() {
  RaftLoadout loadout({String hull = 'log', String size = 'medium', int color = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  Raft raftAt(double x, {int facing = -1, int player = 1}) {
    final lo = loadout(color: player);
    return Raft(
      playerIndex: player,
      x: x,
      loadout: lo,
      look: CrewLook.raider,
      label: 'T',
      facing: facing,
      crew: [
        for (int i = 0; i < lo.crewCount; i++) Crew(hp: 100, maxHp: 100, bobPhase: i * 0.7),
      ],
    );
  }

  /// Flies a planned shot and returns where it crosses the target's height.
  double flyTo({
    required Offset from,
    required AiShot shot,
    required int facing,
    required double targetY,
  }) {
    var p = from;
    var v = BattleWorld.launchVelocity(
      angleDeg: shot.angle,
      power: shot.power,
      facing: facing,
      weapon: shot.weapon,
    );
    for (int i = 0; i < 2000; i++) {
      final next = p + v;
      if (next.dy > targetY && v.dy > 0) {
        final span = next.dy - p.dy;
        final t = span.abs() < 1e-9 ? 0.0 : ((targetY - p.dy) / span).clamp(0.0, 1.0);
        return p.dx + (next.dx - p.dx) * t;
      }
      p = next;
      v = Offset(v.dx, v.dy + BattleConst.gravity);
    }
    return p.dx;
  }

  group('Ballistic solution quality (no jitter)', () {
    // baseJitter 0 isolates the solver from the difficulty roll: whatever
    // error remains is the planner being wrong, not being sloppy on purpose.
    test('Lands within the hit radius across the whole engagement range', () {
      final shooter = raftAt(BattleConst.playerX, facing: 1, player: 0);

      for (final targetX in [500.0, 800.0, 1120.0, 1480.0, 1830.0, 2000.0]) {
        final target = raftAt(targetX);
        final aim = target.crewPos(0);
        final ai = AiController(AiDifficulty.expert, seed: 7);
        final shot = ai.plan(
          from: shooter.muzzle(),
          muzzleAt: (a) => shooter.muzzle(aimAngleDeg: a),
          targetPos: aim,
          facing: shooter.facing,
          arsenal: [Weapons.starter],
          baseJitter: 0,
        );
        final landed = flyTo(
          from: shooter.muzzle(aimAngleDeg: shot.angle),
          shot: shot,
          facing: shooter.facing,
          targetY: aim.dy,
        );
        expect((landed - aim.dx).abs(), lessThan(BattleConst.hitRadius),
            reason: 'range $targetX: solved shot must land inside the hit capsule '
                '(landed $landed, wanted ${aim.dx})');
      }
    });

    test('Solves for every weapon in the arsenal, not just the starter', () {
      final shooter = raftAt(BattleConst.playerX, facing: 1, player: 0);
      final target = raftAt(1120);
      final aim = target.crewPos(0);

      for (final w in Weapons.all) {
        final ai = AiController(AiDifficulty.expert, seed: 3);
        final shot = ai.plan(
          from: shooter.muzzle(),
          muzzleAt: (a) => shooter.muzzle(aimAngleDeg: a),
          targetPos: aim,
          facing: shooter.facing,
          arsenal: [w],
          baseJitter: 0,
        );
        expect(shot.weapon.id, w.id);
        final landed = flyTo(
          from: shooter.muzzle(aimAngleDeg: shot.angle),
          shot: shot,
          facing: shooter.facing,
          targetY: aim.dy,
        );
        expect((landed - aim.dx).abs(), lessThan(BattleConst.hitRadius),
            reason: '${w.id}: heavier/slower rounds must be solved too');
      }
    });

    test('Close targets pick a steeper arc rather than pinning power at the floor', () {
      // A near target is the case a fixed ~45 degree arc cannot serve: even
      // minimum power sails past it, so the planner has to loft the shot.
      final shooter = raftAt(BattleConst.playerX, facing: 1, player: 0);
      final target = raftAt(BattleConst.playerX + 260);
      final aim = target.crewPos(0);

      final shot = AiController(AiDifficulty.expert, seed: 1).plan(
        from: shooter.muzzle(),
        muzzleAt: (a) => shooter.muzzle(aimAngleDeg: a),
        targetPos: aim,
        facing: shooter.facing,
        arsenal: [Weapons.starter],
        baseJitter: 0,
      );

      expect(shot.power, greaterThan(BattleConst.powerMin + 0.5),
          reason: 'a shot pinned at minimum power has no correction left');
      final landed = flyTo(
        from: shooter.muzzle(aimAngleDeg: shot.angle),
        shot: shot,
        facing: shooter.facing,
        targetY: aim.dy,
      );
      expect((landed - aim.dx).abs(), lessThan(BattleConst.hitRadius));
    });

    test('Mirrored (left-firing) rafts solve just as well', () {
      final shooter = raftAt(1830, facing: -1, player: 0);
      final target = raftAt(600, facing: 1);
      final aim = target.crewPos(0);

      final shot = AiController(AiDifficulty.expert, seed: 11).plan(
        from: shooter.muzzle(),
        muzzleAt: (a) => shooter.muzzle(aimAngleDeg: a),
        targetPos: aim,
        facing: shooter.facing,
        arsenal: [Weapons.starter],
        baseJitter: 0,
      );
      final landed = flyTo(
        from: shooter.muzzle(aimAngleDeg: shot.angle),
        shot: shot,
        facing: shooter.facing,
        targetY: aim.dy,
      );
      expect((landed - aim.dx).abs(), lessThan(BattleConst.hitRadius));
    });

    test('Aims at the crew plane, not the waterline', () {
      // Crew stand well above the water; a solver that lands at sea level
      // thuds into the hull short of them every time.
      final shooter = raftAt(BattleConst.playerX, facing: 1, player: 0);
      final target = raftAt(1120);
      final aim = target.crewPos(0);
      expect(aim.dy, lessThan(BattleConst.waterY - 20),
          reason: 'the fixture must actually put crew above the water');

      final shot = AiController(AiDifficulty.expert, seed: 5).plan(
        from: shooter.muzzle(),
        muzzleAt: (a) => shooter.muzzle(aimAngleDeg: a),
        targetPos: aim,
        facing: shooter.facing,
        arsenal: [Weapons.starter],
        baseJitter: 0,
      );

      final atCrew = flyTo(
        from: shooter.muzzle(aimAngleDeg: shot.angle),
        shot: shot,
        facing: shooter.facing,
        targetY: aim.dy,
      );
      expect((atCrew - aim.dx).abs(), lessThan(BattleConst.hitRadius));
    });
  });

  group('Difficulty actually separates', () {
    /// Median absolute landing error over many rolls, in world units.
    double medianError(AiDifficulty diff, {double baseJitter = 10}) {
      final shooter = raftAt(BattleConst.playerX, facing: 1, player: 0);
      final target = raftAt(1480);
      final aim = target.crewPos(0);
      final errors = <double>[];
      for (int seed = 0; seed < 40; seed++) {
        final shot = AiController(diff, seed: seed).plan(
          from: shooter.muzzle(),
          muzzleAt: (a) => shooter.muzzle(aimAngleDeg: a),
          targetPos: aim,
          facing: shooter.facing,
          arsenal: [Weapons.starter],
          baseJitter: baseJitter,
        );
        final landed = flyTo(
          from: shooter.muzzle(aimAngleDeg: shot.angle),
          shot: shot,
          facing: shooter.facing,
          targetY: aim.dy,
        );
        errors.add((landed - aim.dx).abs());
      }
      errors.sort();
      return errors[errors.length ~/ 2];
    }

    test('Harder opponents are monotonically more accurate', () {
      final easy = medianError(AiDifficulty.easy);
      final normal = medianError(AiDifficulty.normal);
      final hard = medianError(AiDifficulty.hard);
      final expert = medianError(AiDifficulty.expert);

      expect(normal, lessThan(easy));
      expect(hard, lessThan(normal));
      expect(expert, lessThan(hard));
    });

    test('Hard and expert land hits, not near misses', () {
      // The whole point of the fix: a "hard" enemy should routinely put the
      // ball on the crew capsule rather than splashing beside the raft.
      expect(medianError(AiDifficulty.hard), lessThan(BattleConst.hitRadius),
          reason: 'hard should typically hit');
      expect(medianError(AiDifficulty.expert), lessThan(BattleConst.hitRadius * 0.6),
          reason: 'expert should hit comfortably');
    });

    test('Easy still misses often enough to be beatable', () {
      expect(medianError(AiDifficulty.easy), greaterThan(BattleConst.hitRadius * 0.5),
          reason: 'easy opponents are supposed to be sloppy');
    });
  });

  group('Robustness', () {
    test('Never returns a non-finite or out-of-range plan', () {
      final shooter = raftAt(BattleConst.playerX, facing: 1, player: 0);
      final rnd = Random(99);
      for (int i = 0; i < 200; i++) {
        final tx = BattleConst.playerX + rnd.nextDouble() * 1900;
        final ty = BattleConst.waterY - rnd.nextDouble() * 120;
        final shot = AiController(
          AiDifficulty.values[rnd.nextInt(AiDifficulty.values.length)],
          seed: i,
        ).plan(
          from: shooter.muzzle(),
          muzzleAt: (a) => shooter.muzzle(aimAngleDeg: a),
          targetPos: Offset(tx, ty),
          facing: shooter.facing,
          arsenal: Weapons.all,
          baseJitter: 10,
        );
        expect(shot.angle.isFinite, true);
        expect(shot.power.isFinite, true);
        expect(shot.angle, inInclusiveRange(BattleConst.angleMin, BattleConst.angleMax));
        expect(shot.power, inInclusiveRange(BattleConst.powerMin, BattleConst.powerMax));
      }
    });

    test('A target on top of the shooter degrades gracefully', () {
      final shooter = raftAt(BattleConst.playerX, facing: 1, player: 0);
      final shot = AiController(AiDifficulty.normal, seed: 2).plan(
        from: shooter.muzzle(),
        muzzleAt: (a) => shooter.muzzle(aimAngleDeg: a),
        targetPos: shooter.muzzle(),
        facing: shooter.facing,
        arsenal: [Weapons.starter],
        baseJitter: 10,
      );
      expect(shot.angle.isFinite, true);
      expect(shot.power, inInclusiveRange(BattleConst.powerMin, BattleConst.powerMax));
    });
  });
}
