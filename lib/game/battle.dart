import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'build.dart';
import 'characters.dart';
import 'maps.dart';
import 'models.dart';
import 'raft.dart';
import 'weapon_views.dart';

// CrewLook and the character roster moved to characters.dart when the five
// hardcoded archetypes grew into a full cast. Re-exported because this is
// where every caller already imports it from.
export 'characters.dart';

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
  /// flight — nor past [trajectoryMaxFrames] of simulation, so a
  /// full-power lob reveals barely more arc than a gentle one. Friv's Raft
  /// shows a stub of the arc, not the landing spot, and now that the rafts
  /// are far apart an uncapped preview would hand the player the exact
  /// range they are supposed to be guessing at.
  static const double trajectoryReveal = 0.26;

  /// Absolute cap on previewed flight frames, so the preview stays short
  /// even at maximum fire force (the arc used to climb halfway to the
  /// enemy on a full-power drag).
  static const double trajectoryMaxFrames = 30;

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

  /// Velocity kept per frame by a slow body already down on the deck. Verlet
  /// bodies shed energy very slowly on their own, and the residue was enough
  /// to keep resetting the settle window forever.
  static const double bodySettleDamp = 0.6;

  /// Below this, a grounded living body is simply stopped — static friction.
  ///
  /// Damping alone cannot hold a body still on a SLOPE, and the rounded
  /// hulls have one all along their deck: gravity re-adds a little downhill
  /// speed every frame, so the body creeps, the settle window's drift check
  /// keeps resetting, and the crew member lies there twitching until the
  /// watchdog fires. This is what stops the creep.
  static const double bodyStopSpeed = 0.75;

  /// How long a living body may keep tumbling on the deck before it is simply
  /// stood up. The settle check handles the ordinary case far faster; this is
  /// the guarantee that nothing can lie twitching by the rail waiting for a
  /// jitter that never quite dies down.
  static const double bodyRecoverLimit = 1.4;

  /// How long the stand-back-up blend takes once a settled ragdoll rises,
  /// and how fast a recovered crew member shuffles back to their station.
  static const double bodyGetUpTime = 0.5;
  static const double bodyRecover = 0.12;

  /// Residual walk-cycle phase advance per 60Hz step, used only while a
  /// walk is easing out and the body is no longer really covering ground.
  ///
  /// It used to drive every walk in the game at 0.30 cycles per frame —
  /// eighteen strides a second, which is why the legs scissored like a
  /// cartoon no matter how slowly the body actually moved. Real walking is
  /// driven by [walkStride] instead, off the distance covered.
  static const double walkCycleSpeed = 0.06;

  /// Ground covered by one full two-step walk cycle, in world units.
  ///
  /// Driving the phase off distance rather than off time is what keeps the
  /// legs and the floor agreeing: however fast the body is being moved —
  /// walked by the player, shuffling home, slowed by tar — each stride
  /// covers the same ground, so the feet never skate or sprint on the spot.
  /// Sized to the drawn leg swing (±7 units from centre, two steps a cycle).
  static const double walkStride = 26.0;



  // --- Terraced water --------------------------------------------------

  /// How far one terrace can stand above the next, in world units.
  ///
  /// Sized against a crew member, who is about a hundred units from boot to
  /// scalp: at the top of this range one raft's deck is well above the other
  /// crew's heads, which is a real change to every shot in the match, while
  /// the bottom of the range is a step you notice without it dominating.
  static const double waterStepMin = 34;
  static const double waterStepMax = 86;

  /// How wide the falls itself is — the stretch over which the surface makes
  /// the change.
  static const double fallsWidthMin = 74;
  static const double fallsWidthMax = 132;

  /// How much clear water a raft needs either side of its slot before a
  /// falls may be placed. Half the widest hull plus a margin — a raft is
  /// flat and rigid, and half of one hanging over a waterfall is nonsense.
  static const double raftClearance = 155;
  // --- Bodies as hazards -----------------------------------------------
  //
  // A ragdoll flung across the deck is a projectile in its own right: it
  // hurts whoever it lands on and knocks them down too, so a well-placed
  // shot into a crowded deck can start a pile-up. The thresholds below are
  // what keep that a spectacle rather than a mess — a body that is merely
  // sliding along the planks has to be harmless, or a single knockdown next
  // to a neighbour would grind the whole crew down for free.

  /// Minimum speed (world units per 60Hz frame) at which a tumbling body
  /// counts as a hazard. Below this it is sliding, not flying.
  static const double bodySlamSpeed = 3.2;

  /// How close two body centres must come, in world units, to collide.
  /// Roughly a torso's width plus a body's half-width.
  static const double bodySlamRadius = 24;

  /// HP per unit of speed above [bodySlamSpeed], and the cap on one slam.
  /// Capped well below a weapon hit: being bowled into is a complication,
  /// not a way to win the game without aiming.
  static const double bodySlamDamage = 2.6;
  static const double bodySlamMaxDamage = 20;

  /// Seconds before a body that has just been bowled over can be bowled
  /// again. Without it two bodies resting against each other trade a hit
  /// every frame and delete each other.
  static const double bodySlamCooldown = 0.6;

  /// Fraction of its speed the flying body keeps after a slam — it spends
  /// energy on the person it hit, so a chain reaction runs down instead of
  /// ricocheting around the deck forever.
  static const double bodySlamBleed = 0.5;

  // --- Obstacles in the channel ----------------------------------------
  //
  // The stretch of open water between the player's raft and the nearest
  // enemy slot. Obstacles are placed only inside this band, so they can
  // never sit on top of a raft or behind the furthest enemy — the point is
  // to complicate the line between the two, not to hide anybody.

  /// Left and right edges of the band obstacles may occupy.
  static const double obstacleBandStart = playerX + 260;
  static const double obstacleBandEnd = 1240;


  /// Percent chance that a shot is followed by a firing flourish.
  ///
  /// Not every shot: a flourish after every single one stops reading as a
  /// flourish and becomes the firing animation, which is both duller and
  /// slower than no flourish at all.
  static const int fireFlourishPercent = 45;
  /// Seconds an obstacle shudders for after being struck.
  static const double obstacleStruckTime = 0.28;

  /// Base height above the waterline of each obstacle kind, and its
  /// half-width. The height a given obstacle actually gets is this scaled by
  /// [obstacleHeightJitter] and by how close to mid-channel it sits — see
  /// `_buildObstacles`.
  ///
  /// A crew member's head stands about a hundred units above the water, and
  /// these are sized against that: a wreck is knee-high and only spoils the
  /// very flattest shots, while a mast stands half again as tall as a person
  /// and has to be gone over.
  static const Map<String, (double halfW, double height, int hits)> obstacleSizes = {
    'wreck': (70, 62, 0),
    'rock': (42, 104, 0),
    'iceberg': (62, 130, 0),
    'buoy': (13, 140, 2),
    'crate': (28, 158, 3),
    'mast': (10, 224, 0),
  };

  /// The tallest each kind may ever be drawn relative to its own width.
  ///
  /// The height roll and the mid-channel bonus both scale a kind's base, and
  /// scaling alone does not know what the thing IS: stretched to the same
  /// multiple, a slender mast still reads as a mast while a crate becomes a
  /// door and a rock becomes a menhir. Capping on the aspect ratio keeps each
  /// kind recognisable however tall the channel wants it.
  static const Map<String, double> obstacleMaxAspect = {
    'wreck': 1.1,
    'rock': 2.4,
    'iceberg': 2.0,
    'buoy': 6.5,
    'crate': 3.0,
    'mast': 12.0,
  };

  /// Random scale applied to every obstacle's height.
  ///
  /// Widened along with the heights themselves: the point of making them tall
  /// is that the field genuinely dictates the arc, and a tall field that is
  /// always the SAME tall field is a fixed puzzle you solve once. The spread
  /// is what keeps each match's channel its own problem.
  static const double obstacleHeightMin = 0.62;
  static const double obstacleHeightMax = 1.6;

  /// Extra height for standing in mid-channel, at the very centre.
  ///
  /// The tall ones belong in the middle. An obstacle near either raft is
  /// close to the muzzle or close to the target, where a shot is low and a
  /// modest lump already blocks it; in the middle the shot is at the top of
  /// its arc, so only real height makes any difference to how you have to
  /// aim. Putting the height where it changes the aim is the whole point.
  static const double obstacleCentreBoost = 0.6;

  /// Most a kind may be stretched beyond its own base height. The roll and
  /// the mid-channel bonus compound, and unclamped they reach about 2.5x,
  /// which stops a slender kind reading as itself.
  static const double obstacleStretchMax = 1.85;

  /// Sky left above the tallest obstacle, in world units. The cap is
  /// measured down from the water at that spot rather than being a fixed
  /// height, because a terrace raises the water and lowers the ceiling with
  /// it.
  static const double obstacleSkyMargin = 26;
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
  // Shortened from 8: a body that has somehow failed to settle should be put
  // right long before the player notices it twitching on the deck.
  static const double ragdollWatchdog = 3.5;

  /// Total time a weapon swap takes: lower to the hip, equip at the
  /// midpoint, raise the new model into the grip.
  static const double weaponSwapTime = 0.5;

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

  /// How far above the rail's own deck surface the lip still catches a body.
  ///
  /// Raised from 14. Measured against the outermost berth on every hull, the
  /// old window let a plain TENNIS BALL — the starter weapon — put a crew
  /// member in the sea, which is what "they fall off far too easily" was.
  /// Retuned alongside the crew-spacing fix: berths spread out toward the
  /// rails, so the same lip that was barely adequate at the old packed
  /// positions became an absolute wall at the new ones. At 16 the starter
  /// weapon never drowns anyone and a heavier round still occasionally does, so going overboard stays a real threat rather than a
  /// coin toss on every hit. Anything lofted higher than this clears the lip
  /// outright, which is what keeps it possible at all.
  static const double railWallHeight = 16.0;

  /// How far BELOW the rail surface the lip still acts, so a body already
  /// dropping past the edge is still shouldered back aboard rather than
  /// slipping under the check.
  static const double railWallDepth = 10.0;

  /// How much of a caught point's outward speed is returned as a bounce.
  static const double railBounce = 0.5;

  /// The fraction of the whole body's outward drift the rail bleeds off when
  /// it catches a limb. Deliberately well below 1: at 0.75 nothing short of
  /// twenty times a real weapon's shove could carry a body over at all, which
  /// turned the rail into a wall.
  static const double railHold = 0.25;

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

  /// Extra angular kick thrown into a head-region hit — the "shoot off and
  /// backflip" tumble, delivered through [RagdollPose.applyImpulse]'s
  /// [spin]. Landed on top of the ordinary torque.
  static const double headshotSpin = 0.58;

  /// Hard cap on angular velocity after a spin kick — above the ordinary
  /// torque clamp so a headshot visibly whips the body over, but still
  /// finite so nothing spins forever.
  static const double ragdollSpinCap = 0.82;

  /// How long a struck crew member stays curled after a flip-inducing hit,
  /// and how fast the curl comes on and lets go. The tuck is what converts
  /// a modest hop into a readable somersault — see [RagdollPose.tuck]. The
  /// rate is deliberately brisk: a flip only has [flipLift]'s worth of hang
  /// time, so a curl that eased in over half a second would arrive after the
  /// body had already landed.
  // A ceiling, not the normal case: the tuck is released the moment the body
  // lands (see BattleWorld's stepper). This only bounds a body that never
  // comes down — one heading over the side, say. Was 1.1s, which on its own
  // left a landed body curled up for the better part of a second.
  static const double flipTuckTime = 0.6;

  /// Consecutive grounded frames before a flip's curl is released. A
  /// somersaulting hip skims the planks partway round, and letting go on
  /// that single frame cut the rotation short.
  static const int flipLandFrames = 5;
  static const double flipTuckRate = 22.0;

  /// Uniform upward velocity added to a somersaulting body, and the rise cap
  /// that applies while the flip runs (ordinary knock-backs keep
  /// [bodyMaxRise]).
  ///
  /// A somersault needs hang time as well as spin. With the tuck in place the
  /// body turns at roughly 0.3 rad/frame, so a full revolution wants about 21
  /// airborne frames — which is what this launch buys. It is a deliberately
  /// small exception: the apex still sits well inside the world's scale, and
  /// only a hit that actually triggered a flip is ever launched this way.
  // Raised from 4.5 alongside the shallower [RagdollPose.tuckShrink]. A
  // shallower curl spins slower, so the rotation has to be paid for in hang
  // time instead — this is the trade that lets a somersault still come all
  // the way round without curling the body into an unreadable marble.
  static const double flipLift = 5.0;
  static const double flipRise = 5.2;

  /// Chance a head hit sends the victim into a flip at all, and the extra
  /// chance per unit of projectile weight on top — a tennis ball to the
  /// skull sometimes does it, an anchor round nearly always does.
  static const double flipChanceBase = 0.42;
  static const double flipChancePerWeight = 0.30;

  /// Probability that a head hit from a round of this [weight] somersaults
  /// the victim. Capped short of certainty so even the heaviest round
  /// occasionally just knocks someone flat.
  static double flipChanceFor(double weight) =>
      (flipChanceBase + weight * flipChancePerWeight).clamp(0.0, 0.92);

  /// Chance a leg hit spins the victim out sideways instead of simply
  /// sweeping their feet — the low-line counterpart to the head flip.
  static const double sweepSpinChance = 0.35;
  static const double sweepSpin = 0.3;

  /// How long a leg-region hit keeps its planted foot glued to the deck
  /// while the rest of the body flies — the "one leg still standing"
  /// stumble that pivots the body around the planted boot.
  static const double legPlantTime = 0.8;

  /// How long a torso-region hit keeps the off hand clutching the spot.
  static const double grabTime = 0.7;

  /// How fast screen-shake energy bleeds off, in units per second.
  static const double shakeDecay = 55;

  // ---------------------------------------------------------------------------
  // Death sequence
  // ---------------------------------------------------------------------------

  /// How long the flare at the wound lasts on a killing blow.
  ///
  /// This used to be a 0.16s white overlay across the WHOLE body at 0.85
  /// alpha — a full-figure strobe on a two-frame timer, which is a flicker
  /// rather than an impact, and it landed on the same frame the body
  /// switched from its standing drawing to a ragdoll. Two discontinuities at
  /// once read as the character being replaced rather than killed.
  ///
  /// It is now a flare at the point of impact that eases up and back down,
  /// with sparks thrown off it, over roughly twice as long — so the eye is
  /// pulled to the wound while the body takes over underneath.
  static const double deathFlashTime = 0.34;

  /// How long the body keeps throwing sparks after a killing blow.
  static const double deathSparkTime = 0.5;

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

  // ---------------------------------------------------------------------------
  // Facial expressions
  // ---------------------------------------------------------------------------

  /// How long a survived hit shows a pained wince on the victim's face.
  static const double hitReactTime = 0.5;

  /// How long a landed shot shows a satisfied grin on the shooter's face.
  static const double gloatTime = 1.0;

  /// HP fraction below which an alive crew member's default face turns
  /// worried (and blinks faster) whenever nothing more urgent is happening.
  static const double lowHpFace = 0.3;
}

/// One point of the verlet ragdoll. Position is integrated; velocity is
/// implicit (pos − prev), which makes bounce and friction a matter of
/// nudging [prev] at collision time.
class RagdollPoint {
  Offset pos;
  Offset prev;

  /// 1 / mass. Zero would pin the point — no crew point is ever pinned.
  final double invMass;

