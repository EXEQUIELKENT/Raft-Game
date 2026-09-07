import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'controller.dart';
import 'net.dart';

/// A battle in progress, kept on disk so closing the app does not forfeit it.
///
/// Both transports are stored, but they resume by quite different routes and
/// the snapshot carries what each of them needs.
///
/// **Online** resumes through the server. The relay holds the match open and
/// keeps its message history, so a returning player rebuilds the world,
/// re-applies what had happened to it, and picks the conversation back up
/// from [relaySince].
///
/// **Hotspot** has no server to hold anything. The socket died with the app,
/// and every message sent while a device was away is gone. So it resumes by
/// rendezvous plus reconciliation: [roomCode] re-opens the same room and
/// [hostAddress] dials back into it, and once the two devices are talking
/// again they compare accounts of the match and both adopt the further-on one
/// (see [ResumeOffer]). That is why a hotspot snapshot has to record which
/// side of the connection this device was on — [iAmHost] decides whether it
/// re-hosts or re-joins.
class MatchSnapshot {
  /// The `start` payload the match was built from. Replaying it rebuilds a
  /// byte-identical world, which is the whole reason a lockstep game can be
  /// resumed from so little (see [GameController.snapshotState]).
  final Map<String, dynamic> start;

  /// What had happened to that world by the time we were last playing.
  final Map<String, dynamic> state;

  final int matchId;
  final bool iAmHost;

  /// How far through the relay's history this device had already read.
  /// Resuming at 0 would replay every shot of the match.
  final int relaySince;

  final String peerName;
  final DateTime savedAt;

  /// Which transport was carrying the match, and so how it is resumed.
  final NetMode transport;

  /// Hotspot only: the room to re-open (host) or look for (guest).
  final String roomCode;

  /// Hotspot only, and only on a guest: the address to dial back.
  final String hostAddress;

  /// How far the local simulation had got. The two devices compare this on
  /// reconnect to decide whose state to carry on from.
  final int turnSeq;

  const MatchSnapshot({
    required this.start,
    required this.state,
    required this.matchId,
    required this.iAmHost,
    required this.relaySince,
    required this.peerName,
    required this.savedAt,
    this.transport = NetMode.online,
    this.roomCode = '',
    this.hostAddress = '',
    this.turnSeq = 0,
  });

  bool get isHotspot => transport == NetMode.hotspot;

  /// Identifies the match to the peer. Room plus seed: the room alone repeats
  /// across sessions (a host that re-opens the same code), and the seed alone
  /// says nothing about which pair of devices agreed on it.
  String get matchKey => '$roomCode:${start['seed']}';

  Map<String, dynamic> toJson() => {
        'start': start,
        'state': state,
        'matchId': matchId,
        'iAmHost': iAmHost,
        'relaySince': relaySince,
        'peerName': peerName,
        'savedAt': savedAt.toIso8601String(),
        'transport': transport.name,
        'roomCode': roomCode,
        'hostAddress': hostAddress,
        'turnSeq': turnSeq,
      };

  static MatchSnapshot? fromJson(Map<String, dynamic> j) {
    final start = j['start'];
    final state = j['state'];
    if (start is! Map || state is! Map) return null;
    // Before hotspot could be resumed every snapshot was an online one, so a
    // missing transport means online — and an online match with no id cannot
    // be rejoined at all.
    final transport = NetMode.values.firstWhere(
      (m) => m.name == j['transport'],
      orElse: () => NetMode.online,
    );
    final matchId = (j['matchId'] as num?)?.toInt();
    if (transport == NetMode.online && matchId == null) return null;
    return MatchSnapshot(
      start: Map<String, dynamic>.from(start),
      state: Map<String, dynamic>.from(state),
      matchId: matchId ?? 0,
      iAmHost: j['iAmHost'] == true,
      relaySince: (j['relaySince'] as num?)?.toInt() ?? 0,
      peerName: (j['peerName'] as String?) ?? 'Opponent',
      savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      transport: transport,
      roomCode: (j['roomCode'] as String?) ?? '',
      hostAddress: (j['hostAddress'] as String?) ?? '',
      turnSeq: (j['turnSeq'] as num?)?.toInt() ?? 0,
    );
  }

  /// This device's account of the match, for the reconnect handshake.
  ResumeOffer get offer =>
      ResumeOffer(key: matchKey, seq: turnSeq, state: state);
}

/// Persists the match in progress, and hands it back on the next launch.
///
/// Saving is driven off turn changes rather than every frame: a turn is the
/// only thing that actually alters what a resume needs, and the battle runs
/// its listener at 60Hz.
class MatchStore {
  MatchStore._();
  static final MatchStore instance = MatchStore._();

  static const _key = 'raft_match_saved_v1';

