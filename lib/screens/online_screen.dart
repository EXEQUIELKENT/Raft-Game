import 'dart:async';

import 'package:flutter/material.dart';

import '../game/audio.dart';
import '../game/characters.dart';
import '../game/maps.dart';
import '../game/match_store.dart';
import '../game/net.dart';
import '../game/online_service.dart';
import '../game/raft.dart';
import '../game/save.dart';
import '../theme.dart';
import 'net_match.dart';

/// Internet play: sign in, keep a friends list, and find someone to battle.
///
/// Everything below the surface is the same match a hotspot game plays — the
/// server pairs two captains and then does nothing but pass their JSON lines
/// along, so once a match goes live this screen hands over to exactly the
/// launcher the hotspot lobby uses. What lives here is only the part a LAN
/// game does not need: an account, presence, friends and a queue.
class OnlineScreen extends StatefulWidget {
  const OnlineScreen({super.key});

  @override
  State<OnlineScreen> createState() => _OnlineScreenState();
}

class _OnlineScreenState extends State<OnlineScreen> {
  final OnlineService _online = OnlineService();
  final NetService _net = NetService.instance;

  final _serverController = TextEditingController();
  final _searchController = TextEditingController();
  final _nameController = TextEditingController();

  List<OnlinePlayer> _results = const [];
  bool _searching = false;

  /// Set the moment a live match is handed to the launcher, so a second
  /// poll landing in the same frame cannot push the battle screen twice.
  bool _launching = false;
  int? _lastMatchId;

  MapDef _map = GameMaps.all.first;

  @override
  void initState() {
    super.initState();
    _nameController.text = SaveService.instance.data.playerName;
    // Announced in our greeting, so whichever side ends up hosting builds
    // the match with the character we actually picked.
    _net.selfLook = myLook().name;
    _online.addListener(_onOnline);
    unawaited(_boot());
  }

  @override
  void dispose() {
    _online.removeListener(_onOnline);
    _online.dispose();
    _serverController.dispose();
    _searchController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _online.load();
    await MatchStore.instance.load();
    _serverController.text = _online.baseUrl;
    if (!mounted) return;
    setState(() {});
    // Find a server and sign in without anybody typing an address, the same
    // way the hotspot lobby scans rather than asking for an IP.
    await _online.connectAuto(SaveService.instance.data);
    if (!mounted) return;
    _serverController.text = _online.baseUrl;
    if (_online.signedIn) _online.startHeartbeat();
    setState(() {});
  }

  void _onOnline() {
    if (!mounted) return;
    setState(() {});
    _maybeEnterMatch();
  }

  /// A pairing both captains accepted becomes a live match; that is the
  /// signal to stop lobbying and start playing.
  void _maybeEnterMatch() {
    final match = _online.match;
    if (match == null || !match.isActive) return;
    if (_launching || match.id == _lastMatchId) return;
    // A match we have a snapshot for is OFFERED, not resumed behind the
    // player's back: dropping them into a battle they left hours ago is
    // startling, and entering here would skip the snapshot and restart it
    // at full health.
    if (_resumable != null) return;
    _launching = true;
    _lastMatchId = match.id;
    unawaited(_enterMatch(match));
  }

