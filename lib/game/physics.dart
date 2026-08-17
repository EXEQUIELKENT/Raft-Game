import 'dart:math';
import 'dart:ui';
import 'models.dart';

/// ---------------------------------------------------------------------------
/// Raft Rumble custom 2D physics engine.
/// Axis-aligned + rotated rect bodies, circle projectiles, impulse knockback,
/// ragdoll tumbling, debris, water, wind, chain destruction.
/// Deterministic-ish given the same inputs & fixed step.
/// ---------------------------------------------------------------------------

enum BodyType { block, character, debris, projectile }

enum MaterialType { wood, stone, metal, glass, raft }

class PhysBody {
  int id;
  BodyType type;
  Offset pos; // center
  Size size;
  double angle;
  Offset vel;
  double angularVel;
  double mass;
  double restitution;
  double friction;
  bool isStatic; // anchored (raft bases, terrain)
  bool sleeping = false;
  bool dead = false;
  int playerIndex; // owner for characters/blocks
  // damage
  double hp;
  double maxHp;
  MaterialType material;
  double frozenUntil = 0; // frozen bodies are static-ish & brittle
  double burnUntil = 0;
  double slowUntil = 0;
  double supportTimer = 0; // seconds without support -> collapse
  bool isSensor = false; // projectiles use manual collision
  bool explosive = false; // e.g. desert barrels: detonate when destroyed
  bool isVehicle = false; // map-hazard traffic: cruises at fixed height, ignores gravity/wind

  PhysBody({
    required this.id,
    required this.type,
    required this.pos,
    required this.size,
    this.angle = 0,
    this.vel = Offset.zero,
    this.angularVel = 0,
    this.mass = 1,
    this.restitution = 0.2,
    this.friction = 0.6,
    this.isStatic = false,
    this.playerIndex = -1,
    this.hp = 100,
    this.maxHp = 100,
    this.material = MaterialType.wood,
  });

  Rect get aabb {
    // conservative AABB covering rotation
    final c = cos(angle).abs(), s = sin(angle).abs();
    final w = size.width * c + size.height * s;
    final h = size.width * s + size.height * c;
    return Rect.fromCenter(center: pos, width: w, height: h);
  }

  /// corners in world space
  List<Offset> corners() {
    final hw = size.width / 2, hh = size.height / 2;
    final pts = [
      Offset(-hw, -hh), Offset(hw, -hh), Offset(hw, hh), Offset(-hw, hh),
    ];
    return pts.map((p) => pos + rotate(p, angle)).toList();
  }

  double get damageFrac => (hp / maxHp).clamp(0.0, 1.0);
}

/// A projectile in flight
class Projectile {
  Offset pos;
  Offset vel;
  double radius;
  WeaponDef weapon;
  int owner;
  double bornAt;
  double age = 0;
  int bounces = 0;
  double fuse = -1; // grenades: time until explosion after first touch
  bool dead = false;
  bool clustered = false;
  List<Offset> trail = [];

  Projectile({
    required this.pos,
    required this.vel,
    required this.weapon,
    required this.owner,
    required this.bornAt,
    this.radius = 10,
  });
}

class Particle {
  Offset pos;
  Offset vel;
  double life;
  double maxLife;
  double size;
  Color color;
  double gravity;
  bool glow;

  Particle({
    required this.pos,
    required this.vel,
    required this.life,
    required this.size,
    required this.color,
    this.gravity = 0,
    this.glow = false,
  }) : maxLife = life;
}

class FloatingText {
  Offset pos;
  String text;
  Color color;
  double life = 1.2;
  double size;
  FloatingText(this.pos, this.text, this.color, {this.size = 22});
}

/// Events emitted for networking / UI
class GameEvent {
  final String kind;
  final Map<String, dynamic> data;
  GameEvent(this.kind, [this.data = const {}]);
}

class PhysicsWorld {
  final double width;
  final double height;
  double waterLevel; // y coordinate of water surface
  double gravity = 900;
  double wind = 0; // -1..1
  double elapsed = 0;
  final GameRng rng;

  // ---------------------------------------------------------------------
  // Velocity safety limits.
  //
  // Characters are ragdolls integrated by the *same* body loop as blocks
  // and debris (see `step()`) — never routed through the projectile path —
  // so gravity, wind, knockback, collision impulses and hazards all act on
  // them through ordinary linear/angular velocity, exactly like any other
  // dynamic body. Nothing here ever writes to `pos` directly to fake a
  // ground height; these are true terminal-velocity/terminal-spin ceilings
  // applied to the velocities that drive position, same as a real physics
  // engine would use. They sit far above any legitimate in-game speed
  // (the hardest explosion knockback tops out well under half of
  // [_maxCharacterSpeed]) so normal falls, hits, launches and tumbles are
  // completely unaffected — they only stop *unbounded* accumulation from
  // stacking/chained impulses (e.g. repeated tiny collision corrections
  // while wedged between two bodies) from ever running away.
  static const double _maxCharacterSpeed = 1600; // px/s
  static const double _maxCharacterAngularVel = 14; // rad/s (~2.2 rev/s)
  static const double _maxBodySpeed = 2200; // blocks/debris/hazard rocks
  static const double _maxBodyAngularVel = 20; // rad/s
  // Below these, residual velocity is treated as solver/collision noise
  // and snapped to exactly zero rather than left to linger — otherwise a
  // "resting" body can sit at some tiny nonzero velocity forever, and the
  // next microscopic collision correction has something nonzero to keep
  // amplifying instead of a clean zero to start from.
  static const double _sleepLinearEps = 4; // px/s
  static const double _sleepAngularEps = 0.05; // rad/s

