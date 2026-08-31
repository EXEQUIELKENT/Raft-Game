import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/weapon_views.dart';

/// Character animation framework: per-projectile firearm models, their grip
/// layouts (IK targets), their firing animation specs, and the equip/swap
/// transition that moves between them.
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

  group('Weapon views (per-projectile firearm models)', () {
    test('Every projectile type resolves to a distinct firearm model', () {
      final seen = <WeaponView>{};
      for (final w in Weapons.all) {
        final view = WeaponView.forId(w.id);
        seen.add(view);
        expect(view.id, w.id);
        // A model is more than a bare barrel: it has a real receiver with a
        // grip behind it.
        expect(view.receiverX1, greaterThan(view.receiverX0));
        expect(view.barrelX1, greaterThan(view.barrelX0));
        expect(view.muzzleX, greaterThan(view.barrelX1),
            reason: '${w.id}: the muzzle cap sits at the barrel tip');
      }
      expect(seen.length, Weapons.all.length,
          reason: 'no two calibers share a firearm model');
      // Unknown ids fall back to the starter model rather than crashing.
      expect(WeaponView.forId('does-not-exist').id, 'tennis');
    });

    test('Firing animation reflects the caliber: heavier hits kick harder', () {
      double kick(String id) => WeaponView.forId(id).kick;
      double flash(String id) => WeaponView.forId(id).flashR;

      expect(kick('anchor'), greaterThan(kick('bomb')));
      expect(kick('bomb'), greaterThan(kick('grenade')));
      expect(kick('grenade'), greaterThan(kick('tennis')));
      expect(kick('cluster'), greaterThan(kick('tennis')));

      expect(flash('anchor'), greaterThan(flash('tennis')));
      expect(flash('bomb'), greaterThan(flash('grenade')));

      // Recovery windows stretch with weight too.
      expect(WeaponView.forId('anchor').recoilDur,
          greaterThan(WeaponView.forId('tennis').recoilDur));
    });

    test('Grip layouts differ per weapon: foregrips, cups and rear hefts', () {
      expect(WeaponView.forId('tennis').supportStyle, GripStyle.cup);
      expect(WeaponView.forId('grenade').supportStyle, GripStyle.foregrip);
      expect(WeaponView.forId('bomb').supportStyle, GripStyle.heft);
      // The grenade launcher's slide is a real pump action with travel.
      expect(WeaponView.forId('grenade').pumpTravel, greaterThan(0));
      // The starter has no slide to work.
      expect(WeaponView.forId('tennis').pumpTravel, 0);
    });
  });

  group('Arm IK (procedural hand placement)', () {
    test('Reaches a target inside the arm span exactly', () {
      final shoulder = Offset.zero;
      final (elbow, hand) = ArmIK.solve(shoulder, const Offset(24, 4));
      expect((hand - const Offset(24, 4)).distance, lessThan(0.01));
      // Two real bone segments connect shoulder to hand.
      expect((elbow - shoulder).distance, closeTo(ArmIK.upper, 0.01));
      expect((elbow - hand).distance, closeTo(ArmIK.fore, 0.01));
    });

    test('Clamps to reach without degenerating', () {
      final (elbow, hand) = ArmIK.solve(Offset.zero, const Offset(60, 0));
      expect(hand.dx, closeTo(ArmIK.reachMax, 0.5));
      expect((elbow - Offset.zero).distance, closeTo(ArmIK.upper * ArmIK.softStretch, 0.01));
      expect((elbow - hand).distance, closeTo(ArmIK.fore * ArmIK.softStretch, 0.01));
    });

    test('Bend picks which side the elbow breaks toward', () {
      final (elbowDown, _) = ArmIK.solve(Offset.zero, const Offset(18, 0), bend: 1);
      final (elbowUp, _) = ArmIK.solve(Offset.zero, const Offset(18, 0), bend: -1);
      expect(elbowDown.dy, greaterThan(elbowUp.dy),
          reason: 'a low elbow reads as a carry, a high one as a brace');
    });

    test('The support hand chokes up along a long gun to stay in reach', () {
      const axis = Offset(1, 0);
      // A realistic aiming frame: the grip sits one hold-distance ahead of
      // the gun shoulder, and the support shoulder is a torso-width behind.
      // The foregrip of a long gun is beyond the arm span, so the solve
      // pulls the hand back onto the weapon.
      final anchor = const Offset(9.5, 0) + const Offset(1, 0) * 12;
      const suppShoulder = Offset(-9.5, 0);
      final t = ArmIK.chokeUp(
        anchor: anchor,
        axis: axis,
        shoulder: suppShoulder,
        preferredT: 16,
        minT: 1,
        maxT: 25,
      );
      expect(t, lessThan(16), reason: 'the hand chokes up on the long gun');
      final hand = anchor + axis * t;
      expect((hand - suppShoulder).distance,
          lessThanOrEqualTo(ArmIK.reachMax + 0.5),
          reason: 'the chosen grip point is inside the support arm span');

      // A short gun's foregrip is reachable as-is: no choke-up.
      final tShort = ArmIK.chokeUp(
        anchor: const Offset(5, 0),
        axis: axis,
        shoulder: suppShoulder,
        preferredT: 3,
        minT: 1,
        maxT: 10,
      );
      expect(tShort, 3, reason: 'the preferred foregrip is kept when reachable');
    });

    test('Arm IK soft-stretches to grips just past nominal span', () {
      // A heavy rear heft puts the hand ~30 units from the shoulder: the
      // 28-unit rig stretches (cartoon-style) to meet the weapon.
      final (elbow, hand) = ArmIK.solve(Offset.zero, const Offset(30, 0));
      expect(hand.dx, 30, reason: 'the hand lands on the target');
      expect((elbow - Offset.zero).distance + (elbow - hand).distance,
          closeTo(30, 0.1), reason: 'both bones stretched proportionally');
      // But it has a hard ceiling — nothing can reach across the screen.
      final (elbow2, hand2) = ArmIK.solve(Offset.zero, const Offset(120, 0));
      expect(hand2.dx, closeTo(ArmIK.reachMax, 0.5));
      expect((elbow2 - Offset.zero).distance + (elbow2 - hand2).distance,
          closeTo(ArmIK.reachMax, 0.5));
    });
  });

  group('Equip + swap transition', () {
    test('selectWeapon lowers, swaps the model and raises it back', () {
      final ctrl = newMatch();
      final crew = ctrl.world.raftOf(0)!.activeCrew!;
      expect(crew.swapping, false, reason: 'starter equipped at turn start');
      expect(crew.equipped ?? 'tennis', 'tennis');

      expect(ctrl.selectWeapon('grenade'), true);
      expect(crew.swapping, true, reason: 'the swap animation starts');
      expect(crew.equipped, 'tennis', reason: 'the old firearm is still in hand');

      // Halfway through, the new model is equipped and rises.
      for (int i = 0; i < 16; i++) {
        ctrl.world.update(1 / 60);
      }
      expect(crew.equipped, 'grenade', reason: 'equipped at the swap midpoint');
      for (int i = 0; i < 20; i++) {
        ctrl.world.update(1 / 60);
      }
      expect(crew.swapping, false, reason: 'the raise completes');
      expect(crew.equipped, 'grenade');
      ctrl.dispose();
    });

    test('The swap gates firing until the new weapon is in the grip', () {
      final ctrl = newMatch();
      final crew = ctrl.world.raftOf(0)!.activeCrew!;
      ctrl.selectWeapon('grenade');
      expect(ctrl.canHumanAct, false, reason: 'cannot fire while lowering');
      ctrl.humanFire();
      expect(ctrl.world.shot, isNull, reason: 'the fire path rejects it too');

      for (int i = 0; i < 40; i++) {
        ctrl.world.update(1 / 60);
      }
      expect(crew.swapping, false);
      expect(ctrl.canHumanAct, true, reason: 'the raise is done: fire at will');
      final ammoBefore = ctrl.ammoFor('grenade');
      ctrl.humanFire();
      expect(ctrl.world.shot, isNotNull);
      expect(ctrl.ammoFor('grenade'), ammoBefore - 1,
          reason: 'the shot was fired with the newly equipped caliber');
      expect(crew.equipped, 'grenade',
          reason: 'and the in-hand model stays the fired weapon');
      ctrl.dispose();
    });

    test('Re-selecting the equipped weapon is a no-op', () {
      final ctrl = newMatch();
      final crew = ctrl.world.raftOf(0)!.activeCrew!;
      expect(ctrl.selectWeapon('tennis'), true);
      expect(crew.swapping, false);
      ctrl.dispose();
    });

    test('A swap in flight retargets cleanly to the newest selection', () {
      final ctrl = newMatch();
      final crew = ctrl.world.raftOf(0)!.activeCrew!;
      ctrl.selectWeapon('grenade');
      ctrl.selectWeapon('bomb');
      for (int i = 0; i < 40; i++) {
        ctrl.world.update(1 / 60);
      }
      expect(crew.swapping, false);
      expect(crew.equipped, 'bomb', reason: 'the latest selection wins');
      ctrl.dispose();
    });

    test('The AI equips its planned caliber instantly at fire time', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;
      // Simulate the AI fire path: plan a bomb shot and fire it.
      final bomb = Weapons.byId('bomb');
      me.activeCrew!.equipInstant(bomb.id);
      expect(me.activeCrew!.equipped, bomb.id);
      expect(me.activeCrew!.swapping, false,
          reason: 'no raise animation fighting the recoil window');
      ctrl.dispose();
    });
  });
}
