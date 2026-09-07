import 'dart:math';

import 'characters.dart';
import 'models.dart';

/// ---------------------------------------------------------------------------
/// Captain progression.
///
/// The old curve was eleven hand-typed thresholds ending at level 10, and
/// levelling did nothing on its own — a couple of weapons happened to be
/// gated on it and that was all. Levels arrived, said "LEVEL UP", and changed
/// nothing the player could point at.
///
/// This replaces it with three things:
///
///  * **A generated curve** to level 30, so the numbers stay smooth and there
///    is somewhere to go after the campaign's last sea.
///  * **A reward at every single level.** Never a level that gives nothing —
///    that is the whole complaint about the old system. Doubloons are the
///    filler, and they are real currency in the shop, not a participation
///    trophy.
///  * **XP that reflects how the battle went**, rather than a flat 60 for a
///    win. Beating a harder fleet, taking less damage and finishing quickly
///    all pay more, which is what makes replaying an early level for XP
///    strictly worse than pushing into a new one.
/// ---------------------------------------------------------------------------

const int kMaxLevel = 30;

/// What a level hands over. A level always gives doubloons; the other fields
/// are the occasional headline.
class LevelReward {
  final int level;
  final int doubloons;

  /// Weapon unlocked at this level, if any (matches [WeaponDef.levelLock]).
  final String? weaponId;

  /// Character unlocked for customisation, if any.
  final CrewLook? character;

  /// Rounds of [weaponId]-like ordnance handed over as a starter kit.
  final Map<String, int> ammo;

  /// Permanent bonus to every crew member's starting HP.
  final double bonusHp;

  const LevelReward({
    required this.level,
    required this.doubloons,
    this.weaponId,
    this.character,
    this.ammo = const {},
    this.bonusHp = 0,
  });

  /// A one-line description for the level-up card. Ordered by what the
  /// player will care about most.
  String get headline {
    if (weaponId != null) return '${Weapons.byId(weaponId!).name} unlocked!';
    if (character != null) return '${Cast.of(character!).name} unlocked!';
    if (bonusHp > 0) return '+${bonusHp.round()} max HP';
    if (ammo.isNotEmpty) {
      final e = ammo.entries.first;
      return '+${e.value} ${Weapons.byId(e.key).name}';
    }
    return '+$doubloons doubloons';
  }
}

/// Rank shown beside the level. Purely flavour, but it gives the back half of
/// the curve something to move towards once the unlocks thin out.
class Rank {
  final String title;
  final int fromLevel;
  const Rank(this.title, this.fromLevel);

  static const List<Rank> all = [
    Rank('Castaway', 1),
    Rank('Deckhand', 4),
    Rank('Bosun', 8),
    Rank('Navigator', 12),
    Rank('First Mate', 16),
    Rank('Captain', 20),
    Rank('Commodore', 24),
    Rank('Sea Legend', 28),
  ];

  static String forLevel(int level) {
    var title = all.first.title;
    for (final r in all) {
      if (level >= r.fromLevel) title = r.title;
    }
    return title;
  }
}

class Progression {
  Progression._();

  /// Cumulative XP needed to *reach* each level, index 0 = level 1.
  ///
  /// Generated rather than typed out: the shape is a gentle quadratic, so
  /// early levels come fast enough to teach the player that levelling is
  /// worth caring about, and later ones stretch without ever needing the
  /// kind of grind that makes people stop.
  static final List<int> thresholds = List<int>.generate(kMaxLevel, (i) {
    if (i == 0) return 0;
    // Round to a readable multiple of 25 so the HUD never shows 1,337 / 1,462.
    final raw = 55.0 * i * i + 55.0 * i;
    return (raw / 25).round() * 25;
  });

  static int levelForXp(int xp) {
    var lvl = 1;
    for (int i = 0; i < thresholds.length; i++) {
      if (xp >= thresholds[i]) lvl = i + 1;
    }
    return lvl.clamp(1, kMaxLevel);
  }

  /// Cumulative XP at which [level] began.
  static int xpAtLevel(int level) =>
      thresholds[(level - 1).clamp(0, kMaxLevel - 1)];

  /// Cumulative XP needed for the next level, or the final threshold at cap.
  static int xpForNext(int level) =>
      level >= kMaxLevel ? thresholds.last : thresholds[level];

