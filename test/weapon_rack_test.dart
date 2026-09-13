import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// Each seat carries its own weapons.
///
/// The rack used to be one `selectedWeaponId` and one `ammo` map shared by
/// the whole match, which is wrong in three different ways and all of them
/// show up in play:
///
///  * two players sharing one pouch, so spending a bomb spent it for both;
///  * the AI writing its choice into the same field at fire time, so an
///    enemy turn swapped the player's weapon out from under them;
///  * a networked shot, which is applied locally with `currentPlayer` set to
///    the remote seat, spending the *local* player's ammunition.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  RaftLoadout lo({int c = 0}) =>
      RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: c);

  /// A match with two seats; [ai] says whether seat 1 is the computer.
  GameController match({bool ai = true}) => GameController(
        settings: MatchSettings(map: GameMaps.all.first, startHp: 100),
        players: [
          PlayerConfig(name: 'P1', loadout: lo()),
          PlayerConfig(
            name: 'P2',
            loadout: lo(c: 1),
            isAi: ai,
            aiDifficulty: AiDifficulty.easy,
          ),
        ],
        mode: ai ? GameMode.vsAi : GameMode.local,
        seed: 42,
      );

  /// A weapon that is stocked rather than infinite.
  WeaponDef limited() =>
      Weapons.all.firstWhere((w) => !w.infinite, orElse: () => Weapons.starter);

  group('Racks are per seat', () {
    test('every seat starts with its own full rack', () {
      final ctrl = match();
      final w = limited().id;
      expect(ctrl.ammoOf(0)[w], isNotNull);
      expect(ctrl.ammoOf(1)[w], ctrl.ammoOf(0)[w],
          reason: 'both seats should start equally stocked');
      expect(identical(ctrl.ammoOf(0), ctrl.ammoOf(1)), false,
          reason: 'the two seats are sharing one rack object');
      ctrl.dispose();
    });

    test('spending one seat\'s ammo does not touch the other\'s', () {
      final ctrl = match(ai: false);
      final w = limited().id;
      final before = ctrl.ammoOf(1)[w];

      ctrl.setWeaponOf(0, w);
      ctrl.humanFire();

      expect(ctrl.ammoOf(0)[w], before! - 1, reason: 'the shooter paid');
      expect(ctrl.ammoOf(1)[w], before,
          reason: 'the opponent paid for a shot they did not take');
      ctrl.dispose();
    });

    test('choosing a weapon does not change what the opponent holds', () {
      final ctrl = match(ai: false);
      final w = limited().id;
      final theirs = ctrl.weaponOf(1);

      ctrl.selectWeapon(w);
      expect(ctrl.weaponOf(0), w);
      expect(ctrl.weaponOf(1), theirs,
          reason: 'picking a weapon reached across and changed the other '
              'seat\'s selection');
      ctrl.dispose();
    });

    test('hot-seat: the HUD follows whoever is up', () {
      // Two humans share one screen, so the weapon bar has to show the rack
      // of whoever's turn it is — not a fixed seat.
      final ctrl = match(ai: false);
      final w = limited().id;
      ctrl.setWeaponOf(0, w);
      ctrl.setWeaponOf(1, Weapons.starter.id);

      expect(ctrl.currentPlayer, 0);
      expect(ctrl.selectedWeaponId, w);

      ctrl.beginTurnForTest(1);
      expect(ctrl.selectedWeaponId, Weapons.starter.id,
          reason: 'the second player was handed the first player\'s weapon');
      ctrl.dispose();
    });
  });

  group('The AI keeps its hands off the player\'s rack', () {
    test('an enemy turn does not change the player\'s selected weapon', () {
      // The complaint. The AI picks its weapon at fire time and used to
      // write it into the single shared field, so the player came back to
      // their turn holding whatever the computer had just thrown.
      final ctrl = match();
      final w = limited().id;
      ctrl.selectWeapon(w);
      expect(ctrl.weaponOf(0), w);

      // Hand over and let the AI take its whole turn.
      ctrl.beginTurnForTest(1);
      var fired = false;
      for (int f = 0; f < 60 * 20 && !fired; f++) {
        ctrl.stepForTest(1 / 60);
        if (ctrl.world.shot != null) fired = true;
      }
      expect(fired, true,
          reason: 'the AI never fired, so this test proves nothing');

      expect(ctrl.weaponOf(0), w,
          reason: 'the AI\'s shot changed what the player was holding');
      ctrl.dispose();
    });

    test('the AI never spends the player\'s ammunition', () {
      final ctrl = match();
      final w = limited().id;
      final before = ctrl.ammoOf(0)[w];

      // Hand over and let the AI take its whole turn.
      ctrl.beginTurnForTest(1);
      var fired = false;
      for (int f = 0; f < 60 * 20 && !fired; f++) {
        ctrl.stepForTest(1 / 60);
        if (ctrl.world.shot != null) fired = true;
      }
      expect(fired, true,
          reason: 'the AI never fired, so this test proves nothing');

      expect(ctrl.ammoOf(0)[w], before,
          reason: 'an enemy turn cost the player a round');
      ctrl.dispose();
    });
  });

  group('Running dry', () {
    test('an empty weapon is dropped for that seat only', () {
      final ctrl = match(ai: false);
      final w = limited().id;
      ctrl.setWeaponOf(0, w);
      ctrl.setWeaponOf(1, w);
      ctrl.ammoOf(0)[w] = 1;

      ctrl.humanFire();

      expect(ctrl.weaponOf(0), Weapons.starter.id,
          reason: 'a seat that ran dry should fall back to the starter');
      expect(ctrl.weaponOf(1), w,
          reason: 'the other seat still has rounds and should keep its pick');
      ctrl.dispose();
    });

    test('a seat cannot fire a weapon it has none of', () {
      final ctrl = match(ai: false);
      final w = limited().id;
      ctrl.setWeaponOf(0, w);
      ctrl.ammoOf(0)[w] = 0;
      expect(ctrl.canFire, false);

      final inFlight = ctrl.world.shot;
      ctrl.humanFire();
      expect(identical(ctrl.world.shot, inFlight), true,
          reason: 'fired a weapon this seat had none of');
      ctrl.dispose();
    });

    test('one seat running dry leaves the other able to fire', () {
      final ctrl = match(ai: false);
      final w = limited().id;
      ctrl.ammoOf(0)[w] = 0;
      ctrl.setWeaponOf(1, w);

      ctrl.beginTurnForTest(1);
      expect(ctrl.weaponOf(1), w,
          reason: 'the second seat was disarmed by the first seat running out');
      expect(ctrl.canFire, true);
      ctrl.dispose();
    });
  });
}
