import 'ai.dart';
import 'battle.dart';
import 'bosses.dart';
import 'characters.dart';
import 'controller.dart';
import 'maps.dart';
import 'raft.dart';
import 'save.dart';

/// ---------------------------------------------------------------------------
/// Campaign mode: a scripted single-player progression through all six of
/// Raft Rumble's existing seas, each captained by a rival crew that gets
/// tougher as the campaign goes on. Built entirely on top of the existing
/// match machinery (MatchSettings / PlayerConfig / GameController) — a
/// campaign level is just a match with curated settings and a named AI
/// opponent, not a separate game mode under the hood.
///
/// Original premise: you're a raft captain making a name for yourself,
/// challenging the self-declared "toughest crew" on each sea in turn. No
/// characters, names, story or assets borrowed from any other game.
/// ---------------------------------------------------------------------------

const List<String> kWeaponsBasic = ['tennis', 'grenade'];
const List<String> kWeaponsMid = ['tennis', 'grenade', 'bomb'];
const List<String> kWeaponsFull = [
  'tennis', 'grenade', 'bomb', 'cluster', 'anchor',
  // The utility shelf unlocks with the late game: a shove, a burn and a
  // breaching round join every full-arsenal fight, on both sides of it.
  'gust', 'cinder', 'wrecker',
];

/// One enemy crew archetype, ported from the design mockup's `TYPES` table.
/// Determines the rival's look, toughness, raft and how shaky their aim is.
class EnemyArchetype {
  final String id;
  final String label;
  final double hp;
  final CrewLook look;
  final String hullId;
  final int crew;

  /// Innate aim sloppiness before difficulty scaling — a Log Raider is a far
  /// worse shot than a Captain even on the same difficulty.
  final double jitter;

  const EnemyArchetype({
    required this.id,
    required this.label,
    required this.hp,
    required this.look,
    required this.hullId,
    required this.jitter,
    this.crew = 1,
  });

  static const raider = EnemyArchetype(
      id: 'raider', label: 'Log Raider', hp: 40, look: CrewLook.raider, hullId: 'log', jitter: 13);
  static const ducker = EnemyArchetype(
      id: 'ducker', label: 'Ducker', hp: 55, look: CrewLook.ducker, hullId: 'tube', jitter: 11);
  static const pirate = EnemyArchetype(
      id: 'pirate', label: 'Pirate', hp: 70, look: CrewLook.pirate, hullId: 'barrel', jitter: 8);
  static const captain = EnemyArchetype(
      id: 'captain', label: 'Captain', hp: 100, look: CrewLook.captain, hullId: 'sloop',
      jitter: 5, crew: 2);
}

class CampaignLevel {
  final String id; // e.g. 'ocean_2' — stable, used as the save-data key
  final String worldId; // matches MapDef.id
  final int indexInWorld; // 0, 1, 2 (2 = the world's boss)
  final String captainName;
  final AiDifficulty aiDifficulty;

  /// Extra HP added to every enemy crew member on top of their archetype's
  /// base, so a world's later battles are tougher without new archetypes.
  final double enemyHp;

  /// The rival fleet: one raft per entry, laid out across the enemy slots.
  final List<EnemyArchetype> fleet;

  final List<String> enabledWeapons;
  final int doubloonReward;
  final bool isBoss;

  /// The third star's constraint. Rotates by battle so every fight asks for
  /// something different: opener is restraint, middle is care, boss is
  /// destruction.
  final StarObjective star3;

  /// Win within this many rounds for the second star. Grows with the fleet
  /// so a four-raft brawl is not held to a duel's pace.
  int get star2Rounds => 4 + fleet.length * 2;

  /// Flavour the world mutates: thin air, storms, or a fight that is won by
  /// outlasting rather than sinking. Null most of the time — ordinary
  /// physics is the default, not the exception.
  final LevelMutator? mutator;

  /// Rounds to stay afloat for a survival level. 0 means a normal fight to
  /// the sinking.
  final int surviveRounds;

  const CampaignLevel({
    required this.id,
    required this.worldId,
    required this.indexInWorld,
    required this.captainName,
    required this.aiDifficulty,
    required this.enemyHp,
    required this.fleet,
    required this.enabledWeapons,
    required this.doubloonReward,
    this.isBoss = false,
    this.star3 = StarObjective.tennisOnly,
    this.mutator,
    this.surviveRounds = 0,
  });

