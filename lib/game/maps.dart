import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart' hide MaterialType;
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

class MapDef {
  final String id;
  final String name;
  final String tagline;
  final IconData icon;
  final List<Color> sky;
  final double windBase;
  final String hazard; // none | waves | rocks | barrels | lava | traffic
  final int levelLock;

  const MapDef({
    required this.id,
    required this.name,
    required this.tagline,
    required this.icon,
    required this.sky,
    this.windBase = 0,
    this.hazard = 'none',
    this.levelLock = 1,
  });
}

class GameMaps {
  GameMaps._();

  static const List<MapDef> all = [
    MapDef(
      id: 'ocean', name: 'Ocean Drift', tagline: 'Classic raft warfare on rolling waves',
      icon: Icons.sailing, sky: [Color(0xFFFF9D5C), Color(0xFFFF5E8A), Color(0xFF7B4FB3)],
      windBase: 0.15, hazard: 'waves',
    ),
    MapDef(
      id: 'island', name: 'Coconut Cove', tagline: 'Sandy beach with palm towers',
      icon: Icons.beach_access, sky: [Color(0xFF4FC3F7), Color(0xFF29B6F6), Color(0xFF0288D1)],
      hazard: 'none',
    ),
    MapDef(
      id: 'mountains', name: 'Frosty Peaks', tagline: 'Icy cliffs, tumbling rocks',
      icon: Icons.landscape, sky: [Color(0xFFB39DDB), Color(0xFF7E57C2), Color(0xFF4527A0)],
      windBase: 0.25, hazard: 'rocks', levelLock: 2,
    ),
    MapDef(
      id: 'desert', name: 'Dusty Dunes', tagline: 'Explosive barrels everywhere!',
      icon: Icons.wb_sunny, sky: [Color(0xFFFFE082), Color(0xFFFFB300), Color(0xFFFF6F00)],
      windBase: 0.2, hazard: 'barrels', levelLock: 3,
    ),
    MapDef(
      id: 'volcano', name: 'Mount Sizzle', tagline: 'Lava pools & falling embers',
      icon: Icons.volcano, sky: [Color(0xFF4A148C), Color(0xFF880E4F), Color(0xFFB71C1C)],
      windBase: 0.1, hazard: 'lava', levelLock: 5,
    ),
    MapDef(
      id: 'city', name: 'Rooftop Rumble', tagline: 'Urban chaos on breakable towers',
      icon: Icons.location_city, sky: [Color(0xFF37474F), Color(0xFF263238), Color(0xFF102027)],
      hazard: 'traffic', levelLock: 7,
    ),
  ];

  static MapDef byId(String id) => all.firstWhere((m) => m.id == id, orElse: () => all.first);
}

/// Builds the world layout for a given map + player count
class MapBuilder {
  /// Returns (character spawn x positions are on rafts/platforms)
  static void build(PhysicsWorld world, MapDef map, int numPlayers, double windSeed) {
    final W = world.width;
    final wl = world.waterLevel;
    final rnd = Random(windSeed.hashCode);

    // positions for players across the map
    List<double> slots;
    if (numPlayers == 2) {
      slots = [W * 0.13, W * 0.87];
    } else if (numPlayers == 3) {
      slots = [W * 0.11, W * 0.5, W * 0.89];
    } else {
      slots = [W * 0.09, W * 0.37, W * 0.63, W * 0.91];
    }

    switch (map.id) {
      case 'ocean':
        _buildOcean(world, slots, rnd);
        break;
      case 'island':
        _buildIsland(world, slots, rnd);
        break;
      case 'mountains':
        _buildMountains(world, slots, rnd);
        break;
      case 'desert':
        _buildDesert(world, slots, rnd);
        break;
      case 'volcano':
        _buildVolcano(world, slots, rnd);
        break;
      case 'city':
        _buildCity(world, slots, rnd);
        break;
      default:
        _buildOcean(world, slots, rnd);
    }
  }