  final List<PhysBody> bodies = [];
  final List<Projectile> projectiles = [];
  final List<Particle> particles = [];
  final List<FloatingText> texts = [];
  final List<GameEvent> events = [];

  int _nextId = 1;
  double screenShake = 0;

  /// hazard zones (fire patches)
  final List<_Hazard> hazards = [];

  /// The current map's hazard type: none | waves | rocks | barrels | lava | traffic.
  /// 'barrels' is handled reactively in [destroyBlock] via [PhysBody.explosive];
  /// the rest are driven periodically by [_updateMapHazard].
  final String mapHazard;

  /// What lies beyond the play area's edge: water | sand | lava. Affects the
  /// splash effect and elimination cause when something falls off the edge.
  final String environment;

  double _hazardTimer = 3.0;

  PhysicsWorld({
    required this.width,
    required this.height,
    required this.waterLevel,
    int seed = 42,
    this.mapHazard = 'none',
    this.environment = 'water',
  }) : rng = GameRng(seed);

  int nextId() => _nextId++;

  // -------------------------------------------------------------------------
  // Body management
  // -------------------------------------------------------------------------

  PhysBody addBlock({
    required Offset pos,
    required Size size,
    required MaterialType material,
    double angle = 0,
    bool isStatic = false,
    int playerIndex = -1,
  }) {
    final spec = _materialSpec(material);
    final b = PhysBody(
      id: nextId(),
      type: BodyType.block,
      pos: pos,
      size: size,
      angle: angle,
      mass: spec.mass * (size.width * size.height) / 3000,
      restitution: spec.restitution,
      friction: spec.friction,
      isStatic: isStatic,
      playerIndex: playerIndex,
      hp: spec.hp * ((size.width * size.height) / 3000).clamp(0.5, 2.5),
      maxHp: 0,
      material: material,
    );
    b.maxHp = b.hp;
    bodies.add(b);
    return b;
  }

  PhysBody addCharacter({
    required Offset pos,
    required int playerIndex,
    double hp = 100,
  }) {
    final b = PhysBody(
      id: nextId(),
      type: BodyType.character,
      pos: pos,
      size: const Size(34, 52),
      mass: 3,
      restitution: 0.25,
      friction: 0.55,
      playerIndex: playerIndex,
      hp: hp,
      maxHp: hp,
      material: MaterialType.wood,
    );
    bodies.add(b);
    return b;
  }

  void addDebris(Offset pos, Offset vel, Size size, Color color, MaterialType mat, {double? angVel}) {
    final b = PhysBody(
      id: nextId(),
      type: BodyType.debris,
      pos: pos,
      size: size,
      angle: rng.range(0, pi),
      vel: vel,
      angularVel: angVel ?? rng.range(-8, 8),
      mass: 0.4,
      restitution: 0.4,
      friction: 0.5,
      hp: 1,
      maxHp: 1,
      material: mat,
    );
    b.dead = false;
    bodies.add(b);
    debrisColors[b.id] = color;
  }

  final Map<int, Color> debrisColors = {};

  // -------------------------------------------------------------------------
  // Combat
  // -------------------------------------------------------------------------

  Projectile fire({
    required Offset from,
    required double angleRad,
    required double power, // 0..1
    required WeaponDef weapon,
    required int owner,
  }) {
    final speed = weapon.speed * (280 + power * 620);
    final vel = Offset(cos(angleRad), sin(angleRad)) * speed;
    final p = Projectile(
      pos: from,
      vel: vel,
      weapon: weapon,
      owner: owner,
      bornAt: elapsed,
      radius: 9 * weapon.weight,
    );
    projectiles.add(p);
    events.add(GameEvent('fire', {'owner': owner, 'weapon': weapon.id}));
    return p;
  }

