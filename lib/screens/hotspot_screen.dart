import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../game/audio.dart';
import '../game/controller.dart';
import '../game/maps.dart';
import '../game/models.dart';
import '../game/net.dart';
import '../game/save.dart';
import '../theme.dart';
import 'game_screen.dart';

/// Hotspot multiplayer: host or join over local Wi-Fi / hotspot.
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

  // match settings (host picks)
  int _buildLimit = 10;
  double _startHp = 100;
  double _wind = 0.5;

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
    super.dispose();
  }

  void _onConnected() {
    if (!mounted) return;
    setState(() => _status = _net.isHost ? 'Opponent joined! Press START.' : 'Connected! Waiting for host to start…');
    if (_net.isHost) {
      // send hello
      _net.send({'t': 'hello', 'name': 'Host'});
    }
  }

  void _onLobbyMessage(Map<String, dynamic> msg) {
    // lobby-phase messages only; once in game the GameController takes over
    if (msg['t'] == 'start' && !_net.isHost) {
      final settings = MatchSettings(
        map: GameMaps.byId(msg['map']),
        buildLimit: msg['build'],
        startHp: (msg['hp'] as num).toDouble(),
        windStrength: (msg['wind'] as num).toDouble(),
        turnSeconds: 30,
      );
      _startGame(settings, seed: msg['seed']);
    }
  }

  Future<void> _host() async {
    setState(() { _busy = true; _status = 'Starting host…'; });
    AudioService.instance.sfx('click');
    final ok = await _net.host();
    setState(() {
      _busy = false;
      _status = ok ? 'Hosting on ${_net.hostAddress}:50505 — tell your friend to JOIN this IP!' : _net.status;
    });
  }

  Future<void> _join() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    setState(() { _busy = true; _status = 'Connecting…'; });
    AudioService.instance.sfx('click');
    final ok = await _net.join(ip);
    setState(() { _busy = false; _status = _net.status; });
  }

  void _hostStart() {
    final seed = DateTime.now().millisecondsSinceEpoch;
    _net.send({
      't': 'start',
      'map': _map.id,
      'build': _buildLimit,
      'hp': _startHp,
      'wind': _wind,
      'seed': seed,
    });
    final settings = MatchSettings(map: _map, buildLimit: _buildLimit, startHp: _startHp, windStrength: _wind, turnSeconds: 30);
    _startGame(settings, seed: seed);
  }

  void _startGame(MatchSettings settings, {required int seed}) {
    final save = SaveService.instance.data;
    final players = [
      PlayerConfig(name: 'HOST', colorIndex: save.colorIndex, hatIndex: save.hatIndex, netId: 0),
      PlayerConfig(name: 'GUEST', colorIndex: 1, hatIndex: 3, netId: 1),
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
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: RT.card(),
                        child: Column(
                          children: [
                            Text('📡 SAME WI-FI / HOTSPOT', style: RT.chunky(size: 16, color: RT.ink)),
                            const SizedBox(height: 6),
                            Text(
                              'Both devices must be on the same Wi-Fi network or mobile hotspot. One player HOSTs, the other JOINs using the host\'s IP address.',
                              style: RT.chunky(size: 11, color: RT.ink.withOpacity(0.7), weight: FontWeight.w600, letterSpacing: 0.4),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ChunkyButton(
                              label: 'HOST GAME', icon: Icons.wifi_tethering, color: RT.blue,
                              width: double.infinity, fontSize: 17,
                              onPressed: _busy ? null : _host,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: RT.card(),
                        child: Row(
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
                              label: 'JOIN', icon: Icons.login, color: RT.green,
                              width: 110, height: 52, fontSize: 16,
                              onPressed: _busy ? null : _join,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (_net.isHost && _net.connected) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: RT.card(),
                          child: Column(
                            children: [
                              Text('HOST SETTINGS', style: RT.chunky(size: 14, color: RT.ink)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8, runSpacing: 8,
                                children: GameMaps.all.take(3).map((m) => GestureDetector(
                                  onTap: () => setState(() => _map = m),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: RT.card(color: _map.id == m.id ? RT.yellow : Colors.white, radius: 12, border: 3),
                                    child: Text(m.name, style: RT.chunky(size: 11, color: RT.ink)),
                                  ),
                                )).toList(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        ChunkyButton(
                          label: 'START MATCH!', icon: Icons.play_arrow, color: RT.red,
                          width: 280, height: 60, fontSize: 22,
                          onPressed: _hostStart,
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (_status.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: RT.card(color: RT.ink.withOpacity(0.8), border: 0),
                          child: Text(_status, style: RT.chunky(size: 13, color: Colors.white), textAlign: TextAlign.center),
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
}
