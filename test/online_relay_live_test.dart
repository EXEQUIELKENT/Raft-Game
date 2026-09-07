@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/net.dart';
import 'package:raft_rumble/game/online_api.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/game/server_discovery.dart';

/// End-to-end online play against a REAL server.
///
/// Excluded from the normal suite (tagged `live`) because it needs the PHP
/// backend and its database actually running — but it is the only thing that
/// proves the whole chain: two accounts register under this game, matchmaking
/// pairs them with each other and nobody else, the relay carries Raft's own
/// protocol between two real `GameController`s, and a shot fired on one device
/// lands on the other.
///
///   flutter test test/online_relay_live_test.dart --tags live \
///     --dart-define=RAFT_TEST_SERVER=http://127.0.0.1/Battle-Ship-Blitz-Mobile-Game/server
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const base = String.fromEnvironment(
    'RAFT_TEST_SERVER',
    defaultValue: 'http://127.0.0.1/Battle-Ship-Blitz-Mobile-Game/server',
  );

  OnlineApi apiFor({String game = kGameId}) => OnlineApi()
    ..baseUrl = base
    ..game = game;

  /// Registers a throwaway account and returns its api client plus id.
  Future<(OnlineApi, int)> signUp(String name, {String game = kGameId}) async {
    final api = apiFor(game: game);
    final res = await api.call('register', args: {'name': name}, authed: false);
    api.token = res['token'] as String?;
    expect(res['game'], game, reason: 'the server should file us under $game');
    return (api, (res['id'] as num).toInt());
  }

  RaftLoadout loadout({int color = 0}) =>
      RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: color);

  setUp(() {
    SaveService.instance.data = SaveData();
    // TestWidgetsFlutterBinding installs an HttpOverrides that answers every
    // request with a 400 so unit tests can never touch the network. This
    // suite exists precisely to touch it, so hand the real client back.
    HttpOverrides.global = null;
  });

  test('the server advertises this game', () async {
    final api = apiFor();
    final res = await api.call('ping', authed: false);
    expect(res['games'], contains(kGameId),
        reason: 'discovery matches on this list');
    api.close();
  });

  test('matchmaking never pairs across games', () async {
    // A Battleship captain sitting in the queue must be invisible to Raft.
    final (bsb, _) = await signUp('LiveShip', game: 'bsb');
    await bsb.call('queue_join');

    final (raft, _) = await signUp('LiveRaftSolo');
    final res = await raft.call('queue_join');
    expect(res['searching'], true,
        reason: 'a waiting Battleship captain is not a Raft candidate');
    expect(res['match'], isNull);

    await raft.call('queue_leave');
    await bsb.call('queue_leave');
    bsb.close();
    raft.close();
  });

  test('two captains are paired, and the relay carries a real match', () async {
    final (hostApi, hostId) = await signUp('LiveHost');
    final (guestApi, guestId) = await signUp('LiveGuest');

    // --- matchmaking: first in queue hosts -------------------------------
    await hostApi.call('queue_join');
    final paired = await guestApi.call('queue_join');
    final match = paired['match'] as Map?;
    expect(match, isNotNull, reason: 'the second searcher should pair');
    final matchId = (match!['id'] as num).toInt();
    expect(match['youAreHost'], false, reason: 'whoever waited first hosts');
    expect((match['peerId'] as num).toInt(), hostId);

    // Both accept; the match only goes live on the second yes.
    await hostApi.call('accept_match', args: {'matchId': matchId});
    final live = await guestApi.call('accept_match', args: {'matchId': matchId});
    expect(live['status'], 'active',
        reason: 'the match goes live on the second acceptance');

    // --- the relay, under two real NetServices ---------------------------
    // Separate instances rather than the singleton: this is two devices.
    final hostNet = NetService.forTest();
    final guestNet = NetService.forTest();

    expect(
      await hostNet.startRelayMatch(
          api: hostApi, matchId: matchId, asHost: true, playerName: 'LiveHost'),
      true,
    );
    expect(
      await guestNet.startRelayMatch(
          api: guestApi, matchId: matchId, asHost: false, playerName: 'LiveGuest'),
      true,
    );

    // Each side greets unprompted over the relay; give the poll loops a
    // moment to carry both hellos across.
    await _until(() => hostNet.peerName == 'LiveGuest' && guestNet.peerName == 'LiveHost');
    expect(hostNet.handshakeDone, true);
    expect(guestNet.handshakeDone, true);

    // --- the same protocol a hotspot match speaks ------------------------
    const seed = 4242;
    final settings = MatchSettings(
        map: GameMaps.all.first, startHp: 100, turnSeconds: 30);
    List<PlayerConfig> seats() => [
          PlayerConfig(name: 'HOST', loadout: loadout(), netId: 0),
          PlayerConfig(name: 'GUEST', loadout: loadout(color: 1), netId: 1),
        ];

    final hostGame = GameController(
        settings: settings, players: seats(), mode: GameMode.online,
        net: hostNet, seed: seed);
    final guestGame = GameController(
        settings: settings, players: seats(), mode: GameMode.online,
        net: guestNet, seed: seed);

    // Seats: matchmaking's host is player 0 on both devices.
    expect(hostGame.myPlayerIndex, 0);
    expect(guestGame.myPlayerIndex, 1);
    expect(hostGame.canHumanAct, true, reason: 'host opens');
    expect(guestGame.canHumanAct, false, reason: 'guest waits its turn');

    // The host fires; the shot has to cross the internet and land on the
    // guest's simulation.
    hostGame.aimAngle = 45;
    hostGame.aimPower = 70;
    hostGame.humanFire();
    expect(hostGame.phase, GamePhase.firing);

    await _until(() => guestGame.phase != GamePhase.aiming,
        reason: 'the guest never saw the shot');
    expect(guestGame.aimPower, closeTo(70, 0.001));
    expect(guestGame.aimAngle, closeTo(45, 0.001));

    // Chat rides the same channel.
    hostNet.sendChat('hello from the host');
    await _until(() => guestNet.chat.any((c) => c.text == 'hello from the host'));
    final heard = guestNet.chat.firstWhere((c) => c.text == 'hello from the host');
    expect(heard.mine, false);
    expect(heard.name, 'LiveHost');

    hostGame.dispose();
    guestGame.dispose();
    await hostNet.close();
    await guestNet.close();
    await hostApi.call('match_end', args: {'matchId': matchId});
    hostApi.close();
    guestApi.close();
    expect(guestId, isPositive);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a killed app rejoins where it left off, without replaying the match',
      () async {
    final (hostApi, _) = await signUp('ResumeHost');
    final (guestApi, _) = await signUp('ResumeGuest');

    await hostApi.call('queue_join');
    final paired = await guestApi.call('queue_join');
    final matchId = ((paired['match'] as Map)['id'] as num).toInt();
    await hostApi.call('accept_match', args: {'matchId': matchId});
    await guestApi.call('accept_match', args: {'matchId': matchId});

    // --- play a little, then "close the app" -----------------------------
    final guestNet = NetService.forTest();
    await guestNet.startRelayMatch(
        api: guestApi, matchId: matchId, asHost: false, playerName: 'ResumeGuest');

    final hostNet = NetService.forTest();
    await hostNet.startRelayMatch(
        api: hostApi, matchId: matchId, asHost: true, playerName: 'ResumeHost');

    // The host takes a shot, so there is real history on the server.
    hostNet.send({'t': 'fire', 'a': 45.0, 'p': 70.0, 'w': 'tennis', 'pl': 0});
    hostNet.sendChat('opening shot');

    // The guest reads it, which is what advances its relay cursor past
    // those lines.
    await _until(() => guestNet.chat.any((c) => c.text == 'opening shot'),
        reason: 'the guest never received the history it must not replay');
    final cursor = guestNet.relaySince;
    expect(cursor, greaterThan(0), reason: 'the cursor has to have moved');

    // The guest's device is killed mid-match.
    await guestNet.close();

    // --- relaunch and resume ---------------------------------------------
    final resumedNet = NetService.forTest();
    final replayed = <Map<String, dynamic>>[];
    expect(
      await resumedNet.startRelayMatch(
        api: guestApi,
        matchId: matchId,
        asHost: false,
        playerName: 'ResumeGuest',
        since: cursor,
      ),
      true,
    );
    resumedNet.onMessage = replayed.add;

    // Give the poll loop several cycles to hand back anything it is going to.
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(replayed.where((m) => m['t'] == 'fire'), isEmpty,
        reason: 'resuming at the saved cursor must not re-fire old shots');
    expect(resumedNet.chat.where((c) => c.text == 'opening shot'), isEmpty,
        reason: 'nor replay old chat');

    // And the link is genuinely live: a NEW line still arrives.
    hostNet.sendChat('still here?');
    await _until(() => resumedNet.chat.any((c) => c.text == 'still here?'),
        reason: 'the resumed link should carry new traffic');

    await hostNet.close();
    await resumedNet.close();
    await hostApi.call('match_end', args: {'matchId': matchId});
    hostApi.close();
    guestApi.close();
  }, timeout: const Timeout(Duration(seconds: 90)));
}

/// Polls [cond] until it holds or the deadline passes.
Future<void> _until(
  bool Function() cond, {
  Duration limit = const Duration(seconds: 25),
  String? reason,
}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  fail(reason ?? 'timed out waiting for the relay');
}
