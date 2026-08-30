import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/audio.dart';
import '../game/controller.dart';
import '../game/maps.dart';
import '../game/net.dart';
import '../game/raft.dart';
import '../game/save.dart';
import '../theme.dart';
import 'game_screen.dart';

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
  MapDef _map = GameMaps.all.first;
  double _startHp = 100;

  @override
  void initState() {
    super.initState();
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
    _ipController.dispose();
    super.dispose();
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
      final hp = msg['hp'];
      final seed = msg['seed'];
      final settings = MatchSettings(
        map: GameMaps.byId(msg['map'] as String? ?? _map.id),
        startHp: hp is num ? hp.toDouble() : 100,
        turnSeconds: 30,
      );
      _startGame(settings, seed: seed is int ? seed : DateTime.now().millisecondsSinceEpoch);
    }
  }

  Future<void> _host() async {
    setState(() {
      _busy = true;
      _status = 'Starting host…';
    });
    AudioService.instance.sfx('click');
    final code = await _net.host(playerName: 'Host');
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
    await _net.join(room.host, playerName: 'Guest');
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
    await _net.join(ip, playerName: 'Guest');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = _net.status;
    });
  }

  void _hostStart() {
    final seed = DateTime.now().millisecondsSinceEpoch;
    _net.send({
      't': 'start',
      'map': _map.id,
      'hp': _startHp,
      'seed': seed,
    });
    final settings = MatchSettings(map: _map, startHp: _startHp, turnSeconds: 30);
    _startGame(settings, seed: seed);
  }

  void _startGame(MatchSettings settings, {required int seed}) {
    final save = SaveService.instance.data;
    final players = [
      PlayerConfig(
        name: 'HOST',
        loadout: save.raftLoadout,
        netId: 0,
      ),
      PlayerConfig(
        name: 'GUEST',
        loadout: RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 1),
        netId: 1,
      ),
    ];
    final controller = GameController(
      settings: settings,
      players: players,
      mode: GameMode.hotspot,
      net: _net,
      seed: seed,
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => GameScreen(
          settings: settings,
          players: players,
          mode: GameMode.hotspot,
          seed: seed,
          controller: controller,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: RT.sunset),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        _net.close();
                        Navigator.pop(context);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: RT.card(color: Colors.white, radius: 12, border: 3),
                        child: const Icon(Icons.arrow_back, color: RT.ink),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('HOTSPOT BATTLE', style: RT.chunky(size: 24, outline: 3)),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _infoCard(),
                      const SizedBox(height: 14),
                      _hostCard(),
                      const SizedBox(height: 14),
                      _scanCard(),
                      const SizedBox(height: 14),
                      _ipCard(),
                      const SizedBox(height: 16),
                      if (_status.isNotEmpty)
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
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: RT.card(),
      child: Column(
        children: [
          Text('📡 SAME WI-FI / HOTSPOT', style: RT.chunky(size: 16, color: RT.ink)),
          const SizedBox(height: 6),
          Text(
            'Both devices must be on the same Wi-Fi network or mobile hotspot. '
            'One player HOSTs; the other taps SCAN FOR GAMES and picks the room.',
            style: RT.chunky(
                size: 11,
                color: RT.ink.withOpacity(0.7),
                weight: FontWeight.w600,
                letterSpacing: 0.4),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _hostCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: RT.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChunkyButton(
            label: 'HOST GAME',
            icon: Icons.wifi_tethering,
            color: RT.blue,
            width: double.infinity,
            fontSize: 17,
            onPressed: _busy ? null : _host,
          ),
          // Everything the joiner needs to know, shown straight away — the
          // room code for scanning, and EVERY address this device has, since
          // a hotspot phone also holds a mobile-data address that is useless
          // to a device sitting on its hotspot.
          if (_net.isHost && _net.roomCode.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: RT.card(color: RT.yellow, radius: 14, border: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ROOM CODE',
                      style: RT.body(size: 9, color: const Color(0xFF6B4A00),
                          weight: FontWeight.w800, letterSpacing: 1.6)),
                  const SizedBox(height: 2),
                  Text(_net.roomCode,
                      style: RT.chunky(size: 30, color: const Color(0xFF6B4A00))),
                ],
              ),
            ),
            if (_net.localIps.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('OR JOIN BY IP',
                  style: RT.body(size: 9, color: RT.ink.withOpacity(0.55),
                      weight: FontWeight.w800, letterSpacing: 1.6)),
              const SizedBox(height: 4),
              for (final ip in _net.localIps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(ip,
                            style: RT.body(size: 14, color: RT.ink, weight: FontWeight.w800)),
                      ),
                      GestureDetector(
                        onTap: () async {
                          await Clipboard.setData(ClipboardData(text: ip));
                          if (!mounted) return;
                          setState(() => _status = 'Copied $ip — paste it on the other device.');
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: RT.pill(radius: 10),
                          child: const Icon(Icons.copy, size: 16, color: RT.ink),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 10),
            Text('HOST SETTINGS',
                style: RT.body(size: 9, color: RT.ink.withOpacity(0.55),
                    weight: FontWeight.w800, letterSpacing: 1.6)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: GameMaps.all
                  .take(3)
                  .map((m) => GestureDetector(
                        onTap: () => setState(() => _map = m),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: RT.card(
                            color: _map.id == m.id ? RT.yellow : Colors.white,
                            radius: 12,
                            border: 3,
                          ),
                          child: Text(m.name, style: RT.chunky(size: 11, color: RT.ink)),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            ChunkyButton(
              label: _net.handshakeDone ? 'START MATCH!' : 'WAITING FOR OPPONENT…',
              icon: Icons.play_arrow,
              color: RT.red,
              width: double.infinity,
              height: 60,
              fontSize: 22,
              // Handshake first: pressing START the instant a TCP connection
              // existed used to fire the match setup at a guest whose game
              // had not attached its listener yet, so only the host played.
              onPressed: _net.handshakeDone ? _hostStart : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _scanCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: RT.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChunkyButton(
            label: _net.isSearching ? 'SCANNING…' : 'SCAN FOR GAMES',
            icon: Icons.wifi_find,
            color: RT.green,
            width: double.infinity,
            fontSize: 17,
            onPressed: _busy || _net.isSearching ? null : _scan,
          ),
          if (_net.foundRooms.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final room in _net.foundRooms)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GestureDetector(
                  onTap: _busy ? null : () => _joinRoom(room),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: RT.card(color: Colors.white, radius: 14, border: 3),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: RT.card(color: RT.yellow, radius: 10, border: 2),
                          child: Text(room.code,
                              style: RT.chunky(size: 16, color: const Color(0xFF6B4A00))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(room.playerName,
                                  style: RT.body(size: 13, color: RT.ink, weight: FontWeight.w800)),
                              Text(room.host,
                                  style: RT.body(size: 10, color: RT.ink.withOpacity(0.6),
                                      weight: FontWeight.w700)),
                            ],
                          ),
                        ),
                        const Icon(Icons.login, color: RT.green),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _ipCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: RT.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('OR JOIN BY IP',
              style: RT.body(size: 9, color: RT.ink.withOpacity(0.55),
                  weight: FontWeight.w800, letterSpacing: 1.6)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipController,
                  // A plain numeric keypad hides the "." key on most phones,
                  // making it painful to type a dotted IPv4 address. Requesting
                  // the decimal-enabled numeric keyboard keeps digits front and
                  // center while still exposing a period key, and the input
                  // formatter below blocks anything that isn't a digit or dot.
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    hintText: 'Host IP, e.g. 192.168.1.5',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ChunkyButton(
                label: 'JOIN',
                icon: Icons.login,
                color: RT.green,
                width: 110,
                height: 52,
                fontSize: 16,
                onPressed: _busy ? null : _joinByIp,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
