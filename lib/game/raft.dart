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
      thickness: 0.26, rounding: 1.0,
    ),
    RaftHull(
      id: 'log', name: 'Log Raft', desc: 'Lashed timber. The classic castaway special.',
      tierRequired: 1, thickness: 0.17, rounding: 0.18,
    ),
    RaftHull(
      id: 'barrel', name: 'Barrel Float', desc: 'Planks over sealed barrels. Rides high.',
      tierRequired: 2, thickness: 0.26, rounding: 0.35,
    ),
    RaftHull(
      id: 'sloop', name: 'Little Sloop', desc: 'A proper hull, and a proper sail.',
      tierRequired: 3, thickness: 0.28, rounding: 0.3, hasMast: true,
    ),
    RaftHull(
      id: 'galleon', name: 'Galleon Deck', desc: 'Captain-grade timber. Nothing sinks it easily.',
      tierRequired: 4, thickness: 0.30, rounding: 0.24, hasMast: true,
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

  /// How the renderer dresses this segment. Physics ignores it entirely.
  final DeckStyle style;

  const DeckSegment({
    required this.x0,
    required this.x1,
    required this.rise0,
    required this.rise1,
    this.isBlock = true,
    this.style = DeckStyle.planks,
  });

  bool get isFlat => rise0 == rise1;

  /// Surface rise at [x], clamped to the segment's span.
  double riseAt(double x) {
    final t = ((x - x0) / max(1e-6, x1 - x0)).clamp(0.0, 1.0);
    return rise0 + (rise1 - rise0) * t;
  }

  /// The same segment mirrored across the raft's centreline.
  DeckSegment mirrored() => DeckSegment(
        x0: -x1,
        x1: -x0,
        rise0: rise1,
        rise1: rise0,
        isBlock: isBlock,
        style: style,
      );
}

/// One tier of a hull's deck plan, before it is turned into segments.
///
/// A plan is written as fractions of the walkable deck so it scales with hull
/// size: [span] is this tier's share of the deck width, [rise] its height
/// above the main deck plane, and [crewWeight] how eagerly crew are posted
/// here when berths are handed out (0 = scenery only, never stood on).
class DeckTier {
  final double span;
  final double rise;
  final int crewWeight;

  /// What the renderer builds here — changes the furniture, not the physics.
  final DeckStyle style;

  const DeckTier({
    required this.span,
    required this.rise,
    this.crewWeight = 1,
    this.style = DeckStyle.planks,
  });
}

/// Visual treatment for a deck tier. The height-field is identical either
/// way; this only picks what the renderer stacks on top.
enum DeckStyle {
  /// Bare planking — the main deck.
  planks,

  /// Lashed timber with visible rope bindings.
  lashed,

  /// Planks over sealed barrels, barrel ends showing at the front wall.
  barrels,

  /// A proper raised castle: solid wall, railing posts along the top.
  castle,

  /// A cargo stack — crates roped down, no railing.
  cargo,
}

/// A crew berth: where one crew member stands, and what they are standing on.
class DeckStation {
  /// Hull-local x of the station.
  final double x;

  /// Rise of the surface underfoot (0 = main deck).
  final double rise;

  const DeckStation({required this.x, required this.rise});
}

/// The deck layout for one hull — a series of platforms of varying shape
/// and height, ordered stern-to-bow, that together tile the whole deck,
/// plus the crew berths posted across them.
class DeckProfile {
  final String hullId;
  final List<DeckSegment> segments;

  /// Where each crew member stands. Built with the segments so a berth is
  /// always on a *flat* patch of some tier — nobody is ever posted mid-ramp,
  /// standing on a slope.
  final List<DeckStation> stations;

  const DeckProfile({
    required this.hullId,
    required this.segments,
    this.stations = const [],
  });

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

