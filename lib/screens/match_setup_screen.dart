import 'package:flutter/material.dart';
import '../game/ai.dart';
import '../game/audio.dart';
import '../game/maps.dart';
import '../game/save.dart';
import '../game/models.dart';
import '../theme.dart';
import 'game_screen.dart';
import '../game/controller.dart';

/// Match setup for vs-AI and local modes
class MatchSetupScreen extends StatefulWidget {
  final String mode; // 'ai' | 'local'
  const MatchSetupScreen({super.key, required this.mode});

  @override
  State<MatchSetupScreen> createState() => _MatchSetupScreenState();
}

class _MatchSetupScreenState extends State<MatchSetupScreen> {
  MapDef _map = GameMaps.all.first;
  int _buildLimit = 10;
  double _startHp = 100;
  double _turnSeconds = 30;
  double _wind = 0.5;
  int _aiLevel = 1; // 0 easy 1 normal 2 hard 3 expert
  Set<String> _weapons = Weapons.all.map((w) => w.id).toSet();

  static const _aiNames = ['Easy Pete', 'Normal Nora', 'Hard Hank', 'Expert Eva'];

  @override
  Widget build(BuildContext context) {
    final save = SaveService.instance.data;
    final isAi = widget.mode == 'ai';
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: RT.sunset),
        child: SafeArea(
          child: Column(
            children: [
              _header(isAi ? 'BATTLE VS AI' : 'LOCAL BATTLE'),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      _section('MAP', _mapPicker(save)),
                      _section('BUILD PIECES', _buildPicker()),
                      _section('STARTING HEALTH', _hpPicker()),
                      _section('TURN TIMER', _turnPicker()),
                      _section('WIND', _windPicker()),
                      if (isAi) _section('AI DIFFICULTY', _aiPicker()),
                      _section('WEAPONS', _weaponPicker(save)),
                      const SizedBox(height: 20),
                      ChunkyButton(
                        label: 'START BATTLE!',
                        icon: Icons.play_arrow,
                        color: RT.red,
                        width: 300,
                        height: 66,
                        fontSize: 26,
                        onPressed: _start,
                      ),
                      const SizedBox(height: 30),
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

  Widget _header(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          _backBtn(),
          const SizedBox(width: 10),
          Text(title, style: RT.chunky(size: 26, outline: 3)),
        ],
      ),
    );
  }

  Widget _backBtn() {
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx('click');
        Navigator.pop(context);
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: RT.card(color: Colors.white, radius: 12, border: 3),
        child: const Icon(Icons.arrow_back, color: RT.ink, size: 24),
      ),
    );
  }

  Widget _section(String title, Widget child) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: RT.card(color: RT.cream),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: RT.chunky(size: 16, color: RT.ink)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _mapPicker(SaveData save) {
    return SizedBox(
      height: 118,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: GameMaps.all.map((m) {
          final locked = m.levelLock > save.level;
          final sel = _map.id == m.id;
          return GestureDetector(
            onTap: locked
                ? () => AudioService.instance.sfx('bounce')
                : () {
                    AudioService.instance.sfx('click');
                    setState(() => _map = m);
                  },
            child: Container(
              width: 120,
              margin: const EdgeInsets.only(right: 10),
              decoration: RT.card(
                color: sel ? RT.yellow : Colors.white,
                border: sel ? 5 : 3,
              ),
              child: Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(m.icon, size: 34, color: locked ? Colors.grey : RT.ink),
                        const SizedBox(height: 4),
                        Text(m.name, style: RT.chunky(size: 11, color: locked ? Colors.grey : RT.ink), textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                  if (locked)
                    Center(
                      child: Container(
                        color: Colors.black38,
                        child: Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: Text('LVL ${m.levelLock}', style: RT.chunky(size: 12, color: Colors.white, outline: 2)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPicker() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final (label, val) in [('QUICK', 5), ('STRATEGIC', 10), ('ADVANCED', 15), ('NONE', 0)])
          _chip(label, _buildLimit == val, () => setState(() => _buildLimit = val)),
      ],
    );
  }

  Widget _hpPicker() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final v in [50.0, 100.0, 150.0, 200.0])
          _chip('${v.round()}', _startHp == v, () => setState(() => _startHp = v)),
      ],
    );
  }

  Widget _turnPicker() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final v in [15.0, 30.0, 45.0, 60.0])
          _chip('${v.round()}s', _turnSeconds == v, () => setState(() => _turnSeconds = v)),
      ],
    );
  }

  Widget _windPicker() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final (label, v) in [('CALM', 0.0), ('BREEZY', 0.35), ('WINDY', 0.65), ('STORM', 1.0)])
          _chip(label, _wind == v, () => setState(() => _wind = v)),
      ],
    );
  }

  Widget _aiPicker() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (int i = 0; i < 4; i++)
          _chip(['EASY', 'NORMAL', 'HARD', 'EXPERT'][i], _aiLevel == i, () => setState(() => _aiLevel = i)),
      ],
    );
  }

  Widget _weaponPicker(SaveData save) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: Weapons.all.map((w) {
        final unlocked = w.levelLock <= save.level;
        final sel = _weapons.contains(w.id);
        return GestureDetector(
          onTap: !unlocked
              ? () => AudioService.instance.sfx('bounce')
              : () {
                  AudioService.instance.sfx('click');
                  setState(() {
                    if (sel && _weapons.length > 1) {
                      _weapons.remove(w.id);
                    } else {
                      _weapons.add(w.id);
                    }
                  });
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: RT.card(
              color: !unlocked ? Colors.grey.shade300 : (sel ? w.color : Colors.white),
              radius: 14,
              border: 3,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(unlocked ? w.icon : Icons.lock, size: 16, color: sel && unlocked ? Colors.white : RT.ink),
                const SizedBox(width: 4),
                Text(
                  w.name,
                  style: RT.chunky(size: 11, color: sel && unlocked ? Colors.white : (unlocked ? RT.ink : Colors.grey)),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx('click');
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: RT.card(color: selected ? RT.orange : Colors.white, radius: 14, border: 3),
        child: Text(label, style: RT.chunky(size: 12, color: selected ? Colors.white : RT.ink)),
      ),
    );
  }

  void _start() {
    AudioService.instance.sfx('fire');
    final settings = MatchSettings(
      map: _map,
      buildLimit: _buildLimit,
      startHp: _startHp,
      turnSeconds: _turnSeconds,
      windStrength: _wind,
      enabledWeapons: _weapons.toList(),
    );
    final save = SaveService.instance.data;
    final List<PlayerConfig> players;
    if (widget.mode == 'ai') {
      players = [
        PlayerConfig(name: 'YOU', colorIndex: save.colorIndex, hatIndex: save.hatIndex),
        PlayerConfig(
          name: _aiNames[_aiLevel],
          colorIndex: 1,
          hatIndex: 3,
          isAi: true,
          aiDifficulty: AiDifficulty.values[_aiLevel],
        ),
      ];
    } else {
      players = [
        PlayerConfig(name: 'PLAYER 1', colorIndex: 0, hatIndex: save.hatIndex),
        PlayerConfig(name: 'PLAYER 2', colorIndex: 1, hatIndex: 3),
      ];
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => GameScreen(
          settings: settings,
          players: players,
          mode: widget.mode == 'ai' ? GameMode.vsAi : GameMode.local,
        ),
      ),
    );
  }
}
