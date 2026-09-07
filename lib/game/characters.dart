import 'package:flutter/material.dart';

/// ---------------------------------------------------------------------------
/// The cast.
///
/// Every body on a deck — the player's own crew, the rank-and-file enemies and
/// the world bosses — is one [CharacterDef]. The definition is pure data: a
/// palette, a hat, a face marking and a voice. The renderer draws whatever the
/// definition says rather than switching on who the character *is*, so adding
/// a captain to the roster is a table entry and not a new branch in the body
/// painter.
///
/// [CrewLook] stays the identifier because it is what a [Raft] and a
/// [PlayerConfig] already carry, and what the campaign tables and the battle
/// tests are written against. It grew from five hardcoded archetypes into the
/// full roster; everything that made those five different now lives in the
/// table below.
///
/// Characters are grouped into themes, and a theme is tied to a stretch of the
/// campaign: you meet tarred-up wreckers in the volcano and parka-wrapped
/// icebreakers in the mountains, so a sea reads as a *place* with its own
/// people rather than the same three silhouettes recoloured six times.
/// ---------------------------------------------------------------------------

/// Cosmetic identity of a crew member. One value per character in the roster.
enum CrewLook {
  // Castaway — the player's own people.
  player,
  drifter,
  swimmer,
  // Scavengers — the early seas.
  raider,
  ducker,
  // Buccaneers — the classic pirates.
  pirate,
  captain,
  gunner,
  // Frostbound — the mountain sea.
  furlined,
  icebreaker,
  // Sunbaked — the desert sea.
  nomad,
  duneRunner,
  // Emberkin — the volcano sea.
  stoker,
  ashwalker,
  // Harbour — the city sea.
  dockhand,
  neonRunner,
}

/// Which family a character belongs to. Drives the campaign's casting and the
/// grouping in the customisation screen.
enum CharacterTheme {
  castaway,
  scavenger,
  buccaneer,
  frostbound,
  sunbaked,
  emberkin,
  harbour,
}

extension CharacterThemeInfo on CharacterTheme {
  String get label => switch (this) {
        CharacterTheme.castaway => 'Castaways',
        CharacterTheme.scavenger => 'Scavengers',
        CharacterTheme.buccaneer => 'Buccaneers',
        CharacterTheme.frostbound => 'Frostbound',
        CharacterTheme.sunbaked => 'Sunbaked',
        CharacterTheme.emberkin => 'Emberkin',
        CharacterTheme.harbour => 'Harbour Crew',
      };
}

/// What sits on a character's head. Drawn by the renderer's headgear painter.
enum HeadGear {
  none,
  bandana,
  tricorn,
  strawHat,
  ushanka,
  hood,
  turban,
  wideBrim,
  hardHat,
  visor,
  beanie,
  crown,
  capBackwards,
  gasMask,
}

/// A distinguishing mark drawn over the face, on top of the expression. Kept
/// separate from [HeadGear] so a character can have both.
enum FaceMark {
  none,
  beard,
  stubble,
  eyePatch,
  goggles,
  scar,
  moustache,
  snorkel,
  warPaint,
}

/// How a character sounds. Voice clips are generated at three pitches (see
/// `tool/gen_voice_sfx.dart`), so a hulking gunner and a wiry runner do not
/// yelp in the same register.
enum VoiceType { low, mid, high }

extension VoiceTypeInfo on VoiceType {
  /// Suffix appended to a voice clip's base name, e.g. `voice_ouch1_low`.
  String get suffix => switch (this) {
        VoiceType.low => '_low',
        VoiceType.mid => '',
        VoiceType.high => '_high',
      };
}

class CharacterDef {
  final CrewLook look;
  final String name;
  final CharacterTheme theme;

  /// One line for the customisation screen.
  final String blurb;

  final Color skin;

  /// Torso and upper arms.
  final Color outfit;

  /// Trim: sash, belt, cuffs, hat band.
  final Color accent;

  final HeadGear gear;
  final FaceMark mark;
  final VoiceType voice;

  /// Player level needed before this character can be worn. 0 = from the
  /// start. Enemy-only characters use [playable] = false and are never shown.
  final int unlockLevel;

  /// True if the player can pick this one in the customisation screen.
  final bool playable;

  /// Build multiplier applied to the drawn body. A dockhand is broad, a
  /// dune runner is wiry. Small numbers on purpose — the silhouettes still
  /// have to read at raft scale.
  final double build;

  const CharacterDef({
    required this.look,
    required this.name,
    required this.theme,
    required this.blurb,
    required this.skin,
    required this.outfit,
    required this.accent,
    this.gear = HeadGear.none,
    this.mark = FaceMark.none,
    this.voice = VoiceType.mid,
    this.unlockLevel = 0,
    this.playable = false,
    this.build = 1.0,
  });

