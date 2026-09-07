import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/net.dart';
import 'package:raft_rumble/game/online_api.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/relay_link.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/screens/net_match.dart';

/// The internet transport, without an internet.
///
/// [RelayLink] is the whole of what online play adds to the match: it turns
/// the same JSON lines a hotspot socket carries into `relay_send` posts and
/// `relay_poll` reads. These tests drive it against a stand-in server so the
/// ordering, presence and shutdown rules can be checked deterministically —
/// the live end-to-end run against a real backend lives in
/// `online_relay_live_test.dart`.
class _FakeApi implements OnlineApi {
  /// Lines the "opponent" has queued for us to read back.
  final List<String> inbox = [];

  /// Everything we posted, in the order it reached the server.
  final List<String> sent = [];

  /// How long ago the peer last spoke, as `relay_poll` reports it.
  int? peerAgo = 0;
  String status = 'active';

  /// Fail the next N sends, to exercise the re-queue path.
  int failSends = 0;
  int failPolls = 0;

  int _seq = 0;
  final _pollGate = <Completer<void>>[];

  @override
  String baseUrl = 'http://fake';
  @override
  String game = 'raft';
  @override
  String? token = 't';
  @override
  bool get configured => true;
  @override
  void close() {}

  @override
  Future<Map<String, dynamic>> call(
    String action, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 12),
    bool authed = true,
  }) async {
    if (action == 'relay_send') {
      if (failSends > 0) {
        failSends--;
        throw const OnlineError('boom', offline: true);
      }
      sent.addAll((args['lines'] as List).cast<String>());
      return {'ok': true};
    }
    if (action == 'relay_poll') {
      if (failPolls > 0) {
        failPolls--;
        throw const OnlineError('boom', offline: true);
      }
      // Hand back whatever is waiting; otherwise yield so the loop cannot
      // spin the event queue solid.
      if (inbox.isEmpty) {
        final gate = Completer<void>();
        _pollGate.add(gate);
        await gate.future.timeout(const Duration(milliseconds: 40),
            onTimeout: () {});
      }
      final lines = List<String>.from(inbox);
      inbox.clear();
      _seq += lines.length;
      return {
        'ok': true,
        'seq': _seq,
        'lines': lines,
        'status': status,
        'peerAgo': peerAgo,
      };
    }
    return {'ok': true};
  }

  void release() {
    for (final g in _pollGate) {
      if (!g.isCompleted) g.complete();
    }
    _pollGate.clear();
  }
}

