import 'package:flutter/material.dart';

/// ---------------------------------------------------------------------------
/// Raft customization + progression.
///
/// A raft is described by three independent choices:
///   * [RaftHull]  — silhouette (tube, log, barrel, sloop, galleon)
///   * [RaftSize]  — small / medium / large: hull width, crew capacity, HP
///   * colour      — an index into [raftColors]
///
/// Campaign play upgrades the raft through [RaftTier]s, which raise the crew
/// cap and HP and unlock better hulls. Local multiplayer instead lets each
/// seat pick hull/size/colour freely, so two players on one device can tell
/// their rafts apart at a glance.
/// ---------------------------------------------------------------------------

class RaftHull {
  final String id;
  final String name;
  final String desc;

  /// Campaign raft tier this hull becomes available at (0 = always).
  final int tierRequired;

  /// Vertical thickness of the hull as a fraction of its width — a tube is
  /// chunky and round, a galleon deck is long and comparatively shallow.
  final double thickness;

  /// Corner rounding as a fraction of hull height. 1.0 = fully rounded
  /// capsule (the inflatable tube), 0.15 = squared-off timber.
  final double rounding;

  /// Draws a mast + sail behind the crew.
  final bool hasMast;

  const RaftHull({
    required this.id,
    required this.name,
    required this.desc,
    this.tierRequired = 0,
    this.thickness = 0.26,
    this.rounding = 1.0,
    this.hasMast = false,
  });

  static const List<RaftHull> all = [
    RaftHull(
      id: 'tube', name: 'Pool Tube', desc: 'Bouncy inflatable ring. Light and cheerful.',
      thickness: 0.27, rounding: 1.0,
    ),
    RaftHull(
      id: 'log', name: 'Log Raft', desc: 'Lashed timber. The classic castaway special.',
      tierRequired: 1, thickness: 0.19, rounding: 0.18,
    ),
    RaftHull(
      id: 'barrel', name: 'Barrel Float', desc: 'Planks over sealed barrels. Rides high.',
      tierRequired: 2, thickness: 0.3, rounding: 0.35,
    ),
    RaftHull(
      id: 'sloop', name: 'Little Sloop', desc: 'A proper hull, and a proper sail.',
      tierRequired: 3, thickness: 0.36, rounding: 0.3, hasMast: true,
    ),
    RaftHull(
      id: 'galleon', name: 'Galleon Deck', desc: 'Captain-grade timber. Nothing sinks it easily.',
      tierRequired: 4, thickness: 0.42, rounding: 0.24, hasMast: true,
    ),
  ];

  static RaftHull byId(String id) => all.firstWhere((h) => h.id == id, orElse: () => all.first);

  /// Hulls the player may pick at campaign raft [tier].
  static List<RaftHull> unlockedAt(int tier) => all.where((h) => h.tierRequired <= tier).toList();
}

class RaftSize {
  final String id;
  final String name;
  final String desc;

  /// Hull width in world units (the design's coordinate space).
  final double width;

  /// How many crew this hull can carry.
  final int crewCapacity;

  /// Added to each crew member's starting HP.
  final double hpBonus;

  const RaftSize({
    required this.id,
    required this.name,
    required this.desc,
    required this.width,
    required this.crewCapacity,
    required this.hpBonus,
  });

  static const List<RaftSize> all = [
    RaftSize(id: 'small', name: 'Skiff', desc: 'Small target, small crew.', width: 104, crewCapacity: 1, hpBonus: 0),
    RaftSize(id: 'medium', name: 'Cruiser', desc: 'Balanced deck. Two hands aboard.', width: 132, crewCapacity: 2, hpBonus: 10),
    RaftSize(id: 'large', name: 'Barge', desc: 'Wide and sturdy — but easier to hit.', width: 168, crewCapacity: 3, hpBonus: 20),
  ];

  static RaftSize byId(String id) => all.firstWhere((s) => s.id == id, orElse: () => all[1]);
}

/// Selectable raft colours. Kept clearly distinct from one another so two
/// local players (and the enemy fleet) never read as the same raft.
const List<Color> raftColors = [
  Color(0xFFFF8A3D), // orange (the design's player tube)
  Color(0xFF3F7FC9), // blue
  Color(0xFF4EC06A), // green
  Color(0xFFFFD34D), // yellow
  Color(0xFFC05A86), // rose
  Color(0xFF8A5FB0), // violet
  Color(0xFF2C8B99), // teal
  Color(0xFF8A5F35), // timber brown
];

