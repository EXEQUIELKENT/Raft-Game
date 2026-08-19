import 'package:flutter/material.dart';

/// ---------------------------------------------------------------------------
/// Water scenes.
///
/// Every battle now takes place on open water — there is no terrain, no
/// destructible platforms and nothing to collide with except rafts. A [MapDef]
/// is therefore purely *scenery*: the sky/sand/water gradient, which decorative
/// props dot the horizon, and how the water moves.
///
/// The six ids here are unchanged from the terrain era on purpose: campaign
/// data in `campaign.dart` keys levels by `worldId`, so keeping ids stable
/// means the whole campaign/progression structure carries over untouched.
/// ---------------------------------------------------------------------------

/// A decorative prop on the horizon. Purely painted — never collides.
enum SceneProp { palm, hut, rock, iceberg, wreck, cactus, ember, buoy, rig, crane }

class MapDef {
  final String id;
  final String name;
  final String tagline;
  final IconData icon;

  /// Vertical gradient stops from the top of the sky down to the deep water,
  /// matching the design's `sky -> pale sky -> sand band -> sea -> deep sea`.
  final List<Color> sky;

  /// Water surface colour and the deep colour it fades into.
  final Color water;
  final Color waterDeep;

  /// Sand/horizon band colour drawn just above the waterline.
  final Color shore;

  /// Props scattered along the horizon for this scene.
  final List<SceneProp> props;

  /// How lively the water surface is (wave amplitude multiplier).
  final double chop;

  /// Player level required to pick this scene in a quick match.
  final int levelLock;

  const MapDef({
    required this.id,
    required this.name,
    required this.tagline,
    required this.icon,
    required this.sky,
    required this.water,
    required this.waterDeep,
    required this.shore,
    this.props = const [SceneProp.palm, SceneProp.rock],
    this.chop = 1.0,
    this.levelLock = 1,
  });
}

class GameMaps {
  GameMaps._();

  static const List<MapDef> all = [
    MapDef(
      id: 'ocean', name: 'Ocean Drift', tagline: 'Classic raft warfare on rolling waves',
      icon: Icons.sailing,
      sky: [Color(0xFF77BFE3), Color(0xFFC3E4F2), Color(0xFFDFE6B0), Color(0xFFE7D9A0)],
      water: Color(0xFF2F93A1), waterDeep: Color(0xFF175F6B), shore: Color(0xFFE7D9A0),
      props: [SceneProp.palm, SceneProp.rock, SceneProp.buoy],
      chop: 1.0,
    ),
    MapDef(
      id: 'island', name: 'Coconut Cove', tagline: 'Turquoise shallows and palm huts',
      icon: Icons.beach_access,
      sky: [Color(0xFF6FD3E8), Color(0xFFCFF0F5), Color(0xFFF2E3B4), Color(0xFFEBD9A2)],
      water: Color(0xFF34B3AE), waterDeep: Color(0xFF16787C), shore: Color(0xFFF2E3B4),
      props: [SceneProp.palm, SceneProp.hut, SceneProp.rock],
      chop: 0.75,
    ),
    MapDef(
      id: 'mountains', name: 'Frosty Peaks', tagline: 'Icebergs adrift in a cold swell',
      icon: Icons.ac_unit,
      sky: [Color(0xFF9FC6DE), Color(0xFFDCEBF3), Color(0xFFE8F2F6), Color(0xFFCFE2EA)],
      water: Color(0xFF3E7E96), waterDeep: Color(0xFF1B4A5C), shore: Color(0xFFE8F2F6),
      props: [SceneProp.iceberg, SceneProp.rock],
      chop: 1.45, levelLock: 2,
    ),
    MapDef(
      id: 'desert', name: 'Dusty Dunes', tagline: 'A hot channel between the dunes',
      icon: Icons.wb_sunny,
      sky: [Color(0xFFF6C98A), Color(0xFFF7DFB2), Color(0xFFE8C98B), Color(0xFFDDB877)],
      water: Color(0xFF4E9A93), waterDeep: Color(0xFF2A6360), shore: Color(0xFFDDB877),
      props: [SceneProp.cactus, SceneProp.wreck, SceneProp.rock],
      chop: 0.6, levelLock: 3,
    ),
    MapDef(
      id: 'volcano', name: 'Mount Sizzle', tagline: 'Ash on the wind, embers on the water',
      icon: Icons.volcano,
      sky: [Color(0xFF7A4A5C), Color(0xFFC97A63), Color(0xFFE0996B), Color(0xFF9A5A48)],
      water: Color(0xFF6E4152), waterDeep: Color(0xFF3A2130), shore: Color(0xFF9A5A48),
      props: [SceneProp.ember, SceneProp.rock, SceneProp.wreck],
      chop: 1.2, levelLock: 5,
    ),
    MapDef(
      id: 'city', name: 'Harbour Lights', tagline: 'Duelling between the docks at dusk',
      icon: Icons.location_city,
      sky: [Color(0xFF4C6C8C), Color(0xFF89A9C4), Color(0xFFB9C6CE), Color(0xFF8FA2AE)],
      water: Color(0xFF2E6274), waterDeep: Color(0xFF16323F), shore: Color(0xFF8FA2AE),
      props: [SceneProp.rig, SceneProp.crane, SceneProp.buoy],
      chop: 0.9, levelLock: 7,
    ),
  ];

  static MapDef byId(String id) => all.firstWhere((m) => m.id == id, orElse: () => all.first);
}