  void explode(Offset center, double radius, double damage, double knockback,
      {double structDamage = 1.0, int owner = -1, String effect = 'standard'}) {
    screenShake = min(screenShake + radius / 40, 14);
    events.add(GameEvent('explosion', {'x': center.dx, 'y': center.dy, 'r': radius, 'effect': effect}));

    // particles
    final count = (radius / 3).round().clamp(10, 40);
    for (int i = 0; i < count; i++) {
      final a = rng.range(0, 2 * pi);
      final sp = rng.range(40, radius * 3.2);
      particles.add(Particle(
        pos: center,
        vel: Offset(cos(a) * sp, sin(a) * sp - 40),
        life: rng.range(0.35, 0.8),
        size: rng.range(4, 12),
        color: [const Color(0xFFFFD32A), const Color(0xFFFF8C1A), const Color(0xFFFF4757), const Color(0xFF555555)]
            [rng.nextInt(4)],
        gravity: 300,
        glow: true,
      ));
    }

    // damage bodies (iterate a copy — destroyBlock spawns debris into bodies)
    for (final b in List.of(bodies)) {
      if (b.dead) continue;
      final d = (b.pos - center).distance;
      if (d > radius + b.size.longestSide / 2) continue;
      final falloff = 1 - (d / (radius + b.size.longestSide / 2)).clamp(0.0, 1.0);
      final dir = (b.pos - center);
      final n = dir.distance < 1 ? const Offset(0, -1) : dir / dir.distance;

      if (b.type == BodyType.character) {
        final dmg = damage * falloff;
        damageCharacter(b, dmg, n * knockback * 260 * falloff, owner: owner, cause: effect);
      } else if (b.type == BodyType.block && !b.isStatic) {
        damageBlock(b, damage * structDamage * falloff * 1.4, effect: effect);
        b.vel += n * knockback * 200 * falloff / max(b.mass, 0.5);
        b.angularVel += rng.range(-4, 4) * falloff * knockback;
        b.sleeping = false;
      } else if (b.type == BodyType.block && b.isStatic) {
        damageBlock(b, damage * structDamage * falloff, effect: effect);
      }
    }

    if (effect == 'fire') {
      hazards.add(_Hazard(center: Offset(center.dx, center.dy), radius: radius * 0.75, until: elapsed + 4, kind: 'fire'));
    }
    if (effect == 'ice') {
      for (final b in bodies) {
        if (b.dead) continue;
        if ((b.pos - center).distance < radius + 20) {
          if (b.type == BodyType.block) b.frozenUntil = elapsed + 5;
          if (b.type == BodyType.character) b.slowUntil = elapsed + 3;
        }
      }
    }
  }

  void damageCharacter(PhysBody c, double amount, Offset impulse, {int owner = -1, String cause = 'hit'}) {
    if (c.dead || amount <= 0 && impulse == Offset.zero) return;
    c.hp -= amount;
    c.vel += impulse / c.mass;
    c.angularVel += rng.range(-6, 6) * (impulse.distance / 200).clamp(0.3, 2.0);
    c.sleeping = false;
    texts.add(FloatingText(
      c.pos + const Offset(0, -40),
      '-${amount.round()}',
      amount >= 30 ? const Color(0xFFFF4757) : const Color(0xFFFFD32A),
      size: amount >= 30 ? 30 : 20,
    ));
    events.add(GameEvent('charHit', {
      'id': c.id, 'dmg': amount.round(), 'hp': max(0, c.hp).round(), 'player': c.playerIndex, 'by': owner,
    }));
    if (c.hp <= 0 && !c.dead) {
      c.dead = true;
      events.add(GameEvent('eliminated', {'player': c.playerIndex, 'by': owner, 'cause': cause}));
      // ragdoll burst
      for (int i = 0; i < 10; i++) {
        particles.add(Particle(
          pos: c.pos,
          vel: Offset(rng.range(-160, 160), rng.range(-260, -40)),
          life: rng.range(0.5, 1.0),
          size: rng.range(3, 8),
          color: const Color(0xFFFF6BC1),
          gravity: 500,
        ));
      }
    }
  }

  void damageBlock(PhysBody b, double amount, {String effect = 'hit'}) {
    if (b.dead) return;
    if (b.frozenUntil > elapsed) amount *= 1.8; // brittle when frozen
    b.hp -= amount;
    if (b.hp <= 0) destroyBlock(b, effect: effect);
  }

  void destroyBlock(PhysBody b, {String effect = 'hit'}) {
    if (b.dead) return;
    final wasExplosive = b.explosive;
    b.dead = true;
    events.add(GameEvent('blockDestroyed', {'material': b.material.name, 'x': b.pos.dx, 'y': b.pos.dy}));
    final color = _materialSpec(b.material).color;
    final pieces = (b.size.width * b.size.height / 1200).round().clamp(2, 7);
    for (int i = 0; i < pieces; i++) {
      addDebris(
        b.pos + Offset(rng.range(-b.size.width / 3, b.size.width / 3), rng.range(-b.size.height / 3, b.size.height / 3)),
        b.vel + Offset(rng.range(-140, 140), rng.range(-220, -20)),
        Size(max(6, b.size.width / 2.4), max(6, b.size.height / 2.4)),
        color,
        b.material,
      );
    }
    // dust
    for (int i = 0; i < 6; i++) {
      particles.add(Particle(
        pos: b.pos + Offset(rng.range(-14, 14), rng.range(-14, 14)),
        vel: Offset(rng.range(-60, 60), rng.range(-90, -10)),
        life: rng.range(0.4, 0.9),
        size: rng.range(6, 14),
        color: color.withOpacity(0.7),
        gravity: 120,
      ));
    }
    // desert barrels: popping one detonates it (and can chain into any
    // neighbouring barrels caught in the blast, since explode() re-enters
    // destroyBlock for anything it kills — b.dead is already true by then
    // so this barrel itself can't double-trigger).
    if (wasExplosive) {
      explode(b.pos, 80, 32, 1.15, structDamage: 1.2, owner: -1, effect: 'standard');
    }
  }

  // -------------------------------------------------------------------------
  // Simulation step (fixed dt)
  // -------------------------------------------------------------------------