  Future<void> _enterMatch(OnlineMatch match, {MatchSnapshot? resume}) async {
    final ok = await _net.startRelayMatch(
      api: _online.api,
      matchId: match.id,
      asHost: match.youAreHost,
      playerName: myName(),
      // Picking the conversation back up where we left it. Starting at 0
      // would replay the whole match history — every shot already taken.
      since: resume?.relaySince ?? 0,
    );
    if (!mounted || !ok) {
      _launching = false;
      return;
    }
    _online.noteMatchStarted(match.id,
        opponentId: match.peerId, opponentName: match.peerName);
    // The relay is now the only thing that needs to be polling; a lobby
    // heartbeat on top of it is pure duplicate traffic.
    _online.stopHeartbeat();

    // Resuming: the world is rebuilt from the `start` we saved rather than
    // negotiated again, and the saved turn state goes back on top of it.
    if (resume != null) {
      launchNetMatch(
        context,
        net: _net,
        setup: NetMatchSetup.fromStart(resume.start, guestName: myName()),
        startPayload: resume.start,
        restore: resume.state,
      );
      return;
    }

    if (match.youAreHost) {
      // The host settles the match and tells the guest, exactly as over a
      // socket. The guest's own `start` handler does the rest.
      final seed = DateTime.now().millisecondsSinceEpoch;
      final hostRaft = myRaft();
      final guestRaft =
          RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 1);
      final payload = NetMatchSetup.startPayload(
        map: _map,
        startHp: 100,
        seed: seed,
        hostRaft: hostRaft,
        guestRaft: guestRaft,
        hostName: myName(),
        hostLook: myLook(),
        guestLook: NetMatchSetup.lookOf(_net.peerLook, CrewLook.raider),
      );
      _net.send(payload);
      if (!mounted) return;
      launchNetMatch(
        context,
        net: _net,
        startPayload: payload,
        setup: NetMatchSetup.forHost(
          map: _map,
          startHp: 100,
          seed: seed,
          hostRaft: hostRaft,
          guestRaft: guestRaft,
          hostName: myName(),
          guestName: match.peerName,
          hostLook: myLook(),
          guestLook: NetMatchSetup.lookOf(_net.peerLook, CrewLook.raider),
        ),
      );
    } else {
      // Wait for the host's `start`, then launch on it.
      _net.onMessage = (msg) {
        if (msg['t'] != 'start' || !mounted) return;
        launchNetMatch(
          context,
          net: _net,
          setup: NetMatchSetup.fromStart(msg, guestName: myName()),
          startPayload: msg,
        );
      };
    }
  }

  /// A match left running when the app was closed, if the server still has
  /// it open. Both halves have to agree: our own snapshot says what was
  /// happening, and the server's `poll` says the opponent is still there.
  MatchSnapshot? get _resumable {
    final snap = MatchStore.instance.saved;
    if (snap == null) return null;
    if (snap.isHotspot) return null;
    final m = _online.match;
    if (m == null || !m.isActive || m.id != snap.matchId) return null;
    return snap;
  }

  Future<void> _resume() async {
    final snap = _resumable;
    final m = _online.match;
    if (snap == null || m == null || _launching) return;
    _tap();
    _launching = true;
    _lastMatchId = m.id;
    await _enterMatch(m, resume: snap);
  }

  // ---------------------------------------------------------------- actions

  void _tap() => AudioService.instance.sfx('click');

  Future<void> _saveName() async {
    final n = _nameController.text.trim();
    if (n.isEmpty) return;
    SaveService.instance.data.playerName = n;
    await SaveService.instance.save();
    await _online.syncProfile(SaveService.instance.data);
    if (mounted) setState(() {});
  }

  Future<void> _useServer() async {
    _tap();
    await _online.setBaseUrl(_serverController.text);
    await _online.ensureAccount(SaveService.instance.data);
    if (_online.signedIn) _online.startHeartbeat();
    if (mounted) setState(() {});
  }

  Future<void> _search() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    _tap();
    setState(() => _searching = true);
    final found = await _online.search(q);
    if (!mounted) return;
    setState(() {
      _results = found.where((p) => p.id != _online.myId).toList();
      _searching = false;
    });
  }

  Future<void> _queue() async {
    _tap();
    if (_online.searching) {
      await _online.leaveQueue();
      _online.startHeartbeat();
    } else {
      await _online.joinQueue();
      // Tight long-polling while the MATCH FOUND prompt is what we're
      // waiting on; back to the calm heartbeat once it resolves.
      _online.startHeartbeat(fast: true);
    }
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    final match = _online.match;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: RT.sunset),
        child: SafeArea(
          child: Column(
            children: [
              _header(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!_online.signedIn) _serverCard(),
                      if (_online.signedIn) ...[
                        _meCard(),
                        const SizedBox(height: 14),
                        if (_resumable != null) ...[
                          _resumeCard(_resumable!),
                          const SizedBox(height: 14),
                        ],
                        if (match != null && match.isFound) _foundCard(match),
                        if (match != null && match.isIncomingInvite)
                          _inviteCard(match),
                        if (match != null &&
                            (match.isFound || match.isIncomingInvite))
                          const SizedBox(height: 14),
                        _quickMatchCard(),
                        const SizedBox(height: 14),
                        _findCard(),
                        const SizedBox(height: 14),
                        _friendsCard(),
                      ],
                      if (_online.lastError != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: RT.card(color: RT.red, border: 0),
                          child: Text(_online.lastError!,
                              style: RT.chunky(size: 12, color: Colors.white),
                              textAlign: TextAlign.center),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            GestureDetector(
              onTap: () {
                _online.stopHeartbeat();
                Navigator.pop(context);
              },
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: RT.card(color: Colors.white, radius: 12, border: 3),
                child: const Icon(Icons.arrow_back, color: RT.ink),
              ),
            ),
            const SizedBox(width: 10),
            Text('ONLINE BATTLE', style: RT.chunky(size: 24, outline: 3)),
            const Spacer(),
            if (_online.busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
              ),
          ],
        ),
      );

  Widget _card({required String title, required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: RT.card(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: RT.chunky(size: 16, color: RT.ink)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );

  Widget _serverCard() => _card(
        title: 'GAME SERVER',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _online.busy
                  ? 'Looking for a server…'
                  : 'No server found automatically. Type its address and try again.',
              style: RT.body(size: 12, color: RT.ink.withOpacity(0.7)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(
                hintText: 'http://192.168.1.7/…/server',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            ChunkyButton(
              label: 'CONNECT',
              icon: Icons.cloud,
              color: RT.orange,
              width: double.infinity,
              height: 48,
              fontSize: 16,
              onPressed: _online.busy ? null : _useServer,
            ),
          ],
        ),
      );

  Widget _meCard() => _card(
        title: 'YOUR CAPTAIN',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _saveName(),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _saveName,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: RT.card(color: RT.green, radius: 12, border: 0),
                    child: const Icon(Icons.check, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('FRIEND CODE ', style: RT.body(size: 11, color: RT.ink.withOpacity(0.6), weight: FontWeight.w800)),
                Text(_online.myTag, style: RT.chunky(size: 16, color: RT.orange)),
              ],
            ),
          ],
        ),
      );

  Widget _resumeCard(MatchSnapshot snap) => Container(
        padding: const EdgeInsets.all(14),
        decoration: RT.card(color: RT.green, border: 0),
        child: Column(
          children: [
            Text('BATTLE IN PROGRESS',
                style: RT.chunky(size: 16, color: Colors.white)),
            const SizedBox(height: 4),
            Text('against ${snap.peerName}',
                style: RT.body(size: 12, color: Colors.white.withOpacity(0.85))),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ChunkyButton(
                    label: 'RESUME',
                    icon: Icons.play_arrow,
                    color: RT.orange,
                    width: double.infinity,
                    height: 48,
                    fontSize: 16,
                    onPressed: _resume,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChunkyButton(
                    label: 'FORFEIT',
                    color: RT.red,
                    width: double.infinity,
                    height: 48,
                    fontSize: 15,
                    onPressed: () async {
                      _tap();
                      await MatchStore.instance.clear();
                      await _online.endMatch();
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _quickMatchCard() => _card(
        title: 'QUICK MATCH',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _online.searching
                  ? 'Searching for an opponent…'
                  : 'Get paired with another captain looking for a battle.',
              style: RT.body(size: 12, color: RT.ink.withOpacity(0.7)),
            ),
            const SizedBox(height: 10),
            ChunkyButton(
              label: _online.searching ? 'CANCEL SEARCH' : 'FIND A MATCH',
              icon: _online.searching ? Icons.close : Icons.search,
              color: _online.searching ? RT.red : RT.orange,
              width: double.infinity,
              height: 52,
              fontSize: 17,
              onPressed: _queue,
            ),
          ],
        ),
      );

  Widget _foundCard(OnlineMatch match) => Container(
        padding: const EdgeInsets.all(14),
        decoration: RT.card(color: RT.yellow, border: 0),
        child: Column(
          children: [
            Text('MATCH FOUND', style: RT.chunky(size: 18, color: RT.ink)),
            const SizedBox(height: 4),
            Text(match.peerName, style: RT.chunky(size: 15, color: RT.ink)),
            const SizedBox(height: 4),
            Text(
              match.youAccepted ? 'Waiting for them to accept…' : 'Both captains must accept.',
              style: RT.body(size: 11, color: RT.ink.withOpacity(0.7)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ChunkyButton(
                    label: match.youAccepted ? 'ACCEPTED' : 'ACCEPT',
                    color: RT.green,
                    width: double.infinity,
                    height: 46,
                    fontSize: 15,
                    onPressed: match.youAccepted
                        ? null
                        : () {
                            _tap();
                            unawaited(_online.acceptMatch(match.id));
                          },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChunkyButton(
                    label: 'DECLINE',
                    color: RT.red,
                    width: double.infinity,
                    height: 46,
                    fontSize: 15,
                    onPressed: () {
                      _tap();
                      unawaited(_online.leaveQueue());
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _inviteCard(OnlineMatch match) => Container(
        padding: const EdgeInsets.all(14),
        decoration: RT.card(color: RT.blue, border: 0),
        child: Column(
          children: [
            Text('${match.peerName} CHALLENGED YOU',
                style: RT.chunky(size: 15, color: Colors.white),
                textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ChunkyButton(
                    label: 'ACCEPT',
                    color: RT.green,
                    width: double.infinity,
                    height: 46,
                    fontSize: 15,
                    onPressed: () {
                      _tap();
                      unawaited(_online.respondToInvite(match.id, true));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChunkyButton(
                    label: 'DECLINE',
                    color: RT.red,
                    width: double.infinity,
                    height: 46,
                    fontSize: 15,
                    onPressed: () {
                      _tap();
                      unawaited(_online.respondToInvite(match.id, false));
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _findCard() => _card(
        title: 'ADD A FRIEND',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: 'Name or friend code',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _search,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: RT.card(color: RT.orange, radius: 12, border: 0),
                    child: const Icon(Icons.search, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
            if (_searching)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('Searching…',
                    style: RT.body(size: 12, color: RT.ink.withOpacity(0.6))),
              ),
            for (final p in _results)
              _playerRow(
                p,
                trailing: _online.isFriend(p.id)
                    ? Text('FRIEND',
                        style: RT.body(size: 10, color: RT.green, weight: FontWeight.w800))
                    : _online.hasOutgoingRequest(p.id)
                        ? Text('ASKED',
                            style: RT.body(
                                size: 10, color: RT.ink.withOpacity(0.5), weight: FontWeight.w800))
                        : _iconBtn(Icons.person_add, RT.orange, () {
                            _tap();
                            unawaited(_online.requestById(p.id));
                          }),
              ),
          ],
        ),
      );

  Widget _friendsCard() {
    final incoming = _online.incomingRequests;
    final friends = _online.friends;
    return _card(
      title: 'FRIENDS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (incoming.isEmpty && friends.isEmpty)
            Text('Nobody yet — search for a captain above.',
                style: RT.body(size: 12, color: RT.ink.withOpacity(0.6))),
          for (final p in incoming)
            _playerRow(
              p,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _iconBtn(Icons.check, RT.green, () {
                    _tap();
                    unawaited(_online.respondToRequest(p.id, true));
                  }),
                  const SizedBox(width: 6),
                  _iconBtn(Icons.close, RT.red, () {
                    _tap();
                    unawaited(_online.respondToRequest(p.id, false));
                  }),
                ],
              ),
            ),
          for (final p in friends)
            _playerRow(
              p,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.online)
                    _iconBtn(Icons.sports_esports, RT.orange, () {
                      _tap();
                      unawaited(_online.invite(p.id));
                    }),
                  const SizedBox(width: 6),
                  _iconBtn(Icons.person_remove, RT.ink.withOpacity(0.45), () {
                    _tap();
                    unawaited(_online.unfriend(p.id));
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _playerRow(OnlinePlayer p, {required Widget trailing}) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: raftColorAt(p.raftColorIndex),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text('${p.level}',
                  style: RT.body(size: 12, color: Colors.white, weight: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, style: RT.chunky(size: 14, color: RT.ink)),
                  Text(
                    '${p.presenceLabel} · ${p.wins}W ${p.losses}L',
                    style: RT.body(size: 10, color: RT.ink.withOpacity(0.55)),
                  ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      );

  Widget _iconBtn(IconData icon, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: RT.card(color: color, radius: 10, border: 0),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      );
}
