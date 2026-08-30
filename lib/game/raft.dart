import 'dart:math';

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
    RaftSize(id: 'small', name: 'Skiff', desc: 'Small target, small crew.', width: 150, crewCapacity: 1, hpBonus: 0),
    RaftSize(id: 'medium', name: 'Cruiser', desc: 'Balanced deck. Two hands aboard.', width: 200, crewCapacity: 2, hpBonus: 10),
    RaftSize(id: 'large', name: 'Barge', desc: 'Wide and sturdy — but easier to hit.', width: 260, crewCapacity: 3, hpBonus: 20),
  ];

  static RaftSize byId(String id) => all.firstWhere((s) => s.id == id, orElse: () => all[1]);
}

/// ---------------------------------------------------------------------------
/// Deck geometry — a walkable height-field instead of one flat slab.
///
/// A raft's deck is a sequence of [DeckSegment]s: raised platforms at
/// different heights joined by ramps, spanning from the rails inward with
/// the flat main deck between them. The profile is *continuous* — ramps
/// always meet the deck at rise 0 — which is the structural-integrity
/// guarantee: a tumbling body can land on a raised stern castle, slide down
/// its ramp and across the main deck, but there is no crack between
/// platforms for it to fall through. The only way off a raft is over a rail.
///
/// Segment coordinates are hull-local (x from the raft centre, y-down like
/// the rest of the game) and canonical: the stern sits at negative x. Rafts
/// that shoot to the right get the canonical layout; mirrored fleets get the
/// profile flipped, so every crew has the high ground *behind* them.
///
/// Heights are stored as *rises above the main deck plane* (0 at the main
/// deck, positive = higher). Physics samples the profile through
/// [DeckProfile.riseAt]; the renderer draws the same segments.
/// ---------------------------------------------------------------------------
class DeckSegment {
  /// Left edge, in hull-local units (x from raft centre, negative aft).
  final double x0;
  final double x1;

  /// Surface rise above the main deck at the segment's left and right edges.
  /// Equal values make a flat platform; different values make a ramp.
  final double rise0;
  final double rise1;

  /// A raised block (crate, castle deck) renders as a solid slab with a
  /// front wall; a ramp (rise0 != rise1) renders as a wedge you can walk.
  final bool isBlock;

  const DeckSegment({
    required this.x0,
    required this.x1,
    required this.rise0,
    required this.rise1,
    this.isBlock = true,
  });

  bool get isFlat => rise0 == rise1;

  /// Surface rise at [x], clamped to the segment's span.
  double riseAt(double x) {
    final t = ((x - x0) / max(1e-6, x1 - x0)).clamp(0.0, 1.0);
    return rise0 + (rise1 - rise0) * t;
  }

  /// The same segment mirrored across the raft's centreline.
  DeckSegment mirrored() =>
      DeckSegment(x0: -x1, x1: -x0, rise0: rise1, rise1: rise0, isBlock: isBlock);
}

/// The deck layout for one hull — a series of platforms of varying shape
/// and height, ordered stern-to-bow, that together tile the whole deck.
class DeckProfile {
  final String hullId;
  final List<DeckSegment> segments;

  const DeckProfile({required this.hullId, required this.segments});

  /// Surface rise at hull-local [x]. Anywhere not covered by a segment is
  /// the flat main deck (rise 0), so the profile is total: every x has a
  /// walkable surface, and adjacent segments share their edge heights, so
  /// the surface never steps or gaps.
  double riseAt(double x) {
    var rise = 0.0;
    for (final s in segments) {
      if (x >= s.x0 && x <= s.x1) {
        rise = max(rise, s.riseAt(x));
      }
    }
    return rise;
  }

  /// True when the profile's segments are ordered and leave no internal
  /// gap wider than the epsilon — the structural-integrity invariant.
  bool get isValid {
    for (int i = 1; i < segments.length; i++) {
      if (segments[i].x0 < segments[i - 1].x1 - 0.01) return false;
    }
    for (final s in segments) {
      if (s.x1 <= s.x0) return false;
    }
    return true;
  }

