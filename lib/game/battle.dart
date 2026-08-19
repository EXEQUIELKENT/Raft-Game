import 'dart:math';
import 'dart:ui';

import 'maps.dart';
import 'models.dart';
import 'raft.dart';

/// ---------------------------------------------------------------------------
/// The battle simulation.
///
/// This is a direct port of the Claude Design mockup's model, and deliberately
/// *not* a rigid-body engine: rafts hold station at fixed x positions on open
/// water, a shot is a single ballistic point, and a hit subtracts HP from the
/// crew member it lands on. Everything runs in the design's own coordinate
/// space so its tuned constants (gravity, velocity scale, pull distances,
/// enemy slots) transfer without re-derivation.
///
///   world  2100 x 422      water line  y = 300
///   player x = 152         enemy slots [760, 1120, 1480, 1830]
///
/// The camera shows a [viewWidth]-wide window of that world, derived from the
/// device aspect so the full 422 of height always fits with no letterboxing.
/// ---------------------------------------------------------------------------

class BattleConst {
  BattleConst._();

  static const double worldW = 2100;
  static const double worldH = 422;
  static const double waterY = 300;

  /// Design-space gravity and velocity scale, per 60Hz frame.
  static const double gravity = 0.35;
  static const double velScale = 0.24;

  /// Pull-back aiming.
  static const double pullMax = 300;
  static const double deadzone = 16;
  static const double smooth = 0.34;

  /// Where the "fine tune" part of the pull begins (fraction of full pull).
  static const double fineZone = 0.66;

  static const double angleMin = 6;
  static const double angleMax = 85;
  static const double powerMin = 10;
  static const double powerMax = 100;

  static const double playerX = 152;
  static const List<double> enemySlots = [760, 1120, 1480, 1830];

  /// A shot within this many units of a crew member counts as a direct hit.
  static const double hitRadius = 34;
}

/// One character aboard a raft.
class Crew {
  double hp;
  final double maxHp;

  /// Phase offset so crew on the same raft don't bob in lockstep.
  final double bobPhase;

  /// 0 while alive; ramps to 1 as a defeated crew member sinks out of view.
  double sinkT = 0;

  Crew({required this.hp, required this.maxHp, this.bobPhase = 0});

  bool get alive => hp > 0;

  /// True once the sink animation has finished and they should stop drawing.
  bool get gone => !alive && sinkT >= 1;

  double get hpFrac => (hp / maxHp).clamp(0.0, 1.0);
}

/// Cosmetic archetype for an enemy crew — drives the renderer's hat/beard/
/// bandana choices and the label shown above the raft.
enum CrewLook { player, raider, ducker, pirate, captain }

class Raft {
  final int playerIndex;
  final double x;
  final RaftLoadout loadout;
  final CrewLook look;
  final String label;

  /// Which way this raft shoots: +1 fires to the right, -1 to the left.
  final int facing;

  final List<Crew> crew;

  /// Index of the crew member whose turn it is to shoot on this raft.
  int activeIndex = 0;

  Raft({
    required this.playerIndex,
    required this.x,
    required this.loadout,
    required this.look,
    required this.label,
    required this.facing,
    required this.crew,
  });

  bool get alive => crew.any((c) => c.alive);

  List<Crew> get living => crew.where((c) => c.alive).toList();

  double get hp => crew.fold(0.0, (s, c) => s + max(0.0, c.hp));

  double get maxHp => crew.fold(0.0, (s, c) => s + c.maxHp);

  double get hpFrac => maxHp <= 0 ? 0 : (hp / maxHp).clamp(0.0, 1.0);

  /// Deck surface height — where crew stand.
  double get deckY => BattleConst.waterY - loadout.width * loadout.hull.thickness * 0.5 - 6;

  /// World position of crew member [i].
  Offset crewPos(int i) => Offset(x + loadout.crewOffset(i), deckY - 20);

  /// The crew member currently taking this raft's shot, or null if none left.
  Crew? get activeCrew {
    if (activeIndex < 0 || activeIndex >= crew.length) return null;
    final c = crew[activeIndex];
    return c.alive ? c : null;
  }

  /// Where this raft's shots originate.
  Offset get muzzle {
    final i = activeIndex.clamp(0, max(0, crew.length - 1)).toInt();
    return crewPos(i) + Offset(facing * 18.0, -6);
  }

