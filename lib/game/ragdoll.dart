import 'dart:math';
import 'dart:ui';
import 'models.dart';
import 'physics.dart';

/// ---------------------------------------------------------------------------
/// Multi-segment ragdoll skeleton attached to a character [PhysBody].
///
/// The character's main [PhysBody] stays the single source of truth for
/// gameplay: gravity, collision with terrain/raft, water/edge elimination,
/// support checks and multiplayer sync are all still driven by the existing
/// single-body physics in [PhysicsWorld.step] exactly as before — nothing
/// about that path changes. A [Ragdoll] is a secondary skeleton of 10 bone
/// segments (head, torso, upper/lower arms, upper/lower legs) sharing 11
/// joint points, simulated with simple Verlet integration + iterative
/// position-based constraints (distance + hinge/swing angle limits). It is
/// gently tethered to the main body's position so it never visually drifts
/// away from the real hitbox, while being free to tumble, flail and settle
/// on its own between hits.
///
/// Two modes:
///  - Standing (kinematic): points are eased toward an upright reference
///    pose that tracks the main body's position/angle. Cheap — no solver.
///  - Ragdoll (active): points free-fall under gravity/wind, bones keep
///    their length via distance constraints, and joints are held inside
///    sensible bend/swing limits so limbs can't rotate infinitely or fold
///    through themselves. A hit kicks the nearest bone's endpoints, and the
///    shared-joint structure naturally propagates that momentum into
///    connected bones (a torso hit shakes both arms and both legs; an arm
///    hit mostly stays local to that arm) without any special-cased logic.
/// ---------------------------------------------------------------------------

enum BodyPart {
  head,
  torso,
  upperArmL,
  lowerArmL,
  upperArmR,
  lowerArmR,
  upperLegL,
  lowerLegL,
  upperLegR,
  lowerLegR,
}

enum _Pt { head, neck, pelvis, elbowL, handL, elbowR, handR, kneeL, footL, kneeR, footR }

class _Bone {
  final BodyPart part;
  final _Pt a, b;
  final double width;
  late final double restLen;
  _Bone(this.part, this.a, this.b, this.width);
}

/// World-space view of one bone, for rendering / external hit queries.
class RagdollBone {
  final BodyPart part;
  final Offset a;
  final Offset b;
  final double width;
  const RagdollBone(this.part, this.a, this.b, this.width);
  Offset get mid => Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  double get angle => atan2(b.dy - a.dy, b.dx - a.dx);
}

double _wrapAngle(double a) {
  while (a > pi) a -= 2 * pi;
  while (a < -pi) a += 2 * pi;
  return a;
}

class Ragdoll {
  // Reference "standing" pose: local offsets from the character's anchor
  // point (the main PhysBody's `pos`), unrotated. Anchored so the feet sit
  // at exactly +26 — the actual bottom edge of the character's 34x52
  // collision box used in PhysicsWorld.addCharacter (half-height 26) — so
  // the rendered feet land precisely on whatever surface the physics body
  // is actually resting on instead of hovering above or clipping through
  // it. The rest of the figure extends upward from there (head top ~-68),
  // giving a noticeably taller, more proportional silhouette (~94px vs the
  // old 52px box) with real arms where none existed before.
  static const Map<_Pt, Offset> _standing = {
    _Pt.neck: Offset(0, -46),
    _Pt.pelvis: Offset(0, -14),
    _Pt.head: Offset(0, -58),
    _Pt.elbowL: Offset(-15, -36),
    _Pt.handL: Offset(-17, -18),
    _Pt.elbowR: Offset(15, -36),
    _Pt.handR: Offset(17, -18),
    _Pt.kneeL: Offset(-7, 6),
    _Pt.footL: Offset(-7, 26),
    _Pt.kneeR: Offset(7, 6),
    _Pt.footR: Offset(7, 26),
  };

