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

  /// A shot within this many units of a crew member counts as a direct hit.
  static const double hitRadius = 34;

  // ---------------------------------------------------------------------------
  // Camera lock (blind fire)
  // ---------------------------------------------------------------------------

  /// How far ahead of the shooter's own raft the locked camera centres, so
  /// there is open water in front of them instead of them hugging the edge.
  static const double camLead = 190;

  /// Extra clearance kept between the camera's frame and the near edge of a
  /// living enemy raft. Bigger than a raft's half-width, so even a wide barge
  /// cannot poke into view.
  static const double camEnemyMargin = 90;

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
  /// sideways, and the tuning target is that an ordinary hit rocks someone
  /// back on their heels while only heavy ordnance can carry them over the
  /// side.
  static const double bodyLift = 0.25;

  /// Below this speed and spin a grounded body is considered to have stopped
  /// tumbling, and starts [bodySettleTime] of "getting up" before it stands.
  static const double bodySleepSpeed = 0.85;
  static const double bodySleepSpin = 0.022;
  static const double bodySettleTime = 0.4;

  /// How fast a recovered crew member shuffles back to their station, and how
  /// quickly an upright body unwinds its tilt (0..1 per frame).
  static const double bodyRecover = 0.12;
  static const double bodyUnwind = 0.22;

  /// How far below the waterline a body's feet must sink before they drown.
  static const double drownDepth = 14;
}

/// One character aboard a raft.
///
/// Besides HP, a crew member carries a small rigid body: an [offset] from
/// their station on the deck plus a [tilt]. While [ragdoll] is set that body
/// is airborne or sliding and is integrated by [BattleWorld.update]; once it
/// goes to sleep the body eases back to its station and stands up. A body
/// that slides off the deck falls into the sea and drowns — being knocked
/// overboard is what actually eliminates a crew member in this game, not
/// merely reaching 0 HP where they stand.
class Crew {
  double hp;
  final double maxHp;

  /// Phase offset so crew on the same raft don't bob in lockstep.
  final double bobPhase;

  /// 0 while alive; ramps to 1 as a defeated crew member sinks out of view.
  double sinkT = 0;

  /// Offset of the body's feet from its station, in world units. +dx is to
  /// the right, +dy is *down* (toward and then through the waterline).
  Offset offset = Offset.zero;

  /// Body velocity in world units per 60Hz frame.
  Offset vel = Offset.zero;

  /// Current lean in radians, and how fast that lean is spinning.
  double tilt = 0;
  double spin = 0;

  /// True while the body is being thrown around by an impact.
  bool ragdoll = false;

  /// True once the body has come to rest after tumbling. Counts up to
  /// [BattleConst.bodySettleTime] before they stand back up.
  double rest = 0;

  /// Went into the water. This is fatal and permanent for the round.
  bool drowned = false;

  Crew({required this.hp, required this.maxHp, this.bobPhase = 0});

  bool get alive => hp > 0;

  /// True once the sink animation has finished and they should stop drawing.
  bool get gone => !alive && sinkT >= 1;

  double get hpFrac => (hp / maxHp).clamp(0.0, 1.0);

