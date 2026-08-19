import 'package:flutter/material.dart';
import '../game/ai.dart';
import '../game/audio.dart';
import '../game/battle.dart';
import '../game/maps.dart';
import '../game/raft.dart';
import '../game/save.dart';
import '../game/models.dart';
import '../theme.dart';
import 'game_screen.dart';
import '../game/controller.dart';
import 'raft_preview.dart';

/// Match setup for vs-AI and local modes
class MatchSetupScreen extends StatefulWidget {
  final String mode; // 'ai' | 'local'
  const MatchSetupScreen({super.key, required this.mode});

  @override
  State<MatchSetupScreen> createState() => _MatchSetupScreenState();
}

class _MatchSetupScreenState extends State<MatchSetupScreen> {
  MapDef _map = GameMaps.all.first;
  double _startHp = 100;
  double _turnSeconds = 30;
  int _aiLevel = 1; // 0 easy 1 normal 2 hard 3 expert
  final Set<String> _weapons = Weapons.all.map((w) => w.id).toSet();

  // Per-seat raft customization. Seat 0 is the local player in both modes;
  // seat 1 is the second local player (unused when playing against AI).
  final List<String> _hullIds = ['tube', 'log'];
  final List<String> _sizeIds = ['medium', 'medium'];
  final List<int> _raftColors = [0, 1];

  /// Which seat the raft pickers currently edit.
  int _editingSeat = 0;

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
                      _section('WATERS', _mapPicker(save)),
                      if (!isAi) _section('EDITING RAFT', _seatPicker()),
                      _section(isAi ? 'YOUR RAFT' : 'RAFT ${_editingSeat + 1}', _raftPicker()),
                      _section('STARTING HEALTH', _hpPicker()),
                      _section('TURN TIMER', _turnPicker()),
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

  Widget _seatPicker() {
    return Row(
      children: [
        for (int i = 0; i < 2; i++) ...[
          _chip('PLAYER ${i + 1}', _editingSeat == i, () => setState(() => _editingSeat = i)),
          const SizedBox(width: 8),
        ],
      ],
    );
  }

  /// Raft hull / size / colour pickers for the seat currently being edited.
  Widget _raftPicker() {
    final seat = _editingSeat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RaftPreview(
          loadout: RaftLoadout.custom(
            hullId: _hullIds[seat],
            sizeId: _sizeIds[seat],
            colorIndex: _raftColors[seat],
          ),
        ),
        const SizedBox(height: 10),
        Text('DESIGN', style: RT.body(size: 10, color: RT.ink.withOpacity(0.6), weight: FontWeight.w800, letterSpacing: 1.4)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final h in RaftHull.all)
              _chip(h.name.toUpperCase(), _hullIds[seat] == h.id,
                  () => setState(() => _hullIds[seat] = h.id)),
          ],
        ),
        const SizedBox(height: 12),
        Text('SIZE', style: RT.body(size: 10, color: RT.ink.withOpacity(0.6), weight: FontWeight.w800, letterSpacing: 1.4)),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final s in RaftSize.all) ...[
              _chip('${s.name.toUpperCase()} · ${s.crewCapacity} CREW', _sizeIds[seat] == s.id,
                  () => setState(() => _sizeIds[seat] = s.id)),
              const SizedBox(width: 8),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text('COLOUR', style: RT.body(size: 10, color: RT.ink.withOpacity(0.6), weight: FontWeight.w800, letterSpacing: 1.4)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (int c = 0; c < raftColors.length; c++)
              GestureDetector(
                onTap: () {
                  AudioService.instance.sfx('click');
                  setState(() => _raftColors[seat] = c);
                },
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: raftColorAt(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _raftColors[seat] == c ? RT.ink : Colors.transparent,
                      width: 3,
                    ),
                  ),
                ),
              ),
          ],
        ),
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
    final save = SaveService.instance.data;
    // Campaign upgrades pay off everywhere, not just in campaign battles —
    // same principle as XP-unlocked weapons not being campaign-exclusive.
    // Local 2P is hot-seat on one shared account, so both seats get it;
    // vs-AI only the human side does.
    final localBoth = widget.mode == 'local';
    final settings = MatchSettings(
      map: _map,
      startHp: _startHp,
      turnSeconds: _turnSeconds,
      enabledWeapons: _weapons.toList(),
      startHpPerPlayer: [
        _startHp + save.bonusHp,
        localBoth ? _startHp + save.bonusHp : _startHp,
      ],
      ammo: save.battleAmmo(),
    );

    RaftLoadout seatLoadout(int seat) => RaftLoadout.custom(
          hullId: _hullIds[seat],
          sizeId: _sizeIds[seat],
          colorIndex: _raftColors[seat],
        );

    final List<PlayerConfig> players;
    if (widget.mode == 'ai') {
      players = [
        PlayerConfig(
          name: 'YOU',
          loadout: seatLoadout(0),
          powerMultiplier: save.powerMultiplier,
        ),
        PlayerConfig(
          name: _aiNames[_aiLevel],
          loadout: RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: 7),
          look: CrewLook.pirate,
          isAi: true,
          aiDifficulty: AiDifficulty.values[_aiLevel],
        ),
      ];
    } else {
      players = [
        PlayerConfig(name: 'PLAYER 1', loadout: seatLoadout(0), powerMultiplier: save.powerMultiplier),
        PlayerConfig(name: 'PLAYER 2', loadout: seatLoadout(1), powerMultiplier: save.powerMultiplier),
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
