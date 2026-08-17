import 'package:flutter/material.dart';
import '../game/audio.dart';
import '../game/save.dart';
import '../theme.dart';

class CharactersScreen extends StatefulWidget {
  const CharactersScreen({super.key});

  @override
  State<CharactersScreen> createState() => _CharactersScreenState();
}

class _CharactersScreenState extends State<CharactersScreen> {
  static const _hats = ['Bandana', 'Captain Hat', 'Propeller Cap', 'Viking Helm', 'Fish Hat'];
  static const _colors = ['Ruby Red', 'Ocean Blue', 'Leaf Green', 'Sunny Amber'];

  /// Persists the chosen hat/color before leaving the screen. Used by both
  /// the custom back arrow and the system back button/gesture (via
  /// PopScope) so neither path can discard an unsaved selection.
  void _saveAndPop() {
    AudioService.instance.sfx('click');
    SaveService.instance.save();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final save = SaveService.instance.data;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _saveAndPop();
      },
      child: Scaffold(
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
                        onTap: _saveAndPop,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: RT.card(color: Colors.white, radius: 12, border: 3),
                          child: const Icon(Icons.arrow_back, color: RT.ink),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('YOUR CHARACTER', style: RT.chunky(size: 24, outline: 3)),
                    ],
                  ),
                ),
                // preview
                Container(
                  margin: const EdgeInsets.all(14),
                  padding: const EdgeInsets.all(20),
                  decoration: RT.card(),
                  child: Column(
                    children: [
                      Container(
                        width: 110, height: 110,
                        decoration: BoxDecoration(
                          color: RT.playerColors[save.colorIndex % 4],
                          shape: BoxShape.circle,
                          border: Border.all(color: RT.ink, width: 5),
                        ),
                        child: Icon(Icons.face, size: 60, color: Colors.white.withOpacity(0.9)),
                      ),
                      const SizedBox(height: 8),
                      Text('${_hats[save.hatIndex % 5]} • ${_colors[save.colorIndex % 4]}',
                          style: RT.chunky(size: 14, color: RT.ink)),
                    ],
                  ),
                ),
                Text('HATS', style: RT.chunky(size: 16, outline: 2.5)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10, runSpacing: 10,
                  children: [
                    for (int i = 0; i < _hats.length; i++)
                      _opt(_hats[i], save.hatIndex == i, () {
                        setState(() => save.hatIndex = i);
                      }),
                  ],
                ),
                const SizedBox(height: 18),
                Text('COLORS', style: RT.chunky(size: 16, outline: 2.5)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10, runSpacing: 10,
                  children: [
                    for (int i = 0; i < 4; i++)
                      GestureDetector(
                        onTap: () {
                          AudioService.instance.sfx('click');
                          setState(() => save.colorIndex = i);
                        },
                        child: Container(
                          width: 56, height: 56,
                          decoration: BoxDecoration(
                            color: RT.playerColors[i],
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: save.colorIndex == i ? RT.yellow : RT.ink,
                              width: save.colorIndex == i ? 5 : 3,
                            ),
                          ),
                          child: save.colorIndex == i ? const Icon(Icons.check, color: Colors.white) : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _opt(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx('click');
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: RT.card(color: selected ? RT.pink : Colors.white, radius: 14, border: 3),
        child: Text(label, style: RT.chunky(size: 12, color: selected ? Colors.white : RT.ink)),
      ),
    );
  }
}