  /// Per-hull deck plans, written stern-to-bow as fractions of the walkable
  /// deck. This is what makes the fleet read as five different boats rather
  /// than one slab in five colours: the tube is a single flat ring, the log
  /// raft has a lashed sleeping platform aft, the barrel float steps up
  /// twice over its floats, the sloop carries a proper stern castle, and the
  /// galleon stacks a castle, a working waist and a raised forecastle.
  ///
  /// Spans are normalised on use, so they need only be proportional.
  static const Map<String, List<DeckTier>> _plans = {
    // One cheerful flat ring — the starter raft has nothing to climb.
    'tube': [
      DeckTier(span: 1, rise: 0, crewWeight: 3),
    ],
    // Lashed timber: a low sleeping platform aft, open deck forward.
    'log': [
      DeckTier(span: 0.40, rise: 8, crewWeight: 2, style: DeckStyle.lashed),
      DeckTier(span: 0.60, rise: 0, crewWeight: 2),
    ],
    // Planks over sealed barrels: two steps down from stern to bow.
    'barrel': [
      DeckTier(span: 0.34, rise: 13, crewWeight: 2, style: DeckStyle.barrels),
      DeckTier(span: 0.36, rise: 6, crewWeight: 2, style: DeckStyle.barrels),
      DeckTier(span: 0.30, rise: 0, crewWeight: 1),
    ],
    // A proper little ship: raised stern castle, working deck, and cargo at
    // the bow that is scenery only (crewWeight 0) so nobody stands on it.
    'sloop': [
      DeckTier(span: 0.32, rise: 17, crewWeight: 3, style: DeckStyle.castle),
      DeckTier(span: 0.46, rise: 0, crewWeight: 2),
      DeckTier(span: 0.22, rise: 7, crewWeight: 0, style: DeckStyle.cargo),
    ],
    // Captain's deck: high castle aft, main deck amidships, raised
    // forecastle at the bow — three separate levels to fight from.
    'galleon': [
      DeckTier(span: 0.30, rise: 21, crewWeight: 3, style: DeckStyle.castle),
      DeckTier(span: 0.42, rise: 0, crewWeight: 2),
      DeckTier(span: 0.28, rise: 11, crewWeight: 2, style: DeckStyle.castle),
    ],
  };

  /// Length of the walkable ramp joining two tiers, per unit of height
  /// difference. Shallow enough that a tumbling body slides down rather than
  /// catching on a wall.
  static const double rampPerRise = 1.5;

  /// Smallest flat top a tier may keep once its ramps are cut out of it. A
  /// tier squeezed below this gives up ramp length instead of becoming an
  /// unusable sliver.
  static const double minTopLen = 16.0;

  /// Shoulder-to-shoulder spacing between two crew on the same tier. A body
  /// is about 29 units across, so anything tighter draws them overlapping.
  static const double minBerthGap = 42.0;

  /// How far a berth stays clear of the deck edge.
  ///
  /// Tiers run right out to the rails, so without this the outermost crew
  /// member is posted a few units from open water — and a heavy hit that
  /// should merely knock them down slides them straight over the side. Being
  /// swept overboard is meant to be an occasional disaster, not the default
  /// outcome of standing where the layout put you.
  static const double railMargin = 26.0;

  /// Half a crew member's width. Berths stay this far inside a flat top so
  /// nobody stands with a foot on the ramp beside them.
  static const double bodyHalf = 9.0;

