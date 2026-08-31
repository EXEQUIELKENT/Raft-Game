import 'dart:math';
import 'dart:ui';

import 'battle.dart';
import 'models.dart';

enum AiDifficulty { easy, normal, hard, expert }

class AiShot {
  /// Launch angle in degrees (6..85), matching the design's aim model.
  final double angle;

  /// Launch power, 10..100.
  final double power;

  final WeaponDef weapon;

  const AiShot({required this.angle, required this.power, required this.weapon});
}

/// Enemy aiming, ported from the design mockup.
///
/// It solves the range equation for a rough first guess at the power that
/// lands on the target at a near-45° lob, then *refines* that guess against
/// the real per-frame ballistic integrator (which accounts for launch
/// height, drag-free arcs and the actual gravity constant), and finally
/// spoils the answer with difficulty-scaled jitter. The refinement is what
/// keeps enemies honest: without it, shots launched from the muzzle's
/// height sailed long or fell short seemingly at random. The jitter is
/// deliberately softer on the low side, so a spoiled shot drifts past the
/// target far more often than it plops into the sea halfway there.
class AiController {
  final AiDifficulty difficulty;
  final Random _rnd;

  AiController(this.difficulty, {int? seed}) : _rnd = Random(seed);

  /// Jitter multiplier per difficulty — retuned for this game's ballistics:
  /// a power jitter of J translates to a landing miss of roughly
  /// `2 * J * range / power`, so at a 1200-unit lob with power ≈ 54 the
  /// scales below give easy ≈ ±260, normal ≈ ±130, hard ≈ ±55 and expert
  /// ≈ ±20 landing error. "Hard" therefore actually hits the deck (and the
  /// crew standing on it) most of the time, instead of splashing ±178
  /// around the target like the old untuned 0.4 scale did.
  double get _jitterScale => switch (difficulty) {
        AiDifficulty.easy => 0.6,
        AiDifficulty.normal => 0.3,
        AiDifficulty.hard => 0.125,
        AiDifficulty.expert => 0.05,
      };

  /// Plans a shot from [from] at [targetPos], firing in direction [facing].
  ///
  /// [baseJitter] lets an enemy archetype be innately more or less accurate
  /// than its difficulty alone implies (a raw Log Raider is shakier than a
  /// Captain), mirroring the design's per-type `jitter` field.
  AiShot plan({
    required Offset from,
    required Offset targetPos,
    required int facing,
    required List<WeaponDef> arsenal,
    double baseJitter = 10,
    double powerMultiplier = 1.0,
  }) {
    final weapon = _pickWeapon(arsenal);

    // A lob a little either side of 45°, which maximises range for a given
    // power and keeps shots arcing high enough to read on screen.
    final angle = (44 + (_rnd.nextDouble() * 8 - 4))
        .clamp(BattleConst.angleMin, BattleConst.angleMax);

    final range = (targetPos.dx - from.dx).abs();
    // Height the shot must fall *to*: crew stand on their raft's deck, a
    // couple of dozen units above the waterline. Solving the landing at the
    // water instead made every AI shot undershoot the deck by that height —
    // and since rafts are solid hulls now, the ball thudded into the player's
    // planking and never touched a crew capsule at all. This was the whole
    // "hard AI can't hit anything" bug.
    final targetHeight = max(0.0, BattleConst.waterY - targetPos.dy);
    var power = _solvePower(
      range: range,
      angleDeg: angle,
      weapon: weapon,
      powerMultiplier: powerMultiplier,
      drop: targetHeight,
    );

    // Refine against the real integrator: predict where this shot lands at
    // the target's height, then scale the power by how short/long it was.
    // Four passes collapse the error to under a couple of units — no more
    // mystery duds that thud into the player's hull planking short of the
    // crew standing on it.
    for (int i = 0; i < 4; i++) {
      final landing = _predictLanding(
        from: from,
        angleDeg: angle,
        power: power,
        facing: facing,
        weapon: weapon,
        powerMultiplier: powerMultiplier,
        drop: targetHeight,
      );
      if (landing <= 0) break;
      final overshoot = (landing - from.dx).abs();
      if (overshoot <= 0.5) break;
      final corrected = power * range / overshoot;
      final next = corrected.clamp(BattleConst.powerMin, BattleConst.powerMax);
      if ((next - power).abs() < 0.05) break;
      power = next;
    }

    final jitter = baseJitter * _jitterScale;
    final roll = (_rnd.nextDouble() * 2 - 1) * jitter;
    // Soften the short side: a shot falling 60% of its jitter short reads
    // as a blunder; the same jitter long reads as a near miss.
    final spoiled = (power + (roll < 0 ? roll * 0.6 : roll))
        .clamp(BattleConst.powerMin, BattleConst.powerMax);

    return AiShot(angle: angle, power: spoiled, weapon: weapon);
  }