  void step(double dt) {
    elapsed += dt;
    events.clear();

    // --- projectiles ---
    // iterate a copy: cluster split appends children to `projectiles`
    for (final p in List.of(projectiles)) {
      if (p.dead) continue;
      p.age += dt;
      final gMult = p.weapon.behavior == 'rocket' && p.age < 0.55 ? 0.25 : p.weapon.gravity;
      p.vel += Offset(wind * 260 * (p.weapon.behavior == 'rocket' ? 0.3 : 1.0), gravity * gMult) * dt;
      p.pos += p.vel * dt;
      p.trail.add(p.pos);
      if (p.trail.length > 14) p.trail.removeAt(0);

      // grenade fuse
      if (p.fuse > 0) {
        p.fuse -= dt;
        if (p.fuse <= 0) {
          p.dead = true;
          explode(p.pos, p.weapon.radius, p.weapon.damage, p.weapon.knockback,
              structDamage: p.weapon.structDamage, owner: p.owner);
          continue;
        }
      }

      // cluster split
      if (p.weapon.behavior == 'cluster' && !p.clustered && p.age > 0.7) {
        p.clustered = true;
        p.dead = true;
        for (int i = 0; i < 5; i++) {
          final a = -pi / 2 + (i - 2) * 0.45;
          final sp = p.vel.distance * 0.55;
          final child = Projectile(
            pos: p.pos,
            vel: Offset(cos(a), sin(a)) * sp + p.vel * 0.35,
            weapon: p.weapon,
            owner: p.owner,
            bornAt: elapsed,
            radius: 6,
          );
          child.age = 0.71; // children don't re-split
          projectiles.add(child);
        }
        events.add(GameEvent('split', {}));
        continue;
      }

      _collideProjectile(p, dt);
      if (p.dead) continue;

      // water
      if (p.pos.dy > waterLevel) {
        p.dead = true;
        splash(p.pos, p.vel.distance / 40);
        events.add(GameEvent('splash', {'x': p.pos.dx, 'y': p.pos.dy}));
        continue;
      }
      // out of bounds
      if (p.pos.dx < -300 || p.pos.dx > width + 300 || p.pos.dy > height + 400) {
        p.dead = true;
      }
    }
    projectiles.removeWhere((p) => p.dead);

    // --- bodies ---
    for (final b in bodies) {
      if (b.dead) continue;

      // burning damage
      if (b.burnUntil > elapsed) {
        b.hp -= 8 * dt;
        if (rng.nextDouble() < 0.3) {
          particles.add(Particle(
            pos: b.pos + Offset(rng.range(-12, 12), rng.range(-16, 0)),
            vel: Offset(rng.range(-15, 15), rng.range(-70, -30)),
            life: 0.5, size: rng.range(4, 9),
            color: const Color(0xFFFF8C1A), glow: true,
          ));
        }
        if (b.hp <= 0) {
          if (b.type == BodyType.block) destroyBlock(b, effect: 'fire');
          else if (b.type == BodyType.character) damageCharacter(b, 1, Offset.zero, cause: 'fire');
        }
      }

      final frozen = b.frozenUntil > elapsed;
      if (b.isStatic || frozen) {
        if (frozen) {
          b.vel = Offset.zero;
          b.angularVel = 0;
        }
        continue;
      }

      if (b.isVehicle) {
        // hazard traffic: cruises at a fixed height in a straight line,
        // unaffected by gravity/wind/drag, and simply despawns once it has
        // driven off the far side of the map.
        b.pos += b.vel * dt;
        if (b.pos.dx < -160 || b.pos.dx > width + 160) b.dead = true;
        continue;
      }

      final slow = b.slowUntil > elapsed ? 0.5 : 1.0;
      // Gravity + wind. `gravity` (900) is positive-down in this Y-down
      // coordinate space, so this always accelerates every non-static,
      // non-frozen, non-vehicle body — characters included — downward,
      // never upward. Characters go through this exact body loop (not
      // Projectile's separate, gravity-multiplier-driven integration
      // above), so they always fall like ragdolls, never like projectiles.
      b.vel += Offset(wind * 90, gravity) * dt;
      // drag
      b.vel *= (1 - 0.12 * dt);
      b.angularVel *= (1 - 0.8 * dt);
      b.pos += b.vel * dt * slow;
      b.angle += b.angularVel * dt * slow;
      if (b.angle > pi * 4 || b.angle < -pi * 4) b.angle = b.angle % (2 * pi);

      // water (or sand / lava, depending on the map): characters are
      // eliminated, debris floats/sinks
      if (b.pos.dy > waterLevel + b.size.height / 2) {
        if (b.type == BodyType.character) {
          splash(b.pos, 3);
          damageCharacter(b, 9999.0, Offset.zero, cause: _edgeCause);
        } else if (b.type == BodyType.debris) {
          b.vel = Offset(b.vel.dx * 0.9, b.vel.dy * 0.6 - 30);
          if (b.pos.dy > waterLevel + 120) b.dead = true;
        } else if (b.type == BodyType.block && !b.isStatic) {
          // blocks sink with buoyancy drag
          b.vel = Offset(b.vel.dx * 0.92, b.vel.dy * 0.55);
          b.angularVel *= 0.9;
          if (b.pos.dy > waterLevel + 260) b.dead = true;
        }
      }

      // out of world sides
      if (b.pos.dx < -80) { b.pos = Offset(-80, b.pos.dy); b.vel = Offset(b.vel.dx.abs() * 0.3, b.vel.dy); }
      if (b.pos.dx > width + 80) { b.pos = Offset(width + 80, b.pos.dy); b.vel = Offset(-b.vel.dx.abs() * 0.3, b.vel.dy); }
      if (b.pos.dy > height + 500) {
        if (b.type == BodyType.character) damageCharacter(b, 9999.0, Offset.zero, cause: 'fell');
        b.dead = true;
      }
    }

    // --- collisions body vs body (positional + impulse, O(n^2) but n small) ---
    final active = bodies.where((b) => !b.dead).toList();
    for (int i = 0; i < active.length; i++) {
      for (int j = i + 1; j < active.length; j++) {
        _resolvePair(active[i], active[j]);
      }
    }

    // --- support check: dynamic blocks with nothing below slowly collapse ---
    for (final b in active) {
      if (b.type != BodyType.block || b.isStatic || b.isVehicle) continue;
      final supported = _hasSupport(b, active);
      if (supported) {
        b.supportTimer = 0;
      } else {
        b.supportTimer += dt;
        // unsupported blocks sag & eventually fall apart
        if (b.supportTimer > 2.2) {
          destroyBlock(b, effect: 'collapse');
          events.add(GameEvent('collapse', {}));
        } else if (b.supportTimer > 0.4) {
          b.vel += Offset(rng.range(-8, 8), 60) * dt; // wobble
        }
      }
    }

    // --- hazards ---
    hazards.removeWhere((h) => h.until < elapsed);
    for (final h in hazards) {
      for (final b in active) {
        if ((b.pos - h.center).distance < h.radius + b.size.longestSide / 3) {
          if (h.kind == 'fire') b.burnUntil = elapsed + 2.2;
        }
      }
      if (rng.nextDouble() < 0.5) {
        particles.add(Particle(
          pos: h.center + Offset(rng.range(-h.radius / 2, h.radius / 2), 0),
          vel: Offset(rng.range(-10, 10), rng.range(-90, -40)),
          life: rng.range(0.3, 0.7),
          size: rng.range(5, 12),
          color: rng.nextBool() ? const Color(0xFFFF8C1A) : const Color(0xFFFFD32A),
          glow: true,
        ));
      }
    }

    // --- per-map hazard (rocks / traffic / embers / wind gusts) ---
    _updateMapHazard(dt);

    // --- velocity safety net -----------------------------------------
    // Runs last, after gravity/wind (body loop), knockback & collision
    // impulses (_resolvePair), support-collapse wobble, and map hazards
    // have all had their say this frame. This is a hard cap on the
    // *result* of those forces, not a substitute for them — it never
    // touches `pos` or `angle` directly (no Y-clamping), it only keeps
    // the velocities that drive them inside sane, physically-plausible
    // bounds so a chain of small impulses (e.g. a character wedged
    // between two colliding bodies, or repeated hazard hits) can never
    // accumulate into runaway upward drift or endless spin.
    for (final b in bodies) {
      if (b.dead || b.isStatic || b.isVehicle) continue;
      if (b.frozenUntil > elapsed) continue; // already zeroed above
      final isChar = b.type == BodyType.character;
      final maxSpeed = isChar ? _maxCharacterSpeed : _maxBodySpeed;
      final maxSpin = isChar ? _maxCharacterAngularVel : _maxBodyAngularVel;

      final speed = b.vel.distance;
      if (speed > maxSpeed) {
        b.vel = b.vel * (maxSpeed / speed);
      } else if (speed < _sleepLinearEps) {
        b.vel = Offset.zero;
      }

      if (b.angularVel.abs() > maxSpin) {
        b.angularVel = maxSpin * b.angularVel.sign;
      } else if (b.angularVel.abs() < _sleepAngularEps) {
        b.angularVel = 0;
      }
    }

    // --- particles & texts ---
    for (final pt in particles) {
      pt.life -= dt;
      pt.vel += Offset(0, pt.gravity) * dt;
      pt.pos += pt.vel * dt;
    }
    particles.removeWhere((p) => p.life <= 0);
    for (final t in texts) {
      t.life -= dt;
      t.pos += const Offset(0, -55) * dt;
    }
    texts.removeWhere((t) => t.life <= 0);

    bodies.removeWhere((b) => b.dead && b.type == BodyType.debris);
    if (screenShake > 0) screenShake = max(0, screenShake - dt * 22);
  }