  /// Builds the deck layout and crew berths for a hull. [facing] is the
  /// raft's shooting direction: the raised stern work always sits *behind*
  /// the crew, so the canonical negative-x stern flips for rafts firing left.
  ///
  /// The profile is continuous by construction — every tier's flat top is
  /// joined to the next by a ramp meeting both at their exact heights — which
  /// is the structural-integrity guarantee: a tumbling body can slide from
  /// the castle down to the main deck without ever finding a crack.
  factory DeckProfile.forLoadout(RaftLoadout loadout, {required int facing}) {
    final half = loadout.deckHalf;
    final deck = half * 2;
    final plan = _plans[loadout.hull.id] ?? _plans['tube']!;

    // 1. Lay the tiers out edge to edge across the deck, stern to bow.
    final spanTotal = plan.fold<double>(0, (s, t) => s + t.span);
    final edges = <double>[-half];
    for (final t in plan) {
      edges.add(edges.last + deck * (t.span / spanTotal));
    }
    edges[edges.length - 1] = half; // kill accumulated rounding

    // 2. Cut a ramp out of the *taller* side of every internal boundary, then
    //    emit the flat top that remains. Hosting the ramp on the raised tier
    //    reads as a stair cut into the structure rather than a wedge leaning
    //    against it, and it keeps the lower deck fully walkable.
    final segments = <DeckSegment>[];
    final tops = <int, ({double x0, double x1, double rise})>{};

    for (int i = 0; i < plan.length; i++) {
      var x0 = edges[i];
      final x1 = edges[i + 1];
      final rise = plan[i].rise;

      double cutFor(int other) {
        if (other < 0 || other >= plan.length) return 0;
        final drop = (plan[other].rise - rise).abs();
        if (drop <= 0.01) return 0;
        if (plan[other].rise > rise) return 0; // the taller tier hosts it
        return min(drop * rampPerRise, (x1 - x0) * 0.4);
      }

      final cutL = cutFor(i - 1);
      final cutR = cutFor(i + 1);
      // On a small hull the ramps can eat the whole tier; give up ramp length
      // rather than the standing area, so the top never vanishes.
      final shrink = ((x1 - x0) - cutL - cutR) < minTopLen && (cutL + cutR) > 0
          ? (((x1 - x0) - minTopLen) / (cutL + cutR)).clamp(0.0, 1.0)
          : 1.0;
      final rampL = cutL * shrink;
      final rampR = cutR * shrink;

      if (rampL > 0) {
        segments.add(DeckSegment(
          x0: x0,
          x1: x0 + rampL,
          rise0: plan[i - 1].rise,
          rise1: rise,
          isBlock: false,
          style: plan[i].style,
        ));
        x0 += rampL;
      }
      final topX1 = x1 - rampR;
      if (topX1 > x0) {
        segments.add(DeckSegment(
          x0: x0,
          x1: topX1,
          rise0: rise,
          rise1: rise,
          isBlock: rise > 0,
          style: plan[i].style,
        ));
        tops[i] = (x0: x0, x1: topX1, rise: rise);
      }
      if (rampR > 0) {
        segments.add(DeckSegment(
          x0: topX1,
          x1: x1,
          rise0: rise,
          rise1: plan[i + 1].rise,
          isBlock: false,
          style: plan[i].style,
        ));
      }
    }

    // 3. Post the crew across the tiers that want them, so a galleon crew
    //    genuinely fights from the castle, the waist and the forecastle
    //    rather than lining up along one plank.
    final stations = _berths(loadout.crewCount, plan, tops, half);

    final canonical = DeckProfile(
      hullId: loadout.hull.id,
      segments: segments,
      stations: stations,
    );
    return facing < 0 ? _mirrored(canonical) : canonical;
  }

  /// Hands [count] berths out across the tiers that accept crew, then spreads
  /// each tier's share along its flat top.
  static List<DeckStation> _berths(
    int count,
    List<DeckTier> plan,
    Map<int, ({double x0, double x1, double rise})> tops,
    double deckHalf,
  ) {
    if (count <= 0) return const [];

    final usable = <int>[
      for (int i = 0; i < plan.length; i++)
        if (plan[i].crewWeight > 0 && tops.containsKey(i)) i,
    ];
    if (usable.isEmpty) {
      // Every tier is scenery, or all were squeezed out: fall back to the
      // middle of the widest surface there is.
      if (tops.isEmpty) {
        return [for (int i = 0; i < count; i++) const DeckStation(x: 0, rise: 0)];
      }
      final t = tops.values.reduce((a, b) => (a.x1 - a.x0) >= (b.x1 - b.x0) ? a : b);
      return [
        for (int i = 0; i < count; i++)
          DeckStation(x: (t.x0 + t.x1) / 2, rise: t.rise),
      ];
    }

    // How many bodies each tier can actually hold shoulder to shoulder. A
    // narrow stern castle that is handed three crew draws them standing
    // inside one another, so capacity is a hard limit on the deal below.
    int capacityOf(int i) {
      final t = tops[i]!;
      return max(1, ((t.x1 - t.x0) / minBerthGap).floor());
    }

    // Deal one berth at a time to whichever tier is most under-served for its
    // weight, so a 2-crew galleon takes the castle and the waist while a
    // 4-crew galleon doubles up. Tiers drop out of the running once full.
    final assigned = <int, int>{for (final i in usable) i: 0};
    for (int n = 0; n < count; n++) {
      var best = -1;
      var bestScore = double.negativeInfinity;
      for (final i in usable) {
        if (assigned[i]! >= capacityOf(i)) continue;
        final score = plan[i].crewWeight - assigned[i]! * 1.0;
        if (score > bestScore) {
          bestScore = score;
          best = i;
        }
      }
      // Every tier full: put the overflow on the roomiest one rather than
      // dropping a crew member on the floor.
      if (best < 0) {
        best = usable.reduce((a, b) =>
            (tops[a]!.x1 - tops[a]!.x0) >= (tops[b]!.x1 - tops[b]!.x0) ? a : b);
      }
      assigned[best] = assigned[best]! + 1;
    }

    // Spread each tier's berths along its top, keeping a body's width clear
    // of the tier edges.
    final out = <DeckStation>[];
    for (final i in usable) {
      final n = assigned[i]!;
      if (n == 0) continue;
      final t = tops[i]!;
      // Usable band on this tier: inside its own edges, and clear of the
      // ship's rails — a tier runs right out to the deck edge, and a crew
      // member posted there goes over the side on any solid hit.
      // The inset is a body half-width: a berth any closer to the flat top's
      // edge would have one boot hanging over the ramp beside it.
      var x0 = max(t.x0 + bodyHalf, -deckHalf + railMargin);
      var x1 = min(t.x1 - bodyHalf, deckHalf - railMargin);
      if (x1 < x0) {
        // The tier is entirely inside the rail margin (a tiny hull): fall
        // back to its centre rather than inverting the band.
        final mid = (t.x0 + t.x1) / 2;
        x0 = mid;
        x1 = mid;
      }

      if (n == 1) {
        out.add(DeckStation(x: (x0 + x1) / 2, rise: t.rise));
        continue;
      }
      // Space them a full body apart about the band's centre, shrinking the
      // spread only as far as the band forces — overlapping crew look far
      // worse than a slightly tighter line.
      final span = min(minBerthGap * (n - 1), x1 - x0);
      final lo = (x0 + x1) / 2 - span / 2;
      for (int k = 0; k < n; k++) {
        out.add(DeckStation(x: lo + span * k / (n - 1), rise: t.rise));
      }
    }
    out.sort((a, b) => a.x.compareTo(b.x));
    return out;
  }