  /// Knocked off their feet by an impact.
  ///
  /// [dir] is the projectile's travel direction, [force] its shove in world
  /// units per frame. The body is launched mostly along the shot with a
  /// little lift, plus spin away from the impact so they tumble rather than
  /// slide like a crate.
  void knock(Offset dir, double force) {
    final d = dir.distance <= 0 ? const Offset(1, 0) : dir / dir.distance;
    ragdoll = true;
    rest = 0;
    vel = Offset(
      vel.dx + d.dx * force,
      vel.dy + d.dy * force - force * BattleConst.bodyLift,
    );
    spin += (d.dx >= 0 ? 1 : -1) * force * 0.045;
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
  double get deckHalf => loadout.width * 0.5 - 10;

  /// World position of crew member [i]'s feet, following their body.
  Offset feetPos(int i) => Offset(x + loadout.crewOffset(i) + crew[i].offset.dx, deckY + crew[i].offset.dy);

  /// World position of crew member [i]'s body centre — the point a shot has
  /// to land near. Sits a torso-and-a-bit above the feet.
  Offset crewPos(int i) => feetPos(i) - const Offset(0, 24);

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
      // The shove is what sells the hit — they kick back the way the shot
      // was travelling and tumble, rather than standing there soaking it up.
      if (c.alive) c.knock(s.vel, Crew.impactForce(s.weapon));
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
          if (c.alive) {
            final away = raft.crewPos(i) - impact;
            c.knock(away, Crew.impactForce(s.weapon) * 0.55 * falloff);
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
    for (final raft in rafts) {
      for (int i = 0; i < raft.crew.length; i++) {
        final c = raft.crew[i];

        if (!c.alive && c.sinkT < 1) {
          c.sinkT = (c.sinkT + 1 / 60 * 1.4).clamp(0.0, 1.0);
          // A body killed where it stands goes limp and sinks; one that was
          // already in the water is handled by the drowned path instead.
          if (!c.drowned) c.ragdoll = false;
        }

        if (c.ragdoll) {
          _stepBody(raft, i, c);
        } else if (c.alive && c.offset != Offset.zero) {
          // Recovered: shuffle back to the station they were knocked off.
          c.offset = c.offset * (1 - BattleConst.bodyRecover);
          c.tilt *= (1 - BattleConst.bodyUnwind);
          if (c.tilt.abs() < 0.01) c.tilt = 0;
          if (c.offset.distance < 0.4) c.offset = Offset.zero;
        }
      }
    }
  }

  void _stepBody(Raft raft, int index, Crew c) {
    var p = c.offset;
    var v = c.vel;

    v = Offset(v.dx * BattleConst.bodyDrag, v.dy + BattleConst.bodyGravity);
    p += v;

    // Feet are at the body's origin, so the deck stops them at offset 0 —
    // but only while they are still over the planks. Their station is not
    // necessarily the middle of the raft, hence the absolute check.
    final overDeck = (raft.loadout.crewOffset(index) + p.dx).abs() < raft.deckHalf;
    final onDeck = p.dy >= 0 && overDeck;

    if (onDeck) {
      p = Offset(p.dx, 0);
      if (v.dy > 0) {
        // Land: bounce a little, and bleed the tumble off on impact.
        v = Offset(v.dx, -v.dy * BattleConst.bodyBounce);
        c.spin *= 0.55;
        if (v.dy.abs() < 0.6) v = Offset(v.dx, 0);
      }
      v = Offset(v.dx * BattleConst.bodyFriction, v.dy);
      c.spin *= BattleConst.bodyFriction;
    }

    // Overboard there is no deck to stop them at all — they just keep
    // falling until the waterline takes them.

    c.offset = p;
    c.vel = v;
    c.tilt += c.spin;
    c.spin *= BattleConst.bodyDrag;

    // Drowning: feet this far under the waterline ends them for the round.
    final feetY = raft.deckY + p.dy;
    if (!c.drowned && feetY > BattleConst.waterY + BattleConst.drownDepth) {
      c.drowned = true;
      c.ragdoll = false;
      c.hp = 0;
      c.vel = Offset.zero;
      c.spin = 0;
      effects.add(Fx(
        pos: Offset(raft.feetPos(index).dx, BattleConst.waterY),
        kind: 'splash',
        color: const Color(0xFFBFE9F2),
        size: 88,
        life: 0.7,
      ));
      return;
    }

    // Settling: down on the deck, barely moving — stop tumbling and stand.
    if (onDeck && v.distance < BattleConst.bodySleepSpeed && c.spin.abs() < BattleConst.bodySleepSpin) {
      c.rest += 1 / 60;
      c.vel = Offset.zero;
      c.spin = 0;
      if (c.rest >= BattleConst.bodySettleTime) {
        c.ragdoll = false;
        c.rest = 0;
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