  static PhysBody _raft(PhysicsWorld w, double x, {double width = 150}) {
    // raft: static base floating at water level
    final raft = w.addBlock(
      pos: Offset(x, w.waterLevel - 12),
      size: Size(width, 26),
      material: MaterialType.raft,
      isStatic: true,
    );
    // little flag pole
    return raft;
  }

  static Offset spawnOn(PhysBody platform) =>
      Offset(platform.pos.dx, platform.pos.dy - platform.size.height / 2 - 32);

  static void _buildOcean(PhysicsWorld w, List<double> slots, Random rnd) {
    for (final x in slots) {
      final raft = _raft(w, x);
      // small starter wall on outer edge
      final dir = x < w.width / 2 ? -1 : 1;
      w.addBlock(
        pos: Offset(x + dir * 55, raft.pos.dy - 50),
        size: const Size(16, 78),
        material: MaterialType.wood,
        isStatic: false,
      );
    }
    // floating debris platforms in the middle
    for (int i = 0; i < 3; i++) {
      w.addBlock(
        pos: Offset(w.width * (0.3 + i * 0.2), w.waterLevel - 30 - rnd.nextDouble() * 60),
        size: Size(70 + rnd.nextDouble() * 40, 14),
        material: MaterialType.wood,
        isStatic: true,
      );
    }
    // a couple of barrels floating
    for (int i = 0; i < 2; i++) {
      w.addBlock(
        pos: Offset(w.width * (0.35 + i * 0.3), w.waterLevel - 6),
        size: const Size(26, 26),
        material: MaterialType.wood,
        isStatic: false,
      );
    }
  }

  static void _buildIsland(PhysicsWorld w, List<double> slots, Random rnd) {
    // central sandy island
    w.addBlock(
      pos: Offset(w.width / 2, w.waterLevel - 25),
      size: Size(w.width * 0.30, 50),
      material: MaterialType.stone,
      isStatic: true,
    );
    // palm towers on island
    w.addBlock(
      pos: Offset(w.width / 2 - 40, w.waterLevel - 100),
      size: const Size(20, 100),
      material: MaterialType.wood,
      isStatic: true,
    );
    w.addBlock(
      pos: Offset(w.width / 2 - 40, w.waterLevel - 158),
      size: const Size(64, 16),
      material: MaterialType.wood,
      isStatic: true,
    );
    for (int i = 0; i < slots.length; i++) {
      final x = slots[i];
      if ((x - w.width / 2).abs() < w.width * 0.18) {
        // spawn on island
        final platform = w.addBlock(
          pos: Offset(x, w.waterLevel - 52),
          size: const Size(80, 8),
          material: MaterialType.stone,
          isStatic: true,
        );
        platform.dead = false;
      } else {
        final raft = _raft(w, x);
        // stone starter cover
        final dir = x < w.width / 2 ? -1 : 1;
        w.addBlock(
          pos: Offset(x + dir * 52, raft.pos.dy - 38),
          size: const Size(34, 52),
          material: MaterialType.stone,
        );
      }
    }
  }

  static void _buildMountains(PhysicsWorld w, List<double> slots, Random rnd) {
    // jagged cliff platforms at different heights
    final heights = [120.0, 190.0, 140.0, 210.0];
    for (int i = 0; i < slots.length; i++) {
      final h = heights[i % heights.length];
      w.addBlock(
        pos: Offset(slots[i], w.waterLevel - h + 14),
        size: const Size(120, 28),
        material: MaterialType.stone,
        isStatic: true,
      );
      // wooden brace
      w.addBlock(
        pos: Offset(slots[i], w.waterLevel - h + 70),
        size: const Size(16, 90),
        material: MaterialType.wood,
        isStatic: true,
      );
    }
    // hanging ice platforms
    for (int i = 0; i < 2; i++) {
      w.addBlock(
        pos: Offset(w.width * (0.38 + i * 0.24), w.waterLevel - 260),
        size: const Size(70, 14),
        material: MaterialType.glass,
        isStatic: true,
      );
    }
    // loose boulders that can tumble
    for (int i = 0; i < 3; i++) {
      w.addBlock(
        pos: Offset(w.width * (0.3 + rnd.nextDouble() * 0.4), 60 + rnd.nextDouble() * 60),
        size: const Size(30, 30),
        material: MaterialType.stone,
      );
    }
  }