  /// Where a shot fired at [angleDeg]/[power] comes down — the same
  /// per-frame integrator the simulation and the aim preview use, so a
  /// refined plan is exact rather than approximate. [drop] is the height
  /// the shot falls *to* (a crew member's deck plane, above the water), so
  /// the plan aims at where crew actually stand.
  static double _predictLanding({
    required Offset from,
    required double angleDeg,
    required double power,
    required int facing,
    required WeaponDef weapon,
    required double powerMultiplier,
    required double drop,
  }) {
    var p = from;
    var v = BattleWorld.launchVelocity(
      angleDeg: angleDeg,
      power: power,
      facing: facing,
      weapon: weapon,
      powerMultiplier: powerMultiplier,
    );
    final floor = BattleConst.waterY - drop;
    for (int i = 0; i < 400; i++) {
      p += v;
      v = Offset(v.dx, v.dy + BattleConst.gravity);
      if (p.dy > floor) break;
    }
    return p.dx;
  }

  /// Inverts the projectile range equation for the power that lands a shot
  /// at [range] while falling through [drop] of height. The closed form for
  /// flat ground is `v² sin 2θ / G`; with a launch height above the impact
  /// plane the ball travels farther, so the exact power is slightly lower —
  /// solved here with two Newton steps from the flat-ground seed, which the
  /// integrator refinement in [plan] then polishes to sub-unit accuracy.
  double _solvePower({
    required double range,
    required double angleDeg,
    required WeaponDef weapon,
    required double powerMultiplier,
    required double drop,
  }) {
    final r = angleDeg * pi / 180;
    final sin2 = sin(2 * r);
    if (sin2 <= 0.02) return BattleConst.powerMax;
    final g = BattleConst.gravity;
    final scale = BattleConst.velScale * weapon.speed * powerMultiplier;
    if (scale <= 0) return BattleConst.powerMax;

    var v = sqrt(max(60.0, range) * g / sin2);
    // Newton refinement: f(v) = v·cosθ/G · (v·sinθ + sqrt(v²sin²θ + 2·g·drop)) − range.
    for (int i = 0; i < 2; i++) {
      final vy = v * sin(r);
      final vy2 = vy * vy + 2 * g * drop;
      if (vy2 <= 0) break;
      final t = (vy + sqrt(vy2)) / g;
      final f = v * cos(r) * t - max(60.0, range);
      final df = cos(r) * (t + v / g);
      if (df.abs() < 1e-9) break;
      v = max(1.0, v - f / df);
    }
    return (v / scale).clamp(BattleConst.powerMin, BattleConst.powerMax);
  }

  /// Enemies mostly lob the basic shot; higher difficulties reach for heavier
  /// ordnance when they have it.
  WeaponDef _pickWeapon(List<WeaponDef> arsenal) {
    if (arsenal.isEmpty) return Weapons.starter;
    if (difficulty == AiDifficulty.easy) return arsenal.first;
    final heavy = arsenal.where((w) => w.damage > Weapons.starter.damage).toList();
    if (heavy.isEmpty) return arsenal.first;
    // Reach for something heavy roughly a third of the time on normal, more
    // often the harder the opponent is.
    final chance = switch (difficulty) {
      AiDifficulty.normal => 0.3,
      AiDifficulty.hard => 0.5,
      _ => 0.7,
    };
    return _rnd.nextDouble() < chance ? heavy[_rnd.nextInt(heavy.length)] : arsenal.first;
  }
}
