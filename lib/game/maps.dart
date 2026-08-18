import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart' hide MaterialType;
import 'models.dart';
import 'physics.dart';

/// Building piece catalogue
class PieceDef {
  final String id;
  final String name;
  final IconData icon;
  final MaterialType material;
  final Size size;
  final String desc;

  const PieceDef(this.id, this.name, this.icon, this.material, this.size, this.desc);

  static final List<PieceDef> catalogue = [
    const PieceDef('wood_wall', 'Wood Wall', Icons.fence, MaterialType.wood, Size(18, 90), 'Light & cheap cover'),
    const PieceDef('wood_plank', 'Wood Plank', Icons.carpenter, MaterialType.wood, Size(90, 16), 'Walkway / roof'),
    const PieceDef('stone_block', 'Stone Block', Icons.square, MaterialType.stone, Size(46, 46), 'Heavy & tough'),
    const PieceDef('metal_wall', 'Metal Wall', Icons.shield, MaterialType.metal, Size(16, 80), 'Very strong defense'),
    const PieceDef('metal_plate', 'Metal Plate', Icons.table_bar, MaterialType.metal, Size(80, 14), 'Strong platform'),
    const PieceDef('glass_panel', 'Glass Panel', Icons.window, MaterialType.glass, Size(60, 40), 'Fragile but sneaky'),
    const PieceDef('tower', 'Lookout Tower', Icons.cell_tower, MaterialType.wood, Size(30, 120), 'Get the high ground'),
  ];
}

/// Named procedural terrain silhouettes. Each [MapDef] lists the patterns
/// that fit its theme; one is picked deterministically from the match seed
/// (via [PhysicsWorld.rng], so host & client always agree) each time the
/// map is built, giving every round a different — but always playable —
/// layout while keeping the map's recognizable identity.
enum TerrainPattern {
  flat,
  rollingHills,
  centralMountain,
  splitIslands,
  unevenCliffs,
  narrowPlatforms,
  valley,
  randomIslands,
}

class MapDef {
  final String id;
  final String name;
  final String tagline;
  final IconData icon;
  final List<Color> sky;
  final double windBase;
  final String hazard; // none | waves | rocks | barrels | lava | traffic
  final int levelLock;
  final List<TerrainPattern> patterns;

  const MapDef({
    required this.id,
    required this.name,
    required this.tagline,
    required this.icon,
    required this.sky,
    this.windBase = 0,
    this.hazard = 'none',
    this.levelLock = 1,
    this.patterns = const [TerrainPattern.flat],
  });

  /// What the void beyond the edge of the play area actually is: water for
  /// most maps, but sand for the desert and lava for the volcano. Drives
  /// both the renderer (background/foreground art) and the physics world
  /// (splash effect + elimination cause when a body falls off the edge).
  String get terrain {
    switch (id) {
      case 'desert':
        return 'sand';
      case 'volcano':
        return 'lava';
      default:
        return 'water';
    }
  }
}

class GameMaps {
  GameMaps._();

