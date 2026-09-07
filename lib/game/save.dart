import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'campaign.dart';
import 'characters.dart';
import 'models.dart';
import 'progression.dart';
import 'raft.dart';




class SaveData {
  int xp = 0;
  int wins = 0;
  int losses = 0;
  int shotsFired = 0;
  int totalDamage = 0;
  /// Which of the [Cast] the player sails as, by [CharacterDef.id].
  ///
  /// Defaults to the castaway captain — NOT the string 'captain', which used
  /// to be a meaningless legacy label and now names the *rival* captain, an
  /// enemy-only character. [fromJson] rewrites any save still carrying it.
  String character = CrewLook.player.name;

  /// The name other captains see — over a hotspot link, and on the online
  /// server's friends lists. Kept here rather than in the online service
  /// because a LAN match needs it too, with no account involved.
  String playerName = 'Captain';
  int hatIndex = 0;
  int colorIndex = 0;

  // Raft customization
  String raftHullId = 'tube';
  int raftColorIndex = 0;
  /// Campaign raft upgrade tier — drives crew capacity and HP bonus.
  int raftTier = 0;
  /// Owned rounds by weapon id, spent in battle and restocked in the shop.
  Map<String, int> ammo = {};
  double musicVolume = 0.6;
  double sfxVolume = 0.9;
  bool vibration = true;
  int quality = 1; // 0 low, 1 med, 2 high
  double sensitivity = 1.0;
  bool aimAssist = true;
  bool showTrajectory = true;
  List<String> achievements = [];
  List<Map<String, dynamic>> matchHistory = [];

  // Campaign
  int doubloons = 0;
  /// Level id -> best star rating (1-3) ever earned there. Absent/0 means
  /// never won. Also doubles as the unlock ledger — see Campaign.isUnlocked.
  Map<String, int> campaignStars = {};
  /// Upgrade kind name -> purchased tier (0 = not purchased, up to 3).
  Map<String, int> upgradeTiers = {};

  int upgradeTier(UpgradeKind k) => upgradeTiers[k.name] ?? 0;
  double get powerMultiplier => Upgrades.powerMultiplierAt(upgradeTier(UpgradeKind.power));
  /// Bonus HP from both progression tracks: what the shop's Extra Plating was
  /// bought up to, plus the small permanent grants every fifth captain level
  /// hands over. They stack on purpose — one is spent for, the other is
  /// played for — but both are deliberately small next to the campaign's
  /// enemy HP curve.
  double get bonusHp =>
      Upgrades.bonusHpAt(upgradeTier(UpgradeKind.plating)) +
      Progression.bonusHpAt(level);
  int get trajectoryDots => Upgrades.trajectoryDotsAt(upgradeTier(UpgradeKind.aim));

  /// Captain level, from the generated curve in [Progression]. The old
  /// hand-typed `xpLevels` list stopped at 10 and is gone; existing saves
  /// carry only `xp`, so they simply re-derive their level on the new curve.
  int get level => Progression.levelForXp(xp);

  String get rank => Rank.forLevel(level);

  int get xpForNext => Progression.xpForNext(level);
  int get xpForCurrent => Progression.xpAtLevel(level);

  /// 0..1 through the current level, for the XP bar.
  double get levelProgress => Progression.progress(xp);

  bool get atMaxLevel => level >= kMaxLevel;

  List<WeaponDef> get unlockedWeapons => Weapons.unlockedAt(level);

  /// Rounds owned of [weaponId]. Infinite weapons always report -1.
  int ammoFor(String weaponId) {
    final w = Weapons.byId(weaponId);
    if (w.infinite) return -1;
    return ammo[weaponId] ?? w.startAmmo;
  }

  /// Ammo map handed to a new battle, covering every non-infinite weapon the
  /// player has unlocked so the battle layer never has to consult save data.
  Map<String, int> battleAmmo() => {
        for (final w in Weapons.all)
          if (!w.infinite && w.levelLock <= level) w.id: ammoFor(w.id),
      };

  /// The player's raft as configured by campaign progression.
  RaftLoadout get raftLoadout => RaftLoadout.fromCampaign(
        hullId: raftHullId,
        colorIndex: raftColorIndex,
        raftTier: raftTier,
      );

  /// Hulls unlocked by the current raft tier.
  List<RaftHull> get unlockedHulls => RaftHull.unlockedAt(raftTier);