  /// Advances [activeIndex] to the next living crew member, wrapping around.
  void advanceCrew() {
    if (!alive) return;
    for (int k = 1; k <= crew.length; k++) {
      final idx = (activeIndex + k) % crew.length;
      if (crew[idx].alive) {
        activeIndex = idx;
        return;
      }
    }
  }

  /// Makes sure [activeIndex] points at somebody who is still alive.
  void ensureActiveAlive() {
    if (activeCrew != null) return;
    advanceCrew();
  }
}

/// A projectile in flight.
class Shot {
  Offset pos;
  Offset vel;
  final WeaponDef weapon;
  final int owner;
  final List<Offset> trail = [];

  Shot({required this.pos, required this.vel, required this.weapon, required this.owner});
}

/// A short-lived visual: the design's expanding `boom`, a water splash, or the
/// ripple under a raft. No physics attached.
class Fx {
  final Offset pos;
  final String kind; // boom | splash | ripple
  final Color color;
  final double size;
  double t = 0;
  final double life;

  Fx({required this.pos, required this.kind, required this.color, this.size = 60, this.life = 0.55});

  bool get done => t >= life;
  double get progress => (t / life).clamp(0.0, 1.0);
}

/// The result of resolving one shot, so the controller can drive turn flow
/// and messaging without re-deriving what happened.
class ShotOutcome {
  final bool hitSomething;
  final bool hitPlayerSide;
  final double damage;
  final Offset impact;

  const ShotOutcome({
    required this.hitSomething,
    required this.hitPlayerSide,
    required this.damage,
    required this.impact,
  });
}

/// A single trajectory-preview sample.
class TrajectoryDot {
  final Offset pos;
  final int index;
  const TrajectoryDot(this.pos, this.index);
}

class BattleWorld {
  final MapDef map;
  final GameRng rng;
  final List<Raft> rafts = [];
  final List<Fx> effects = [];

  Shot? shot;
  double elapsed = 0;

  /// Horizontal camera offset — the left edge of the visible window.
  double cam = 0;

  /// Width of the visible window in world units. Set by the renderer/screen
  /// from the device aspect ratio so the 422 world height always fits.
  double viewWidth = 870;

  BattleWorld({required this.map, required int seed}) : rng = GameRng(seed);

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------

  void addRaft(Raft raft) => rafts.add(raft);

  Raft? raftOf(int playerIndex) {
    for (final r in rafts) {
      if (r.playerIndex == playerIndex) return r;
    }
    return null;
  }

  List<Raft> get aliveRafts => rafts.where((r) => r.alive).toList();

  List<Raft> enemiesOf(int playerIndex) =>
      rafts.where((r) => r.playerIndex != playerIndex && r.alive).toList();

  // ---------------------------------------------------------------------------
  // Camera
  // ---------------------------------------------------------------------------

  /// Clamps a desired centre-x into a valid left-edge camera offset.
  double camFor(double centerX) =>
      (centerX - viewWidth / 2).clamp(0.0, max(0.0, BattleConst.worldW - viewWidth));

  void snapCam(double centerX) => cam = camFor(centerX);

  void easeCam(double centerX, double dt) {
    final target = camFor(centerX);
    cam += (target - cam) * (dt * 3.2).clamp(0.0, 1.0);
  }

  /// True when [worldX] sits off the right edge of the current view.
  bool isOffscreenRight(double worldX) => worldX - cam > viewWidth - 70;

  // ---------------------------------------------------------------------------
  // Ballistics
  // ---------------------------------------------------------------------------

  /// Initial velocity for a shot, in world units per 60Hz frame.
  static Offset launchVelocity({
    required double angleDeg,
    required double power,
    required int facing,
    required WeaponDef weapon,
    double powerMultiplier = 1.0,
  }) {
    final v = power * BattleConst.velScale * weapon.speed * powerMultiplier;
    final r = angleDeg * pi / 180;
    return Offset(facing * v * cos(r), -v * sin(r));
  }