  static const List<MapDef> all = [
    MapDef(
      id: 'ocean', name: 'Ocean Drift', tagline: 'Classic raft warfare on rolling waves',
      icon: Icons.sailing, sky: [Color(0xFFFF9D5C), Color(0xFFFF5E8A), Color(0xFF7B4FB3)],
      windBase: 0.15, hazard: 'waves',
      patterns: [TerrainPattern.rollingHills, TerrainPattern.randomIslands, TerrainPattern.flat, TerrainPattern.splitIslands],
    ),
    MapDef(
      id: 'island', name: 'Coconut Cove', tagline: 'Sandy beach with palm towers',
      icon: Icons.beach_access, sky: [Color(0xFF4FC3F7), Color(0xFF29B6F6), Color(0xFF0288D1)],
      hazard: 'none',
      patterns: [TerrainPattern.splitIslands, TerrainPattern.flat, TerrainPattern.randomIslands],
    ),
    MapDef(
      id: 'mountains', name: 'Frosty Peaks', tagline: 'Icy cliffs, tumbling rocks',
      icon: Icons.landscape, sky: [Color(0xFFB39DDB), Color(0xFF7E57C2), Color(0xFF4527A0)],
      windBase: 0.25, hazard: 'rocks', levelLock: 2,
      patterns: [TerrainPattern.centralMountain, TerrainPattern.unevenCliffs, TerrainPattern.narrowPlatforms],
    ),
    MapDef(
      id: 'desert', name: 'Dusty Dunes', tagline: 'Explosive barrels everywhere!',
      icon: Icons.wb_sunny, sky: [Color(0xFFFFE082), Color(0xFFFFB300), Color(0xFFFF6F00)],
      windBase: 0.2, hazard: 'barrels', levelLock: 3,
      patterns: [TerrainPattern.valley, TerrainPattern.flat, TerrainPattern.splitIslands],
    ),
    MapDef(
      id: 'volcano', name: 'Mount Sizzle', tagline: 'Lava pools & falling embers',
      icon: Icons.volcano, sky: [Color(0xFF4A148C), Color(0xFF880E4F), Color(0xFFB71C1C)],
      windBase: 0.1, hazard: 'lava', levelLock: 5,
      patterns: [TerrainPattern.centralMountain, TerrainPattern.unevenCliffs, TerrainPattern.narrowPlatforms],
    ),
    MapDef(
      id: 'city', name: 'Rooftop Rumble', tagline: 'Urban chaos on breakable towers',
      icon: Icons.location_city, sky: [Color(0xFF37474F), Color(0xFF263238), Color(0xFF102027)],
      hazard: 'traffic', levelLock: 7,
      patterns: [TerrainPattern.narrowPlatforms, TerrainPattern.splitIslands, TerrainPattern.flat],
    ),
  ];

  static MapDef byId(String id) => all.firstWhere((m) => m.id == id, orElse: () => all.first);
}

/// Builds the world layout for a given map + player count.
///
/// All randomness is drawn from [PhysicsWorld.rng] (a [GameRng] seeded from
/// the match seed) rather than `dart:math`'s `Random`, so host and client in
/// hotspot multiplayer — both constructing a [PhysicsWorld] with the same
/// synced seed — always generate byte-for-byte identical terrain, and a
/// given seed always reproduces the same map for debugging/replays.
class MapBuilder {
  /// How far from the absolute world edge a player's guaranteed spawn
  /// platform may sit — close enough that its raft/platform (up to ~150px
  /// wide) stays fully inside the playable area, far enough to leave real
  /// clearance from the edge. Not a fraction: a fixed pixel margin, so it
  /// scales correctly with [PhysicsWorld.width] regardless of map.
  static const double _edgeMargin = 100;

  /// Player slot x-positions — fixed and NOT randomized, so [spawnFor]
  /// (called independently, elsewhere, long after [build] ran) always
  /// agrees with what [build] used. Slots are spread across the *entire*
  /// playable width (edge margin to edge margin) rather than compressed
  /// toward the center, maximizing separation between players — for 2
  /// players this puts them close to opposite ends of the map instead of
  /// leaving a large unused margin on both sides. Per-round *variety*
  /// instead comes from randomizing platform height/width/terrain pattern/
  /// decoration, plus a small x-jitter on the guaranteed spawn platform
  /// itself (well within [spawnFor]'s 90px search radius, so it never loses
  /// track of a player's platform).
  static List<double> _slots(double W, int numPlayers) {
    final lo = _edgeMargin, hi = W - _edgeMargin;
    if (numPlayers == 1) return [W / 2];
    return List.generate(numPlayers, (i) => lo + (hi - lo) * i / (numPlayers - 1));
  }

  /// Horizontal gap between adjacent player slots for a given player count.
  /// Exposed so UI (e.g. the build-area rect) can size itself to guarantee
  /// no overlap between neighbouring players regardless of player count,
  /// instead of assuming a single fixed width that only fits 2 players.
  static double slotSpacing(double worldWidth, int numPlayers) {
    if (numPlayers <= 1) return worldWidth;
    return (worldWidth - 2 * _edgeMargin) / (numPlayers - 1);
  }