  Map<String, dynamic> toJson() => {
        'xp': xp, 'wins': wins, 'losses': losses, 'shotsFired': shotsFired,
        'totalDamage': totalDamage,
        'playerName': playerName,
        'character': character, 'hatIndex': hatIndex, 'colorIndex': colorIndex,
        'raftHullId': raftHullId, 'raftColorIndex': raftColorIndex,
        'raftTier': raftTier, 'ammo': ammo,
        'musicVolume': musicVolume, 'sfxVolume': sfxVolume, 'vibration': vibration,
        'quality': quality, 'sensitivity': sensitivity, 'aimAssist': aimAssist,
        'showTrajectory': showTrajectory, 'achievements': achievements,
        'matchHistory': matchHistory,
        'doubloons': doubloons, 'campaignStars': campaignStars, 'upgradeTiers': upgradeTiers,
      };

  void fromJson(Map<String, dynamic> j) {
    xp = j['xp'] ?? 0;
    wins = j['wins'] ?? 0;
    losses = j['losses'] ?? 0;
    shotsFired = j['shotsFired'] ?? 0;
    totalDamage = j['totalDamage'] ?? 0;
    playerName = j['playerName'] ?? 'Captain';
    // Old saves stored 'captain', a label with no character behind it. It
    // now names an enemy-only definition, so anything that is not a playable
    // character falls back to the default rather than dressing the player as
    // one of their rivals.
    final savedLook = j['character'] as String?;
    final match = Cast.playable.where((c) => c.id == savedLook);
    character = match.isEmpty ? CrewLook.player.name : match.first.id;
    hatIndex = j['hatIndex'] ?? 0;
    colorIndex = j['colorIndex'] ?? 0;
    raftHullId = j['raftHullId'] ?? 'tube';
    raftColorIndex = j['raftColorIndex'] ?? 0;
    raftTier = j['raftTier'] ?? 0;
    ammo = Map<String, int>.from(j['ammo'] ?? {});
    musicVolume = (j['musicVolume'] ?? 0.6).toDouble();
    sfxVolume = (j['sfxVolume'] ?? 0.9).toDouble();
    vibration = j['vibration'] ?? true;
    doubloons = j['doubloons'] ?? 0;
    campaignStars = Map<String, int>.from(j['campaignStars'] ?? {});
    upgradeTiers = Map<String, int>.from(j['upgradeTiers'] ?? {});
    quality = j['quality'] ?? 1;
    sensitivity = (j['sensitivity'] ?? 1.0).toDouble();
    aimAssist = j['aimAssist'] ?? true;
    showTrajectory = j['showTrajectory'] ?? true;
    achievements = List<String>.from(j['achievements'] ?? []);
    matchHistory = List<Map<String, dynamic>>.from(j['matchHistory'] ?? []);
  }
}

class SaveService {
  SaveService._();
  static final SaveService instance = SaveService._();