  /// 0 = free; >0 = planted in place. A planted point neither falls nor
  /// moves during the constraint solve — used for the "one leg still
  /// standing" tumble, where the far boot stays glued to the deck while
  /// the rest of the body whips around it.
  int pin = 0;

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
  factory RagdollPose.standingAt(Offset origin, {double mass = 1}) {
    Offset at(double dx, double dy) => origin + Offset(dx, dy);
    // Per-character mass: a broad dockhand is genuinely heavier than a wiry
    // dune runner, so the same blow shoves them less far and spins them
    // slower. Before this every body weighed the same and tumbled the same
    // way, which is most of why a deck of different-looking crew still read
    // as one puppet the moment anything hit them.
    final pose = RagdollPose._(
      RagdollPoint(at(0, -58), mass: 0.9 * mass),
      RagdollPoint(at(0, -42), mass: 1.2 * mass),
      RagdollPoint(at(0, -15), mass: 2.2 * mass),
      RagdollPoint(at(-10, -25), mass: 0.7 * mass),
      RagdollPoint(at(10, -25), mass: 0.7 * mass),
      RagdollPoint(at(-8, 0), mass: 1.1 * mass),
      RagdollPoint(at(8, 0), mass: 1.1 * mass),
    );
    final c = pose._constraints;
    // Spine and legs: rigid.
    c.add(_RagConstraint(pose.head, pose.neck, 16));
    c.add(_RagConstraint(pose.neck, pose.hip, 27));
    c.add(_RagConstraint(pose.hip, pose.footL, 15));
    c.add(_RagConstraint(pose.hip, pose.footR, 15));
    // Arms: ropes — elbows fold, so the hands may come close but never
    // stretch past full reach.
    //
    // The minimum was 6, which let both hands collapse onto the throat: a
    // settled body ended up with its forearms folded in a tight X across its
    // chest, like a mummy. 12 is roughly a folded elbow's worth, so the arms
    // still bend right up but the hands stay out where a person's would.
    c.add(_RagConstraint(pose.neck, pose.handL, 26, min: 12, max: 26));
    c.add(_RagConstraint(pose.neck, pose.handR, 26, min: 12, max: 26));
    // Hands keep out of each other's way, exactly as the feet do. Without
    // this the two arms converge on the same spot and cross over the body —
    // the constraint to the neck alone says nothing about which SIDE of it a
    // hand is on.
    c.add(_RagConstraint(pose.handL, pose.handR, 22, min: 15, max: 44));
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
  /// gravity with per-frame drag. Planted points sit still — they neither
  /// fall nor drift, so a planted foot can hold a whole body upright around
  /// itself.
  void integrate({required double gravity, required double drag}) {
    for (final p in points) {
      if (p.pin > 0) {
        p.prev = p.pos;
        continue;
      }
      final v = (p.pos - p.prev) * drag;
      p.prev = p.pos;
      p.pos += v + Offset(0, gravity);
    }
  }

  /// How tightly the body is curled, 0 (spread out) to 1 (knees to chest).
  ///
  /// A tuck is what makes a backflip actually read as one. Every ragdoll
  /// point is speed-capped ([BattleConst.bodyMaxSpeed]) so nothing can be
  /// flung out of the world, and a point's speed under rotation is
  /// `spin * radius` — so a sprawled body, whose head sits ~43 units from the
  /// hip, cannot spin fast enough to come round inside the hang time a hop
  /// affords — it turns about three quarters of a somersault and flops back,
  /// which reads as being knocked over rather than flipped.
  ///
  /// Curling in is what fixes it, and the budget is tight in both directions:
  /// a point's speed is `linear + spin * radius` against one shared cap, so
  /// launching higher (more hang time) directly costs spin. Cutting the
  /// radius is the only move that buys rotation without spending lift, and
  /// [tuckShrink] is set where a flip clears a full turn with margin. A
  /// cannonball silhouette is what a flip looks like anyway.
  double tuck = 0;

  /// How much a full tuck shortens the body's constraints — every rest
  /// length, so the curl pulls head and boots toward the hip together.
  ///
  /// Was 0.66, which curled the body to barely a third of its size: enough
  /// rotation for two and a bit somersaults, and far past anything that
  /// still read as a person. At 0.42 the head still comes to about 58% of
  /// its standing radius from the hip, which caps the spin at roughly
  /// `bodyMaxSpeed / 25 ≈ 0.36` rad/frame — over a flip's ~22 frames of
  /// hang time that is comfortably more than a full turn, so somersaults
  /// land exactly as before while the body stays legible mid-air.
  static const double tuckShrink = 0.18;

  /// What a curled body's ARTWORK should be scaled by.
  ///
  /// The solver shrinks the skeleton; without this the renderer kept drawing
  /// a full-size torso, head and boots inside it, which is what turned a
  /// tucked ragdoll into an unreadable blob. Exposed rather than recomputed
  /// in the renderer so the two can never disagree about how curled a body
  /// is.
  double get drawScale => 1 - tuckShrink * tuck.clamp(0.0, 1.0);

  /// Relaxation pass over every constraint. Called [BattleConst.ragdollIters]
  /// times per step, after integration and after any collision response.
  void solve() {
    // Curling scales every rest length, including the keep-apart minimums —
    // those exist to stop the body folding flat, and would otherwise fight
    // the tuck instead of merely limiting it.
    final k = drawScale;
    for (int it = 0; it < BattleConst.ragdollIters; it++) {
      for (final con in _constraints) {
        final delta = con.b.pos - con.a.pos;
        final d = delta.distance;
        if (d <= 1e-6) continue;
        final len = con.len * k;
        final cmin = con.min == null ? null : con.min! * k;
        final cmax = con.max == null ? null : con.max! * k;
        double diff = 0;
        if (cmin == null && cmax == null) {
          diff = (d - len) / d;
        } else if (cmax != null && d > cmax) {
          diff = (d - cmax) / d;
        } else if (cmin != null && d < cmin) {
          diff = (d - cmin) / d;
        }
        if (diff == 0) continue;
        // Planted points are inert: they anchor the constraint like a wall.
        final ia = con.a.pin > 0 ? 0.0 : con.a.invMass;
        final ib = con.b.pin > 0 ? 0.0 : con.b.invMass;
        final wSum = ia + ib;
        if (wSum <= 0) continue;
        final corr = delta * diff;
        con.a.pos += corr * (ia / wSum);
        con.b.pos -= corr * (ib / wSum);
      }
    }
  }

  /// Applies a blow delivered at [hitLocal] (station-local) with per-frame
  /// velocity [impulse]: every point takes the linear shove, and an
  /// off-centre hit adds torque around the centre of mass — a shot to the
  /// head snaps the body head-over-heels while one to the legs sweeps the
  /// feet out from under them. [spin] adds an extra angular kick on top
  /// (headshot backflips), clamped at the hard [BattleConst.ragdollSpinCap].
  void applyImpulse(Offset hitLocal, Offset impulse, {double spin = 0}) {
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
    w = (w + spin).clamp(-BattleConst.ragdollSpinCap, BattleConst.ragdollSpinCap);

    for (final p in points) {
      final r = p.pos - com;
      final lin = impulse * BattleConst.ragdollLinear;
      final tan = Offset(-r.dy, r.dx) * w;
      p.setVel(p.vel + lin + tan);
    }
  }

  /// Mass-weighted mean velocity of the whole body — its drift, with any
  /// rotation about the centre of mass averaged out.
  Offset get meanVel {
    var sum = Offset.zero;
    var mass = 0.0;
    for (final p in points) {
      final m = p.invMass > 0 ? 1 / p.invMass : 0.0;
      sum += p.vel * m;
      mass += m;
    }
    return mass <= 0 ? Offset.zero : sum / mass;
  }

  /// Limits how fast the body as a whole may rise, without touching the
  /// rotation about its centre of mass.
  ///
  /// Applying the limit to each point separately would also shave the upward
  /// half of any spin — which is exactly what stopped somersaults from
  /// coming round. Correcting the mean and applying that same correction to
  /// every point moves the body without changing its rotation at all.
  void capRise(double maxRise) {
    final v = meanVel;
    if (v.dy >= -maxRise) return;
    final delta = Offset(0, -maxRise - v.dy);
    for (final p in points) {
      p.setVel(p.vel + delta);
    }
  }

  /// Adds a uniform upward velocity to the whole body — the launch that buys
  /// a somersault enough hang time to finish. Uniform, so it lifts without
  /// disturbing the spin already applied.
  void addLift(double amount) {
    for (final p in points) {
      p.setVel(p.vel + Offset(0, -amount));
    }
  }

  /// Blends every point toward [target]'s layout by [t] (0..1), killing
  /// momentum as it goes — the stand-back-up animation. Physics is
  /// suspended while the blend runs.
  /// Repositions this pose into the standing layout at [origin] in place.
  ///
  /// The get-up blend needs a fresh standing target every frame, and was
  /// building a whole new [RagdollPose] each time — seven points, thirteen
  /// constraint objects and two lists — for every body currently standing up.
  /// One blast can put three or four crew members into that state at once, so
  /// the frames right after an impact were allocating hardest at exactly the
  /// moment the player is watching. Reusing one scratch pose costs nothing.
  void setStandingAt(Offset origin) {
    void put(RagdollPoint p, double dx, double dy) {
      p.pos = Offset(origin.dx + dx, origin.dy + dy);
      p.prev = p.pos;
      p.pin = 0;
    }

    // Same layout as [standingAt]; the two must not drift apart.
    put(head, 0, -58);
    put(neck, 0, -42);
    put(hip, 0, -15);
    put(handL, -10, -25);
    put(handR, 10, -25);
    put(footL, -8, 0);
    put(footR, 8, 0);
  }

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
/// Short, random things a crew member does with their face while standing
/// around not shooting — picked by [Crew.updateIdle] every few seconds so
/// the deck never reads as a row of frozen mannequins. Rendered by the
/// face painter; each activity has a matching voice blip (see
/// [BattleWorld.onVoice]).
enum CrewIdle {
  none,

  /// Eyes dart left and right, scanning the horizon.
  lookAround,

  /// A big slow yawn, eyes squeezing shut — and the whole body stretches up
  /// with it.
  yawn,

  /// Puckered mouth with floating music notes, and a gentle sway.
  whistle,

  /// A brief bout of flapping-mouth chatter, hands talking along.
  chatter,

  /// Alternating brow bobs and a smirk.
  browWaggle,

  /// A big overhead stretch, up on the toes.
  stretch,

  /// Bouncing on the spot out of sheer boredom.
  hop,

  /// A "search me" shrug, shoulders up and free hand out.
  shrug,

  /// Free hand up to the head, puzzled.
  scratchHead,

  /// A short private jig. Rare, and the funniest one.
  jig,

  // --- Standing about, continued ----------------------------------------
  //
  // A deck of people who cycle through eleven things starts to read as a
  // loop surprisingly quickly — you notice the repeat long before you can
  // name it. These widen the pool enough that a whole match can go by
  // without a crew member obviously repeating themselves.

  /// Holds a hand out and inspects their nails, thoroughly unimpressed.
  checkNails,

  /// Swats at something buzzing round their head.
  swatFly,

  /// Leans right over the rail to look at the water.
  lookOverboard,

  /// Buffs the firearm on a sleeve.
  polishWeapon,

  /// Shows off a bicep to nobody in particular.
  flex,

  /// Takes the hat off, settles it back on.
  adjustHat,

  /// A wind-up and a whole-body snap forward.
  sneeze,

  /// Hugs themselves and shivers.
  shiver,

  /// Points across the water at the enemy.
  pointAtEnemy,

  /// Counts what is left in the ammo pouch.
  countAmmo,

  /// Waves at the other raft, cheerfully, while trying to kill them.
  wave,

  /// Scuffs a boot along the planks out of boredom.
  kickDeck,

  // --- Firing flourishes -------------------------------------------------
  //
  // The shooter is the one crew member the player is actually looking at,
  // and they were the only one who never did anything: activities are
  // suppressed for whoever is lining up, for the good reason that a body
  // twisting about mid-aim looks broken. These play in the beat AFTER the
  // shot leaves, while the round is in the air and the body is free again.

  /// Blows the smoke off the barrel.
  blowBarrel,

  /// Spins the firearm once and tucks it back.
  spinWeapon,

  /// A sharp fist-pump.
  fistPump,

  /// A two-finger salute at the target.
  salute,

  /// Both arms out, jeering across the water.
  jeer,

  /// Slaps the weapon, satisfied with it.
  patWeapon,
}

/// How the whole body is carrying itself this frame.
///
/// Faces alone were doing all the acting, which reads as a row of mannequins
/// with animated heads — at raft scale the face is barely fifteen pixels
/// across, so an expression that lives only there is an expression nobody
/// sees. Every value here moves the BODY: the knees, the spine, the free
/// arm, the whole figure's height off the deck.
///
/// Deliberately a plain value object computed from crew state rather than an
/// animation system: it is a pure function of (crew, time), so the renderer
/// can ask for it every frame, the tests can assert on it directly, and
/// nothing about how a body feels can drift out of sync with what it is
/// actually doing.
class BodyExpression {
  /// 0..1 knee bend. Raises the hips when negative-going (a stretch).
  final double crouch;

  /// Forward (+) / back (−) lean of the whole upper body, in radians.
  final double lean;

  /// 0..1 of the free arm raised overhead.
  final double armRaise;

  /// Vertical offset in world units; negative is up off the deck.
  final double bounce;

  /// Horizontal shake in world units — shivering, or a laugh.
  final double tremble;

  /// 0..1 shoulder droop. Exhaustion, tar, or very low health.
  final double slump;

  /// 0..1 head tilt toward the gun side, for puzzlement and shrugs.
  final double headTilt;

  /// Where the raised free hand goes, along the body's facing axis.
  ///
  /// −1 pulls it across the chest, 0 leaves it at the shoulder, +1 extends
  /// it out in front. [armRaise] alone was only a height, so every activity
  /// that raised an arm put the hand in the identical spot: a wave, a
  /// salute, a point across the water and somebody inspecting their nails
  /// were the same drawing with a different face. Height and reach together
  /// are enough to tell them apart at raft scale.
  final double armReach;

  const BodyExpression({
    this.crouch = 0,
    this.lean = 0,
    this.armRaise = 0,
    this.bounce = 0,
    this.tremble = 0,
    this.slump = 0,
    this.headTilt = 0,
    this.armReach = 0,
  });

  static const none = BodyExpression();

  bool get isNeutral =>
      crouch == 0 &&
      lean == 0 &&
      armRaise == 0 &&
      bounce == 0 &&
      tremble == 0 &&
      slump == 0 &&
      headTilt == 0 &&
      armReach == 0;
}

/// Which band of the body a given blow landed on — computed from the
/// station-local hit point and used to pick the funny ragdoll reaction:
/// headshots can whip into a backflip, leg hits plant one boot and make the
/// rest of the body pivot around it, torso hits sometimes clutch the spot.
enum HitZone {
  head,
  torso,
  legs,
}

/// How *this particular tumble* goes.
///
/// [RagdollTraits] says what kind of person this is — a dockhand is heavy, a
/// runner cartwheels — and it never changes, which is precisely why a deck
/// of different-looking crew still read as one puppet: the same character
/// hit the same way always fell exactly the same way, every time, all game.
///
/// A style is rolled fresh for every knock, so no two tumbles match even for
/// the same character. It is a set of multipliers on things the tumble
/// already does rather than new behaviour, so a body cannot be rolled into
/// something that reads wrong — every field's range is bounded either side
/// of the old fixed value.
///
/// **It must stay deterministic.** A hotspot match is lockstep: both devices
/// build the same world from one seed and exchange only shots, so anything
/// that moves a body has to be computable from state both sides already
/// hold. That rules out [Random] entirely — hence the integer hash below,
/// fed from the shot and a per-crew tumble counter.
class RagdollStyle {
  /// How deeply this tumble curls in the air, as a fraction of a full tuck.
  /// A somersault no longer depends on the curl to come round (see the
  /// ragdoll tests), so this is free to vary for looks.
  final double curl;

  /// Windmill: how hard the arms are thrown about, how fast, and where in
  /// the cycle this body starts. The phase matters most — identical timing
  /// is what made two bodies hit at once look like one body drawn twice.
  final double flailGain;
  final double flailRate;
  final double flailPhase;

  /// How loose the body is. Above 1 it bleeds energy faster and sprawls;
  /// below 1 it stays stiff and skitters.
  final double limp;

  /// Multiplier on how long they lie there before picking themselves up.
  final double linger;

  /// Which shoulder leads, and how much: a small asymmetric kick at the
  /// moment of impact so the body twists off-axis instead of tumbling
  /// perfectly in-plane.
  final double twist;

  /// Multiplier on the spin an impact imparts.
  final double spinScale;

  const RagdollStyle({
    this.curl = 1,
    this.flailGain = 1,
    this.flailRate = 1,
    this.flailPhase = 0,
    this.limp = 1,
    this.linger = 1,
    this.twist = 0,
    this.spinScale = 1,
  });

  /// The old fixed behaviour, kept as the default so anything that knocks a
  /// body without rolling a style (tests, the drift that pushes a corpse
  /// overboard) behaves exactly as it did.
  static const plain = RagdollStyle();

  /// Deterministic roll from an integer seed.
  ///
  /// A cheap integer bit-mix rather than [Random]: it has to produce the
  /// identical style on both devices in a hotspot match from the same seed,
  /// and it is called on an impact frame, which is already the most
  /// expensive frame in the game.
  factory RagdollStyle.roll(int seed) {
    var h = seed * 0x9E3779B1;
    double next(double lo, double hi) {
      h ^= h >>> 15;
      h = (h * 0x85EBCA6B) & 0x7FFFFFFF;
      h ^= h >>> 13;
      return lo + (h & 0xFFFF) / 0xFFFF * (hi - lo);
    }

    return RagdollStyle(
      curl: next(0.55, 1.0),
      flailGain: next(0.35, 1.7),
      flailRate: next(0.7, 1.45),
      flailPhase: next(0, 2 * pi),
      limp: next(0.75, 1.35),
      linger: next(0.65, 1.75),
      twist: next(-1, 1),
      spinScale: next(0.75, 1.3),
    );
  }
}

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

  /// Seconds of sparks still coming off a fresh kill. Counts down alongside
  /// [deathFlash]; the renderer throws embers from the wound while it runs.
  double deathSpark = 0;

  /// Where the killing blow landed, in the body's own frame — so the flare
  /// and the sparks come off the wound rather than off the middle of the
  /// figure. The point of impact IS the thing to look at while the standing
  /// drawing hands over to the ragdoll underneath it.
  Offset deathWound = Offset.zero;

  // --- Facial expression ------------------------------------------------

  /// Seconds left showing a pained wince — set the instant a hit is
  /// survived (see [BattleWorld._resolve]), consumed by the renderer and
  /// counted down in [BattleWorld._stepBodies]. Overrides every other
  /// expression, including mid-tumble, so a ragdoll reads the same flinch
  /// that knocked it down.
  double hitReactT = 0;

  /// Seconds left showing a satisfied grin — set on the shooter's active
  /// crew member the instant their own shot lands on an enemy.
  double gloatT = 0;

  // --- Status effects -------------------------------------------------------

  /// What a boss round left on this crew member, or null. See [StatusEffect]:
  /// this is how a boss takes a turn's advantage away instead of simply
  /// hitting harder.
  StatusEffect? status;

  /// Turns of [status] left. Counted down by the controller as the turn comes
  /// back round to this seat, not by wall clock — an effect that expired
  /// while somebody else was aiming would be no effect at all.
  int statusTurns = 0;

  /// Seconds of the "just applied" flash left, for the renderer.
  double statusFlash = 0;

  bool get afflicted => status != null && statusTurns > 0;

  /// Launch power multiplier from the current status. 1.0 when clean.
  double get statusPowerScale => afflicted ? status!.powerScale : 1.0;

  /// How much knockback still lands. Tar makes a body harder to shift.
  double get statusKnockScale => afflicted ? status!.knockScale : 1.0;

  /// True while this crew member has to sit a turn out.
  bool get snared => afflicted && status == StatusEffect.snared;

  /// Applies [effect] for [turns]. A fresh application always replaces
  /// whatever was there rather than stacking — two statuses at once, or a
  /// long one topped up before it lapses, is exactly the runaway a boss
  /// fight must not have.
  void afflict(StatusEffect effect, int turns) {
    status = effect;
    statusTurns = turns;
    statusFlash = 0.6;
  }

  void clearStatus() {
    status = null;
    statusTurns = 0;
  }

  /// Ticks the status down by one of this crew member's own turns. Returns
  /// true if they are snared and must sit this one out.
  bool consumeTurnStatus() {
    if (!afflicted) {
      status = null;
      return false;
    }
    final wasSnared = snared;
    statusTurns--;
    if (statusTurns <= 0) clearStatus();
    return wasSnared;
  }

  // --- Ragdoll reactions ----------------------------------------------------

  /// Which foot is planted from a leg-hit tumble: −1 left, +1 right, 0
  /// none. The planted boot stays glued to the deck while everything else
  /// flies — the "one leg still standing" stumble.
  double plantFoot = 0;

  /// Seconds left the plant is active.
  double plantT = 0;

  /// Seconds left clutching the spot a torso hit landed on — the off hand
  /// grabs the belly while they tumble.
  double grabT = 0;

  /// Seconds left of an active somersault. While this runs the ragdoll curls
  /// in ([RagdollPose.tuck]), which is both what a flip looks like and what
  /// lets it spin fast enough to complete under the point speed cap.
  double flipT = 0;

  /// True once the current flip has actually left the deck.
  ///
  /// A flip begins while the body is still standing on the planks, so being
  /// grounded only means "landed" after this has been seen. Without it the
  /// tuck would be cancelled on the very frame it was applied.
  bool flipAirborne = false;

  /// Consecutive frames the flipping body has been down on the deck.
  ///
  /// A somersault's hip passes close to the planks partway round, and
  /// releasing the curl on that single frame cut the rotation short — the
  /// flip stopped coming all the way round. The landing has to actually
  /// stick before the tuck is let go.
  int flipGround = 0;

  /// Frees a planted foot, if any.
  void clearPlant() {
    plantFoot = 0;
    plantT = 0;
    if (pose != null) {
      pose!.footL.pin = 0;
      pose!.footR.pin = 0;
    }
  }

  // --- Idle micro-activities ------------------------------------------------

  /// What this crew member is currently fidgeting with while standing
  /// around; [CrewIdle.none] most of the time. Advanced by
  /// [BattleWorld]'s body stepper, drawn by the face painter.
  CrewIdle idle = CrewIdle.none;

  /// Seconds left on the current idle activity.
  double idleT = 0;

  /// Duration the current activity was picked for — lets the renderer
  /// ease expressions in and out over the activity's lifetime.
  double idleDur = 1;

  /// Countdown to the next idle activity; staggered per character via
  /// [bobPhase] so the crew never fidgets in lockstep.
  double idleNextIn = 0;

  /// Per-character RNG for idle picking — seeded from [bobPhase] rather
  /// than the world's stream, so idle fidgets never perturb battle
  /// determinism (camera, AI and decor all share [BattleWorld.rng]).
  late final Random _idleRng = Random((bobPhase * 7919).round() ^ 0x5f37);

  /// Advances the idle fidget state. Returns the name of the voice blip to
  /// play when a new activity starts (null otherwise). New activities are
  /// only picked when [allowNew] — the active shooter keeps a straight
  /// face while lining up their shot.
  String? updateIdle(double dt, {required bool allowNew}) {
    if (!alive || ragdoll || pose != null) {
      idle = CrewIdle.none;
      idleT = 0;
      return null;
    }
    if (idle != CrewIdle.none) {
      idleT -= dt;
      if (idleT <= 0) {
        idle = CrewIdle.none;
        idleNextIn = 5 + _idleRng.nextDouble() * 8;
      }
      return null;
    }
    if (!allowNew) return null;
    idleNextIn -= dt;
    if (idleNextIn > 0) return null;
    // Weighted toward the whole-body activities: a deck of people stretching,
    // hopping and shrugging reads as alive from across the screen, where a
    // deck of people making faces reads as a row of statues.
    const pool = [
      CrewIdle.lookAround,
      CrewIdle.yawn,
      CrewIdle.whistle,
      CrewIdle.chatter,
      CrewIdle.browWaggle,
      CrewIdle.stretch,
      CrewIdle.stretch,
      CrewIdle.hop,
      CrewIdle.shrug,
      CrewIdle.scratchHead,
      CrewIdle.jig,
      CrewIdle.checkNails,
      CrewIdle.swatFly,
      CrewIdle.lookOverboard,
      CrewIdle.polishWeapon,
      CrewIdle.flex,
      CrewIdle.adjustHat,
      CrewIdle.sneeze,
      CrewIdle.shiver,
      CrewIdle.pointAtEnemy,
      CrewIdle.countAmmo,
      CrewIdle.wave,
      CrewIdle.kickDeck,
    ];
    return _begin(pool[_idleRng.nextInt(pool.length)]);
  }

  /// The flourishes the shooter may throw after a shot leaves the barrel.
  ///
  /// Kept apart from the standing-about pool on purpose. These read as a
  /// reaction to having just fired — blowing the barrel, a fist-pump — and
  /// would be nonsense on a crew member who has not shot anything.
  static const fireFlourishes = [
    CrewIdle.blowBarrel,
    CrewIdle.spinWeapon,
    CrewIdle.fistPump,
    CrewIdle.salute,
    CrewIdle.jeer,
    CrewIdle.patWeapon,
  ];

  /// Starts a firing flourish, if one is due.
  ///
  /// Called the moment a shot leaves. Not every shot gets one — a flourish
  /// on every single turn stops being a flourish and becomes the firing
  /// animation — and one is never started over an activity already running.
  ///
  /// Returns the voice line to play, or null.
  String? startFireFlourish() {
    if (!alive || ragdoll || pose != null) return null;
    // A flourish may interrupt somebody mid-yawn — having just fired is more
    // interesting than whatever they were doing a moment ago, and refusing
    // here meant the shot went unremarked purely because of an activity the
    // player had already stopped watching. It will not interrupt ANOTHER
    // flourish, which would cut the first one off halfway.
    if (fireFlourishes.contains(idle)) return null;
    if (_idleRng.nextInt(100) >= BattleConst.fireFlourishPercent) return null;
    return _begin(fireFlourishes[_idleRng.nextInt(fireFlourishes.length)]);
  }

  /// Starts [act]: sets its duration, its speech bubble if it has one, and
  /// returns the voice line that goes with it.
  ///
  /// One place rather than three, because the three things an activity needs
  /// have to agree with each other — an activity with a duration but no
  /// entry in the voice table plays silently, which is exactly the sort of
  /// omission nobody notices until a whole deck is doing it.
  String? _begin(CrewIdle act) {
    idle = act;
    idleDur = switch (act) {
      CrewIdle.lookAround => 2.2,
      CrewIdle.yawn => 1.7,
      CrewIdle.whistle => 2.4,
      CrewIdle.chatter => 1.9,
      CrewIdle.browWaggle => 1.5,
      CrewIdle.stretch => 1.9,
      CrewIdle.hop => 1.6,
      CrewIdle.shrug => 1.3,
      CrewIdle.scratchHead => 1.8,
      CrewIdle.jig => 2.1,
      CrewIdle.checkNails => 2.0,
      CrewIdle.swatFly => 1.7,
      CrewIdle.lookOverboard => 2.3,
      CrewIdle.polishWeapon => 2.1,
      CrewIdle.flex => 1.6,
      CrewIdle.adjustHat => 1.3,
      CrewIdle.sneeze => 1.1,
      CrewIdle.shiver => 2.0,
      CrewIdle.pointAtEnemy => 1.5,
      CrewIdle.countAmmo => 1.9,
      CrewIdle.wave => 1.6,
      CrewIdle.kickDeck => 1.8,
      CrewIdle.blowBarrel => 1.2,
      CrewIdle.spinWeapon => 1.0,
      CrewIdle.fistPump => 0.9,
      CrewIdle.salute => 1.0,
      CrewIdle.jeer => 1.4,
      CrewIdle.patWeapon => 1.0,
      CrewIdle.none => 1,
    };
    idleT = idleDur;

    // Only the talkative activities get a line, and only sometimes: a bubble
    // over every one would be constant visual noise on a four-raft deck.
    final talks = act == CrewIdle.chatter ||
        act == CrewIdle.jeer ||
        act == CrewIdle.pointAtEnemy ||
        ((act == CrewIdle.shrug ||
                act == CrewIdle.wave ||
                act == CrewIdle.countAmmo) &&
            _idleRng.nextInt(2) == 0);
    if (talks) say(idleLine, seconds: 1.8);

    final blip = switch (act) {
      CrewIdle.yawn => 'voice_yawn',
      CrewIdle.whistle => 'voice_whistle',
      CrewIdle.chatter => 'voice_chatter',
      CrewIdle.browWaggle => 'voice_hmm',
      CrewIdle.lookAround => 'voice_look',
      CrewIdle.stretch => 'voice_yawn',
      CrewIdle.hop => 'voice_hup',
      CrewIdle.shrug => 'voice_hmm',
      CrewIdle.scratchHead => 'voice_hmm',
      CrewIdle.jig => 'voice_cheer',
      CrewIdle.checkNails => 'voice_hmm',
      CrewIdle.swatFly => 'voice_tsk',
      CrewIdle.lookOverboard => 'voice_look',
      CrewIdle.polishWeapon => 'voice_hum',
      CrewIdle.flex => 'voice_hup',
      CrewIdle.adjustHat => 'voice_hum',
      CrewIdle.sneeze => 'voice_sneeze',
      CrewIdle.shiver => 'voice_brr',
      CrewIdle.pointAtEnemy => 'voice_taunt',
      CrewIdle.countAmmo => 'voice_count',
      CrewIdle.wave => 'voice_cheer',
      CrewIdle.kickDeck => 'voice_tsk',
      CrewIdle.blowBarrel => 'voice_blow',
      CrewIdle.spinWeapon => 'voice_hup',
      CrewIdle.fistPump => 'voice_cheer',
      CrewIdle.salute => 'voice_hup',
      CrewIdle.jeer => 'voice_taunt',
      CrewIdle.patWeapon => 'voice_hum',
      CrewIdle.none => null,
    };
    return blip == null ? null : voiced(blip);
  }

  // --- Speech bubbles -------------------------------------------------------

  /// What this crew member is saying, or null. Deliberately tiny: three or
  /// four words, one at a time, above one head. A battle with four rafts on
  /// screen would be unreadable if these were any bigger or any more
  /// frequent, so [say] refuses to interrupt a line already showing and the
  /// renderer draws them small and low-contrast.
  String? bubble;

  /// Seconds of bubble left.
  double bubbleT = 0;

  bool get talking => bubble != null && bubbleT > 0;

  /// Says [text] for [seconds]. A line already on screen wins — a crew
  /// member who gets hit twice in a row should not flicker between two
  /// yelps, they should finish the first one.
  void say(String text, {double seconds = 1.6}) {
    if (talking) return;
    bubble = text;
    bubbleT = seconds;
  }

  /// One of the idle chatter lines, picked with this crew member's own RNG.
  static const List<String> _idleLines = [
    'Nice weather.',
    'Still floating.',
    'Any snacks?',
    'My feet hurt.',
    'Is it my turn?',
    'Shhh. Aiming.',
    'Hmm.',
    'Look busy!',
  ];

  static const List<String> _hitLines = [
    'Ow!',
    'Rude!',
    'Not the face!',
    'Aaagh!',
    'That stung!',
  ];

  static const List<String> _gloatLines = [
    'Got one!',
    'Ha!',
    'Direct hit!',
    'Too easy.',
    'Bullseye!',
  ];

  String _pick(List<String> pool) => pool[_idleRng.nextInt(pool.length)];

  String get idleLine => _pick(_idleLines);
  String get hitLine => _pick(_hitLines);
  String get gloatLine => _pick(_gloatLines);

  // --- Whole-body expression ------------------------------------------------

  /// How the body is carrying itself right now.
  ///
  /// Ordered by urgency, exactly like the face is: a wince beats a gloat
  /// beats an idle fidget, so the body and the face are never telling two
  /// different stories about the same moment.
  BodyExpression bodyExpression(double time) {
    if (!alive || ragdoll || pose != null) return BodyExpression.none;
    final t = time + bobPhase;

    // 1. A fresh hit doubles them over, whatever else was happening.
    if (hitReactT > 0) {
      final k = (hitReactT / BattleConst.hitReactTime).clamp(0.0, 1.0);
      return BodyExpression(
        crouch: 0.45 * k,
        lean: 0.28 * k,
        slump: 0.6 * k,
        tremble: sin(t * 42) * 1.4 * k,
      );
    }

    // 2. Landing one is worth a whole-body celebration — this is the beat
    //    that used to be a slightly different mouth shape.
    if (gloatT > 0) {
      final k = (gloatT / BattleConst.gloatTime).clamp(0.0, 1.0);
      return BodyExpression(
        armRaise: k,
        bounce: -(sin(t * 11).abs()) * 5.0 * k,
        lean: -0.12 * k,
        crouch: -0.18 * k,
      );
    }

    // 3. Statuses are worn by the body: shivering, sagging under tar,
    //    swaying while dazed. It is a second, always-visible read on a
    //    condition the badge over their head also shows.
    if (afflicted) {
      switch (status!) {
        case StatusEffect.chilled:
          return BodyExpression(
            crouch: 0.3,
            slump: 0.4,
            tremble: sin(t * 34) * 1.6,
          );
        case StatusEffect.tarred:
          return const BodyExpression(crouch: 0.42, slump: 0.75, lean: 0.14);
        case StatusEffect.dazed:
          return BodyExpression(
            lean: sin(t * 2.4) * 0.14,
            headTilt: sin(t * 1.9) * 0.5,
            slump: 0.3,
          );
        case StatusEffect.snared:
          return BodyExpression(
            crouch: 0.55,
            tremble: sin(t * 26) * 2.2,
            slump: 0.5,
          );
      }
    }

    // 4. Running out of health shows in the shoulders.
    final hpFrac = maxHp <= 0 ? 1.0 : (hp / maxHp).clamp(0.0, 1.0);
    if (hpFrac < 0.3) {
      return BodyExpression(
        slump: 0.55,
        crouch: 0.2,
        bounce: sin(t * 2.2) * 0.7,
      );
    }

    // 5. Idle fidgets, eased in and out over the activity so nothing snaps.
    if (idle != CrewIdle.none && idleDur > 0) {
      final k = (idleT / idleDur).clamp(0.0, 1.0);
      // Bell curve: 0 at both ends, 1 in the middle.
      final ease = sin(pi * (1 - k));
      switch (idle) {
        case CrewIdle.stretch:
          return BodyExpression(
            armRaise: ease,
            crouch: -0.3 * ease,
            bounce: -3.0 * ease,
            lean: -0.14 * ease,
          );
        case CrewIdle.yawn:
          return BodyExpression(
            armRaise: 0.7 * ease,
            crouch: -0.16 * ease,
            lean: -0.1 * ease,
          );
        case CrewIdle.hop:
          return BodyExpression(
            bounce: -(sin(t * 8.5).abs()) * 6.0 * ease,
            crouch: 0.16 * ease,
          );
        case CrewIdle.shrug:
          return BodyExpression(
            armRaise: 0.42 * ease,
            slump: -0.5 * ease,
            headTilt: 0.6 * ease,
          );
        case CrewIdle.scratchHead:
          return BodyExpression(
            armRaise: 0.85 * ease,
            headTilt: 0.45 * ease,
            lean: 0.06 * ease,
          );
        case CrewIdle.jig:
          return BodyExpression(
            bounce: -(sin(t * 9.5).abs()) * 4.0 * ease,
            tremble: sin(t * 9.5) * 3.2 * ease,
            lean: sin(t * 4.75) * 0.1 * ease,
          );
        case CrewIdle.whistle:
          return BodyExpression(
            lean: sin(t * 1.8) * 0.07 * ease,
            bounce: sin(t * 3.6) * 1.1 * ease,
          );
        case CrewIdle.chatter:
          return BodyExpression(
            armRaise: 0.2 * ease,
            headTilt: sin(t * 6.5) * 0.3 * ease,
          );
        case CrewIdle.lookAround:
          return BodyExpression(headTilt: sin(t * 2.1) * 0.5 * ease);
        case CrewIdle.browWaggle:
          return BodyExpression(
            bounce: sin(t * 7.0) * 1.2 * ease,
            headTilt: 0.2 * ease,
          );
        case CrewIdle.checkNails:
          return BodyExpression(
            armReach: 0.85 * ease,
            armRaise: 0.62 * ease,
            headTilt: 0.3 * ease,
            lean: -0.05 * ease,
          );
        case CrewIdle.swatFly:
          return BodyExpression(
            armReach: (0.2 + sin(t * 11) * 0.5) * ease,
            armRaise: (0.5 + sin(t * 11) * 0.45) * ease,
            headTilt: sin(t * 7.5) * 0.45 * ease,
            bounce: sin(t * 11) * 1.4 * ease,
          );
        case CrewIdle.lookOverboard:
          return BodyExpression(
            lean: 0.34 * ease,
            crouch: 0.4 * ease,
            headTilt: 0.25 * ease,
          );
        case CrewIdle.polishWeapon:
          return BodyExpression(
            armReach: 0.5 * ease,
            armRaise: 0.4 * ease,
            lean: 0.1 * ease,
            tremble: sin(t * 13) * 1.6 * ease,
          );
        case CrewIdle.flex:
          return BodyExpression(
            armReach: -0.55 * ease,
            armRaise: 0.9 * ease,
            crouch: -0.22 * ease,
            headTilt: -0.3 * ease,
            slump: -0.6 * ease,
          );
        case CrewIdle.adjustHat:
          return BodyExpression(
            armReach: -0.1 * ease,
            armRaise: 0.95 * ease,
            headTilt: -0.2 * ease,
            crouch: 0.06 * ease,
          );
        case CrewIdle.sneeze:
          // A wind-up and a snap: leans back through the first half, then
          // doubles forward hard through the second.
          final snap = sin(pi * (1 - k) * 2) * (k > 0.5 ? 1.0 : -0.55);
          return BodyExpression(
            lean: 0.42 * snap,
            crouch: 0.3 * ease * (k > 0.5 ? 1 : 0),
            armRaise: 0.7 * ease,
            armReach: -0.55 * ease,
            tremble: sin(t * 30) * 1.4 * ease,
          );
        case CrewIdle.shiver:
          return BodyExpression(
            armReach: -0.9 * ease,
            crouch: 0.3 * ease,
            slump: 0.55 * ease,
            armRaise: 0.3 * ease,
            tremble: sin(t * 24) * 2.4 * ease,
          );
        case CrewIdle.pointAtEnemy:
          return BodyExpression(
            armReach: 1.0 * ease,
            armRaise: 0.75 * ease,
            lean: 0.16 * ease,
            headTilt: -0.15 * ease,
          );
        case CrewIdle.countAmmo:
          return BodyExpression(
            armReach: 0.6 * ease,
            crouch: 0.3 * ease,
            lean: 0.2 * ease,
            headTilt: 0.4 * ease,
            armRaise: 0.25 * ease,
          );
        case CrewIdle.wave:
          return BodyExpression(
            armReach: 0.3 * ease,
            armRaise: (0.8 + sin(t * 9) * 0.18) * ease,
            headTilt: sin(t * 4.5) * 0.2 * ease,
            bounce: -sin(t * 9).abs() * 1.2 * ease,
          );
        case CrewIdle.kickDeck:
          return BodyExpression(
            crouch: (0.12 + sin(t * 5) * 0.12) * ease,
            lean: 0.08 * ease,
            headTilt: 0.35 * ease,
          );

        // --- Firing flourishes ---
        case CrewIdle.blowBarrel:
          return BodyExpression(
            armReach: 0.55 * ease,
            armRaise: 0.8 * ease,
            headTilt: -0.18 * ease,
            lean: -0.06 * ease,
          );
        case CrewIdle.spinWeapon:
          return BodyExpression(
            armReach: (0.3 + cos(t * 14) * 0.5) * ease,
            armRaise: (0.5 + sin(t * 14) * 0.4) * ease,
            lean: -0.08 * ease,
            slump: -0.35 * ease,
          );
        case CrewIdle.fistPump:
          return BodyExpression(
            armReach: -0.35 * ease,
            armRaise: (0.75 + sin(t * 10).abs() * 0.25) * ease,
            bounce: -sin(t * 10).abs() * 3.4 * ease,
            crouch: -0.12 * ease,
          );
        case CrewIdle.salute:
          return BodyExpression(
            armReach: -0.25 * ease,
            armRaise: 1.0 * ease,
            headTilt: -0.22 * ease,
            slump: -0.5 * ease,
          );
        case CrewIdle.jeer:
          return BodyExpression(
            armReach: 0.75 * ease,
            armRaise: 0.66 * ease,
            lean: 0.2 * ease,
            bounce: sin(t * 7) * 1.8 * ease,
            headTilt: sin(t * 3.5) * 0.28 * ease,
          );
        case CrewIdle.patWeapon:
          return BodyExpression(
            armReach: 0.4 * ease,
            armRaise: 0.35 * ease,
            bounce: -sin(t * 12).abs() * 1.6 * ease,
            headTilt: 0.18 * ease,
          );
        case CrewIdle.none:
          break;
      }
    }

    return BodyExpression.none;
  }

  /// Picks one of the "Awww" hit variations with this crew member's own
  /// RNG — every pained yelp is a little different.
  String hitVoice() {
    const pool = ['voice_ouch1', 'voice_ouch2', 'voice_ouch3', 'voice_ouch4'];
    return voiced(pool[_idleRng.nextInt(pool.length)]);
  }

  // --- Dynamic health bar ---------------------------------------------------

  /// Seconds left to show this crew member's HP bar; 0 = hidden.
  double hpBarT = 0;

  /// The "ghost" HP fraction the bar drains from after a hit. Reset to the
  /// live fraction whenever the bar fully hides, so it always reflects the
  /// most current HP when it reappears.
  double hpDisplay = 1;

  // --- Walk-back animation --------------------------------------------------

  /// True while the player is steering this crew member around the deck.
  ///
  /// The stepper normally walks anyone who is away from their berth back to
  /// it; that has to stand down while somebody is deliberately walking them
  /// somewhere, or the two fight and the character moonwalks.
  bool steering = false;

  /// Walk-cycle phase while shuffling back to the station.
  double walkPhase = 0;

  /// 0..1 weight of the walk animation; eases in while walking and out
  /// once the station is reached.
  double walkAmp = 0;

  // --- Weapon equipment -----------------------------------------------------

  /// The weapon currently equipped in hand — the firearm model, grip and
  /// firing animation all follow this. While [swapTarget] is set, a swap is
  /// in progress: the old weapon lowers ([swapT] 0 → 0.5), the new one is
  /// equipped at the halfway point, and the new weapon rises (0.5 → 1).
  String? equipped;

  /// The weapon being swapped in; null when no swap is running.
  String? swapTarget;

  /// 0..1 swap progress. The held weapon lowers to the hip through the
  /// first half, the new model is equipped at the midpoint, and it rises
  /// back into the grip through the second half.
  double swapT = 1;

  /// True while a weapon swap animation is running.
  bool get swapping => swapTarget != null;

  /// Guards the swap sound effects so the slide-clack/"hup!" pair fires
  /// exactly once per swap (a re-targeted swap keeps it quiet).
  bool swapSoundStarted = false;

  /// Requests a weapon swap. Re-requesting the equipped weapon is a no-op;
  /// a swap already in flight retargets cleanly. The lower/equip/raise
  /// animation is driven by the world's body stepper on the same fixed-step
  /// clock as the bodies, so both hotspot devices see the same transition.
  void equip(String weaponId) {
    if (swapTarget == weaponId) return;
    if (equipped == weaponId) {
      swapTarget = null;
      swapT = 1;
      swapSoundStarted = false;
      return;
    }
    if (equipped == null) {
      // First equip: the weapon appears in hand already raised.
      equipped = weaponId;
      swapTarget = null;
      swapT = 1;
      swapSoundStarted = false;
      return;
    }
    swapTarget = weaponId;
    swapT = 0;
  }

  /// Sets the equipped weapon with no transition — used for AI shots and
  /// turn-start sync, where the raise animation would fight the fire.
  void equipInstant(String weaponId) {
    equipped = weaponId;
    swapTarget = null;
    swapT = 1;
    swapSoundStarted = false;
  }

  /// How this crew member behaves when knocked down — mass, flail, flip
  /// bias and how fast they get back up. Comes from their character, so no
  /// two kinds of person tumble the same way.
  final RagdollTraits traits;

  /// How the tumble currently in progress goes — rolled fresh on every
  /// knock so the same character never falls the same way twice. See
  /// [RagdollStyle].
  RagdollStyle style = RagdollStyle.plain;

  /// How many times this body has been thrown about. Feeds the style roll,
  /// so successive knocks on the same crew member differ from each other as
  /// well as from everyone else's. Deterministic, so it is safe in lockstep.
  int tumbles = 0;

  /// True once the player has deliberately walked this crew member somewhere.
  ///
  /// Without it, letting go of the walk controls handed the body straight
  /// back to the "walk home to your berth" stepper, which marched them back
  /// to the exact spot they started from — so every walk undid itself the
  /// moment you stopped, and the controls did nothing you could keep. Being
  /// knocked down clears it: a body that has been thrown across the deck
  /// still picks itself up and returns to its post.
  bool parked = false;

  /// Seconds until this crew member can be bowled over by a flying body
  /// again. See [BattleConst.bodySlamCooldown].
  double slamCool = 0;

  /// Advances the leg cycle by the ground actually covered.
  ///
  /// Called with the horizontal distance moved this frame, so the stride
  /// length on screen matches the stride length underfoot. See
  /// [BattleConst.walkStride].
  void advanceWalk(double distance) {
    walkPhase += distance.abs() / BattleConst.walkStride;
  }

  /// Rolls a new [style] for a tumble about to start. [seed] should carry
  /// whatever the caller knows about the blow (see `_tumbleSeed`); it is
  /// mixed with this body's own identity and history so two crew members hit
  /// by the same blast still tumble differently.
  void rollStyle(int seed) {
    tumbles++;
    style = RagdollStyle.roll(
        seed ^ (bobPhase * 10007).round() ^ (tumbles * 0x27D4EB2D));
  }

  /// Which register this crew member speaks in, from their character. Only
  /// the clips that have `_low`/`_high` variants are pitched — see
  /// [AudioService.voiceBases]; anything else falls back to the mid clip via
  /// [voiced].
  final VoiceType voice;

  Crew({
    required this.hp,
    required this.maxHp,
    this.bobPhase = 0,
    this.voice = VoiceType.mid,
    this.traits = RagdollTraits.standard,
  }) {
    idleNextIn = 2.5 + bobPhase % 5;
  }

  /// This crew member's own take on a voice clip.
  ///
  /// A deck used to be a row of people sharing one voice, which is most of
  /// why they read as identical. Every character now carries a [VoiceType]
  /// and this is where it is applied — one place, so nothing can play an
  /// unpitched line by accident.
  String voiced(String base) =>
      voice == VoiceType.mid ? base : '$base${voice.suffix}';

  bool get alive => hp > 0;

  /// Bruise/cut severity from HP loss — drives the injury decals drawn over
  /// the whole body: 0 healthy, 1 scuffed, 2 bruised and cut, 3 battered.
  int get injuryLevel {
    final f = hpFrac;
    if (!alive) return 3;
    if (f >= 0.66) return 0;
    if (f >= 0.34) return 1;
    if (f >= 0.15) return 2;
    return 3;
  }

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
  ///
  /// The knockout comedy lives here: [zone] decides the funny reaction —
  /// [HitZone.head] can whip into a backflip ([spin], [headKick]), a
  /// [HitZone.legs] hit can [plant] one boot so the body pivots around it,
  /// and [lift] adds an upward launch for blasts.
  void knock(
    Offset dir,
    double force, {
    Offset? hitLocal,
    HitZone zone = HitZone.torso,
    double lift = 0,
    double spin = 0,
    double headKick = 0,
    bool plant = false,
    double hitSide = 0,
    int seed = 0,
  }) {
    final d = dir.distance <= 0 ? const Offset(1, 0) : dir / dir.distance;
    // Tar makes a body harder to shift: the same blast that would send a
    // clean crew member over the rail only slides a tarred one. That is the
    // upside half of the effect, and it is why tar is a trade rather than a
    // pure punishment.
    force *= statusKnockScale;
    ragdoll = true;
    ragdollTime = 0;
    rest = 0;
    getUpT = -1;
    parked = false;
    clearPlant();
    // A fresh style for this tumble, before anything is applied — the spin
    // and the twist below both read from it.
    rollStyle(seed);
    pose ??= RagdollPose.standingAt(Offset(offset.dx, offset.dy),
        mass: traits.mass);
    final impulse = Offset(
        d.dx * force, d.dy * force - force * (BattleConst.bodyLift + lift));
    pose!.applyImpulse(hitLocal ?? pose!.hip.pos, impulse,
        spin: spin * style.spinScale);
    if (headKick > 0 && pose != null) {
      // A headshot can "shoot off": the head gets an extra snap backward,
      // pitching the whole body over into a backflip.
      pose!.head.setVel(pose!.head.vel + Offset(0, -headKick));
    }
    _applyTwist(force);
    // Any real spin curls them up and launches them: the tuck lets the
    // rotation survive the speed cap, and the lift buys the hang time to
    // bring it round. Without both, a flip stalls halfway and flops back.
    if (spin.abs() > 0.05) {
      flipT = BattleConst.flipTuckTime;
      flipAirborne = false;
      flipGround = 0;
      pose!.addLift(BattleConst.flipLift);
    }
    vel = pose!.hip.vel;
    if (plant && pose != null) {
      final side = hitSide < 0 ? -1.0 : 1.0;
      plantFoot = side;
      plantT = BattleConst.legPlantTime;
      (side < 0 ? pose!.footL : pose!.footR).pin = 1;
    }
  }

  /// An off-axis kick at the moment of impact: one shoulder and the opposite
  /// hip lead, by an amount and a direction the style rolled.
  ///
  /// This is the single biggest reason two tumbles look different. Without
  /// it every body is thrown by a force applied on the vertical centre line,
  /// so every body rotates cleanly in the screen plane and the whole deck
  /// falls over like a row of identical skittles. A small asymmetry sends
  /// each one into its own wobble.
  void _applyTwist(double force) {
    final p = pose;
    if (p == null || style.twist.abs() < 0.02) return;
    // Scaled by the blow: a graze should not spin anybody off-axis, and the
    // kick is capped so a point-blank anchor cannot tear the body apart
    // against its own constraints.
    //
    // Applied as a plain velocity on the limbs, matching [applyImpulse],
    // which also hands every point the same linear velocity and lets mass
    // tell only through the body's moment of inertia. Scaling this one by
    // mass instead would make the twist disagree with the blow it rides on.
    final k = (force * 0.055).clamp(0.0, 1.6) * style.twist;
    p.handL.setVel(p.handL.vel + Offset(-k, -k * 0.5));
    p.handR.setVel(p.handR.vel + Offset(k, k * 0.5));
    p.footL.setVel(p.footL.vel + Offset(k * 0.6, 0));
    p.footR.setVel(p.footR.vel + Offset(-k * 0.6, 0));
  }

  /// A killing blow. Unlike a hit someone survives, a dead body never stands
  /// back up: it tumbles the way the impact pointed, goes limp, and — nudged
  /// along by the death drift in [_stepBody] — slides off the deck and into
  /// the sea. [railDir] is the way off the nearest rail, used when the
  /// impact itself has little horizontal say in where they fall. [spin]
  /// lets a killing headshot still throw a backflip on the way down.
  void startDeath(
    Offset hitDir,
    double force, {
    double railDir = 1,
    Offset? hitLocal,
    double spin = 0,
    int seed = 0,
  }) {
    final d = hitDir.distance <= 0 ? const Offset(1, 0) : hitDir / hitDir.distance;
    deathDir = d.dx.abs() >= 0.4
        ? (d.dx < 0 ? -1.0 : 1.0)
        : (railDir < 0 ? -1.0 : 1.0);
    deathFlash = BattleConst.deathFlashTime;
    deathSpark = BattleConst.deathSparkTime;
    deathWound = hitLocal ?? const Offset(0, -34);
    ragdoll = true;
    ragdollTime = 0;
    rest = 0;
    getUpT = -1;
    parked = false;
    clearPlant();
    rollStyle(seed ^ 0x5EAD);
    // Spawned with the character's own mass, exactly as [knock] does. It
    // used to default to 1 here, so a heavy character's killing blow landed
    // on a body a fraction of their weight: the same impulse threw them
    // much harder, and the constraint solver had to swallow the difference
    // in a single frame — which is what the compression on death was.
    pose ??= RagdollPose.standingAt(Offset(offset.dx, offset.dy),
        mass: traits.mass);
    final f = max(force, 3.0);
    pose!.applyImpulse(
      hitLocal ?? pose!.hip.pos,
      Offset(d.dx * f, d.dy * f - 2.2),
      spin: spin * style.spinScale,
    );
    _applyTwist(f);
    if (spin.abs() > 0.05) {
      flipT = BattleConst.flipTuckTime;
      flipAirborne = false;
      flipGround = 0;
      pose!.addLift(BattleConst.flipLift);
    }
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

  /// What this side is standing on.
  ///
  /// A raft is the common case and the default; the rest are the enemy
  /// emplacements — an island, a rock ledge, lashed hulls, a cove. It
  /// changes the floors, the width, and whether the thing bobs.
  final Emplacement emplacement;

  EmplacementDef get place => EmplacementDef.of(emplacement);

  /// The deck's platform layout, oriented so the raised stern work sits
  /// behind this raft's crew (see [DeckProfile.forLoadout]).
  late final DeckProfile profile = DeckProfile.forLoadout(
    loadout,
    facing: facing,
    emplacement: emplacement,
  );

  Raft({
    required this.playerIndex,
    required this.x,
    required this.loadout,
    required this.look,
    required this.label,
    required this.facing,
    required this.crew,
    this.emplacement = Emplacement.raft,
  });

  bool get alive => crew.any((c) => c.alive);

  List<Crew> get living => crew.where((c) => c.alive).toList();

  double get hp => crew.fold(0.0, (s, c) => s + max(0.0, c.hp));

  double get maxHp => crew.fold(0.0, (s, c) => s + c.maxHp);

  double get hpFrac => maxHp <= 0 ? 0 : (hp / maxHp).clamp(0.0, 1.0);

  /// The waterline THIS raft floats on.

  /// The structure this player built, if they built one instead of picking a
  /// prefab hull.
  ///
  /// It sits ON the deck: the hull underneath is still a hull, and the
  /// blocks are what stands on it. That keeps every existing path working —
  /// the hull still floats, still bounces shots off its flanks, still holds
  /// the rails — and confines the new behaviour to the surface the crew walk
  /// on and the blocks a shot can knock out.
  BuildPlan? build;
  ///
  /// The sea is terraced (see [WaterProfile]), so a raft on the high side of
  /// a falls genuinely sits above one on the low side — which is the whole
  /// point of the terraces, and it has to reach the hull, the deck, the crew
  /// and the drowning check or the raft would be drawn on one level and
  /// simulated on another.
  ///
  /// Set by [BattleWorld.addRaft] from the world's profile. The default is
  /// the flat base line, so a raft built on its own — in a preview, or in a
  /// test that has no world — behaves exactly as it always did.
  double waterLine = BattleConst.waterY;

  /// Deck surface height — the line the crew's feet rest on. Matches the
  /// renderer's own deck calculation so a body standing at offset zero is
  /// drawn exactly on the planks.
  double get deckY => waterLine - loadout.deckRise;

  /// Half the walkable deck. Past this a crew member is over open water.
  double get deckHalf => loadout.deckHalf * place.widthScale;

  /// Half the solid hull — the walkable deck plus the rail/deck edges. A
  /// projectile whose x sits past this (but whose y is at water level) is
  /// clear of the raft entirely.
  double get hullHalf => loadout.width * 0.5 * place.widthScale;

  /// Bottom edge of the solid hull block, below the waterline.
  double get hullBottom => deckY + loadout.hullHeight;

  /// The walkable surface at hull-local [x], as a y-offset from [deckY]
  /// (0 on the main deck, negative up on a raised platform), or null past
  /// the rails. This is the height-field the body physics and the walk-back
  /// both follow — platforms, ramps and deck are one continuous surface.

  /// True when build column [col] sits fully on this raft's planks.
  ///
  /// The build grid is a fixed width so a plan can be carried between rafts
  /// and the build screen is the same shape every time — which means a wide
  /// plan on a narrow hull would hang its end blocks over the water. Those
  /// columns are simply not built: skipped when drawing, skipped when a shot
  /// tests against them, and contributing nothing to the walkable surface,
  /// so all three agree.
  bool buildColumnOnDeck(int col) =>
      (BuildPlan.columnX(col)).abs() + BuildPlan.cellW / 2 <= deckHalf;
  /// The walkable surface at hull-local [x], or null past the deck edge.
  ///
  /// The higher of the hull's own tiers and whatever the player built on top
  /// of them, so a structure is something to stand on rather than scenery —
  /// and so the surface DROPS when the blocks holding it up are shot away.
  double? surfaceY(double x) {
    if (x.abs() > deckHalf) return null;
    final col = BuildPlan.columnAt(x);
    final built = (col >= 0 && buildColumnOnDeck(col)) ? build?.riseAt(x) ?? 0 : 0.0;
    return -max(profile.riseAt(x), built);
  }

  /// Hull-local x of crew member [i]'s berth, taken from this raft's own
  /// (facing-oriented) deck plan — so the high ground is always aft and the
  /// crew stand on whatever tier the plan posted them to.
  double stationX(int i) {
    final st = profile.stations;
    if (st.isEmpty) return loadout.crewOffset(i);
    return st[i.clamp(0, st.length - 1)].x;
  }

  /// The body offset crew member [i] rests at when they are home and
  /// undisturbed: no horizontal displacement, and standing on whatever
  /// surface their berth sits on. Crew posted to a raised platform rest
  /// *up there*, not at main-deck level.
  Offset restOffset(int i) => Offset(0, surfaceY(stationX(i)) ?? 0);

  /// True when crew member [i] is standing at their berth, rather than
  /// displaced by a hit. Compares against [restOffset] — not `Offset.zero` —
  /// because a berth on a platform has a non-zero resting height.
  bool atStation(int i) => (crew[i].offset - restOffset(i)).distance < 0.4;

  /// World position of crew member [i]'s feet, following their body.
  Offset feetPos(int i) =>
      Offset(x + stationX(i) + crew[i].offset.dx, deckY + crew[i].offset.dy);

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
    final cx = x + stationX(i) + b.center.dx;
    return (Offset(cx, deckY + b.bottom), Offset(cx, deckY + b.top));
  }

  /// Which way leads off the nearest rail from crew member [i]'s current
  /// position: +1 toward the bow-side rail, -1 toward the stern-side one.
  double railDir(int i) =>
      (stationX(i) + crew[i].offset.dx) >= 0 ? 1.0 : -1.0;

  /// The crew member currently taking this raft's shot, or null if none left.
  Crew? get activeCrew {
    if (activeIndex < 0 || activeIndex >= crew.length) return null;
    final c = crew[activeIndex];
    return c.alive ? c : null;
  }

  /// Where this raft's shots originate: the drawn firearm's muzzle tip.
  ///
  /// Mirrors the renderer's levelled aim pose — standing crew, zero recoil,
  /// the grip carried [WeaponView.holdDist] along the aim line and the shot
  /// exiting at [WeaponView.muzzleX] — so the projectile, the aim-assist arc
  /// and the AI's ballistic solve all start at the barrel mouth the player
  /// actually sees, instead of a fixed offset from the body that read as
  /// firing from the hip. [aimAngleDeg] defaults to the nominal 45° lob for
  /// callers that plan before an angle exists; the live aim angle must be
  /// passed at fire and preview time. [weapon] resolves which firearm is in
  /// hand exactly like the renderer does ([WeaponView.forCrew]).
  Offset muzzle({double aimAngleDeg = 45, WeaponDef? weapon}) {
    final i = activeIndex.clamp(0, max(0, crew.length - 1)).toInt();
    // An explicitly named weapon WINS over whatever is currently in the
    // crew's hands. Both callers that name one — the fire path and the
    // planner — are asking the same question: where will the ball leave
    // from when this round is fired? Deferring to `equipped` answered a
    // different question (where would it leave from with the last round
    // still up), and since weapons differ in reach the two answers are a
    // weapon-length apart.
    final equippedId = weapon?.id ?? crew[i].equipped;
    final wv = WeaponView.forCrew(equippedId, weapon,
        variant: WeaponView.variantForPhase(crew[i].bobPhase, equippedId ?? 'tennis'));
    final gunSide = facing >= 0 ? 1.0 : -1.0;
    // Standing rig layout — same constants as the renderer's crew: feet on
    // the deck, 15-unit legs, 27-unit torso, gun shoulder 9.5 in from the
    // centre and 5 below the shoulder line.
    final shoulderY = deckY + crew[i].offset.dy - 15.0 - 27.0;
    final gunShoulder = Offset(
      x + stationX(i) + crew[i].offset.dx + gunSide * 9.5,
      shoulderY + 5,
    );
    final r = aimAngleDeg * pi / 180;
    // Mirrors the renderer's head-clearance blend (see [ArmIK.headClearance])
    // so the drawn grip and the actual shot-spawn point never drift apart.
    final steep = sin(r).clamp(0.0, 1.0);
    final bodyAng = gunSide > 0 ? -r : r - pi;
    // Carried by the barrel line, with the grip hanging below it — the same
    // geometry the renderer uses (see its `barrelAnchor`). Anchoring the grip
    // on the shoulder ray instead would sit the bore a grip-height too high,
    // and the shot would leave from above the drawn muzzle.
    final barrelAnchor = gunShoulder +
        Offset(gunSide * cos(r), -sin(r)) * wv.holdDist +
        Offset(gunSide * steep * ArmIK.headClearance, 0);
    final grip = barrelAnchor +
        Offset(-gunSide * sin(bodyAng), gunSide * cos(bodyAng)) * wv.gripY;
    final c = cos(bodyAng), s = sin(bodyAng);
    // Weapon-local muzzle tip -> body space: grip-centred frame, y mirrored
    // for left-facing rafts. Must stay in lockstep with the renderer's
    // toBody() — including the per-crew variant pick — so the ball can
    // never leave from beside the barrel.
    final p = Offset(wv.muzzleX - wv.gripX, -wv.gripY * gunSide);
    return grip + Offset(p.dx * c - p.dy * s, p.dx * s + p.dy * c);
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

/// A step in the waterline, and whatever joins the two levels.
///
/// The water to the right of [x] sits [rise] units higher than the water to
/// its left — negative when it steps down instead. [width] is how far the
/// surface takes to make the change, which is the transition itself.
class WaterStep {
  final double x;
  final double rise;
  final double width;
  final WaterStepKind kind;

  const WaterStep({
    required this.x,
    required this.rise,
    required this.width,
    this.kind = WaterStepKind.falls,
  });

  double get left => x - width / 2;
  double get right => x + width / 2;
}

/// The shape of the water across the whole world.
///
/// Every battle used to be fought on one flat waterline, so both rafts sat
/// at exactly the same height and the only thing that varied between
/// matches was distance. With terraces, one side can be a good drop above
/// the other — which changes every shot in the match, because a lob onto a
/// higher terrace has to clear more and one onto a lower terrace falls
/// further.
///
/// Levels are expressed as a RISE above [BattleConst.waterY] rather than as
/// absolute heights, and never go below it: the world is only 422 units tall
/// and the hulls already hang some way under the surface, so the base level
/// is the floor of the design and terraces are built upward into the sky,
/// where there is room.
class WaterProfile {
  /// Steps in ascending x. A profile with none is one flat sea, which is
  /// still a perfectly good match and comes up deliberately often.
  final List<WaterStep> steps;

  /// Rise of the LOWEST terrace above [BattleConst.waterY].
  ///
  /// Steps are relative to each other, so a run of downward ones would put a
  /// terrace below the base line — and the base is the floor of the design:
  /// the hulls already hang some way under it and the world is only 422
  /// units tall. Lifting the whole profile by this instead keeps every
  /// terrace at or above the base and builds the variety upward, into the
  /// sky, where there is room for it.
  final double base;

  const WaterProfile(this.steps, {this.base = 0});

  static const flat = WaterProfile([]);

  /// How far above [BattleConst.waterY] the surface sits at [x].
  ///
  /// Smoothed across each falls rather than stepped, so a body or a shot
  /// crossing one is never teleported: everything that touches the water
  /// reads this, and a discontinuity here would be a discontinuity in the
  /// physics.
  double riseAt(double x) {
    var rise = base;
    for (final s in steps) {
      if (x >= s.right) {
        rise += s.rise;
      } else if (x > s.left) {
        final u = (x - s.left) / s.width;
        // Smoothstep: flat where it meets each terrace, steepest mid-falls.
        rise += s.rise * (u * u * (3 - 2 * u));
      }
    }
    return rise;
  }

  /// The highest any terrace stands above the base line. Used by the
  /// renderer to size the water gradient so one paint covers every level.
  double get maxRise {
    var hi = base;
    var running = base;
    for (final s in steps) {
      running += s.rise;
      if (running > hi) hi = running;
    }
    return hi;
  }

  /// True if [x] lies inside any falls — where the surface is sloping and
  /// nothing should be placed.
  bool onFalls(double x, {double margin = 0}) {
    for (final s in steps) {
      if (x > s.left - margin && x < s.right + margin) return true;
    }
    return false;
  }
}
/// Deliberately an axis-aligned box rather than a polygon: the shape a
/// player has to read at a glance while judging an arc should be the shape
/// the physics actually uses, and a box is the one shape where those two can
/// never quietly diverge. The artwork fills its box; the box is the truth.
class Obstacle {
  final ObstacleKind kind;

  /// Centre, in world coordinates. Not final — floating kinds bob.
  Offset pos;

  final double halfW;
  final double halfH;

  /// Hits it takes before it breaks apart, or 0 for the immovable kinds.
  /// Being able to shoot a hole through the middle of the map is what stops
  /// a badly placed obstacle from souring a whole match: you can always
  /// spend a turn opening the line instead of aiming around it.
  final int maxHits;
  int hits = 0;

  /// Seconds left of this obstacle's reaction to being struck.
  ///
  /// Drives a small shudder, not a white flash. The flash was a bright
  /// full-box overlay on a two-frame timer, which on a shot that bounces —
  /// and so hits things repeatedly — reads as flicker rather than impact.
  /// A solid object that is hit should move a little, not light up.
  double struckT = 0;

  /// Phase offset so a row of floating obstacles does not bob in lockstep.
  final double bobPhase;

  /// Resting y, so bobbing is measured from where it was placed.
  final double baseY;

  Obstacle({
    required this.kind,
    required this.pos,
    required this.halfW,
    required this.halfH,
    required this.maxHits,
    required this.bobPhase,
  }) : baseY = pos.dy;

  bool get destructible => maxHits > 0;
  bool get broken => destructible && hits >= maxHits;

  /// How battered it looks, 0..1.
  double get wear => maxHits == 0 ? 0 : (hits / maxHits).clamp(0.0, 1.0);

  Rect get rect =>
      Rect.fromCenter(center: pos, width: halfW * 2, height: halfH * 2);
}

/// A projectile in flight.
class Shot {
  Offset pos;
  Offset vel;
  final WeaponDef weapon;
  final int owner;
  final List<Offset> trail = [];

  /// How many times this shot has ricocheted off a raft deck. Caps the
  /// ping-pong so a shot can never bounce forever.
  int bounces = 0;

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
  final String kind; // boom | splash | ripple | shock | fire | spark
  final Color color;
  final double size;
  double t = 0;
  final double life;

  Fx({required this.pos, required this.kind, required this.color, this.size = 60, this.life = 0.55});

  bool get done => t >= life;
  double get progress => (t / life).clamp(0.0, 1.0);

  /// Cached unit-radius gradient paint for the gradient-heavy kinds ('boom',
  /// 'fire'). The radial gradient is rotation-invariant and its colours only
  /// depend on the fx's own lifetime, so the shader is built once per
  /// progress bucket and drawn through a scaled canvas transform — instead
  /// of rebuilding the shader object every frame for every explosion on
  /// screen (the old per-frame allocation was the visible hitch when
  /// explosive volleys landed).
  /// The gradient paints, parameterised by how far into the fx's life we are
  /// — rebuilt only when the progress bucket changes, not every frame.
  Paint? _paint;
  double _paintBucket = -1;
  Paint paintFor(double radius) {
    _paint ??= Paint();
    final bucket = (progress * 20).floorToDouble();
    if (bucket != _paintBucket) {
      _paintBucket = bucket;
      final p = 1 - bucket / 20;
      final colors = <Color>[];
      final stops = <double>[];
      switch (kind) {
        case 'boom':
          colors.addAll([
            const Color(0xFFFFFFFF).withOpacity(p),
            const Color(0xFFFFB347).withOpacity(p * 0.85),
            const Color(0x00FF7A3C),
          ]);
          stops.addAll(const [0.0, 0.55, 1.0]);
          break;
        case 'fire':
          colors.addAll([
            const Color(0xFFFFFFFF).withOpacity(p * 0.95),
            const Color(0xFFFFB347).withOpacity(p * 0.9),
            const Color(0xFFE2541E).withOpacity(p * 0.55),
            const Color(0xFFE2541E).withOpacity(0),
          ]);
          stops.addAll(const [0.0, 0.4, 0.75, 1.0]);
          break;
        default:
          colors.addAll([color.withOpacity(p), color.withOpacity(0)]);
          stops.addAll(const [0.0, 1.0]);
      }
      _paint!.shader = Gradient.radial(
        Offset.zero,
        1,
        colors,
        stops,
        TileMode.clamp,
      );
    }
    return _paint!;
  }

  static Color accentLike(Fx fx) => fx.color;
}

/// The result of resolving one shot, so the controller can drive turn flow
/// and messaging without re-deriving what happened.
class ShotOutcome {
  final bool hitSomething;
  final bool hitPlayerSide;
  final double damage;
  final Offset impact;

  /// True when this was an explosive round (splash > 0) — the controller
  /// layers the deep-boom sound on top of the regular hit/splash.
  final bool splash;

  const ShotOutcome({
    required this.hitSomething,
    required this.hitPlayerSide,
    required this.damage,
    required this.impact,
    required this.splash,
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

  /// One reusable standing pose, lent to every body that is getting up. See
  /// [RagdollPose.setStandingAt].
  final RagdollPose _standScratch = RagdollPose.standingAt(Offset.zero);

  /// Horizontal camera offset — the left edge of the visible window.
  double cam = 0;

  /// Width of the visible window in world units. Set by the renderer/screen
  /// from the device aspect ratio so the 422 world height always fits.
  double viewWidth = 870;

  /// Whose raft the camera is locked to. Shots are lobbed blind, so the view
  /// belongs to whoever is firing — never to their target.
  int camAnchor = 0;

  /// The seat currently lining up a shot, or -1 when nobody is.
  ///
  /// Activities are suppressed for the crew member actually taking aim,
  /// because a body twisting about mid-aim looks broken. That used to be
  /// decided by "are you your raft's active crew member?" alone — which
  /// covers the shooter, but also silences the PLAYER's chosen crew member
  /// for the whole match, including the long stretches while the other side
  /// is taking its turn. They are the one character the player looks at
  /// most, and they were the only one on the deck who never did anything.
  ///
  /// Set by the controller at the start of each turn and cleared the moment
  /// the shot is away.
  int aimingPlayer = -1;

  /// Team check: the human side is seat 0; every other seat belongs to the
  /// enemy team. AI shots can therefore never wound their own side — the
  /// enemies kept bombing each other across the gap, which read as a bug
  /// rather than chaos. (The player is a team of one and never hits
  /// themselves: splash already skips the shooter's own raft.)
  static bool sameSide(int a, int b) => a == b || (a != 0 && b != 0);

  /// Called whenever a crew member makes a sound with their face — a grunt
  /// on fire, an "ow" on being hit, a laugh on landing one, and the idle
  /// fidget blips (yawn, whistle, chatter, "hmm"). The controller wires
  /// this to the audio service; the simulation itself never touches audio.
  void Function(String sound)? onVoice;

  /// Non-voice world sounds — deck ricochets, weapon swaps. Same pipe as
  /// [onVoice], separate hook so the controller can balance them apart.
  void Function(String sound)? onSfx;

  /// A boss round landed a status on someone. The screen uses it to pop the
  /// "CHILLED!" banner and the victim's speech bubble.
  void Function(Crew victim, StatusEffect effect)? onStatus;

  /// Test/preview hook: forces the zone reaction of the next direct hit —
  /// 'flip' (headshot backflip), 'plant' (leg plant) or 'grab' (torso
  /// clutch) — instead of the deterministic dice roll. Null plays normally.
  String? debugHitReaction;

  /// Screen-shake energy in world units: decays each frame in [update] and
  /// offsets the whole scene in the renderer while above zero. Set by
  /// impacts and explosions.
  double shake = 0;

  void bumpShake(double amount) => shake = min(shake + amount, 26.0);

  BattleWorld({required this.map, required int seed}) : rng = GameRng(seed) {
    // Water first: obstacles sit ON the water, so they need to know where
    // its surface is before they can be placed.
    _buildWater(seed);
    _buildObstacles(seed);
  }


  /// The shape of the water for this match, built once from the seed.
  WaterProfile water = WaterProfile.flat;

  /// Absolute y of the water surface at [x].
  double waterAt(double x) => BattleConst.waterY - water.riseAt(x);

  /// Lays out this match's terraces.
  ///
  /// The falls go in the gaps BETWEEN the fixed raft slots, never under one:
  /// a raft is a flat rigid thing and half of it hanging over a waterfall
  /// would be nonsense. Those slots are compile-time constants, which is
  /// what makes this safe to do here, before any raft has been added.
  ///
  /// Roughly a third of matches come out flat on purpose. A feature that
  /// fires every single time stops being variety and becomes the new normal,
  /// and "both rafts level" is a perfectly good match — it is what every
  /// match used to be.
  void _buildWater(int seed) {
    final r = GameRng(seed * 131 + 17);

    // Level, and no falls at all.
    if (r.nextInt(3) == 0) {
      water = WaterProfile.flat;
      return;
    }

    final steps = <WaterStep>[];

    // The main channel, between the player's slot and the nearest enemy.
    // This is the one that matters: it is the drop the player actually
    // shoots across every turn.
    final mainX = r.range(
      BattleConst.playerX + BattleConst.raftClearance + 240,
      BattleConst.enemySlots.first - BattleConst.raftClearance - 140,
    );
    // Which side ends up high is a coin toss, so a player cannot learn one
    // habit and keep it. Levels are rises above the base, so "player high"
    // is a positive step DOWN as you move right, and vice versa.
    final drop = r.range(BattleConst.waterStepMin, BattleConst.waterStepMax);
    // Which kind of transition joins the two levels, themed to the scene:
    // an ice shelf belongs in the frozen swell and a built weir belongs in a
    // harbour, and neither belongs in the other. Each kind also sets its own
    // width — see [stepWidthScale] — so a weir is an abrupt sill and a shoal
    // is a long ramp.
    final kind = map.waterSteps[r.nextInt(map.waterSteps.length)];
    final baseWidth =
        r.range(BattleConst.fallsWidthMin, BattleConst.fallsWidthMax);
    steps.add(WaterStep(
      x: mainX,
      rise: r.nextBool() ? -drop : drop,
      width: baseWidth * stepWidthScale(kind),
      kind: kind,
    ));

    // Sometimes a second, smaller step out among the enemy slots, so a map
    // with several enemy rafts is not just two flat halves.
    //
    // The enemy slots are only four hundred apart and the widest hull needs
    // [raftClearance] either side, so what is left is a narrow window — the
    // falls is centred in it and narrowed to fit rather than placed at
    // random, and skipped entirely if it will not fit at all. Getting this
    // wrong puts a waterfall under a raft, which is the one placement that
    // cannot be allowed: a raft is flat and rigid.
    if (r.nextInt(3) == 0) {
      final gapStart = BattleConst.enemySlots[0] + BattleConst.raftClearance;
      final gapEnd = BattleConst.enemySlots[1] - BattleConst.raftClearance;
      final free = gapEnd - gapStart;
      if (free >= BattleConst.fallsWidthMin) {
        // Narrow gap out here, so only the abrupt kinds fit.
        const tight = [
          WaterStepKind.weir,
          WaterStepKind.ledge,
          WaterStepKind.falls,
          WaterStepKind.iceShelf,
        ];
        final kinds = map.waterSteps.where(tight.contains).toList();
        final kind = kinds.isEmpty
            ? WaterStepKind.ledge
            : kinds[r.nextInt(kinds.length)];
        steps.add(WaterStep(
          x: (gapStart + gapEnd) / 2,
          rise: (r.nextBool() ? -1 : 1) *
              r.range(BattleConst.waterStepMin * 0.5,
                  BattleConst.waterStepMax * 0.7),
          width: min(free, BattleConst.fallsWidthMax * stepWidthScale(kind)),
          kind: kind,
        ));
      }
    }

    steps.sort((a, b) => a.x.compareTo(b.x));

    // Shift the whole profile so its lowest terrace sits exactly on the base
    // waterline. Without this a run of negative steps would push a terrace
    // BELOW the base, and the base is the floor of the design — the hulls
    // already hang some way under it and the world is only so tall.
    var lowest = 0.0;
    var running = 0.0;
    for (final s in steps) {
      running += s.rise;
      if (running < lowest) lowest = running;
    }
    water = WaterProfile(steps, base: -lowest);
  }
  /// Solid things floating in the channel between the rafts. Built once,
  /// from the match seed, so both devices in a hotspot match get the
  /// identical field without exchanging a byte about it.
  final List<Obstacle> obstacles = [];

  /// Lays out this match's obstacles.
  ///
  /// Placed in evenly divided slots across [BattleConst.obstacleBandStart] to
  /// [BattleConst.obstacleBandEnd] with jitter inside each slot, rather than
  /// at free random x: random placement clusters, and a cluster in the middle
  /// of a short channel can leave no line at all. Slots guarantee the gaps
  /// exist; the jitter stops the field looking laid out with a ruler.
  ///
  /// Drawn from its own [GameRng] rather than the world's shared one so that
  /// adding or removing an obstacle never shifts every other random decision
  /// in the match.
  void _buildObstacles(int seed) {
    final kinds = map.obstacles;
    if (kinds.isEmpty) return;
    final r = GameRng(seed * 31 + 7);
    final count = 2 + r.nextInt(3);
    final span = BattleConst.obstacleBandEnd - BattleConst.obstacleBandStart;
    final slot = span / count;
    // At most one mast per field: it is the only kind that has to be cleared
    // rather than worked around, and two of them in a short channel stops
    // being a puzzle and starts being a wall.
    var mastUsed = false;
    // Coverage budget. Some scenes are themed on a single wide kind — the
    // frozen swell is nothing but icebergs — and four wide obstacles in a
    // short channel walled it off almost entirely. Rather than special-case
    // those maps, the field spends a budget: once the solid width would pass
    // this share of the channel, the remaining slots take the narrowest kind
    // available, and if even that will not fit they stay open water.
    final budget = span * 0.45;
    var solid = 0.0;
    for (int i = 0; i < count; i++) {
      var kind = kinds[r.nextInt(kinds.length)];
      if (kind == ObstacleKind.mast && mastUsed) {
        kind = ObstacleKind.rock;
      }
      if (solid + BattleConst.obstacleSizes[kind.name]!.$1 * 2 > budget) {
        kind = ObstacleKind.buoy;
        if (solid + BattleConst.obstacleSizes[kind.name]!.$1 * 2 > budget) {
          continue;
        }
      }
      if (kind == ObstacleKind.mast) mastUsed = true;

      final size = BattleConst.obstacleSizes[kind.name]!;
      final halfW = size.$1;
      final centre = BattleConst.obstacleBandStart + slot * (i + 0.5);
      // Kept a half-width inside its own slot so neighbours never touch.
      final room = max(0.0, slot / 2 - halfW - 8);
      var x = centre + r.range(-room, room);

      /// True if an obstacle of this width centred at [cx] would sit on flat
      /// water, inside the band, and clear of everything already placed.
      bool spotIsClear(double cx) {
        if (water.onFalls(cx, margin: halfW + 6)) return false;
        if (cx - halfW < BattleConst.obstacleBandStart) return false;
        if (cx + halfW > BattleConst.obstacleBandEnd) return false;
        for (final placed in obstacles) {
          if ((cx - placed.pos.dx).abs() < halfW + placed.halfW + 8) {
            return false;
          }
        }
        return true;
      }

      // Keep it off the falls.
      //
      // An obstacle sits ON the water at its own centre, which is fine on a
      // flat terrace and wrong on a slope: across the width of a wreck the
      // surface can drop sixty units, so one end hangs clear in the air and
      // the other is buried. The obstacle band and the main falls overlap by
      // most of their length, so roughly one obstacle in eight landed on the
      // slope before this.
      //
      // Rather than reject the roll, the channel is searched outward from the
      // chosen point for the nearest spot that is flat AND still clear of the
      // obstacles already placed — the search is allowed to leave its own
      // slot, so it has to re-check spacing itself rather than relying on the
      // slot to guarantee it. Only if nothing within reach works does it give
      // up and leave the slot empty, which is the right answer: there is
      // nowhere flat to put anything.
      if (!spotIsClear(x)) {
        var placed = false;
        for (double step = 6; step <= slot * 1.5; step += 6) {
          for (final candidate in [x - step, x + step]) {
            if (!spotIsClear(candidate)) continue;
            x = candidate;
            placed = true;
            break;
          }
          if (placed) break;
        }
        if (!placed) continue;
      }

      // Height: the base for the kind, scaled by a roll and again by how
      // close to mid-channel this one stands.
      //
      // The rolled part stops the field being the same set of silhouettes
      // every match — otherwise the arc that cleared one crate clears every
      // crate forever, which is the "learn it once" problem the obstacles
      // exist to break, only moved up a level.
      //
      // The mid-channel part is where the height does any work. Near either
      // raft a shot is low anyway and a small lump already blocks it; in the
      // middle the shot is at the top of its arc, so only real height
      // changes how anybody has to aim.
      final mid = (BattleConst.obstacleBandStart + BattleConst.obstacleBandEnd) / 2;
      final halfSpan = span / 2;
      final centreness =
          halfSpan <= 0 ? 1.0 : (1 - (x - mid).abs() / halfSpan).clamp(0.0, 1.0);
      // The two multipliers compound, so they are clamped together rather
      // than separately: at full stretch a roll and a mid-channel bonus
      // would otherwise take a kind to two and a half times its own base,
      // which turns a slender buoy into a needle and stops it reading as
      // the thing it is meant to be.
      final stretch =
          (r.range(BattleConst.obstacleHeightMin, BattleConst.obstacleHeightMax) *
                  (1 + centreness * BattleConst.obstacleCentreBoost))
              .clamp(BattleConst.obstacleHeightMin, BattleConst.obstacleStretchMax);
      // Capped against the sky ACTUALLY above this spot, not a fixed number.
      // The sea is terraced now, so an obstacle on a raised terrace has
      // markedly less room above it than one on the base line, and a flat
      // cap let the tall kinds run off the top of the world there.
      final headroom = waterAt(x) - BattleConst.obstacleSkyMargin;
      // Also capped by what this kind can be stretched to and still read as
      // itself — see [BattleConst.obstacleMaxAspect].
      final aspectCap =
          halfW * 2 * (BattleConst.obstacleMaxAspect[kind.name] ?? 3.0);
      final height = min(min(headroom, aspectCap), size.$2 * stretch);
      final halfH = height / 2;

      obstacles.add(Obstacle(
        kind: kind,
        // Sits ON the water: the box's bottom edge is a touch below the
        // waterline so nothing appears to hover.
        // On the water at ITS x, which on a terraced sea is not the base
        // line: an obstacle just past a falls floats on the lower level.
        pos: Offset(x, waterAt(x) - halfH + 5),
        halfW: halfW,
        halfH: halfH,
        maxHits: size.$3,
        bobPhase: r.range(0, 6.28),
      ));
      solid += halfW * 2;
    }
  }

  /// Earliest fraction of the segment [from]→[to] that lies inside [rect],
  /// along with which face it entered through — or null if it never does.
  ///
  /// Swept rather than a point-in-box check on the shot's new position,
  /// because a fast round moves further in one frame than a buoy is wide and
  /// would otherwise tunnel straight through it — the same bug the rail lip
  /// had.
  ///
  /// The face matters because a shot now bounces off an obstacle rather than
  /// bursting on it, and a bounce needs to know which way is "away": the
  /// slab test already computes which axis was the last to admit the
  /// segment, and that axis IS the face it came in through, so reporting it
  /// costs nothing and guessing it from the impact point would be wrong at
  /// the corners.
  static ({double t, bool vertical})? segmentRectHit(
      Offset from, Offset to, Rect rect) {
    var t0 = 0.0;
    var t1 = 1.0;
    // Which axis last raised t0 — 0 for the left/right faces, 1 for top and
    // bottom. Starts at the x face so a segment that begins already inside
    // the box is pushed out sideways rather than nowhere.
    var axisIn = 0;
    final d = to - from;
    for (int axis = 0; axis < 2; axis++) {
      final p = axis == 0 ? d.dx : d.dy;
      final o = axis == 0 ? from.dx : from.dy;
      final lo = axis == 0 ? rect.left : rect.top;
      final hi = axis == 0 ? rect.right : rect.bottom;
      if (p.abs() < 1e-9) {
        if (o < lo || o > hi) return null;
      } else {
        var ta = (lo - o) / p;
        var tb = (hi - o) / p;
        if (ta > tb) {
          final swap = ta;
          ta = tb;
          tb = swap;
        }
        if (ta > t0) {
          t0 = ta;
          axisIn = axis;
        }
        if (tb < t1) t1 = tb;
        if (t0 > t1) return null;
      }
    }
    return (t: t0, vertical: axisIn == 0);
  }

  /// Backwards-compatible entry point: just the fraction.
  static double? segmentRectT(Offset from, Offset to, Rect rect) =>
      segmentRectHit(from, to, rect)?.t;

  /// Bobbing and the decay of the struck-shudder timer.
  void _stepObstacles(double dt) {
    for (final o in obstacles) {
      if (o.struckT > 0) o.struckT = max(0, o.struckT - dt);
      if (o.broken) continue;
      // Only the floating kinds ride the swell; a rock is a rock.
      if (o.kind == ObstacleKind.buoy || o.kind == ObstacleKind.crate) {
        o.pos = Offset(
          o.pos.dx,
          o.baseY + sin(elapsed * 1.6 + o.bobPhase) * 2.4 * map.chop,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------

  void addRaft(Raft raft) {
    // Which terrace this raft floats on. Taken at its centre, and the
    // generator keeps every falls clear of the raft slots, so a raft is
    // never half on one level and half on another.
    raft.waterLine = waterAt(raft.x);
    // Seat the crew at their berths straight away. A berth on a raised tier
    // rests above the main deck, so a crew member who starts at a bare zero
    // offset would spend the first moments of the battle standing in mid-air
    // and then walking down to a deck they were never posted to.
    for (int i = 0; i < raft.crew.length; i++) {
      raft.crew[i].offset = raft.restOffset(i);
    }
    rafts.add(raft);
  }

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
      // Against the water under the shot, not a flat line: on a terraced
      // sea the surface the round comes down on depends on where it is.
      if (p.dy > waterAt(p.dx)) break;
    }
    return p.dx;
  }

  /// Dotted arc preview.
  ///
  /// Capped hard: first at [BattleConst.trajectoryReveal] of the flight,
  /// then at [BattleConst.trajectoryMaxFrames] of simulation absolute — so
  /// cranking the power stretches the *real* shot, not the hint. What the
  /// player sees is a short fan of dots near the muzzle, enough to read the
  /// shape of the lob, like the Friv original, and no more.
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
      if (probe.dy > waterAt(probe.dx) + 8) break;
    }
    final budget = max(
      6.0,
      min(
        flight * BattleConst.trajectoryReveal,
        BattleConst.trajectoryMaxFrames,
      ),
    ).round();

    for (int i = 0; i < flight; i++) {
      p += v;
      v = Offset(v.dx, v.dy + BattleConst.gravity);
      if (p.dy > waterAt(p.dx) + 8) break;
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
    // The effortful grunt that rides the recoil.
    // The grunt belongs to whoever pulled the trigger, in their own voice.
    final shooter = rafts.where((r) => r.playerIndex == owner).firstOrNull?.activeCrew;
    onVoice?.call(shooter?.voiced('voice_grunt') ?? 'voice_grunt');
    // …and, some of the time, a flourish once the round is away. The
    // shooter is the crew member the player is actually watching and was the
    // only one who never did anything, because activities are suppressed for
    // whoever is lining up (a body twisting about mid-aim looks broken).
    // This is the beat where their hands are free again.
    if (shooter != null) {
      final flourish = shooter.startFireFlourish();
      if (flourish != null) onVoice?.call(flourish);
    }
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

    // Collision resolution picks the *earliest* hit along this frame's sweep
    // — every candidate (crew capsules, raft decks, hull walls) reports the
    // fraction of the segment it happens at, and only the smallest t acts.
    // The previous version tested crew before hulls, so a capsule behind a
    // raft stole the hit and let the projectile fly through the raft's near
    // wall; and a side-wall crossing at low speed burst through instead of
    // bouncing.
    var bestT = double.infinity;
    ShotOutcome? resolve;
    void Function() act = () {};

    // --- Crew capsules ---
    for (final raft in rafts) {
      if (BattleWorld.sameSide(raft.playerIndex, s.owner) || !raft.alive) continue;
      for (int i = 0; i < raft.crew.length; i++) {
        if (!raft.crew[i].alive) continue;
        final sweep = _sweepCrew(prev, s.pos, raft, i);
        if (!sweep.hit) continue;
        final t = _sweepT(prev, s.pos, sweep.point);
        if (t < bestT) {
          bestT = t;
          final raftHit = raft;
          final idx = i;
          final point = sweep.point;
          act = () => resolve = _resolve(s, raftHit, idx, hitPoint: point);
        }
      }
    }

    // --- Raft hulls ---
    for (final raft in rafts) {
      final localX = s.pos.dx - raft.x;
      final top = raft.deckY;
      final bottom = raft.hullBottom;

      // 0. Built blocks. Tested before the deck, because a structure stands
      //    ON the deck and a round coming down on it must hit the blocks
      //    rather than passing through them to the planks underneath.
      //
      //    Each block is its own box, so a shot knocks out the one it
      //    actually struck — which is what makes dismantling a tower a real
      //    play: take the bottom out and everything it was holding up comes
      //    down with it.
      final plan = raft.build;
      if (plan != null) {
        for (final (col, row, cell) in plan.standing) {
          if (!raft.buildColumnOnDeck(col)) continue;
          final cx = raft.x + BuildPlan.columnX(col);
          final cyTop = raft.deckY - (row + 1) * BuildPlan.cellH;
          final box = Rect.fromLTWH(
            cx - BuildPlan.cellW / 2,
            cyTop,
            BuildPlan.cellW,
            BuildPlan.cellH,
          );
          final sweep = BattleWorld.segmentRectHit(prev, s.pos, box);
          if (sweep == null || sweep.t >= bestT) continue;
          bestT = sweep.t;
          final hit = prev + (s.pos - prev) * sweep.t;
          final struckRaft = raft;
          final struckCol = col;
          final struckRow = row;
          act = () {
            // Damage lands on the block, not on the crew: cover works.
            final before = cell.hp;
            struckRaft.build?.damageAt(
              BuildPlan.columnX(struckCol),
              struckRow * BuildPlan.cellH + BuildPlan.cellH / 2,
              s.weapon.damage,
            );
            cell.flash = BattleConst.obstacleStruckTime;
            onSfx?.call(cell.broken && before > 0 ? 'explosion' : 'hit');
            bumpShake(cell.broken ? 2.4 : 1.2);
            // Resolved as a hit on the structure. An explosive round still
            // throws its splash from where it struck, so a bomb against the
            // wall still reaches whoever is standing behind it.
            resolve = _resolve(s, null, -1, hitPoint: hit);
          };
        }
      }

      // 1. Deck/platform top, within the walkable deck.
      if (localX.abs() <= raft.deckHalf) {
        final surf = top + (raft.surfaceY(localX) ?? 0.0);
        if (prev.dy <= surf && s.pos.dy >= surf && s.vel.dy > 0) {
          final hit = Offset(s.pos.dx, surf);
          final t = _sweepT(prev, s.pos, hit);
          if (t < bestT) {
            if (s.bounces < 2 && _shotBounce(s)) {
              bestT = t;
              final surfHit = surf;
              act = () {
                s.pos = Offset(s.pos.dx, surfHit - 0.5);
                s.vel = Offset(s.vel.dx * 0.72, -s.vel.dy * 0.48);
                s.bounces++;
                _hullBounceFx(Offset(s.pos.dx, surfHit), s);
              };
            } else {
              bestT = t;
              act = () => resolve = _resolve(s, raft, -1, hitPoint: hit);
            }
          }
        }
      }

      // 2. Hull shoulders: the deck edge band between the walkable deck and
      // the hull's outer walls.
      if (localX.abs() > raft.deckHalf && localX.abs() <= raft.hullHalf) {
        if (prev.dy <= top && s.pos.dy >= top && s.vel.dy > 0) {
          final hit = Offset(s.pos.dx, top);
          final t = _sweepT(prev, s.pos, hit);
          if (t < bestT) {
            if (s.bounces < 2 && _shotBounce(s)) {
              bestT = t;
              act = () {
                s.pos = Offset(s.pos.dx, top - 0.5);
                s.vel = Offset(s.vel.dx * 0.62, -s.vel.dy * 0.4);
                s.bounces++;
                _hullBounceFx(Offset(s.pos.dx, top), s);
              };
            } else {
              bestT = t;
              act = () => resolve = _resolve(s, raft, -1, hitPoint: hit);
            }
          }
        }
      }

      // 3. Side walls: a shot entering the hull's vertical faces below the
      // deck ALWAYS bounces off the solid hull — fast shots ricochet back
      // into play, slow shots thud in (bounce momentum spent) and burst on
      // the spot. Nobody's raft lets anything through its flank, from
      // either side.
      for (final side in [-1.0, 1.0]) {
        final plane = raft.x + side * raft.hullHalf;
        final cameFromOut = side < 0 ? prev.dx < plane : prev.dx > plane;
        final crossed = side < 0 ? s.pos.dx >= plane : s.pos.dx <= plane;
        if (!cameFromOut || !crossed) continue;
        final ddx = s.pos.dx - prev.dx;
        if (ddx.abs() < 1e-9) continue;
        final t = (plane - prev.dx) / ddx;
        if (t < 0 || t > 1) continue;
        final y = prev.dy + (s.pos.dy - prev.dy) * t;
        if (y < top || y > bottom + 6) continue;
        final hit = Offset(plane + side * 0.5, y);
        if (t >= bestT) continue;
        if (s.bounces < 2 && s.vel.distance > 5) {
          bestT = t;
          act = () {
            s.pos = hit;
            s.vel = Offset(-s.vel.dx * 0.55, s.vel.dy * 0.8);
            s.bounces++;
            _hullBounceFx(hit, s);
            bumpShake(1.2);
            onSfx?.call('bounce');
          };
        } else {
          bestT = t;
          act = () => resolve = _resolve(s, raft, -1, hitPoint: hit);
        }
      }

    }


    // --- Obstacles in the channel ---
    //
    // Tested in the same earliest-wins sweep as everything else, so a rock
    // in front of a raft takes the hit rather than the raft behind it.
    //
    // A round RICOCHETS off one rather than bursting on it, exactly as it
    // does off a raft's hull — a rock is a rock, and a ball that hits one
    // and vanishes reads as the shot being deleted rather than deflected.
    // The bounce also makes the field interesting to play with instead of
    // only against: a deliberate carom off a crate is a real shot.
    //
    // A round that has already spent its bounces, or one moving too slowly
    // to ricochet, thuds in and bursts on the spot as before.
    for (final o in obstacles) {
      if (o.broken) continue;
      final sweep = BattleWorld.segmentRectHit(prev, s.pos, o.rect);
      if (sweep == null || sweep.t >= bestT) continue;
      bestT = sweep.t;
      final struck = o;
      final hit = prev + (s.pos - prev) * sweep.t;
      final offFace = sweep.vertical;
      act = () {
        struck.struckT = BattleConst.obstacleStruckTime;
        if (struck.destructible) struck.hits++;

        if (!struck.broken && s.bounces < 2 && _shotBounce(s)) {
          // Reflected about the face it came in through, and nudged clear of
          // the box so the next frame does not immediately find it inside
          // again and bounce it back in.
          if (offFace) {
            s.vel = Offset(-s.vel.dx * 0.62, s.vel.dy * 0.85);
            s.pos = Offset(
              hit.dx + (s.vel.dx >= 0 ? 1.5 : -1.5),
              hit.dy,
            );
          } else {
            s.vel = Offset(s.vel.dx * 0.85, -s.vel.dy * 0.55);
            s.pos = Offset(
              hit.dx,
              hit.dy + (s.vel.dy >= 0 ? 1.5 : -1.5),
            );
          }
          s.bounces++;
          _hullBounceFx(hit, s);
          bumpShake(1.2);
          onSfx?.call('bounce');
          return;
        }

        onSfx?.call(struck.broken ? 'explosion' : 'bounce');
        bumpShake(struck.broken ? 3.0 : 1.4);
        // Resolved as a miss that happens to have landed somewhere solid:
        // an explosive round still throws its splash from the point of
        // impact, so a bomb against a crate beside a raft is a real play.
        resolve = _resolve(s, null, -1, hitPoint: hit);
      };
    }
    // Safety net: ended up inside a solid hull below the deck without
    // crossing a face this frame (spawn edge cases) — resolve there, but
    // only when no real candidate claimed the sweep.
    if (bestT.isInfinite) {
      for (final raft in rafts) {
        final localX = s.pos.dx - raft.x;
        if (localX.abs() <= raft.hullHalf &&
            s.pos.dy >= raft.deckY &&
            s.pos.dy <= raft.hullBottom) {
          act = () => resolve = _resolve(s, raft, -1, hitPoint: s.pos);
          break;
        }
      }
    }

    act();

    // Splashdown / off the world: only when nothing along the sweep claimed
    // the frame.
    if (resolve == null) {
      if (s.pos.dy > waterAt(s.pos.dx) + 40 ||
          s.pos.dx < -100 ||
          s.pos.dx > BattleConst.worldW + 100) {
        resolve = _resolve(s, null, -1);
      }
    }
    return resolve;
  }

  /// Sweep fraction [t] ∈ [0,1] at which the frame's segment passes nearest
  /// to [point] — used to order simultaneous collision candidates.
  double _sweepT(Offset from, Offset to, Offset point) {
    final d = to - from;
    final len2 = d.dx * d.dx + d.dy * d.dy;
    if (len2 < 1e-9) return 0;
    return (((point - from).dx * d.dx + (point - from).dy * d.dy) / len2)
        .clamp(0.0, 1.0);
  }

  /// Whether a shot is moving fast enough to ricochet off a raft surface
  /// rather than thud into it and burst.
  bool _shotBounce(Shot s) => s.vel.distance > 5;

  void _hullBounceFx(Offset at, Shot s) {
    effects.add(Fx(
      pos: at,
      kind: 'ripple',
      color: s.weapon.color,
      size: 24,
      life: 0.3,
    ));
    onSfx?.call('bounce');
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
    final impact =
        hitPoint ?? Offset(s.pos.dx, min(s.pos.dy, waterAt(s.pos.dx) + 12));
    double dealt = 0;
    bool hitPlayerSide = false;

    // Whoever fired this shot — captured before anything below can change
    // their raft's activeIndex, so a landed hit grins on the actual shooter.
    Crew? shooterCrew;
    for (final r in rafts) {
      if (r.playerIndex == s.owner) {
        shooterCrew = r.activeCrew;
        break;
      }
    }

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
        hitRaft.x + hitRaft.stationX(crewIndex),
        hitRaft.deckY,
      );
      final zone = _hitZone(hitLocal);
      final boom = s.weapon.splash > 0;
      // A boss round leaves its mark on whoever it landed on directly. Only
      // on a direct hit and only on the living: splash spreading a snare
      // across a whole deck would end the fight on one lucky shot.
      final st = s.weapon.status;
      if (st != null && c.alive) {
        c.afflict(st, s.weapon.statusTurns);
        c.say(st.bubble, seconds: 2.0);
        // Chills get teeth-chatter; everything else gets a sharp gasp.
        onVoice?.call(st == StatusEffect.chilled
            ? 'voice_brr'
            : c.voiced('voice_gasp'));
        onStatus?.call(c, st);
      }
      // Test/preview hook: when set ('flip' | 'plant' | 'grab'), the
      // matching zone reaction always fires instead of being dice-rolled.
      final forced = debugHitReaction;
      if (c.alive) {
        // Zone-driven comedy: headshots can whip into a backflip, leg hits
        // sometimes plant a boot and pivot, torso hits sometimes clutch —
        // each rolled deterministically from the shot so replays agree. A
        // torso clutch replaces the knock-down entirely: they take the hit
        // on their feet, hunched over the wound (until it fades and they
        // carry on — or the next blast sends them flying).
        final grab = zone == HitZone.torso &&
            !boom &&
            (forced == 'grab' || _hitChance(s, 0x55, 0.4));
        if (grab) {
          c.grabT = BattleConst.grabTime;
          c.hitReactT = BattleConst.hitReactTime;
          onVoice?.call(c.hitVoice());
          c.say(c.hitLine);
          onSfx?.call('hit');
          bumpShake(1.2);
        } else {
          // Head hits somersault BACKWARDS, always. The rotation is thrown
          // away from the shot, which is the read that sells it: you see
          // where the blow came from in which way the body goes over.
          //
          // There used to be a 22% chance of a front flip instead, as "a
          // rarer, funnier accident". It is not funnier — it is the same
          // animation mirrored, it reads as the physics getting the
          // direction wrong rather than as a variation, and a fifth of every
          // player's headshots looking like a bug is a bad trade for a joke
          // nobody identified as one. Variety in a tumble comes from
          // [RagdollStyle], which varies how it goes over rather than which
          // way.
          //
          // Per-character flip bias: a wiry runner cartwheels off a hit that
          // merely topples a dockhand.
          final flipChance =
              BattleConst.flipChanceFor(s.weapon.weight) * c.traits.flipBias;
          final flips =
              zone == HitZone.head && (forced == 'flip' || _hitChance(s, 0x11, flipChance));
          final backward = s.vel.dx >= 0 ? 1.0 : -1.0;
          final spin = flips
              ? backward *
                  BattleConst.headshotSpin *
                  (0.8 + s.weapon.weight * 0.35)
              : (zone == HitZone.legs &&
                      (forced == 'plant' || _hitChance(s, 0x66, BattleConst.sweepSpinChance))
                  // Swept legs spin the body out low, the opposite way a
                  // head hit throws it.
                  ? -backward * BattleConst.sweepSpin
                  : 0.0);
          final headKick = flips ? 4.2 + s.weapon.weight * 1.5 : 0.0;
          c.knock(s.vel, Crew.impactForce(s.weapon) * (boom ? 1.35 : 1.0),
              hitLocal: hitLocal,
              lift: boom ? 0.12 : 0,
              spin: spin,
              headKick: headKick,
              zone: zone,
              plant: zone == HitZone.legs &&
                  (forced == 'plant' || _hitChance(s, 0x44, 0.55)),
              hitSide: hitLocal.dx,

              seed: _tumbleSeed(s, crewIndex));
          c.hitReactT = BattleConst.hitReactTime;
          onVoice?.call(c.hitVoice());
          c.say(c.hitLine);
          // Impact audio: a thud for small arms, a proper bang for
          // explosives, and a whoosh riding any backflip launch.
          onSfx?.call(boom ? 'explosion' : 'hit');
          if (spin != 0) onSfx?.call('whoosh');
        }
      } else {
        // A killing headshot still gets to somersault on the way over the
        // rail — the same rotation as a survivable one, thrown away from
        // the shot, and heavier rounds throw it harder.
        final backward = s.vel.dx >= 0 ? 1.0 : -1.0;
        c.startDeath(s.vel, Crew.impactForce(s.weapon) * (boom ? 1.4 : 1.0),
            railDir: hitRaft.railDir(crewIndex),
            hitLocal: hitLocal,
            spin: zone == HitZone.head
                ? backward *
                    BattleConst.headshotSpin *
                    (forced == 'flip' ? 1.0 : 0.75) *
                    (0.8 + s.weapon.weight * 0.35)
                : 0,
                seed: _tumbleSeed(s, crewIndex));
        onSfx?.call(boom ? 'explosion' : 'hit');
        onSfx?.call('eliminate');
      }
    }

    // Explosive blast: everyone on another team inside the damage radius is
    // hurt, and everyone within an even wider "pressure" radius gets thrown
    // flat — blast damage on a near miss that still ragdolls the crew.
    if (s.weapon.splash > 0) {
      final shoveR = s.weapon.splash * 1.25;
      for (final raft in rafts) {
        if (BattleWorld.sameSide(raft.playerIndex, s.owner) || !raft.alive) continue;
        for (int i = 0; i < raft.crew.length; i++) {
          if (identical(raft, hitRaft) && i == crewIndex) continue;
          final c = raft.crew[i];
          if (!c.alive) continue;
          final d = (impact - raft.crewPos(i)).distance;
          final station = Offset(raft.x + raft.stationX(i), raft.deckY);
          final away = raft.crewPos(i) - impact;
          if (d <= s.weapon.splash) {
            final falloff = 1 - (d / s.weapon.splash);
            final before = c.hp;
            c.hp = max(0, c.hp - s.weapon.damage * 0.6 * falloff);
            dealt += before - c.hp;
            c.showHpBar(before / c.maxHp);
            // Blast throws bodies: full shove plus an upward launch, so
            // caught crew fly and tumble instead of just sliding.
            final force = Crew.impactForce(s.weapon) * (1.1 + 0.5 * falloff);
            if (c.alive) {
              c.knock(Offset(away.dx, -1.0), force,
                  hitLocal: raft.crewPos(i) - station,
                  lift: 0.45 * falloff,
                  zone: HitZone.torso,
                  seed: _tumbleSeed(s, i * 7 + raft.playerIndex * 31));
              c.hitReactT = BattleConst.hitReactTime;
              onVoice?.call(c.hitVoice());
              c.say(c.hitLine);
            } else {
              c.startDeath(Offset(away.dx, -1.0), max(3.0, force),
                  railDir: raft.railDir(i),
                  hitLocal: raft.crewPos(i) - station,
                  seed: _tumbleSeed(s, i * 7 + raft.playerIndex * 31));
            }
            if (raft.playerIndex == 0) hitPlayerSide = true;
          } else if (d <= shoveR) {
            // Pressure wave only: no HP damage, but the shock still knocks
            // them flat — the ragdoll sells the near miss.
            final falloff = 1 - (d - s.weapon.splash) / (shoveR - s.weapon.splash);
            c.knock(Offset(away.dx, -0.6), 1.2 + falloff * 3.2,
                hitLocal: raft.crewPos(i) - station,
                lift: 0.3 * falloff,
                zone: HitZone.torso,
                seed: _tumbleSeed(s, i * 13 + raft.playerIndex * 31));
            c.hitReactT = BattleConst.hitReactTime;
          }
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
    // Explosives get the full show: a shockwave ring, a hot fireball, a
    // scatter of embers — and screen shake loud enough to feel.
    if (s.weapon.splash > 0) {
      effects.add(Fx(
        pos: impact,
        kind: 'shock',
        color: s.weapon.color,
        size: s.weapon.splash * 1.6,
        life: 0.5,
      ));
      effects.add(Fx(
        pos: impact,
        kind: 'fire',
        color: s.weapon.color,
        size: s.weapon.splash * 0.75,
        life: 0.32,
      ));
      for (int k = 0; k < 5; k++) {
        final a = pi * 2 * (k / 5) + s.firedAt * 0.6;
        effects.add(Fx(
          pos: impact + Offset(cos(a) * 8, sin(a) * 8),
          kind: 'spark',
          color: const Color(0xFFFFC966),
          size: 10,
          life: 0.4,
        ));
      }
      bumpShake(5 + s.weapon.damage * 0.13);
      onSfx?.call('explosion');
      onSfx?.call('shockwave');
    } else if (dealt > 0) {
      bumpShake(1.5 + s.weapon.damage * 0.045);
    } else {
      // A clean miss into the water: the splash is all the feedback the
      // shooter gets.
      onSfx?.call('splash');
    }

    // A landed hit earns the shooter a satisfied grin — and a chuckle —
    // whether it was a direct hit or splash damage caught someone.
    if (dealt > 0) {
      shooterCrew?.gloatT = BattleConst.gloatTime;
      shooterCrew?.say(shooterCrew.gloatLine);
      if (shooterCrew?.alive == true) {
        onVoice?.call(shooterCrew!.voiced('voice_laugh'));
      }
    }

    shot = null;
    for (final r in rafts) {
      r.ensureActiveAlive();
    }

    return ShotOutcome(
      hitSomething: hitRaft != null,
      hitPlayerSide: hitPlayerSide,
      damage: dealt,
      impact: impact,
      splash: s.weapon.splash > 0,
    );
  }

  /// Band of the body a station-local hit point landed on, by height off
  /// the deck: head above the neck (−46), legs at/below the hip (−14),
  /// torso between.
  HitZone _hitZone(Offset local) {
    if (local.dy < -46) return HitZone.head;
    if (local.dy > -14) return HitZone.legs;
    return HitZone.torso;
  }

  /// Deterministic per-shot dice roll so ragdoll comedy (backflips, kicks,
  /// clutches) replays identically on both hotspot seats and never draws
  /// from the shared world RNG.
  /// A per-blow seed for [Crew.rollStyle], built from exactly the same shot
  /// state as [_hitChance] so it stays lockstep-safe: both devices compute
  /// it from a shot they both already have. [extra] separates crew members
  /// caught by one blast from each other.
  int _tumbleSeed(Shot s, int extra) =>
      (s.firedAt * 104729).round() ^ (s.pos.dx * 61).round() ^ (extra * 2246822519);

  /// A deterministic per-shot coin flip, one independent stream per [salt].
  ///
  /// The salt used to be XORed straight into the hash and the low ten bits
  /// read off the result — which does not separate the streams at all, it
  /// only permutes a few low bits. Every roll on a given shot was therefore
  /// reading the SAME number with a tiny perturbation, so the rolls were
  /// strongly correlated with each other: asking "does this hit flip them?"
  /// and then "is it a front flip?" was really asking the same question
  /// twice. Conditioning on the first made the second far likelier than its
  /// stated probability — a head hit that flipped at all came out a front
  /// flip about 56% of the time against an intended 22%, so the backflip
  /// that is supposed to be the common, readable one was the minority.
  ///
  /// Mixing the salt through a multiply-and-shift avalanche instead gives
  /// each salt its own stream, so 0.22 means 0.22 whatever else was rolled
  /// on the same shot.
  bool _hitChance(Shot s, int salt, double probability) {
    var h = (s.firedAt * 7919).round() ^ (s.pos.dx * 31).round();
    h = (h + salt * 0x9E3779B1) & 0x7FFFFFFF;
    h ^= h >>> 15;
    h = (h * 0x85EBCA6B) & 0x7FFFFFFF;
    h ^= h >>> 13;
    return (h & 0x3FF) / 1024 < probability;
  }

  /// The raw roll behind every zone reaction, exposed so its distribution can
  /// be tested.
  ///
  /// Worth a seam of its own: a biased roll here is invisible from outside —
  /// the body still flips, it just flips the wrong way more often than it
  /// should — and the only symptom is a vague "the backflips look wrong".
  @visibleForTesting
  bool hitChanceForTest(Shot s, int salt, double probability) =>
      _hitChance(s, salt, probability);

  // ---------------------------------------------------------------------------
  // Per-frame update
  // ---------------------------------------------------------------------------

  /// Crew bodies are integrated on their own fixed 60Hz accumulator so a
  /// bounce happens at exactly the same point regardless of the display's
  /// refresh rate — and so both devices in a hotspot match, which never tick
  /// in lockstep, compute the identical result.
  double _bodyAccum = 0;


  /// Fixed-step counter for the body simulation.
  ///
  /// Used wherever a body needs a deterministic "when" — notably the tumble
  /// style rolled for a crew member bowled over by another body. [elapsed]
  /// cannot be used for that: it accumulates whatever `dt` the display
  /// handed us, so two devices in a hotspot match hold different values for
  /// the same moment. The step count does not.
  int bodyFrames = 0;

  /// Bodies hitting bodies.
  ///
  /// A ragdoll thrown hard enough across the deck knocks over whoever it
  /// lands on, hurts them, and sets them tumbling in turn — so a shot into a
  /// tight crew can start a pile-up, and standing your crew shoulder to
  /// shoulder becomes a real risk rather than free safety.
  ///
  /// Run as its own pass after every body has stepped, so the result does
  /// not depend on which crew member happens to be stepped first.
  void _bodySlams() {
    for (final raft in rafts) {
      for (final c in raft.crew) {
        if (c.slamCool > 0) c.slamCool = max(0, c.slamCool - 1 / 60);
      }
    }

    for (final raft in rafts) {
      for (int i = 0; i < raft.crew.length; i++) {
        final flyer = raft.crew[i];
        final pose = flyer.pose;
        // Only a body actually in flight. A corpse counts — being hit by one
        // is funnier than being hit by a live body, and it is the same
        // physics — but one that has drowned or is already climbing back to
        // its feet does not.
        if (pose == null || !flyer.ragdoll || flyer.drowned) continue;
        if (flyer.getUpT >= 0) continue;
        final speed = pose.maxSpeed;
        if (speed < BattleConst.bodySlamSpeed) continue;

        final from = raft.crewPos(i);
        for (final other in rafts) {
          for (int j = 0; j < other.crew.length; j++) {
            if (identical(other, raft) && i == j) continue;
            final victim = other.crew[j];
            if (!victim.alive || victim.drowned || victim.gone) continue;
            if (victim.slamCool > 0) continue;
            final to = other.crewPos(j);
            if ((to - from).distance > BattleConst.bodySlamRadius) continue;

            final over = speed - BattleConst.bodySlamSpeed;
            final damage =
                min(BattleConst.bodySlamMaxDamage, over * BattleConst.bodySlamDamage);
            final before = victim.hp;
            victim.hp = max(0.0, victim.hp - damage);
            victim.showHpBar(before / victim.maxHp);
            victim.slamCool = BattleConst.bodySlamCooldown;
            // The flyer too, so one body cannot scythe through a whole rank
            // in consecutive frames.
            flyer.slamCool = BattleConst.bodySlamCooldown * 0.5;

            // Thrown on along the flyer's own heading, which is what makes a
            // pile-up read as one continuous event rather than a row of
            // unrelated knockdowns.
            final dir = pose.hip.vel;
            final force = (speed * 0.55).clamp(1.5, 7.0);
            final seed = bodyFrames * 7919 ^ (i * 31) ^ (j * 131);
            if (victim.alive) {
              victim.knock(dir, force,
                  hitLocal: const Offset(0, -26), zone: HitZone.torso, seed: seed);
              victim.hitReactT = BattleConst.hitReactTime;
              onVoice?.call(victim.hitVoice());
              victim.say(victim.hitLine);
            } else {
              victim.startDeath(dir, force,
                  railDir: other.railDir(j), seed: seed);
              onSfx?.call('eliminate');
            }
            onSfx?.call('hit');
            bumpShake(1.4);

            // The flyer spends energy on whoever it hit — unless it is still
            // mid-somersault. A backflip is the game's signature piece of
            // comedy and it only just has the hang time to come round; taking
            // half its speed away because it clipped a neighbour on the way
            // up turned every flip on a crowded deck into a flop. A flipping
            // body still hurts and still knocks people down, it just carries
            // its own rotation through.
            if (flyer.flipT <= 0) {
              for (final p in pose.points) {
                p.setVel(p.vel * BattleConst.bodySlamBleed);
              }
            }
          }
        }
      }
    }
  }
  void update(double dt) {
    elapsed += dt;
    for (final fx in effects) {
      fx.t += dt;
    }
    effects.removeWhere((f) => f.done);
    // Safety cap: an explosive volley can stack boom/shock/fire/spark layers
    // fast; past this, drop the oldest so the fx list can never balloon.
    if (effects.length > 60) {
      effects.removeRange(0, effects.length - 60);
    }
    shake = max(0, shake - dt * BattleConst.shakeDecay);
    _stepObstacles(dt);

    _bodyAccum += dt;
    const step = 1 / 60;
    var guard = 0;
    while (_bodyAccum >= step && guard < 4) {
      _bodyAccum -= step;
      guard++;
      bodyFrames++;
      // Before the step, not after: a slam hands out velocity, and the
      // step is what caps it. Running it afterwards let a slam launch a
      // body past the speed cap for a frame.
      _bodySlams();
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
        // Weapon swap: the held firearm lowers to the hip, the new model
        // is equipped at the halfway point, and the new one rises back
        // into the grip. The swap runs on the same fixed-step clock as
        // the bodies so both hotspot devices see the identical transition.
        if (c.swapTarget != null) {
          // Swap feedback: a slide-clack as the old firearm drops, a
          // chirpy "hup!" and the new model locks in with a click at the
          // halfway point.
          if (!c.swapSoundStarted) {
            c.swapSoundStarted = true;
            onSfx?.call('swap');
            onVoice?.call('voice_swap');
          }
          c.swapT += dt / BattleConst.weaponSwapTime;
          if (c.swapT >= 0.5 && c.equipped != c.swapTarget) {
            c.equipped = c.swapTarget;
            onSfx?.call('click');
          }
          if (c.swapT >= 1) {
            c.equipped = c.swapTarget;
            c.swapTarget = null;
            c.swapT = 1;
            c.swapSoundStarted = false;
          }
        }

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
        // Built blocks shudder for a moment after being struck.
        final plan = raft.build;
        if (plan != null) {
          for (final (_, _, cell) in plan.standing) {
            if (cell.flash > 0) cell.flash = max(0, cell.flash - dt);
          }
        }
        if (c.deathSpark > 0) {
          c.deathSpark = max(0, c.deathSpark - dt);
        }

        if (c.hitReactT > 0) c.hitReactT = max(0, c.hitReactT - dt);
        if (c.gloatT > 0) c.gloatT = max(0, c.gloatT - dt);
        if (c.statusFlash > 0) c.statusFlash = max(0, c.statusFlash - dt);
        if (c.bubbleT > 0) {
          c.bubbleT = max(0, c.bubbleT - dt);
          if (c.bubbleT == 0) c.bubble = null;
        }

        // Ragdoll-reaction timers: the leg plant releases after its window,
        // and a torso clutch fades once the body settles.
        if (c.plantT > 0) {
          c.plantT -= dt;
          if (c.plantT <= 0) c.clearPlant();
        }
        if (c.grabT > 0) c.grabT = max(0, c.grabT - dt);

        // Idle fidgets: anyone standing around may pick a little activity —
        // and voice it. Only the crew member actually taking aim right now
        // is kept still; everybody else, including the player's own chosen
        // crew member while the other side is shooting, stays alive.
        final takingAim =
            raft.activeIndex == i && raft.playerIndex == aimingPlayer;
        final voice = c.updateIdle(dt, allowNew: !takingAim);
        if (voice != null) onVoice?.call(voice);

        if (c.ragdoll) {
          _stepBody(raft, i, c);
        } else if (c.alive && c.steering) {
          // Being walked by the player: the controller owns the position,
          // the stepper only keeps the legs moving.
          c.walkAmp = min(1.0, c.walkAmp + dt * 6);
        } else if (c.alive && !c.parked && !raft.atStation(i)) {
          // Recovered: walk back to the berth they were knocked off. The
          // renderer turns walkPhase/walkAmp into a proper leg swing, and
          // the feet follow the deck surface — up or down a platform ramp,
          // across the main deck — rather than gliding through it. Home is
          // the berth's own resting height, which for crew posted to a
          // castle or a barrel step is well above the main deck.
          c.walkAmp = min(1.0, c.walkAmp + dt * 5);
          final dx = c.offset.dx * (1 - BattleConst.bodyRecover);
          c.advanceWalk(dx - c.offset.dx);
          final surface = raft.surfaceY(raft.stationX(i) + dx) ?? 0.0;
          c.offset = Offset(dx, surface);
          if (raft.atStation(i)) c.offset = raft.restOffset(i);
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
    final stationX = raft.stationX(index);

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
            raft.waterLine,
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
      c.clearPlant();
      c.grabT = 0;
      // Uncurl before standing: blending to a standing pose while the solver
      // still holds a tuck fights itself and the body pops.
      c.flipT = 0;
      pose.tuck = 0;
      c.getUpT = min(
          1.0,
          c.getUpT +
              (1 / 60) /
                  (BattleConst.bodyGetUpTime * c.traits.getUpSpeed));
      final feet = raft.surfaceY(stationX + pose.hip.pos.dx) ?? 0.0;
      _standScratch.setStandingAt(Offset(pose.hip.pos.dx, feet));
      pose.blendTo(_standScratch, c.getUpT);
      // Blending POSITIONS between two poses does not preserve bone length:
      // a body lying flat and the same body standing up put each point on
      // opposite sides of an arc, and the straight line between them is
      // shorter than the arc. Halfway through getting up, every bone was
      // therefore drawn at about 70% of its length — the whole character
      // visibly squashed and then sprang back.
      //
      // Re-solving after the blend restores the bones without fighting it:
      // the constraints only fix lengths, so the figure still travels to its
      // feet, it just stays the same size on the way.
      pose.solve();
      // Physics is suspended during the blend, so the points carry no real
      // momentum — but verlet infers velocity from how far a point moved,
      // and the blend moves them a long way each frame. That phantom
      // velocity used to sit there above the speed cap (the branch returns
      // before the cap is applied) waiting to be turned into real motion
      // the moment the body was disturbed mid-stand — which a body being
      // bowled into by another body now makes routine. Zeroing it is both
      // honest and what the blend already pretends is true.
      for (final p in pose.points) {
        p.setVel(Offset.zero);
      }
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

    // Somersault curl: hold the tuck while the flip runs, then let it out so
    // the body sprawls again for the landing. Easing rather than snapping
    // keeps the constraint solver stable — yanking every rest length in one
    // frame injects energy.
    if (c.flipT > 0) c.flipT = max(0, c.flipT - 1 / 60);
    // How deep THIS tumble curls, not a constant: a shallow roll and a tight
    // ball are both somersaults, and rolling the depth per knock is most of
    // what stops two flips looking like the same animation played twice.
    final wantTuck = c.flipT > 0 ? c.style.curl : 0.0;
    pose.tuck += (wantTuck - pose.tuck) * (BattleConst.flipTuckRate / 60);

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
    // A tuck is for the AIR. It exists to shrink the body's moment of inertia
    // so a somersault can come round inside its hang time — once the body is
    // back on the planks it buys nothing, and holding it just leaves a person
    // lying on the deck curled into a ball.
    //
    // It used to run on a fixed 1.1s timer while a flip's hang time is only
    // about 0.4s, so a body spent the best part of a second balled up on the
    // deck after landing. That is what "they turn into a ball" actually was:
    // not the curl itself, but the curl outstaying the jump by more than
    // twice its length.
    if (c.flipT > 0) {
      if (!grounded) {
        c.flipAirborne = true;
        c.flipGround = 0;
      } else if (c.flipAirborne) {
        c.flipGround++;
        if (c.flipGround >= BattleConst.flipLandFrames) {
          c.flipT = 0;
          c.flipAirborne = false;
          c.flipGround = 0;
        }
      }
    }

    // Set when the rail actually stops a limb this frame — see the whole-body
    // damping after the loop.
    var railCaught = false;
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
        //
        // The lip's height window is measured from the deck surface *at that
        // rail*, not from the main deck plane. Crew are berthed on raised
        // tiers, and a body knocked off a forecastle starts a whole platform
        // height above the main deck — measuring from the plane put it above
        // the window before it ever reached the edge, so it sailed straight
        // over a rail that should have caught it.
        final worldX = stationX + p.pos.dx;
        final side = worldX > 0 ? 1.0 : -1.0;
        final railSurface = raft.surfaceY(side * raft.deckHalf) ?? 0.0;
        final over = worldX.abs() - raft.deckHalf;

        // A point that CROSSED the rail line during this step counts, however
        // far past it ended up. The old test was "is it currently within
        // [railWall] of the edge", and points move up to
        // [BattleConst.bodyMaxSpeed] units a frame — nine, against an
        // eight-unit band — so a decent shove tunnelled a limb clean through
        // the rail without ever being inside the window that was supposed to
        // stop it. That, far more than the rail being too low, is why crew
        // went overboard from hits that should only have knocked them down.
        final crossed = (stationX + p.prev.dx).abs() <= raft.deckHalf;
        final atRail = over > 0 && (crossed || over < BattleConst.railWall);
        if (atRail &&
            p.pos.dy > railSurface - BattleConst.railWallHeight &&
            p.pos.dy < railSurface + BattleConst.railWallDepth) {
          final inward = -side;
          final v = p.vel;
          if (v.dx * inward < 0) {
            p.setVel(Offset(-v.dx * BattleConst.railBounce, v.dy));
            p.pos = Offset(side * raft.deckHalf - stationX, p.pos.dy);
            railCaught = true;
          }
        }
      }
    }

    // The rail stopped a limb — but a body is one thing, and the rest of its
    // mass carries the same outward momentum. Reflecting one point and
    // leaving the other six pulling means the catch holds for a frame and
    // the body goes over anyway on the next. Bleeding the outward half of
    // the whole body's drift is what makes the rail actually hold someone
    // aboard, which is the difference between "knocked down near the edge"
    // and "knocked overboard".
    if (railCaught && !dead) {
      final outward = pose.hip.pos.dx + stationX > 0 ? 1.0 : -1.0;
      final v = pose.meanVel;
      if (v.dx * outward > 0) {
        final kill = Offset(-v.dx * BattleConst.railHold, 0);
        for (final p in pose.points) {
          p.setVel(p.vel + kill);
        }
      }
    }
    pose.solve();

    // Close the loop with the deck.
    //
    // The order used to be integrate, collide, solve — so the solver got the
    // last word and was free to push points back down through the planks.
    // The next frame's collision shoved them out again, the solver pushed
    // them back, and the body micro-jittered on the spot forever. That is
    // what "stuck" actually was: not caught on the rail, but never able to
    // hold still long enough to satisfy the settle check, so it flopped on
    // the deck until the eight-second watchdog hauled it upright.
    //
    // Clamping again after the solve makes the last word the floor's, and
    // costs one pass over seven points.
    // Only while the body is actually down and settling. A somersault dips
    // its lower half through the deck plane partway round, and straightening
    // that out mid-rotation costs the flip a quarter of its turn — while a
    // body in the air has no jitter problem to solve in the first place.
    // How much of the body is actually lying on something.
    //
    // "Grounded" asks only about the hip, and the rounded hulls have a sloped
    // deck — a body draped across one can have its hip a good way clear of
    // the surface while its shoulders and boots are firmly down. Those bodies
    // never qualified for the settle damping below, so they crept down the
    // slope forever and never stood up.
    var touching = 0;
    for (final p in pose.points) {
      final f = raft.surfaceY(stationX + p.pos.dx);
      if (f != null && p.pos.dy > f - 2) touching++;
    }
    final resting = grounded || touching >= 3;

    for (final p in resting ? pose.points : const <RagdollPoint>[]) {
      final floor = raft.surfaceY(stationX + p.pos.dx);
      if (floor != null && p.pos.dy > floor) {
        // POSITION ONLY. The first collision pass has already decided what
        // this point's velocity should be — bounce, friction, or dead stop.
        // Touching it again here takes energy out of a body that is still
        // moving through the deck plane legitimately: a somersault dips its
        // lower half below the planks partway round, and damping that was
        // enough to cost the flip a quarter of its rotation, and to stop a
        // corpse drifting over the side.
        final v = p.vel;
        p.pos = Offset(p.pos.dx, floor);
        p.prev = p.pos - v;
      }
    }

    // Flail: while a body is still tumbling in the air, characters with a
    // high flail throw their arms about instead of going limp. It is applied
    // to the hands only, as a small outward push that alternates — a
    // windmill, not a force that moves the body.
    //
    // Rate, strength and starting phase all come from the tumble's own style
    // as well as the character's trait. The phase is the important one: with
    // a fixed phase two crew members caught by the same blast windmilled in
    // perfect unison, which reads as one animation on two puppets rather
    // than two people falling over.
    if (!resting && c.alive && c.traits.flail > 0.05 && pose.maxSpeed > 1) {
      final t = c.ragdollTime * 17 * c.style.flailRate +
          c.bobPhase * 6 +
          c.style.flailPhase;
      final swing = c.traits.flail * 0.55 * c.style.flailGain;
      pose.handL.setVel(pose.handL.vel +
          Offset(cos(t) * swing, sin(t) * swing));
      pose.handR.setVel(pose.handR.vel +
          Offset(cos(t + pi) * swing, sin(t + pi) * swing));
    }

    // A slow body on the deck is trying to stop; help it. Verlet bodies bleed
    // energy very gradually, and the residue was enough to keep resetting the
    // settle window.
    // Not while a flip is still resolving: a somersault touches down and
    // keeps turning for a few frames, and stopping it dead on contact costs
    // the last of the rotation.
    if (resting && !dead && c.flipT <= 0) {
      if (pose.maxSpeed < BattleConst.bodyStopSpeed) {
        for (final p in pose.points) {
          p.setVel(Offset.zero);
        }
      } else if (pose.maxSpeed < BattleConst.bodySleepSpeed * 1.8) {
        // Limpness: how fast this body gives up its last energy. A loose one
        // flops down and stays put, a stiff one skitters a moment longer.
        final damp =
            (BattleConst.bodySettleDamp * (2 - c.style.limp)).clamp(0.35, 0.92);
        for (final p in pose.points) {
          p.setVel(p.vel * damp);
        }
      }
    }

    // Energy cap: constraint relaxation and stacked impulses can otherwise
    // fling points absurdly far — the "ragdoll into the sky" bug.
    //
    // The rise limit applies to the body's *mean* upward velocity, not to
    // each point independently. Clipping per point also clipped the upward
    // half of any rotation, which quietly bled the spin out of every
    // somersault: a flip would start, stall halfway and flop back. Capping
    // the whole-body drift keeps the "hop, not a launch" guarantee (it is
    // the mean that carries the body up) while leaving rotation intact. The
    // absolute per-point speed cap still applies, so nothing tunnels.
    pose.capRise(
        c.flipT > 0 ? BattleConst.flipRise : BattleConst.bodyMaxRise);
    for (final p in pose.points) {
      final v = p.vel;
      final speed = v.distance;
      if (speed > BattleConst.bodyMaxSpeed) {
        p.setVel(v / speed * BattleConst.bodyMaxSpeed);
      }
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
    if (!c.drowned &&
        raft.deckY + pose.hip.pos.dy > raft.waterLine + BattleConst.drownDepth) {
      c.drowned = true;
      c.clearPlant();
      c.ragdoll = false;
      c.hp = 0;
      c.vel = Offset.zero;
      effects.add(Fx(
        pos: Offset(raft.x + stationX + pose.hip.pos.dx, raft.waterLine),
        kind: 'splash',
        color: const Color(0xFFBFE9F2),
        size: 88,
        life: 0.7,
      ));
      return;
    }

    // A tumble is allowed to take a moment; it is not allowed to take all
    // day. Delicate settle tuning (sleep speeds, spin thresholds, a drift
    // window) decides when a body has come to rest NICELY, and on a sloped
    // deck a body can creep or a dangling limb can swing for long enough to
    // keep resetting it — which is what left crew twitching by the rail.
    // This is the floor under all of that: once a living body has had its
    // tumble and is lying on something, it gets up, tidily, whatever the
    // jitter is doing.
    if (c.alive &&
        c.getUpT < 0 &&
        resting &&
        c.ragdollTime > BattleConst.bodyRecoverLimit) {
      c.rest = 0;
      c.getUpT = 0;
      return;
    }

    // Settling: down on the deck (or a platform), barely moving — stop
    // tumbling and stand. Only the living get up; a body at 0 HP stays down
    // until the water takes it. Speed and spin sit above the resting
    // jitter; the drift check catches a body still sliding (down a ramp,
    // say), which keeps resetting the window instead of rising mid-slide.
    // A body that has come to rest draped over the rail is still aboard.
    //
    // The floor lookup returns null the instant the hip is a hair past the
    // deck edge, and "settled" required a non-null floor — so a crew member
    // the rail had just caught could never satisfy the check, never stood up,
    // and flopped at the edge until the eight-second watchdog gave up on
    // them. That is the "stuck on the railings" bug. Looking the floor up at
    // the edge instead lets them stand and walk home; the overhang limit
    // keeps a body genuinely out over the water from "settling" in mid-air.
    final hipLocal = stationX + pose.hip.pos.dx;
    final overhang = hipLocal.abs() - raft.deckHalf;
    final hipFloor = overhang <= BattleConst.railWall
        ? raft.surfaceY(hipLocal.clamp(-raft.deckHalf, raft.deckHalf))
        : null;
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
      // How long they lie there before picking themselves up is rolled per
      // tumble too — a deck where everyone springs up on the same beat looks
      // choreographed.
      if (c.rest >= BattleConst.bodySettleTime * c.style.linger) {
        c.rest = 0;
        c.getUpT = 0;
      }
    } else {
      c.rest = 0;
    }
  }

  /// Vertical bob offset for a raft at the current time — the design's gentle
  /// `bob` keyframe, scaled by the scene's chop.
  ///
  /// Zero for anything rooted to the seabed. An island rising and falling on
  /// the swell reads as a bug rather than as weather.
  double bobOf(Raft raft) => raft.place.floats
      ? sin(elapsed * 1.9 + raft.x * 0.01) * 3.2 * map.chop
      : 0.0;
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