  // -------------------------------------------------------------------------
  // Per-map hazards (MapDef.hazard) — 'barrels' is reactive (see
  // destroyBlock); everything else here fires on its own timer.
  // -------------------------------------------------------------------------

  void _updateMapHazard(double dt) {
    if (mapHazard == 'none' || mapHazard == 'barrels') return;
    _hazardTimer -= dt;
    if (_hazardTimer > 0) return;
    switch (mapHazard) {
      case 'rocks':
        _spawnFallingRock();
        _hazardTimer = rng.range(4.5, 8.0);
        break;
      case 'lava':
        _spawnEmber();
        _hazardTimer = rng.range(3.0, 5.5);
        break;
      case 'traffic':
        _spawnTraffic();
        _hazardTimer = rng.range(5.0, 9.0);
        break;
      case 'waves':
        _gustWind();
        _hazardTimer = rng.range(3.5, 6.5);
        break;
      default:
        _hazardTimer = 999; // unknown hazard kind: don't loop forever
    }
  }

  /// Frosty Peaks: boulders tumble down from off-screen and slam into
  /// whatever (or whoever) is below — reuses the normal falling-block /
  /// impact-damage physics, it just needs to exist.
  void _spawnFallingRock() {
    final x = rng.range(width * 0.12, width * 0.88);
    final side = rng.range(22.0, 34.0);
    final rock = addBlock(
      pos: Offset(x, -60),
      size: Size(side, side),
      material: MaterialType.stone,
      isStatic: false,
    );
    rock.vel = Offset(rng.range(-30, 30), rng.range(120, 200));
    events.add(GameEvent('rockfall', {'x': x}));
  }

