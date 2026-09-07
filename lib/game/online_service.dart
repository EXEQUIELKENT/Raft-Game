import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'online_api.dart';
import 'server_discovery.dart';

import 'save.dart';

/// Another captain, as the online server knows them.
///
/// The server keeps the fields every title shares (id, tag, name,
/// presence, wins/losses) in columns of its own, and each game's extra
/// stats in a free-form `profile` blob — see `sync` in `server/api.php`.
/// Raft's half of that is its level, doubloons and the raft they sail.
class OnlinePlayer {
  final int id;
  final String tag;
  final String name;
  final int wins;
  final int losses;
  final int level;
  final int doubloons;

  /// The raft they show up in, so a friends list can preview it.
  final String raftHullId;
  final int raftColorIndex;

  final bool online;

  /// Seconds since they last touched the server, or null if unknown.
  /// Drives the "LAST SEEN 4M AGO" line for offline friends.
  final int? lastSeenAgo;

  const OnlinePlayer({
    required this.id,
    required this.tag,
    required this.name,
    required this.wins,
    required this.losses,
    required this.level,
    required this.doubloons,
    required this.raftHullId,
    required this.raftColorIndex,
    required this.online,
    required this.lastSeenAgo,
  });

  factory OnlinePlayer.fromJson(Map<String, dynamic> j) {
    final profile = j['profile'] is Map
        ? Map<String, dynamic>.from(j['profile'] as Map)
        : const <String, dynamic>{};
    return OnlinePlayer(
      id: (j['id'] as num?)?.toInt() ?? 0,
      tag: (j['tag'] as String?) ?? '------',
      name: (j['name'] as String?) ?? 'Captain',
      wins: (j['wins'] as num?)?.toInt() ?? 0,
      losses: (j['losses'] as num?)?.toInt() ?? 0,
      level: (profile['level'] as num?)?.toInt() ?? 1,
      doubloons: (profile['doubloons'] as num?)?.toInt() ?? 0,
      raftHullId: (profile['hull'] as String?) ?? 'tube',
      raftColorIndex: (profile['color'] as num?)?.toInt() ?? 0,
      online: j['online'] == true,
      lastSeenAgo: (j['lastSeenAgo'] as num?)?.toInt(),
    );
  }

  int get played => wins + losses;

  /// Win rate as a whole percentage, or null before they've played.
  int? get winRate => played == 0 ? null : ((wins * 100) / played).round();

  /// "ONLINE NOW" / "LAST SEEN 4M AGO" / "OFFLINE".
  String get presenceLabel {
    if (online) return 'ONLINE NOW';
    final ago = lastSeenAgo;
    if (ago == null) return 'OFFLINE';
    if (ago < 3600) return 'LAST SEEN ${(ago / 60).floor()}M AGO';
    if (ago < 86400) return 'LAST SEEN ${(ago / 3600).floor()}H AGO';
    return 'LAST SEEN ${(ago / 86400).floor()}D AGO';
  }
}

/// A match this player is part of, as far as the server is concerned.
class OnlineMatch {
  final int id;

  /// `inviting` — a friend has been invited and hasn't answered yet.
  /// `found`    — matchmaking paired two searchers; BOTH must accept.
  /// `active`   — both sides are in; the relay is carrying the game.
  final String status;
  final bool youAreHost;
  final int peerId;
  final String peerName;

  /// For a matchmaking pairing (`found`): whether each captain has tapped
  /// accept. The match only goes live on the second yes.
  final bool youAccepted;
  final bool peerAccepted;

  const OnlineMatch({
    required this.id,
    required this.status,
    required this.youAreHost,
    required this.peerId,
    required this.peerName,
    this.youAccepted = false,
    this.peerAccepted = false,
  });

  factory OnlineMatch.fromJson(Map<String, dynamic> j) => OnlineMatch(
        id: (j['id'] as num?)?.toInt() ?? 0,
        status: (j['status'] as String?) ?? 'done',
        youAreHost: j['youAreHost'] == true,
        peerId: (j['peerId'] as num?)?.toInt() ?? 0,
        peerName: (j['peerName'] as String?) ?? 'Opponent',
        youAccepted: j['youAccepted'] == true,
        peerAccepted: j['peerAccepted'] == true,
      );