  static void build(PhysicsWorld world, MapDef map, int numPlayers) {
    final slots = _slots(world.width, numPlayers);
    final pattern = map.patterns[world.rng.nextInt(map.patterns.length)];

    switch (map.id) {
      case 'ocean':
        _buildOcean(world, slots, pattern);
        break;
      case 'island':
        _buildIsland(world, slots, pattern);
        break;
      case 'mountains':
        _buildMountains(world, slots, pattern);
        break;
      case 'desert':
        _buildDesert(world, slots, pattern);
        break;
      case 'volcano':
        _buildVolcano(world, slots, pattern);
        break;
      case 'city':
        _buildCity(world, slots, pattern);
        break;
      default:
        _buildOcean(world, slots, pattern);
    }
  }

  // ---------------------------------------------------------------------
  // Shared terrain-shaping helpers
  // ---------------------------------------------------------------------

  /// Height *above* the water/base line (bigger = taller) for a feature at
  /// horizontal fraction [xFrac] (0..1 across the map), shaped by [pattern]
  /// around a [base] height with [amp] amplitude of variation. Deterministic
  /// given [rng]'s current state, so the same seed always yields the same
  /// silhouette.
  static double _patternHeight(TerrainPattern pattern, double xFrac, GameRng rng, double base, double amp) {
    switch (pattern) {
      case TerrainPattern.flat:
        return base + rng.range(-amp * 0.15, amp * 0.15);
      case TerrainPattern.rollingHills:
        return base + sin(xFrac * pi * 2.3 + rng.range(0, pi)) * amp * 0.8;
      case TerrainPattern.centralMountain:
        final d = (xFrac - 0.5).abs() * 2; // 0 at center, 1 at edges
        return base + (1 - d) * amp * 1.3;
      case TerrainPattern.splitIslands:
        final d = (xFrac - 0.5).abs();
        return d < 0.14 ? base - amp * 0.8 : base + rng.range(-amp * 0.25, amp * 0.25);
      case TerrainPattern.unevenCliffs:
        return base + (rng.nextBool() ? 1 : -1) * rng.range(amp * 0.35, amp * 1.05);
      case TerrainPattern.narrowPlatforms:
        return base + rng.range(-amp * 0.55, amp * 0.55);
      case TerrainPattern.valley:
        final d = (xFrac - 0.5).abs() * 2;
        return base + d * amp * 1.05;
      case TerrainPattern.randomIslands:
        return base + rng.range(-amp, amp);
    }
  }

  /// True if [x] falls within a reserved player-spawn column — decorative /
  /// randomized terrain must steer clear of these so a player can never
  /// spawn inside, or have terrain generated on top of, their own body.
  static bool _inReservedColumn(double x, List<double> slots, {double margin = 100}) =>
      slots.any((s) => (x - s).abs() < margin);

  static PhysBody _raft(PhysicsWorld w, double x, {double width = 150}) {
    final raft = w.addBlock(
      pos: Offset(x, w.waterLevel - 12),
      size: Size(width, 26),
      material: MaterialType.raft,
      isStatic: true,
    );
    return raft;
  }

  static Offset spawnOn(PhysBody platform) =>
      Offset(platform.pos.dx, platform.pos.dy - platform.size.height / 2 - 32);

  /// Small, bounded x-jitter for a guaranteed spawn feature — stays well
  /// inside [spawnFor]'s 90px search radius so spawn lookup never fails.
  static double _spawnJitter(GameRng rng) => rng.range(-35, 35);

  // ---------------------------------------------------------------------
  // Per-map builders (theme + hazards unchanged; heights/counts/positions
  // now pattern- and seed-driven)
  // ---------------------------------------------------------------------