  /// Mount Sizzle: a shower of embers drifts down and ignites a patch of
  /// fire where it lands, reusing the existing fire-hazard/burn mechanic.
  void _spawnEmber() {
    final x = rng.range(width * 0.15, width * 0.85);
    final landY = waterLevel - rng.range(20, 90);
    for (int i = 0; i < 10; i++) {
      particles.add(Particle(
        pos: Offset(x + rng.range(-10, 10), landY - 260 - rng.range(0, 160)),
        vel: Offset(rng.range(-20, 20), rng.range(160, 260)),
        life: rng.range(0.9, 1.6),
        size: rng.range(3, 7),
        color: rng.nextBool() ? const Color(0xFFFF8C1A) : const Color(0xFFFFD32A),
        gravity: 40,
        glow: true,
      ));
    }
    hazards.add(_Hazard(center: Offset(x, landY), radius: 42, until: elapsed + 3.4, kind: 'fire'));
    events.add(GameEvent('ember', {'x': x, 'y': landY}));
  }

  /// Rooftop Rumble: a vehicle zooms along the street below the towers,
  /// dealing the usual "moving block slam" damage to anyone in its path.
  void _spawnTraffic() {
    final dir = rng.nextBool() ? 1.0 : -1.0;
    final startX = dir > 0 ? -140.0 : width + 140.0;
    final car = addBlock(
      pos: Offset(startX, waterLevel + 16),
      size: const Size(70, 24),
      material: MaterialType.metal,
      isStatic: false,
    );
    car.mass = 6;
    car.isVehicle = true;
    car.vel = Offset(dir * rng.range(260, 340), 0);
    events.add(GameEvent('traffic', {'dir': dir}));
  }

  /// Ocean Drift: rolling waves periodically gust the wind for a few beats.
  void _gustWind() {
    final dir = rng.nextBool() ? 1.0 : -1.0;
    wind = (wind + dir * rng.range(0.15, 0.35)).clamp(-1.0, 1.0);
    events.add(GameEvent('gust', {'wind': wind}));
  }

  bool _hasSupport(PhysBody b, List<PhysBody> all) {
    // sample 3 points under the body
    for (final fx in [-0.3, 0.0, 0.3]) {
      final probe = b.pos + Offset(b.size.width * fx, b.size.height / 2 + 6);
      for (final o in all) {
        if (identical(o, b) || o.dead || o.type == BodyType.debris) continue;
        if (o.aabb.contains(probe)) return true;
      }
    }
    return false;
  }

  void _collideProjectile(Projectile p, double dt) {
    for (final b in bodies) {
      if (b.dead) continue;
      // projectile vs character
      if (b.type == BodyType.character) {
        final hit = _circleVsBody(p.pos, p.radius, b);
        if (hit != null) {
          if (p.weapon.behavior == 'grenade') {
            // Grenades don't detonate on contact — they arm their fuse (if not
            // already armed) and bounce off, same as when hitting a block.
            if (p.fuse < 0) {
              p.fuse = 1.1;
              events.add(GameEvent('fuse', {}));
            }
            final n = hit;
            final v = p.vel;
            p.vel = (v - n * 2 * (v.dx * n.dx + v.dy * n.dy)) * 0.55;
            p.pos += n * (p.radius + 3);
            events.add(GameEvent('bounce', {}));
            return;
          }
          final speed = p.vel.distance;
          final dmg = p.weapon.damage * (0.7 + 0.6 * (speed / 700).clamp(0.0, 1.0));
          final kb = p.vel.normalizedSafe() * p.weapon.knockback * 300;
          if (p.weapon.radius > 0) {
            explode(p.pos, p.weapon.radius, p.weapon.damage, p.weapon.knockback,
                structDamage: p.weapon.structDamage, owner: p.owner, effect: p.weapon.behavior);
          } else {
            damageCharacter(b, dmg, kb, owner: p.owner);
            events.add(GameEvent('hit', {}));
          }
          p.dead = true;
          return;
        }
        continue;
      }
      if (b.type == BodyType.debris) continue;
      // projectile vs block
      final hit = _circleVsBody(p.pos, p.radius, b);
      if (hit != null) {
        final w = p.weapon;
        // behaviors
        if (w.behavior == 'bouncer' && p.bounces < 4) {
          p.bounces++;
          final n = hit;
          final v = p.vel;
          p.vel = (v - n * 2 * (v.dx * n.dx + v.dy * n.dy)) * 0.82;
          p.pos += n * (p.radius + 2);
          events.add(GameEvent('bounce', {}));
          damageBlock(b, w.damage * w.structDamage * 0.5);
          return;
        }
        if (w.behavior == 'drill' &&
            (b.material == MaterialType.wood || b.material == MaterialType.glass)) {
          // chew through
          damageBlock(b, w.damage * w.structDamage * 1.6);
          p.vel *= 0.86;
          events.add(GameEvent('drill', {}));
          for (int i = 0; i < 4; i++) {
            particles.add(Particle(
              pos: p.pos,
              vel: Offset(rng.range(-90, 90), rng.range(-120, 20)),
              life: 0.4, size: rng.range(3, 7),
              color: _materialSpec(b.material).color,
              gravity: 400,
            ));
          }
          return;
        }
        if (w.behavior == 'grenade') {
          if (p.fuse < 0) {
            p.fuse = 1.1;
            events.add(GameEvent('fuse', {}));
          }
          // bounce off
          final n = hit;
          final v = p.vel;
          p.vel = (v - n * 2 * (v.dx * n.dx + v.dy * n.dy)) * 0.55;
          p.pos += n * (p.radius + 3);
          events.add(GameEvent('bounce', {}));
          return;
        }
        // direct impact damage
        final speed = p.vel.distance;
        damageBlock(b, w.damage * w.structDamage * (0.8 + speed / 900));
        if (!b.isStatic) {
          b.vel += p.vel.normalizedSafe() * w.knockback * 90 / max(b.mass, 0.6);
          b.angularVel += rng.range(-3, 3);
        }
        if (w.radius > 0) {
          explode(p.pos, w.radius, w.damage, w.knockback,
              structDamage: w.structDamage, owner: p.owner, effect: w.behavior);
        } else {
          events.add(GameEvent('impact', {'x': p.pos.dx, 'y': p.pos.dy}));
          screenShake = min(screenShake + 3 + speed / 200, 10);
          for (int i = 0; i < 8; i++) {
            particles.add(Particle(
              pos: p.pos,
              vel: Offset(rng.range(-120, 120), rng.range(-160, 0)),
              life: rng.range(0.3, 0.6),
              size: rng.range(3, 8),
              color: const Color(0xFFFFE3A3),
              gravity: 500,
            ));
          }
        }
        p.dead = true;
        return;
      }
    }
  }

