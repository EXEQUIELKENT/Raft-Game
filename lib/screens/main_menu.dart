import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../game/audio.dart';
import '../game/save.dart';
import '../theme.dart';
import 'armory_screen.dart';
import 'campaign_screen.dart';
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

class _MainMenuScreenState extends State<MainMenuScreen> with TickerProviderStateMixin {
  late AnimationController _bob;
  late AnimationController _drift;

  @override
  void initState() {
    super.initState();
    AudioService.instance.playMusic('music_menu');
    _bob = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat(reverse: true);
    _drift = AnimationController(vsync: this, duration: const Duration(seconds: 26))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _bob.dispose();
    _drift.dispose();
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
              // drifting clouds
              AnimatedBuilder(
                animation: _drift,
                builder: (_, __) => Stack(
                  children: [
                    Positioned(top: 20, left: 40 + _drift.value * 26, child: const _Cloud(width: 150, opacity: 0.9)),
                    Positioned(top: 6, right: 160 - _drift.value * 40, child: const _Cloud(width: 104, opacity: 0.65)),
                  ],
                ),
              ),
              // decorative waves along the bottom
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: AnimatedBuilder(
                  animation: _bob,
                  builder: (_, __) => CustomPaint(
                    size: Size(MediaQuery.of(context).size.width, 110),
                    painter: _WavePainter(_bob.value),
                  ),
                ),
              ),
              // pirate mascot, bottom-right
              Positioned(
                right: 26,
                bottom: 46,
                child: AnimatedBuilder(
                  animation: _bob,
                  builder: (_, child) => Transform.translate(offset: Offset(0, -4 + _bob.value * 8), child: child),
                  child: const _PirateMascot(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 10),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                        child: IntrinsicHeight(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('PHYSICS ARTILLERY · HIGH SEAS',
                                  style: RT.body(size: 11, color: RT.ink.withOpacity(0.55), weight: FontWeight.w800, letterSpacing: 3)),
                              const SizedBox(height: 4),
                              Text('RAFT', style: RT.chunky(size: 52, color: Colors.white, outline: 4)),
                              Transform.translate(
                                offset: const Offset(0, -10),
                                child: Text('RUMBLE', style: RT.chunky(size: 52, color: RT.yellow, outline: 4)),
                              ),
                              const SizedBox(height: 10),
                              _statBadge(save),
                              const SizedBox(height: 20),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  ChunkyButton(
                                    label: 'CAMPAIGN', icon: Icons.map, color: RT.orange, width: 230, height: 62, fontSize: 22,
                                    onPressed: () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const CampaignScreen()))),
                                  ),
                                  const SizedBox(width: 16),
                                  Text('DRAG TO AIM\nBUILD & BATTLE',
                                      style: RT.body(size: 11, color: RT.ink.withOpacity(0.7), weight: FontWeight.w800, letterSpacing: 1.6)),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _secondaryBtn('PLAY VS AI', Icons.smart_toy,
                                      () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const MatchSetupScreen(mode: 'ai'))))),
                                  _secondaryBtn('LOCAL 2P', Icons.people,
                                      () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const MatchSetupScreen(mode: 'local'))))),
                                  _secondaryBtn('HOTSPOT', Icons.wifi_tethering,
                                      () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const HotspotScreen())))),
                                ],
                              ),
                              const SizedBox(height: 18),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _iconChip('ARMORY', Icons.gps_fixed, RT.purple, () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const ArmoryScreen())))),
                                  _iconChip('CHARACTERS', Icons.face, RT.pink, () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const CharactersScreen())))),
                                  _iconChip('MAPS', Icons.public, RT.sea2, () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const MapsScreen())))),
                                  _iconChip('STATS', Icons.bar_chart, RT.red, () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const StatsScreen())))),
                                  _iconChip('SETTINGS', Icons.settings, const Color(0xFF5C7A85), () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())))),
                                ],
                              ),
                            ],
                          ),
                        ),
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

  Widget _statBadge(SaveData save) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: RT.pill(radius: 26),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, color: RT.orange, size: 18),
          const SizedBox(width: 5),
          Text('LVL ${save.level}', style: RT.body(size: 13, color: RT.ink, weight: FontWeight.w800)),
          const SizedBox(width: 12),
          const Icon(Icons.emoji_events, color: RT.yellow, size: 18),
          const SizedBox(width: 5),
          Text('${save.wins} WINS', style: RT.body(size: 13, color: RT.ink, weight: FontWeight.w800)),
          const SizedBox(width: 12),
          const Text('◉', style: TextStyle(color: RT.yellow, fontSize: 15, fontWeight: FontWeight.w900)),
          const SizedBox(width: 5),
          Text('${save.doubloons}', style: RT.body(size: 13, color: RT.ink, weight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _secondaryBtn(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(color: Color(0x33000000), offset: Offset(0, 4))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: RT.ink, size: 18),
            const SizedBox(width: 8),
            Text(label, style: RT.chunky(size: 14, color: RT.ink)),
          ],
        ),
      ),
    );
  }

  Widget _iconChip(String label, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [BoxShadow(color: Color(0x33000000), offset: Offset(0, 3))],
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 3),
            Text(label, style: RT.body(size: 10, color: Colors.white, weight: FontWeight.w800, letterSpacing: 0.6), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Simple CSS-cloud-style decoration: a few overlapping soft-white circles.
class _Cloud extends StatelessWidget {
  final double width;
  final double opacity;
  const _Cloud({required this.width, this.opacity = 0.85});

  @override
  Widget build(BuildContext context) {
    final h = width * 0.36;
    return SizedBox(
      width: width * 1.3,
      height: h * 1.6,
      child: Stack(
        children: [
          Positioned(left: 0, top: h * 0.3, child: _blob(width * 0.62, h)),
          Positioned(left: width * 0.32, top: 0, child: _blob(width * 0.5, h * 0.86)),
          Positioned(left: width * 0.62, top: h * 0.22, child: _blob(width * 0.42, h * 0.7)),
        ],
      ),
    );
  }

  Widget _blob(double w, double h) => Container(
        width: w,
        height: h,
        decoration: BoxDecoration(color: Colors.white.withOpacity(opacity), borderRadius: BorderRadius.circular(h)),
      );
}

/// Decorative pirate-on-raft illustration built from plain shapes — no
/// image assets, matching the rest of the app's procedurally-drawn look.
class _PirateMascot extends StatelessWidget {
  const _PirateMascot();

  static const _skin = Color(0xFFEFD79F);
  static const _brow = Color(0xFF7A6540);
  static const _nose = Color(0xFFDCC48B);
  static const _mouth = Color(0xFFB9955C);
  static const _vest = Color(0xFF2D4F8F);
  static const _ring = Color(0xFFFF8A3D);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 150,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 66,
            height: 66,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: _skin,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), offset: const Offset(-6, -6), blurRadius: 0)],
                  ),
                ),
                Positioned(left: 12, top: -4, child: _bar(16, 4, _brow, -0.24)),
                Positioned(right: 12, top: -5, child: _bar(16, 4, _brow, 0.14)),
                Positioned(left: 6, top: 20, child: _eye()),
                Positioned(right: 6, top: 20, child: _eye()),
                Positioned(left: 27, top: 36, child: Container(width: 10, height: 8, decoration: const BoxDecoration(color: _nose, shape: BoxShape.circle))),
                Positioned(left: 22, top: 48, child: _bar(20, 4, _mouth, 0)),
              ],
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -5),
            child: Container(
              width: 44, height: 30,
              decoration: const BoxDecoration(color: _vest, borderRadius: BorderRadius.vertical(top: Radius.circular(11), bottom: Radius.circular(4))),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -9),
            child: Container(
              width: 128, height: 34,
              decoration: BoxDecoration(
                color: _ring,
                borderRadius: BorderRadius.circular(34),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.14), offset: const Offset(0, -9))],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(double w, double h, Color c, double rot) => Transform.rotate(
        angle: rot,
        child: Container(width: w, height: h, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
      );

  Widget _eye() => Container(
        width: 18, height: 21,
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            width: 8, height: 8,
            decoration: const BoxDecoration(color: RT.ink, shape: BoxShape.circle),
          ),
        ),
      );
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
