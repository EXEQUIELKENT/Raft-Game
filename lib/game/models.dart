import 'dart:math';
import 'package:flutter/material.dart';

/// What a hit leaves behind on the crew member it landed on.
///
/// Bosses are the reason this exists. A boss that simply had more HP and hit
/// harder would be the same fight with bigger numbers; what makes one *feel*
/// different is that it takes something away from you for a turn — your
/// power, your aim line, or the turn itself. Each effect is deliberately a
/// single turn and telegraphed by the projectile that applies it, so it reads
/// as "the tar gun did that" and never as the game misbehaving.
///
/// Balance rule for every boss round: a projectile that applies a status
/// deals noticeably LESS direct damage than an ordinary round of its weight.
/// The boss is buying disruption with damage, not getting both.
enum StatusEffect {
  /// Chilled stiff: the next shot launches at reduced power. Recoverable by
  /// simply aiming higher, so it costs a shot rather than a turn.
  chilled,

  /// Tarred: heavy and sluggish. Reduced power AND the body resists being
  /// knocked around — a genuine mixed blessing near a rail.
  tarred,

  /// Dazed: the trajectory preview is gone for a turn. Nothing is taken from
  /// the shot itself; the player just has to aim by eye, which is the
  /// original game underneath the aim assist.
  dazed,

  /// Snared: the crew member misses their next turn entirely. The harshest
  /// one, so it is rare, short and only ever hits one body.
  snared,
}

extension StatusEffectInfo on StatusEffect {
  String get label => switch (this) {
        StatusEffect.chilled => 'CHILLED',
        StatusEffect.tarred => 'TARRED',
        StatusEffect.dazed => 'DAZED',
        StatusEffect.snared => 'SNARED',
      };

  /// Short line shown when it lands, in the crew member's speech bubble.
  String get bubble => switch (this) {
        StatusEffect.chilled => 'B-brrr!',
        StatusEffect.tarred => 'Ugh, sticky!',
        StatusEffect.dazed => 'Wh-which way?',
        StatusEffect.snared => 'Tangled!',
      };

  Color get tint => switch (this) {
        StatusEffect.chilled => const Color(0xFF9FE3F0),
        StatusEffect.tarred => const Color(0xFF3A3238),
        StatusEffect.dazed => const Color(0xFFE8C84D),
        StatusEffect.snared => const Color(0xFF8FBF6A),
      };

  /// Multiplier applied to a launch while this is active. 1.0 = no change.
  double get powerScale => switch (this) {
        StatusEffect.chilled => 0.78,
        StatusEffect.tarred => 0.7,
        StatusEffect.dazed => 1.0,
        StatusEffect.snared => 1.0,
      };

  /// How much of an impact's knockback the body still takes.
  double get knockScale => switch (this) {
        StatusEffect.tarred => 0.45,
        _ => 1.0,
      };
}

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

  /// What a direct hit inflicts beyond damage. Boss ordnance only.
  final StatusEffect? status;

  /// How many of the victim's turns the status lasts.
  final int statusTurns;

  /// Projectile look: 'ball' (the default round), 'shard', 'blob', 'net',
  /// 'ember' or 'disc'. Purely visual, but it is what tells the player which
  /// boss round is inbound while it is still in the air — which is the only
  /// warning they get.
  final String projectile;

  /// True for a boss's signature round: never bought, never in the HUD, and
  /// excluded from the player's ammo map.
  final bool bossOnly;

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
    this.status,
    this.statusTurns = 1,
    this.projectile = 'ball',
    this.bossOnly = false,
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

  /// Boss signature rounds. Deliberately NOT in [all]: they are never bought,
  /// never shown in the HUD or the shop, and never enter the player's ammo
  /// map — a boss brings its own gun and the player never gets to keep it.
  ///
  /// Every one of these trades damage for disruption. Compare each against
  /// the ordinary round of similar weight in [all] and it hits for less; what
  /// it buys instead is a turn where the player is short of power, aim or
  /// tempo. That trade is the whole balance argument for bosses being harder
  /// without being unfair — nothing here can burst a full-health crew member
  /// down, and nothing chains, because every status is one turn long.
  static const List<WeaponDef> boss = [
    WeaponDef(
      id: 'frost', name: 'Frost Shard', desc: 'Chills the crew stiff for a turn.',
      icon: Icons.ac_unit, color: Color(0xFF9FE3F0),
      damage: 22, speed: 1.05, splash: 55, weight: 0.95,
      status: StatusEffect.chilled, projectile: 'shard', bossOnly: true,
    ),
    WeaponDef(
      id: 'tarpot', name: 'Tar Pot', desc: 'Sticky, heavy, and hard to shake off.',
      icon: Icons.opacity, color: Color(0xFF3A3238),
      damage: 26, speed: 0.9, splash: 80, weight: 1.3,
      status: StatusEffect.tarred, projectile: 'blob', bossOnly: true,
    ),
    WeaponDef(
      id: 'sandburst', name: 'Sand Burst', desc: 'Blinds the spotter — no arc next turn.',
      icon: Icons.grain, color: Color(0xFFE8C84D),
      damage: 18, speed: 1.1, splash: 110, weight: 0.9,
      status: StatusEffect.dazed, projectile: 'ember', bossOnly: true,
    ),
    WeaponDef(
      id: 'netshot', name: 'Net Shot', desc: 'Tangles one deckhand for a turn.',
      icon: Icons.grid_on, color: Color(0xFF8FBF6A),
      damage: 14, speed: 1.0, splash: 0, weight: 1.05,
      status: StatusEffect.snared, projectile: 'net', bossOnly: true,
    ),
    WeaponDef(
      id: 'emberlob', name: 'Ember Lob', desc: 'Burns hot and scatters wide.',
      icon: Icons.local_fire_department, color: Color(0xFFE2541E),
      damage: 34, speed: 0.95, splash: 120, weight: 1.2,
      projectile: 'ember', bossOnly: true,
    ),
    WeaponDef(
      id: 'sawdisc', name: 'Saw Disc', desc: 'Skips off the deck and keeps going.',
      icon: Icons.album, color: Color(0xFFB8BCC0),
      damage: 30, speed: 1.15, splash: 0, weight: 1.0,
      projectile: 'disc', bossOnly: true,
    ),
  ];

  /// Everything that can be in flight, player ordnance and boss rounds alike.
  static List<WeaponDef> get everything => [...all, ...boss];

  static WeaponDef byId(String id) =>
      everything.firstWhere((w) => w.id == id, orElse: () => all.first);

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
