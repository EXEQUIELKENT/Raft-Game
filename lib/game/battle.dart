import 'dart:math';
import 'dart:ui';

import 'maps.dart';
import 'models.dart';
import 'raft.dart';

/// ---------------------------------------------------------------------------
/// The battle simulation.
///
/// Rafts hold station at fixed x positions on open water, a shot is a single
/// ballistic point, and a hit subtracts HP from the crew member it lands on
/// *and* knocks them about (see [Crew]) — the crew bodies are the only
/// rigid-ish thing in here.
///
///   world  3210 x 422      water line  y = 300
///   player x = 210         enemy slots [1500, 1900, 2300, 2700]
///
/// The rafts are deliberately a long way apart: the player is meant to lob
/// blind across open water at a raft they cannot see (see [BattleWorld]'s
/// camera lock), so the gap has to be several times wider than the view.
///
/// The camera shows a [viewWidth]-wide window of that world, derived from the
/// device aspect so the full 422 of height always fits with no letterboxing.
/// ---------------------------------------------------------------------------

class BattleConst {
  BattleConst._();

  static const double worldW = 3210;
  static const double worldH = 422;
  static const double waterY = 300;

  /// Design-space gravity and velocity scale, per 60Hz frame.
  ///
  /// [velScale] is set so the nearest enemy slot is comfortably in reach at
  /// roughly two-thirds power on a 45° lob, leaving real headroom above it —
  /// a shot that can only just reach can never miss long, and blind artillery
  /// needs both kinds of miss.
  static const double gravity = 0.35;
  static const double velScale = 0.32;

  /// Pull-back aiming.
  static const double pullMax = 300;
  static const double deadzone = 16;

  /// Per-axis smoothing for [easeAim]. Angle uses a higher factor than power:
  /// the angle is what the player reads off the readout as "the direction the
  /// ball will go", and a slow lerp makes a clear drag feel unresponsive.
  /// Power is lower because twitchy power readings make the meter feel noisy.
  static const double smoothAngle = 0.55;
  static const double smoothPower = 0.34;
  static const double smooth = 0.45; // back-compat for any outside callers

  /// Where the "fine tune" part of the pull begins (fraction of full pull).
  static const double fineZone = 0.66;

  static const double angleMin = 6;
  static const double angleMax = 85;
  static const double powerMin = 10;
  static const double powerMax = 100;

  static const double playerX = 210;
  static const List<double> enemySlots = [1500, 1900, 2300, 2700];

  /// A shot within this many units of a crew member's body counts as a
  /// direct hit.
  static const double hitRadius = 34;

  /// Height of a standing crew member, feet to top of head, in world units.
  /// Matches the proportions the renderer actually draws — see the layout
  /// block in its `_crewMember` — so the hit capsule wraps the character
  /// rather than an invisible circle around their middle.
  static const double bodyHeight = 72;

  // ---------------------------------------------------------------------------
  // Camera lock (blind fire)
  // ---------------------------------------------------------------------------

  /// How far ahead of the shooter's own raft the locked camera centres, so
  /// there is open water in front of them instead of them hugging the edge.
  static const double camLead = 190;

  /// Extra clearance kept between the camera's frame and the near edge of a
  /// living enemy raft. Bigger than the widest raft's half-width (130), so
  /// even a barge with its stern castle cannot poke into view.
  static const double camEnemyMargin = 140;

  /// The trajectory preview never draws past this fraction of the shot's
  /// flight. Friv's Raft shows a stub of the arc, not the landing spot, and
  /// now that the rafts are far apart an uncapped preview would hand the
  /// player the exact range they are supposed to be guessing at.
  static const double trajectoryReveal = 0.34;

  /// How far the camera may pan past either end of the world.
  ///
  /// The shooter's raft sits near the left edge, so on a very wide viewport
  /// — an ultrawide monitor shows a third of the ocean at once — the only
  /// way to keep the far raft out of frame is to pull back past the world's
  /// end. There is nothing there but sky and water, which is drawn to fill
  /// whatever the window shows, so this is free.
  static const double camOverhang = 420;

  // ---------------------------------------------------------------------------
  // Crew body physics (ragdoll knockback)
  // ---------------------------------------------------------------------------

  /// Downward acceleration on a tumbling crew member, per 60Hz frame.
  static const double bodyGravity = 0.42;

  /// Bounciness on landing, and the fraction of horizontal speed kept per
  /// frame while sliding along the deck.
  static const double bodyBounce = 0.32;
  static const double bodyFriction = 0.72;
  static const double bodyDrag = 0.995;

  /// How much of a hit's shove becomes lift rather than slide. Low on
  /// purpose: a body that spends a long time airborne travels a long way
  /// sideways — and, worse, reads as launched into the sky — so the lift is
  /// a fraction of the shove and the rest carries along the deck.
  static const double bodyLift = 0.16;

  /// Below this speed and spin a grounded body is considered to have stopped
  /// tumbling, and starts [bodySettleTime] of "getting up" before it stands.
  /// The thresholds sit above the solver's resting jitter — a body propped
  /// on bent legs breathes at roughly 1.3 speed / 0.07 spin from gravity
  /// fighting the constraints — but far below anything that looks like real
  /// motion. A body that is still *drifting* is caught by the positional
  /// check in the settle logic regardless.
  static const double bodySleepSpeed = 1.7;
  static const double bodySleepSpin = 0.09;
  static const double bodySettleTime = 0.4;

  /// During the settle window a grounded body's hips may not wander more
  /// than this (per frame-since-window-start) — a body sliding down a ramp
  /// keeps resetting the window instead of standing up mid-slide.
  static const double bodySettleDrift = 0.8;

  /// How long the stand-back-up blend takes once a settled ragdoll rises,
  /// and how fast a recovered crew member shuffles back to their station.
  static const double bodyGetUpTime = 0.5;
  static const double bodyRecover = 0.12;

  /// Walk-cycle phase advance per 60Hz step while a crew member is shuffling
  /// back to their station — the renderer turns this into leg swings.
  static const double walkCycleSpeed = 0.30;

  /// How far below the waterline a body's hips must sink before they drown.
  static const double drownDepth = 14;

  /// Friction along the deck for a dead body — much slicker than for a
  /// living one, because a corpse is limp. This is what lets a killing blow
  /// carry a body all the way to the rail instead of dumping it mid-deck.
  static const double bodyDeadFriction = 0.96;

  /// A dead body on the deck that has all but stopped is kept sliding toward
  /// the rail at this speed, so every death ends in the water.
  static const double bodyDeadDrift = 0.9;

  /// Hard cap on any ragdoll point's speed, per 60Hz frame. Constraint
  /// solving can inject energy when points pile up (and repeat hits stack
  /// impulses), which could launch a body into the sky; the cap keeps every
  /// flight inside the world's scale while gravity brings it back down.
  static const double bodyMaxSpeed = 9.0;

  /// Separate, much tighter cap on *upward* velocity. Sideways travel reads
  /// as a knock-back; vertical travel reads as launched into the sky. With
  /// the cap at 4/frame a body's apex stays within ~20 units of the deck —
  /// a hop, not a launch.
  static const double bodyMaxRise = 4.0;