  static final List<_Bone> _skeleton = [
    _Bone(BodyPart.head, _Pt.neck, _Pt.head, 17),
    _Bone(BodyPart.torso, _Pt.neck, _Pt.pelvis, 21),
    _Bone(BodyPart.upperArmL, _Pt.neck, _Pt.elbowL, 11),
    _Bone(BodyPart.lowerArmL, _Pt.elbowL, _Pt.handL, 9),
    _Bone(BodyPart.upperArmR, _Pt.neck, _Pt.elbowR, 11),
    _Bone(BodyPart.lowerArmR, _Pt.elbowR, _Pt.handR, 9),
    _Bone(BodyPart.upperLegL, _Pt.pelvis, _Pt.kneeL, 13),
    _Bone(BodyPart.lowerLegL, _Pt.kneeL, _Pt.footL, 10.5),
    _Bone(BodyPart.upperLegR, _Pt.pelvis, _Pt.kneeR, 13),
    _Bone(BodyPart.lowerLegR, _Pt.kneeR, _Pt.footR, 10.5),
  ]..forEach((bo) => bo.restLen = (_standing[bo.b]! - _standing[bo.a]!).distance);

  // How strongly a hit on each part kicks its own endpoints (relative to
  // the main body's own knockback-derived velocity delta) — extremities
  // whip harder than root segments for the same impulse, and torso/head
  // hits rely on the shared-joint propagation below rather than a huge
  // local multiplier, matching "torso hit = full-body reaction, limb hit
  // stays mostly local unless the projectile is powerful".
  static const Map<BodyPart, double> _kickMul = {
    BodyPart.head: 1.9,
    BodyPart.torso: 1.0,
    BodyPart.upperArmL: 2.1,
    BodyPart.upperArmR: 2.1,
    BodyPart.lowerArmL: 2.6,
    BodyPart.lowerArmR: 2.6,
    BodyPart.upperLegL: 1.6,
    BodyPart.upperLegR: 1.6,
    BodyPart.lowerLegL: 2.0,
    BodyPart.lowerLegR: 2.0,
  };

  static const double _maxPointSpeed = 2600; // px/s safety backstop (see physics.dart's own caps)
  static const double _stiffness = 0.9;
  static const double _damping = 0.985;

  final Map<_Pt, Offset> pos = {};
  final Map<_Pt, Offset> prev = {};

  bool active = false;
  double activeUntil = 0;
  double _blend = 1.0; // 0 = just left ragdoll mode, 1 = fully tracking standing pose
  double _dt = 1 / 60;

  Ragdoll({required Offset pos, double angle = 0}) {
    for (final k in _Pt.values) {
      final w = pos + rotate(_standing[k]!, angle);
      this.pos[k] = w;
      prev[k] = w;
    }
  }

  bool get isRagdolling => active || _blend < 0.999;

  Offset get headCenter => pos[_Pt.head]!;
  static const double headRadius = 12;

  /// Bones in a sensible back-to-front draw order (legs, torso, arms; head last).
  List<RagdollBone> get bones =>
      _skeleton.map((bo) => RagdollBone(bo.part, pos[bo.a]!, pos[bo.b]!, bo.width)).toList();

  /// Angle (radians, 0 = pointing straight up) of the head/neck bone —
  /// used by the renderer to tilt the face naturally as the body tumbles.
  double get headTilt {
    final d = pos[_Pt.head]! - pos[_Pt.neck]!;
    return atan2(d.dx, -d.dy);
  }

  // -------------------------------------------------------------------------

  void update(double dt, PhysBody body, PhysicsWorld world) {
    _dt = dt <= 0 ? _dt : dt;

    // Auto-engage from any high-energy body state, even damage paths that
    // don't explicitly call [applyHit] (e.g. crush impacts) — keeps the
    // ragdoll visually honest about whatever the authoritative body is
    // doing. The threshold matches the same "genuinely hard landing" bar
    // used for crush damage in PhysicsWorld: a routine landing (spawning,
    // walking off a small step, settling after a short fall) easily clears
    // a low bar like 70px/s — a 3px fall alone gets there — which was
    // dropping the ragdoll into free-simulated "loose heap" mode for a
    // second or more after *every* ordinary landing instead of a clean
    // standing pose, even though the underlying body physics was stable.
    if (!active && (body.vel.distance > 260 || body.angularVel.abs() > 2.0)) {
      active = true;
      activeUntil = world.elapsed + 1.6;
    }
    if (body.dead) {
      active = true;
      activeUntil = double.infinity;
    }

    if (active) {
      _simulate(dt, body, world);
      if (world.elapsed > activeUntil && !body.dead) {
        if (body.vel.distance < 35 && body.angularVel.abs() < 0.5 && _centroidSpeed() < 40) {
          active = false;
          _blend = 0.0;
        } else {
          activeUntil = world.elapsed + 0.5; // still settling, give it more time
        }
      }
    } else {
      _updateStanding(dt, body, world);
    }
  }