  /// Flips the whole layout across the centreline so a left-firing raft has
  /// its high ground aft as well. Mirroring reverses each segment's edges
  /// *and* the list order, keeping the profile sorted stern-to-bow.
  static DeckProfile _mirrored(DeckProfile p) => DeckProfile(
        hullId: p.hullId,
        segments: [
          for (final s in p.segments.reversed) s.mirrored(),
        ],
        stations: [
          for (final s in p.stations.reversed) DeckStation(x: -s.x, rise: s.rise),
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

  /// How tall the hull block sits in the water, in world units.
  ///
  /// Deliberately *not* a flat fraction of [width]: [RaftHull.thickness] is a
  /// proportion, so scaling it straight off the beam made the widest hulls
  /// enormous — a 260-wide galleon came out over a hundred units tall, a
  /// slab taller than the crew standing on it, which read as a brick rather
  /// than a boat. Anchoring on a reference beam and letting size nudge it
  /// keeps a barge visibly bigger than a skiff without the hull swallowing
  /// the deck structure that is supposed to be the interesting part.
  static const double _refWidth = 200.0;
  double get hullHeight =>
      hull.thickness * _refWidth * (0.85 + 0.15 * width / _refWidth);

  /// Y of the deck surface relative to the waterline (negative = above it).
  /// The single definition every drawing and physics path shares.
  double get deckRise => hullHeight * 0.55;

  /// The canonical (right-facing) deck layout for this loadout, including
  /// where its crew are posted. In a battle a [Raft] builds its own copy
  /// oriented to its facing; this one serves callers that have a loadout but
  /// no raft — the customisation preview, and the offsets below.
  DeckProfile get profile => DeckProfile.forLoadout(this, facing: 1);

  /// Where crew [i] stands, as an offset from the raft's centre.
  ///
  /// Berths come from the hull's deck plan, so they follow the structure:
  /// a galleon crew is spread over its castle, waist and forecastle rather
  /// than evenly along a line. Falls back to even spacing only if a plan
  /// somehow posts nobody.
  double crewOffset(int i) {
    final st = profile.stations;
    if (st.isEmpty) return crewCount <= 1 ? 0 : (i - (crewCount - 1) / 2) * crewSpacing;
    return st[i.clamp(0, st.length - 1)].x;
  }

  /// Height of the surface crew [i] stands on, above the main deck plane.
  double crewRise(int i) {
    final st = profile.stations;
    if (st.isEmpty) return 0;
    return st[i.clamp(0, st.length - 1)].rise;
  }

  /// Even fallback spacing, used only when a hull plan yields no berths.
  double get crewSpacing => crewCount <= 1 ? 0 : (width * 0.5) / (crewCount - 1);

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
