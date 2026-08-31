import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/net.dart';
import 'package:raft_rumble/game/raft.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RaftLoadout loadout({String hull = 'tube', String size = 'medium', int color = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  GameController newVsAi({int seed = 1}) {
    final settings = MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30);
    final players = [
      PlayerConfig(name: 'P1', loadout: loadout()),
      PlayerConfig(
        name: 'AI',
        loadout: loadout(hull: 'log', color: 1),
        isAi: true,
        aiDifficulty: AiDifficulty.easy,
      ),
    ];
    return GameController(settings: settings, players: players, mode: GameMode.vsAi, seed: seed);
  }

  test('Rapid repeated humanFire() calls create exactly one shot per turn', () {
    final ctrl = newVsAi();
    ctrl.aimAngle = 45;
    ctrl.aimPower = 70;
    ctrl.selectedWeaponId = 'tennis';
    for (int i = 0; i < 10; i++) {
      ctrl.humanFire();
    }
    expect(ctrl.world.shot, isNotNull, reason: 'the first tap should have fired');
    expect(ctrl.phase, GamePhase.firing);
    expect(ctrl.shotsFired, 1, reason: 'ten rapid taps must still fire only once');
    ctrl.dispose();
  });

  test('Firing rejects non-finite angle/power instead of crashing or creating a bad shot', () {
    final ctrl = newVsAi(seed: 2);
    ctrl.aimAngle = double.nan;
    ctrl.aimPower = double.infinity;
    ctrl.humanFire();
    expect(ctrl.world.shot, isNull, reason: 'NaN/Infinity input must not create a shot');
    expect(ctrl.phase, GamePhase.aiming, reason: 'rejected fire must not advance the phase');
    ctrl.dispose();
  });

  test('Limited-ammo weapons cannot be fired past zero', () {
    final ctrl = newVsAi(seed: 4);
    // Drain the grenade stock, then confirm a further attempt is refused and
    // selection has fallen back to the infinite starter weapon.
    ctrl.ammo['grenade'] = 1;
    expect(ctrl.selectWeapon('grenade'), true);
    // The raise animation runs before the weapon is in firing condition —
    // see the equip/swap tests — so bring the swap to completion first.
    for (int i = 0; i < 40; i++) {
      ctrl.world.update(1 / 60);
    }
    expect(ctrl.world.raftOf(0)!.activeCrew!.swapping, false);
    ctrl.humanFire();
    expect(ctrl.ammo['grenade'], 0);
    expect(ctrl.selectedWeaponId, Weapons.starter.id,
        reason: 'running dry must not leave an unusable weapon selected');
    expect(ctrl.selectWeapon('grenade'), false, reason: 'cannot select an empty weapon');
    ctrl.dispose();
  });

  test('Malformed/stale network fire messages are ignored, not crashing the host', () {
    NetService.instance.isHost = true;
    final ctrl = GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
      players: [
        PlayerConfig(name: 'Host', loadout: loadout()),
        PlayerConfig(name: 'Client', loadout: loadout(hull: 'log', color: 1)),
      ],
      mode: GameMode.hotspot,
      net: NetService.instance,
      seed: 3,
    );
    expect(ctrl.currentPlayer, 0);

    expect(() => NetService.instance.onMessage?.call({'t': 'fire'}), returnsNormally);
    expect(() => NetService.instance.onMessage?.call({'t': 'fire', 'a': null, 'p': 50, 'w': 'tennis'}), returnsNormally);
    expect(() => NetService.instance.onMessage?.call({'t': 'fire', 'a': 45, 'p': 'not a number', 'w': 'tennis'}), returnsNormally);
    expect(() => NetService.instance.onMessage?.call({'t': 'fire', 'a': 45, 'p': 50, 'w': 42}), returnsNormally);
    expect(() => NetService.instance.onMessage?.call({'t': 'rematch', 'seed': 'not an int'}), returnsNormally);
    expect(() => NetService.instance.onMessage?.call({'t': 'unknown-type-entirely'}), returnsNormally);
    expect(ctrl.world.shot, isNull, reason: 'none of the malformed fire messages should have fired');

    // A stale player index must be dropped, not applied to whoever is current.
    NetService.instance.onMessage?.call({'t': 'fire', 'a': 45, 'p': 50, 'w': 'tennis', 'pl': 1});
    expect(ctrl.world.shot, isNull, reason: 'a fire message for the wrong player must be ignored');
    expect(ctrl.phase, GamePhase.aiming);

    ctrl.dispose();
    NetService.instance.onMessage = null;
  });

  test('Many shots across every weapon never produce NaN or a stuck projectile', () {
    // Driven against BattleWorld directly rather than through a controller so
    // 200 shots run in milliseconds instead of spinning up 200 real tickers.
    final world = BattleWorld(map: GameMaps.all.first, seed: 777);
    world.addRaft(Raft(
      playerIndex: 0, x: BattleConst.playerX, loadout: loadout(),
      look: CrewLook.player, label: 'P1', facing: 1,
      crew: [Crew(hp: 100, maxHp: 100), Crew(hp: 100, maxHp: 100)],
    ));
    world.addRaft(Raft(
      playerIndex: 1, x: BattleConst.enemySlots.first, loadout: loadout(hull: 'log'),
      look: CrewLook.raider, label: 'AI', facing: -1,
      crew: [Crew(hp: 9999999, maxHp: 9999999)],
    ));

    final rng = Random(9001);
    for (int shot = 0; shot < 200; shot++) {
      final w = Weapons.all[shot % Weapons.all.length];
      final angle = BattleConst.angleMin +
          rng.nextDouble() * (BattleConst.angleMax - BattleConst.angleMin);
      final power = BattleConst.powerMin +
          rng.nextDouble() * (BattleConst.powerMax - BattleConst.powerMin);
      world.fire(
        from: world.rafts.first.muzzle(aimAngleDeg: angle),
        angleDeg: angle, power: power, facing: 1, weapon: w, owner: 0,
      );

      // Every shot must terminate: it hits, splashes down, or leaves the
      // world. A shot still airborne after this many frames would mean the
      // resolve conditions can be escaped, which would hang a real turn.
      var frames = 0;
      while (world.shot != null && frames < 4000) {
        world.stepShot();
        frames++;
      }
      expect(world.shot, isNull,
          reason: 'shot $shot with ${w.id} never resolved (angle=$angle power=$power)');

      for (final raft in world.rafts) {
        for (final c in raft.crew) {
          expect(c.hp.isFinite, true, reason: 'shot $shot with ${w.id} produced non-finite hp');
          expect(c.hp, greaterThanOrEqualTo(0), reason: 'hp must never go negative');
        }
      }
    }
  });

  test('Pull-back aim shaping honours the dead zone, clamps, and fine-tune band', () {
    // Inside the dead zone nothing registers at all — this is what stops a
    // shaky finger from nudging the aim on a near-stationary touch.
    expect(shapeAim(2, 2), isNull);
    expect(shapeAim(BattleConst.deadzone - 1, 0), isNull);

    final short = shapeAim(60, 40);
    expect(short, isNotNull);
    expect(short!.fine, false, reason: 'a short pull is still in the coarse band');

    final long = shapeAim(280, 180);
    expect(long, isNotNull);
    expect(long!.fine, true, reason: 'a long pull should enter the fine-tune band');
    expect(long.power, greaterThan(short.power));

    // Slingshot feel: pulling straight back fires flat, pulling back *and
    // down* lifts the arc. Getting this backwards makes a full-power drag
    // land at the shooter's feet, so it is worth pinning down.
    final flat = shapeAim(200, 0)!;
    final lifted = shapeAim(200, 200)!;
    final steep = shapeAim(120, 400)!;
    expect(flat.angle, BattleConst.angleMin, reason: 'a level pull shoots flat');
    expect(lifted.angle, greaterThan(flat.angle));
    expect(steep.angle, greaterThan(lifted.angle), reason: 'pulling further down arcs higher');

    // Pull-back distance is what builds power, independent of the arc.
    expect(shapeAim(240, 0)!.power, greaterThan(shapeAim(80, 0)!.power));

    // Angle and power always stay inside the design's legal ranges, however
    // absurd the drag.
    for (final v in [10000.0, -10000.0, 0.001]) {
      final a = shapeAim(v, v);
      if (a == null) continue;
      expect(a.angle, inInclusiveRange(BattleConst.angleMin, BattleConst.angleMax));
      expect(a.power, inInclusiveRange(BattleConst.powerMin, BattleConst.powerMax));
    }
  });

  test('A forward pull (dx < 0) does not produce a shot', () {
    // dx is measured as origin.x minus finger.x for a raft facing right, so a
    // forward pull has dx < 0. That is a drag-out gesture, not an aim — it
    // would otherwise produce a low-power shot at the angle clamped to 6°
    // and feel like the controls are "stuck on".
    expect(shapeAim(-100, 0), isNull,
        reason: 'pulling forward must not produce an aim');
    expect(shapeAim(-100, 200), isNull,
        reason: 'pulling forward and down must not produce an aim');
    // Exactly at the threshold it is still no-op, just past it it fires.
    expect(shapeAim(4, 0), isNull);
    expect(shapeAim(40, 0), isNotNull);
  });

  test('easeAim converges on the target instead of oscillating between clamps', () {
    // Held steady, repeated easing must actually arrive at the target. With a
    // lerp factor above 1 this diverges and slams into the angle clamps, which
    // is what made every careful drag read as a flat 6 degree shot.
    // Deliberately a target well away from the 45 degree starting angle, so
    // "moved toward it" is actually measurable.
    final target = shapeAim(200, 400)!;
    expect(target.angle, greaterThan(50));
    var angle = 45.0, power = 70.0;
    for (int i = 0; i < 60; i++) {
      final eased = easeAim(angle, power, target);
      angle = eased.angle;
      power = eased.power;
      expect(angle.isFinite && power.isFinite, true);
    }
    expect(angle, closeTo(target.angle, 1.0), reason: 'angle should settle on the target');
    expect(power, closeTo(target.power, 1.0), reason: 'power should settle on the target');

    // And it must move toward the target on the very first frame, not away.
    final first = easeAim(45, 70, target);
    expect((first.angle - target.angle).abs(), lessThan((45 - target.angle).abs()));
  });
}
