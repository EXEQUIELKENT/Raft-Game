import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as ft;
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/match_store.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/net_match.dart';

/// Resuming a battle after the app is killed.
///
/// A match is lockstep — both devices build the same world from one seed and
/// then exchange only shots — so a resume is not a physics save. It is the
/// `start` payload (which rebuilds the world exactly) plus what has happened
/// to that world since. These tests pin both halves: that a snapshot carries
/// enough to restore a match faithfully, and that it degrades safely when it
/// does not.
void main() {
  ft.TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  RaftLoadout loadout({int color = 0}) =>
      RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: color);

  Map<String, dynamic> startPayload() => NetMatchSetup.startPayload(
        map: GameMaps.all.first,
        startHp: 100,
        seed: 777,
        hostRaft: loadout(),
        guestRaft: loadout(color: 1),
        hostName: 'Skipper',
      );

  GameController build(Map<String, dynamic> start) {
    final setup = NetMatchSetup.fromStart(start, guestName: 'Mate');
    return GameController(
      settings: setup.settings,
      players: setup.players,
      mode: GameMode.vsAi,
      seed: setup.seed,
    );
  }

  group('Snapshot and restore', () {
    test('a battle in progress comes back exactly as it was left', () {
      final start = startPayload();
      final before = build(start);

      // Play the match forward: damage on both sides, ammo spent, a couple
      // of turns gone by, and the other seat up next.
      before.world.raftOf(0)!.crew[0].hp = 41;
      before.world.raftOf(1)!.crew[0].hp = 12;
      before.world.raftOf(1)!.activeIndex = 1;
      before.ammo['grenade'] = 1;
      before.selectWeapon('grenade');
      before.round = 4;
      before.shotsFired = 9;
      before.shotsHit = 5;
      before.damageDealtByHuman = 133;
      before.currentPlayer = 1;

      final snap = before.snapshotState();
      before.dispose();

      // A fresh launch: same seed, same start message, nothing else.
      final after = build(start);
      after.restoreState(snap);

      expect(after.world.raftOf(0)!.crew[0].hp, 41);
      expect(after.world.raftOf(1)!.crew[0].hp, 12);
      expect(after.world.raftOf(1)!.activeIndex, 1);
      expect(after.ammo['grenade'], 1);
      expect(after.selectedWeaponId, 'grenade');
      expect(after.round, 4);
      expect(after.shotsFired, 9);
      expect(after.shotsHit, 5);
      expect(after.damageDealtByHuman, 133);
      expect(after.currentPlayer, 1, reason: 'the same seat is still up');
      expect(after.phase, GamePhase.aiming);
      after.dispose();
    });

    test('the world itself is rebuilt identically from the start payload', () {
      // The snapshot deliberately carries no geometry: the seed and the two
      // raft descriptions are what make both devices agree, and a resume is
      // just a third device doing the same thing.
      final start = startPayload();
      final a = build(start);
      final b = build(start);

      expect(b.world.rafts.length, a.world.rafts.length);
      for (int i = 0; i < a.world.rafts.length; i++) {
        expect(b.world.rafts[i].x, a.world.rafts[i].x);
        expect(b.world.rafts[i].loadout.hull.id, a.world.rafts[i].loadout.hull.id);
        expect(b.world.rafts[i].crew.length, a.world.rafts[i].crew.length);
        for (int c = 0; c < a.world.rafts[i].crew.length; c++) {
          expect(b.world.rafts[i].stationX(c), a.world.rafts[i].stationX(c),
              reason: 'crew must stand in the same place on both builds');
        }
      }
      a.dispose();
      b.dispose();
    });

    test('a seat eliminated while away passes the turn instead of hanging', () {
      final start = startPayload();
      final ctrl = build(start);
      final snap = ctrl.snapshotState();
      // The saved turn belonged to player 1 — who is wiped out in the
      // snapshot. Restoring must not leave the match waiting on a dead seat.
      snap['currentPlayer'] = 1;
      (snap['rafts'] as List)[1]['hp'] = [0.0, 0.0];

      ctrl.restoreState(snap);
      expect(ctrl.world.raftOf(1)!.alive, false);
      expect(ctrl.currentPlayer, 0, reason: 'play passes to whoever is left');
      ctrl.dispose();
    });

    test('a malformed snapshot leaves a playable match rather than throwing', () {
      final ctrl = build(startPayload());
      expect(() => ctrl.restoreState({}), returnsNormally);
      expect(() => ctrl.restoreState({'rafts': 'nonsense', 'ammo': 7}),
          returnsNormally);
      expect(
          () => ctrl.restoreState({
                'rafts': [
                  {'player': 99, 'hp': 'bad'},
                  {'player': 0, 'hp': [null, 'x']},
                ],
                'weapon': 'no-such-weapon',
              }),
          returnsNormally);
      expect(ctrl.phase, GamePhase.aiming);
      expect(Weapons.all.any((w) => w.id == ctrl.selectedWeaponId), true,
          reason: 'an unknown weapon id must not be adopted');
      ctrl.dispose();
    });

    test('hp is clamped to the crew it is restored onto', () {
      final ctrl = build(startPayload());
      final snap = ctrl.snapshotState();
      (snap['rafts'] as List)[0]['hp'] = [99999.0, -50.0];
      ctrl.restoreState(snap);
      final crew = ctrl.world.raftOf(0)!.crew;
      expect(crew[0].hp, crew[0].maxHp);
      expect(crew[1].hp, 0);
      ctrl.dispose();
    });
  });

  group('MatchSnapshot serialisation', () {
    MatchSnapshot sample() => MatchSnapshot(
          start: startPayload(),
          state: const {'round': 3, 'currentPlayer': 1},
          matchId: 42,
          iAmHost: true,
          relaySince: 17,
          peerName: 'Rival',
          savedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        );

    test('round-trips through JSON', () {
      final back = MatchSnapshot.fromJson(sample().toJson())!;
      expect(back.matchId, 42);
      expect(back.iAmHost, true);
      expect(back.peerName, 'Rival');
      expect(back.state['round'], 3);
      expect(back.start['seed'], 777);
      expect(back.savedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('the relay cursor survives — resuming at 0 would replay the match', () {
      // Every shot of the match is still sitting in the server's history.
      // Rebuilding the link at `since: 0` would hand them all back and
      // re-fire each one, which is the single worst thing a resume can do.
      final back = MatchSnapshot.fromJson(sample().toJson())!;
      expect(back.relaySince, 17);
    });

    test('an unreadable entry is rejected rather than half-loaded', () {
      expect(MatchSnapshot.fromJson({}), isNull);
      expect(MatchSnapshot.fromJson({'start': 'not a map', 'state': {}, 'matchId': 1}),
          isNull);
      expect(MatchSnapshot.fromJson({'start': {}, 'state': {}}), isNull,
          reason: 'without a match id there is nothing to rejoin');
    });
  });
}