  /// 0..1 progress through the current level. Always 1 at cap.
  static double progress(int xp) {
    final lvl = levelForXp(xp);
    if (lvl >= kMaxLevel) return 1;
    final from = xpAtLevel(lvl);
    final to = xpForNext(lvl);
    if (to <= from) return 1;
    return ((xp - from) / (to - from)).clamp(0.0, 1.0);
  }

  /// The reward table. Weapon and character unlocks are placed to line up
  /// with [WeaponDef.levelLock] and [CharacterDef.unlockLevel] — those
  /// remain the authority on whether a thing is available, and this table is
  /// what *announces* it, so the two can never claim different levels
  /// (see the progression tests).
  static final Map<int, LevelReward> _rewards = {
    for (int lvl = 2; lvl <= kMaxLevel; lvl++)
      lvl: LevelReward(
        level: lvl,
        // Grows with the level, so a level 20 unlock is not worth the same
        // as a level 3 one.
        doubloons: 25 + lvl * 5,
        weaponId: _weaponUnlockingAt(lvl),
        character: _characterUnlockingAt(lvl),
        // Every fifth level toughens the hull a little. Small steps: this is
        // on top of the shop's Extra Plating, and the two together must not
        // outrun what the campaign's enemy HP curve expects.
        bonusHp: lvl % 5 == 0 ? 4 : 0,
        ammo: _ammoGiftAt(lvl),
      ),
  };

  static LevelReward? rewardFor(int level) => _rewards[level];

  /// Every reward between [from] (exclusive) and [to] (inclusive) — what a
  /// battle that crossed several levels at once should show.
  static List<LevelReward> rewardsBetween(int from, int to) => [
        for (int l = from + 1; l <= to; l++)
          if (_rewards[l] != null) _rewards[l]!,
      ];

  /// Total permanent HP granted by every level reached at [level].
  static double bonusHpAt(int level) {
    var hp = 0.0;
    for (int l = 2; l <= level; l++) {
      hp += _rewards[l]?.bonusHp ?? 0;
    }
    return hp;
  }

  static String? _weaponUnlockingAt(int level) {
    for (final w in Weapons.all) {
      if (!w.infinite && w.levelLock == level) return w.id;
    }
    return null;
  }

  static CrewLook? _characterUnlockingAt(int level) {
    for (final c in Cast.playable) {
      if (c.unlockLevel == level) return c.look;
    }
    return null;
  }

  /// A few rounds handed over on the levels where nothing else lands, so the
  /// "filler" levels still change what the player can do in the next battle.
  static Map<String, int> _ammoGiftAt(int level) {
    if (level % 3 != 0) return const {};
    if (level < 6) return const {'grenade': 2};
    if (level < 12) return const {'bomb': 1};
    if (level < 20) return const {'cluster': 1};
    return const {'anchor': 1};
  }

  // -------------------------------------------------------------------- XP --

  /// XP for finishing a battle.
  ///
  /// A flat award made grinding the first level the most efficient way to
  /// progress, which is exactly backwards. The pieces here:
  ///
  ///  * a **win base** that scales with the fight's difficulty tier,
  ///  * **damage dealt**, so a losing effort still earns something,
  ///  * a **survival bonus** for finishing with HP left, which rewards
  ///    playing well rather than merely playing long, and
  ///  * a **speed bonus** for winning in fewer rounds.
  ///
  /// [difficultyTier] is 0 for a casual skirmish and rises through the
  /// campaign; [hpFraction] is how much of your own HP survived.
  static int battleXp({
    required bool won,
    required int damageDealt,
    double hpFraction = 0,
    int difficultyTier = 0,
    int rounds = 0,
    bool isBoss = false,
  }) {
    var xp = won ? 45 + difficultyTier * 12 : 15;
    xp += (damageDealt / 8).round();
    if (won) {
      xp += (hpFraction.clamp(0.0, 1.0) * 30).round();
      // Under six rounds is a decisive win; past twelve there is no rush
      // bonus left to give.
      if (rounds > 0 && rounds < 12) xp += (12 - rounds) * 3;
      if (isBoss) xp = (xp * 1.5).round();
    }
    return max(1, xp);
  }
}