  MapDef get map => GameMaps.byId(worldId);
}

/// What the third star demands, beyond winning.
///
/// Each is checkable from the match's own end state — no new telemetry
/// beyond what the controller already tracks — and each pushes a different
/// playstyle: restraint, care, or deliberate destruction.
enum StarObjective {
  /// Win firing nothing but the infinite starter.
  tennisOnly('TENNIS ONLY', 'Win firing nothing but tennis balls'),

  /// Win without losing a single crewmate of your own.
  flawless('FLAWLESS', 'Win without losing a single crewmate'),

  /// Win having smashed at least half the breakable defences afloat.
  demolition('DEMOLITION', 'Smash at least half the buoys and crates');

  final String title;
  final String blurb;
  const StarObjective(this.title, this.blurb);

  bool satisfied({
    required Set<String> weaponsFired,
    required bool flawless,
    required double breakFraction,
  }) =>
      switch (this) {
        StarObjective.tennisOnly =>
          weaponsFired.isNotEmpty && weaponsFired.length == 1 && weaponsFired.contains('tennis'),
        StarObjective.flawless => flawless,
        StarObjective.demolition => breakFraction >= 0.5,
      };
}

/// A flavour mutation for a level: thin air that floats every shot further,
/// a storm that triples the gusts and rains on the channel, or nothing.
enum LevelMutator {
  lowGravity('THIN AIR', 'Shots fly floaty and far'),
  storm('STORM', 'Triple gusts and driving rain');

  final String title;
  final String blurb;
  const LevelMutator(this.title, this.blurb);
}

class CampaignWorld {
  final String id; // matches MapDef.id
  final List<CampaignLevel> levels;

  /// Who crews this sea's rafts. The archetype table decides how tough and
  /// how accurate a rival is; the theme decides who they *are*, so the
  /// mountain sea is manned by parka-wrapped icebreakers and the volcano by
  /// soot-blackened stokers instead of the same three silhouettes recoloured
  /// six times.
  final CharacterTheme theme;

  const CampaignWorld({
    required this.id,
    required this.levels,
    this.theme = CharacterTheme.scavenger,
  });

  MapDef get map => GameMaps.byId(id);

  /// This world's boss, if it has one.
  BossDef? get boss => Bosses.forWorld(id);
}

class Campaign {
  Campaign._();

  static CampaignLevel _lvl(
    String world,
    int i,
    String captain,
    AiDifficulty diff,
    double hp,
    List<EnemyArchetype> fleet,
    List<String> weapons,
    int reward, {
    bool boss = false,
    StarObjective? star3,
    LevelMutator? mutator,
    int surviveRounds = 0,
  }) =>
      CampaignLevel(
        id: '${world}_$i',
        worldId: world,
        indexInWorld: i,
        captainName: captain,
        aiDifficulty: diff,
        enemyHp: hp,
        fleet: fleet,
        enabledWeapons: weapons,
        doubloonReward: reward,
        isBoss: boss,
        // Openers ask restraint, middles ask care, bosses ask destruction.
        star3: star3 ??
            const [
              StarObjective.tennisOnly,
              StarObjective.flawless,
              StarObjective.demolition,
            ][i.clamp(0, 2)],
        mutator: mutator,
        surviveRounds: surviveRounds,
      );

  static const _raider = EnemyArchetype.raider;
  static const _ducker = EnemyArchetype.ducker;
  static const _pirate = EnemyArchetype.pirate;
  static const _captain = EnemyArchetype.captain;

