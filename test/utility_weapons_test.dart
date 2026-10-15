import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/build.dart';
import 'package:raft_rumble/game/campaign.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/game/tutorial.dart';
import 'package:raft_rumble/game/weapon_views.dart';

/// The utility shelf: a shove (Gale), a burn (Cinder) and a breaching round
/// (Wrecker). Each trades raw damage for a job — moving bodies, damage over
/// time, stripping cover — so the choice is tactical rather than biggest.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
  });

  RaftLoadout loadout({String hull = 'tube', String size = 'medium', int color = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  GameController newMatch() {
    return GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
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
      seed: 42,
    );
  }

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

  /// Fires [weaponId] point-blank at the foe's first crew member and steps
  /// until it resolves.
  ShotOutcome? directHit(BattleWorld world, String weaponId) {
    final foe = world.raftOf(1)!;
    world.fire(
      from: foe.crewPos(0) - const Offset(30, 0),
      angleDeg: 10, power: 40, facing: 1,
      weapon: Weapons.byId(weaponId), owner: 0,
    );
    ShotOutcome? outcome;
    for (int i = 0; i < 200 && outcome == null; i++) {
      outcome = world.stepShot();
    }
    return outcome;
  }

  group('The shelf', () {
    test('Three new rounds exist, stocked, gated and visually distinct', () {
      for (final id in ['gust', 'cinder', 'wrecker']) {
        final w = Weapons.byId(id);
        expect(w.id, id);
        expect(Weapons.all.contains(w), true);
        expect(Weapons.purchasable.contains(w), true);
        expect(WeaponView.forId(id).id, id);
      }
      // Ordered by unlock: a reason to keep levelling. Each claims a level
      // no older weapon announces, so the level-up card names the right gun.
      expect(Weapons.byId('gust').levelLock, 3);
      expect(Weapons.byId('cinder').levelLock, 5);
      expect(Weapons.byId('wrecker').levelLock, 7);
      // The tutorial stays a tennis-only lesson.
      final (settings, _) = Tutorial.match();
      expect(settings.enabledWeapons, ['tennis']);
    });

    test('Late-campaign arsenals carry the whole shelf', () {
      expect(kWeaponsFull,
          containsAll(['gust', 'cinder', 'wrecker']));
      expect(kWeaponsMid, isNot(contains('gust')),
          reason: 'early fights stay simple');
      expect(kWeaponsBasic, hasLength(2));
    });
  });

  group('Gale: the shove', () {
    test('Out-shoves every damage round despite its light wound', () {
      expect(Weapons.byId('gust').damage, lessThan(Weapons.starter.damage));
      expect(Crew.impactForce(Weapons.byId('gust')),
          greaterThan(Crew.impactForce(Weapons.byId('anchor'))));
    });

    test('A gust carries a body much further than a tennis ball', () {
      double slide(double force) {
        final world = twoRafts();
        final c = world.raftOf(1)!.crew.first;
        c.knock(const Offset(1, 0), force);
        for (int i = 0; i < 30; i++) {
          world.update(1 / 60);
        }
        return c.offset.dx.abs();
      }

      expect(
          slide(Crew.impactForce(Weapons.byId('gust'))),
          greaterThan(slide(Crew.impactForce(Weapons.starter)) * 1.5),
          reason: 'the shove is the weapon, not the wound');
    });

    test('A direct gust launches upward toward the rails', () {
      final world = twoRafts();
      final outcome = directHit(world, 'gust');
      expect(outcome, isNotNull);
      expect(outcome!.hitSomething, true);
      final c = world.raftOf(1)!.crew.first;
      expect(c.hp, 100 - Weapons.byId('gust').damage);
      expect(c.ragdoll, true, reason: 'a gale victim leaves their feet');
    });
  });

  group('Cinder: the burn', () {
    test('A direct hit wounds lightly and sets three turns of fire', () {
      final world = twoRafts();
      final outcome = directHit(world, 'cinder');
      expect(outcome, isNotNull);
      final c = world.raftOf(1)!.crew.first;
      expect(c.hp, 100 - Weapons.byId('cinder').damage);
      expect(c.burnTurns, 3);
      expect(c.burnDps, Weapons.byId('cinder').burnDamage);
    });

    test('Fire ticks on the victim\'s own turns, then goes out', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;
      final c = foe.crew.first;
      c.hp = 100;
      c.ignite(3, 7);

      for (int turn = 0; turn < 3; turn++) {
        final before = c.hp;
        ctrl.beginTurnForTest(1);
        expect(c.hp, before - 7, reason: 'turn ${turn + 1} burns');
        expect(c.hpBarT, greaterThan(0), reason: 'each tick re-summons the bar');
      }
      expect(
          ctrl.world.effects.any((f) => f.kind == 'fire'), true,
          reason: 'the burns are visible');
      ctrl.beginTurnForTest(1);
      expect(c.burnTurns, 0);
      expect(c.hp, 100 - 21);
      ctrl.dispose();
    });

    test('A fresh burn tops up turns but never cools a hotter one', () {
      final c = Crew(hp: 100, maxHp: 100);
      c.ignite(3, 7);
      c.ignite(2, 10);
      expect(c.burnTurns, 3);
      expect(c.burnDps, 10);
      c.ignite(5, 5);
      expect(c.burnTurns, 5);
      expect(c.burnDps, 10);
    });

    test('Fire can finish the job, and the body still falls overboard', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;
      final c = foe.crew.first;
      c.hp = 15;
      c.ignite(3, 7);

      ctrl.beginTurnForTest(1); // 15 -> 8
      expect(c.alive, true);
      ctrl.beginTurnForTest(1); // 8 -> 1
      expect(c.alive, true);
      expect(c.burnTurns, 1);
      ctrl.beginTurnForTest(1); // 1 -> 0
      expect(c.alive, false);
      expect(c.burnTurns, 0);
      expect(c.ragdoll, true, reason: 'a burn death keels over like any other');

      var frames = 0;
      while (!c.drowned && frames++ < 900) {
        ctrl.world.update(1 / 60);
      }
      expect(c.drowned, true, reason: 'and still ends in the water');
      ctrl.dispose();
    });

    test('A burning loser still loses the tennis-only star', () {
      // Cinder is not tennis: firing one voids restraint, burn or no burn.
      expect(
          StarObjective.tennisOnly.satisfied(
              weaponsFired: {'tennis', 'cinder'},
              flawless: true,
              breakFraction: 0),
          false);
    });
  });

  group('Wrecker: the breach', () {
    BattleWorld walledWorld(BuildPlan plan) {
      final w = BattleWorld(map: GameMaps.all.first, seed: 11);
      w.obstacles.clear();
      w.water = WaterProfile.flat;
      for (int p = 0; p < 2; p++) {
        final raft = Raft(
          playerIndex: p,
          x: p == 0 ? BattleConst.playerX : BattleConst.enemySlots.first,
          loadout: RaftLoadout.custom(hullId: 'barge', sizeId: 'large', colorIndex: p),
          look: p == 0 ? CrewLook.player : CrewLook.raider,
          label: 'R$p',
          facing: p == 0 ? 1 : -1,
          crew: [Crew(hp: 100, maxHp: 100)],
        );
        if (p == 0) raft.build = plan;
        w.addRaft(raft);
      }
      return w;
    }

    /// Fires a flat shot from the east into the player raft's wall.
    void shootWall(BattleWorld w, int col, int row, String weaponId) {
      final raft = w.rafts[0];
      final cx = raft.x + BuildPlan.columnX(col);
      final cy = raft.deckY - (row + 0.5) * BuildPlan.cellH;
      w.fire(
        from: Offset(cx + 320, cy),
        angleDeg: 0, power: 95, facing: -1,
        weapon: Weapons.byId(weaponId), owner: 1,
      );
      for (int f = 0; f < 900 && w.shot != null; f++) {
        w.stepShot();
      }
    }

    test('A 16-damage wrecker one-shots driftwood a tennis ball only scratches', () {
      for (final weaponId in ['tennis', 'wrecker']) {
        final p = BuildPlan.empty();
        p.set(4, 0, BuildMaterial.driftwood); // 45 HP
        final w = walledWorld(p);
        shootWall(w, 4, 0, weaponId);
        if (weaponId == 'tennis') {
          expect(p.at(4, 0)!.hp, 45 - Weapons.byId('tennis').damage);
          expect(p.at(4, 0)!.broken, false);
        } else {
          expect(p.at(4, 0)!.broken, true,
              reason: '48 breaching damage clears 45 HP of timber');
        }
      }
    });

    test('...while barely bruising the crew it was covering', () {
      final p = BuildPlan.empty();
      p.set(4, 0, BuildMaterial.driftwood);
      final w = walledWorld(p);
      final crew = w.rafts[0].crew[0];
      shootWall(w, 4, 0, 'wrecker');
      // The wall ate the round; a bomb would have done 58 through cover.
      expect(crew.hp, greaterThan(100 - Weapons.byId('bomb').damage));
    });
  });

  group('The AI can throw the new shelf', () {
    test('Every new round plans, flies and terminates', () {
      for (final id in ['gust', 'cinder', 'wrecker']) {
        final world = twoRafts(seed: 5);
        final me = world.raftOf(0)!;
        final foe = world.raftOf(1)!;
        final w = Weapons.byId(id);
        final ai = AiController(AiDifficulty.normal, seed: 9);
        final shot = ai.plan(
          from: me.muzzle(aimAngleDeg: 45, weapon: w),
          targetPos: foe.crewPos(0),
          facing: 1,
          arsenal: [w],
          muzzleAt: (a) => me.muzzle(aimAngleDeg: a, weapon: w),
          baseJitter: 0,
        );
        world.fire(
          from: me.muzzle(aimAngleDeg: shot.angle, weapon: w),
          angleDeg: shot.angle, power: shot.power, facing: 1,
          weapon: w, owner: 0,
        );
        ShotOutcome? outcome;
        for (int i = 0; i < 600 && outcome == null; i++) {
          outcome = world.stepShot();
        }
        expect(outcome, isNotNull, reason: '$id never resolved');
        for (final c in foe.crew) {
          expect(c.hp.isFinite, true);
          expect(c.hp, greaterThanOrEqualTo(0));
        }
      }
    });
  });
}