  static void _buildOcean(PhysicsWorld w, List<double> slots, TerrainPattern pattern) {
    final rng = w.rng;
    for (int i = 0; i < slots.length; i++) {
      final baseX = slots[i];
      final x = (baseX + _spawnJitter(rng)).clamp(baseX - 60, baseX + 60);
      final raft = _raft(w, x, width: 140 + rng.range(0, 24));
      raft.playerIndex = i;
      final dir = x < w.width / 2 ? -1 : 1;
      w.addBlock(
        pos: Offset(x + dir * 55, raft.pos.dy - 45 - rng.range(0, 20)),
        size: Size(16, 70 + rng.range(0, 18)),
        material: MaterialType.wood,
        isStatic: false,
      );
    }
    // floating debris platforms in the middle — count & heights shaped by pattern
    final count = pattern == TerrainPattern.randomIslands ? 4 + rng.nextInt(2) : 2 + rng.nextInt(2);
    for (int i = 0; i < count; i++) {
      final xFrac = 0.28 + (i / max(1, count - 1)) * 0.44 + rng.range(-0.04, 0.04);
      final x = w.width * xFrac;
      if (_inReservedColumn(x, slots)) continue;
      final h = _patternHeight(pattern, xFrac, rng, 55, 70);
      w.addBlock(
        pos: Offset(x, w.waterLevel - h.clamp(20, 230)),
        size: Size(65 + rng.range(0, 45), 14),
        material: MaterialType.wood,
        isStatic: true,
      );
    }
    // a few floating barrels
    final barrels = 1 + rng.nextInt(3);
    for (int i = 0; i < barrels; i++) {
      final x = w.width * rng.range(0.3, 0.7);
      if (_inReservedColumn(x, slots)) continue;
      w.addBlock(
        pos: Offset(x, w.waterLevel - 6),
        size: const Size(26, 26),
        material: MaterialType.wood,
        isStatic: false,
      );
    }
  }

  static void _buildIsland(PhysicsWorld w, List<double> slots, TerrainPattern pattern) {
    final rng = w.rng;
    if (pattern == TerrainPattern.randomIslands) {
      // several small scattered islands instead of one big central mass
      final count = 3 + rng.nextInt(2);
      for (int i = 0; i < count; i++) {
        final xFrac = 0.2 + i / max(1, count - 1) * 0.6 + rng.range(-0.03, 0.03);
        final x = w.width * xFrac;
        if (_inReservedColumn(x, slots)) continue;
        final h = 40 + rng.range(0, 60);
        w.addBlock(
          pos: Offset(x, w.waterLevel - h * 0.35),
          size: Size(60 + rng.range(0, 50), 30 + rng.range(0, 20)),
          material: MaterialType.stone,
          isStatic: true,
        );
      }
    } else if (pattern == TerrainPattern.splitIslands) {
      // two islands, one per side, with open water in the middle
      for (final side in [-1.0, 1.0]) {
        final x = w.width / 2 + side * w.width * 0.22;
        w.addBlock(
          pos: Offset(x, w.waterLevel - (22 + rng.range(0, 18))),
          size: Size(w.width * 0.2 + rng.range(0, 40), 46 + rng.range(0, 16)),
          material: MaterialType.stone,
          isStatic: true,
        );
      }
    } else {
      // classic single central island, height/width jittered
      w.addBlock(
        pos: Offset(w.width / 2, w.waterLevel - (22 + rng.range(0, 14))),
        size: Size(w.width * 0.30 + rng.range(-20, 30), 46 + rng.range(0, 12)),
        material: MaterialType.stone,
        isStatic: true,
      );
    }
    // palm tower on/near the island
    final towerH = 90 + rng.range(0, 24);
    w.addBlock(
      pos: Offset(w.width / 2 - 40, w.waterLevel - towerH / 2 - 8),
      size: Size(20, towerH),
      material: MaterialType.wood,
      isStatic: true,
    );
    w.addBlock(
      pos: Offset(w.width / 2 - 40, w.waterLevel - towerH - 16),
      size: const Size(64, 16),
      material: MaterialType.wood,
      isStatic: true,
    );
    for (int i = 0; i < slots.length; i++) {
      final baseX = slots[i];
      if ((baseX - w.width / 2).abs() < w.width * 0.18) {
        final x = (baseX + _spawnJitter(rng)).clamp(baseX - 45, baseX + 45);
        final platform = w.addBlock(
          pos: Offset(x, w.waterLevel - (48 + rng.range(0, 12))),
          size: const Size(80, 8),
          material: MaterialType.stone,
          isStatic: true,
        );
        platform.playerIndex = i;
      } else {
        final x = (baseX + _spawnJitter(rng)).clamp(baseX - 45, baseX + 45);
        final raft = _raft(w, x);
        raft.playerIndex = i;
        final dir = x < w.width / 2 ? -1 : 1;
        w.addBlock(
          pos: Offset(x + dir * 52, raft.pos.dy - 38),
          size: const Size(34, 52),
          material: MaterialType.stone,
        );
      }
    }
  }

