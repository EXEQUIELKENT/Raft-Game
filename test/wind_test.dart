import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// Seeded per-turn wind: a deterministic push on every shot, identical on
/// both devices of a networked match with no traffic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
  });

  RaftLoadout loadout({String hull = 'tube', String size = 'medium', int color = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  BattleWorld twoRafts({int seed = 42}) {
    final world = BattleWorld(map: GameMaps.all.first, seed: seed);
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
    return world;
  }

  group('Wind.forTurn', () {
    test('Is a pure function of seed, turn and bias', () {
      final a = Wind.forTurn(seed: 42, turn: 3, bias: 0);
      final b = Wind.forTurn(seed: 42, turn: 3, bias: 0);
      expect(a, b, reason: 'both networked devices must derive the same air');
    });

    test('Varies turn to turn and stays inside the limit', () {
      final seen = <double>{
        for (int t = 1; t <= 30; t++) Wind.forTurn(seed: 99, turn: t, bias: 0)
      };
      expect(seen.length, greaterThan(20), reason: 'nearly every turn blows different air');
      for (final w in seen) {
        expect(w.abs(), lessThanOrEqualTo(BattleConst.windLimit));
      }
    });

    test('Map bias shifts the mean without breaking the cap', () {
      var sum = 0.0;
      const n = 200;
      for (int t = 1; t <= n; t++) {
        sum += Wind.forTurn(seed: 7, turn: t, bias: 0.02);
      }
      expect(sum / n, closeTo(0.02, 0.01));
    });

    test('Calm and pips read sanely', () {
      expect(Wind.calm(0), true);
      expect(Wind.calm(0.001), true);
      expect(Wind.calm(BattleConst.windMax), false);
      expect(Wind.pips(0), 0);
      expect(Wind.pips(BattleConst.windMax), 5);
      expect(Wind.pips(-BattleConst.windLimit), 5);
    });
  });

  group('Wind in flight', () {
    test('Pushes the landing downwind, by a playable amount', () {
      final world = twoRafts();
      final me = world.raftOf(0)!;

      world.wind = 0;
      final still = world.landingX(
          from: me.muzzle(), angleDeg: 45, power: 80, facing: 1, weapon: Weapons.starter);
      world.wind = BattleConst.windMax;
      final down = world.landingX(
          from: me.muzzle(), angleDeg: 45, power: 80, facing: 1, weapon: Weapons.starter);
      world.wind = -BattleConst.windMax;
      final up = world.landingX(
          from: me.muzzle(), angleDeg: 45, power: 80, facing: 1, weapon: Weapons.starter);

      expect(down, greaterThan(still));
      expect(up, lessThan(still));
      expect(down - still, lessThan(320), reason: 'a full gale moves, not decides');
      expect(down - still, greaterThan(40), reason: '...but it must be worth compensating for');
    });

    test('A real in-flight shot drifts with the set wind', () {
      ShotOutcome? fly(double wind) {
        final world = twoRafts();
        world.wind = wind;
        final me = world.raftOf(0)!;
        world.fire(
          from: Offset(me.x, BattleConst.waterY - 60),
          angleDeg: 30, power: 60, facing: 1,
          weapon: Weapons.starter, owner: 0,
        );
        ShotOutcome? outcome;
        for (int i = 0; i < 400 && outcome == null; i++) {
          outcome = world.stepShot();
        }
        return outcome;
      }

      // A low flat shot over open water: nothing to hit, so both resolve as
      // misses and the only difference is where the wind carried them.
      final calm = fly(0)!;
      final pushed = fly(BattleConst.windMax)!;
      expect(pushed.impact.dx, greaterThan(calm.impact.dx + 30));
    });
  });

  group('Wind and the AI', () {
    test('The solver compensates: a solved shot lands in a full gale either way', () {
      for (final wind in [BattleConst.windMax, -BattleConst.windMax]) {
        final world = twoRafts(seed: 11);
        world.rollWind(1);
        world.wind = wind; // pin the worst case, not the rolled one
        final me = world.raftOf(0)!;
        final foe = world.raftOf(1)!;

        final ai = AiController(AiDifficulty.expert, seed: 1);
        final shot = ai.plan(
          from: me.muzzle(aimAngleDeg: 45, weapon: Weapons.starter),
          targetPos: foe.crewPos(0),
          facing: 1,
          arsenal: [Weapons.starter],
          muzzleAt: (a) => me.muzzle(aimAngleDeg: a, weapon: Weapons.starter),
          baseJitter: 0,
          wind: wind,
        );
        world.fire(
          from: me.muzzle(aimAngleDeg: shot.angle, weapon: shot.weapon),
          angleDeg: shot.angle, power: shot.power, facing: 1,
          weapon: shot.weapon, owner: 0,
        );
        ShotOutcome? outcome;
        for (int i = 0; i < 400 && outcome == null; i++) {
          outcome = world.stepShot();
        }
        expect(outcome, isNotNull);
        expect(outcome!.hitSomething, true,
            reason: 'a wind-aware solution lands in a ${wind > 0 ? 'tailwind' : 'headwind'}');
      }
    });
  });

  group('Wind per turn', () {
    GameController newMatch({int seed = 42}) {
      return GameController(
        settings: MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
        players: [
          PlayerConfig(name: 'P1', loadout: loadout()),
          PlayerConfig(
              name: 'P2', loadout: loadout(hull: 'log', color: 1),
              isAi: true, aiDifficulty: AiDifficulty.easy),
        ],
        mode: GameMode.vsAi,
        seed: seed,
      );
    }

    test('Every turn rolls fresh air from the match seed', () {
      final ctrl = newMatch();
      final bias = ctrl.world.map.windBias;
      expect(ctrl.world.wind, Wind.forTurn(seed: 42, turn: 1, bias: bias));

      ctrl.beginTurnForTest(1);
      expect(ctrl.world.wind, Wind.forTurn(seed: 42, turn: 2, bias: bias));
      ctrl.dispose();
    });

    test('Resuming re-rolls the restored turn, not the bumped one', () {
      final ctrl = newMatch();
      ctrl.stepForTest(1 / 60);
      ctrl.beginTurnForTest(1);
      ctrl.stepForTest(1 / 60);
      // Simulate what restoreState does around _beginTurn: the sequence is
      // authoritative, and the wind must match it, not the bump.
      ctrl.world.rollWind(1);
      expect(ctrl.world.wind, Wind.forTurn(seed: 42, turn: 1, bias: ctrl.world.map.windBias));
      ctrl.dispose();
    });
  });

  group('Map biases', () {
    test('Mountains blow hardest, the harbour sits still', () {
      final mountain = GameMaps.byId('mountains').windBias;
      final ocean = GameMaps.byId('ocean').windBias;
      final city = GameMaps.byId('city').windBias;
      expect(mountain, greaterThan(ocean));
      expect(city, 0);
      for (final m in GameMaps.all) {
        expect(m.windBias.abs(), lessThanOrEqualTo(BattleConst.windLimit),
            reason: '${m.id} bias must survive the clamp');
      }
    });
  });
}