  /// A ragdoll may not stay active longer than this. Real tumbles settle or
  /// drown within a few seconds; if one is still going (constraint pile-up,
  /// an edge case, anything), the watchdog force-resolves it — on their feet
  /// if over the deck, into the water if not — so a body can never hang in
  /// the air indefinitely.
  static const double ragdollWatchdog = 8.0;

  /// Floor impacts slower than this land dead — no bounce. Without it a
  /// resting body never sleeps: gravity re-energizes the points into the
  /// deck every frame and the bounce returns a slice of that energy,
  /// producing a permanent micro-bounce that random-walks the body around
  /// the deck.
  static const double bodyRestSpeed = 1.0;

  /// Rail lips: living bodies that reach the deck's edge below lip height
  /// are bounced back aboard instead of washing overboard. The lip extends
  /// this far past the walkable deck, and only covers bodies up to this far
  /// above deck level — anything flying higher clears the rail entirely.
  static const double railWall = 8.0;
  static const double railWallHeight = 14.0;

  // ---------------------------------------------------------------------------
  // Ragdoll solver (verlet points + distance constraints)
  // ---------------------------------------------------------------------------

  /// Constraint relaxation iterations per physics step. More iterations make
  /// the body stiffer; five keeps a crew member recognisably human at a cost
  /// the fixed-step loop can afford.
  static const int ragdollIters = 5;

  /// Fraction of an impact's shove applied as whole-body linear velocity —
  /// the rest of the energy goes into spin when the blow lands off-centre.
  static const double ragdollLinear = 0.9;

  /// Multiplier on the torque an off-centre impact generates. The raw
  /// angular velocity from the point impulse is physically correct but
  /// reads as sluggish at this art scale, so it is boosted and then capped.
  static const double ragdollTorque = 4.0;
  static const double ragdollMaxSpin = 0.22;

  // ---------------------------------------------------------------------------
  // Death sequence
  // ---------------------------------------------------------------------------

  /// White impact-flash duration on a killing blow.
  static const double deathFlashTime = 0.16;

  /// Total time a drowned body takes to slip under, and the fraction of
  /// that spent bobbing at the surface before the descent begins.
  static const double sinkTime = 2.6;
  static const double sinkFloatFrac = 0.3;

  // ---------------------------------------------------------------------------
  // Dynamic health bars
  // ---------------------------------------------------------------------------

  /// How long a crew member's HP bar stays up after taking damage, how long
  /// of that is the fade-out, how long the ghost bar waits before it starts
  /// draining, and how fast the ghost drains (fractions per second).
  static const double hpBarTime = 2.6;
  static const double hpBarFade = 0.4;
  static const double hpBarGhostDelay = 0.3;
  static const double hpGhostDrain = 0.9;
}

/// One point of the verlet ragdoll. Position is integrated; velocity is
/// implicit (pos − prev), which makes bounce and friction a matter of
/// nudging [prev] at collision time.
class RagdollPoint {
  Offset pos;
  Offset prev;

  /// 1 / mass. Zero would pin the point — no crew point is ever pinned.
  final double invMass;

  RagdollPoint(Offset at, {double mass = 1})
      : pos = at,
        prev = at,
        invMass = mass <= 0 ? 0 : 1 / mass;

  Offset get vel => pos - prev;

  void setVel(Offset v) => prev = pos - v;
}

/// One end of a distance constraint. `min`/`max` null means a rigid stick of
/// [len]; otherwise the constraint only fires outside the given range (ropes
/// and struts — arms fold, legs don't pass through each other).
class _RagConstraint {
  final RagdollPoint a;
  final RagdollPoint b;
  final double len;
  final double? min;
  final double? max;
  const _RagConstraint(this.a, this.b, this.len, {this.min, this.max});
}

/// A dynamic physics ragdoll for one crew member, built from seven verlet
/// points (head, neck, hip, two hands, two feet) held together by distance
/// constraints. Points live in *station-local* coordinates: x relative to
/// the crew member's slot on the deck, y relative to the deck surface — the
/// same frame the renderer's standing pose uses, so a body at rest maps 1:1
/// onto the drawn character and an impact genuinely displaces them through
/// the world.
class RagdollPose {
  final RagdollPoint head;
  final RagdollPoint neck;
  final RagdollPoint hip;
  final RagdollPoint handL;
  final RagdollPoint handR;
  final RagdollPoint footL;
  final RagdollPoint footR;

  final List<RagdollPoint> points;
  final List<_RagConstraint> _constraints = [];

  RagdollPose._(
    this.head,
    this.neck,
    this.hip,
    this.handL,
    this.handR,
    this.footL,
    this.footR,
  ) : points = [head, neck, hip, handL, handR, footL, footR];

  /// A standing body whose feet-origin anchor sits at [origin] — the layout
  /// mirrors the renderer's proportions (leg 15, torso 27, head at −58) so
  /// spawning a pose from a standing crew member never pops.
  factory RagdollPose.standingAt(Offset origin) {
    Offset at(double dx, double dy) => origin + Offset(dx, dy);
    final pose = RagdollPose._(
      RagdollPoint(at(0, -58), mass: 0.9),
      RagdollPoint(at(0, -42), mass: 1.2),
      RagdollPoint(at(0, -15), mass: 2.2),
      RagdollPoint(at(-10, -25), mass: 0.7),
      RagdollPoint(at(10, -25), mass: 0.7),
      RagdollPoint(at(-8, 0), mass: 1.1),
      RagdollPoint(at(8, 0), mass: 1.1),
    );
    final c = pose._constraints;
    // Spine and legs: rigid.
    c.add(_RagConstraint(pose.head, pose.neck, 16));
    c.add(_RagConstraint(pose.neck, pose.hip, 27));
    c.add(_RagConstraint(pose.hip, pose.footL, 15));
    c.add(_RagConstraint(pose.hip, pose.footR, 15));
    // Arms: ropes — elbows fold, so the hands may come close but never
    // stretch past full reach.
    c.add(_RagConstraint(pose.neck, pose.handL, 26, min: 6, max: 26));
    c.add(_RagConstraint(pose.neck, pose.handR, 26, min: 6, max: 26));
    // Feet stay a stride apart but never cross.
    c.add(_RagConstraint(pose.footL, pose.footR, 16, min: 4, max: 18));
    // Anti-fold struts: the body may crumple but never fold flat in half.
    c.add(_RagConstraint(pose.head, pose.hip, 34, min: 34));
    c.add(_RagConstraint(pose.head, pose.footL, 24, min: 24));
    c.add(_RagConstraint(pose.head, pose.footR, 24, min: 24));
    c.add(_RagConstraint(pose.neck, pose.footL, 18, min: 18));
    c.add(_RagConstraint(pose.neck, pose.footR, 18, min: 18));
    return pose;
  }

  /// Advances the sim one 60Hz step: implicit-velocity integration under
  /// gravity with per-frame drag.
  void integrate({required double gravity, required double drag}) {
    for (final p in points) {
      final v = (p.pos - p.prev) * drag;
      p.prev = p.pos;
      p.pos += v + Offset(0, gravity);
    }
  }

