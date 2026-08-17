import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../game/audio.dart';
import '../game/save.dart';
import '../theme.dart';
import 'armory_screen.dart';
import 'characters_screen.dart';
import 'maps_screen.dart';
import 'match_setup_screen.dart';
import 'hotspot_screen.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';

class MainMenuScreen extends StatefulWidget {
  const MainMenuScreen({super.key});

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen> with SingleTickerProviderStateMixin {
  late AnimationController _bob;

  @override
  void initState() {
    super.initState();
    AudioService.instance.playMusic('music_menu');
    _bob = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  void _tap(VoidCallback go) {
    AudioService.instance.sfx('click');
    if (SaveService.instance.data.vibration) HapticFeedback.lightImpact();
    go();
  }

  @override
  Widget build(BuildContext context) {
    final save = SaveService.instance.data;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: RT.sunset),
        child: SafeArea(
          child: Stack(
            children: [
              // decorative waves
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: AnimatedBuilder(
                  animation: _bob,
                  builder: (_, __) => CustomPaint(
                    size: Size(MediaQuery.of(context).size.width, 120),
                    painter: _WavePainter(_bob.value),
                  ),
                ),
              ),
              Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 12),
                      // Logo with starburst
                      AnimatedBuilder(
                        animation: _bob,
                        builder: (_, child) => Transform.translate(
                          offset: Offset(0, -6 + _bob.value * 12),
                          child: Transform.rotate(
                            angle: -0.03 + _bob.value * 0.04,
                            child: child,
                          ),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            const SizedBox(
                              width: 300, height: 200,
                              child: CustomPaint(painter: StarburstPainter(color: RT.yellow, points: 16)),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('RAFT', style: RT.chunky(size: 58, color: Colors.white, outline: 5)),
                                Text('RUMBLE', style: RT.chunky(size: 58, color: RT.yellow, outline: 5)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // player badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                        decoration: RT.card(color: RT.cream, radius: 30, border: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star, color: RT.orange, size: 22),
                            const SizedBox(width: 6),
                            Text('LVL ${save.level}', style: RT.chunky(size: 16, color: RT.ink)),
                            const SizedBox(width: 14),
                            const Icon(Icons.emoji_events, color: RT.yellow, size: 22),
                            const SizedBox(width: 6),
                            Text('${save.wins} WINS', style: RT.chunky(size: 16, color: RT.ink)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      ChunkyButton(
                        label: 'PLAY VS AI', icon: Icons.smart_toy, color: RT.orange,
                        onPressed: () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const MatchSetupScreen(mode: 'ai')))),
                      ),
                      const SizedBox(height: 14),
                      ChunkyButton(
                        label: 'LOCAL 2P', icon: Icons.people, color: RT.green,
                        onPressed: () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const MatchSetupScreen(mode: 'local')))),
                      ),
                      const SizedBox(height: 14),
                      ChunkyButton(
                        label: 'HOTSPOT GAME', icon: Icons.wifi_tethering, color: RT.blue,
                        onPressed: () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const HotspotScreen()))),
                      ),
                      const SizedBox(height: 22),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.center,
                        children: [
                          _smallBtn('ARMORY', Icons.gps_fixed, RT.purple, () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const ArmoryScreen())))),
                          _smallBtn('CHARACTER', Icons.face, RT.pink, () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const CharactersScreen())))),
                          _smallBtn('MAPS', Icons.map, RT.sea1, () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapsScreen())))),
                          _smallBtn('STATS', Icons.bar_chart, RT.red, () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const StatsScreen())))),
                          _smallBtn('SETTINGS', Icons.settings, const Color(0xFF607D8B), () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())))),
                        ],
                      ),
                      const SizedBox(height: 40),
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

  Widget _smallBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 104,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: RT.card(color: color, radius: 16, border: 3),
        child: Column(
          children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(height: 4),
            Text(label, style: RT.chunky(size: 12, color: Colors.white, outline: 1.5), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final double t;
  _WavePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = RT.sea1.withOpacity(0.75);
    final path = Path()..moveTo(0, size.height);
    for (double x = 0; x <= size.width; x += 10) {
      final y = 30 + (x / size.width) * 10 + (x / 60 + t * 6).remainder(6) * 2;
      path.lineTo(x, y);
    }
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, paint);
    final paint2 = Paint()..color = RT.sea2.withOpacity(0.9);
    final path2 = Path()..moveTo(0, size.height);
    for (double x = 0; x <= size.width; x += 10) {
      final y = 55 + (x / 45 - t * 5).remainder(8);
      path2.lineTo(x, y);
    }
    path2.lineTo(size.width, size.height);
    path2.close();
    canvas.drawPath(path2, paint2);
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.t != t;
}
