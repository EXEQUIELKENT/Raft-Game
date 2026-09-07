import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raft_rumble/game/campaign.dart';
import 'package:raft_rumble/game/characters.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/progression.dart';
import 'package:raft_rumble/game/save.dart';

/// Captain progression.
///
/// The complaint these tests exist to pin down: the old system had eleven
/// hand-typed thresholds, stopped at level 10, and levelling up gave nothing.
/// XP was a flat 60 for a win regardless of what you beat, which made
/// replaying the easiest level the most efficient way to progress.
///
/// So the properties worth defending are (a) the curve is monotonic and goes
/// somewhere, (b) EVERY level pays out, (c) the reward table never disagrees
/// with the systems that actually gate things, and (d) a harder, cleaner,
/// faster win is always worth more XP than an easier, scrappier, longer one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SaveService.instance.data = SaveData();
  });

  group('The curve', () {
    test('rises without ever flattening or going backwards', () {
      for (int i = 1; i < Progression.thresholds.length; i++) {
        expect(Progression.thresholds[i], greaterThan(Progression.thresholds[i - 1]),
            reason: 'level ${i + 1} must cost more than level $i');
      }
      expect(Progression.thresholds.length, kMaxLevel);
      expect(Progression.thresholds.first, 0);
    });

    test('each level costs more than the one before it', () {
      // Not just monotonic — the *gaps* have to grow, or the back half of
      // the curve arrives all at once.
      var prevGap = 0;
      for (int i = 1; i < Progression.thresholds.length; i++) {
        final gap = Progression.thresholds[i] - Progression.thresholds[i - 1];
        expect(gap, greaterThanOrEqualTo(prevGap));
        prevGap = gap;
      }
    });

    test('xp maps back to the level it belongs to', () {
      for (int lvl = 1; lvl <= kMaxLevel; lvl++) {
        final at = Progression.xpAtLevel(lvl);
        expect(Progression.levelForXp(at), lvl);
        if (lvl < kMaxLevel) {
          expect(Progression.levelForXp(Progression.xpForNext(lvl) - 1), lvl,
              reason: 'one xp short of $lvl+1 is still level $lvl');
        }
      }
    });

    test('clamps at both ends rather than running off the table', () {
      expect(Progression.levelForXp(0), 1);
      expect(Progression.levelForXp(-500), 1);
      expect(Progression.levelForXp(99999999), kMaxLevel);
      expect(Progression.progress(99999999), 1.0);
      expect(Progression.progress(0), 0.0);
    });
  });

  group('Rewards', () {
    test('every level from 2 to the cap gives something', () {
      // The whole point of the rework. A level that hands over nothing is
      // the bug being fixed here.
      for (int lvl = 2; lvl <= kMaxLevel; lvl++) {
        final r = Progression.rewardFor(lvl);
        expect(r, isNotNull, reason: 'level $lvl has no reward');
        expect(r!.doubloons, greaterThan(0), reason: 'level $lvl pays nothing');
        expect(r.headline, isNotEmpty);
      }
    });

    test('later levels pay better than earlier ones', () {
      expect(Progression.rewardFor(kMaxLevel)!.doubloons,
          greaterThan(Progression.rewardFor(2)!.doubloons));
    });

    test('a weapon unlock announcement matches the weapon that actually gates',
        () {
      // Two systems know about weapon levels: WeaponDef.levelLock decides
      // what you can use, and the reward table decides what gets announced.
      // If they drift, the game either promises a weapon it will not give or
      // hands one over silently.
      for (final w in Weapons.all) {
        if (w.infinite || w.levelLock <= 1) continue;
        final r = Progression.rewardFor(w.levelLock);
        expect(r, isNotNull, reason: '${w.id} unlocks at an unrewarded level');
        expect(r!.weaponId, w.id,
            reason: '${w.id} gates at ${w.levelLock} but is announced elsewhere');
      }
    });

    test('a character unlock announcement matches the roster gate', () {
      for (final c in Cast.playable) {
        if (c.unlockLevel <= 1) continue;
        final r = Progression.rewardFor(c.unlockLevel);
        expect(r?.character, c.look,
            reason: '${c.id} unlocks at ${c.unlockLevel} but is not announced there');
      }
    });

    test('rewardsBetween covers a multi-level jump exactly once', () {
      final jump = Progression.rewardsBetween(3, 7);
      expect(jump.map((r) => r.level), [4, 5, 6, 7]);
      expect(Progression.rewardsBetween(5, 5), isEmpty,
          reason: 'no level was crossed');
      expect(Progression.rewardsBetween(9, 3), isEmpty,
          reason: 'going backwards awards nothing');
    });

    test('bonus HP accumulates across levels and never shrinks', () {
      var prev = 0.0;
      for (int lvl = 1; lvl <= kMaxLevel; lvl++) {
        final hp = Progression.bonusHpAt(lvl);
        expect(hp, greaterThanOrEqualTo(prev));
        prev = hp;
      }
      expect(Progression.bonusHpAt(kMaxLevel), greaterThan(0));
    });
  });

  group('Battle XP', () {
    test('a win pays more than a loss, all else equal', () {
      expect(Progression.battleXp(won: true, damageDealt: 100),
          greaterThan(Progression.battleXp(won: false, damageDealt: 100)));
    });

    test('a harder fight pays more than an easier one', () {
      // The bug this fixes: a flat award made farming level one the fastest
      // way to level, which is exactly backwards.
      final easy = Progression.battleXp(
          won: true, damageDealt: 200, difficultyTier: 0, rounds: 8);
      final hard = Progression.battleXp(
          won: true, damageDealt: 200, difficultyTier: 8, rounds: 8);
      expect(hard, greaterThan(easy));
    });

    test('a cleaner win pays more than a scrappier one', () {
      final scrappy = Progression.battleXp(
          won: true, damageDealt: 200, hpFraction: 0.05, rounds: 8);
      final clean = Progression.battleXp(
          won: true, damageDealt: 200, hpFraction: 0.95, rounds: 8);
      expect(clean, greaterThan(scrappy));
    });

    test('a faster win pays more than a drawn-out one', () {
      final slow = Progression.battleXp(won: true, damageDealt: 200, rounds: 20);
      final fast = Progression.battleXp(won: true, damageDealt: 200, rounds: 3);
      expect(fast, greaterThan(slow));
    });

    test('a boss is worth more than the same fight without one', () {
      final normal = Progression.battleXp(
          won: true, damageDealt: 200, difficultyTier: 5, rounds: 8);
      final boss = Progression.battleXp(
          won: true, damageDealt: 200, difficultyTier: 5, rounds: 8, isBoss: true);
      expect(boss, greaterThan(normal));
    });

    test('losing still pays something, so a bad run is not wasted', () {
      expect(Progression.battleXp(won: false, damageDealt: 0), greaterThan(0));
    });

    test('the last campaign battle out-pays the first by a wide margin', () {
      // End to end on the real tables: pushing forward has to beat farming.
      final first = Campaign.allLevels.first;
      final last = Campaign.allLevels.last;
      final firstXp = Progression.battleXp(
        won: true,
        damageDealt: 200,
        hpFraction: 0.8,
        difficultyTier: Campaign.difficultyTierOf(first),
        rounds: 8,
        isBoss: first.isBoss,
      );
      final lastXp = Progression.battleXp(
        won: true,
        damageDealt: 200,
        hpFraction: 0.8,
        difficultyTier: Campaign.difficultyTierOf(last),
        rounds: 8,
        isBoss: last.isBoss,
      );
      expect(lastXp, greaterThan(firstXp * 2));
    });

    test('campaign difficulty tiers rise monotonically through the campaign',
        () {
      var prev = -1;
      for (final l in Campaign.allLevels) {
        final t = Campaign.difficultyTierOf(l);
        expect(t, greaterThanOrEqualTo(prev));
        prev = t;
      }
    });
  });

  group('Recording a match', () {
    test('banks the rewards of every level crossed, not just the last', () {
      final svc = SaveService.instance;
      // Enough XP in one go to cross several early levels at once.
      svc.data.xp = 0;
      final before = svc.data.doubloons;
      svc.recordMatch(
          won: true, damageDealt: 4000, hpFraction: 1, difficultyTier: 10);

      expect(svc.lastXpGain, greaterThan(0));
      expect(svc.data.level, greaterThan(1));
      expect(svc.lastLevelUps, isNotEmpty);
      final promised =
          svc.lastLevelUps.fold<int>(0, (s, r) => s + r.doubloons);
      expect(svc.data.doubloons - before, promised,
          reason: 'every crossed level must actually pay out');
    });

    test('a match that crosses no level reports no level-ups', () {
      final svc = SaveService.instance;
      svc.data.xp = 5;
      svc.recordMatch(won: false, damageDealt: 0);
      expect(svc.lastLevelUps, isEmpty);
      expect(svc.data.level, 1);
    });

    test('an existing save keeps its xp and re-derives its level', () {
      // Saves in the wild only ever stored `xp`; the level was computed. So
      // the curve change must not lose anyone their progress.
      final save = SaveData();
      save.fromJson({'xp': 1200});
      expect(save.xp, 1200);
      expect(save.level, Progression.levelForXp(1200));
      expect(save.level, greaterThan(1));
    });
  });
}