  bool get isInvitation => status == 'inviting';
  bool get isActive => status == 'active';
  bool get isFound => status == 'found';

  /// An invitation waiting for THIS player to answer.
  bool get isIncomingInvite => isInvitation && !youAreHost;

  /// An invitation this player sent that hasn't been answered.
  bool get isOutgoingInvite => isInvitation && youAreHost;
}

/// One finished online match, kept on this device so the ONLINE tab can
/// show "who did I just play" — a captain's log of recent opponents,
/// win/loss and RP, with a way to add a stranger met through matchmaking
/// as a friend before their name is forgotten.
///
/// Deliberately local-only, the same way [SaveData.wins]/[SaveData.losses]
/// are: the server is the post box for the match itself, not a system of
/// record for history, so there is nothing to fetch and nothing that can
/// disagree with what this device saw happen.
class MatchHistoryEntry {
  /// The opponent's server-side player id — what [OnlineService.requestById]
  /// needs to send them a friend request.
  final int opponentId;
  final String opponentName;
  final bool won;

  /// RP change from this result. Can be 0 if RP was somehow not awarded.
  final int xpDelta;
  final DateTime when;

  const MatchHistoryEntry({
    required this.opponentId,
    required this.opponentName,
    required this.won,
    required this.xpDelta,
    required this.when,
  });

  Map<String, dynamic> toJson() => {
        'opponentId': opponentId,
        'opponentName': opponentName,
        'won': won,
        'xpDelta': xpDelta,
        'when': when.toIso8601String(),
      };

  factory MatchHistoryEntry.fromJson(Map<String, dynamic> j) =>
      MatchHistoryEntry(
        opponentId: (j['opponentId'] as num?)?.toInt() ?? 0,
        opponentName: (j['opponentName'] as String?) ?? 'Captain',
        won: j['won'] == true,
        xpDelta: (j['xpDelta'] as num?)?.toInt() ?? 0,
        when: DateTime.tryParse((j['when'] as String?) ?? '') ??
            DateTime.now(),
      );
}

/// Accounts, friends, presence and invitations for internet play.
///
/// Deliberately separate from `NetworkService`, which owns the match
/// itself. This class gets two players as far as "we have agreed to
/// play"; from there `NetworkService` takes over with a `RelayLink` and
/// runs the identical match protocol hotspot play uses.
///
/// There are no usernames or passwords: the app registers itself once and
/// keeps the token it is given. That means a player's account lives on
/// the install — which suits a game whose profile, RP and purchases are
/// already local-only — and their friend code is how anyone else finds
/// them.
class OnlineService extends ChangeNotifier {
  static const _kBaseUrl = 'online.baseUrl';
  static const _kToken = 'online.token';
  static const _kTag = 'online.tag';
  static const _kId = 'online.id';
  static const _kHistory = 'online.history';

  /// How many recent matches the captain's log keeps. Old enough entries
  /// just fall off the end — this is a recap, not permanent record
  /// keeping (the server-side `wins`/`losses` counters are that).
  static const _maxHistory = 25;

  /// How long the server holds a matchmaking pairing before releasing both
  /// captains back into the queue — `pair_hold_seconds` in
  /// `server/config.php`, mirrored here so the accept prompt can show the
  /// time actually left instead of an open-ended "waiting…".
  ///
  /// The client has no server clock to read, so it counts from the moment
  /// it FIRST SAW the pairing, which can be up to one poll behind the
  /// server's own start. That makes the number shown slightly pessimistic
  /// — the safe direction for a deadline, since it can only ever hurry a
  /// captain rather than promise them time they don't have.
  static const Duration pairHold = Duration(seconds: 30);

  final OnlineApi api = OnlineApi();

  SharedPreferences? _prefs;

  int myId = 0;
  String myTag = '';

  /// This player's captain name as the server knows it — the thing other
  /// people search for to add them.
  String myName = '';

