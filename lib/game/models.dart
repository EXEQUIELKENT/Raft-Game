import 'dart:math';
import 'package:flutter/material.dart';

/// A throwable/launchable. Ported to the design's model: one infinite basic
/// lob plus heavier limited-ammo ordnance, shown in the HUD as `×∞ / ×2 / ×1`.
class WeaponDef {
  final String id;
  final String name;
  final String desc;
  final IconData icon;
  final Color color;

  /// Direct-hit damage.
  final double damage;

  /// Launch speed multiplier applied on top of the pull power.
  final double speed;

  /// Splash radius in world units. 0 = direct hit only.
  final double splash;

  /// Visual size multiplier for the projectile.
  final double weight;

  /// True for the starter weapon — never consumes ammo, always available.
  final bool infinite;

  /// Rounds carried into a battle when the player owns this weapon, and how
  /// many one shop purchase adds.
  final int startAmmo;
  final int packSize;

  /// Doubloon cost of one pack in the campaign shop.
  final int packCost;

  /// Player level (XP progression) required before this appears at all.
  final int levelLock;

  const WeaponDef({
    required this.id,
    required this.name,
    required this.desc,
    required this.icon,
    required this.color,
    required this.damage,
    this.speed = 1.0,
    this.splash = 0,
    this.weight = 1.0,
    this.infinite = false,
    this.startAmmo = 0,
    this.packSize = 3,
    this.packCost = 150,
    this.levelLock = 1,
  });

  /// Short label used on the HUD weapon chips.
  String get chipLabel => name.toUpperCase();
}

class Weapons {
  Weapons._();

  /// Ordered from starter to heaviest — the HUD renders them in this order.
  static const List<WeaponDef> all = [
    WeaponDef(
      id: 'tennis', name: 'Tennis', desc: 'Endless supply of fuzzy yellow menace.',
      icon: Icons.sports_tennis, color: Color(0xFFE8E34D),
      damage: 20, speed: 1.0, weight: 1.0, infinite: true,
    ),
    WeaponDef(
      id: 'grenade', name: 'Grenade', desc: 'Heavier arc, shorter reach, real splash.',
      icon: Icons.egg, color: Color(0xFF3F5A44),
      damage: 38, speed: 0.95, splash: 70, weight: 1.15,
      startAmmo: 2, packSize: 3, packCost: 150, levelLock: 1,
    ),
    WeaponDef(
      id: 'bomb', name: 'Bomb', desc: 'Splits a log raft in one hit.',
      icon: Icons.dangerous, color: Color(0xFFB8BCC0),
      damage: 58, speed: 0.88, splash: 95, weight: 1.35,
      startAmmo: 1, packSize: 1, packCost: 260, levelLock: 2,
    ),
    WeaponDef(
      id: 'cluster', name: 'Cluster', desc: 'Bursts wide — good against a packed deck.',
      icon: Icons.bubble_chart, color: Color(0xFF8A5FB0),
      damage: 26, speed: 1.0, splash: 130, weight: 1.1,
      startAmmo: 0, packSize: 2, packCost: 300, levelLock: 4,
    ),
    WeaponDef(
      id: 'anchor', name: 'Anchor', desc: 'Slow, brutal, and very hard to argue with.',
      icon: Icons.anchor, color: Color(0xFF5D6D7E),
      damage: 74, speed: 0.78, splash: 60, weight: 1.6,
      startAmmo: 0, packSize: 1, packCost: 420, levelLock: 6,
    ),
  ];

  static WeaponDef byId(String id) => all.firstWhere((w) => w.id == id, orElse: () => all.first);

  static WeaponDef get starter => all.first;

  static List<WeaponDef> unlockedAt(int level) => all.where((w) => w.levelLock <= level).toList();

  /// Weapons that can be bought/stocked (everything except the starter).
  static List<WeaponDef> get purchasable => all.where((w) => !w.infinite).toList();
}

/// Deterministic RNG so a given seed always produces the same battle —
/// used for enemy aim jitter and decoration placement.
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

Offset rotate(Offset v, double angle) {
  final c = cos(angle), s = sin(angle);
  return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
}

double clampd(double v, double a, double b) => v < a ? a : (v > b ? b : v);