Color raftColorAt(int index) => raftColors[index % raftColors.length];

/// A campaign raft-upgrade step. Tier 0 is the starting raft: chapter one
/// begins with a **two-person crew**, per the design brief.
class RaftTier {
  final int tier;
  final String name;
  final int crewCapacity;
  final double hpBonus;
  final int cost;
  final int starsRequired;

  const RaftTier({
    required this.tier,
    required this.name,
    required this.crewCapacity,
    required this.hpBonus,
    required this.cost,
    required this.starsRequired,
  });
}

class RaftTiers {
  RaftTiers._();

  /// Index == tier. `all[0]` is what a brand-new save starts with, so it has
  /// no cost/star requirement — the purchasable steps are `all[1..]`.
  static const List<RaftTier> all = [
    RaftTier(tier: 0, name: 'Starter Raft', crewCapacity: 2, hpBonus: 0, cost: 0, starsRequired: 0),
    RaftTier(tier: 1, name: 'Reinforced Raft', crewCapacity: 2, hpBonus: 20, cost: 60, starsRequired: 0),
    RaftTier(tier: 2, name: 'Third Berth', crewCapacity: 3, hpBonus: 30, cost: 140, starsRequired: 6),
    RaftTier(tier: 3, name: 'Rigged Raft', crewCapacity: 3, hpBonus: 45, cost: 240, starsRequired: 12),
    RaftTier(tier: 4, name: "Captain's Deck", crewCapacity: 4, hpBonus: 60, cost: 380, starsRequired: 20),
  ];

  static int get maxTier => all.length - 1;

  static RaftTier at(int tier) => all[tier.clamp(0, maxTier)];

  /// The next purchasable tier, or null when already maxed.
  static RaftTier? next(int currentTier) => currentTier >= maxTier ? null : all[currentTier + 1];
}

/// Everything needed to build and draw one player's raft in a battle.
/// Assembled from save data (campaign) or from the match-setup pickers
/// (local multiplayer), so the battle layer never has to know which.
class RaftLoadout {
  final RaftHull hull;
  final RaftSize size;
  final int colorIndex;

  /// How many crew actually board this raft — the lower of the hull size's
  /// capacity and (for campaign) the raft tier's capacity.
  final int crewCount;

  /// Added to every crew member's starting HP.
  final double hpBonus;

  const RaftLoadout({
    required this.hull,
    required this.size,
    required this.colorIndex,
    required this.crewCount,
    this.hpBonus = 0,
  });

  Color get color => raftColorAt(colorIndex);

  double get width => size.width;

  /// Horizontal gap between crew members standing on the deck.
  double get crewSpacing => crewCount <= 1 ? 0 : (width * 0.62) / (crewCount - 1);

  /// Offset of crew [i] from the raft's centre.
  double crewOffset(int i) => crewCount <= 1 ? 0 : (i - (crewCount - 1) / 2) * crewSpacing;

  /// The player's own raft as configured by campaign progression.
  factory RaftLoadout.fromCampaign({
    required String hullId,
    required int colorIndex,
    required int raftTier,
  }) {
    final tier = RaftTiers.at(raftTier);
    // Campaign crew capacity comes from the tier; pick the size whose deck
    // is wide enough to seat them so the raft visually matches its crew.
    final size = RaftSize.all.firstWhere(
      (s) => s.crewCapacity >= tier.crewCapacity,
      orElse: () => RaftSize.all.last,
    );
    return RaftLoadout(
      hull: RaftHull.byId(hullId),
      size: size,
      colorIndex: colorIndex,
      crewCount: tier.crewCapacity,
      hpBonus: tier.hpBonus,
    );
  }

  /// A raft configured directly by the local-multiplayer pickers.
  ///
  /// [hpBonus] defaults to the size's own bonus — the deliberate trade of a
  /// bigger, tougher deck for a bigger target. Pass 0 for opponents whose HP
  /// is dictated elsewhere (campaign levels set enemy HP explicitly, and
  /// letting the hull silently add to it would make those numbers a lie).
  factory RaftLoadout.custom({
    required String hullId,
    required String sizeId,
    required int colorIndex,
    double? hpBonus,
  }) {
    final size = RaftSize.byId(sizeId);
    return RaftLoadout(
      hull: RaftHull.byId(hullId),
      size: size,
      colorIndex: colorIndex,
      crewCount: size.crewCapacity,
      hpBonus: hpBonus ?? size.hpBonus,
    );
  }
}
