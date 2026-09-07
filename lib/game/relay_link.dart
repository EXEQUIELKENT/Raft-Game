import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'net.dart';
import 'online_api.dart';

/// Carries the game's match protocol over the internet, through the
/// online server's relay endpoints.
///
/// This is the *only* thing internet play adds to the game itself. A
/// hotspot match writes JSON lines into a TCP socket; an online match
/// posts the identical lines to `relay_send` and reads the opponent's
/// back from `relay_poll`. Because both are [GameLink]s, everything
/// above — the lobby handshake, the match start, firing, turn changes,
/// chat and the rematch — runs unchanged and unaware of which one it is
/// using.
///
/// Two details make that hold up in practice:
///
///  * **Ordering.** Outgoing lines go through a queue flushed by a single
///    worker, so two `send`s in the same frame can never race each other
///    onto the wire out of order. The server hands them back in insert
///    order, which is the same guarantee a socket gives.
///
///  * **Liveness.** A socket tells you the instant the other end goes
///    away; HTTP does not. The server reports how long ago the opponent
///    last spoke to it instead, and since both players poll continuously
///    while a match is running, a few seconds of silence already means
///    something is wrong — see [peerSilenceLimit].
class RelayLink implements GameLink {
  final OnlineApi api;
  final int matchId;

  /// Fired once when the relay stops carrying this match at all — the
  /// match was ended server-side, our own connection failed repeatedly,
  /// or [close] was called. Mirrors `SocketLink.onClosed`.
  final void Function()? onClosed;

  /// Fired when the opponent's presence changes: false once they have
  /// been silent past [peerSilenceLimit], true again when they come
  /// back.
  ///
  /// This is the part a socket gets for free and HTTP does not, and the
  /// reason it is a separate callback rather than just closing the link:
  /// the opponent vanishing must NOT tear down our own channel, because
  /// that channel is exactly how we find out they have returned. Their
  /// rejoining `hello` arrives on the connection we kept open, and the
  /// ordinary reconnect path handles it from there — so a dropped
  /// internet match recovers the same way a dropped hotspot one does.
  final void Function(bool peerPresent)? onPeerPresence;

  final _in = StreamController<Map<String, dynamic>>.broadcast();
  final List<String> _outbox = [];

  bool _closed = false;
  bool _flushing = false;
  int _since;

  /// How far into the match's message history this link has already
  /// polled. Exposed so `MatchStore` can persist it: without a starting
  /// point to resume from, a freshly built `RelayLink` after a cold
  /// restart always begins at 0 and replays the ENTIRE match history —
  /// up to the 200 rows `relay_poll` returns per call — duplicating every
  /// chat line and re-delivering a possibly-stale `resume` on top of
  /// whatever the reconnect flow already sent.
  int get since => _since;

  /// How long the opponent may go without touching the server before we
  /// call it a disconnection. Both ends re-poll the moment a poll returns
  /// (and a poll returns at least every `poll_hold_seconds`, which the
  /// server keeps at 8), so this is several missed cycles rather than a
  /// hair trigger — but still far quicker than the 35-second window the
  /// friends list uses to decide somebody is offline.
  static const Duration defaultPeerSilenceLimit = Duration(seconds: 22);

  /// This link's own limit. Overridable so a test can exercise the
  /// drop-and-return path without sitting through 22 seconds of real time —
  /// the rule is measured against the wall clock, deliberately, because it
  /// is about how long the opponent has actually been quiet.
  final Duration peerSilenceLimit;

  RelayLink({
    required this.api,
    required this.matchId,
    this.onClosed,
    this.onPeerPresence,
    int since = 0,
    this.peerSilenceLimit = defaultPeerSilenceLimit,
  })  : _since = since {
    unawaited(_pollLoop());
  }

  @override
  Stream<Map<String, dynamic>> get messages => _in.stream;

  @override
  void send(Map<String, dynamic> msg) {
    if (_closed) return;
    _outbox.add(jsonEncode(msg));
    unawaited(_flush());
  }

  /// Drains the outbox one request at a time. The `_flushing` guard is
  /// what keeps ordering: a second `send` arriving mid-request appends to
  /// the outbox and lets the worker already in flight carry it, instead
  /// of starting a competing request that might land first.
  Future<void> _flush() async {
    if (_flushing || _closed) return;
    _flushing = true;
    try {
      while (_outbox.isNotEmpty && !_closed) {
        final batch = List<String>.from(_outbox);
        _outbox.clear();
        try {
          await api.call('relay_send', args: {
            'matchId': matchId,
            'lines': batch,
          });
        } on OnlineError catch (e) {
          // A transient network blip must not silently drop a shot, so
          // the batch goes back to the FRONT of the queue and the poll
          // loop's own failure counter decides when to give up on the
          // connection entirely.
          _outbox.insertAll(0, batch);
          if (kDebugMode) debugPrint('RelayLink: send failed ($e)');
          await Future<void>.delayed(const Duration(milliseconds: 600));
          if (_closed) return;
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _pollLoop() async {
    var consecutiveFailures = 0;
    var peerPresent = true;
    DateTime lastHeardFromPeer = DateTime.now();

    while (!_closed) {
      try {
        final res = await api.call(
          'relay_poll',
          args: {'matchId': matchId, 'since': _since},
          // Must outlast the server's own hold, or every quiet poll would
          // look like a timeout.
          timeout: const Duration(seconds: 20),
        );
        consecutiveFailures = 0;

        _since = (res['seq'] as num?)?.toInt() ?? _since;
        for (final line in (res['lines'] as List? ?? const [])) {
          if (line is! String) continue;
          try {
            _in.add(Map<String, dynamic>.from(jsonDecode(line) as Map));
          } catch (_) {/* ignore malformed */}
        }

        final peerAgo = (res['peerAgo'] as num?)?.toInt();
        if (peerAgo != null && peerAgo <= peerSilenceLimit.inSeconds) {
          lastHeardFromPeer = DateTime.now();
        }
        final nowPresent =
            DateTime.now().difference(lastHeardFromPeer) <= peerSilenceLimit;
        if (nowPresent != peerPresent) {
          peerPresent = nowPresent;
          onPeerPresence?.call(nowPresent);
        }

        // The server marking the match done is the one genuinely
        // terminal case — the opponent left for good, so there is
        // nothing left to carry.
        if (res['status'] == 'done') {
          await close();
          return;
        }
      } on OnlineError catch (e) {
        consecutiveFailures++;
        if (kDebugMode) debugPrint('RelayLink: poll failed ($e)');
        // Our OWN connection is the problem here, not the opponent's.
        // A handful of retries rides out a lift or a wifi handover; past
        // that, the match is no longer being carried and pretending
        // otherwise just leaves the player firing into nothing.
        if (consecutiveFailures >= 5) {
          await close();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_in.isClosed) await _in.close();
    onClosed?.call();
  }
}
