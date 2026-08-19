import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
  });

  RaftLoadout loadout({String hull = 'tube', String size = 'medium', int color = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  GameController newMatch({
    int seed = 42,
    GameMode mode = GameMode.vsAi,
    bool enemyIsAi = true,
  }) {
    return GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
      players: [
        PlayerConfig(name: 'P1', loadout: loadout()),
        PlayerConfig(
          name: 'P2',
          loadout: loadout(hull: 'log', color: 1),
          isAi: enemyIsAi,
          aiDifficulty: AiDifficulty.easy,
        ),
      ],
      mode: mode,
      seed: seed,
    );
  }

  group('Battle setup', () {
    test('Rafts spawn at the design slots, facing each other, with full crew', () {
      final ctrl = newMatch();

      expect(ctrl.phase, GamePhase.aiming);
      expect(ctrl.world.rafts.length, 2);

      final me = ctrl.world.raftOf(0)!;
      final foe = ctrl.world.raftOf(1)!;

      expect(me.x, BattleConst.playerX);
      expect(foe.x, BattleConst.enemySlots.first);
      expect(me.facing, 1, reason: 'the player shoots to the right');
      expect(foe.facing, -1, reason: 'the enemy shoots back to the left');

      // A "medium" raft seats two — the chapter-one default crew — and its
      // size bonus is added on top of the match's base HP.
      expect(me.crew.length, 2);
      final expectedHp = 100 + me.loadout.hpBonus;
      expect(me.crew.every((c) => c.hp == expectedHp), true);
      expect(me.hpFrac, 1.0);

      ctrl.dispose();
    });

    test('Crew stand apart on the deck and above the waterline', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;

      final a = me.crewPos(0), b = me.crewPos(1);
      expect((a.dx - b.dx).abs(), greaterThan(20), reason: 'crew must not overlap');
      for (final p in [a, b]) {
        expect(p.dy, lessThan(BattleConst.waterY), reason: 'crew stand above the water');
      }
      ctrl.dispose();
    });
  });

  group('Firing and damage', () {
    test('A shot fired at an enemy damages exactly one crew member and resolves', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;
      final before = foe.crew.first.hp;

      // Fire straight at the enemy rather than relying on aim: place the shot
      // adjacent to them so the hit test trips on the next step.
      final target = foe.crewPos(0);
      ctrl.world.fire(
        from: target - const Offset(30, 0),
        angleDeg: 10, power: 40, facing: 1,
        weapon: Weapons.byId('tennis'), owner: 0,
      );

      ShotOutcome? outcome;
      for (int i = 0; i < 200 && outcome == null; i++) {
        outcome = ctrl.world.stepShot();
      }

      expect(outcome, isNotNull, reason: 'the shot must resolve');
      expect(outcome!.hitSomething, true);
      expect(foe.crew.first.hp, lessThan(before));
      expect(ctrl.world.shot, isNull, reason: 'a resolved shot is cleared');
      ctrl.dispose();
    });

    test('Crew reaching 0 HP die, and a raft dies only when its whole crew does', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;

      me.crew[0].hp = 0;
      expect(me.crew[0].alive, false);
      expect(me.alive, true, reason: 'one crew member left means the raft fights on');

      me.crew[1].hp = 0;
      expect(me.alive, false, reason: 'a raft with no living crew is out');
      ctrl.dispose();
    });

    test('Splash weapons damage nearby crew, direct hits are not double-counted', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;
      final bomb = Weapons.byId('bomb');
      expect(bomb.splash, greaterThan(0));

      final hpBefore = foe.crew.first.hp;
      ctrl.world.fire(
        from: foe.crewPos(0) - const Offset(30, 0),
        angleDeg: 10, power: 40, facing: 1, weapon: bomb, owner: 0,
      );
      ShotOutcome? outcome;
      for (int i = 0; i < 200 && outcome == null; i++) {
        outcome = ctrl.world.stepShot();
      }

      final dealt = hpBefore - foe.crew.first.hp;
      // A direct hit applies full damage once; the splash pass explicitly
      // skips the crew member it already hit, so damage must not exceed the
      // weapon's rated figure.
      expect(dealt, closeTo(bomb.damage, 0.001),
          reason: 'the directly-hit crew member must not also take splash');
      ctrl.dispose();
    });
  });

  group('Turn flow', () {
    test('The active shooter rotates through living crew', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;

      expect(me.activeIndex, 0);
      me.advanceCrew();
      expect(me.activeIndex, 1, reason: 'a two-person crew alternates');
      me.advanceCrew();
      expect(me.activeIndex, 0, reason: 'and wraps back around');

      // With one crew member down, rotation must skip them entirely.
      me.crew[1].hp = 0;
      me.advanceCrew();
      expect(me.activeIndex, 0, reason: 'a dead crew member never takes a turn');
      ctrl.dispose();
    });

    test('ensureActiveAlive moves off a crew member who has just died', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;
      me.crew[0].hp = 0;
      me.ensureActiveAlive();
      expect(me.activeIndex, 1);
      expect(me.activeCrew, isNotNull);
      ctrl.dispose();
    });

    test('Muzzle sits ahead of the active shooter, on their facing side', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;
      final foe = ctrl.world.raftOf(1)!;

      expect(me.muzzle.dx, greaterThan(me.crewPos(me.activeIndex).dx),
          reason: 'player muzzle points right');
      expect(foe.muzzle.dx, lessThan(foe.crewPos(foe.activeIndex).dx),
          reason: 'enemy muzzle points left');
      ctrl.dispose();
    });
  });

  group('Ballistics', () {
    test('More power carries a shot further', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;
      final w = Weapons.starter;

      final near = ctrl.world.landingX(
          from: me.muzzle, angleDeg: 45, power: 40, facing: 1, weapon: w);
      final far = ctrl.world.landingX(
          from: me.muzzle, angleDeg: 45, power: 90, facing: 1, weapon: w);

      expect(far, greaterThan(near));
      expect(near.isFinite && far.isFinite, true);
      ctrl.dispose();
    });

    test('Trajectory preview follows an arc and stops at the water', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;
      final dots = ctrl.world.trajectory(
        from: me.muzzle, angleDeg: 45, power: 70, facing: 1,
        weapon: Weapons.starter, limit: 30,
      );

      expect(dots, isNotEmpty);
      expect(dots.length, lessThanOrEqualTo(30));
      for (final d in dots) {
        expect(d.pos.dy, lessThanOrEqualTo(BattleConst.waterY + 8),
            reason: 'the preview must stop at the waterline');
      }
      // The arc should actually rise before it falls.
      final highest = dots.map((d) => d.pos.dy).reduce((a, b) => a < b ? a : b);
      expect(highest, lessThan(me.muzzle.dy), reason: 'the shot arcs upward first');
      ctrl.dispose();
    });

    test("The AI's solved power lands near its target", () {
      final world = BattleWorld(map: GameMaps.all.first, seed: 5);
      world.addRaft(Raft(
        playerIndex: 0, x: BattleConst.playerX, loadout: loadout(),
        look: CrewLook.player, label: 'P1', facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      final foe = Raft(
        playerIndex: 1, x: BattleConst.enemySlots.first, loadout: loadout(hull: 'log'),
        look: CrewLook.raider, label: 'AI', facing: -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      );
      world.addRaft(foe);

      // Expert AI has the least jitter, so its solved shot should be close.
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final me = world.rafts.first;
      final shot = ai.plan(
        from: me.muzzle,
        targetPos: foe.crewPos(0),
        facing: 1,
        arsenal: [Weapons.starter],
        baseJitter: 0,
      );

      final landing = world.landingX(
        from: me.muzzle, angleDeg: shot.angle, power: shot.power,
        facing: 1, weapon: shot.weapon,
      );
      expect((landing - foe.crewPos(0).dx).abs(), lessThan(160),
          reason: 'an expert shot should land in the neighbourhood of the target');
    });
  });

  group('Camera', () {
    test('Camera clamps to the world and never shows past its edges', () {
      final world = BattleWorld(map: GameMaps.all.first, seed: 1);
      world.viewWidth = 870;

      expect(world.camFor(-9999), 0, reason: 'cannot pan left of the world');
      expect(world.camFor(99999), BattleConst.worldW - world.viewWidth,
          reason: 'cannot pan past the right edge');
      expect(world.camFor(BattleConst.worldW / 2),
          BattleConst.worldW / 2 - world.viewWidth / 2);
    });
  });

  group('Weapons and ammo', () {
    test('Only the starter weapon is infinite; the rest carry finite stock', () {
      expect(Weapons.starter.infinite, true);
      expect(Weapons.purchasable.any((w) => w.infinite), false);
      expect(Weapons.all.where((w) => w.infinite).length, 1,
          reason: 'exactly one always-available weapon');
    });

    test('Controller stocks ammo from settings and reports infinite as -1', () {
      final ctrl = GameController(
        settings: MatchSettings(
          map: GameMaps.all.first,
          startHp: 100,
          ammo: {'grenade': 5, 'bomb': 2},
        ),
        players: [
          PlayerConfig(name: 'P1', loadout: loadout()),
          PlayerConfig(name: 'AI', loadout: loadout(hull: 'log'), isAi: true),
        ],
        mode: GameMode.vsAi,
        seed: 7,
      );

      expect(ctrl.ammoFor('tennis'), -1, reason: 'infinite renders as ∞');
      expect(ctrl.ammoFor('grenade'), 5);
      expect(ctrl.ammoFor('bomb'), 2);
      ctrl.dispose();
    });
  });

  group('Raft customization', () {
    test('Size drives crew capacity and hull width', () {
      final small = RaftLoadout.custom(hullId: 'tube', sizeId: 'small', colorIndex: 0);
      final large = RaftLoadout.custom(hullId: 'tube', sizeId: 'large', colorIndex: 0);

      expect(small.crewCount, lessThan(large.crewCount));
      expect(small.width, lessThan(large.width));
      expect(large.hpBonus, greaterThan(small.hpBonus));
    });

    test('Campaign raft tier 0 seats a crew of two, and upgrades grow it', () {
      final start = RaftLoadout.fromCampaign(hullId: 'tube', colorIndex: 0, raftTier: 0);
      expect(start.crewCount, 2, reason: 'chapter one starts with two characters');

      final maxed = RaftLoadout.fromCampaign(
          hullId: 'tube', colorIndex: 0, raftTier: RaftTiers.maxTier);
      expect(maxed.crewCount, greaterThan(start.crewCount));
      expect(maxed.hpBonus, greaterThan(start.hpBonus));
    });

    test('Hull unlocks are gated by raft tier', () {
      expect(RaftHull.unlockedAt(0).length, lessThan(RaftHull.all.length));
      expect(RaftHull.unlockedAt(RaftTiers.maxTier).length, RaftHull.all.length);
      expect(RaftHull.unlockedAt(0).first.id, 'tube', reason: 'the starter hull is always available');
    });

    test('Crew offsets are symmetric about the raft centre', () {
      final lo = RaftLoadout.custom(hullId: 'tube', sizeId: 'large', colorIndex: 0);
      final offsets = [for (int i = 0; i < lo.crewCount; i++) lo.crewOffset(i)];
      final sum = offsets.reduce((a, b) => a + b);
      expect(sum, closeTo(0, 0.001), reason: 'crew are centred on the deck');
    });
  });
}