  /// Relaxation pass over every constraint. Called [BattleConst.ragdollIters]
  /// times per step, after integration and after any collision response.
  void solve() {
    for (int it = 0; it < BattleConst.ragdollIters; it++) {
      for (final con in _constraints) {
        final delta = con.b.pos - con.a.pos;
        final d = delta.distance;
        if (d <= 1e-6) continue;
        double diff = 0;
        if (con.min == null && con.max == null) {
          diff = (d - con.len) / d;
        } else if (con.max != null && d > con.max!) {
          diff = (d - con.max!) / d;
        } else if (con.min != null && d < con.min!) {
          diff = (d - con.min!) / d;
        }
        if (diff == 0) continue;
        final wSum = con.a.invMass + con.b.invMass;
        if (wSum <= 0) continue;
        final corr = delta * diff;
        con.a.pos += corr * (con.a.invMass / wSum);
        con.b.pos -= corr * (con.b.invMass / wSum);
      }
    }
  }

  /// Applies a blow delivered at [hitLocal] (station-local) with per-frame
  /// velocity [impulse]: every point takes the linear shove, and an
  /// off-centre hit adds torque around the centre of mass — a shot to the
  /// head snaps the body head-over-heels while one to the legs sweeps the
  /// feet out from under them.
  void applyImpulse(Offset hitLocal, Offset impulse) {
    final com = hip.pos;

    // Moment of inertia about the centre of mass.
    var inertia = 0.0;
    for (final p in points) {
      final r = p.pos - com;
      final m = p.invMass > 0 ? 1 / p.invMass : 0.0;
      inertia += m * (r.dx * r.dx + r.dy * r.dy);
    }

    final rHit = hitLocal - com;
    final cross = rHit.dx * impulse.dy - rHit.dy * impulse.dx;
    var w = inertia > 1e-6 ? cross / inertia * BattleConst.ragdollTorque : 0.0;
    w = w.clamp(-BattleConst.ragdollMaxSpin, BattleConst.ragdollMaxSpin);

    for (final p in points) {
      final r = p.pos - com;
      final lin = impulse * BattleConst.ragdollLinear;
      final tan = Offset(-r.dy, r.dx) * w;
      p.setVel(p.vel + lin + tan);
    }
  }

  /// Blends every point toward [target]'s layout by [t] (0..1), killing
  /// momentum as it goes — the stand-back-up animation. Physics is
  /// suspended while the blend runs.
  void blendTo(RagdollPose target, double t) {
    void blend(RagdollPoint p, RagdollPoint q) {
      p.pos = Offset(
        p.pos.dx + (q.pos.dx - p.pos.dx) * t,
        p.pos.dy + (q.pos.dy - p.pos.dy) * t,
      );
      p.prev = p.pos;
    }

    blend(head, target.head);
    blend(neck, target.neck);
    blend(hip, target.hip);
    blend(handL, target.handL);
    blend(handR, target.handR);
    blend(footL, target.footL);
    blend(footR, target.footR);
  }

  /// Fastest point, in per-frame units — the sleep test.
  double get maxSpeed {
    var m = 0.0;
    for (final p in points) {
      m = max(m, p.vel.distance);
    }
    return m;
  }

  /// Fastest angular velocity about the hip, in radians per frame.
  double get maxSpin {
    final com = hip.pos;
    var m = 0.0;
    for (final p in points) {
      final r = p.pos - com;
      final d2 = max(1.0, r.dx * r.dx + r.dy * r.dy);
      final cross = r.dx * p.vel.dy - r.dy * p.vel.dx;
      m = max(m, (cross / d2).abs());
    }
    return m;
  }

