import 'dart:math';
import 'dart:ui';
import 'models.dart';
import 'physics.dart';

enum AiDifficulty { easy, normal, hard, expert }

class AiController {
  final AiDifficulty difficulty;
  final Random _rnd = Random();

  AiController(this.difficulty);

  /// Compute (angle, power, weapon) for AI shooting from [from] at nearest enemy.
  /// Uses ballistic simulation with randomized error — no cheating.
  AiShot plan(PhysicsWorld world, PhysBody shooter, List<PhysBody> enemies, List<WeaponDef> arsenal) {
    if (enemies.isEmpty) {
      return AiShot(angle: -pi / 4, power: 0.5, weapon: arsenal.first);
    }
    // pick nearest living enemy
    enemies.sort((a, b) => (a.pos - shooter.pos).distance.compareTo((b.pos - shooter.pos).distance));
    final target = enemies.first.pos;

    // weapon selection heuristics
    WeaponDef weapon = _pickWeapon(arsenal, (target - shooter.pos).distance, world, target);

    // iterative ballistic search: try angles/powers, simulate, minimize miss distance
    double bestScore = double.infinity;
    double bestAngle = -pi / 4;
    double bestPower = 0.6;

    final facing = target.dx >= shooter.pos.dx ? 1.0 : -1.0;
    final dist = (target - shooter.pos).distance;

    // candidate angles (radians, negative = up)
    final baseAngles = <double>[];
    for (double deg = 20; deg <= 80; deg += 6) {
      final rad = -deg * pi / 180;
      baseAngles.add(facing > 0 ? rad : pi - rad);
    }
    final powers = <double>[];
    final rough = (dist / 700).clamp(0.25, 1.0);
    for (double p = max(0.2, rough - 0.3); p <= min(1.0, rough + 0.3); p += 0.1) {
      powers.add(p);
    }

    // difficulty controls search depth & error
    final int simSteps;
    final double errAngle, errPower;
    switch (difficulty) {
      case AiDifficulty.easy:
        simSteps = 40; errAngle = 0.14; errPower = 0.16; break;
      case AiDifficulty.normal:
        simSteps = 60; errAngle = 0.07; errPower = 0.09; break;
      case AiDifficulty.hard:
        simSteps = 90; errAngle = 0.03; errPower = 0.045; break;
      case AiDifficulty.expert:
        simSteps = 130; errAngle = 0.008; errPower = 0.015; break;
    }

    final coarse = difficulty == AiDifficulty.expert ? baseAngles : baseAngles.where((a) => baseAngles.indexOf(a) % 2 == 0).toList();

    for (final ang in coarse) {
      for (final pow_ in powers) {
        final score = _simulate(world, shooter.pos, ang, pow_, weapon, target, simSteps);
        if (score < bestScore) {
          bestScore = score;
          bestAngle = ang;
          bestPower = pow_;
        }
      }
    }

    // refine around best for hard/expert
    if (difficulty.index >= AiDifficulty.hard.index) {
      for (double da = -0.06; da <= 0.06; da += 0.02) {
        for (double dp = -0.05; dp <= 0.05; dp += 0.025) {
          final a = bestAngle + da;
          final p = (bestPower + dp).clamp(0.15, 1.0);
          final score = _simulate(world, shooter.pos, a, p, weapon, target, simSteps);
          if (score < bestScore) {
            bestScore = score;
            bestAngle = a;
            bestPower = p;
          }
        }
      }
    }

    // apply human-like error
    bestAngle += (_rnd.nextDouble() * 2 - 1) * errAngle;
    bestPower = (bestPower + (_rnd.nextDouble() * 2 - 1) * errPower).clamp(0.15, 1.0);

    return AiShot(angle: bestAngle, power: bestPower, weapon: weapon);
  }

  WeaponDef _pickWeapon(List<WeaponDef> arsenal, double dist, PhysicsWorld world, Offset target) {
    // expert/hard pick situationally; easy picks random-ish
    if (difficulty == AiDifficulty.easy) {
      return arsenal[_rnd.nextInt(min(arsenal.length, 3))];
    }
    // prefer explosion vs clustered blocks, heavy for close, rocket for far
    final hasBlocksNearTarget = world.bodies.any((b) =>
        b.type == BodyType.block && !b.dead && (b.pos - target).distance < 120);
    List<WeaponDef> preferred;
    if (hasBlocksNearTarget) {
      preferred = arsenal.where((w) => w.radius > 0 || w.structDamage > 1.4).toList();
    } else if (dist > 500) {
      preferred = arsenal.where((w) => w.speed > 1.1).toList();
    } else {
      preferred = arsenal.where((w) => w.damage >= 30).toList();
    }
    if (preferred.isEmpty) preferred = arsenal;
    return preferred[_rnd.nextInt(preferred.length)];
  }

  /// Quick ballistic sim matching PhysicsWorld projectile motion.
  double _simulate(PhysicsWorld world, Offset from, double angle, double power, WeaponDef weapon, Offset target, int steps) {
    final speed = weapon.speed * (280 + power * 620);
    var pos = from;
    var vel = Offset(cos(angle), sin(angle)) * speed;
    const dt = 1 / 30;
    double best = double.infinity;
    for (int i = 0; i < steps; i++) {
      vel += Offset(world.wind * 260, world.gravity * weapon.gravity) * dt;
      pos += vel * dt;
      final d = (pos - target).distance;
      if (d < best) best = d;
      if (pos.dy > world.waterLevel) break;
      // approximate: stop if hits any body aabb
      var hitSomething = false;
      for (final b in world.bodies) {
        if (b.dead || b.type == BodyType.debris) continue;
        if (b.aabb.inflate(4).contains(pos)) { hitSomething = true; break; }
      }
      if (hitSomething) break;
    }
    return best;
  }
}

class AiShot {
  final double angle;
  final double power;
  final WeaponDef weapon;
  AiShot({required this.angle, required this.power, required this.weapon});
}