  static void _buildMountains(PhysicsWorld w, List<double> slots, TerrainPattern pattern) {
    final rng = w.rng;
    for (int i = 0; i < slots.length; i++) {
      final baseX = slots[i];
      final x = (baseX + _spawnJitter(rng)).clamp(baseX - 40, baseX + 40);
      final xFrac = x / w.width;
      final h = _patternHeight(pattern, xFrac, rng, 165, 90).clamp(90.0, 320.0);
      final platform = w.addBlock(
        pos: Offset(x, w.waterLevel - h + 14),
        size: Size(120 + rng.range(-10, 20), 28),
        material: MaterialType.stone,
        isStatic: true,
      );
      platform.playerIndex = i;
      w.addBlock(
        pos: Offset(x, w.waterLevel - h + 70),
        size: Size(16, 60 + rng.range(0, 40)),
        material: MaterialType.wood,
        isStatic: true,
      );
    }
    // hanging ice platforms — count shaped by pattern
    final iceCount = pattern == TerrainPattern.narrowPlatforms ? 3 + rng.nextInt(2) : 1 + rng.nextInt(3);
    for (int i = 0; i < iceCount; i++) {
      final xFrac = 0.25 + i / max(1, iceCount - 1) * 0.5 + rng.range(-0.05, 0.05);
      final x = w.width * xFrac;
      if (_inReservedColumn(x, slots)) continue;
      w.addBlock(
        pos: Offset(x, w.waterLevel - (220 + rng.range(-40, 60))),
        size: Size(55 + rng.range(0, 30), 14),
        material: MaterialType.glass,
        isStatic: true,
      );
    }
    // loose boulders that can tumble
    final boulders = 2 + rng.nextInt(3);
    for (int i = 0; i < boulders; i++) {
      final x = w.width * rng.range(0.25, 0.75);
      if (_inReservedColumn(x, slots)) continue;
      w.addBlock(
        pos: Offset(x, 50 + rng.range(0, 70)),
        size: const Size(30, 30),
        material: MaterialType.stone,
      );
    }
  }

  static void _buildDesert(PhysicsWorld w, List<double> slots, TerrainPattern pattern) {
    final rng = w.rng;
    // canyon floor
    w.addBlock(
      pos: Offset(w.width / 2, w.waterLevel + 20),
      size: Size(w.width * 0.5 + rng.range(-40, 60), 60),
      material: MaterialType.stone,
      isStatic: true,
    );
    for (int i = 0; i < slots.length; i++) {
      final baseX = slots[i];
      final x = (baseX + _spawnJitter(rng)).clamp(baseX - 40, baseX + 40);
      final xFrac = x / w.width;
      final h = _patternHeight(pattern, xFrac, rng, 40, 30).clamp(15.0, 100.0);
      final platform = w.addBlock(
        pos: Offset(x, w.waterLevel - h),
        size: Size(130 + rng.range(-10, 20), 80),
        material: MaterialType.stone,
        isStatic: true,
      );
      platform.playerIndex = i;
    }
    // explosive barrels: low hp so they pop quickly, and flagged `explosive`
    // so the physics world detonates them (and any neighbours) on death.
    final barrelCount = pattern == TerrainPattern.splitIslands ? 6 + rng.nextInt(3) : 3 + rng.nextInt(4);
    for (int i = 0; i < barrelCount; i++) {
      final x = w.width * rng.range(0.2, 0.8);
      if (_inReservedColumn(x, slots, margin: 70)) continue;
      final b = w.addBlock(
        pos: Offset(x, w.waterLevel - 100 - rng.range(0, 110)),
        size: const Size(24, 30),
        material: MaterialType.wood,
        isStatic: true,
      );
      b.hp = 12; b.maxHp = 12;
      b.explosive = true;
    }
  }