  /// Bounding box of the body in station-local coordinates.
  Rect get bounds {
    var left = head.pos.dx;
    var right = left;
    var top = head.pos.dy;
    var bottom = top;
    for (final p in points) {
      left = min(left, p.pos.dx);
      right = max(right, p.pos.dx);
      top = min(top, p.pos.dy);
      bottom = max(bottom, p.pos.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// The bounds plus head radius and limb thickness — what a fade or flash
  /// layer must cover to always wrap the drawn body.
  Rect get drawBounds => bounds
      .inflate(18)
      .intersect(const Rect.fromLTWH(-220, -260, 440, 560));
}

/// One character aboard a raft.
///
/// Besides HP, a crew member carries a small physics body: a [RagdollPose]
/// of verlet points that is spawned the moment they are knocked off their
/// feet and integrated by [BattleWorld.update]. The impact is applied *at
/// the point the shot actually struck*, so the body reacts to the blow's
/// location — head shots tumble, leg shots sweep — and the body's world
/// position is genuinely displaced by the hit. Once the ragdoll goes to
/// sleep the crew member blends back onto their feet and walks back to
/// their station. A body that slides off the deck falls into the sea and
/// drowns — being knocked overboard is what actually eliminates a crew
/// member in this game, not merely reaching 0 HP where they stand.
class Crew {
  double hp;
  final double maxHp;

  /// Phase offset so crew on the same raft don't bob in lockstep.
  final double bobPhase;

  /// 0 while alive; ramps to 1 as a defeated crew member sinks out of view.
  double sinkT = 0;

  /// Displacement of the body's feet-origin from its station, in world
  /// units. Follows the ragdoll's hips while tumbling, and is walked back to
  /// zero as the crew member returns to their slot. +dx is to the right,
  /// +dy is *down* (toward and then through the waterline).
  Offset offset = Offset.zero;

  /// Representative body velocity (the ragdoll's hips), in world units per
  /// 60Hz frame.
  Offset vel = Offset.zero;

  /// True while the body is being thrown around by an impact.
  bool ragdoll = false;

  /// Seconds the current ragdoll has been running. Drives the watchdog that
  /// force-resolves a body which neither settles nor drowns.
  double ragdollTime = 0;

  /// True when this crew member can take their turn shot: alive, on their
  /// feet, and not mid-recovery. A body tumbling across the deck (or in the
  /// air) cannot fire.
  bool get ready => alive && !ragdoll && pose == null && getUpT < 0;

  /// The live ragdoll, or null while standing.
  RagdollPose? pose;

  /// 0..1 progress of standing back up after a settled ragdoll; −1 while
  /// not getting up.
  double getUpT = -1;

  /// True once the body has come to rest after tumbling. Counts up to
  /// [BattleConst.bodySettleTime] before they stand back up.
  double rest = 0;

  /// Where the hips were when the current settle window began — the drift
  /// check that keeps a sliding body from "standing up" mid-slide.
  Offset restHip = Offset.zero;

  /// Went into the water. This is fatal and permanent for the round.
  bool drowned = false;

  /// Horizontal direction a dying body falls and drifts in (±1); 0 while
  /// alive. The body stepper uses it to keep a corpse sliding toward the
  /// rail until it goes over the side.
  double deathDir = 0;

  /// White impact-flash countdown fired by a killing blow.
  double deathFlash = 0;

  // --- Dynamic health bar ---------------------------------------------------

  /// Seconds left to show this crew member's HP bar; 0 = hidden.
  double hpBarT = 0;

  /// The "ghost" HP fraction the bar drains from after a hit. Reset to the
  /// live fraction whenever the bar fully hides, so it always reflects the
  /// most current HP when it reappears.
  double hpDisplay = 1;

  // --- Walk-back animation --------------------------------------------------

  /// Walk-cycle phase while shuffling back to the station.
  double walkPhase = 0;

  /// 0..1 weight of the walk animation; eases in while walking and out
  /// once the station is reached.
  double walkAmp = 0;

  Crew({required this.hp, required this.maxHp, this.bobPhase = 0});

  bool get alive => hp > 0;

  /// True once the sink animation has finished and they should stop drawing.
  bool get gone => !alive && sinkT >= 1;

  double get hpFrac => (hp / maxHp).clamp(0.0, 1.0);

  /// Flags the dynamic HP bar to appear. [fracBefore] is the HP fraction the
  /// character had *before* the damage was applied — the ghost bar starts
  /// there and drains to the live value so the loss is animated, not
  /// instant. Repeated hits while the bar is up extend it and keep the
  /// ghost draining from the highest point it reached.
  void showHpBar(double fracBefore) {
    final f = fracBefore.clamp(0.0, 1.0);
    hpDisplay = hpBarT <= 0 ? f : max(hpDisplay, f);
    hpBarT = BattleConst.hpBarTime;
  }

  /// Knocked off their feet by an impact.
  ///
  /// [dir] is the projectile's travel direction, [force] its shove in world
  /// units per frame, and [hitLocal] the station-local point the blow
  /// actually landed at — where the hit lands decides how the body moves.
  /// Omitting it treats the blow as landing dead-centre: a clean shove with
  /// no spin.
  void knock(Offset dir, double force, {Offset? hitLocal}) {
    final d = dir.distance <= 0 ? const Offset(1, 0) : dir / dir.distance;
    ragdoll = true;
    ragdollTime = 0;
    rest = 0;
    getUpT = -1;
    pose ??= RagdollPose.standingAt(Offset(offset.dx, offset.dy));
    final impulse = Offset(d.dx * force, d.dy * force - force * BattleConst.bodyLift);
    pose!.applyImpulse(hitLocal ?? pose!.hip.pos, impulse);
    vel = pose!.hip.vel;
  }

  /// A killing blow. Unlike a hit someone survives, a dead body never stands
  /// back up: it tumbles the way the impact pointed, goes limp, and — nudged
  /// along by the death drift in [_stepBody] — slides off the deck and into
  /// the sea. [railDir] is the way off the nearest rail, used when the
  /// impact itself has little horizontal say in where they fall.
  void startDeath(Offset hitDir, double force, {double railDir = 1, Offset? hitLocal}) {
    final d = hitDir.distance <= 0 ? const Offset(1, 0) : hitDir / hitDir.distance;
    deathDir = d.dx.abs() >= 0.4
        ? (d.dx < 0 ? -1.0 : 1.0)
        : (railDir < 0 ? -1.0 : 1.0);
    deathFlash = BattleConst.deathFlashTime;
    ragdoll = true;
    ragdollTime = 0;
    rest = 0;
    getUpT = -1;
    pose ??= RagdollPose.standingAt(Offset(offset.dx, offset.dy));
    final f = max(force, 3.0);
    pose!.applyImpulse(
      hitLocal ?? pose!.hip.pos,
      Offset(d.dx * f, d.dy * f - 2.2),
    );
    vel = pose!.hip.vel;
  }

  /// Force of a hit from [weapon], scaled by how heavy it is.
  ///
  /// Tuned against how far a body actually travels (see [BattleConst] for the
  /// per-frame numbers): the starter tennis ball rocks someone back on the
  /// deck, a bomb or an anchor slides them far enough that a crew member
  /// standing near the rail can go over the side. Being knocked overboard is
  /// meant to be a real but occasional way to lose someone — not what every
  /// hit does, which is what an early, much punchier version of this did.
  static double impactForce(WeaponDef weapon) =>
      (1.2 + weapon.damage * 0.028) * (0.8 + 0.2 * weapon.weight);
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

  /// The deck's platform layout, oriented so the raised stern work sits
  /// behind this raft's crew (see [DeckProfile.forLoadout]).
  late final DeckProfile profile =
      DeckProfile.forLoadout(loadout, facing: facing);

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

  /// Deck surface height — the line the crew's feet rest on. Matches the
  /// renderer's own deck calculation so a body standing at offset zero is
  /// drawn exactly on the planks.
  double get deckY => BattleConst.waterY - loadout.width * loadout.hull.thickness * 0.55;

  /// Half the walkable deck. Past this a crew member is over open water.
  double get deckHalf => loadout.deckHalf;

  /// The walkable surface at hull-local [x], as a y-offset from [deckY]
  /// (0 on the main deck, negative up on a raised platform), or null past
  /// the rails. This is the height-field the body physics and the walk-back
  /// both follow — platforms, ramps and deck are one continuous surface.
  double? surfaceY(double x) {
    if (x.abs() > deckHalf) return null;
    return -profile.riseAt(x);
  }

  /// World position of crew member [i]'s feet, following their body.
  Offset feetPos(int i) => Offset(x + loadout.crewOffset(i) + crew[i].offset.dx, deckY + crew[i].offset.dy);

  /// World position of crew member [i]'s body centre — the point a shot has
  /// to land near. Sits a torso-and-a-bit above the feet.
  Offset crewPos(int i) => feetPos(i) - const Offset(0, 24);

  /// The two endpoints of crew member [i]'s hit capsule in world space,
  /// following their live pose. A tumbling body is hit where it actually
  /// is, not where it would be standing.
  (Offset, Offset) crewCapsule(int i) {
    final pose = crew[i].pose;
    if (pose == null) {
      final feet = feetPos(i);
      return (feet, feet - const Offset(0, BattleConst.bodyHeight));
    }
    final b = pose.bounds;
    final cx = x + loadout.crewOffset(i) + b.center.dx;
    return (Offset(cx, deckY + b.bottom), Offset(cx, deckY + b.top));
  }

  /// Which way leads off the nearest rail from crew member [i]'s current
  /// position: +1 toward the bow-side rail, -1 toward the stern-side one.
  double railDir(int i) =>
      (loadout.crewOffset(i) + crew[i].offset.dx) >= 0 ? 1.0 : -1.0;

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

  /// Makes sure [activeIndex] points at a crew member who can actually take
  /// the shot: alive **and** on their feet. A shooter mid-ragdoll cannot
  /// fire — the body is wherever the physics left it, not at the station.
  /// Prefers a ready member; falls back to any living one (the turn then
  /// waits for them to recover). Returns false only when nobody aboard can
  /// act at all.
  bool ensureActiveReady() {
    if (activeCrew != null && activeCrew!.ready) return true;
    for (int k = 1; k <= crew.length; k++) {
      final idx = (activeIndex + k) % crew.length;
      if (crew[idx].ready) {
        activeIndex = idx;
        return true;
      }
    }
    ensureActiveAlive();
    return activeCrew != null && activeCrew!.ready;
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

  /// [BattleWorld.elapsed] at the moment this shot left the barrel. Lets the
  /// renderer time the shooter's recoil kick and muzzle flash without the
  /// simulation itself needing to know anything about how it's drawn.
  final double firedAt;

  Shot({
    required this.pos,
    required this.vel,
    required this.weapon,
    required this.owner,
    required this.firedAt,
  });
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

  /// Whose raft the camera is locked to. Shots are lobbed blind, so the view
  /// belongs to whoever is firing — never to their target.
  int camAnchor = 0;

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
  ///
  /// The usual bounds are the world's own edges, widened by
  /// [BattleConst.camOverhang] so the blind-fire lock always has somewhere
  /// left to go — see the constant for why that matters.
  double camFor(double centerX) =>
      clampCam((centerX - viewWidth / 2));

  /// Clamps a raw left-edge offset into the legal camera range: the world's
  /// own edges, widened by [BattleConst.camOverhang].
  double clampCam(double camX) {
    final maxCam = BattleConst.worldW - viewWidth + BattleConst.camOverhang;
    final minCam = -BattleConst.camOverhang;
    return camX.clamp(min(minCam, maxCam), maxCam);
  }

  void snapCam(double centerX) => cam = camFor(centerX);

  void easeCam(double centerX, double dt) {
    final target = camFor(centerX);
    cam += (target - cam) * (dt * 3.2).clamp(0.0, 1.0);
  }

  /// True when [worldX] sits off the right edge of the current view.
  bool isOffscreenRight(double worldX) => worldX - cam > viewWidth - 70;

  /// Right edge of the visible window, in world units.
  double get camRight => cam + viewWidth;

  // ---------------------------------------------------------------------------
  // Camera lock — blind fire
  //
  // The view belongs to the shooter and never leaves them. Aiming must not
  // pan the camera (the old code eased toward where the shot would land,
  // which walked the whole way across to the enemy raft and turned every
  // shot into a point-and-click), and a projectile is only followed for as
  // far as it stays on the shooter's own water.
  // ---------------------------------------------------------------------------

  /// How far inside the frame edge the anchor's own raft is kept, so the
  /// shooter can always see themselves even while the camera leans after an
  /// incoming shot.
  static const double camAnchorMargin = 130;

  /// The centre-x the locked camera wants: the anchor's own raft, pushed
  /// [BattleConst.camLead] out in the direction they fire.
  double lockedCenter([int? index]) {
    final me = raftOf(index ?? camAnchor);
    if (me == null) return cam + viewWidth / 2;
    return me.x + me.facing * BattleConst.camLead;
  }

  /// Clamps a desired centre-x into the window the anchor is allowed.
  ///
  /// The clamp is expressed as a *lead* over the anchor's raft rather than an
  /// absolute position, which is what makes both ends behave: at one end the
  /// anchor's own raft is held inside the frame, at the other every living
  /// enemy is held outside it. Clamping the absolute position instead would
  /// let an incoming shot drag the view so far across that the player lost
  /// sight of their own deck.
  double clampToLock(double centerX, [int? index]) {
    final i = index ?? camAnchor;
    final me = raftOf(i);
    if (me == null) return centerX;

    final half = viewWidth * 0.5;
    var leadMax = half - camAnchorMargin;
    var leadMin = -half + camAnchorMargin;

    for (final r in rafts) {
      if (r.playerIndex == i || !r.alive) continue;
      final ahead = (r.x - me.x) * me.facing; // distance in the firing direction
      if (ahead <= 0) continue;
      // Stop short of the enemy's near edge, plus clearance, minus half a
      // screen — the lead at which their bow would just touch the frame.
      leadMax = min(leadMax, ahead - r.loadout.width * 0.5 - BattleConst.camEnemyMargin - half);
    }
    if (leadMax < leadMin) leadMax = leadMin;

    final signed = (centerX - me.x) * me.facing;
    return me.x + me.facing * signed.clamp(leadMin, leadMax);
  }

  /// Points the camera at a new anchor and cuts straight to it. Used on a
  /// turn change, where easing across a thousand-odd world units of empty
  /// ocean would just look like the screen sliding sideways forever.
  void lockCam(int playerIndex) {
    camAnchor = playerIndex;
    cam = camFor(clampToLock(lockedCenter(playerIndex), playerIndex));
  }

  /// Holds the camera on the current anchor — the whole of the aiming phase
  /// runs through this, so no amount of dragging can move the view.
  void holdCam(double dt) => easeCam(clampToLock(lockedCenter()), dt);

  /// Follows [worldX] (a projectile, usually) but never far enough to show
  /// the enemy, and never so far that the anchor leaves the frame. The shot
  /// arcing out of frame is the point: after that, whether it found anything
  /// is a surprise for both sides.
  void followCam(double worldX, double dt) =>
      easeCam(clampToLock(worldX), dt);

  /// Hard cut to centre on [worldX] — the camera jump from the shooter to
  /// the projectile a beat after firing. A cut, not an ease: by the time the
  /// view switches the shot is already a long way out, and panning across
  /// that distance reads as lag where a cut reads as coverage. [trackShot]
  /// takes over from here and eases alongside the ball.
  void cutCam(double worldX) => cam = camFor(worldX);

  /// How fast the camera closes on a tracked projectile, per second.
  ///
  /// This is a *lag* constant, not a speed limit: see [trackShot].
  static const double shotTrackRate = 3.5;

  /// Clearance a tracked shot keeps from the frame edge, as a fraction of the
  /// visible width. Must stay under 0.5 or the allowed camera range is empty.
  static const double shotEdgeMargin = 0.25;

  /// Tracks a projectile in flight, ignoring the blind-fire clamp.
  ///
  /// The aiming-phase lock is right for *aiming* (you would otherwise see
  /// exactly where the shot was going to land) but wrong for *flight*: while
  /// the shot is in the air both players should be able to watch where it
  /// goes. This eases the camera so the projectile sits in frame, clamped
  /// only to the world bounds — not to the shooter's raft.
  ///
  /// [vx] is the projectile's horizontal velocity in world units per second.
  /// It drives a feed-forward term: the camera aims at where the shot *will
  /// be* one time-constant from now rather than where it is. Without it, an
  /// exponential ease trails a fast shot by roughly `vx / shotTrackRate`,
  /// which is ~400 units at full power — enough to fly clean off the side of
  /// an 870-wide viewport, and far worse on a narrow one. With it the
  /// steady-state error is exactly zero, so the shot stays centred at any
  /// speed and on any aspect ratio, and the follow rate can stay low (which
  /// is what keeps the pan smooth).
  ///
  /// The world is only 422 units tall, so the projectile's Y stays inside
  /// the visible band regardless of aspect ratio; only X needs tracking.
  void trackShot(double worldX, double vx, double dt) {
    // Lead by one time constant: 1 / shotTrackRate seconds of travel.
    final lead = vx / shotTrackRate;
    final target = camFor(worldX + lead);
    cam += (target - cam) * (dt * shotTrackRate).clamp(0.0, 1.0);

    // Safety net. Feed-forward zeroes the *steady-state* error, but on a very
    // narrow viewport the launch transient can still outrun the ease before
    // it converges, and this is the one thing the tracking absolutely must
    // not get wrong. Clamp the camera so the shot can never come closer than
    // shotEdgeMargin to either edge. In steady state the camera sits dead
    // centre and this never fires — it only engages as a catch-up.
    final margin = viewWidth * shotEdgeMargin;
    final lo = worldX + margin - viewWidth;
    final hi = worldX - margin;
    // The world bounds get the last word: we never pan off the map to keep a
    // shot in frame. Near the edges the shot is in frame anyway, because the
    // overhang gives the camera room to pull back.
    cam = clampCam(cam.clamp(min(lo, hi), max(lo, hi)));
  }

  /// Eases the camera back toward [playerIndex]'s raft so the next turn
  /// starts on the new shooter's deck. Used after a shot has resolved.
  void returnCamTo(int playerIndex, double dt) {
    final me = raftOf(playerIndex);
    if (me == null) return;
    final target = camFor(me.x);
    cam += (target - cam) * (dt * 2.4).clamp(0.0, 1.0);
  }

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

  /// Dotted arc preview.
  ///
  /// Capped hard at [BattleConst.trajectoryReveal] of the flight: now that
  /// the rafts sit a thousand-odd units apart, an uncapped arc would climb
  /// over the horizon and come down on the enemy raft, telling the player
  /// the exact range they are supposed to be judging by eye. What they get
  /// is the first third — enough to read the shape of the lob, like the
  /// Friv original, and no more.
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
    // Flight length to the waterline, so "a third of the arc" means a third
    // of *this* shot rather than a fixed number of frames.
    var flight = 0;
    var probe = from;
    var pv = v;
    for (; flight < 400; flight++) {
      probe += pv;
      pv = Offset(pv.dx, pv.dy + BattleConst.gravity);
      if (probe.dy > BattleConst.waterY + 8) break;
    }
    final budget = max(6.0, flight * BattleConst.trajectoryReveal).round();

    for (int i = 0; i < flight; i++) {
      p += v;
      v = Offset(v.dx, v.dy + BattleConst.gravity);
      if (p.dy > BattleConst.waterY + 8) break;
      if (p.dx < -80 || p.dx > BattleConst.worldW + 80) break;
      if (i % 4 == 0) out.add(TrajectoryDot(p, i));
      if (out.length >= limit || i >= budget) break;
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
      firedAt: elapsed,
    );
  }

  /// Advances the in-flight shot by one frame. Returns a [ShotOutcome] on the
  /// frame it resolves (hit, splash-down or out of bounds), otherwise null.
  ShotOutcome? stepShot() {
    final s = shot;
    if (s == null) return null;

    final prev = s.pos;
    s.trail.add(s.pos);
    if (s.trail.length > 18) s.trail.removeAt(0);

    s.pos += s.vel;
    s.vel = Offset(s.vel.dx, s.vel.dy + BattleConst.gravity);

    // Direct hit on any crew member not belonging to the shooter. The shot
    // is tested as the segment it swept this frame against a body-shaped
    // capsule, so a fast projectile cannot step over a head, torso or pair
    // of legs in a single frame and phase through a character it visibly
    // clipped — the old point-in-circle test did exactly that. The closest
    // point on the capsule is kept so the ragdoll knows exactly where the
    // blow landed.
    for (final raft in rafts) {
      if (raft.playerIndex == s.owner || !raft.alive) continue;
      for (int i = 0; i < raft.crew.length; i++) {
        final c = raft.crew[i];
        if (!c.alive) continue;
        final sweep = _sweepCrew(prev, s.pos, raft, i);
        if (sweep.hit) {
          return _resolve(s, raft, i, hitPoint: sweep.point);
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

  /// Whether the shot's sweep from [from] to [to] comes close enough to crew
  /// member [i] of [raft] to count as a direct hit — and if so, the exact
  /// point on the body it struck.
  ///
  /// A crew member is a vertical capsule — the line from their feet to the
  /// top of their head, inflated by [BattleConst.hitRadius] — not the old
  /// circle floating at torso height, which never covered the head or the
  /// legs at all. The capsule endpoints follow the live ragdoll pose, so a
  /// body mid-tumble is hit where it actually lies.
  ({bool hit, Offset point}) _sweepCrew(Offset from, Offset to, Raft raft, int i) {
    final (a, b) = raft.crewCapsule(i);
    final (dist, point) = _segSegClosest(from, to, a, b);
    return (hit: dist < BattleConst.hitRadius, point: point);
  }

  /// Distance between the segments [p1]–[q1] and [p2]–[q2], plus the closest
  /// point on the second segment.
  (double, Offset) _segSegClosest(Offset p1, Offset q1, Offset p2, Offset q2) {
    final d1 = q1 - p1;
    final d2 = q2 - p2;
    final r = p1 - p2;
    final a = d1.dx * d1.dx + d1.dy * d1.dy;
    final e = d2.dx * d2.dx + d2.dy * d2.dy;
    final f = d2.dx * r.dx + d2.dy * r.dy;

    double s;
    double t;
    if (a <= 1e-9 && e <= 1e-9) {
      return (r.distance, p2);
    }
    if (a <= 1e-9) {
      s = 0;
      t = (f / e).clamp(0.0, 1.0);
    } else {
      final c2 = d1.dx * r.dx + d1.dy * r.dy;
      if (e <= 1e-9) {
        t = 0;
        s = (-c2 / a).clamp(0.0, 1.0);
      } else {
        final b = d1.dx * d2.dx + d1.dy * d2.dy;
        final denom = a * e - b * b;
        s = denom > 1e-9 ? ((b * f - c2 * e) / denom).clamp(0.0, 1.0) : 0.0;
        t = (b * s + f) / e;
        if (t < 0) {
          t = 0;
          s = (-c2 / a).clamp(0.0, 1.0);
        } else if (t > 1) {
          t = 1;
          s = ((b - c2) / a).clamp(0.0, 1.0);
        }
      }
    }
    final closest = p2 + d2 * t;
    return ((p1 + d1 * s - closest).distance, closest);
  }

  ShotOutcome? _resolve(Shot s, Raft? hitRaft, int crewIndex, {Offset? hitPoint}) {
    final impact = hitPoint ?? Offset(s.pos.dx, min(s.pos.dy, BattleConst.waterY + 12));
    double dealt = 0;
    bool hitPlayerSide = false;

    if (hitRaft != null && crewIndex >= 0) {
      final c = hitRaft.crew[crewIndex];
      final before = c.hp;
      c.hp = max(0, c.hp - s.weapon.damage);
      dealt += before - c.hp;
      hitPlayerSide = hitRaft.playerIndex == 0;
      // The dynamic HP bar comes up the moment damage lands, animating the
      // loss from where the HP was.
      c.showHpBar(before / c.maxHp);
      // The shove is what sells the hit — they kick back the way the shot
      // was travelling and tumble, reacting to the exact spot the blow
      // landed. A crew member the shot kills goes limp instead: they never
      // stand back up, and the body drifts off the deck into the water.
      final hitLocal = impact - Offset(
        hitRaft.x + hitRaft.loadout.crewOffset(crewIndex),
        hitRaft.deckY,
      );
      if (c.alive) {
        c.knock(s.vel, Crew.impactForce(s.weapon), hitLocal: hitLocal);
      } else {
        c.startDeath(s.vel, Crew.impactForce(s.weapon),
            railDir: hitRaft.railDir(crewIndex), hitLocal: hitLocal);
      }
    }

    // Splash damage: everyone (on any raft but the shooter's) inside radius,
    // falling off with distance. The directly-hit crew member is skipped so a
    // direct hit isn't double-counted. Everyone caught in the blast is shoved
    // away from the burst, which is how a near miss empties a crowded deck.
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
          c.showHpBar(before / c.maxHp);
          final away = raft.crewPos(i) - impact;
          final station = Offset(raft.x + raft.loadout.crewOffset(i), raft.deckY);
          if (c.alive) {
            c.knock(away, Crew.impactForce(s.weapon) * 0.55 * falloff,
                hitLocal: raft.crewPos(i) - station);
          } else {
            c.startDeath(
              away,
              max(2.5, Crew.impactForce(s.weapon) * 0.55 * falloff),
              railDir: raft.railDir(i),
              hitLocal: raft.crewPos(i) - station,
            );
          }
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

  /// Crew bodies are integrated on their own fixed 60Hz accumulator so a
  /// bounce happens at exactly the same point regardless of the display's
  /// refresh rate — and so both devices in a hotspot match, which never tick
  /// in lockstep, compute the identical result.
  double _bodyAccum = 0;

  void update(double dt) {
    elapsed += dt;
    for (final fx in effects) {
      fx.t += dt;
    }
    effects.removeWhere((f) => f.done);

    _bodyAccum += dt;
    const step = 1 / 60;
    var guard = 0;
    while (_bodyAccum >= step && guard < 4) {
      _bodyAccum -= step;
      guard++;
      _stepBodies();
    }
  }

  /// One 60Hz tick of every crew body on the water.
  void _stepBodies() {
    const dt = 1 / 60;
    for (final raft in rafts) {
      for (int i = 0; i < raft.crew.length; i++) {
        final c = raft.crew[i];

        // A body in the water slips under as the second half of the death
        // sequence: a surface bob first, then a slow sink and fade (the
        // renderer draws the bubbles and the wisp that lift away). A dead
        // one on the deck is a ragdoll instead — it tumbles off the raft
        // and into the sea (see [_stepBody]) and only starts sinking once
        // it is actually in the water.
        if (c.drowned) {
          c.sinkT = (c.sinkT + dt / BattleConst.sinkTime).clamp(0.0, 1.0);
        } else if (!c.alive && !c.ragdoll) {
          // Safety net: a crew member killed without an impact shove still
          // keels over and goes in like any other death.
          c.startDeath(const Offset(1, 0), 3.0, railDir: raft.railDir(i));
        }

        // Dynamic health bar lifecycle: hold up, ghost drains toward the
        // live HP, fade out — and reset the ghost so the next appearance
        // always starts from the most current value.
        if (c.hpBarT > 0) {
          c.hpBarT = max(0, c.hpBarT - dt);
          final shownFor = BattleConst.hpBarTime - c.hpBarT;
          if (shownFor > BattleConst.hpBarGhostDelay) {
            c.hpDisplay = max(c.hpFrac, c.hpDisplay - BattleConst.hpGhostDrain * dt);
          }
          if (c.hpBarT == 0) c.hpDisplay = c.hpFrac;
        }

        if (c.deathFlash > 0) {
          c.deathFlash = max(0, c.deathFlash - dt);
        }

        if (c.ragdoll) {
          _stepBody(raft, i, c);
        } else if (c.alive && c.offset != Offset.zero) {
          // Recovered: walk back to the station they were knocked off. The
          // renderer turns walkPhase/walkAmp into a proper leg swing, and
          // the feet follow the deck surface — down a platform ramp, across
          // the main deck — rather than gliding through it.
          c.walkAmp = min(1.0, c.walkAmp + dt * 5);
          c.walkPhase += BattleConst.walkCycleSpeed;
          final dx = c.offset.dx * (1 - BattleConst.bodyRecover);
          final surface = raft.surfaceY(raft.loadout.crewOffset(i) + dx) ?? 0.0;
          c.offset = Offset(dx, surface);
          if (c.offset.distance < 0.4) c.offset = Offset.zero;
        } else if (c.alive) {
          // Arrived (or never left): ease the walk out.
          if (c.walkAmp > 0) {
            c.walkAmp = max(0.0, c.walkAmp - dt * 5);
            c.walkPhase += BattleConst.walkCycleSpeed * c.walkAmp;
            if (c.walkAmp == 0) c.walkPhase = 0;
          }
        }
      }
    }
  }

  void _stepBody(Raft raft, int index, Crew c) {
    final pose = c.pose;
    if (pose == null) {
      c.ragdoll = false;
      c.ragdollTime = 0;
      return;
    }
    final stationX = raft.loadout.crewOffset(index);

    // Watchdog: a ragdoll that has been running far longer than any real
    // tumble — or whose hips have left the world's sane band entirely — is
    // force-resolved instead of being left hanging in the air: over the
    // deck they stand up where they are, over open water the sea takes
    // them. Nothing can stay airborne, ever.
    final hip = pose.hip.pos;
    final stalled = !c.ragdollTime.isFinite ||
        c.ragdollTime > BattleConst.ragdollWatchdog ||
        !hip.isFinite ||
        hip.dy.abs() > 400 ||
        hip.dx.abs() > 800;
    if (stalled) {
      if (raft.surfaceY(stationX + hip.dx) != null) {
        c.getUpT = 0;
        c.rest = 0;
        c.restHip = hip;
        c.ragdollTime = 0;
      } else {
        c.drowned = true;
        c.ragdoll = false;
        c.ragdollTime = 0;
        c.hp = 0;
        c.vel = Offset.zero;
        effects.add(Fx(
          pos: Offset(
            (raft.x + stationX + hip.dx).clamp(-60.0, BattleConst.worldW + 60.0),
            BattleConst.waterY,
          ),
          kind: 'splash',
          color: const Color(0xFFBFE9F2),
          size: 88,
          life: 0.7,
        ));
      }
      return;
    }

    // Standing back up: physics is suspended while the settled body blends
    // from wherever it ended up onto its feet at the same spot — on
    // whatever surface it settled on, platform or deck. When the blend
    // finishes the pose hands over to the normal standing renderer, which
    // walks them back down to their station along the deck surface.
    if (c.getUpT >= 0) {
      c.getUpT = min(1.0, c.getUpT + (1 / 60) / BattleConst.bodyGetUpTime);
      final feet = raft.surfaceY(stationX + pose.hip.pos.dx) ?? 0.0;
      pose.blendTo(RagdollPose.standingAt(Offset(pose.hip.pos.dx, feet)), c.getUpT);
      if (c.getUpT >= 1) {
        c.offset = Offset(pose.hip.pos.dx, feet);
        c.vel = Offset.zero;
        c.pose = null;
        c.getUpT = -1;
        c.ragdoll = false;
        c.ragdollTime = 0;
      }
      return;
    }

    c.ragdollTime += 1 / 60;

    final dead = !c.alive && !c.drowned;

    pose.integrate(gravity: BattleConst.bodyGravity, drag: BattleConst.bodyDrag);

    // Deck collision against the raft's height-field. Contact is per point
    // — a limb may hang past the rail without the body going over — and the
    // surface is continuous (platforms, ramps and deck are one profile), so
    // there is no crack a body can fall through mid-raft. A grounded body is
    // damped as a whole, because a body is one thing, not a bag of loose
    // points: the constraint drag of dangling limbs would otherwise creep an
    // ordinary hit all the way to the rail.
    final fric = dead ? BattleConst.bodyDeadFriction : BattleConst.bodyFriction;
    final hipSurface = raft.surfaceY(stationX + pose.hip.pos.dx);
    final grounded = hipSurface != null && pose.hip.pos.dy > hipSurface - 3;
    for (final p in pose.points) {
      final floor = raft.surfaceY(stationX + p.pos.dx);
      if (floor != null && p.pos.dy > floor) {
        final v = p.vel;
        p.pos = Offset(p.pos.dx, floor);
        // Hard impacts bounce; slow contact settles dead so a resting body
        // can actually come to rest.
        final bounce = v.dy > BattleConst.bodyRestSpeed ? BattleConst.bodyBounce : 0.0;
        p.prev = Offset(p.pos.dx - v.dx * fric, floor + v.dy * bounce);
      } else if (grounded) {
        p.setVel(p.vel * fric);
      } else if (!dead && floor == null) {
        // Rail lip: a living body still at deck level and still over the
        // edge line is bounced back aboard. Corpses skip the lip entirely —
        // the death drift carries them over, and the water takes them.
        final over = (stationX + p.pos.dx).abs() - raft.deckHalf;
        if (over > 0 &&
            over < BattleConst.railWall &&
            p.pos.dy > -BattleConst.railWallHeight &&
            p.pos.dy < 4) {
          final inward = (stationX + p.pos.dx) > 0 ? -1.0 : 1.0;
          final v = p.vel;
          if (v.dx * inward < 0) {
            p.setVel(Offset(-v.dx * 0.5, v.dy));
            p.pos = Offset(
              (raft.deckHalf * (stationX + p.pos.dx > 0 ? 1 : -1)) - stationX,
              p.pos.dy,
            );
          }
        }
      }
    }
    pose.solve();

    // Energy cap: constraint relaxation and stacked impulses can otherwise
    // fling points absurdly far — the "ragdoll into the sky" bug. Upward
    // velocity is capped far tighter than overall speed: sideways reads as
    // a knock-back, a high launch reads as a bug.
    for (final p in pose.points) {
      var v = p.vel;
      if (v.dy < -BattleConst.bodyMaxRise) {
        v = Offset(v.dx, -BattleConst.bodyMaxRise);
      }
      final speed = v.distance;
      if (speed > BattleConst.bodyMaxSpeed) {
        v = v / speed * BattleConst.bodyMaxSpeed;
      }
      p.setVel(v);
    }

    // Every death has to end in the water: a body that has all but stopped
    // on the deck keeps drifting toward the rail it fell toward.
    if (dead) {
      if (c.deathDir == 0) c.deathDir = raft.railDir(index);
      final hip = pose.hip;
      final hipFloor = raft.surfaceY(stationX + hip.pos.dx);
      final onDeck = hipFloor != null && hip.pos.dy <= hipFloor + 2;
      if (onDeck && hip.vel.dx.abs() < BattleConst.bodyDeadDrift) {
        hip.setVel(Offset(c.deathDir * BattleConst.bodyDeadDrift, hip.vel.dy));
      }
    }

    // Follow the body: the crew member's reported position tracks the ragdoll
    // hips so the camera, splash falloff and hit capsules stay honest.
    c.offset = Offset(pose.hip.pos.dx, pose.hip.pos.dy + 15);
    c.vel = pose.hip.vel;

    // Drowning: hips this far under the waterline ends them for the round.
    if (!c.drowned && raft.deckY + pose.hip.pos.dy > BattleConst.waterY + BattleConst.drownDepth) {
      c.drowned = true;
      c.ragdoll = false;
      c.hp = 0;
      c.vel = Offset.zero;
      effects.add(Fx(
        pos: Offset(raft.x + stationX + pose.hip.pos.dx, BattleConst.waterY),
        kind: 'splash',
        color: const Color(0xFFBFE9F2),
        size: 88,
        life: 0.7,
      ));
      return;
    }

    // Settling: down on the deck (or a platform), barely moving — stop
    // tumbling and stand. Only the living get up; a body at 0 HP stays down
    // until the water takes it. Speed and spin sit above the resting
    // jitter; the drift check catches a body still sliding (down a ramp,
    // say), which keeps resetting the window instead of rising mid-slide.
    final hipFloor = raft.surfaceY(stationX + pose.hip.pos.dx);
    final settled = hipFloor != null && pose.hip.pos.dy <= hipFloor + 2;
    if (c.alive &&
        settled &&
        pose.maxSpeed < BattleConst.bodySleepSpeed &&
        pose.maxSpin < BattleConst.bodySleepSpin) {
      if (c.rest <= 0 || (pose.hip.pos - c.restHip).distance > BattleConst.bodySettleDrift) {
        c.restHip = pose.hip.pos;
        c.rest = 1 / 60;
      } else {
        c.rest += 1 / 60;
      }
      if (c.rest >= BattleConst.bodySettleTime) {
        c.rest = 0;
        c.getUpT = 0;
      }
    } else {
      c.rest = 0;
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
/// up toward 85°. Returns null inside the dead zone or when the player
/// pulls *forward* rather than back — a forward pull reads as a drag-out
/// gesture and must not fire, otherwise an accidental swipe toward the
/// target would lob a shot across.
AimTarget? shapeAim(double dx, double dy) {
  // A forward pull (dx negative) is a drag-out, not an aim. It still has to
  // move the existing aim out of the way though — see [_resetAim], where the
  // controller clamps both axes when the player lets go without a pull.
  if (dx < 4.0) return null;
  final dist = sqrt(dx * dx + dy * dy);
  if (dist < BattleConst.deadzone) return null;

  final raw = min(1.0, (dist - BattleConst.deadzone) / (BattleConst.pullMax - BattleConst.deadzone));
  final shaped = raw < BattleConst.fineZone
      ? raw * 1.06
      : 0.70 + (raw - BattleConst.fineZone) * 0.88;

  final angle = (atan2(dy, dx) * 180 / pi)
      .clamp(BattleConst.angleMin, BattleConst.angleMax);
  final power = (shaped * 100).roundToDouble()
      .clamp(BattleConst.powerMin, BattleConst.powerMax);

  return AimTarget(angle: angle, power: power, fine: raw > BattleConst.fineZone);
}

/// Eases current aim toward [target] so a shaky finger produces a steady
/// readout rather than a twitching one.
///
/// The angle uses [BattleConst.smoothAngle] and the power [BattleConst.smoothPower].
/// Both factors are below 1 (any value above 1 overshoots the target every
/// frame and diverges — the old `SMOOTH * 10` design did this and ping-ponged
/// between clamps). The angle is eased harder than the power so the readout
/// reads the drag direction almost immediately.
({double angle, double power}) easeAim(double angle, double power, AimTarget target) {
  final a = angle + (target.angle - angle) * BattleConst.smoothAngle;
  final p = power + (target.power - power) * BattleConst.smoothPower;
  return (
    angle: (a * 10).roundToDouble() / 10, // 1 decimal place
    power: p.roundToDouble(),
  );
}