  static void _buildDesert(PhysicsWorld w, List<double> slots, Random rnd) {
    // canyon floor
    w.addBlock(
      pos: Offset(w.width / 2, w.waterLevel + 20),
      size: Size(w.width * 0.5, 60),
      material: MaterialType.stone,
      isStatic: true,
    );
    for (final x in slots) {
      // mesa platform
      w.addBlock(
        pos: Offset(x, w.waterLevel - 40),
        size: const Size(130, 80),
        material: MaterialType.stone,
        isStatic: true,
      );
    }
    // explosive barrels (as weak wood with bonus dmg — handled via low hp)
    for (int i = 0; i < 5; i++) {
      final b = w.addBlock(
        pos: Offset(w.width * (0.25 + rnd.nextDouble() * 0.5), w.waterLevel - 120 - rnd.nextDouble() * 100),
        size: const Size(24, 30),
        material: MaterialType.wood,
        isStatic: true,
      );
      b.hp = 12; b.maxHp = 12; // very explody
    }
  }

  static void _buildVolcano(PhysicsWorld w, List<double> slots, Random rnd) {
    // obsidian platforms over lava (waterLevel doubles as lava surface here)
    for (int i = 0; i < slots.length; i++) {
      w.addBlock(
        pos: Offset(slots[i], w.waterLevel - 60),
        size: const Size(110, 22),
        material: MaterialType.metal,
        isStatic: true,
      );
      // rock pillar
      w.addBlock(
        pos: Offset(slots[i], w.waterLevel - 25),
        size: const Size(30, 50),
        material: MaterialType.stone,
        isStatic: true,
      );
    }
    // unstable floating rocks
    for (int i = 0; i < 3; i++) {
      w.addBlock(
        pos: Offset(w.width * (0.3 + i * 0.2), w.waterLevel - 170),
        size: const Size(60, 16),
        material: MaterialType.stone,
      );
    }
  }

  static void _buildCity(PhysicsWorld w, List<double> slots, Random rnd) {
    // buildings with windows (glass) + rooftops
    for (int i = 0; i < slots.length; i++) {
      final x = slots[i];
      final bh = 190.0 + (i.isEven ? 40 : 0);
      // main tower
      w.addBlock(
        pos: Offset(x, w.waterLevel - bh / 2),
        size: Size(100, bh),
        material: MaterialType.stone,
        isStatic: true,
      );
      // glass window strips
      for (int r = 0; r < 3; r++) {
        w.addBlock(
          pos: Offset(x, w.waterLevel - bh + 40 + r * 50),
          size: const Size(70, 22),
          material: MaterialType.glass,
          isStatic: true,
        );
      }
      // rooftop
      w.addBlock(
        pos: Offset(x, w.waterLevel - bh - 8),
        size: const Size(120, 16),
        material: MaterialType.metal,
        isStatic: true,
      );
    }
    // water tower mid map
    w.addBlock(
      pos: Offset(w.width / 2, w.waterLevel - 150),
      size: const Size(56, 56),
      material: MaterialType.wood,
    );
  }

  /// Find spawn platform for player i: first static block near their slot
  static Offset spawnFor(PhysicsWorld w, int player, int numPlayers) {
    final W = w.width;
    List<double> slots;
    if (numPlayers == 2) {
      slots = [W * 0.13, W * 0.87];
    } else if (numPlayers == 3) {
      slots = [W * 0.11, W * 0.5, W * 0.89];
    } else {
      slots = [W * 0.09, W * 0.37, W * 0.63, W * 0.91];
    }
    final x = slots[player];
    PhysBody? best;
    double bestDist = double.infinity;
    for (final b in w.bodies) {
      if (!b.isStatic || b.type != BodyType.block) continue;
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