  /// How long a saved online match stays offerable. The server sweeps
  /// finished matches on its own schedule; past this the odds the opponent
  /// is still waiting are slim enough that offering it wastes the player's
  /// time.
  static const Duration staleAfter = Duration(hours: 12);

  /// Hotspot matches go stale far sooner. Resuming one needs both devices
  /// back on the same network with the host's address unchanged — a
  /// condition that survives a crash and a relaunch, but not an afternoon.
  /// Offering a twelve-hour-old LAN match would mostly just spend a minute
  /// of the player's time dialling an address nobody is listening on.
  static const Duration hotspotStaleAfter = Duration(minutes: 45);

  SharedPreferences? _prefs;
  MatchSnapshot? _saved;

  GameController? _ctrl;
  NetService? _net;
  Map<String, dynamic>? _start;
  int _lastTurn = -1;

  /// The match waiting to be resumed, or null if there is none or it has
  /// gone stale.
  MatchSnapshot? get saved {
    final s = _saved;
    if (s == null) return null;
    final limit = s.isHotspot ? hotspotStaleAfter : staleAfter;
    if (DateTime.now().difference(s.savedAt) > limit) return null;
    return s;
  }

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs?.getString(_key);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _saved = MatchSnapshot.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      // A corrupt entry must not stop the app opening; the worst case is
      // one un-resumable match.
      if (kDebugMode) debugPrint('MatchStore: load failed ($e)');
    }
  }

  Future<void> clear() async {
    _saved = null;
    try {
      await _prefs?.remove(_key);
    } catch (_) {}
  }

  /// Starts tracking [controller]. [start] is the payload the match was
  /// built from — see [MatchSnapshot.start].
  void attach(
    GameController controller,
    NetService net, {
    required Map<String, dynamic> start,
  }) {
    detach();
    if (net.mode == NetMode.none) return;
    // An online match is rejoined by id; without one there is nothing to
    // rejoin. A hotspot match is rejoined by room, and the code is settled by
    // the handshake, so by the time a match is running both sides have it.
    if (net.mode == NetMode.online && net.relayMatchId == null) return;
    if (net.mode == NetMode.hotspot && net.roomCode.isEmpty) return;
    _ctrl = controller;
    _net = net;
    _start = start;
    _lastTurn = -1;
    // A returning peer can knock at any moment — including while this device
    // is still sitting in the battle, which is the ordinary case when only
    // one of the two apps died. Answering it here means the survivor never
    // has to leave the match screen to let the other player back in.
    net.onResumeAgreed = (state) {
      final c = _ctrl;
      if (c == null || c.phase == GamePhase.gameOver) return;
      c.restoreState(state);
    };
    controller.addListener(_onTick);
    _onTick();
  }

  void detach() {
    _ctrl?.removeListener(_onTick);
    _net?.onResumeAgreed = null;
    _ctrl = null;
    _net = null;
    _start = null;
  }

  void _onTick() {
    final ctrl = _ctrl;
    final net = _net;
    if (ctrl == null || net == null) return;

    // A finished match is not something to come back to. Dropping the offer
    // too, so the peer's link dying on the results screen is read as the
    // match ending rather than as somebody to wait around for.
    if (ctrl.phase == GamePhase.gameOver) {
      net.cancelResume();
      unawaited(clear());
      detach();
      return;
    }

    // One write per turn. `round` alone is too coarse (it only advances when
    // play comes back round to the first seat), so the seat is part of the
    // key too.
    final turn = ctrl.round * 100 + ctrl.currentPlayer;
    if (turn == _lastTurn) return;
    _lastTurn = turn;
    unawaited(_write());
  }

  Future<void> _write() async {
    final ctrl = _ctrl;
    final net = _net;
    final start = _start;
    if (ctrl == null || net == null || start == null) return;
    final matchId = net.relayMatchId;
    if (net.mode == NetMode.online && matchId == null) return;

    final snap = MatchSnapshot(
      start: start,
      state: ctrl.snapshotState(),
      matchId: matchId ?? 0,
      iAmHost: net.isHost,
      relaySince: net.relaySince,
      peerName: net.peerName,
      savedAt: DateTime.now(),
      transport: net.mode,
      roomCode: net.roomCode,
      hostAddress: net.joinedHostAddress,
      turnSeq: ctrl.turnSeq,
    );
    _saved = snap;
    // Kept in step with the save so a peer that reconnects *now* is answered
    // with what we would have resumed from ourselves — the survivor and the
    // returning player must reconcile against the same account.
    if (net.mode == NetMode.hotspot) net.resumeOffer = snap.offer;
    try {
      await _prefs?.setString(_key, jsonEncode(snap.toJson()));
    } catch (e) {
      if (kDebugMode) debugPrint('MatchStore: save failed ($e)');
    }
  }

  /// Writes immediately, for the moment the app is being backgrounded.
  Future<void> flushNow() => _write();
}