Future<void> _until(bool Function() cond,
    {String reason = 'condition never held',
    Duration limit = const Duration(seconds: 2)}) async {
  final ticks = limit.inMilliseconds ~/ 5;
  for (int i = 0; i < ticks; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail(reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  RaftLoadout loadout({int color = 0}) =>
      RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: color);

  group('RelayLink', () {
    test('sends are delivered in the order they were made', () async {
      final api = _FakeApi();
      final link = RelayLink(api: api, matchId: 1);
      // Three sends in one turn of the event loop: the outbox worker must
      // serialise them rather than racing three requests.
      link.send({'t': 'a', 'n': 1});
      link.send({'t': 'b', 'n': 2});
      link.send({'t': 'c', 'n': 3});

      await _until(() => api.sent.length == 3);
      expect(api.sent[0], contains('"t":"a"'));
      expect(api.sent[1], contains('"t":"b"'));
      expect(api.sent[2], contains('"t":"c"'));
      await link.close();
    });

    test('a failed send is retried, not dropped', () async {
      final api = _FakeApi()..failSends = 1;
      final link = RelayLink(api: api, matchId: 1);
      link.send({'t': 'fire', 'p': 70});

      // The first attempt throws; the batch goes back to the front of the
      // queue and the next attempt carries it. A dropped shot would be a
      // turn silently lost.
      await _until(() => api.sent.length == 1,
          reason: 'the shot was dropped instead of retried');
      expect(api.sent.single, contains('"t":"fire"'));
      await link.close();
    });

    test('incoming lines arrive as decoded messages, malformed ones ignored',
        () async {
      final api = _FakeApi();
      final link = RelayLink(api: api, matchId: 1);
      final seen = <Map<String, dynamic>>[];
      link.messages.listen(seen.add);

      api.inbox.addAll(['{"t":"hello","name":"Pat"}', 'not json at all', '{"t":"endTurn"}']);
      api.release();

      await _until(() => seen.length == 2);
      expect(seen.first['name'], 'Pat');
      expect(seen.last['t'], 'endTurn');
      await link.close();
    });

    test('a silent peer reports absent, then present again — without closing',
        () async {
      final api = _FakeApi();
      final presence = <bool>[];
      final link = RelayLink(
        api: api,
        matchId: 1,
        onPeerPresence: presence.add,
        // The real limit is 22 seconds of wall clock; this is the same rule
        // measured over a window a test can actually sit through.
        peerSilenceLimit: const Duration(milliseconds: 120),
      );

      // Silence far past the limit: they have dropped.
      api.peerAgo = 600;
      api.release();
      await _until(() => presence.contains(false),
          reason: 'a long-silent peer should read as gone');

      // The link must still be alive — it is how their return arrives.
      api.peerAgo = 0;
      api.release();
      await _until(() => presence.contains(true),
          reason: 'the peer coming back must be noticed on the same link');
      await link.close();
    });

    test('the server marking the match done closes the link', () async {
      final api = _FakeApi()..status = 'done';
      var closed = false;
      final link = RelayLink(api: api, matchId: 1, onClosed: () => closed = true);
      api.release();
      await _until(() => closed);
      await link.close();
    });

    test('repeated poll failures give up rather than firing into nothing',
        () async {
      final api = _FakeApi()..failPolls = 99;
      var closed = false;
      final link = RelayLink(api: api, matchId: 1, onClosed: () => closed = true);
      await _until(() => closed,
          reason: 'a link that cannot poll at all must not pretend to work',
          // Five failures, each backed off ~900ms before the link gives up.
          limit: const Duration(seconds: 12));
      await link.close();
    });
  });

  group('NetService over the relay', () {
    test('startRelayMatch greets unprompted and takes the assigned seat',
        () async {
      final api = _FakeApi();
      final net = NetService.forTest();

      expect(
        await net.startRelayMatch(
            api: api, matchId: 7, asHost: true, playerName: 'Skipper'),
        true,
      );
      expect(net.mode, NetMode.online);
      expect(net.isNetworked, true);
      expect(net.isHost, true, reason: 'the seat comes from matchmaking');

      // Unlike a socket join, both ends greet without waiting to be greeted.
      await _until(() => api.sent.any((l) => l.contains('"t":"hello"')));
      expect(api.sent.first, contains('Skipper'));
      await net.close();
      expect(net.mode, NetMode.none, reason: 'closing resets the transport');
    });

    test('chat rides the match protocol in both directions', () async {
      final api = _FakeApi();
      final net = NetService.forTest();
      await net.startRelayMatch(
          api: api, matchId: 7, asHost: false, playerName: 'Me');

      // Ours is echoed locally at once — the relay only returns the other
      // player's lines, so waiting for a round trip would show nothing.
      net.sendChat('nice shot');
      expect(net.chat.single.mine, true);
      expect(net.chat.single.text, 'nice shot');
      await _until(() => api.sent.any((l) => l.contains('nice shot')));

      // Theirs arrives over the wire.
      api.inbox.add('{"t":"hello","name":"Rival"}');
      api.inbox.add('{"t":"chat","m":"good game"}');
      api.release();
      await _until(() => net.chat.length == 2);
      expect(net.chat.last.mine, false);
      expect(net.chat.last.name, 'Rival');
      expect(net.chat.last.text, 'good game');

      await net.close();
      expect(net.chat, isEmpty, reason: 'a new match starts with a clean log');
    });

    test('an empty chat line is never sent', () async {
      final api = _FakeApi();
      final net = NetService.forTest();
      await net.startRelayMatch(api: api, matchId: 7, asHost: true);
      net.sendChat('   ');
      expect(net.chat, isEmpty);
      await net.close();
    });
  });

  group('GameMode.online', () {
    GameController controllerFor(NetService net) => GameController(
          settings: MatchSettings(
              map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
          players: [
            PlayerConfig(name: 'HOST', loadout: loadout(), netId: 0),
            PlayerConfig(name: 'GUEST', loadout: loadout(color: 1), netId: 1),
          ],
          mode: GameMode.online,
          net: net,
          seed: 9,
        );

    test('inherits the hotspot seat mapping and turn gating', () async {
      final hostNet = NetService.forTest()..isHost = true;
      final guestNet = NetService.forTest()..isHost = false;
      await hostNet.startRelayMatch(api: _FakeApi(), matchId: 1, asHost: true);
      await guestNet.startRelayMatch(api: _FakeApi(), matchId: 1, asHost: false);

      final host = controllerFor(hostNet);
      final guest = controllerFor(guestNet);

      expect(host.isNetworked, true);
      expect(guest.isNetworked, true);
      expect(host.myPlayerIndex, 0);
      expect(guest.myPlayerIndex, 1);
      // Player 0 opens, so only the host may act.
      expect(host.canHumanAct, true);
      expect(guest.canHumanAct, false);

      host.dispose();
      guest.dispose();
      await hostNet.close();
      await guestNet.close();
    });

    test('a shot only leaves the device whose turn it is', () async {
      final guestApi = _FakeApi();
      final guestNet = NetService.forTest();
      await guestNet.startRelayMatch(
          api: guestApi, matchId: 1, asHost: false);
      final guest = controllerFor(guestNet);

      guestApi.sent.clear();
      guest.humanFire(); // not their turn
      expect(guest.world.shot, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(guestApi.sent.any((l) => l.contains('"t":"fire"')), false,
          reason: 'firing out of turn must not even reach the wire');

      guest.dispose();
      await guestNet.close();
    });
  });

  group('Match setup travels with the start message', () {
    test('both rafts cross the wire, so the two sims match', () {
      // Each device simulates the whole battle and only exchanges shots, so
      // a raft read from the local save on one side and the message on the
      // other would give the two sims different deck geometry.
      final hostRaft =
          RaftLoadout.custom(hullId: 'galleon', sizeId: 'large', colorIndex: 3);
      final guestRaft =
          RaftLoadout.custom(hullId: 'barrel', sizeId: 'small', colorIndex: 5);

      final payload = _startPayload(hostRaft, guestRaft);
      final setup = _fromStart(payload);

      expect(setup.players[0].loadout.hull.id, 'galleon');
      expect(setup.players[0].loadout.size.id, 'large');
      expect(setup.players[0].loadout.colorIndex, 3);
      expect(setup.players[1].loadout.hull.id, 'barrel');
      expect(setup.players[1].loadout.colorIndex, 5);
      expect(setup.seed, 1234);
      expect(setup.settings.map.id, GameMaps.all.first.id);
    });

    test('a malformed start still yields a playable match', () {
      final setup = _fromStart({'t': 'start'});
      expect(setup.players.length, 2);
      expect(setup.settings.startHp, 100);
      expect(setup.seed, isPositive);
    });
  });
}

Map<String, dynamic> _startPayload(RaftLoadout host, RaftLoadout guest) =>
    NetMatchSetup.startPayload(
      map: GameMaps.all.first,
      startHp: 100,
      seed: 1234,
      hostRaft: host,
      guestRaft: guest,
      hostName: 'Skipper',
    );

NetMatchSetup _fromStart(Map<String, dynamic> msg) =>
    NetMatchSetup.fromStart(msg, guestName: 'Mate');
