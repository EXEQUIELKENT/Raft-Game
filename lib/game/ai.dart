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

/// Enemy aiming.
///
/// The planner picks the *angle* as well as the power. For each candidate
/// arc it seeds a power from the closed-form range equation, polishes that
/// against the real per-frame ballistic integrator, and scores the result by
/// how close the predicted impact lands to the target — then the best arc's
/// answer is spoiled by difficulty-scaled jitter.
///
/// Three things here matter more than anything else for whether an enemy
/// actually hits:
///
///  * **The refinement is square-root, not linear.** Range grows with the
///    *square* of launch speed (v^2 sin2t / g), so a shot that flew twice as
///    far as wanted needs v/sqrt(2), not v/2. Correcting linearly overshoots
///    the other way every pass, so the loop oscillated instead of converging
///    and often exited on its iteration cap still tens of units off — which
///    is what "the AI fires inaccurately" looked like.
///  * **The landing is interpolated inside the crossing frame.** A fast shot
///    covers 20+ units per frame; reporting the frame's end position quantised
///    every prediction by that much and put a floor under how accurate any
///    amount of refinement could be.
///  * **The plan is made from the muzzle of the arc it actually picks.** The
///    muzzle rides out along the aim line (see Raft.muzzle), so planning from
///    a nominal 45 degree muzzle and then firing at 51 moved the origin out
///    from under the solution.
class AiController {
  final AiDifficulty difficulty;
  final Random _rnd;

  AiController(this.difficulty, {int? seed}) : _rnd = Random(seed);

  /// Jitter multiplier per difficulty — retuned for this game's ballistics:
  /// a power jitter of J translates to a landing miss of roughly
  /// `2 * J * range / power`, so at a 1200-unit lob with power around 54 the
  /// scales below give easy about +/-260, normal +/-110, hard +/-40 and
  /// expert +/-13 units of landing error. Now that the solver itself
  /// converges, this jitter is the *only* remaining source of miss — so an
  /// expert genuinely snipes, and an easy opponent is sloppy on purpose
  /// rather than by accident.
  double get _jitterScale => switch (difficulty) {
        AiDifficulty.easy => 0.6,
        AiDifficulty.normal => 0.26,
        AiDifficulty.hard => 0.09,
        AiDifficulty.expert => 0.03,
      };

  /// Candidate launch arcs, in degrees, tried in preference order.
  ///
  /// 45 degrees maximises range, so it is the natural first choice — but a
  /// bad one when the target is close enough that even [BattleConst.powerMin]
  /// sails past it, or far enough that [BattleConst.powerMax] falls short.
  /// Steeper arcs shorten the throw for a given power, so offering the solver
  /// a spread lets it pick an arc whose power sits comfortably inside the
  /// legal band instead of pinned against a clamp with no way to correct.
  static const List<double> _arcs = [45, 52, 38, 60, 32, 68, 75, 25, 82];

  /// Plans a shot at [targetPos], firing in direction [facing].
  ///
  /// [muzzleAt] resolves the shot's origin for a given launch angle — the
  /// muzzle swings along the aim line, so the plan must be built from the
  /// origin the chosen arc will actually fire from. [from] is the fallback
  /// origin when no resolver is supplied.
  ///
  /// [baseJitter] lets an enemy archetype be innately more or less accurate
  /// than its difficulty alone implies (a raw Log Raider is shakier than a
  /// Captain), mirroring the design's per-type `jitter` field.
  AiShot plan({
    required Offset from,
    required Offset targetPos,
    required int facing,
    required List<WeaponDef> arsenal,
    Offset Function(double angleDeg)? muzzleAt,
    double baseJitter = 10,
    double powerMultiplier = 1.0,
  }) {
    final weapon = _pickWeapon(arsenal);

    // Height the shot must fall *to*: crew stand on their raft's deck, well
    // above the waterline, and higher again on a raised platform. Solving the
    // landing at the water instead makes every shot undershoot by that
    // height — and since hulls are solid, the ball thuds into the planking
    // short of the crew standing on it.
    final targetHeight = BattleConst.waterY - targetPos.dy;

    _Solution? best;
    for (final arc in _arcs) {
      final angle = arc.clamp(BattleConst.angleMin, BattleConst.angleMax).toDouble();
      final origin = muzzleAt?.call(angle) ?? from;
      final sol = _solveArc(
        origin: origin,
        targetX: targetPos.dx,
        angleDeg: angle,
        weapon: weapon,
        facing: facing,
        powerMultiplier: powerMultiplier,
        targetHeight: targetHeight,
      );
      if (sol == null) continue;
      if (best == null || sol.score < best.score) best = sol;
      // A dead-on solution with power comfortably off both clamps is as good
      // as it gets; no need to try flatter or loftier arcs.
      if (sol.score < 1.0) break;
    }

    if (best == null) {
      return AiShot(
        angle: 45,
        power: (BattleConst.powerMin + BattleConst.powerMax) / 2,
        weapon: weapon,
      );
    }

    final jitter = baseJitter * _jitterScale;
    final roll = (_rnd.nextDouble() * 2 - 1) * jitter;
    // Soften the short side: a shot falling 60% of its jitter short reads as
    // a blunder; the same jitter long reads as a near miss.
    final spoiled = (best.power + (roll < 0 ? roll * 0.6 : roll))
        .clamp(BattleConst.powerMin, BattleConst.powerMax);

    return AiShot(angle: best.angle, power: spoiled, weapon: weapon);
  }