  void _updateStanding(double dt, PhysBody body, PhysicsWorld world) {
    _blend = min(1.0, _blend + dt / 0.4);
    final followRate = 6.0 + _blend * 9.0;
    final t = (dt * followRate).clamp(0.0, 1.0);
    final idle = sin(world.elapsed * 3 + body.id) * 1.4;
    for (final k in _Pt.values) {
      var local = _standing[k]!;
      // tiny idle sway on hands/feet so a standing character doesn't look frozen
      if (k == _Pt.handL || k == _Pt.footL) local += Offset(0, idle * 0.4);
      if (k == _Pt.handR || k == _Pt.footR) local += Offset(0, -idle * 0.4);
      final target = body.pos + rotate(local, body.angle);
      final np = Offset.lerp(pos[k]!, target, t)!;
      pos[k] = np;
      prev[k] = np; // zero implied velocity while kinematic, so a future hit starts clean
    }
  }

  void _simulate(double dt, PhysBody body, PhysicsWorld world) {
    final g = world.gravity;
    final windAccel = world.wind * 70;
    for (final k in _Pt.values) {
      final cur = pos[k]!;
      final prv = prev[k]!;
      var step = (cur - prv) * _damping;
      final maxStep = _maxPointSpeed * dt;
      final stepLen = step.distance;
      if (stepLen > maxStep) step = step * (maxStep / stepLen);
      final next = cur + step + Offset(windAccel, g) * dt * dt;
      prev[k] = cur;
      pos[k] = next;
    }

    for (int iter = 0; iter < 4; iter++) {
      for (final bo in _skeleton) {
        _solveDistance(bo);
      }
      // hinge joints: can't fold flatter than ~20-25deg, but may straighten fully
      _clampAngle(_Pt.elbowL, _Pt.neck, _Pt.handL, 0.35, pi);
      _clampAngle(_Pt.elbowR, _Pt.neck, _Pt.handR, 0.35, pi);
      _clampAngle(_Pt.kneeL, _Pt.pelvis, _Pt.footL, 0.35, pi);
      _clampAngle(_Pt.kneeR, _Pt.pelvis, _Pt.footR, 0.35, pi);
      // shoulder swing: bounded cone around the "hanging straight down
      // alongside the torso" direction (pelvis, as seen from neck).
      _clampAngle(_Pt.neck, _Pt.pelvis, _Pt.elbowL, 0, 2.7);
      _clampAngle(_Pt.neck, _Pt.pelvis, _Pt.elbowR, 0, 2.7);
      // hip/neck swing: bounded cone around the direction that *continues*
      // the torso bone past the pivot (down past the pelvis for hips, up
      // past the neck for the head) — flipRef=true reflects the reference
      // vector so "straight" reads as 0 bend instead of a 180° violation of
      // the standing pose (which is exactly what "continuing the torso
      // line" means for a normal upright stance).
      _clampAngle(_Pt.pelvis, _Pt.neck, _Pt.kneeL, 0, 2.6, flipRef: true);
      _clampAngle(_Pt.pelvis, _Pt.neck, _Pt.kneeR, 0, 2.6, flipRef: true);
      _clampAngle(_Pt.neck, _Pt.pelvis, _Pt.head, 0, 2.3, flipRef: true);
      for (final k in _Pt.values) {
        _collidePoint(k, world);
      }
    }

    // Gentle tether back toward the real hitbox so the skeleton never
    // detaches from what gameplay/collision actually considers the
    // character to be — strong enough to keep it in the same neighbourhood,
    // weak enough to let it tumble freely relative to that anchor.
    final centroid = _centroid();
    final drift = body.pos - centroid;
    final pull = drift * min(1.0, dt * 3.0);
    if (pull != Offset.zero) {
      for (final k in _Pt.values) {
        pos[k] = pos[k]! + pull;
      }
    }
  }

