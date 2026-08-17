import 'dart:math';
import 'package:flutter/material.dart';

/// Definition of a weapon type with tactical characteristics.
class WeaponDef {
  final String id;
  final String name;
  final String desc;
  final IconData icon;
  final Color color;
  final double damage;        // base direct hit damage
  final double speed;         // launch speed multiplier
  final double gravity;       // gravity multiplier
  final double radius;        // explosion radius (0 = none)
  final double knockback;
  final double structDamage;  // multiplier vs structures
  final double weight;        // projectile size/weight visual
  final int levelLock;        // player level required
  final String behavior;      // standard|rocket|grenade|cluster|bouncer|drill|shockwave|fire|ice

  const WeaponDef({
    required this.id,
    required this.name,
    required this.desc,
    required this.icon,
    required this.color,
    required this.damage,
    required this.speed,
    this.gravity = 1.0,
    this.radius = 0,
    this.knockback = 1.0,
    this.structDamage = 1.0,
    this.weight = 1.0,
    this.levelLock = 1,
    this.behavior = 'standard',
  });
}

class Weapons {
  Weapons._();

  static const List<WeaponDef> all = [
    WeaponDef(
      id: 'cannon', name: 'Pop Cannon', desc: 'Trusty all-rounder. Balanced everything.',
      icon: Icons.sports_baseball, color: Color(0xFF3B9CFF),
      damage: 34, speed: 1.0, knockback: 1.0,
    ),
    WeaponDef(
      id: 'heavy', name: 'Anchor Lob', desc: 'Slow, heavy anchor. Massive thud on impact.',
      icon: Icons.anchor, color: Color(0xFF5D6D7E),
      damage: 55, speed: 0.75, gravity: 1.35, knockback: 1.6, structDamage: 1.5, weight: 1.6, levelLock: 2,
    ),
    WeaponDef(
      id: 'rocket', name: 'Sardine Rocket', desc: 'Fast rocket, explodes on contact.',
      icon: Icons.rocket_launch, color: Color(0xFFFF4757),
      damage: 28, speed: 1.35, radius: 90, knockback: 1.3, structDamage: 1.2,
    ),
    WeaponDef(
      id: 'grenade', name: 'Bouncy Bomb', desc: 'Bounces around, then BOOM after a short fuse.',
      icon: Icons.sports_tennis, color: Color(0xFF2ED573),
      damage: 30, speed: 0.95, radius: 85, knockback: 1.2, behavior: 'grenade', levelLock: 3,
    ),
    WeaponDef(
      id: 'cluster', name: 'Grape Cluster', desc: 'Splits into 5 mini-bombs mid-air.',
      icon: Icons.bubble_chart, color: Color(0xFF9B59D0),
      damage: 14, speed: 0.95, radius: 55, knockback: 0.8, behavior: 'cluster', levelLock: 4,
    ),
    WeaponDef(
      id: 'bouncer', name: 'Super Ball', desc: 'Ricochets off everything up to 4 times.',
      icon: Icons.sports_basketball, color: Color(0xFFFF8C1A),
      damage: 40, speed: 1.1, knockback: 1.4, behavior: 'bouncer', levelLock: 5,
    ),
    WeaponDef(
      id: 'drill', name: 'Drill Torpedo', desc: 'Chews straight through wood and glass.',
      icon: Icons.hardware, color: Color(0xFF8D6E63),
      damage: 26, speed: 1.25, structDamage: 2.6, behavior: 'drill', levelLock: 6,
    ),
    WeaponDef(
      id: 'shock', name: 'Boom Horn', desc: 'Huge knockback shockwave, light damage. Launch foes into the sea!',
      icon: Icons.campaign, color: Color(0xFFFFD32A),
      damage: 12, speed: 1.15, radius: 130, knockback: 3.2, structDamage: 0.6, behavior: 'shockwave', levelLock: 7,
    ),
    WeaponDef(
      id: 'fire', name: 'Chili Flare', desc: 'Sets the impact zone on fire for a while.',
      icon: Icons.local_fire_department, color: Color(0xFFFF6B35),
      damage: 18, speed: 1.0, radius: 75, knockback: 0.8, behavior: 'fire', levelLock: 8,
    ),
    WeaponDef(
      id: 'ice', name: 'Brain Freeze', desc: 'Freezes structures brittle & slows victims.',
      icon: Icons.ac_unit, color: Color(0xFF7DD8FF),
      damage: 22, speed: 1.05, radius: 70, knockback: 0.9, structDamage: 1.3, behavior: 'ice', levelLock: 9,
    ),
  ];

  static WeaponDef byId(String id) => all.firstWhere((w) => w.id == id, orElse: () => all.first);

  static List<WeaponDef> unlockedAt(int level) =>
      all.where((w) => w.levelLock <= level).toList();
}

/// Deterministic RNG helper for multiplayer sync
class GameRng {
  int _state;
  GameRng(int seed) : _state = seed & 0x7FFFFFFF;

  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
    return (_state >> 8) % max;
  }

  double nextDouble() => nextInt(100000) / 100000.0;

  bool nextBool() => nextInt(2) == 0;

  double range(double a, double b) => a + nextDouble() * (b - a);
}

/// Simple 2D vector-ish helpers
Offset rotate(Offset v, double angle) {
  final c = cos(angle), s = sin(angle);
  return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
}

double clampd(double v, double a, double b) => v < a ? a : (v > b ? b : v);