  /// Solves one candidate arc, returning the power that lands nearest the
  /// target and a score (lower is better) that also penalises answers pinned
  /// against a power clamp — those are the arcs that physically cannot reach.
  _Solution? _solveArc({
    required Offset origin,
    required double targetX,
    required double angleDeg,
    required WeaponDef weapon,
    required int facing,
    required double powerMultiplier,
    required double targetHeight,
  }) {
    final range = (targetX - origin.dx).abs();
    if (range < 1) return null;

    // Height the shot falls through, from this arc's own muzzle down to the
    // target's plane.
    final drop = (BattleConst.waterY - targetHeight) - origin.dy;

    var power = _seedPower(
      range: range,
      angleDeg: angleDeg,
      weapon: weapon,
      powerMultiplier: powerMultiplier,
      drop: drop,
    );

    double landing(double p) => _predictLanding(
          from: origin,
          angleDeg: angleDeg,
          power: p,
          facing: facing,
          weapon: weapon,
          powerMultiplier: powerMultiplier,
          targetHeight: targetHeight,
        );

    // Polish against the real integrator. Range scales with v^2, so the
    // correction is the SQUARE ROOT of the range ratio; a linear correction
    // overshoots every pass and never settles.
    for (int i = 0; i < 6; i++) {
      final flown = (landing(power) - origin.dx).abs();
      if (flown < 1e-3) break;
      final next = (power * sqrt(range / flown))
          .clamp(BattleConst.powerMin, BattleConst.powerMax);
      final settled = (next - power).abs() < 0.01;
      power = next;
      if (settled) break;
    }

    // Score: distance from the target, plus a penalty for an arc that only
    // "fits" by pinning power against a clamp — it has no correction left.
    var score = (landing(power) - targetX).abs();
    if (power <= BattleConst.powerMin + 0.01 || power >= BattleConst.powerMax - 0.01) {
      score += 40;
    }
    return _Solution(angle: angleDeg, power: power, score: score);
  }

  /// Where a shot fired at [angleDeg]/[power] comes down — the same per-frame
  /// integrator the simulation and the aim preview use, so a refined plan is
  /// exact rather than approximate. The crossing is interpolated *within* the
  /// frame that breaks the target's plane rather than snapped to the frame
  /// boundary.
  static double _predictLanding({
    required Offset from,
    required double angleDeg,
    required double power,
    required int facing,
    required WeaponDef weapon,
    required double powerMultiplier,
    required double targetHeight,
  }) {
    var p = from;
    var v = BattleWorld.launchVelocity(
      angleDeg: angleDeg,
      power: power,
      facing: facing,
      weapon: weapon,
      powerMultiplier: powerMultiplier,
    );
    final floor = BattleConst.waterY - targetHeight;
    for (int i = 0; i < 600; i++) {
      final next = p + v;
      if (next.dy > floor && v.dy > 0) {
        final span = next.dy - p.dy;
        final t = span.abs() < 1e-9 ? 0.0 : ((floor - p.dy) / span).clamp(0.0, 1.0);
        return p.dx + (next.dx - p.dx) * t;
      }
      p = next;
      v = Offset(v.dx, v.dy + BattleConst.gravity);
    }
    return p.dx;
  }

  /// Closed-form seed for the power that lands a shot at [range] while
  /// falling through [drop] of height: `v^2 sin2t / g` for flat ground, then
  /// two Newton steps to account for the launch height. The integrator
  /// refinement in [_solveArc] polishes this to sub-unit accuracy.
  double _seedPower({
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
    for (int i = 0; i < 2; i++) {
      final vy = v * sin(r);
      final vy2 = vy * vy + 2 * g * max(0.0, drop);
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

/// One candidate arc's answer, used to pick between them.
class _Solution {
  final double angle;
  final double power;
  final double score;
  const _Solution({required this.angle, required this.power, required this.score});
}
