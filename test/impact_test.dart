import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// Impact physics: the raft hull as a solid obstacle (no pass-through, side
/// walls that bounce from either side), explosives that detonate with real
/// force on any contact, and the zone-driven ragdoll comedy (backflips on
/// headshots, planted boots on leg hits, clutches on torso hits).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
  });

  BattleWorld world({required List<Offset> raftXs, int crewPerRaft = 2}) {
    final w = BattleWorld(map: GameMaps.all.first, seed: 7);
    for (int i = 0; i < raftXs.length; i++) {
      w.addRaft(Raft(
        playerIndex: i,
        x: raftXs[i].dx,
        loadout: RaftLoadout.custom(
            hullId: 'log', sizeId: 'medium', colorIndex: i),
        look: i == 0 ? CrewLook.player : CrewLook.raider,
        label: 'R$i',
        facing: i == 0 ? 1 : -1,
        crew: [
          for (int k = 0; k < crewPerRaft; k++)
            Crew(hp: 100, maxHp: 100, bobPhase: k * 0.7),
        ],
      ));
    }
    return w;
  }

  /// Fires and steps until the shot resolves; returns the outcome.
  ShotOutcome fireAndWait(
    BattleWorld world, {
    required Offset from,
    required double angleDeg,
    required double power,
    int facing = 1,
    WeaponDef? weapon,
    int owner = 0,
  }) {
    world.fire(
      from: from,
      angleDeg: angleDeg,
      power: power,
      facing: facing,
      weapon: weapon ?? Weapons.starter,
      owner: owner,
    );
    ShotOutcome? out;
    for (int i = 0; i < 900 && out == null; i++) {
      world.update(1 / 60);
      out = world.stepShot();
    }
    return out!;
  }

  group('Raft hulls are solid (no pass-through)', () {
    test('A slow shot thuds into the side wall and bursts — never enters', () {
      final w = world(raftXs: [const Offset(300, 0), const Offset(1300, 0)]);
      final enemy = w.rafts[1];
      final plane = enemy.x - enemy.hullHalf;
      final hpBefore = enemy.crew.fold<double>(0, (s, c) => s + c.hp);

      // Straight horizontal shot just under the deck line, at walking pace.
      final out = fireAndWait(
        w,
        from: Offset(plane - 40, enemy.deckY + 9),
        angleDeg: 0,
        power: 14,
      );

      expect(out.hitSomething, false,
          reason: 'the side wall always bounces — nothing bursts through it');
      // The ball never got past the wall.
      for (final p in w.rafts[0].crew) {
        expect(p.alive, true);
      }
      expect(enemy.crew.fold<double>(0, (s, c) => s + c.hp), hpBefore,
          reason: 'no crew behind the wall was harmed');
    });

    test('Side walls bounce from either side — even for enemy rafts', () {
      // An enemy volley hitting the player's own hull flank also bounces.
      final w = world(raftXs: [const Offset(300, 0), const Offset(1300, 0)]);
      final player = w.rafts[0];
      final plane = player.x + player.hullHalf;
      final hpBefore = player.crew.fold<double>(0, (s, c) => s + c.hp);

      final out = fireAndWait(
        w,
        from: Offset(plane + 40, player.deckY + 9),
        angleDeg: 0,
        power: 14,
        facing: -1,
        weapon: Weapons.byId('grenade'),
        owner: 1,
      );

      expect(out.hitSomething, false,
          reason: 'the player hull is as solid as the enemy hull');
      expect(player.crew.fold<double>(0, (s, c) => s + c.hp), hpBefore);
    });

    test('The near hull blocks shots aimed at a crew member behind it', () {
      // Two enemy rafts nose to tail: a flat shot at the far raft's crew
      // line, below the near raft's deck, must hit the NEAR raft's wall
      // instead of tunnelling through to the far crew.
      final w = BattleWorld(map: GameMaps.all.first, seed: 11);
      w.addRaft(Raft(
        playerIndex: 0, x: 300,
        loadout: RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 0),
        look: CrewLook.player, label: 'P1', facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      final enemy1X = 1150.0;
      final enemy2X = enemy1X + 230.0;
      final near = Raft(
        playerIndex: 1, x: enemy1X,
        loadout: RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 1),
        look: CrewLook.raider, label: 'E1', facing: -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      );
      final far = Raft(
        playerIndex: 2, x: enemy2X,
        loadout: RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 2),
        look: CrewLook.raider, label: 'E2', facing: -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      );
      w.addRaft(near);
      w.addRaft(far);

      var maxBounces = 0;
      w.fire(
        from: Offset(enemy1X - near.hullHalf - 30, near.deckY + 9),
        angleDeg: 0,
        power: 40,
        facing: 1,
        weapon: Weapons.starter,
        owner: 0,
      );
      ShotOutcome? out;
      for (int i = 0; i < 900 && out == null; i++) {
        w.update(1 / 60);
        out = w.stepShot();
        maxBounces = max(maxBounces, w.shot?.bounces ?? 0);
        // The ball is never past the near raft's far wall while below deck
        // level — that would mean it tunnelled through the hull.
        if (w.shot != null && w.shot!.pos.dy >= near.deckY) {
          expect(w.shot!.pos.dx, lessThan(near.x + near.hullHalf + 2),
              reason: 'frame $i: the ball passed through the near hull');
        }
      }

      expect(maxBounces, greaterThanOrEqualTo(1),
          reason: 'the near wall bounced the shot back out');
      expect(out!.hitSomething, false, reason: 'the wall hit ricochets, not bursts');
      expect(near.crew[0].hp, 100, reason: 'the near crew is not shot through its own wall');
      expect(far.crew[0].hp, 100, reason: 'the far crew is shielded by the near hull');
    });
  });

  group('Explosives bite', () {
    test('A bomb bursting on the deck blasts and ragdolls the whole crew', () {
      final w = world(raftXs: [const Offset(300, 0), const Offset(1300, 0)]);
      final enemy = w.rafts[1];

      // Straight down onto the middle of the enemy deck.
      final out = fireAndWait(
        w,
        from: Offset(enemy.x, enemy.deckY - 24),
        angleDeg: -90,
        power: 40,
        weapon: Weapons.byId('bomb'),
      );

      expect(out.hitSomething, true, reason: 'the deck takes the burst');
      var hurt = 0;
      var flying = 0;
      for (final c in enemy.crew) {
        if (c.hp < c.maxHp) hurt++;
        if (c.pose != null || !c.alive) flying++;
      }
      expect(hurt, greaterThan(0), reason: 'blast damage caught the crew');
      expect(flying, greaterThan(0),
          reason: 'the blast launches them into ragdolls');
      expect(w.shake, greaterThan(0), reason: 'the screen felt the bang');
    });

    test('An explosive miss into the water still blasts nearby crew', () {
      final w = world(raftXs: [const Offset(300, 0), const Offset(1300, 0)]);
      final enemy = w.rafts[1];

      // A cluster bomb dropped into the water just off the enemy's hull:
      // a genuine miss, but well inside its 130-unit blast radius.
      final dropX = enemy.x - enemy.hullHalf - 30;
      final out = fireAndWait(
        w,
        from: Offset(dropX, BattleConst.waterY - 60),
        angleDeg: -90,
        power: 40,
        weapon: Weapons.byId('cluster'),
      );

      expect(out.hitSomething, false, reason: 'it missed the raft itself');
      final crew1 = enemy.crew[0];
      final crew2 = enemy.crew[1];
      expect(crew1.hp, lessThan(crew1.maxHp),
          reason: 'blast damage does not need a direct hit');
      expect(crew1.pose, isNotNull,
          reason: 'the blast shockwave ragdolls the near crew');
      // The far crew member is outside the blast radius and unharmed.
      expect(crew2.hp, crew2.maxHp);
      expect(w.shake, greaterThan(0), reason: 'the screen felt the bang');
    });

    test('Screen-shake energy decays back to calm', () {
      final w = world(raftXs: [const Offset(300, 0), const Offset(1300, 0)]);
      w.bumpShake(20);
      expect(w.shake, greaterThan(0));
      for (int i = 0; i < 120; i++) {
        w.update(1 / 60);
      }
      expect(w.shake, 0, reason: 'the camera settles after the bang');
    });
  });

  group('Zone ragdoll comedy', () {
    ShotOutcome fireAtHeight(
      BattleWorld w, {
      required double dy,
      required String? reaction,
    }) {
      final enemy = w.rafts[1];
      w.debugHitReaction = reaction;
      return fireAndWait(
        w,
        from: Offset(enemy.x - 170, dy),
        angleDeg: 0,
        power: 60,
      );
    }

    test('A headshot can whip the body into a backflip', () {
      final w = world(raftXs: [const Offset(300, 0), const Offset(1300, 0)]);
      final enemy = w.rafts[1];
      final headY = enemy.crewPos(0).dy - 34;
      fireAtHeight(w, dy: headY, reaction: 'flip');

      final c = enemy.crew[0];
      expect(c.alive, true, reason: 'a tennis ball to the head stings, not kills');
      expect(c.pose, isNotNull, reason: 'knocked into a ragdoll');
      expect(c.pose!.maxSpin, greaterThan(0.02),
          reason: 'the whip sets the body spinning (backflip energy)');
    });

    test('A leg hit can plant one boot while the body tumbles around it', () {
      final w = world(raftXs: [const Offset(300, 0), const Offset(1300, 0)]);
      final enemy = w.rafts[1];
      // Station-local −10: below the hip line (−14 is the torso/legs edge).
      final legY = enemy.crewPos(0).dy + 14;

      fireAtHeight(w, dy: legY, reaction: 'plant');

      final c = enemy.crew[0];
      expect(c.plantFoot, isNot(0), reason: 'one boot is planted');
      expect(c.plantT, greaterThan(0));
      expect(c.pose, isNotNull);
      final pinned = c.plantFoot < 0 ? c.pose!.footL : c.pose!.footR;
      expect(pinned.pin, greaterThan(0), reason: 'the planted boot is pinned');
    });

    test('A torso hit can leave them standing, clutching the wound', () {
      final w = world(raftXs: [const Offset(300, 0), const Offset(1300, 0)]);
      final enemy = w.rafts[1];
      // Station-local −30: between the neck (−46) and hip (−14) lines.
      final torsoY = enemy.crewPos(0).dy - 6;

      fireAtHeight(w, dy: torsoY, reaction: 'grab');

      final c = enemy.crew[0];
      expect(c.alive, true);
      expect(c.grabT, greaterThan(0), reason: 'the clutch animation is up');
      expect(c.pose, isNull,
          reason: 'no ragdoll — they stayed on their feet to grab it');
    });
  });
}
