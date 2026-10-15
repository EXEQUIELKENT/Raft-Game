import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/campaign.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// Star objectives (win fast, win constrained) and level mutators
/// (thin air, storms, survival): what each star demands, and that each
/// flavour actually changes the physics or the ending.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
  });

  RaftLoadout loadout({String hull = 'tube', String size = 'medium', int color = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  GameController newMatch({
    int seed = 42,
    MatchSettings? settings,
  }) {
    return GameController(
      settings: settings ??
          MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
      players: [
        PlayerConfig(name: 'P1', loadout: loadout()),
        PlayerConfig(
          name: 'P2',
          loadout: loadout(hull: 'log', color: 1),
          isAi: true,
          aiDifficulty: AiDifficulty.easy,
        ),
      ],
      mode: GameMode.vsAi,
      seed: seed,
    );
  }

  group('Star objectives', () {
    test('Each constraint is satisfied exactly when it should be', () {
      expect(
          StarObjective.tennisOnly.satisfied(
              weaponsFired: {'tennis'}, flawless: false, breakFraction: 0),
          true);
      expect(
          StarObjective.tennisOnly.satisfied(
              weaponsFired: {'tennis', 'grenade'},
              flawless: true,
              breakFraction: 1),
          false,
          reason: 'one non-starter round voids restraint');
      expect(
          StarObjective.tennisOnly.satisfied(
              weaponsFired: {}, flawless: true, breakFraction: 0),
          false,
          reason: 'firing nothing is not restraint, it is a bye');
      expect(
          StarObjective.flawless.satisfied(
              weaponsFired: {'bomb'}, flawless: true, breakFraction: 0),
          true);
      expect(
          StarObjective.flawless.satisfied(
              weaponsFired: {'tennis'}, flawless: false, breakFraction: 0),
          false);
      expect(
          StarObjective.demolition.satisfied(
              weaponsFired: {'tennis'}, flawless: false, breakFraction: 0.5),
          true,
          reason: 'half the defences smashed is enough');
      expect(
          StarObjective.demolition.satisfied(
              weaponsFired: {'tennis'}, flawless: false, breakFraction: 0.49),
          false);
    });

    test('The speed target grows with the fleet', () {
      final small = Campaign.levelById('ocean_0')!;
      final big = Campaign.levelById('city_2')!;
      expect(small.star2Rounds, 4 + small.fleet.length * 2);
      expect(big.star2Rounds, greaterThan(small.star2Rounds),
          reason: 'a four-raft brawl is not held to a duel\'s pace');
    });

    test('Battles rotate constraints: restraint, care, destruction', () {
      for (final world in Campaign.worlds) {
        expect(world.levels[0].star3, StarObjective.tennisOnly);
        expect(world.levels[1].star3, StarObjective.flawless);
        expect(world.levels[2].star3, StarObjective.demolition);
      }
    });

    test('Only the human seat feeds the tennis-only ledger', () {
      final ctrl = newMatch();
      ctrl.stepForTest(1 / 60);
      expect(ctrl.humanWeaponsUsed, isEmpty);

      ctrl.humanFire();
      expect(ctrl.humanWeaponsUsed, {'tennis'});

      expect(ctrl.selectWeapon('grenade'), true);
      // The turn is spent — the second shot goes on the player's NEXT turn,
      // once the AI has had its go.
      var frames = 0;
      while (!(ctrl.phase == GamePhase.aiming &&
              ctrl.currentPlayer == 0 &&
              ctrl.canHumanAct) &&
          frames++ < 3000) {
        ctrl.stepForTest(1 / 60);
      }
      expect(ctrl.canHumanAct, true, reason: 'the turn came back around');
      ctrl.humanFire();
      expect(ctrl.humanWeaponsUsed, {'tennis', 'grenade'});
      ctrl.dispose();
    });

    test('Demolition fields always hold something to smash', () {
      // Mountains list no breakable kinds at all — the guarantee still has
      // to produce one, on every seed.
      for (int seed = 0; seed < 40; seed++) {
        final world = BattleWorld(
            map: GameMaps.byId('mountains'), seed: seed, minBreakables: 1);
        expect(world.breakablesTotal, greaterThanOrEqualTo(1),
            reason: 'seed $seed rolled a field with nothing shootable');
      }
      // And breaking registers.
      final world = BattleWorld(
          map: GameMaps.byId('city'), seed: 5, minBreakables: 1);
      final target =
          world.obstacles.firstWhere((o) => o.destructible);
      expect(world.breakablesBroken, 0);
      target.hits = target.maxHits;
      expect(target.broken, true);
      expect(world.breakablesBroken, 1);
    });
  });

  group('Thin air', () {
    test('Low gravity carries the same shot further', () {
      final world = BattleWorld(map: GameMaps.all.first, seed: 9);
      world.addRaft(Raft(
        playerIndex: 0, x: BattleConst.playerX, loadout: loadout(),
        look: CrewLook.player, label: 'P1', facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      final me = world.raftOf(0)!;

      world.gravityScale = 1.0;
      final normal = world.landingX(
          from: me.muzzle(), angleDeg: 45, power: 70, facing: 1, weapon: Weapons.starter);
      world.gravityScale = 0.55;
      final floaty = world.landingX(
          from: me.muzzle(), angleDeg: 45, power: 70, facing: 1, weapon: Weapons.starter);

      expect(floaty, greaterThan(normal + 200),
          reason: 'thin air must change real decisions, not decimals');
    });

    test('The AI solves and lands under thin air', () {
      final world = BattleWorld(map: GameMaps.byId('mountains'), seed: 21);
      world.gravityScale = 0.55;
      world.addRaft(Raft(
        playerIndex: 0, x: BattleConst.playerX, loadout: loadout(),
        look: CrewLook.player, label: 'P1', facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      world.addRaft(Raft(
        playerIndex: 1, x: BattleConst.enemySlots.first, loadout: loadout(hull: 'log'),
        look: CrewLook.raider, label: 'AI', facing: -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      final me = world.raftOf(0)!;
      final foe = world.raftOf(1)!;

      final ai = AiController(AiDifficulty.expert, seed: 3);
      final shot = ai.plan(
        from: me.muzzle(aimAngleDeg: 45, weapon: Weapons.starter),
        targetPos: foe.crewPos(0),
        facing: 1,
        arsenal: [Weapons.starter],
        muzzleAt: (a) => me.muzzle(aimAngleDeg: a, weapon: Weapons.starter),
        baseJitter: 0,
        gravityScale: 0.55,
      );
      world.fire(
        from: me.muzzle(aimAngleDeg: shot.angle, weapon: shot.weapon),
        angleDeg: shot.angle, power: shot.power, facing: 1,
        weapon: shot.weapon, owner: 0,
      );
      ShotOutcome? outcome;
      for (int i = 0; i < 600 && outcome == null; i++) {
        outcome = world.stepShot();
      }
      expect(outcome, isNotNull);
      expect(outcome!.hitSomething, true,
          reason: 'a gravity-aware solution lands in thin air too');
    });
  });

  group('Storms', () {
    test('A storm multiplies the roll past the ordinary cap', () {
      const seed = 77;
      const bias = 0.0;
      final calm = Wind.forTurn(seed: seed, turn: 4, bias: bias);
      final world = BattleWorld(map: GameMaps.all.first, seed: seed);
      world.windScale = 2.2;
      world.rollWind(4);
      expect(world.wind, (calm * 2.2).clamp(-BattleConst.windLimit * 2.2, BattleConst.windLimit * 2.2));
      var stormy = false;
      for (int t = 1; t <= 60; t++) {
        world.rollWind(t);
        if (world.wind.abs() > BattleConst.windMax) stormy = true;
      }
      expect(stormy, true, reason: 'storms must sometimes exceed fair weather');
    });

    test('Boss storm levels actually bring weather', () {
      for (final id in ['island_2', 'city_2']) {
        final (settings, _) = Campaign.matchFor(Campaign.levelById(id)!);
        expect(settings.storm, true, reason: '$id should storm');
        expect(settings.windScale, greaterThan(1.5));
      }
      final (plain, _) = Campaign.matchFor(Campaign.levelById('ocean_0')!);
      expect(plain.storm, false);
      expect(plain.windScale, 1.0);
      expect(plain.gravityScale, 1.0);
    });
  });

  group('Survival levels', () {
    test('Outlasting the limit wins by health, ties to the survivor', () {
      final settings = MatchSettings(
          map: GameMaps.all.first, startHp: 100, turnSeconds: 30, roundLimit: 2);
      final ctrl = newMatch(settings: settings);
      ctrl.stepForTest(1 / 60);

      // Bloody the enemy so the judgement has something to read.
      final foe = ctrl.world.raftOf(1)!;
      for (final c in foe.crew) {
        c.hp = 1;
      }
      // Fire wide into the water to hand turns over fast.
      var frames = 0;
      while (ctrl.phase != GamePhase.gameOver && frames++ < 4000) {
        if (ctrl.canHumanAct) {
          ctrl.aimAngle = 6;
          ctrl.aimPower = 10;
          ctrl.humanFire();
        }
        ctrl.stepForTest(1 / 60);
      }

      expect(ctrl.phase, GamePhase.gameOver);
      expect(ctrl.winner, 0, reason: 'healthier at the bell takes it');
      expect(ctrl.statusMessage, 'SURVIVED!');
      ctrl.dispose();
    });

    test('Sinking the enemy first still wins normally under a limit', () {
      final settings = MatchSettings(
          map: GameMaps.all.first, startHp: 100, turnSeconds: 30, roundLimit: 8);
      final ctrl = newMatch(settings: settings);
      ctrl.stepForTest(1 / 60);

      // Sink them outright on the first exchange.
      final foe = ctrl.world.raftOf(1)!;
      for (final c in foe.crew) {
        c.hp = 0;
      }
      var frames = 0;
      while (ctrl.phase != GamePhase.gameOver && frames++ < 2000) {
        if (ctrl.canHumanAct) {
          ctrl.aimAngle = 6;
          ctrl.aimPower = 10;
          ctrl.humanFire();
        }
        ctrl.stepForTest(1 / 60);
      }

      expect(ctrl.phase, GamePhase.gameOver);
      expect(ctrl.winner, 0);
      expect(ctrl.statusMessage, isNot('SURVIVED!'),
          reason: 'a sinking is a sinking, not a decision');
      ctrl.dispose();
    });

    test('Levels declare their flavour in the table', () {
      expect(Campaign.levelById('desert_1')!.surviveRounds, 6);
      expect(Campaign.levelById('city_1')!.surviveRounds, 8);
      expect(Campaign.levelById('ocean_0')!.surviveRounds, 0);
      expect(Campaign.levelById('mountains_1')!.mutator, LevelMutator.lowGravity);
      final (thin, _) =
          Campaign.matchFor(Campaign.levelById('mountains_1')!);
      expect(thin.gravityScale, 0.55);
      for (final level in Campaign.allLevels.where(
          (l) => l.star3 == StarObjective.demolition)) {
        final (settings, _) = Campaign.matchFor(level);
        expect(settings.minBreakables, greaterThanOrEqualTo(1),
            reason: '${level.id} promises demolition, so its field is guaranteed');
      }
    });
  });
}