  List<OnlinePlayer> friends = const [];
  List<OnlinePlayer> incomingRequests = const [];
  List<OnlinePlayer> outgoingRequests = const [];
  OnlineMatch? match;

  /// Recent finished online matches, most recent first. See
  /// [MatchHistoryEntry] for why this lives on the device instead of the
  /// server.
  List<MatchHistoryEntry> history = const [];

  /// The opponent of the match currently being played — captured at
  /// [noteMatchStarted] time, since by the time the match ends `match`
  /// itself has long gone stale (polling stops the moment a battle
  /// starts; see [noteMatchStarted]'s own doc). Consumed and cleared by
  /// [recordMatchResult].
  int? _activeOpponentId;
  String? _activeOpponentName;

  /// True while this player is standing in the find-a-match queue. The
  /// matchmaking screen reads it to tell "still searching" apart from
  /// "paired, waiting on accepts" and from "released, re-searching".
  bool searching = false;

  /// Last thing that went wrong, ready to show. Cleared by the next
  /// successful call.
  String? lastError;

  /// True once a call has actually succeeded, so the UI can tell "not set
  /// up yet" apart from "set up but unreachable".
  bool reachable = false;
  bool busy = false;

  Timer? _heartbeat;

  bool get configured => api.configured;
  bool get signedIn => configured && (api.token ?? '').isNotEmpty;
  String get baseUrl => api.baseUrl;

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // Same reasoning as `_loadHistory`/`SaveService.load` below and
      // above it in the stack: a corrupt on-disk preferences file must
      // not stop the app from opening. `_prefs` stays null; `_persist`
      // already no-ops without one.
      _prefs = null;
    }
    final p = _prefs;
    if (p == null) {
      notifyListeners();
      return;
    }
    api.baseUrl = p.getString(_kBaseUrl) ?? '';
    api.token = p.getString(_kToken);
    myTag = p.getString(_kTag) ?? '';
    myId = p.getInt(_kId) ?? 0;
    history = _loadHistory(p);
    notifyListeners();
  }

  List<MatchHistoryEntry> _loadHistory(SharedPreferences p) {
    final raw = p.getString(_kHistory);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => MatchHistoryEntry.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      // A future version wrote a shape this one doesn't understand, or
      // the value is simply corrupt — an empty log beats crashing on
      // startup over what is, worst case, a cosmetic feature.
      return const [];
    }
  }

  Future<void> _persist() async {
    final p = _prefs;
    if (p == null) return;
    await p.setString(_kBaseUrl, api.baseUrl);
    await p.setString(_kToken, api.token ?? '');
    await p.setString(_kTag, myTag);
    await p.setInt(_kId, myId);
  }

  /// Points the app at a server. Changing the address invalidates the
  /// account with it: the token was issued by the OLD server and means
  /// nothing to the new one, so keeping it would just produce confusing
  /// "not signed in" errors on every call.
  Future<void> setBaseUrl(String url) async {
    final next = url.trim();
    if (next == api.baseUrl) return;
    api.baseUrl = next;
    api.token = null;
    myTag = '';
    myId = 0;
    reachable = false;
    friends = const [];
    incomingRequests = const [];
    outgoingRequests = const [];
    match = null;
    searching = false;
    // Opponent ids in the log are only meaningful against the server
    // that issued them — a different server's player #7 is somebody
    // else entirely, so carrying the log over would risk the ADD button
    // friending the wrong captain.
    history = const [];
    _activeOpponentId = null;
    _activeOpponentName = null;
    final p = _prefs;
    if (p != null) await p.remove(_kHistory);
    await _persist();
    notifyListeners();
  }

  /// The message shown when the device is simply offline — distinct from
  /// "server unreachable", because the fix (turn on data) is different.
  static const _offlineMessage = 'You need an internet connection to '
      'play online. Turn on Wi-Fi or mobile data and try again.';

  /// Finds the game server on its own — nobody types an address — and
  /// signs in against whatever it finds.
  ///
  /// Order: the address remembered from last time (fast path: an
  /// unchanged network answers in one ping), then localhost and the
  /// Android-emulator host, then a sweep of this device's Wi-Fi subnet.
  /// Only a machine speaking this game's exact protocol is accepted, so
  /// random web servers on the LAN are ignored.
  ///
  /// A release build carries its server's address inside the binary, so
  /// it needs real internet: with none, it fails here in one DNS check
  /// instead of sweeping, and the player is told exactly that.
  Future<bool> connectAuto(SaveData profile) async {
    busy = true;
    notifyListeners();
    final discovery = ServerDiscovery();

    // Release builds point at one far-away machine; without a route to
    // it there is nothing to find. Dev builds may still legitimately
    // reach a LAN-only XAMPP box with the router's internet down, so
    // they fall through and let discovery try.
    if (ServerDiscovery.bakedUrl.trim().isNotEmpty &&
        !await discovery.hasInternet()) {
      busy = false;
      reachable = false;
      lastError = _offlineMessage;
      notifyListeners();
      return false;
    }

    String? found;
    try {
      found = await discovery.discover(
        known: configured ? api.baseUrl : null,
      );
    } catch (_) {}
    if (found == null) {
      busy = false;
      reachable = false;
      lastError = await discovery.hasInternet()
          ? 'No game server found on this Wi-Fi. Ask whoever is hosting '
              'for its address and enter it below, or start '
              'server/api.php yourself and rejoin the same network.'
          : _offlineMessage;
      notifyListeners();
      return false;
    }
    if (found != api.baseUrl.trim()) {
      // A different machine than last time. The old token means nothing
      // to the new server, so setBaseUrl drops it along with everything
      // that came from the old session.
      await setBaseUrl(found);
    }
    return ensureAccount(profile);
  }

  /// Registers this installation if it has no account yet, then pushes
  /// the current local profile up. Safe to call every time the online
  /// screen opens.
  Future<bool> ensureAccount(SaveData profile) async {
    if (!configured) {
      lastError = 'Enter the game server address first.';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      if ((api.token ?? '').isEmpty) await _register(profile);

      // The saved token can be stale in ways that are nobody's fault: the
      // server's database was reset, the account was removed, or this
      // address is a different server than the one that issued it. All of
      // those come back as "not signed in", and all of them are fixed by
      // registering again rather than by showing the player an error
      // about a token they never knew they had.
      try {
        await api.call('poll');
      } on OnlineError catch (e) {
        if (!e.needsSignIn) rethrow;
        api.token = null;
        await _register(profile);
      }

      await syncProfile(profile);
      await refresh();
      reachable = true;
      lastError = null;
      return true;
    } on OnlineError catch (e) {
      lastError = e.offline ? _offlineMessage : e.message;
      reachable = false;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _register(SaveData profile) async {
    final res = await api.call(
      'register',
      args: {'name': profile.playerName},
      authed: false,
    );
    api.token = res['token'] as String?;
    myTag = (res['tag'] as String?) ?? '';
    myId = (res['id'] as num?)?.toInt() ?? 0;
    await _persist();
  }

  /// Mirrors the local profile up so friends see current stats and the
  /// right loadout. The device stays the authority — this is a copy for
  /// other people to read, not a score being submitted.
  ///
  /// Called from every online entry point AND right after a rename on the
  /// main menu, so the server never keeps showing a name the player
  /// already changed. On success the local display name updates too —
  /// instant feedback, no waiting for the next poll to echo it back.
  Future<void> syncProfile(SaveData profile) async {
    if (!signedIn) return;
    try {
      await api.call('sync', args: {
        'name': profile.playerName,
        'wins': profile.wins,
        'losses': profile.losses,
        // Raft's own half of the profile. The backend serves several
        // titles, so anything not common to all of them travels in this
        // free-form blob rather than as columns of its own — see `sync`
        // in server/api.php.
        'profile': {
          'level': profile.level,
          'doubloons': profile.doubloons,
          'hull': profile.raftHullId,
          'color': profile.raftColorIndex,
        },
      });
      if (myName != profile.playerName) {
        myName = profile.playerName;
        notifyListeners();
      }
    } on OnlineError catch (e) {
      if (kDebugMode) debugPrint('OnlineService: sync failed ($e)');
    }
  }

  /// The fingerprint the server handed back with the last successful
  /// [refresh] — sent as `sinceHash` on the next long-polling call so it
  /// knows what "nothing new" means for THIS player. Reset whenever a
  /// plain (non-waiting) refresh runs, since that already has fresh data
  /// and there is nothing to compare against a stale hash for.
  String? _stateHash;

  /// One request that returns everything the friends screen shows AND
  /// keeps this player marked online — presence costs no extra traffic
  /// because any request at all counts as "I am here".
  ///
  /// [wait] asks the server to hold the connection and only answer once
  /// something matchmaking-relevant has actually changed (or a few
  /// seconds pass), the way [RelayLink]'s poll already does for a live
  /// match — see `poll`'s own doc in `server/api.php`. Only the fast
  /// matchmaking heartbeat below sets it; the plain friends-screen pace
  /// stays a quick, immediate read, since holding a connection open just
  /// to watch an idle friends list has nothing to buy.
  ///
  /// Returns whether the call actually reached the server, so the fast
  /// heartbeat loop knows whether to back off before trying again.
  Future<bool> refresh({bool wait = false}) async {
    if (!signedIn) return false;
    var ok = true;
    try {
      final hash = _stateHash;
      final res = await api.call(
        'poll',
        args: wait
            ? {'wait': true, if (hash != null) 'sinceHash': hash}
            : const {},
        // The server's own hold is `lobby_poll_hold_seconds` (4s by
        // default); this must comfortably outlast that; the plain call
        // keeps the shorter default timeout.
        timeout: wait ? const Duration(seconds: 9) : const Duration(seconds: 12),
      );
      friends = _players(res['friends']);
      incomingRequests = _players(res['incoming']);
      outgoingRequests = _players(res['outgoing']);
      searching = res['searching'] == true;
      final m = res['match'];
      match = m is Map
          ? OnlineMatch.fromJson(Map<String, dynamic>.from(m))
          : null;
      final me = res['me'];
      if (me is Map) {
        myTag = (me['tag'] as String?) ?? myTag;
        myName = (me['name'] as String?) ?? myName;
        myId = (me['id'] as num?)?.toInt() ?? myId;
      }
      _stateHash = res['stateHash'] as String?;
      reachable = true;
      lastError = null;
    } on OnlineError catch (e) {
      // Offline moments say it in the player's own words, everywhere:
      // entry, mid-search heartbeats, invites — one message, one fix.
      lastError = e.offline ? _offlineMessage : e.message;
      if (e.offline) reachable = false;
      ok = false;
    }
    notifyListeners();
    return ok;
  }

  List<OnlinePlayer> _players(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => OnlinePlayer.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Bumped on every [startHeartbeat]/[stopHeartbeat] so the fast-mode
  /// poll loop below knows to stop after the call it is currently
  /// awaiting returns, even though nothing can cancel an in-flight HTTP
  /// request directly.
  int _heartbeatGen = 0;

  /// Starts the presence heartbeat. Runs only while a screen that needs
  /// it is open — there is no reason to advertise as online from inside a
  /// single-player match against the AI.
  ///
  /// [fast] switches from a plain 5-second timer to a continuous long
  /// poll: while a matchmaking screen is up, "opponent accepted" should
  /// land in a blink, not on the next tick. That only works as a tight
  /// loop rather than its own fixed-interval timer — the request itself
  /// now blocks on the server for up to a few seconds when there is
  /// nothing new to report, so a 1.2s timer alongside it would just pile
  /// up overlapping calls.
  void startHeartbeat({bool fast = false}) {
    _heartbeat?.cancel();
    _heartbeat = null;
    _heartbeatGen++;
    if (!signedIn) return;
    _fastPolling = fast;
    if (fast) {
      _stateHash = null; // nothing to compare against yet on this pass
      unawaited(_fastLoop(_heartbeatGen));
    } else {
      unawaited(refresh());
      _heartbeat = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(refresh()),
      );
    }
  }

  /// Keeps re-issuing the long-polling [refresh] for as long as fast
  /// mode is still the current heartbeat. [gen] pins this loop to the
  /// [startHeartbeat]/[stopHeartbeat] call that started it — if either
  /// runs again meanwhile, `gen` no longer matches [_heartbeatGen] once
  /// the in-flight request returns, and this loop quietly stops instead
  /// of racing whatever heartbeat replaced it.
  Future<void> _fastLoop(int gen) async {
    while (_fastPolling && gen == _heartbeatGen) {
      final ok = await refresh(wait: true);
      if (!_fastPolling || gen != _heartbeatGen) return;
      // A failed call already means the connection is unhappy; re-firing
      // instantly would just hammer it. A healthy call, by contrast, is
      // safe to re-issue immediately — the server's own hold is what
      // paces those, not this loop.
      if (!ok) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
    }
  }

  /// Switches an already-running heartbeat between the normal friends
  /// pace and the matchmaking pace without dropping it.
  void setFastPolling(bool fast) {
    if (_fastPolling == fast) return;
    startHeartbeat(fast: fast);
  }

  bool _fastPolling = false;

  // ------------------------------------------------------- MATCHMAKING ---

  /// Puts this captain in the find-a-match queue. The server answers
  /// either "searching" or "paired with X — both of you now accept";
  /// [_act]'s refresh pulls whichever it is into [match]/[searching].
  Future<bool> joinQueue() => _act(() => api.call('queue_join'));

  /// Stops searching. If a pairing was already found but not yet fully
  /// accepted by both sides, this doubles as declining it.
  Future<bool> leaveQueue() => _act(
        () => api.call('queue_leave'),
      );

  /// Says yes to a found pairing. The second yes anywhere flips the match
  /// active, which is what sends both captains into the game.
  Future<bool> acceptMatch(int matchId) => _act(
        () => api.call('accept_match', args: {'matchId': matchId}),
      );

  void stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _fastPolling = false;
    // Lets a `_fastLoop` that's mid-`await` on the server's hold notice,
    // the moment it returns, that it's no longer the current heartbeat —
    // see `_fastLoop`'s own doc.
    _heartbeatGen++;
  }

  // ------------------------------------------------------------ FRIENDS ---

  /// Searches for captains to add. A query matches a player's NAME —
  /// prefix match, so "ken" finds Kent — or their friend code for anyone
  /// still swapping codes. Names are unique per player, which is what
  /// makes searching them a way to find exactly one person; if two
  /// players picked the same name anyway, both come back and the tag on
  /// each result tells them apart.
  Future<List<OnlinePlayer>> search(String q) async {
    try {
      final res = await api.call('find', args: {'q': q});
      lastError = null;
      return _players(res['players']);
    } on OnlineError catch (e) {
      lastError = e.message;
      notifyListeners();
      return const [];
    }
  }

  Future<bool> requestById(int playerId) => _act(
        () => api.call('request', args: {'playerId': playerId}),
      );

  Future<bool> respondToRequest(int playerId, bool accept) => _act(
        () => api.call(
            'respond', args: {'playerId': playerId, 'accept': accept}),
      );

  Future<bool> unfriend(int playerId) => _act(
        () => api.call('unfriend', args: {'playerId': playerId}),
      );

  // ------------------------------------------------------------ INVITES ---

  Future<bool> invite(int playerId) => _act(
        () => api.call('invite', args: {'playerId': playerId}),
      );

  Future<bool> respondToInvite(int matchId, bool accept) => _act(
        () => api.call(
            'invite_respond', args: {'matchId': matchId, 'accept': accept}),
      );

  /// The match currently being played, remembered independently of
  /// [match].
  ///
  /// [match] only exists as long as something is polling, and polling
  /// stops the moment a battle starts — so by the time the player leaves
  /// that battle the poll result is long stale. Holding the id here is
  /// what lets [endMatch] free the seat from any exit path, including the
  /// ones that unwind straight back to the main menu.
  int? _activeMatchId;

  /// [opponentId]/[opponentName] are who this match is against — captured
  /// here (rather than read back off [match] once the battle is over,
  /// which is stale by then, see above) purely so [recordMatchResult] has
  /// someone to attach the result to for the ONLINE tab's history.
  void noteMatchStarted(int matchId, {int? opponentId, String? opponentName}) {
    _activeMatchId = matchId;
    _activeOpponentId = opponentId;
    _activeOpponentName = opponentName;
  }

  bool get hasActiveMatch => _activeMatchId != null;

  /// Ends whatever match this player is in, on the server. Called when
  /// leaving a battle, and when cancelling an invitation — otherwise both
  /// players would keep being told they are "already in a battle".
  Future<void> endMatch() async {
    final id = _activeMatchId ?? match?.id;
    _activeMatchId = null;
    // The captured opponent belongs to this match session — cleared here,
    // when the player actually leaves it, rather than the first time a
    // result gets logged. A rematch reuses the SAME relay/matchId without
    // calling [noteMatchStarted] again (see its own doc), so clearing
    // eagerly would have made every result after the first one in a
    // rematch streak silently fail to log.
    _activeOpponentId = null;
    _activeOpponentName = null;
    if (id == null) return;
    try {
      await api.call('match_end', args: {'matchId': id});
    } on OnlineError catch (e) {
      if (kDebugMode) debugPrint('OnlineService: match_end failed ($e)');
    }
    match = null;
    notifyListeners();
  }

  /// Adds the just-finished online match to this device's captain's log
  /// — see [MatchHistoryEntry]. Called once per finished game from the
  /// result screen, for matches that actually reached a decided outcome
  /// (not one abandoned by a dropped opponent — see
  /// [GameController.abandonMatch], which deliberately records no result
  /// there either). Safe to call again after a rematch: the opponent
  /// captured by [noteMatchStarted] is only cleared in [endMatch], once
  /// the player actually leaves the match session, not here.
  ///
  /// A no-op if there's no captured opponent to attach the result to,
  /// which is the safe default rather than a bug to chase down: it just
  /// means this match didn't go through [noteMatchStarted] (a hotspot
  /// match, say, calling this by mistake).
  Future<void> recordMatchResult({
    required bool won,
    required int xpDelta,
  }) async {
    final opponentId = _activeOpponentId;
    final opponentName = _activeOpponentName;
    if (opponentId == null || opponentId == 0) return;

    final entry = MatchHistoryEntry(
      opponentId: opponentId,
      opponentName: opponentName ?? 'Captain',
      won: won,
      xpDelta: xpDelta,
      when: DateTime.now(),
    );
    history = [entry, ...history].take(_maxHistory).toList();
    notifyListeners();

    final p = _prefs;
    if (p == null) return;
    await p.setString(
      _kHistory,
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
  }

  /// Whether [playerId] is already a friend — the history card uses this
  /// to swap its ADD button for a FRIENDS label instead of offering to
  /// re-send a request that would just bounce.
  bool isFriend(int playerId) => friends.any((f) => f.id == playerId);

  /// Whether a friend request to [playerId] is already sitting out there
  /// unanswered, so the history card can show PENDING instead of ADD.
  bool hasOutgoingRequest(int playerId) =>
      outgoingRequests.any((f) => f.id == playerId);

  /// Runs an action, refreshes, and reports whether it worked — the shape
  /// every mutating call above shares.
  Future<bool> _act(Future<Map<String, dynamic>> Function() action) async {
    busy = true;
    notifyListeners();
    try {
      await action();
      lastError = null;
      await refresh();
      return true;
    } on OnlineError catch (e) {
      lastError = e.offline ? _offlineMessage : e.message;
      notifyListeners();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    // `stopHeartbeat` also bumps `_heartbeatGen`, which is what makes a
    // `_fastLoop` mid-`await` on the server's hold stop after that call
    // returns instead of continuing to poll through a disposed service.
    stopHeartbeat();
    api.close();
    super.dispose();
  }
}
