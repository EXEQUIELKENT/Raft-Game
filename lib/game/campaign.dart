import 'ai.dart';
import 'battle.dart';
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
const List<String> kWeaponsFull = ['tennis', 'grenade', 'bomb', 'cluster', 'anchor'];

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
  });

  MapDef get map => GameMaps.byId(worldId);
}

class CampaignWorld {
  final String id; // matches MapDef.id
  final List<CampaignLevel> levels;
  const CampaignWorld({required this.id, required this.levels});

  MapDef get map => GameMaps.byId(id);
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
    CampaignWorld(id: 'ocean', levels: [
      _lvl('ocean', 0, 'Salty Sam', AiDifficulty.easy, 0, [_raider, _ducker], kWeaponsBasic, 20),
      _lvl('ocean', 1, 'Wobbly Walt', AiDifficulty.normal, 10, [_raider, _ducker, _raider], kWeaponsMid, 30),
      _lvl('ocean', 2, 'Squall Sadie', AiDifficulty.hard, 20, [_ducker, _pirate, _raider], kWeaponsFull, 50, boss: true),
    ]),
    CampaignWorld(id: 'island', levels: [
      _lvl('island', 0, 'Beach Bum Benny', AiDifficulty.easy, 5, [_raider, _ducker], kWeaponsBasic, 24),
      _lvl('island', 1, 'Tiki Tom', AiDifficulty.normal, 15, [_ducker, _pirate], kWeaponsMid, 34),
      _lvl('island', 2, 'Queen Palma', AiDifficulty.hard, 25, [_pirate, _ducker, _raider], kWeaponsFull, 55, boss: true),
    ]),
    CampaignWorld(id: 'mountains', levels: [
      _lvl('mountains', 0, 'Icy Ike', AiDifficulty.easy, 10, [_raider, _raider, _ducker], kWeaponsBasic, 28),
      _lvl('mountains', 1, 'Blizzard Belle', AiDifficulty.normal, 20, [_pirate, _ducker], kWeaponsMid, 38),
      _lvl('mountains', 2, 'The Glacier King', AiDifficulty.hard, 30, [_pirate, _captain], kWeaponsFull, 60, boss: true),
    ]),
    CampaignWorld(id: 'desert', levels: [
      _lvl('desert', 0, 'Sandstorm Sal', AiDifficulty.easy, 15, [_ducker, _raider, _ducker], kWeaponsBasic, 32),
      _lvl('desert', 1, 'Barrel Bart', AiDifficulty.normal, 25, [_pirate, _raider, _ducker], kWeaponsMid, 42),
      _lvl('desert', 2, 'Dune Baron Duke', AiDifficulty.hard, 35, [_captain, _pirate], kWeaponsFull, 65, boss: true),
    ]),
    CampaignWorld(id: 'volcano', levels: [
      _lvl('volcano', 0, 'Ember Eddie', AiDifficulty.normal, 20, [_pirate, _ducker], kWeaponsMid, 40),
      _lvl('volcano', 1, 'Magma Mabel', AiDifficulty.hard, 30, [_pirate, _pirate, _raider], kWeaponsMid, 50),
      _lvl('volcano', 2, 'The Volcano Vixen', AiDifficulty.hard, 40, [_captain, _pirate, _ducker], kWeaponsFull, 75, boss: true),
    ]),
    CampaignWorld(id: 'city', levels: [
      _lvl('city', 0, 'Rookie Rex', AiDifficulty.normal, 25, [_pirate, _ducker, _raider], kWeaponsMid, 45),
      _lvl('city', 1, 'Skyline Sadie', AiDifficulty.hard, 35, [_captain, _pirate], kWeaponsFull, 60),
      _lvl('city', 2, 'Captain Chaos', AiDifficulty.expert, 50, [_captain, _pirate, _pirate, _captain], kWeaponsFull, 100, boss: true),
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

  /// Win-quality -> star rating, based on how much of the player's own
  /// starting HP survived the battle — visible the whole match via the HP
  /// bar, so it's an intuitive target rather than a hidden metric.
  static int starsForHpFraction(double hpFraction) {
    if (hpFraction >= 0.8) return 3;
    if (hpFraction >= 0.5) return 2;
    return 1;
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
        for (final e in fleet) e.hp + level.enemyHp,
      ],
      ammo: save.battleAmmo(),
    );

    final players = [
      PlayerConfig(
        name: 'YOU',
        loadout: save.raftLoadout,
        powerMultiplier: save.powerMultiplier,
      ),
      for (int i = 0; i < fleet.length; i++)
        PlayerConfig(
          // The level's named captain commands the toughest raft in the
          // fleet; the rest are rank-and-file crew of their archetype.
          name: i == _flagshipIndex(fleet) ? level.captainName : fleet[i].label,
          loadout: RaftLoadout.custom(
            hullId: fleet[i].hullId,
            sizeId: fleet[i].crew > 1 ? 'medium' : 'small',
            colorIndex: 7 - (i % 3),
            // Enemy HP comes wholly from the level table above.
            hpBonus: 0,
          ),
          look: fleet[i].look,
          isAi: true,
          aiDifficulty: level.aiDifficulty,
          aimJitter: fleet[i].jitter,
        ),
    ];
    return (settings, players);
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