  void _solveDistance(_Bone bo) {
    final a = pos[bo.a]!, b = pos[bo.b]!;
    final delta = b - a;
    final dist = delta.distance;
    if (dist < 0.0001) return;
    final diff = (dist - bo.restLen) / dist;
    final corr = delta * (diff * 0.5 * _stiffness);
    pos[bo.a] = a + corr;
    pos[bo.b] = b - corr;
  }

  /// Clamps the signed angle of (free-pivot) relative to the reference axis
  /// to [lo, hi] (both measured as |angle|, sign preserved) by rotating
  /// [free] around [pivot]. Used both as a hinge limit (lo>0 stops total
  /// fold-through, hi=pi allows full extension) and a swing/cone limit
  /// (lo=0, hi=max swing away from the reference axis).
  ///
  /// The reference axis normally points from [pivot] toward [ref] (i.e.
  /// "toward the parent joint"). Pass [flipRef]=true to instead use the
  /// axis that *continues* the parent bone past [pivot] (pointing away
  /// from [ref]) — the right reference for a joint whose natural resting
  /// pose extends the parent limb in a straight line (hips, neck) rather
  /// than folding back toward it (shoulders, elbows, knees).
  void _clampAngle(_Pt pivot, _Pt ref, _Pt free, double lo, double hi, {bool flipRef = false}) {
    final p = pos[pivot]!;
    final vRef = (flipRef ? p - pos[ref]! : pos[ref]! - p);
    final vFree = pos[free]! - p;
    final refLen = vRef.distance, freeLen = vFree.distance;
    if (refLen < 0.001 || freeLen < 0.001) return;
    final angRef = atan2(vRef.dy, vRef.dx);
    final angFree = atan2(vFree.dy, vFree.dx);
    final diff = _wrapAngle(angFree - angRef);
    final mag = diff.abs().clamp(lo, hi);
    if ((mag - diff.abs()).abs() < 1e-9) return;
    final sign = diff < 0 ? -1.0 : 1.0;
    final newAng = angRef + sign * mag;
    pos[free] = p + Offset(cos(newAng), sin(newAng)) * freeLen;
  }

  Offset? _penetration(Offset pt, PhysBody b) {
    final local = rotate(pt - b.pos, -b.angle);
    final hw = b.size.width / 2, hh = b.size.height / 2;
    if (local.dx.abs() > hw || local.dy.abs() > hh) return null;
    final dx = hw - local.dx.abs();
    final dy = hh - local.dy.abs();
    final Offset nLocal;
    final double push;
    if (dx < dy) {
      nLocal = Offset(local.dx > 0 ? 1 : -1, 0);
      push = dx;
    } else {
      nLocal = Offset(0, local.dy > 0 ? 1 : -1);
      push = dy;
    }
    return rotate(nLocal, b.angle) * (push + 0.5);
  }

  void _collidePoint(_Pt k, PhysicsWorld world) {
    var p = pos[k]!;
    for (final b in world.bodies) {
      if (b.dead || b.type != BodyType.block) continue;
      final push = _penetration(p, b);
      if (push != null) {
        pos[k] = p + push;
        p = pos[k]!;
        // damped, roughly-inelastic contact: kill most of the velocity
        // component that drove the point into the surface
        prev[k] = Offset.lerp(prev[k]!, pos[k]!, 0.6)!;
      }
    }
  }

  Offset _centroid() {
    var sum = Offset.zero;
    for (final k in _Pt.values) {
      sum += pos[k]!;
    }
    return sum / _Pt.values.length.toDouble();
  }

  double _centroidSpeed() {
    var sum = 0.0;
    for (final k in _Pt.values) {
      sum += (pos[k]! - prev[k]!).distance;
    }
    return (sum / _Pt.values.length) / _dt;
  }

