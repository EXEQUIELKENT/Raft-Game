import 'package:flutter/material.dart';
import '../game/audio.dart';
import '../game/models.dart';
import '../game/save.dart';
import '../theme.dart';

class ArmoryScreen extends StatelessWidget {
  const ArmoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final level = SaveService.instance.data.level;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: RT.sunset),
        child: SafeArea(
          child: Column(
            children: [
              _header(context, 'ARMORY'),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: Weapons.all.length,
                  itemBuilder: (_, i) {
                    final w = Weapons.all[i];
                    final locked = w.levelLock > level;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: RT.card(color: locked ? Colors.grey.shade300 : Colors.white),
                      child: Row(
                        children: [
                          Container(
                            width: 52, height: 52,
                            decoration: RT.card(color: locked ? Colors.grey : w.color, radius: 14, border: 3),
                            child: Icon(locked ? Icons.lock : w.icon, color: Colors.white, size: 26),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(w.name, style: RT.chunky(size: 16, color: RT.ink)),
                                Text(w.desc, style: RT.chunky(size: 10, color: RT.ink.withOpacity(0.65), weight: FontWeight.w600, letterSpacing: 0.2)),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    _stat('DMG', w.damage / 60, RT.red),
                                    _stat('SPD', w.speed / 1.4, RT.blue),
                                    _stat('KB', w.knockback / 3.2, RT.orange),
                                    _stat('BLD', w.structDamage / 2.6, RT.purple),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (locked)
                            Text('LVL\n${w.levelLock}', style: RT.chunky(size: 13, color: Colors.grey), textAlign: TextAlign.center),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, double frac, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: RT.chunky(size: 8, color: RT.ink.withOpacity(0.6))),
          Container(
            height: 7,
            margin: const EdgeInsets.only(right: 6, top: 2),
            decoration: BoxDecoration(
              color: RT.ink.withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: FractionallySizedBox(
              widthFactor: frac.clamp(0.05, 1.0),
              alignment: Alignment.centerLeft,
              child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _header(BuildContext context, String title) {
  return Padding(
    padding: const EdgeInsets.all(10),
    child: Row(
      children: [
        GestureDetector(
          onTap: () {
            AudioService.instance.sfx('click');
            Navigator.pop(context);
          },
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: RT.card(color: Colors.white, radius: 12, border: 3),
            child: const Icon(Icons.arrow_back, color: RT.ink),
          ),
        ),
        const SizedBox(width: 10),
        Text(title, style: RT.chunky(size: 26, outline: 3)),
      ],
    ),
  );
}
