import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/audio.dart';
import '../game/characters.dart';
import '../game/maps.dart';
import '../game/match_store.dart';
import '../game/net.dart';
import '../game/raft.dart';
import '../theme.dart';
import '../widgets/lobby.dart';
import 'net_match.dart';

/// Hotspot multiplayer: host or join over the same Wi-Fi / mobile hotspot.
///
/// Two ways in, on purpose. SCAN FOR GAMES finds rooms by UDP broadcast and
/// needs nothing typed at all; the IP field stays for the networks that drop
/// broadcast (some routers, some corporate Wi-Fi, most hotel portals) where
/// it used to be the only option and a mistyped digit meant "multiplayer is
/// broken".
class HotspotScreen extends StatefulWidget {
  const HotspotScreen({super.key});

  @override
  State<HotspotScreen> createState() => _HotspotScreenState();
}

class _HotspotScreenState extends State<HotspotScreen> {
  final _ipController = TextEditingController();
  final NetService _net = NetService.instance;
  String _status = '';
  bool _busy = false;
  bool _resuming = false;
  MapDef _map = GameMaps.all.first;
  double _startHp = 100;

  @override
  void initState() {
    super.initState();
    // Announced in our greeting so the host can build the match with the
    // character we actually picked. Set here, before anything can host or
    // join, so no code path can greet without it.
    _net.selfLook = myLook().name;
    _net.onConnected = _onConnected;
    _net.onDisconnected = () {
      if (mounted) setState(() => _status = 'Opponent disconnected');
    };
    _net.onMessage = _onLobbyMessage;
  }

  @override
  void dispose() {
    _net.onConnected = null;
    _net.onDisconnected = null;
    _net.onMessage = null;
    _net.onResumeAgreed = null;
    _net.onResumeFailed = null;
    _ipController.dispose();
    super.dispose();
  }

  /// The hotspot battle waiting to be picked back up, if there is one.
  MatchSnapshot? get _resumable {
    final snap = MatchStore.instance.saved;
    return (snap != null && snap.isHotspot) ? snap : null;
  }

  void _onConnected() {
    if (!mounted) return;
    setState(() {
      _status = _net.isHost
          ? (_net.handshakeDone
              ? '${_net.peerName} joined! Press START.'
              : 'Opponent connecting…')
          : 'Connected to ${_net.peerName}! Waiting for the host to start…';
    });
  }

  void _onLobbyMessage(Map<String, dynamic> msg) {
    // Lobby-phase messages only; once a match is running GameController owns
    // the connection and re-points onMessage at itself.
    if (msg['t'] == 'start' && !_net.isHost) {
      launchNetMatch(
        context,
        net: _net,
        setup: NetMatchSetup.fromStart(msg, guestName: myName()),
        startPayload: msg,
      );
    }
  }

  // -------------------------------------------------------------- resume ---

  /// Walks back into an interrupted match.
  ///
  /// Which half of the rendezvous this device performs is decided by the seat
  /// it held: the host re-opens its old room and waits, the guest dials the
  /// host back. Getting that backwards would leave two hosts, or two guests,
  /// both waiting for someone who is also waiting.
  Future<void> _resume() async {
    final snap = _resumable;
    if (snap == null || _resuming) return;
    AudioService.instance.sfx('click');
    setState(() {
      _resuming = true;
      _status = snap.iAmHost
          ? 'Re-opening room ${snap.roomCode}…'
          : 'Looking for ${snap.peerName}…';
    });

    _net.onResumeFailed = (why) {
      if (!mounted) return;
      setState(() {
        _resuming = false;
        _status = why;
      });
    };
    _net.onResumeAgreed = (state) {
      if (!mounted) return;
      // Both devices have settled on one account of the battle; this is the
      // only place a resumed match is launched, so whichever side won the
      // reconciliation, the two enter with the same state.
      launchNetMatch(
        context,
        net: _net,
        setup: NetMatchSetup.fromStart(
          snap.start,
          guestName: snap.iAmHost ? _net.peerName : myName(),
        ),
        startPayload: snap.start,
        restore: state,
      );
    };

    final ok = snap.iAmHost
        ? (await _net.resumeHost(
              playerName: myName(),
              roomCode: snap.roomCode,
              offer: snap.offer,
            )) !=
            null
        : await _rejoinHost(snap);

    if (!mounted) return;
    // The host is now listening; the guest either connected or ran out of
    // patience. Either way the resume finishes on the handshake, not here.
    setState(() {
      if (!ok && !snap.iAmHost) _resuming = false;
      _status = _net.status;
    });
  }