  /// Six worlds, three captains each — ordered gentlest to hardest. Each
  /// level within a world escalates AI difficulty, enemy HP, fleet size and
  /// the weapon pool, so a world's three battles never feel like reruns of
  /// the same fight.
  static final List<CampaignWorld> worlds = [
    CampaignWorld(id: 'ocean', theme: CharacterTheme.scavenger, levels: [
      _lvl('ocean', 0, 'Salty Sam', AiDifficulty.easy, 0, [_raider, _ducker], kWeaponsBasic, 20),
      _lvl('ocean', 1, 'Wobbly Walt', AiDifficulty.normal, 10, [_raider, _ducker, _raider], kWeaponsMid, 30),
      _lvl('ocean', 2, 'Squall Sadie', AiDifficulty.hard, 20, [_ducker, _pirate, _raider], kWeaponsFull, 50, boss: true),
    ]),
    CampaignWorld(id: 'island', theme: CharacterTheme.buccaneer, levels: [
      _lvl('island', 0, 'Beach Bum Benny', AiDifficulty.easy, 5, [_raider, _ducker], kWeaponsBasic, 24),
      _lvl('island', 1, 'Tiki Tom', AiDifficulty.normal, 15, [_ducker, _pirate], kWeaponsMid, 34),
      _lvl('island', 2, 'Queen Palma', AiDifficulty.hard, 25, [_pirate, _ducker, _raider], kWeaponsFull, 55, boss: true, mutator: LevelMutator.storm),
    ]),
    CampaignWorld(id: 'mountains', theme: CharacterTheme.frostbound, levels: [
      _lvl('mountains', 0, 'Icy Ike', AiDifficulty.easy, 10, [_raider, _raider, _ducker], kWeaponsBasic, 28),
      _lvl('mountains', 1, 'Blizzard Belle', AiDifficulty.normal, 20, [_pirate, _ducker], kWeaponsMid, 38, mutator: LevelMutator.lowGravity),
      _lvl('mountains', 2, 'The Glacier King', AiDifficulty.hard, 30, [_pirate, _captain], kWeaponsFull, 60, boss: true),
    ]),
    CampaignWorld(id: 'desert', theme: CharacterTheme.sunbaked, levels: [
      _lvl('desert', 0, 'Sandstorm Sal', AiDifficulty.easy, 15, [_ducker, _raider, _ducker], kWeaponsBasic, 32),
      _lvl('desert', 1, 'Barrel Bart', AiDifficulty.normal, 25, [_pirate, _raider, _ducker], kWeaponsMid, 42, surviveRounds: 6),
      _lvl('desert', 2, 'Dune Baron Duke', AiDifficulty.hard, 35, [_captain, _pirate], kWeaponsFull, 65, boss: true),
    ]),
    CampaignWorld(id: 'volcano', theme: CharacterTheme.emberkin, levels: [
      _lvl('volcano', 0, 'Ember Eddie', AiDifficulty.normal, 20, [_pirate, _ducker], kWeaponsMid, 40),
      _lvl('volcano', 1, 'Magma Mabel', AiDifficulty.hard, 30, [_pirate, _pirate, _raider], kWeaponsMid, 50),
      _lvl('volcano', 2, 'The Volcano Vixen', AiDifficulty.hard, 40, [_captain, _pirate, _ducker], kWeaponsFull, 75, boss: true),
    ]),
    CampaignWorld(id: 'city', theme: CharacterTheme.harbour, levels: [
      _lvl('city', 0, 'Rookie Rex', AiDifficulty.normal, 25, [_pirate, _ducker, _raider], kWeaponsMid, 45),
      _lvl('city', 1, 'Skyline Sadie', AiDifficulty.hard, 35, [_captain, _pirate], kWeaponsFull, 60, surviveRounds: 8),
      _lvl('city', 2, 'Captain Chaos', AiDifficulty.expert, 50, [_captain, _pirate, _pirate, _captain], kWeaponsFull, 100, boss: true, mutator: LevelMutator.storm),
    ]),
  ];

  static List<CampaignLevel> get allLevels => [for (final w in worlds) ...w.levels];