  /// Builds the deck layout for a hull. [facing] is the raft's shooting
  /// direction: the raised stern work is always placed *behind* the crew,
  /// so the canonical negative-x stern flips for rafts firing left.
  ///
  /// Platforms are kept clear of the crew stations (plus headroom for a
  /// tumbling body) and only built when the remaining deck can fit a ramp
  /// and a usable standing area — otherwise the hull stays a flat slab.
  factory DeckProfile.forLoadout(RaftLoadout loadout, {required int facing}) {
    final half = loadout.deckHalf;

    // Crew keep-out: platforms begin beyond the outermost crew station.
    final outerStation =
        loadout.crewCount <= 1 ? 0.0 : loadout.crewSpacing * (loadout.crewCount - 1) / 2;
    final zoneEdge = max(half * 0.5, outerStation + 14);
    final span = half - zoneEdge;

    // How high each hull builds, and whether it also raises its bow.
    final (sternRise, bowRise) = switch (loadout.hull.id) {
      'log' => (7.0, 0.0),
      'barrel' => (9.0, 5.0),
      'sloop' => (13.0, 0.0),
      'galleon' => (17.0, 12.0),
      _ => (0.0, 0.0), // the pool tube is one cheerful flat slab
    };

    // A platform needs room for a walkable ramp plus a usable standing area.
    const rampLen = 16.0;
    const minTop = 10.0;

    DeckSegment? sternBlock(double rise) {
      if (rise <= 0 || span < rampLen + minTop) return null;
      final topLen = min(span - rampLen, 26.0);
      return DeckSegment(
        x0: -half,
        x1: -(half - topLen),
        rise0: rise,
        rise1: rise,
      );
    }

    DeckSegment? sternRamp(double rise) {
      if (rise <= 0 || span < rampLen + minTop) return null;
      final topLen = min(span - rampLen, 26.0);
      return DeckSegment(
        x0: -(half - topLen),
        x1: -zoneEdge,
        rise0: rise,
        rise1: 0,
        isBlock: false,
      );
    }

    DeckSegment? bowBlock(double rise) {
      if (rise <= 0 || span < rampLen + minTop) return null;
      final topLen = min(span - rampLen, 22.0);
      return DeckSegment(
        x0: half - topLen,
        x1: half,
        rise0: rise,
        rise1: rise,
      );
    }

    DeckSegment? bowRamp(double rise) {
      if (rise <= 0 || span < rampLen + minTop) return null;
      final topLen = min(span - rampLen, 22.0);
      return DeckSegment(
        x0: zoneEdge,
        x1: half - topLen,
        rise0: 0,
        rise1: rise,
        isBlock: false,
      );
    }

    final stern = sternBlock(sternRise);
    final bow = bowBlock(bowRise);
    final segments = <DeckSegment>[
      if (stern != null) stern,
      if (stern != null) sternRamp(sternRise)!,
      if (bow != null) bowRamp(bowRise)!,
      if (bow != null) bow,
    ];

    final canonical = DeckProfile(hullId: loadout.hull.id, segments: segments);
    return facing < 0 ? _mirrored(canonical) : canonical;
  }

  /// Flips the whole layout across the centreline so a left-firing raft has
  /// its high ground aft as well. Mirroring reverses each segment's edges
  /// *and* the list order, keeping the profile sorted stern-to-bow.
  static DeckProfile _mirrored(DeckProfile p) => DeckProfile(
        hullId: p.hullId,
        segments: [
          for (final s in p.segments.reversed) s.mirrored(),
        ],
      );
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

  /// Horizontal gap between crew members standing on the deck. Kept well
  /// inside the hull so even a full crew leaves usable platform space at
  /// bow and stern (see [DeckProfile.forLoadout]).
  double get crewSpacing => crewCount <= 1 ? 0 : (width * 0.5) / (crewCount - 1);

  /// Offset of crew [i] from the raft's centre.
  double crewOffset(int i) => crewCount <= 1 ? 0 : (i - (crewCount - 1) / 2) * crewSpacing;

  /// Half the *walkable* deck: the hull side minus a rail margin. Past this
  /// a crew member is over open water.
  double get deckHalf => width * 0.5 - 10;

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