  static const _key = 'raft_rumble_save_v1';
  SaveData data = SaveData();
  bool _loaded = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        data.fromJson(jsonDecode(raw));
      } catch (_) {}
    }
    _loaded = true;
  }

  Future<void> save() async {
    if (!_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(data.toJson()));
  }

  Future<void> reset() async {
    data = SaveData();
    await save();
  }

  /// Levels crossed by the last [recordMatch], and what they handed over.
  /// Read by the game-over screen; cleared at the start of each record.
  List<LevelReward> lastLevelUps = [];

  /// XP awarded by the last [recordMatch].
  int lastXpGain = 0;

  /// Award XP & record a match result. Returns newly unlocked achievements.
  ///
  /// [hpFraction], [difficultyTier], [rounds] and [isBoss] shape the award —
  /// see [Progression.battleXp]. They all default to the shape of a casual
  /// skirmish, so callers that do not know them still work.
  List<String> recordMatch({
    required bool won,
    required int damageDealt,
    String mode = 'AI',
    String map = 'Ocean',
    double hpFraction = 0,
    int difficultyTier = 0,
    int rounds = 0,
    bool isBoss = false,
  }) {
    data.shotsFired += 0; // shots tracked separately
    final levelBefore = data.level;
    if (won) {
      data.wins++;
    } else {
      data.losses++;
    }
    lastXpGain = Progression.battleXp(
      won: won,
      damageDealt: damageDealt,
      hpFraction: hpFraction,
      difficultyTier: difficultyTier,
      rounds: rounds,
      isBoss: isBoss,
    );
    data.xp += lastXpGain;
    // Hand over everything the crossed levels promised. Doing it here rather
    // than in the UI is what stops a player who skips the level-up card from
    // silently losing the reward.
    lastLevelUps = Progression.rewardsBetween(levelBefore, data.level);
    for (final r in lastLevelUps) {
      data.doubloons += r.doubloons;
      for (final e in r.ammo.entries) {
        data.ammo[e.key] = data.ammoFor(e.key) + e.value;
      }
    }
    data.totalDamage += damageDealt;
    data.matchHistory.insert(0, {
      'won': won,
      'mode': mode,
      'map': map,
      'damage': damageDealt,
      'date': DateTime.now().toIso8601String().substring(0, 16),
    });
    if (data.matchHistory.length > 20) data.matchHistory.removeLast();

    final newAch = <String>[];
    void ach(String id) {
      if (!data.achievements.contains(id)) {
        data.achievements.add(id);
        newAch.add(id);
      }
    }

    if (won && data.wins == 1) ach('first_win');
    if (data.wins >= 10) ach('veteran');
    if (data.wins >= 50) ach('legend');
    if (data.totalDamage >= 1000) ach('demolisher');
    if (data.totalDamage >= 10000) ach('wrecker');
    if (data.shotsFired >= 100) ach('trigger_happy');
    if (data.raftTier >= RaftTiers.maxTier) ach('shipwright');

    save();
    return newAch;
  }

  /// Records a campaign victory's *campaign-specific* rewards: doubloons
  /// (base reward + a bonus per star) and the best-ever star rating for
  /// that level (never downgrades a level you've since gotten worse at).
  ///
  /// Deliberately does NOT call [recordMatch] itself — GameController
  /// already calls that for every vs-AI match where the human is player 0
  /// (campaign battles included, see _checkGameOver), so campaign play
  /// already contributes to the same XP/weapon-unlock progression ranked
  /// play does automatically. Calling it again here would double-count
  /// wins/XP/damage for every campaign victory. Returns the doubloons
  /// actually awarded.
  int recordCampaignLevel({required CampaignLevel level, required int stars}) {
    final prevBest = data.campaignStars[level.id] ?? 0;
    if (stars > prevBest) data.campaignStars[level.id] = stars;
    final reward = level.doubloonReward + stars * 10;
    data.doubloons += reward;
    save();
    return reward;
  }

  /// Buys one pack of [weaponId] rounds. Returns false when the player can't
  /// afford it or the weapon isn't purchasable.
  bool purchaseAmmo(String weaponId) {
    final w = Weapons.byId(weaponId);
    if (w.infinite) return false;
    if (data.doubloons < w.packCost) return false;
    data.doubloons -= w.packCost;
    data.ammo[w.id] = data.ammoFor(w.id) + w.packSize;
    save();
    return true;
  }

  /// Buys the next raft tier. Returns false when maxed, unaffordable, or not
  /// enough campaign stars have been earned yet.
  bool purchaseRaftTier() {
    final next = RaftTiers.next(data.raftTier);
    if (next == null) return false;
    if (data.doubloons < next.cost) return false;
    if (Campaign.totalStars(data) < next.starsRequired) return false;
    data.doubloons -= next.cost;
    data.raftTier = next.tier;
    save();
    return true;
  }

  /// True if the tier was purchased (cost deducted); false if the player
  /// can't afford it, hasn't earned enough campaign stars yet, or the next
  /// tier doesn't exist (already maxed).
  bool purchaseUpgrade(UpgradeKind kind) {
    final def = Upgrades.of(kind);
    final current = data.upgradeTier(kind);
    if (current >= def.tiers.length) return false;
    final next = def.tiers[current];
    if (data.doubloons < next.cost) return false;
    if (Campaign.totalStars(data) < next.starsRequired) return false;
    data.doubloons -= next.cost;
    data.upgradeTiers[kind.name] = current + 1;
    save();
    return true;
  }

  static const Map<String, Map<String, String>> achievementInfo = {
    'first_win': {'name': 'First Splash', 'desc': 'Win your first battle'},
    'veteran': {'name': 'Sea Dog', 'desc': 'Win 10 battles'},
    'legend': {'name': 'Raft Legend', 'desc': 'Win 50 battles'},
    'demolisher': {'name': 'Demolisher', 'desc': 'Deal 1,000 total damage'},
    'wrecker': {'name': 'Wrecking Crew', 'desc': 'Deal 10,000 total damage'},
    'trigger_happy': {'name': 'Trigger Happy', 'desc': 'Fire 100 shots'},
    'shipwright': {'name': 'Master Shipwright', 'desc': 'Fully upgrade your raft'},
  };
}