  static CampaignLevel? levelById(String id) {
    for (final l in allLevels) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// Purely sequential: the very first level is always open, and every
  /// other level unlocks once the one immediately before it (in campaign
  /// order, across world boundaries) has been won at least once — simple
  /// to explain in the UI ("beat this to unlock the next one") and simple
  /// to implement correctly.
  static bool isUnlocked(String levelId, SaveData save) {
    final all = allLevels;
    final idx = all.indexWhere((l) => l.id == levelId);
    if (idx <= 0) return true;
    final prev = all[idx - 1];
    return (save.campaignStars[prev.id] ?? 0) > 0;
  }

  static bool isWorldUnlocked(CampaignWorld world, SaveData save) => isUnlocked(world.levels.first.id, save);

  static int starsFor(CampaignLevel level, SaveData save) => save.campaignStars[level.id] ?? 0;

  static int totalStars(SaveData save) => allLevels.fold(0, (s, l) => s + starsFor(l, save));

  static int maxStars = allLevels.length * 3;

  /// Star rating for a won level, from what the victory looked like rather
  /// than how much HP happened to survive it:
  ///   1 star: the win itself.
  ///   2 stars: won within [CampaignLevel.star2Rounds] rounds.
  ///   3 stars: the level's [StarObjective] held too.
  ///
  /// Returns the count plus the per-objective breakdown the result panel
  /// shows, so the sim and the UI can never disagree about what earned what.
  static ({int stars, bool roundsMet, bool objectiveMet}) starsForResult(
    CampaignLevel level, {
    required int rounds,
    required Set<String> weaponsFired,
    required bool flawless,
    required double breakFraction,
  }) {
    final roundsMet = rounds <= level.star2Rounds;
    final objectiveMet = level.star3.satisfied(
      weaponsFired: weaponsFired,
      flawless: flawless,
      breakFraction: breakFraction,
    );
    return (
      stars: 1 + (roundsMet ? 1 : 0) + (objectiveMet ? 1 : 0),
      roundsMet: roundsMet,
      objectiveMet: objectiveMet,
    );
  }

  /// Builds the (MatchSettings, players) pair for launching [level] as a
  /// battle — the one place that turns campaign data into an actual match,
  /// shared by the level-select screen and the game-over "next level"
  /// button so they can never drift out of sync with each other. Player 0
  /// is always the human captain; player 1 is always the level's rival AI.
  static (MatchSettings, List<PlayerConfig>) matchFor(CampaignLevel level) {
    final save = SaveService.instance.data;
    const basePlayerHp = 100.0;

    // Only as many enemy rafts as there are slots to put them on.
    final fleet = level.fleet.take(BattleConst.enemySlots.length).toList();

    final settings = MatchSettings(
      map: level.map,
      startHp: basePlayerHp,
      turnSeconds: 30,
      enabledWeapons: level.enabledWeapons,
      startHpPerPlayer: [
        basePlayerHp + save.bonusHp,
        for (int i = 0; i < fleet.length; i++)
          fleet[i].hp +
              level.enemyHp +
              // The boss's own raft carries its extra HP; its escort does
              // not. A boss that made its whole fleet tougher would just be
              // a longer fight, and the interesting part of the fight is the
              // signature round, not the health bar.
              (level.isBoss && i == _flagshipIndex(fleet)
                  ? (Bosses.forWorld(level.worldId)?.bonusHp ?? 0)
                  : 0),
      ],
      ammo: save.battleAmmo(),
      difficultyTier: difficultyTierOf(level),
      isBoss: level.isBoss,
      // The level's flavour, translated into match physics: thin air floats
      // every shot, storms triple the gusts and rain on the channel, and a
      // survival level ends at the bell instead of at a sinking.
      gravityScale: level.mutator == LevelMutator.lowGravity ? 0.55 : 1.0,
      windScale: level.mutator == LevelMutator.storm ? 2.2 : 1.0,
      storm: level.mutator == LevelMutator.storm,
      roundLimit: level.surviveRounds,
      // A demolition star is only fair on a field with something to smash.
      minBreakables: level.star3 == StarObjective.demolition ? 1 : 0,
      // Campaign has no pre-battle setup screen, so the choice between a
      // prefab hull and a deck of your own is made once in the shipyard and
      // carried into every level from there. Without this the building
      // mechanic existed only in skirmishes.
      buildYourRaft: save.buildOwnRaft,
    );

    final boss = level.isBoss ? Bosses.forWorld(level.worldId) : null;
    final flagship = _flagshipIndex(fleet);
    final theme = worldOf(level.worldId)?.theme;

    final players = [
      PlayerConfig(
        name: 'YOU',
        loadout: save.raftLoadout,
        look: Cast.byId(save.character).look,
        powerMultiplier: save.powerMultiplier,
      ),
      for (int i = 0; i < fleet.length; i++)
        PlayerConfig(
          // The level's named captain commands the toughest raft in the
          // fleet; the rest are rank-and-file crew of their archetype.
          name: i == flagship
              ? (boss?.name ?? level.captainName)
              : fleet[i].label,
          loadout: RaftLoadout.custom(
            hullId: fleet[i].hullId,
            sizeId: fleet[i].crew > 1 ? 'medium' : 'small',
            colorIndex: 7 - (i % 3),
            // Enemy HP comes wholly from the level table above.
            hpBonus: 0,
          ),
          // The boss wears its own face; its escort and every ordinary rival
          // are cast from the world's theme, so a sea's crews look like they
          // belong to it.
          look: i == flagship && boss != null
              ? boss.look
              : _castFor(theme, boss, i, fleet[i].look),
          isAi: true,
          // A boss is as sharp as its own definition says, not as sharp as
          // the level table's blanket setting for the fleet.
          aiDifficulty: i == flagship && boss != null
              ? boss.difficulty
              : level.aiDifficulty,
          aimJitter: fleet[i].jitter,
          boss: i == flagship ? boss : null,
        ),
    ];
    return (settings, players);
  }

  /// Which character crews enemy raft [i].
  ///
  /// A boss's own escort list comes first, so a named opponent arrives with
  /// the people the boss table says. Failing that the world's theme supplies
  /// the cast, and failing *that* the archetype's original look stands —
  /// which is what keeps a world with no theme set working unchanged.
  static CrewLook _castFor(
      CharacterTheme? theme, BossDef? boss, int i, CrewLook fallback) {
    if (boss != null && boss.escort.isNotEmpty) {
      return boss.escort[i % boss.escort.length];
    }
    if (theme == null) return fallback;
    final pool = Cast.ofTheme(theme);
    if (pool.isEmpty) return fallback;
    return pool[i % pool.length].look;
  }

  static CampaignWorld? worldOf(String worldId) {
    for (final w in worlds) {
      if (w.id == worldId) return w;
    }
    return null;
  }

  /// How demanding a level is, on a scale that starts at 0 for the very first
  /// battle and rises across the whole campaign. Feeds the XP award, which is
  /// what makes pushing forward pay better than farming level one.
  static int difficultyTierOf(CampaignLevel level) {
    final idx = allLevels.indexWhere((l) => l.id == level.id);
    if (idx < 0) return 0;
    return idx ~/ 2;
  }

  /// Index of the toughest raft in a fleet — the one the level's named
  /// captain personally commands.
  static int _flagshipIndex(List<EnemyArchetype> fleet) {
    var best = 0;
    for (int i = 1; i < fleet.length; i++) {
      if (fleet[i].hp > fleet[best].hp) best = i;
    }
    return best;
  }
}

/// Campaign upgrade shop: three small, safe, genuinely-wired-in upgrades
/// (not cosmetic) purchased with doubloons earned from campaign victories.
/// Each has a fixed number of tiers; higher tiers cost more and need more
/// total campaign stars to unlock, so raw doubloon-grinding alone can't
/// buy everything immediately.
enum UpgradeKind { power, plating, aim }

class UpgradeTierInfo {
  final int cost;
  final int starsRequired;
  const UpgradeTierInfo(this.cost, this.starsRequired);
}

class UpgradeDef {
  final UpgradeKind kind;
  final String name;
  final String desc;
  final List<UpgradeTierInfo> tiers; // index 0 = tier 1
  const UpgradeDef({required this.kind, required this.name, required this.desc, required this.tiers});
}

class Upgrades {
  Upgrades._();