  /// circle vs (possibly rotated) rect body -> returns contact normal or null
  Offset? _circleVsBody(Offset c, double r, PhysBody b) {
    // transform circle into body's local space
    final local = rotate(c - b.pos, -b.angle);
    final hw = b.size.width / 2, hh = b.size.height / 2;
    final closest = Offset(clampd(local.dx, -hw, hw), clampd(local.dy, -hh, hh));
    final diff = local - closest;
    if (diff.distanceSquared > r * r) return null;
    Offset nLocal;
    if (diff.distanceSquared < 0.0001) {
      // center inside: push along smallest penetration axis
      final dx = hw - local.dx.abs();
      final dy = hh - local.dy.abs();
      nLocal = dx < dy ? Offset(local.dx > 0 ? 1 : -1, 0) : Offset(0, local.dy > 0 ? 1 : -1);
    } else {
      nLocal = diff / diff.distance;
    }
    return rotate(nLocal, b.angle);
  }

  /// Resolve body-body collision: only when at least one is dynamic & moving meaningfully
  void _resolvePair(PhysBody a, PhysBody b) {
    if (a.isStatic && b.isStatic) return;
    if (a.type == BodyType.debris && b.type == BodyType.debris) return;
    // skip characters resting vs own raft micro-jitter? keep for knockback fun
    final ra = a.aabb, rb = b.aabb;
    if (!ra.overlaps(rb)) return;

    // use circle-vs-rect style normal from centers (cheap SAT approximation for near-AABB)
    final overlapX = min(ra.right, rb.right) - max(ra.left, rb.left);
    final overlapY = min(ra.bottom, rb.bottom) - max(ra.top, rb.top);
    if (overlapX <= 0 || overlapY <= 0) return;

    // Ignore tiny overlaps between a character and the raft it stands on at rest
    final relVel = (a.vel - b.vel).distance;
    final resting = relVel < 45;

    Offset n;
    double pen;
    if (overlapX < overlapY) {
      n = Offset(a.pos.dx < b.pos.dx ? -1 : 1, 0);
      pen = overlapX;
    } else {
      n = Offset(0, a.pos.dy < b.pos.dy ? -1 : 1);
      pen = overlapY;
    }

    final invA = a.isStatic ? 0.0 : 1.0 / max(a.mass, 0.2);
    final invB = b.isStatic ? 0.0 : 1.0 / max(b.mass, 0.2);
    final invSum = invA + invB;
    if (invSum == 0) return;

    // positional correction (softened for resting contacts to avoid jitter)
    final corr = pen * (resting ? 0.5 : 0.8);
    if (!a.isStatic) a.pos += n * (corr * invA / invSum);
    if (!b.isStatic) b.pos -= n * (corr * invB / invSum);

    // impulse
    final rv = a.vel - b.vel;
    final velAlongN = rv.dx * n.dx + rv.dy * n.dy;
    if (velAlongN < 0) {
      final e = resting ? 0.0 : min(a.restitution, b.restitution);
      final jimp = -(1 + e) * velAlongN / invSum;
      final impulse = n * jimp;
      if (!a.isStatic) a.vel += impulse * invA;
      if (!b.isStatic) b.vel -= impulse * invB;
      // friction
      final tangent = Offset(-n.dy, n.dx);
      final vt = rv.dx * tangent.dx + rv.dy * tangent.dy;
      final mu = (a.friction + b.friction) / 2;
      final jt = (-vt * mu / invSum).clamp(-jimp * 0.6, jimp * 0.6);
      if (!a.isStatic) a.vel += tangent * jt * invA;
      if (!b.isStatic) b.vel -= tangent * jt * invB;

      // impact damage from momentum (falling blocks hurt!)
      final impact = jimp.abs();
      if (impact > 2.2) {
        if (a.type == BodyType.character || b.type == BodyType.character) {
          final c = a.type == BodyType.character ? a : b;
          final other = identical(c, a) ? b : a;
          // Use the character's own pre-collision speed along the contact
          // normal: a normal standing landing (~1-2 char heights) peaks well
          // under 150 px/s and must be harmless, while explosion knockback,
          // long falls and block slams are several hundred px/s.
          final cVelAlongN = (c.vel.dx * n.dx + c.vel.dy * n.dy).abs();
          double dmg = 0;
          if (other.type == BodyType.block && !other.isStatic) {
            // moving block slam: scale with impulse
            dmg = (impact - 6) * 3.0;
          } else if (cVelAlongN > 260) {
            // genuinely hard landing (long fall / thrown by explosion)
            dmg = (cVelAlongN - 260) * 0.09;
          }
          if (dmg > 2) {
            damageCharacter(c, min(dmg, 45), Offset.zero, cause: 'crush');
          }
        }
        // falling blocks damage what they hit & take damage
        if (a.type == BodyType.block && !a.isStatic && impact > 10) damageBlock(a, impact * 1.2);
        if (b.type == BodyType.block && !b.isStatic && impact > 10) damageBlock(b, impact * 1.2);
        // angular fun for characters (bounded by the velocity safety net
        // at the end of step() — repeated small hits, e.g. from being
        // wedged between colliding bodies, can no longer accumulate into
        // unbounded spin)
        for (final c in [a, b]) {
          if (c.type == BodyType.character && !resting && impact > 6) {
            c.angularVel += rng.range(-3, 3) * (impact / 8).clamp(0.2, 2.0);
          }
        }
      }
    }
  }

