import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/match_store.dart';
import 'package:raft_rumble/game/net.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/net_match.dart';

/// Resuming a hotspot battle after an app is killed.
///
/// This is a harder problem than the online case and these tests are shaped
/// around why. Online, the relay is a server: it holds the match open and
/// keeps the history, so a returning player reads on from a cursor and the
/// server is the single source of truth. A hotspot match has neither. The
/// socket died with the app, everything sent while a device was away is gone,
/// and the two phones have to sort it out between themselves.
///
/// So there are two things to get right, and both are tested over REAL
/// sockets rather than a fake link — the failure modes here are all about two
/// independent devices, and a loopback pair is the cheapest honest way to
/// have two.
///
///  1. **Rendezvous** — after a kill there has to be something left to
///     reconnect *to*. The survivor re-opens itself; the returning device
///     knows which half of that to perform from the seat it held.
///  2. **Reconciliation** — the two devices compare accounts of the battle and
///     must independently reach the SAME answer, or the match desyncs and
///     every shot after it lands somewhere different on each screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final services = <NetService>[];
  NetService svc() {
    final s = NetService.forTest();
    services.add(s);
    return s;
  }

  setUp(() {
    SaveService.instance.data = SaveData();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    // Cancel every resume BEFORE closing anything. Closing one end drops the
    // other's link, and a service that still holds an offer answers that by
    // dialling back — which would run on into the next test and answer its
    // connection instead of the host it is actually waiting for.
    for (final s in services) {
      s.cancelResume();
    }
    for (final s in services) {
      await s.close();
    }
    services.clear();
    // Listeners go away asynchronously. Waiting for the port to actually be
    // bindable again is deterministic where a fixed sleep is a guess.
    for (int i = 0; i < 100; i++) {
      try {
        final probe =
            await ServerSocket.bind(InternetAddress.anyIPv4, kGamePort);
        await probe.close();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  Future<void> until(
    bool Function() cond, {
    String reason = 'condition never came true',
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail(reason);
  }

  ResumeOffer offer(String key, int seq, String who) =>
      ResumeOffer(key: key, seq: seq, state: {'who': who, 'turnSeq': seq});

  /// A connected host/guest pair over the loopback interface.
  Future<(NetService, NetService)> pair({
    ResumeOffer? hostOffer,
    ResumeOffer? guestOffer,
    String code = 'ROOM',
  }) async {
    final host = svc();
    final guest = svc();
    expect(await host.host(playerName: 'Skipper', code: code), code,
        reason: 'could not bind the hotspot port');
    host.resumeOffer = hostOffer;
    guest.resumeOffer = guestOffer;
    expect(await guest.join('127.0.0.1', playerName: 'Mate'), true);
    return (host, guest);
  }

  group('Reconciliation', () {
    test('both devices adopt the further-on account', () async {
      Map<String, dynamic>? hostGot, guestGot;
      final (host, guest) = await pair(
        hostOffer: offer('ROOM:7', 4, 'host'),
        guestOffer: offer('ROOM:7', 9, 'guest'),
      );
      host.onResumeAgreed = (s) => hostGot = s;
      guest.onResumeAgreed = (s) => guestGot = s;

      await until(() => hostGot != null && guestGot != null,
          reason: 'the two never settled on a state');

      // The guest had played two more turns before the host died, so its
      // account is the real one — and crucially the host adopts it too,
      // rather than each keeping its own and drifting apart.
      expect(hostGot!['who'], 'guest');
      expect(guestGot!['who'], 'guest');
    });

    test('a tie is broken the same way on both devices', () async {
      // Equal sequence means both were at the same turn boundary, where the
      // two states already agree. The tiebreak only has to be CONSISTENT.
      Map<String, dynamic>? hostGot, guestGot;
      final (host, guest) = await pair(
        hostOffer: offer('ROOM:7', 5, 'host'),
        guestOffer: offer('ROOM:7', 5, 'guest'),
      );
      host.onResumeAgreed = (s) => hostGot = s;
      guest.onResumeAgreed = (s) => guestGot = s;

      await until(() => hostGot != null && guestGot != null);
      expect(hostGot!['who'], 'host');
      expect(guestGot!['who'], 'host',
          reason: 'both must land on the same account, whichever it is');
    });

    test('two different battles are refused rather than merged', () async {
      // The nightmare: yesterday's snapshot pasted onto today's match. The
      // room code and seed together are what make that detectable.
      final failures = <String>[];
      Map<String, dynamic>? agreed;
      final (host, guest) = await pair(
        hostOffer: offer('ROOM:7', 3, 'host'),
        guestOffer: offer('OTHER:99', 3, 'guest'),
      );
      host.onResumeFailed = failures.add;
      guest.onResumeFailed = failures.add;
      host.onResumeAgreed = (s) => agreed = s;
      guest.onResumeAgreed = (s) => agreed = s;

      await until(() => failures.length >= 2,
          reason: 'a mismatched key must be reported, not ignored');
      expect(agreed, isNull, reason: 'nothing should have been restored');
    });

    test('a peer with nothing saved says so', () async {
      final failures = <String>[];
      final (host, _) = await pair(hostOffer: offer('ROOM:7', 3, 'host'));
      host.onResumeFailed = failures.add;

      await until(() => failures.isNotEmpty,
          reason: 'the guest had no saved match and should have said so');
      expect(failures.first, contains('no saved match'));
    });

    test('the agreement settles once, not once per greeting', () async {
      // Both ends greet unprompted AND the host answers a hello with another
      // one, so the handshake is deliberately chatty. Restoring twice would
      // re-run _beginTurn mid-match.
      int hostCount = 0;
      final (host, _) = await pair(
        hostOffer: offer('ROOM:7', 2, 'host'),
        guestOffer: offer('ROOM:7', 2, 'guest'),
      );
      host.onResumeAgreed = (_) => hostCount++;
      await until(() => hostCount > 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hostCount, 1);
    });
  });

  group('Rendezvous', () {
    test('a host re-opens the room on its original code', () async {
      // The guest is looking for that specific code, in its snapshot and in a
      // scan. A fresh code would be a different room to everyone but us.
      final host = svc();
      expect(await host.host(playerName: 'Skipper', code: 'WXYZ'), 'WXYZ');
      expect(host.roomCode, 'WXYZ');
    });

    test('a host stays reachable after the guest vanishes', () async {
      // The case that made hotspot resume look impossible: the guest's app
      // dies, and by the time they press RESUME the host has torn down its
      // listener and stopped beaconing, so there is nothing to come back to.
      final (host, guest) = await pair(hostOffer: offer('ROOM:7', 6, 'host'));
      await until(() => host.connected);

      await guest.close(); // the guest's app is killed
      await until(() => !host.connected,
          reason: 'the host never noticed the guest go');

      // The same player relaunches and walks back in.
      Map<String, dynamic>? agreed;
      final back = svc();
      back.onResumeAgreed = (s) => agreed = s;
      expect(
        await back.resumeJoin(
          '127.0.0.1',
          playerName: 'Mate',
          offer: offer('ROOM:7', 5, 'returning'),
          timeout: const Duration(seconds: 5),
        ),
        true,
        reason: 'the room should still be listening',
      );
      await until(() => agreed != null);
      expect(agreed!['who'], 'host',
          reason: 'the host played on and is further ahead');
    });

    test('a guest keeps dialling while the host is still restarting',
        () async {
      // Both apps were killed, so whoever presses RESUME first finds nobody
      // home. Failing on the first refused connection would make resuming a
      // race on who tapped faster.
      final guest = svc();
      Map<String, dynamic>? agreed;
      guest.onResumeAgreed = (s) => agreed = s;

      final dialling = guest.resumeJoin(
        '127.0.0.1',
        playerName: 'Mate',
        offer: offer('ROOM:7', 8, 'guest'),
        timeout: const Duration(seconds: 12),
      );

      // The host takes its time coming back. resumeHost is used rather than
      // host()+assignment because the order matters: the offer has to be in
      // place before the listener can accept, or the first knock is answered
      // as "I have no saved match".
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final host = svc();
      await host.resumeHost(
        playerName: 'Skipper',
        roomCode: 'ROOM',
        offer: offer('ROOM:7', 8, 'host'),
      );

      expect(await dialling, true, reason: 'the retry loop should have caught it');
      await until(() => agreed != null);
    });

    test('cancelling stops the dialling and drops the offer', () async {
      final guest = svc();
      final dialling = guest.resumeJoin(
        '127.0.0.1',
        playerName: 'Mate',
        offer: offer('ROOM:7', 1, 'guest'),
        timeout: const Duration(seconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      guest.cancelResume();
      expect(await dialling.timeout(const Duration(seconds: 8)), false);
      expect(guest.resumeOffer, isNull);
    });

    test('forfeiting stops a reconnect that was already under way', () async {
      // When the host's app dies the guest starts dialling it back by itself,
      // with no button pressed. If the player then forfeits, that background
      // loop has to stop — the automatic path used to run through the same
      // entry point as the manual one, which cleared the cancellation on its
      // way in and quietly resurrected dialling the player had just stopped.
      final (host, guest) = await pair(
        hostOffer: offer('ROOM:7', 3, 'host'),
        guestOffer: offer('ROOM:7', 3, 'guest'),
      );
      await until(() => guest.connected);

      await host.close(); // the host's app is killed
      await until(() => !guest.connected);
      guest.cancelResume(); // …and the player gives up on them

      // The host coming back must not drag a forfeited player into the match.
      final revived = svc();
      expect(
        await revived.resumeHost(
          playerName: 'Skipper',
          roomCode: 'ROOM',
          offer: offer('ROOM:7', 3, 'host'),
        ),
        'ROOM',
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(guest.connected, false,
          reason: 'a cancelled resume has to stay cancelled');
    });

    test('an earlier match ending does not disable the next reconnect',
        () async {
      // MatchStore calls cancelResume() whenever a match finishes, and the
      // service is a singleton that outlives it. A cancellation recorded as a
      // sticky flag would therefore switch the automatic reconnect off for
      // every match played afterwards in the same session — a bug nobody
      // would ever reproduce on the first match of a run.
      final (host, guest) = await pair(
        hostOffer: offer('ROOM:7', 4, 'host'),
        guestOffer: offer('ROOM:7', 4, 'guest'),
      );
      await until(() => guest.connected);
      guest.cancelResume(); // an earlier battle finished
      guest.resumeOffer = offer('ROOM:7', 4, 'guest'); // and a new one began

      await host.close();
      await until(() => !guest.connected);

      final revived = svc();
      await revived.resumeHost(
        playerName: 'Skipper',
        roomCode: 'ROOM',
        offer: offer('ROOM:7', 4, 'host'),
      );
      await until(() => guest.connected,
          timeout: const Duration(seconds: 15),
          reason: 'the automatic reconnect should still be armed');
    });

    test('close keeps the resume, because host() and join() both call it',
        () async {
      // Clearing the offer in close() would destroy the resume on the way
      // into the very connection meant to restore it.
      final n = svc();
      n.resumeOffer = offer('ROOM:7', 3, 'me');
      await n.close();
      expect(n.resumeOffer, isNotNull);
      expect(n.joinedHostAddress, isEmpty);

      n.cancelResume();
      expect(n.resumeOffer, isNull,
          reason: 'ending a match for good goes through cancelResume');
    });

    test('a guest remembers the address it dialled', () async {
      final (_, guest) = await pair();
      expect(guest.joinedHostAddress, '127.0.0.1');
    });

    test('a guest learns the room code from the host greeting', () async {
      // Half the match identity a later resume is checked against, and the
      // guest has no other way to know it.
      final (_, guest) = await pair(code: 'QRST');
      await until(() => guest.roomCode.isNotEmpty);
      expect(guest.roomCode, 'QRST');
    });
  });

  group('Snapshot', () {
    Map<String, dynamic> start() => NetMatchSetup.startPayload(
          map: GameMaps.all.first,
          startHp: 100,
          seed: 4242,
          hostRaft: RaftLoadout.custom(
              hullId: 'log', sizeId: 'medium', colorIndex: 0),
          guestRaft: RaftLoadout.custom(
              hullId: 'log', sizeId: 'medium', colorIndex: 1),
          hostName: 'Skipper',
        );

    MatchSnapshot sample({DateTime? at}) => MatchSnapshot(
          start: start(),
          state: const {'round': 3},
          matchId: 0,
          iAmHost: false,
          relaySince: 0,
          peerName: 'Skipper',
          savedAt: at ?? DateTime.now(),
          transport: NetMode.hotspot,
          roomCode: 'ABCD',
          hostAddress: '192.168.43.1',
          turnSeq: 11,
        );

    test('a hotspot match round-trips with what it needs to rejoin', () {
      final back = MatchSnapshot.fromJson(sample().toJson())!;
      expect(back.isHotspot, true);
      expect(back.roomCode, 'ABCD');
      expect(back.hostAddress, '192.168.43.1',
          reason: 'without it the guest has nowhere to dial');
      expect(back.turnSeq, 11, reason: 'without it there is no reconciling');
      expect(back.iAmHost, false);
    });

    test('the match key pins both the room and the battle', () {
      // The room code repeats across sessions and a seed says nothing about
      // which pair of devices agreed on it; together they identify a match.
      expect(sample().matchKey, 'ABCD:4242');
      final o = sample().offer;
      expect(o.key, 'ABCD:4242');
      expect(o.seq, 11);
    });

    test('a snapshot saved before hotspot resume existed still reads as online',
        () {
      final legacy = {
        'start': start(),
        'state': const {'round': 2},
        'matchId': 88,
        'iAmHost': true,
        'relaySince': 40,
        'peerName': 'Rival',
        'savedAt': DateTime.now().toIso8601String(),
      };
      final back = MatchSnapshot.fromJson(legacy)!;
      expect(back.isHotspot, false);
      expect(back.matchId, 88);
      expect(back.relaySince, 40);
    });

    test('an online entry with no match id is still rejected', () {
      final j = sample().toJson()
        ..['transport'] = 'online'
        ..remove('matchId');
      expect(MatchSnapshot.fromJson(j), isNull,
          reason: 'there would be nothing to rejoin');
    });

    test('a hotspot entry goes stale far sooner than an online one', () async {
      // Resuming a LAN match needs both devices back on the same network with
      // the host's address unchanged. That survives a crash, not an afternoon.
      expect(MatchStore.hotspotStaleAfter, lessThan(MatchStore.staleAfter));

      final store = MatchStore.instance;
      await store.clear();
      SharedPreferences.setMockInitialValues({
        'raft_match_saved_v1': _encode(
          sample(at: DateTime.now().subtract(const Duration(hours: 3))),
        ),
      });
      await store.load();
      expect(store.saved, isNull, reason: 'three hours is a dead LAN match');

      SharedPreferences.setMockInitialValues({
        'raft_match_saved_v1': _encode(
          sample(at: DateTime.now().subtract(const Duration(minutes: 5))),
        ),
      });
      await store.load();
      expect(store.saved, isNotNull);
      await store.clear();
    });
  });

  group('Store wiring', () {
    test('a live hotspot match keeps its offer current', () async {
      final store = MatchStore.instance;
      await store.clear();

      final (host, _) = await pair(code: 'LIVE');
      final setup = NetMatchSetup.fromStart(
        NetMatchSetup.startPayload(
          map: GameMaps.all.first,
          startHp: 100,
          seed: 4242,
          hostRaft: RaftLoadout.custom(
              hullId: 'log', sizeId: 'medium', colorIndex: 0),
          guestRaft: RaftLoadout.custom(
              hullId: 'log', sizeId: 'medium', colorIndex: 1),
          hostName: 'Skipper',
        ),
        guestName: 'Mate',
      );
      final ctrl = GameController(
        settings: setup.settings,
        players: setup.players,
        mode: GameMode.vsAi,
        seed: setup.seed,
      );

      store.attach(ctrl, host, start: NetMatchSetup.startPayload(
        map: GameMaps.all.first,
        startHp: 100,
        seed: 4242,
        hostRaft:
            RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 0),
        guestRaft:
            RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 1),
        hostName: 'Skipper',
      ));

      // A returning peer must be answered with the same account this device
      // would resume from itself.
      expect(host.resumeOffer, isNotNull,
          reason: 'a hotspot match is now tracked, not skipped');
      expect(host.resumeOffer!.key, 'LIVE:4242');
      expect(store.saved?.isHotspot, true);
      expect(store.saved?.roomCode, 'LIVE');

      // And the survivor can take a reconciled state without leaving the
      // battle — the ordinary case when only one of the two apps died.
      host.onResumeAgreed!({
        'currentPlayer': 1,
        'round': 6,
        'turnSeq': 12,
        'rafts': [
          {'player': 0, 'hp': [33.0, 33.0]},
        ],
      });
      expect(ctrl.round, 6);
      expect(ctrl.world.raftOf(0)!.crew[0].hp, 33);

      store.detach();
      expect(host.onResumeAgreed, isNull);
      ctrl.dispose();
      await store.clear();
    });
  });
}

String _encode(MatchSnapshot s) => jsonEncode(s.toJson());