  /// Dials the host back, then falls back to a scan.
  ///
  /// The saved address is right almost always, but not quite always: a phone
  /// that reconnects to the hotspot can come back on a different lease. The
  /// room CODE does not change, so when the address goes quiet it is worth one
  /// broadcast scan to find where that room moved to before giving up.
  Future<bool> _rejoinHost(MatchSnapshot snap) async {
    if (await _net.resumeJoin(
      snap.hostAddress,
      playerName: myName(),
      offer: snap.offer,
      timeout: const Duration(seconds: 25),
    )) {
      return true;
    }
    if (!mounted || !_resuming) return false;
    setState(() => _status = 'Not at the old address — scanning for the room…');
    await _net.scanRooms();
    await Future<void>.delayed(const Duration(milliseconds: 6500));
    if (!mounted || !_resuming) return false;
    final moved = _net.foundRooms.where(
      (r) => r.code.toUpperCase() == snap.roomCode.toUpperCase(),
    );
    if (moved.isEmpty) return false;
    return _net.resumeJoin(
      moved.first.host,
      playerName: myName(),
      offer: snap.offer,
      timeout: const Duration(seconds: 20),
    );
  }

  Future<void> _forfeit() async {
    AudioService.instance.sfx('click');
    _net.cancelResume();
    await _net.close();
    await MatchStore.instance.clear();
    if (!mounted) return;
    setState(() {
      _resuming = false;
      _status = 'Match forfeited.';
    });
  }

