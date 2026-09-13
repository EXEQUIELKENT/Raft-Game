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


/// Something solid floating in the channel between the rafts.
///
/// Unlike [SceneProp], which is painted on the horizon and collides with
/// nothing, these sit in the middle of the world and stop shots. They are
/// what turns "aim at the enemy" into "find a line to the enemy": a flat
/// trajectory that used to be a free hit now has to go over, under or round
/// something, and the deep lob that clears everything gives up accuracy.
///
/// Each kind is a different shape of problem rather than a different
/// picture: a tall narrow one has to be cleared, a wide low one has to be
/// lobbed, a floating one can be shot away if you would rather spend a turn
/// on it than aim around it.
enum ObstacleKind {
  /// Wide, low, immovable. Blocks the flat shot; a modest arc clears it.
  rock,

  /// Tall and narrow, and it floats — it can be destroyed, and it drifts
  /// with the swell, so the gap it leaves is never quite where it was.
  buoy,

  /// Very tall, very solid. The one you genuinely have to go over.
  mast,

  /// Tall and wide, but breakable: two or three hits open a hole through
  /// the middle of the map.
  crate,

  /// Big, low and wide, with a shallow shoulder — the awkward one, because
  /// there is no clean line over it that is not also a very long lob.
  iceberg,

  /// A half-sunk hull: low, wide, and it only blocks the bottom of the
  /// channel, so it punishes the flat shot and nothing else.
  wreck,
}
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

  /// Which solid obstacles this scene drops into the channel between the
  /// rafts. Themed per map so the hazard belongs to the place: icebergs in
  /// the frozen swell, crates and masts in the harbour.
  final List<ObstacleKind> obstacles;

  /// What the solid things in this scene are MADE of.
  ///
  /// The shapes alone were not enough: a rock was the same grey lump in the
  /// tropics, in the ice and on the lava flow, so six scenes that differ in
  /// every other colour were dropping identical objects into the water. The
  /// silhouette says what an obstacle does; these say where it is.
  ///
  /// [stone] and [stoneShade] paint rock and iceberg, [timber] and
  /// [timberShade] paint the built things — wreck, crate and mast.
  final Color stone;
  final Color stoneShade;
  final Color timber;
  final Color timberShade;

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
    this.obstacles = const [ObstacleKind.rock, ObstacleKind.buoy],
    this.stone = const Color(0xFF6E6A63),
    this.stoneShade = const Color(0xFF514E49),
    this.timber = const Color(0xFF8A6134),
    this.timberShade = const Color(0xFF5C3F20),
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
      obstacles: [ObstacleKind.rock, ObstacleKind.buoy],
      // Weathered sea granite and salt-bleached driftwood.
      stone: Color(0xFF6E6A63), stoneShade: Color(0xFF4E4B46),
      timber: Color(0xFF9A7346), timberShade: Color(0xFF6A4C2C),
      chop: 1.0,
    ),
    MapDef(
      id: 'island', name: 'Coconut Cove', tagline: 'Turquoise shallows and palm huts',
      icon: Icons.beach_access,
      sky: [Color(0xFF6FD3E8), Color(0xFFCFF0F5), Color(0xFFF2E3B4), Color(0xFFEBD9A2)],
      water: Color(0xFF34B3AE), waterDeep: Color(0xFF16787C), shore: Color(0xFFF2E3B4),
      props: [SceneProp.palm, SceneProp.hut, SceneProp.rock],
      obstacles: [ObstacleKind.rock, ObstacleKind.crate, ObstacleKind.buoy],
      // Warm coral limestone and fresh palm timber.
      stone: Color(0xFFC9A87C), stoneShade: Color(0xFF9C7B52),
      timber: Color(0xFFC08A4A), timberShade: Color(0xFF8A5C28),
      chop: 0.75,
    ),
    MapDef(
      id: 'mountains', name: 'Frosty Peaks', tagline: 'Icebergs adrift in a cold swell',
      icon: Icons.ac_unit,
      sky: [Color(0xFF9FC6DE), Color(0xFFDCEBF3), Color(0xFFE8F2F6), Color(0xFFCFE2EA)],
      water: Color(0xFF3E7E96), waterDeep: Color(0xFF1B4A5C), shore: Color(0xFFE8F2F6),
      props: [SceneProp.iceberg, SceneProp.rock],
      obstacles: [ObstacleKind.iceberg, ObstacleKind.rock, ObstacleKind.iceberg],
      // Wet dark slate against pale blue ice.
      stone: Color(0xFF6E7B85), stoneShade: Color(0xFF4A555F),
      timber: Color(0xFF7A6A5C), timberShade: Color(0xFF52463C),
      chop: 1.45, levelLock: 2,
    ),
    MapDef(
      id: 'desert', name: 'Dusty Dunes', tagline: 'A hot channel between the dunes',
      icon: Icons.wb_sunny,
      sky: [Color(0xFFF6C98A), Color(0xFFF7DFB2), Color(0xFFE8C98B), Color(0xFFDDB877)],
      water: Color(0xFF4E9A93), waterDeep: Color(0xFF2A6360), shore: Color(0xFFDDB877),
      props: [SceneProp.cactus, SceneProp.wreck, SceneProp.rock],
      obstacles: [ObstacleKind.wreck, ObstacleKind.rock, ObstacleKind.mast],
      // Sun-baked sandstone and timber bleached silver-grey.
      stone: Color(0xFFD3A96A), stoneShade: Color(0xFFA37C42),
      timber: Color(0xFFB49A78), timberShade: Color(0xFF7E6850),
      chop: 0.6, levelLock: 3,
    ),
    MapDef(
      id: 'volcano', name: 'Mount Sizzle', tagline: 'Ash on the wind, embers on the water',
      icon: Icons.volcano,
      sky: [Color(0xFF7A4A5C), Color(0xFFC97A63), Color(0xFFE0996B), Color(0xFF9A5A48)],
      water: Color(0xFF6E4152), waterDeep: Color(0xFF3A2130), shore: Color(0xFF9A5A48),
      props: [SceneProp.ember, SceneProp.rock, SceneProp.wreck],
      obstacles: [ObstacleKind.rock, ObstacleKind.wreck, ObstacleKind.rock],
      // Black basalt and charred, half-burnt planking.
      stone: Color(0xFF4A4148), stoneShade: Color(0xFF2E282E),
      timber: Color(0xFF6B4438), timberShade: Color(0xFF3E2620),
      chop: 1.2, levelLock: 5,
    ),
    MapDef(
      id: 'city', name: 'Harbour Lights', tagline: 'Duelling between the docks at dusk',
      icon: Icons.location_city,
      sky: [Color(0xFF4C6C8C), Color(0xFF89A9C4), Color(0xFFB9C6CE), Color(0xFF8FA2AE)],
      water: Color(0xFF2E6274), waterDeep: Color(0xFF16323F), shore: Color(0xFF8FA2AE),
      props: [SceneProp.rig, SceneProp.crane, SceneProp.buoy],
      obstacles: [ObstacleKind.crate, ObstacleKind.mast, ObstacleKind.crate, ObstacleKind.buoy],
      // Harbour concrete and painted dock timber.
      stone: Color(0xFF7E8590), stoneShade: Color(0xFF565C66),
      timber: Color(0xFF8C6A4E), timberShade: Color(0xFF5C4430),
      chop: 0.9, levelLock: 7,
    ),
  ];

  static MapDef byId(String id) => all.firstWhere((m) => m.id == id, orElse: () => all.first);
}