  /// Where a shot fired at [angleDeg]/[power] would come down, used to frame
  /// the camera while aiming. Mirrors the design's `landing()`.
  double landingX({
    required Offset from,
    required double angleDeg,
    required double power,
    required int facing,
    required WeaponDef weapon,
    double powerMultiplier = 1.0,
  }) {
    var p = from;
    var v = launchVelocity(
      angleDeg: angleDeg, power: power, facing: facing,
      weapon: weapon, powerMultiplier: powerMultiplier,
    );
    for (int i = 0; i < 400; i++) {
      p += v;
      v = Offset(v.dx, v.dy + BattleConst.gravity);
      if (p.dy > BattleConst.waterY) break;
    }
    return p.dx;
  }

  /// Dotted arc preview. [limit] caps how far ahead it reveals — the design
  /// shows a longer arc while actively dragging than at rest.
  List<TrajectoryDot> trajectory({
    required Offset from,
    required double angleDeg,
    required double power,
    required int facing,
    required WeaponDef weapon,
    double powerMultiplier = 1.0,
    int limit = 16,
  }) {
    final out = <TrajectoryDot>[];
    var p = from;
    var v = launchVelocity(
      angleDeg: angleDeg, power: power, facing: facing,
      weapon: weapon, powerMultiplier: powerMultiplier,
    );
    for (int i = 0; i < 300; i++) {
      p += v;
      v = Offset(v.dx, v.dy + BattleConst.gravity);
      if (p.dy > BattleConst.waterY + 8) break;
      if (p.dx < -80 || p.dx > BattleConst.worldW + 80) break;
      if (i % 4 == 0) out.add(TrajectoryDot(p, i));
      if (out.length >= limit) break;
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Firing
  // ---------------------------------------------------------------------------

  void fire({
    required Offset from,
    required double angleDeg,
    required double power,
    required int facing,
    required WeaponDef weapon,
    required int owner,
    double powerMultiplier = 1.0,
  }) {
    shot = Shot(
      pos: from,
      vel: launchVelocity(
        angleDeg: angleDeg, power: power, facing: facing,
        weapon: weapon, powerMultiplier: powerMultiplier,
      ),
      weapon: weapon,
      owner: owner,
    );
  }

  /// Advances the in-flight shot by one frame. Returns a [ShotOutcome] on the
  /// frame it resolves (hit, splash-down or out of bounds), otherwise null.
  ShotOutcome? stepShot() {
    final s = shot;
    if (s == null) return null;

    s.trail.add(s.pos);
    if (s.trail.length > 18) s.trail.removeAt(0);

    s.pos += s.vel;
    s.vel = Offset(s.vel.dx, s.vel.dy + BattleConst.gravity);

    // Direct hit on any crew member not belonging to the shooter.
    for (final raft in rafts) {
      if (raft.playerIndex == s.owner || !raft.alive) continue;
      for (int i = 0; i < raft.crew.length; i++) {
        final c = raft.crew[i];
        if (!c.alive) continue;
        if ((s.pos - raft.crewPos(i)).distance < BattleConst.hitRadius) {
          return _resolve(s, raft, i);
        }
      }
    }

    // Splashdown / off the world.
    if (s.pos.dy > BattleConst.waterY + 40 ||
        s.pos.dx < -100 ||
        s.pos.dx > BattleConst.worldW + 100) {
      return _resolve(s, null, -1);
    }
    return null;
  }

  ShotOutcome? _resolve(Shot s, Raft? hitRaft, int crewIndex) {
    final impact = Offset(s.pos.dx, min(s.pos.dy, BattleConst.waterY + 12));
    double dealt = 0;
    bool hitPlayerSide = false;

    if (hitRaft != null && crewIndex >= 0) {
      final c = hitRaft.crew[crewIndex];
      final before = c.hp;
      c.hp = max(0, c.hp - s.weapon.damage);
      dealt += before - c.hp;
      hitPlayerSide = hitRaft.playerIndex == 0;
    }

    // Splash damage: everyone (on any raft but the shooter's) inside radius,
    // falling off with distance. The directly-hit crew member is skipped so a
    // direct hit isn't double-counted.
    if (s.weapon.splash > 0) {
      for (final raft in rafts) {
        if (raft.playerIndex == s.owner || !raft.alive) continue;
        for (int i = 0; i < raft.crew.length; i++) {
          if (identical(raft, hitRaft) && i == crewIndex) continue;
          final c = raft.crew[i];
          if (!c.alive) continue;
          final d = (impact - raft.crewPos(i)).distance;
          if (d > s.weapon.splash) continue;
          final falloff = 1 - (d / s.weapon.splash);
          final before = c.hp;
          c.hp = max(0, c.hp - s.weapon.damage * 0.6 * falloff);
          dealt += before - c.hp;
          if (raft.playerIndex == 0) hitPlayerSide = true;
        }
      }
    }

    effects.add(Fx(
      pos: impact,
      kind: hitRaft != null ? 'boom' : 'splash',
      color: s.weapon.color,
      size: s.weapon.splash > 0 ? s.weapon.splash * 1.1 : 62,
      life: 0.55,
    ));

    shot = null;
    for (final r in rafts) {
      r.ensureActiveAlive();
    }

    return ShotOutcome(
      hitSomething: hitRaft != null,
      hitPlayerSide: hitPlayerSide,
      damage: dealt,
      impact: impact,
    );
  }

  // ---------------------------------------------------------------------------
  // Per-frame update
  // ---------------------------------------------------------------------------

  void update(double dt) {
    elapsed += dt;
    for (final fx in effects) {
      fx.t += dt;
    }
    effects.removeWhere((f) => f.done);
    for (final raft in rafts) {
      for (final c in raft.crew) {
        if (!c.alive && c.sinkT < 1) {
          c.sinkT = (c.sinkT + dt * 1.4).clamp(0.0, 1.0);
        }
      }
    }
  }

  /// Vertical bob offset for a raft at the current time — the design's gentle
  /// `bob` keyframe, scaled by the scene's chop.
  double bobOf(Raft raft) =>
      sin(elapsed * 1.9 + raft.x * 0.01) * 3.2 * map.chop;
}

/// The player's aim as shaped by a pull-back drag.
class AimTarget {
  final double angle;
  final double power;
  final bool fine;
  const AimTarget({required this.angle, required this.power, required this.fine});
}

/// Maps a pull-back drag onto angle/power with the design's shaping: a dead
/// zone kills jitter, and past [BattleConst.fineZone] of the pull the
/// remaining travel maps to a much smaller slice of power, giving a precise
/// "fine tune" band at the end of a long drag.
///
/// Both components are measured so that pulling *away from the shot* is
/// positive, which is what makes this read as a slingshot:
///   [dx] = how far back the finger has been pulled (origin.x - finger.x for
///          a raft firing right), so more pull-back means more power.
///   [dy] = how far *down* the finger has been pulled (finger.y - origin.y),
///          so pulling down raises the launch angle.
///
/// Pulling straight back gives a flat 6° shot; pulling back and down arcs it
/// up toward 85°. Returns null inside the dead zone.
AimTarget? shapeAim(double dx, double dy) {
  final dist = sqrt(dx * dx + dy * dy);
  if (dist < BattleConst.deadzone) return null;

  final raw = min(1.0, (dist - BattleConst.deadzone) / (BattleConst.pullMax - BattleConst.deadzone));
  final shaped = raw < BattleConst.fineZone
      ? raw * 1.06
      : 0.70 + (raw - BattleConst.fineZone) * 0.88;

  final angle = (atan2(dy, max(4.0, dx)) * 180 / pi)
      .clamp(BattleConst.angleMin, BattleConst.angleMax);
  final power = (shaped * 100).roundToDouble()
      .clamp(BattleConst.powerMin, BattleConst.powerMax);

  return AimTarget(angle: angle, power: power, fine: raw > BattleConst.fineZone);
}

/// Eases current aim toward [target] so a shaky finger produces a steady
/// readout rather than a twitching one.
///
/// Both axes use [BattleConst.smooth] (0.34) directly. The design mockup
/// applied `SMOOTH * 10` to the angle and then divided the result by ten;
/// that lerp factor is 3.4, which overshoots the target every frame and
/// diverges — in practice the angle ping-pongs between the 6° and 85° clamps
/// and settles at whichever it hit last, so a careful drag reads as a flat 6°
/// shot no matter how you pull. A factor below 1 is what actually converges.
({double angle, double power}) easeAim(double angle, double power, AimTarget target) {
  final a = angle + (target.angle - angle) * BattleConst.smooth;
  final p = power + (target.power - power) * BattleConst.smooth;
  return (
    angle: (a * 10).roundToDouble() / 10, // 1 decimal place
    power: p.roundToDouble(),
  );
}
