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
/// Rather than searching a grid of candidate shots, it solves the range
/// equation for the power that would land exactly on the target at a roughly
/// 45° lob, then deliberately spoils that answer with difficulty-scaled
/// jitter. That keeps the AI honest (it uses the same ballistics the player
/// does) while making "easy" reliably sloppy and "expert" nearly exact.
class AiController {
  final AiDifficulty difficulty;
  final Random _rnd;

  AiController(this.difficulty, {int? seed}) : _rnd = Random(seed);

  /// Jitter multiplier per difficulty — the design's
  /// `{easy: 1.9, normal: 1, hard: .4}`, extended with an expert tier.
  double get _jitterScale => switch (difficulty) {
        AiDifficulty.easy => 1.9,
        AiDifficulty.normal => 1.0,
        AiDifficulty.hard => 0.4,
        AiDifficulty.expert => 0.15,
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
    final power = _solvePower(
      range: range,
      angleDeg: angle,
      weapon: weapon,
      powerMultiplier: powerMultiplier,
    );

    final jitter = baseJitter * _jitterScale;
    final spoiled = (power + (_rnd.nextDouble() * 2 - 1) * jitter)
        .clamp(BattleConst.powerMin, BattleConst.powerMax);

    return AiShot(angle: angle, power: spoiled, weapon: weapon);
  }

  /// Inverts the projectile range equation for the power that lands a shot at
  /// [range]. With `v = power * VS * speed * mult` and per-frame gravity `G`,
  /// flat range is `v^2 * sin(2θ) / G`, so the exact power is
  /// `sqrt(range * G / sin(2θ)) / (VS * speed * mult)`.
  double _solvePower({
    required double range,
    required double angleDeg,
    required WeaponDef weapon,
    required double powerMultiplier,
  }) {
    final r = angleDeg * pi / 180;
    final sin2 = sin(2 * r);
    if (sin2 <= 0.02) return BattleConst.powerMax;
    final v = sqrt(max(60.0, range) * BattleConst.gravity / sin2);
    final scale = BattleConst.velScale * weapon.speed * powerMultiplier;
    if (scale <= 0) return BattleConst.powerMax;
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