  Future<void> _host() async {
    setState(() {
      _busy = true;
      _status = 'Starting host…';
    });
    AudioService.instance.sfx('click');
    final code = await _net.host(playerName: myName());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = code == null ? _net.status : 'Waiting for an opponent to join…';
    });
  }

  Future<void> _scan() async {
    setState(() {
      _status = 'Scanning for games…';
    });
    AudioService.instance.sfx('click');
    await _net.scanRooms();
    if (!mounted) return;
    // scanRooms returns as soon as the socket is up; the 6s window runs in
    // the background and fills foundRooms as beacons land.
    await Future<void>.delayed(const Duration(milliseconds: 6500));
    if (!mounted) return;
    setState(() {
      _status = _net.foundRooms.isEmpty
          ? 'No games found. Make sure the other device is HOSTING on the same Wi-Fi, or join by IP below.'
          : '${_net.foundRooms.length} game(s) found — tap one to join.';
    });
  }

  Future<void> _joinRoom(RoomInfo room) async {
    setState(() {
      _busy = true;
      _status = 'Joining ${room.code}…';
    });
    AudioService.instance.sfx('click');
    await _net.join(room.host, playerName: myName());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = _net.status;
    });
  }

  Future<void> _joinByIp() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Connecting…';
    });
    AudioService.instance.sfx('click');
    await _net.join(ip, playerName: myName());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = _net.status;
    });
  }

  void _hostStart() {
    final seed = DateTime.now().millisecondsSinceEpoch;
    // The guest's raft is chosen here, by the host, and shipped along with
    // the host's own — see NetMatchSetup for why both have to travel.
    final hostRaft = myRaft();
    final guestRaft =
        RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 1);
    final payload = NetMatchSetup.startPayload(
      map: _map,
      startHp: _startHp,
      seed: seed,
      hostRaft: hostRaft,
      guestRaft: guestRaft,
      hostName: myName(),
      hostLook: myLook(),
      // The guest told us who they sail as in their greeting; the host
      // decides both sides' setup, so without this their choice would be
      // silently replaced by a default on both screens.
      guestLook: NetMatchSetup.lookOf(_net.peerLook, CrewLook.raider),
    );
    _net.send(payload);
    launchNetMatch(
      context,
      net: _net,
      startPayload: payload,
      setup: NetMatchSetup.forHost(
        map: _map,
        startHp: _startHp,
        seed: seed,
        hostRaft: hostRaft,
        guestRaft: guestRaft,
        hostName: myName(),
        guestName: _net.peerName,
        hostLook: myLook(),
        guestLook: NetMatchSetup.lookOf(_net.peerLook, CrewLook.raider),
      ),
    );
  }


  /// Offers the interrupted battle back, rather than dropping the player
  /// straight into it. Someone who closed the app to get out of a losing
  /// match should not be dragged back in by opening the lobby.
  Widget _resumeCard(MatchSnapshot snap) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: RT.card(color: RT.green, border: 0),
      child: Column(
        children: [
          Text('BATTLE IN PROGRESS', style: RT.chunky(size: 16, color: Colors.white)),
          const SizedBox(height: 4),
          Text(
            'against ${snap.peerName} • room ${snap.roomCode}',
            style: RT.body(size: 12, color: Colors.white.withOpacity(0.85)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            snap.iAmHost
                ? 'You were hosting — RESUME re-opens the room and waits.'
                : 'You joined — RESUME dials the host back.',
            style: RT.body(size: 10, color: Colors.white.withOpacity(0.75)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ChunkyButton(
                  label: _resuming ? 'WAITING…' : 'RESUME',
                  icon: Icons.play_arrow,
                  color: RT.orange,
                  width: double.infinity,
                  height: 48,
                  fontSize: 16,
                  onPressed: _resuming ? null : _resume,
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
                  onPressed: _forfeit,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Joins whatever is in the field: a four-letter room code, or a dotted
  /// IP typed straight in.
  ///
  /// A code is not an address, so it has to be resolved to one — the UDP
  /// beacon that SCAN listens to is what carries the mapping. If the code is
  /// not already in hand from a previous sweep this runs one, which is what
  /// makes "type the code your friend just read out" work as the first thing
  /// on the page rather than something you can only do after scanning.
  Future<void> _joinByCodeOrIp() async {
    final text = _ipController.text.trim();
    if (text.isEmpty) return;

    if (_looksLikeIp(text)) {
      await _joinByIp();
      return;
    }

    final code = text.toUpperCase();
    setState(() {
      _busy = true;
      _status = 'Looking for room $code…';
    });
    AudioService.instance.sfx('click');

    RoomInfo? match = _findRoom(code);
    if (match == null) {
      // The beacon sweep is what carries the code-to-address mapping, so a
      // code typed cold needs one before it can be resolved. scanRooms
      // returns as soon as the socket is up and the window fills
      // foundRooms in the background, hence the wait.
      await _net.scanRooms();
      await Future<void>.delayed(const Duration(milliseconds: 6500));
      if (!mounted) return;
      match = _findRoom(code);
    }
    if (!mounted) return;

    if (match == null) {
      setState(() {
        _busy = false;
        _status = 'No room called $code on this Wi-Fi. Check the code, or '
            'join by IP.';
      });
      return;
    }
    setState(() => _status = 'Joining $code…');
    await _net.join(match.host, playerName: myName());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = _net.status;
    });
  }

  RoomInfo? _findRoom(String code) {
    for (final r in _net.foundRooms) {
      if (r.code.toUpperCase() == code) return r;
    }
    return null;
  }

  /// A dotted quad, as opposed to a room code. Codes never contain a dot,
  /// so one is enough to tell them apart.
  static bool _looksLikeIp(String s) => s.contains('.');

  Future<void> _closeRoom() async {
    AudioService.instance.sfx('click');
    await _net.close();
    if (!mounted) return;
    setState(() => _status = '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: RT.sunset),
        child: SafeArea(
          child: Column(
            children: [
              LobbyHeader(
                title: 'HOTSPOT BATTLE',
                busy: _busy,
                onBack: () {
                  _net.close();
                  Navigator.pop(context);
                },
              ),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  /// Ordered by what somebody actually arrives here to do, most common
  /// first: type the code a friend has just read out, open a room of your
  /// own, or sweep the Wi-Fi to see who is already listening.
  ///
  /// It used to be four equal cards — info, host, scan, IP — which reads as
  /// a settings page rather than a lobby: everything the same size, nothing
  /// saying where to start. While a room IS open that block takes over the
  /// top of the page, because at that point it is the thing to hold up to
  /// the other player and everything else is noise.
  Widget _body() {
    final roomOpen = _net.isHost && _net.roomCode.isNotEmpty;
    final pop = PopSequence();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        if (_resumable != null) ...[
          pop.wrap(_resumeCard(_resumable!)),
          const SizedBox(height: 14),
        ],
        // Opening a room swaps the controls for the room panel. Done as a
        // cross-fade rather than a straight rebuild so it reads as "this
        // became that" instead of "that is gone, here is something else" —
        // each side is keyed so the switcher treats them as genuinely
        // different subtrees rather than trying to tween between unrelated
        // widget trees.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 380),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: roomOpen
              ? Column(
                  key: const ValueKey('room-open'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _openRoomPanel(),
                    const SizedBox(height: 14),
                  ],
                )
              : Column(
                  key: const ValueKey('room-closed'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    pop.wrap(_joinCard()),
                    const SizedBox(height: 14),
                    pop.wrap(_hostButton()),
                    const SizedBox(height: 14),
                  ],
                ),
        ),
        pop.wrap(_scanCard()),
        if (_status.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: RT.card(color: RT.ink.withOpacity(0.8), border: 0),
            child: Text(
              _status,
              style: RT.chunky(size: 13, color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ],
    );
  }

  /// The room this device is hosting, as the thing to physically show the
  /// other player: the code big enough to read across a table, every address
  /// underneath as the fallback when a code will not go through, and a live
  /// line for what the room is doing.
  Widget _openRoomPanel() {
    final waiting = _net.handshakeDone
        ? '${_net.peerName} is aboard — press START'
        : 'Waiting for somebody to join…';
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: RT.card(color: RT.ink, radius: 20, border: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Text('ROOM IS OPEN',
                style: RT.chunky(size: 18, color: RT.cream)),
          ),
          const SizedBox(height: 14),
          CodeTiles(code: _net.roomCode),
          const SizedBox(height: 12),
          if (_net.localIps.isNotEmpty)
            Center(
              child: Text(
                'OR BY IP — ${_net.localIps.first}  ·  WORKS IF THE CODE FAILS',
                textAlign: TextAlign.center,
                style: RT.body(
                    size: 8.5,
                    color: RT.cream.withOpacity(0.7),
                    weight: FontWeight.w800),
              ),
            ),
          if (_net.localIps.length > 1) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                'ALSO AT ${_net.localIps.skip(1).join(" · ")}',
                textAlign: TextAlign.center,
                style: RT.body(
                    size: 8,
                    color: RT.cream.withOpacity(0.55),
                    weight: FontWeight.w800),
              ),
            ),
          ],
          const SizedBox(height: 16),
          LobbyWaiting(waiting),
          const SizedBox(height: 14),
          Text('MAP',
              style: RT.body(
                      size: 9,
                      color: RT.cream.withOpacity(0.6),
                      weight: FontWeight.w800)
                  .copyWith(letterSpacing: 1.6)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: GameMaps.all
                .take(3)
                .map((m) => GestureDetector(
                      onTap: () => setState(() => _map = m),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: RT.card(
                          color: _map.id == m.id ? RT.yellow : Colors.white,
                          radius: 12,
                          border: 3,
                        ),
                        child: Text(m.name,
                            style: RT.chunky(size: 11, color: RT.ink)),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 14),
          ChunkyButton(
            label: _net.handshakeDone ? 'START MATCH!' : 'WAITING FOR OPPONENT…',
            icon: Icons.play_arrow,
            color: RT.red,
            width: double.infinity,
            height: 58,
            fontSize: 20,
            // Handshake first: pressing START the instant a TCP connection
            // existed used to fire the match setup at a guest whose game had
            // not attached its listener yet, so only the host played.
            onPressed: _net.handshakeDone ? _hostStart : null,
          ),
          const SizedBox(height: 10),
          ChunkyButton(
            label: 'CLOSE ROOM',
            icon: Icons.close,
            color: RT.red,
            width: double.infinity,
            height: 46,
            fontSize: 15,
            onPressed: _closeRoom,
          ),
        ],
      ),
    );
  }

  Widget _joinCard() {
    return LobbyCard(
      title: 'JOIN BY ROOM CODE',
      icon: Icons.vpn_key,
      color: RT.green,
      subtitle: 'Ask the host for their four-letter code — or read an IP off '
          'their screen and type that instead.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipController,
                  textCapitalization: TextCapitalization.characters,
                  // Room codes use letters; a dotted IP is accepted as the
                  // fallback, so digits and dots are allowed through too.
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9.]')),
                    LengthLimitingTextInputFormatter(15),
                    TextInputFormatter.withFunction(
                      (oldValue, newValue) => newValue.copyWith(
                        text: newValue.text.toUpperCase(),
                      ),
                    ),
                  ],
                  style: RT.chunky(size: 20, color: RT.ink)
                      .copyWith(letterSpacing: 6),
                  textAlign: TextAlign.center,
                  onSubmitted: (_) => _busy ? null : _joinByCodeOrIp(),
                  decoration: lobbyInput('K7QX'),
                ),
              ),
              const SizedBox(width: 10),
              ChunkyButton(
                label: _busy ? '…' : 'JOIN',
                color: RT.green,
                width: 96,
                height: 52,
                fontSize: 16,
                onPressed: _busy ? null : _joinByCodeOrIp,
              ),
            ],
          ),
          const SizedBox(height: 8),
          const LobbyHint(
            'A CODE IS LOOKED UP OVER THE WI-FI  ·  A DOTTED IP JOINS DIRECTLY',
            align: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Hosting is one tap, so it is one button rather than a card wrapped
  /// around one — the explanation it used to carry now lives on the room
  /// panel it opens, where it is actually needed.
  Widget _hostButton() {
    return ChunkyButton(
      label: _busy ? 'OPENING A ROOM…' : 'HOST A ROOM',
      icon: Icons.wifi_tethering,
      color: RT.orange,
      width: double.infinity,
      height: 58,
      fontSize: 19,
      onPressed: _busy ? null : _host,
    );
  }

  Widget _scanCard() {
    final rooms = _net.foundRooms;
    final headline = _net.isSearching
        ? 'Sweeping the Wi-Fi…'
        : rooms.isEmpty
            ? 'Nobody listening yet'
            : '${rooms.length} room${rooms.length == 1 ? '' : 's'} nearby';
    return LobbyCard(
      title: 'FIND A ROOM NEARBY',
      icon: Icons.wifi_find,
      color: RT.blue,
      subtitle: headline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChunkyButton(
            label: _net.isSearching ? 'SCANNING…' : 'SCAN',
            icon: Icons.radar,
            color: RT.blue,
            width: double.infinity,
            height: 48,
            fontSize: 16,
            onPressed: _busy || _net.isSearching ? null : _scan,
          ),
          if (rooms.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (int i = 0; i < rooms.length; i++)
              PopIn(
                key: ValueKey('room-${rooms[i].code}'),
                delay: Duration(milliseconds: 70 * i.clamp(0, 6)),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _roomRow(rooms[i]),
                ),
              ),
          ] else if (!_net.isSearching) ...[
            const SizedBox(height: 10),
            const LobbyHint(
              'THE HOST HAS TO OPEN A ROOM FIRST  ·  BOTH DEVICES ON THE SAME WI-FI',
              align: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _roomRow(RoomInfo room) {
    return GestureDetector(
      onTap: _busy ? null : () => _joinRoom(room),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: RT.card(color: Colors.white, radius: 14, border: 3),
        child: Row(
          children: [
            CodePill(code: room.code, color: RT.yellow),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(room.playerName,
                      style: RT.body(
                          size: 13, color: RT.ink, weight: FontWeight.w800)),
                  Text(room.host,
                      style: RT.body(
                          size: 10,
                          color: RT.ink.withOpacity(0.6),
                          weight: FontWeight.w700)),
                ],
              ),
            ),
            const Icon(Icons.login, color: RT.green),
          ],
        ),
      ),
    );
  }
}
