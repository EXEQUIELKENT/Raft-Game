import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../game/audio.dart';
import '../game/character_art.dart';
import '../game/characters.dart';
import '../game/save.dart';
import '../theme.dart';
import 'armory_screen.dart';
import 'campaign_screen.dart';
import 'characters_screen.dart';
import 'maps_screen.dart';
import 'match_setup_screen.dart';
import 'hotspot_screen.dart';
import 'online_screen.dart';
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
                  child: const MenuMascot(),
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
                                  _secondaryBtn('ONLINE', Icons.public,
                                      () => _tap(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const OnlineScreen())))),
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

/// The menu mascot: the player's OWN captain, on a raft.
///
/// It used to be a hand-assembled stack of [Container]s — a plain circle, two
/// floating eyebrow bars, a nose dot, a rectangle for a body and an orange
/// pill for a tube — put together before the crew art existed in its current
/// form. It had drifted into looking like nothing in the game: no hat, no
/// character, no relation to the person you actually play.
///
/// This draws the same character the battle draws, through the same
/// [CharacterArt] the roster picker uses, from the look saved in
/// [SaveData.character]. Two things follow from that, and both are the point:
/// the menu shows whoever the player has equipped, and it can never go stale
/// again, because there is no second copy of the art to fall behind.
class MenuMascot extends StatelessWidget {
  /// Whose captain to draw. Defaults to the one the player has equipped,
  /// which is the whole point of it on the menu; naming one is for tests
  /// and for any screen that wants to show a specific character.
  final CrewLook? look;

  const MenuMascot({super.key, this.look});

  @override
  Widget build(BuildContext context) {
    final look = this.look ??
        Cast.byId(SaveService.instance.data.character).look;
    return SizedBox(
      width: 150,
      height: 168,
      child: CustomPaint(painter: _MascotPainter(look)),
    );
  }
}

class _MascotPainter extends CustomPainter {
  final CrewLook look;
  const _MascotPainter(this.look);

  @override
  void paint(Canvas canvas, Size size) {
    final ch = Cast.of(look);
    final w = size.width, h = size.height;
    final cx = w * 0.5;

    // Chunky ink keyline, the same one the buttons and cards use, so the
    // mascot belongs to this UI rather than to the battle canvas.
    final line = Paint()
      ..color = RT.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeJoin = StrokeJoin.round;

    // The raft under them, so they are standing on something. Drawn first
    // and low, because the character is what the eye should land on.
    final deckY = h * 0.80;
    final raft = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, deckY), width: w * 0.92, height: 20),
      const Radius.circular(8),
    );
    canvas.drawRRect(raft, Paint()..color = const Color(0xFF9A6438));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, deckY + 6), width: w * 0.92, height: 8),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFF6B4525),
    );
    final seam = Paint()
      ..color = const Color(0xFF6B4525)
      ..strokeWidth = 2;
    for (final f in [-0.30, -0.10, 0.10, 0.30]) {
      canvas.drawLine(Offset(cx + w * f, deckY - 10),
          Offset(cx + w * f, deckY + 9), seam);
    }
    canvas.drawRRect(raft, line);

    // Arms, behind the torso: one raised in a wave, because the mascot is
    // greeting you and a mascot with both arms down reads as a mugshot.
    final limb = Paint()
      ..color = ch.outfit
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11
      ..strokeCap = StrokeCap.round;
    final limbLine = Paint()
      ..color = RT.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15
      ..strokeCap = StrokeCap.round;
    final shoulderL = Offset(cx - w * 0.15, h * 0.60);
    final shoulderR = Offset(cx + w * 0.15, h * 0.60);
    final handUp = Offset(cx + w * 0.33, h * 0.40);
    final handDown = Offset(cx - w * 0.25, h * 0.72);
    for (final pair in [(shoulderR, handUp), (shoulderL, handDown)]) {
      canvas.drawLine(pair.$1, pair.$2, limbLine);
    }
    for (final pair in [(shoulderR, handUp), (shoulderL, handDown)]) {
      canvas.drawLine(pair.$1, pair.$2, limb);
    }
    for (final hand in [handUp, handDown]) {
      canvas.drawCircle(hand, 7.5, Paint()..color = RT.ink);
      canvas.drawCircle(hand, 5.5, Paint()..color = ch.skin);
    }

    // Torso, with the character's own sash across it.
    final torso = RRect.fromRectAndCorners(
      Rect.fromCenter(center: Offset(cx, h * 0.70), width: w * 0.40, height: h * 0.26),
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: const Radius.circular(5),
      bottomRight: const Radius.circular(5),
    );
    canvas.drawRRect(torso, Paint()..color = ch.outfit);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, h * 0.68), width: w * 0.40, height: 8),
        const Radius.circular(4),
      ),
      Paint()..color = ch.accent,
    );
    canvas.drawRRect(torso, line);

    // The head — cartoon-large, which is the proportion the crew use too.
    final headR = w * 0.235;
    final headC = Offset(cx, h * 0.36);
    canvas.drawCircle(headC, headR, Paint()..color = ch.skin);
    canvas.drawArc(
      Rect.fromCircle(center: headC, radius: headR),
      0.35, pi * 0.7, false,
      Paint()
        ..color = Colors.black.withOpacity(0.07)
        ..style = PaintingStyle.stroke
        ..strokeWidth = headR * 0.22,
    );
    canvas.drawCircle(headC, headR, line);

    // A cheerful resting face. The battle's expression system is driven by
    // combat state, and a menu has none — so this is the one place the
    // expression is a constant rather than a reading.
    final ink = Paint()..color = RT.ink;
    for (final s in [-1.0, 1.0]) {
      canvas.drawCircle(headC + Offset(s * headR * 0.36, -headR * 0.06), headR * 0.16, ink);
      canvas.drawCircle(headC + Offset(s * headR * 0.36 + headR * 0.06, -headR * 0.13),
          headR * 0.055, Paint()..color = Colors.white);
    }
    canvas.drawArc(
      Rect.fromCenter(
          center: headC + Offset(0, headR * 0.36),
          width: headR * 0.78,
          height: headR * 0.5),
      0.2, 2.74, false,
      Paint()
        ..color = RT.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = headR * 0.12
        ..strokeCap = StrokeCap.round,
    );

    // Hat last, from the shared painter — the whole reason this is drawn
    // rather than assembled.
    CharacterArt.headgear(canvas, look, headC, headR, 1);
  }

  @override
  bool shouldRepaint(covariant _MascotPainter old) => old.look != look;
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
