import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/campaign.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/save.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // isolate each test from whatever an earlier one left in SharedPreferences
    SaveService.instance.data = SaveData();
  });

  test('Campaign has 6 worlds x 3 levels, unique ids, last level of each world is the boss', () {
    expect(Campaign.worlds.length, 6);
    for (final w in Campaign.worlds) {
      expect(w.levels.length, 3);
      expect(w.levels.last.isBoss, true, reason: '${w.id}: last level should be the boss');
      expect(w.levels.take(2).every((l) => !l.isBoss), true, reason: '${w.id}: only the last level should be a boss');
      // every level's map must resolve to a real, matching MapDef
      for (final l in w.levels) {
        expect(l.map.id, w.id);
        expect(GameMaps.all.any((m) => m.id == l.id.split('_').first), true);
      }
    }
    expect(Campaign.allLevels.length, 18);
    expect(Campaign.allLevels.map((l) => l.id).toSet().length, 18, reason: 'level ids must be unique');
  });

  test('Levels unlock strictly sequentially, world 1 level 1 always open', () {
    final save = SaveData();
    final all = Campaign.allLevels;
    expect(Campaign.isUnlocked(all[0].id, save), true);
    for (int i = 1; i < all.length; i++) {
      expect(Campaign.isUnlocked(all[i].id, save), false, reason: 'level $i should start locked');
    }
    // winning level 0 with any stars unlocks level 1 only
    save.campaignStars[all[0].id] = 1;
    expect(Campaign.isUnlocked(all[1].id, save), true);
    expect(Campaign.isUnlocked(all[2].id, save), false);
    // a whole world unlocks by beating the previous world's boss
    final world0Boss = Campaign.worlds[0].levels.last;
    for (final l in Campaign.worlds[0].levels) {
      save.campaignStars[l.id] = 1;
    }
    expect(Campaign.starsFor(world0Boss, save), 1);
    expect(Campaign.isWorldUnlocked(Campaign.worlds[1], save), true);
    expect(Campaign.isWorldUnlocked(Campaign.worlds[2], save), false);
  });

  test('Star rating thresholds match HP-remaining fractions', () {
    expect(Campaign.starsForHpFraction(1.0), 3);
    expect(Campaign.starsForHpFraction(0.8), 3);
    expect(Campaign.starsForHpFraction(0.79), 2);
    expect(Campaign.starsForHpFraction(0.5), 2);
    expect(Campaign.starsForHpFraction(0.49), 1);
    expect(Campaign.starsForHpFraction(0.0), 1);
  });

  test('recordCampaignLevel awards doubloons and never downgrades a level\'s best star rating', () {
    final level = Campaign.allLevels.first;
    final r1 = SaveService.instance.recordCampaignLevel(level: level, stars: 2);
    expect(r1, level.doubloonReward + 20);
    expect(SaveService.instance.data.doubloons, r1);
    expect(SaveService.instance.data.campaignStars[level.id], 2);

    // a worse replay must not downgrade the recorded best
    SaveService.instance.recordCampaignLevel(level: level, stars: 1);
    expect(SaveService.instance.data.campaignStars[level.id], 2);

    // a better replay does upgrade it, and pays out again
    final before = SaveService.instance.data.doubloons;
    final r3 = SaveService.instance.recordCampaignLevel(level: level, stars: 3);
    expect(SaveService.instance.data.campaignStars[level.id], 3);
    expect(SaveService.instance.data.doubloons, before + r3);
  });

  test('purchaseUpgrade enforces cost and star requirements, and actually changes gameplay values', () {
    final save = SaveService.instance.data;
    expect(save.upgradeTier(UpgradeKind.power), 0);
    expect(save.powerMultiplier, 1.0);

    // can't afford tier 1 yet
    expect(SaveService.instance.purchaseUpgrade(UpgradeKind.power), false);
    expect(save.upgradeTier(UpgradeKind.power), 0);

    save.doubloons = 1000;
    expect(SaveService.instance.purchaseUpgrade(UpgradeKind.power), true);
    expect(save.upgradeTier(UpgradeKind.power), 1);
    expect(save.powerMultiplier, greaterThan(1.0));
    expect(save.doubloons, 1000 - Upgrades.of(UpgradeKind.power).tiers[0].cost);

    // tier 2 requires total campaign stars, not just doubloons
    expect(SaveService.instance.purchaseUpgrade(UpgradeKind.power), false, reason: 'not enough total stars for tier 2 yet');
    expect(save.upgradeTier(UpgradeKind.power), 1);

    for (int i = 0; i < 6; i++) {
      save.campaignStars[Campaign.allLevels[i].id] = 1;
    }
    expect(Campaign.totalStars(save), greaterThanOrEqualTo(6));
    expect(SaveService.instance.purchaseUpgrade(UpgradeKind.power), true);
    expect(save.upgradeTier(UpgradeKind.power), 2);

    // plating/scope upgrades actually move the numbers they claim to
    expect(Upgrades.bonusHpAt(0), 0);
    expect(Upgrades.bonusHpAt(3), greaterThan(0));
    expect(Upgrades.trajectoryDotsAt(3), greaterThan(Upgrades.trajectoryDotsAt(0)));
  });

  test('Every campaign level launches a real, playable match (all 18, no crash, valid rafts)', () {
    for (final level in Campaign.allLevels) {
      final (settings, players) = Campaign.matchFor(level);
      final fleetSize = level.fleet.take(BattleConst.enemySlots.length).length;

      expect(players.length, fleetSize + 1, reason: '${level.id}: one seat per raft plus the player');
      expect(players.first.isAi, false);
      expect(players.skip(1).every((p) => p.isAi), true);
      expect(players[1].aiDifficulty, level.aiDifficulty);
      expect(settings.map.id, level.worldId);
      expect(settings.enabledWeapons, level.enabledWeapons);

      final ctrl = GameController(settings: settings, players: players, mode: GameMode.vsAi, seed: 55);
      expect(ctrl.phase, GamePhase.aiming, reason: '${level.id}: should start in aiming');

      final me = ctrl.world.raftOf(0);
      expect(me, isNotNull, reason: '${level.id}: player raft missing');
      // Chapter one starts with a two-person crew (raft tier 0).
      expect(me!.crew.length, greaterThanOrEqualTo(2), reason: '${level.id}: player crew too small');
      expect(me.alive, true);

      for (int i = 0; i < fleetSize; i++) {
        final enemy = ctrl.world.raftOf(i + 1);
        expect(enemy, isNotNull, reason: '${level.id}: enemy raft $i missing');
        expect(enemy!.alive, true);
        // Enemy HP reflects the archetype plus the level's difficulty bump.
        expect(enemy.crew.first.maxHp, level.fleet[i].hp + level.enemyHp);
      }

      // Rafts must never share a slot, or they'd draw on top of each other.
      final xs = ctrl.world.rafts.map((r) => r.x).toList();
      expect(xs.toSet().length, xs.length, reason: '${level.id}: two rafts share an x slot');

      ctrl.dispose();
    }
  });
}