  static const List<UpgradeDef> all = [
    UpgradeDef(
      kind: UpgradeKind.power,
      name: 'Power Shots',
      desc: 'Every shot launches a little harder.',
      tiers: [UpgradeTierInfo(40, 0), UpgradeTierInfo(90, 6), UpgradeTierInfo(160, 15)],
    ),
    UpgradeDef(
      kind: UpgradeKind.plating,
      name: 'Extra Plating',
      desc: 'Start each battle with bonus HP.',
      tiers: [UpgradeTierInfo(40, 0), UpgradeTierInfo(90, 6), UpgradeTierInfo(160, 15)],
    ),
    UpgradeDef(
      kind: UpgradeKind.aim,
      name: 'Spotter Scope',
      desc: 'Shows more of your trajectory arc before you fire.',
      tiers: [UpgradeTierInfo(40, 0), UpgradeTierInfo(90, 6), UpgradeTierInfo(160, 15)],
    ),
  ];

  static UpgradeDef of(UpgradeKind k) => all.firstWhere((u) => u.kind == k);

  /// This upgrade's effect at [tier] (0 = not purchased). Kept in one place so
  /// the shop UI and the gameplay hook can never disagree about what a tier
  /// actually does.
  static double powerMultiplierAt(int tier) => 1.0 + tier * 0.08; // up to +24% at tier 3
  static double bonusHpAt(int tier) => tier * 15.0; // up to +45 HP at tier 3

  /// Extra trajectory-preview dots shown before firing — 16 at tier 0 up to
  /// 28 at tier 3, matching the design's at-rest/dragging preview lengths.
  static int trajectoryDotsAt(int tier) => 16 + tier * 4;
}