  static void _buildVolcano(PhysicsWorld w, List<double> slots, TerrainPattern pattern) {
    final rng = w.rng;
    for (int i = 0; i < slots.length; i++) {
      final baseX = slots[i];
      final x = (baseX + _spawnJitter(rng)).clamp(baseX - 40, baseX + 40);
      final xFrac = x / w.width;
      final h = _patternHeight(pattern, xFrac, rng, 65, 45).clamp(35.0, 160.0);
      final platform = w.addBlock(
        pos: Offset(x, w.waterLevel - h),
        size: Size(105 + rng.range(0, 20), 22),
        material: MaterialType.metal,
        isStatic: true,
      );
      platform.playerIndex = i;
      w.addBlock(
        pos: Offset(x, w.waterLevel - h / 2 + 5),
        size: Size(30, h * 0.75 + 10),
        material: MaterialType.stone,
        isStatic: true,
      );
    }
    // unstable floating rocks over the lava
    final rocks = 2 + rng.nextInt(3);
    for (int i = 0; i < rocks; i++) {
      final xFrac = 0.25 + i / max(1, rocks - 1) * 0.5 + rng.range(-0.05, 0.05);
      final x = w.width * xFrac;
      if (_inReservedColumn(x, slots)) continue;
      w.addBlock(
        pos: Offset(x, w.waterLevel - (150 + rng.range(-30, 60))),
        size: Size(55 + rng.range(0, 25), 16),
        material: MaterialType.stone,
      );
    }
  }

  static void _buildCity(PhysicsWorld w, List<double> slots, TerrainPattern pattern) {
    final rng = w.rng;
    for (int i = 0; i < slots.length; i++) {
      final baseX = slots[i];
      final x = (baseX + _spawnJitter(rng)).clamp(baseX - 40, baseX + 40);
      final xFrac = x / w.width;
      final amp = pattern == TerrainPattern.narrowPlatforms ? 70.0 : 45.0;
      final bh = _patternHeight(pattern, xFrac, rng, 195, amp).clamp(120.0, 300.0);
      final towerWidth = pattern == TerrainPattern.narrowPlatforms ? 74.0 + rng.range(0, 12) : 100.0;
      final tower = w.addBlock(
        pos: Offset(x, w.waterLevel - bh / 2),
        size: Size(towerWidth, bh),
        material: MaterialType.stone,
        isStatic: true,
      );
      tower.playerIndex = i;
      final windowRows = max(2, (bh / 60).floor());
      for (int r = 0; r < windowRows; r++) {
        w.addBlock(
          pos: Offset(x, w.waterLevel - bh + 40 + r * 50),
          size: Size(towerWidth * 0.7, 22),
          material: MaterialType.glass,
          isStatic: true,
        );
      }
      w.addBlock(
        pos: Offset(x, w.waterLevel - bh - 8),
        size: Size(towerWidth * 1.2, 16),
        material: MaterialType.metal,
        isStatic: true,
      );
    }
    // extra rooftop/street clutter — count & spread shaped by pattern
    final extras = pattern == TerrainPattern.splitIslands ? 1 : 1 + rng.nextInt(2);
    for (int i = 0; i < extras; i++) {
      final x = w.width * rng.range(0.35, 0.65);
      if (_inReservedColumn(x, slots)) continue;
      w.addBlock(
        pos: Offset(x, w.waterLevel - (140 + rng.range(0, 40))),
        size: Size(50 + rng.range(0, 20), 50 + rng.range(0, 20)),
        material: MaterialType.wood,
      );
    }
  }

  /// Find the spawn platform for player i. Each builder above tags the one
  /// block it *guarantees* for a given slot with that player's index (see
  /// [_spawnJitter] call sites), so this always finds the intended platform
  /// directly rather than guessing by proximity — important once terrain is
  /// randomized, since an unrelated but nearer structure (e.g. the desert's
  /// wide canyon floor) could otherwise tie with, or beat, the real spawn
  /// platform in a nearest-block search and place a spawn inside it.
  static Offset spawnFor(PhysicsWorld w, int player, int numPlayers) {
    final slots = _slots(w.width, numPlayers);
    final x = slots[player];
    for (final b in w.bodies) {
      if (b.dead || !b.isStatic || b.type != BodyType.block) continue;
      if (b.playerIndex == player) return spawnOn(b);
    }
    // Defensive fallback (shouldn't normally trigger): nearest untagged
    // static block within range.
    PhysBody? best;
    double bestDist = double.infinity;
    for (final b in w.bodies) {
      if (b.dead || !b.isStatic || b.type != BodyType.block || b.playerIndex >= 0) continue;
      final d = (b.pos.dx - x).abs();
      if (d < bestDist && d < 90) {
        bestDist = d;
        best = b;
      }
    }
    if (best == null) return Offset(x, w.waterLevel - 60);
    return spawnOn(best);
  }
}