  /// Elimination cause used when a body falls off the edge of the world,
  /// matching whatever [environment] actually lies down there.
  String get _edgeCause => switch (environment) {
        'sand' => 'buried',
        'lava' => 'lava',
        _ => 'water',
      };

  void splash(Offset pos, double strength) {
    final Color color;
    final double particleGravity;
    final bool glow;
    switch (environment) {
      case 'sand':
        color = const Color(0xFFE8C07D);
        particleGravity = 900; // grit falls back down fast, doesn't arc like water
        glow = false;
        break;
      case 'lava':
        color = const Color(0xFFFF6A3D);
        particleGravity = 500;
        glow = true;
        break;
      default:
        color = const Color(0xFFBFECFF);
        particleGravity = 600;
        glow = false;
    }
    for (int i = 0; i < (strength * 4).clamp(4, 16); i++) {
      particles.add(Particle(
        pos: Offset(pos.dx, waterLevel),
        vel: Offset(rng.range(-70, 70) * strength / 2, rng.range(-220, -60) * strength / 2),
        life: rng.range(0.4, 0.9),
        size: rng.range(3, 8),
        color: color,
        gravity: particleGravity,
        glow: glow,
      ));
    }
  }

  // -------------------------------------------------------------------------
  // Queries
  // -------------------------------------------------------------------------

  List<PhysBody> charactersOf(int player) =>
      bodies.where((b) => b.type == BodyType.character && b.playerIndex == player && !b.dead).toList();

  bool get hasActiveProjectile => projectiles.isNotEmpty;

  /// Is the world settled enough to end the turn?
  bool get settled {
    if (projectiles.isNotEmpty) return false;
    for (final b in bodies) {
      if (b.dead || b.isStatic) continue;
      if (b.type == BodyType.debris) continue;
      if (b.vel.distance > 30 || b.angularVel.abs() > 1.2) return false;
    }
    return true;
  }

  void clearDynamicRemnants() {
    bodies.removeWhere((b) => b.type == BodyType.debris);
    hazards.clear();
  }
}

class _Hazard {
  Offset center;
  double radius;
  double until;
  String kind;
  _Hazard({required this.center, required this.radius, required this.until, required this.kind});
}

class _MatSpec {
  final double hp;
  final double mass;
  final double restitution;
  final double friction;
  final Color color;
  final Color dark;
  const _MatSpec(this.hp, this.mass, this.restitution, this.friction, this.color, this.dark);
}

_MatSpec _materialSpec(MaterialType m) {
  switch (m) {
    case MaterialType.wood:
      return const _MatSpec(55, 0.8, 0.25, 0.6, Color(0xFFB5793B), Color(0xFF8A5726));
    case MaterialType.stone:
      return const _MatSpec(140, 2.2, 0.15, 0.75, Color(0xFF9AA5B1), Color(0xFF6E7987));
    case MaterialType.metal:
      return const _MatSpec(240, 3.0, 0.3, 0.45, Color(0xFF7FB3D9), Color(0xFF527E9E));
    case MaterialType.glass:
      return const _MatSpec(28, 0.6, 0.45, 0.3, Color(0xFFBFECFF), Color(0xFF8CC6E8));
    case MaterialType.raft:
      return const _MatSpec(160, 4.0, 0.2, 0.8, Color(0xFF9C6B30), Color(0xFF6E4A1E));
  }
}

extension on Offset {
  Offset normalizedSafe() => distance < 0.001 ? const Offset(0, -1) : this / distance;
}