  String get id => look.name;
}

class Cast {
  Cast._();

  static const _tan = Color(0xFFEFD79F);
  static const _sand = Color(0xFFE8C98C);
  static const _bronze = Color(0xFFDCB877);
  static const _umber = Color(0xFFC79A66);
  static const _deep = Color(0xFF9A6B45);

  /// The whole cast, in roster order. The first entry is the default player.
  static const List<CharacterDef> all = [
    // ---- Castaways: the player's own people ------------------------------
    CharacterDef(
      look: CrewLook.player,
      name: 'The Captain',
      theme: CharacterTheme.castaway,
      blurb: 'You. Sunburnt, stubborn, and still afloat.',
      skin: _tan,
      outfit: Color(0xFF2D4F8F),
      accent: Color(0xFFE8B33D),
      gear: HeadGear.none,
      mark: FaceMark.none,
      voice: VoiceType.mid,
      playable: true,
    ),
    CharacterDef(
      look: CrewLook.drifter,
      name: 'Drifter',
      theme: CharacterTheme.castaway,
      blurb: 'Been out here so long the hat grew on.',
      skin: _sand,
      outfit: Color(0xFF6E8B6B),
      accent: Color(0xFFD9C79A),
      gear: HeadGear.strawHat,
      mark: FaceMark.stubble,
      voice: VoiceType.low,
      unlockLevel: 3,
      playable: true,
      build: 1.02,
    ),
    CharacterDef(
      look: CrewLook.swimmer,
      name: 'Swimmer',
      theme: CharacterTheme.castaway,
      blurb: 'Overboard is a commute, not a crisis.',
      skin: _tan,
      outfit: Color(0xFF1F9AA8),
      accent: Color(0xFFFFE28A),
      gear: HeadGear.none,
      mark: FaceMark.snorkel,
      voice: VoiceType.high,
      unlockLevel: 6,
      playable: true,
      build: 0.94,
    ),

    // ---- Scavengers: the first seas --------------------------------------
    CharacterDef(
      look: CrewLook.raider,
      name: 'Log Raider',
      theme: CharacterTheme.scavenger,
      blurb: 'Takes what floats. Which is most things.',
      skin: _sand,
      outfit: Color(0xFF8A5A3B),
      accent: Color(0xFFC9483C),
      gear: HeadGear.bandana,
      mark: FaceMark.stubble,
      voice: VoiceType.mid,
    ),
    CharacterDef(
      look: CrewLook.ducker,
      name: 'Ducker',
      theme: CharacterTheme.scavenger,
      blurb: 'Ducks first, aims second. Sometimes in that order.',
      skin: _tan,
      outfit: Color(0xFFE0A73F),
      accent: Color(0xFF4C6B8A),
      gear: HeadGear.none,
      mark: FaceMark.goggles,
      voice: VoiceType.high,
      build: 0.95,
    ),

    // ---- Buccaneers ------------------------------------------------------
    CharacterDef(
      look: CrewLook.pirate,
      name: 'Pirate',
      theme: CharacterTheme.buccaneer,
      blurb: 'Traditionalist. Owns exactly one hat.',
      skin: _bronze,
      outfit: Color(0xFF4A3350),
      accent: Color(0xFFC9483C),
      gear: HeadGear.tricorn,
      mark: FaceMark.beard,
      voice: VoiceType.low,
      unlockLevel: 9,
      playable: true,
      build: 1.05,
    ),
    CharacterDef(
      look: CrewLook.captain,
      name: 'Rival Captain',
      theme: CharacterTheme.buccaneer,
      blurb: 'Convinced this sea has room for only one captain.',
      skin: _umber,
      outfit: Color(0xFF35304C),
      accent: Color(0xFFE8B33D),
      gear: HeadGear.tricorn,
      mark: FaceMark.eyePatch,
      voice: VoiceType.low,
      build: 1.08,
    ),
    CharacterDef(
      look: CrewLook.gunner,
      name: 'Deck Gunner',
      theme: CharacterTheme.buccaneer,
      blurb: 'Loads fast, listens rarely.',
      skin: _bronze,
      outfit: Color(0xFF7A4A32),
      accent: Color(0xFFD9D2C0),
      gear: HeadGear.beanie,
      mark: FaceMark.scar,
      voice: VoiceType.mid,
      build: 1.04,
    ),

    // ---- Frostbound: the mountain sea ------------------------------------
    CharacterDef(
      look: CrewLook.furlined,
      name: 'Fur-Lined',
      theme: CharacterTheme.frostbound,
      blurb: 'Three coats. Still complaining.',
      skin: _tan,
      outfit: Color(0xFF5C6E92),
      accent: Color(0xFFD8E4F2),
      gear: HeadGear.ushanka,
      mark: FaceMark.stubble,
      voice: VoiceType.low,
      unlockLevel: 12,
      playable: true,
      build: 1.1,
    ),
    CharacterDef(
      look: CrewLook.icebreaker,
      name: 'Icebreaker',
      theme: CharacterTheme.frostbound,
      blurb: 'Cracks the floe, then the jokes.',
      skin: _sand,
      outfit: Color(0xFF3E5B7A),
      accent: Color(0xFF9FE3F0),
      gear: HeadGear.hood,
      mark: FaceMark.goggles,
      voice: VoiceType.mid,
      build: 1.06,
    ),

    // ---- Sunbaked: the desert sea ----------------------------------------
    CharacterDef(
      look: CrewLook.nomad,
      name: 'Salt Nomad',
      theme: CharacterTheme.sunbaked,
      blurb: 'Crossed a dry sea to reach a wet one.',
      skin: _umber,
      outfit: Color(0xFFC9A26B),
      accent: Color(0xFF7C4B3A),
      gear: HeadGear.turban,
      mark: FaceMark.beard,
      voice: VoiceType.mid,
      unlockLevel: 15,
      playable: true,
    ),
    CharacterDef(
      look: CrewLook.duneRunner,
      name: 'Dune Runner',
      theme: CharacterTheme.sunbaked,
      blurb: 'Never stands still. Rarely stands anywhere.',
      skin: _deep,
      outfit: Color(0xFFD8894B),
      accent: Color(0xFF3F5A6B),
      gear: HeadGear.wideBrim,
      mark: FaceMark.warPaint,
      voice: VoiceType.high,
      build: 0.92,
    ),

    // ---- Emberkin: the volcano sea ---------------------------------------
    CharacterDef(
      look: CrewLook.stoker,
      name: 'Stoker',
      theme: CharacterTheme.emberkin,
      blurb: 'Warm handshake. Extremely warm.',
      skin: _deep,
      outfit: Color(0xFF4A3730),
      accent: Color(0xFFE2541E),
      gear: HeadGear.gasMask,
      mark: FaceMark.none,
      voice: VoiceType.low,
      unlockLevel: 18,
      playable: true,
      build: 1.08,
    ),
    CharacterDef(
      look: CrewLook.ashwalker,
      name: 'Ashwalker',
      theme: CharacterTheme.emberkin,
      blurb: 'Grey from boot to brow, and unbothered.',
      skin: _umber,
      outfit: Color(0xFF5A5258),
      accent: Color(0xFFFF9E4A),
      gear: HeadGear.hood,
      mark: FaceMark.scar,
      voice: VoiceType.mid,
    ),

    // ---- Harbour: the city sea -------------------------------------------
    CharacterDef(
      look: CrewLook.dockhand,
      name: 'Dockhand',
      theme: CharacterTheme.harbour,
      blurb: 'Lifts crates all day. Lifts rafts on a dare.',
      skin: _sand,
      outfit: Color(0xFFE4A63C),
      accent: Color(0xFF2E3A47),
      gear: HeadGear.hardHat,
      mark: FaceMark.moustache,
      voice: VoiceType.low,
      unlockLevel: 21,
      playable: true,
      build: 1.12,
    ),
    CharacterDef(
      look: CrewLook.neonRunner,
      name: 'Neon Runner',
      theme: CharacterTheme.harbour,
      blurb: 'Fights for the skyline. And the highlight reel.',
      skin: _tan,
      outfit: Color(0xFF2B2F52),
      accent: Color(0xFF39E0C8),
      gear: HeadGear.visor,
      mark: FaceMark.none,
      voice: VoiceType.high,
      unlockLevel: 25,
      playable: true,
      build: 0.96,
    ),
  ];

  static CharacterDef of(CrewLook look) =>
      all.firstWhere((c) => c.look == look, orElse: () => all.first);

  static CharacterDef byId(String id) =>
      all.firstWhere((c) => c.id == id, orElse: () => all.first);

  static CharacterDef get defaultPlayer => all.first;

  /// Everything the player can wear, roster order.
  static List<CharacterDef> get playable =>
      all.where((c) => c.playable).toList();

  /// Playable characters available at [level].
  static List<CharacterDef> unlockedAt(int level) =>
      playable.where((c) => c.unlockLevel <= level).toList();

  static bool isUnlocked(CharacterDef c, int level) => c.unlockLevel <= level;

  /// The characters that crew a given theme's rafts, in the order a campaign
  /// world should draw on them.
  static List<CharacterDef> ofTheme(CharacterTheme theme) =>
      all.where((c) => c.theme == theme).toList();
}