  // -------------------------------------------------------------------------

  /// Finds the bone segment nearest to [point] (hit-location detection).
  BodyPart hitTest(Offset point) {
    _Bone best = _skeleton.first;
    double bestT = 0.5;
    double bestDistSq = double.infinity;
    for (final bo in _skeleton) {
      final a = pos[bo.a]!, b = pos[bo.b]!;
      final ab = b - a;
      final len2 = ab.distanceSquared;
      double t = len2 < 0.0001 ? 0.0 : (((point - a).dx * ab.dx + (point - a).dy * ab.dy) / len2);
      t = t.clamp(0.0, 1.0);
      final closest = a + ab * t;
      final d2 = (point - closest).distanceSquared;
      if (d2 < bestDistSq) {
        bestDistSq = d2;
        best = bo;
        bestT = t;
      }
    }
    _lastHitT = bestT;
    _lastHitBone = best;
    return best.part;
  }

  double _lastHitT = 0.5;
  _Bone? _lastHitBone;

  /// For a lower-limb/extremity point, the next point one joint further up
  /// the same chain toward the torso. Used by [applyHit] to give a struck
  /// limb an immediate head-start on moving *together* — without this, a
  /// kick applied only to (say) the foot has to wait several frames for the
  /// distance-constraint solver to drag the knee and upper leg along behind
  /// it, which reads as a weak, delayed reaction instead of the leg
  /// visibly swinging as a whole right away.
  static const Map<_Pt, _Pt> _chainParent = {
    _Pt.footL: _Pt.kneeL, _Pt.kneeL: _Pt.pelvis,
    _Pt.footR: _Pt.kneeR, _Pt.kneeR: _Pt.pelvis,
    _Pt.handL: _Pt.elbowL, _Pt.elbowL: _Pt.neck,
    _Pt.handR: _Pt.elbowR, _Pt.elbowR: _Pt.neck,
    _Pt.head: _Pt.neck,
    _Pt.pelvis: _Pt.neck,
  };

  /// Applies location-based impact physics: figures out which bone [hitPos]
  /// struck, activates ragdoll mode, and kicks that bone's two joints
  /// (weighted by how close the impact was to each end), plus a smaller
  /// share propagated one joint further up the chain (see [_chainParent])
  /// so the whole limb visibly reacts immediately. Because joints are also
  /// *shared* between adjacent bones, the kick keeps propagating further
  /// through connected limbs during the next few constraint-solve
  /// iterations — a torso hit rattles both arms and legs, an arm hit mostly
  /// stays local — without any per-body-part special casing.
  void applyHit(Offset hitPos, Offset impulse, PhysBody body, PhysicsWorld world) {
    if (impulse.distance < 0.5) {
      // still worth flagging active (e.g. crush/burn ticks with ~0 impulse
      // rely on the velocity-based auto-engage in update()); nothing to kick.
      return;
    }
    active = true;
    activeUntil = max(activeUntil, world.elapsed + 3.0);

    hitTest(hitPos);
    final bone = _lastHitBone!;
    final t = _lastHitT;
    final mul = _kickMul[bone.part] ?? 1.0;
    final baseVel = impulse / max(body.mass, 0.6);
    var dv = baseVel * mul;
    final sp = dv.distance;
    if (sp > _maxPointSpeed) dv = dv * (_maxPointSpeed / sp);

    final kicks = <_Pt, Offset>{};
    void add(_Pt k, Offset v) => kicks[k] = (kicks[k] ?? Offset.zero) + v;

    final dvA = dv * (1 - t), dvB = dv * t;
    add(bone.a, dvA);
    add(bone.b, dvB);
    final parentA = _chainParent[bone.a];
    final parentB = _chainParent[bone.b];
    if (parentA != null) add(parentA, dvA * 0.4);
    if (parentB != null) add(parentB, dvB * 0.4);

    for (final entry in kicks.entries) {
      _kick(entry.key, entry.value);
    }
  }

  void _kick(_Pt k, Offset dv) {
    prev[k] = pos[k]! - dv * _dt;
  }
}
