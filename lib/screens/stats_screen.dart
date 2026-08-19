import 'dart:math';
import 'package:flutter/material.dart';
import '../game/save.dart';
import '../theme.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final d = SaveService.instance.data;
    final winRate = d.wins + d.losses > 0 ? (d.wins / (d.wins + d.losses) * 100).round() : 0;
    final xpFrac = d.level >= 10 ? 1.0 : ((d.xp - d.xpForCurrent) / max(1, d.xpForNext - d.xpForCurrent));

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
                    Text('STATS & PROGRESS', style: RT.chunky(size: 22, outline: 3)),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    // level card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: RT.card(color: RT.yellow),
                      child: Column(
                        children: [
                          Text('LEVEL ${d.level}', style: RT.chunky(size: 30, color: RT.ink)),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: LinearProgressIndicator(
                              value: xpFrac.clamp(0.0, 1.0),
                              minHeight: 16,
                              backgroundColor: RT.ink.withOpacity(0.15),
                              valueColor: const AlwaysStoppedAnimation(RT.orange),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(d.level >= 10 ? 'MAX LEVEL!' : '${d.xp} / ${d.xpForNext} XP',
                              style: RT.chunky(size: 12, color: RT.ink.withOpacity(0.7))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _statCard('WINS', '${d.wins}', RT.green, Icons.emoji_events),
                        _statCard('LOSSES', '${d.losses}', RT.red, Icons.heart_broken),
                        _statCard('WIN RATE', '$winRate%', RT.blue, Icons.percent),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _statCard('SHOTS', '${d.shotsFired}', RT.orange, Icons.gps_fixed),
                        _statCard('DAMAGE', '${d.totalDamage}', RT.purple, Icons.flash_on),
                        _statCard('RAFT TIER', '${d.raftTier + 1}', RT.pink, Icons.sailing),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('ACHIEVEMENTS', style: RT.chunky(size: 18, outline: 2.5)),
                    const SizedBox(height: 8),
                    ...SaveService.achievementInfo.entries.map((e) {
                      final unlocked = d.achievements.contains(e.key);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: RT.card(color: unlocked ? RT.yellow : Colors.white),
                        child: Row(
                          children: [
                            Icon(unlocked ? Icons.military_tech : Icons.lock_outline,
                                color: unlocked ? RT.orange : Colors.grey, size: 30),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(e.value['name']!, style: RT.chunky(size: 15, color: RT.ink)),
                                  Text(e.value['desc']!, style: RT.chunky(size: 11, color: RT.ink.withOpacity(0.6), weight: FontWeight.w600, letterSpacing: 0.3)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                    Text('MATCH HISTORY', style: RT.chunky(size: 18, outline: 2.5)),
                    const SizedBox(height: 8),
                    if (d.matchHistory.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: RT.card(),
                        child: Text('No matches yet — go rumble!', style: RT.chunky(size: 14, color: RT.ink.withOpacity(0.6)), textAlign: TextAlign.center),
                      )
                    else
                      ...d.matchHistory.take(10).map((m) => Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: RT.card(color: Colors.white),
                            child: Row(
                              children: [
                                Icon(m['won'] == true ? Icons.emoji_events : Icons.close,
                                    color: m['won'] == true ? RT.green : RT.red, size: 22),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text('${m['map']} • ${m['mode']}',
                                      style: RT.chunky(size: 13, color: RT.ink)),
                                ),
                                Text('${m['date']}', style: RT.chunky(size: 10, color: RT.ink.withOpacity(0.5))),
                              ],
                            ),
                          )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statCard(String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(12),
        decoration: RT.card(),
        child: Column(
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: 4),
            Text(value, style: RT.chunky(size: 20, color: RT.ink)),
            Text(label, style: RT.chunky(size: 9, color: RT.ink.withOpacity(0.6))),
          ],
        ),
      ),
    );
  }
}
