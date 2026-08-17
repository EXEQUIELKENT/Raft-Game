import 'package:flutter/material.dart';
import '../game/maps.dart';
import '../game/save.dart';
import '../theme.dart';

class MapsScreen extends StatelessWidget {
  const MapsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final level = SaveService.instance.data.level;
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
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: RT.card(color: Colors.white, radius: 12, border: 3),
                        child: const Icon(Icons.arrow_back, color: RT.ink),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('MAPS', style: RT.chunky(size: 26, outline: 3)),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: GameMaps.all.length,
                  itemBuilder: (_, i) {
                    final m = GameMaps.all[i];
                    final locked = m.levelLock > level;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: RT.card(color: locked ? Colors.grey.shade300 : Colors.white),
                      child: Column(
                        children: [
                          Container(
                            height: 70,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: locked ? [Colors.grey, Colors.grey.shade400] : m.sky),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                              border: const Border(bottom: BorderSide(color: RT.ink, width: 4)),
                            ),
                            child: Center(
                              child: Icon(locked ? Icons.lock : m.icon, size: 36, color: Colors.white),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(m.name, style: RT.chunky(size: 17, color: RT.ink)),
                                      Text(m.tagline, style: RT.chunky(size: 11, color: RT.ink.withOpacity(0.6), weight: FontWeight.w600, letterSpacing: 0.3)),
                                    ],
                                  ),
                                ),
                                if (locked)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: RT.card(color: RT.ink, radius: 10, border: 0),
                                    child: Text('LVL ${m.levelLock}', style: RT.chunky(size: 12, color: Colors.white)),
                                  )
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: RT.card(color: RT.green, radius: 10, border: 3),
                                    child: Text('OPEN', style: RT.chunky(size: 12, color: Colors.white)),
                                  ),
                              ],
                            ),
                          ),
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
}
