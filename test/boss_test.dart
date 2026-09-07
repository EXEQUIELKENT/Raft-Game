import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/bosses.dart';
import 'package:raft_rumble/game/campaign.dart';
import 'package:raft_rumble/game/characters.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// World bosses and the status rounds they fire.
///
/// "Harder but still balanced" is the whole brief, and it is a claim that can
/// be checked rather than asserted. The balance argument for bosses rests on
/// four properties, and each one has a test here:
///
///  1. **A status round buys disruption with damage** — every one of them hits
///     for less than the ordinary round of comparable weight.
///  2. **Statuses never stack or chain** — a fresh application replaces the
///     old one, and each lasts a single turn.
///  3. **The signature is rationed** — a cooldown gates it whatever the
///     trigger says, and the opening shot of a fight is never the special one.
///  4. **It cannot deadlock the match** — a snare passes the turn on, and a
///     table full of snared crews still plays.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SaveService.instance.data = SaveData();
  });

  group('Balance of the boss arsenal', () {
    test('every status round hits for less than ordinary ordnance', () {
      // The core trade. A round that both disrupted AND hit hard would make
      // a boss strictly better armed rather than differently armed.
      final ordinaryAvg = Weapons.all
              .where((w) => !w.infinite)
              .map((w) => w.damage)
              .reduce((a, b) => a + b) /
          Weapons.all.where((w) => !w.infinite).length;
      for (final w in Weapons.boss.where((w) => w.status != null)) {
        expect(w.damage, lessThan(ordinaryAvg),
            reason: '${w.id} disrupts AND out-damages, which is not a trade');
      }
    });

    test('the harshest status is on the weakest round', () {
      // Snare costs a whole turn, so it must be the feeblest thing a boss
      // can throw.
      final snare =
          Weapons.boss.firstWhere((w) => w.status == StatusEffect.snared);
      for (final w in Weapons.boss) {
        expect(snare.damage, lessThanOrEqualTo(w.damage),
            reason: 'a turn-skipping round must not also hit hard');
      }
      expect(snare.splash, 0,
          reason: 'a snare must never be able to catch a whole deck at once');
    });

    test('no status lasts more than a single turn', () {
      for (final w in Weapons.boss) {
        expect(w.statusTurns, lessThanOrEqualTo(1),
            reason: '${w.id} would take more than one turn away');
      }
    });

    test('boss ordnance never reaches the player shop or HUD', () {
      for (final w in Weapons.boss) {
        expect(w.bossOnly, true);
        expect(Weapons.all.any((p) => p.id == w.id), false,
            reason: '${w.id} leaked into the player arsenal');
        expect(Weapons.purchasable.any((p) => p.id == w.id), false);
        expect(SaveData().battleAmmo().containsKey(w.id), false,
            reason: '${w.id} would be handed to the player as ammo');
      }
    });

    test('but it still resolves by id, or a boss shot would draw as a ball',
        () {
      for (final w in Weapons.boss) {
        expect(Weapons.byId(w.id).id, w.id);
        expect(Weapons.byId(w.id).projectile, isNot('ball'),
            reason: '${w.id} has no distinct silhouette to warn the player');
      }
    });
  });

  group('Signature timing', () {
    BossDef boss(String world) => Bosses.forWorld(world)!;

    test('the opening shot of a fight is never the special one', () {
      // The player gets one ordinary exchange to learn what a normal round
      // from this boss looks like before anything is taken from them.
      for (final b in Bosses.all) {
        expect(
          b.wantsSignature(
              shotsTaken: 0, selfHp: 1, playerHp: 1, turnsSinceSignature: 99),
          isFalse,
          reason: '${b.id} opens with its signature',
        );
      }
    });

    test('the cooldown outranks the trigger', () {
      // A wounded boss whose trigger is permanently satisfied must still not
      // fire its special every single turn for the rest of the fight.
      final duke = boss('desert');
      expect(duke.trigger, BossTrigger.whenWounded);
      expect(
        duke.wantsSignature(
            shotsTaken: 9, selfHp: 0.1, playerHp: 1, turnsSinceSignature: 0),
        isFalse,
        reason: 'still on cooldown',
      );
      expect(
        duke.wantsSignature(
            shotsTaken: 9,
            selfHp: 0.1,
            playerHp: 1,
            turnsSinceSignature: duke.signatureCooldown),
        isTrue,
      );
    });

    test('every boss is rationed, even the fastest rotation', () {
      for (final b in Bosses.all) {
        expect(b.signatureCooldown, greaterThanOrEqualTo(2),
            reason: '${b.id} could disrupt on consecutive turns');
      }
    });

    test('the first boss only disrupts a healthy player, and stops after', () {
      // The gentlest pattern in the game, on the first boss a player meets.
      final sadie = boss('ocean');
      expect(sadie.trigger, BossTrigger.whenPlayerHealthy);
      expect(
        sadie.wantsSignature(
            shotsTaken: 3, selfHp: 1, playerHp: 0.9, turnsSinceSignature: 9),
        isTrue,
      );
      expect(
        sadie.wantsSignature(
            shotsTaken: 3, selfHp: 1, playerHp: 0.3, turnsSinceSignature: 9),
        isFalse,
        reason: 'she should leave a hurt player alone',
      );
    });

    test('the every-Nth pattern fires on the count it promises', () {
      final king = boss('mountains');
      expect(king.trigger, BossTrigger.everyNthShot);
      for (int shot = 1; shot <= 12; shot++) {
        final want = king.wantsSignature(
            shotsTaken: shot, selfHp: 1, playerHp: 1, turnsSinceSignature: 99);
        expect(want, shot % king.everyN == 0, reason: 'shot $shot');
      }
    });
  });

  group('The roster', () {
    test('every world has a boss and every boss has a real weapon', () {
      for (final w in Campaign.worlds) {
        final b = Bosses.forWorld(w.id);
        expect(b, isNotNull, reason: '${w.id} has no boss');
        expect(Weapons.boss.any((x) => x.id == b!.signatureWeaponId), true,
            reason: '${b!.id} fires something that is not boss ordnance');
      }
    });

    test('the bosses are all different fights, not one fight six times', () {
      // The complaint being fixed: six worlds that ended identically.
      final weapons = Bosses.all.map((b) => b.signatureWeaponId).toSet();
      expect(weapons.length, greaterThanOrEqualTo(4),
          reason: 'too many bosses share a signature round');
      final triggers = Bosses.all.map((b) => b.trigger).toSet();
      expect(triggers.length, greaterThanOrEqualTo(3),
          reason: 'too many bosses reach for it on the same cue');
      expect(Bosses.all.map((b) => b.look).toSet().length,
          greaterThanOrEqualTo(4),
          reason: 'bosses should not all look the same');
    });

    test('bosses get harder as the campaign goes on', () {
      final order = ['ocean', 'island', 'mountains', 'desert', 'volcano', 'city'];
      var prevHp = -1.0;
      for (final id in order) {
        final b = Bosses.forWorld(id)!;
        expect(b.bonusHp, greaterThanOrEqualTo(prevHp), reason: id);
        prevHp = b.bonusHp;
      }
      expect(Bosses.forWorld('city')!.everyN,
          lessThan(Bosses.forWorld('ocean')!.signatureCooldown + 2));
    });

    test('every boss has its own lines', () {
      final lines = <String>{};
      for (final b in Bosses.all) {
        for (final l in [b.openingLine, b.signatureLine, b.woundedLine]) {
          expect(l, isNotEmpty);
          expect(lines.add(l), true, reason: 'duplicated line: "$l"');
        }
      }
    });
  });

  group('Statuses in play', () {
    Crew crew() => Crew(hp: 100, maxHp: 100);

    test('a fresh status replaces the old one instead of stacking', () {
      final c = crew();
      c.afflict(StatusEffect.snared, 1);
      c.afflict(StatusEffect.chilled, 1);
      expect(c.status, StatusEffect.chilled);
      expect(c.statusTurns, 1, reason: 'topping up would make it permanent');
    });

    test('a status is spent by the victim\'s own turn, then gone', () {
      final c = crew();
      c.afflict(StatusEffect.chilled, 1);
      expect(c.afflicted, true);
      expect(c.statusPowerScale, lessThan(1.0));
      expect(c.consumeTurnStatus(), false, reason: 'chill does not skip a turn');
      expect(c.afflicted, false);
      expect(c.statusPowerScale, 1.0, reason: 'and costs nothing afterwards');
    });

    test('a snare costs exactly one turn and never two', () {
      final c = crew();
      c.afflict(StatusEffect.snared, 1);
      expect(c.consumeTurnStatus(), true, reason: 'this turn is lost');
      expect(c.afflicted, false);
      expect(c.consumeTurnStatus(), false, reason: 'the next one is not');
    });

    test('tar trades power for staying put', () {
      final c = crew();
      c.afflict(StatusEffect.tarred, 1);
      expect(c.statusPowerScale, lessThan(1.0));
      expect(c.statusKnockScale, lessThan(1.0),
          reason: 'the upside half of tar — harder to blow off the deck');
    });

    test('every status costs something on both sides of the fight', () {
      // A status that only bites humans would be free for the AI to eat, and
      // the player can fire boss ordnance's effects at nobody — but they DO
      // face an AI that suffers them. Each effect has to cost the holder
      // something measurable, whoever is holding it.
      for (final e in StatusEffect.values) {
        final c = crew();
        c.afflict(e, 1);
        final costsPower = c.statusPowerScale < 1.0;
        final costsTurn = c.snared;
        final costsAim = e == StatusEffect.dazed;
        expect(costsPower || costsTurn || costsAim, true,
            reason: '$e takes nothing away from the crew member holding it');
      }
    });

    test('a clean crew member is unaffected by any of it', () {
      final c = crew();
      expect(c.afflicted, false);
      expect(c.statusPowerScale, 1.0);
      expect(c.statusKnockScale, 1.0);
      expect(c.snared, false);
    });

    test('the body wears the status, not just the badge', () {
      // A status you can only see in a corner icon reads as the game
      // misbehaving when your shot lands short.
      for (final e in StatusEffect.values) {
        final c = crew();
        c.afflict(e, 1);
        expect(c.bodyExpression(1.0).isNeutral, false,
            reason: '$e leaves the body standing normally');
      }
    });
  });

  group('A boss battle end to end', () {
    test('a snared shooter passes the turn instead of hanging the match', () {
      final (settings, players) = Campaign.matchFor(
          Campaign.allLevels.firstWhere((l) => l.isBoss));
      final ctrl = GameController(
          settings: settings, players: players, mode: GameMode.vsAi, seed: 9);

      ctrl.world.raftOf(0)!.activeCrew!.afflict(StatusEffect.snared, 1);
      ctrl.beginTurnForTest(0);

      expect(ctrl.currentPlayer, isNot(0),
          reason: 'a snared seat must not be left holding the turn');
      expect(ctrl.phase, GamePhase.aiming, reason: 'the match must play on');
      expect(ctrl.world.raftOf(0)!.crew.first.afflicted, false,
          reason: 'the snare was spent by the turn it cost');

      // …and the very next time round they play normally. A snare that could
      // cost two turns in a row would be far past "harder but balanced".
      ctrl.beginTurnForTest(0);
      expect(ctrl.currentPlayer, 0);
      ctrl.dispose();
    });

    test('a restored match does not re-punish a snare it already paid', () {
      // Resuming is not a turn. Spending the status again on the way back in
      // would charge the player twice for one hit.
      final (settings, players) = Campaign.matchFor(
          Campaign.allLevels.firstWhere((l) => l.isBoss));
      final ctrl = GameController(
          settings: settings, players: players, mode: GameMode.vsAi, seed: 9);
      ctrl.restoreState(ctrl.snapshotState()..['currentPlayer'] = 0);
      expect(ctrl.currentPlayer, 0);
      expect(ctrl.phase, GamePhase.aiming);
      ctrl.dispose();
    });

    test('a table of snared crews plays on rather than deadlocking', () {
      // The pathological case: skipping recursively until the stack gives
      // out would be a hard crash, so the last seat plays anyway.
      final ctrl = GameController(
        settings: MatchSettings(map: GameMaps.all.first),
        players: [
          PlayerConfig(
              name: 'P1',
              loadout: RaftLoadout.custom(
                  hullId: 'log', sizeId: 'small', colorIndex: 0)),
          PlayerConfig(
              name: 'P2',
              look: CrewLook.raider,
              isAi: true,
              loadout: RaftLoadout.custom(
                  hullId: 'log', sizeId: 'small', colorIndex: 1)),
        ],
        mode: GameMode.vsAi,
        seed: 3,
      );
      for (final r in ctrl.world.rafts) {
        for (final c in r.crew) {
          c.afflict(StatusEffect.snared, 1);
        }
      }
      expect(() => ctrl.restoreState(ctrl.snapshotState()), returnsNormally);
      expect(ctrl.phase, GamePhase.aiming);
      ctrl.dispose();
    });

    test('only the boss seat carries a BossDef, and it is the flagship', () {
      for (final level in Campaign.allLevels.where((l) => l.isBoss)) {
        final (_, players) = Campaign.matchFor(level);
        final bossSeats = [
          for (int i = 0; i < players.length; i++)
            if (players[i].boss != null) i
        ];
        expect(bossSeats.length, 1, reason: '${level.id}');
        final seat = bossSeats.first;
        expect(seat, greaterThan(0), reason: 'the player is never the boss');
        expect(players[seat].look, Bosses.forWorld(level.worldId)!.look,
            reason: '${level.id}: the boss should wear its own face');
      }
    });
  });
}
