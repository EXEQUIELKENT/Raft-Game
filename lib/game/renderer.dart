import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'battle.dart';
import 'maps.dart';

/// ---------------------------------------------------------------------------
/// Scene renderer, drawn in the flat-vector style of the Claude Design mockup:
/// a sky-to-sand-to-sea gradient, drifting clouds, a few horizon props, and
/// big-headed crew sitting on their rafts.
///
/// The world is [BattleConst.worldW] x [BattleConst.worldH] in design units.
/// The canvas is scaled so the full world height always fits the screen, and
/// panned horizontally by the camera — which is why the visible width varies
/// with device aspect and is fed back into the world as `viewWidth`.
/// ---------------------------------------------------------------------------
class WorldRenderer {
  final BattleWorld world;
  final MapDef map;

  /// Decoration positions, generated once per world from its seed so props
  /// don't twitch between frames.
  final List<_Prop> _props = [];
  final List<_Cloud> _clouds = [];
  bool _decorBuilt = false;

  WorldRenderer(this.world, {required this.map});

  void render(Canvas canvas, Size size, double time) {
    final scale = size.height / BattleConst.worldH;
    world.viewWidth = size.width / scale;
    if (!_decorBuilt) _buildDecor();

    canvas.save();
    canvas.scale(scale);
    canvas.translate(-world.cam, 0);

    _drawSky(canvas, time);
    _drawClouds(canvas, time);
    _drawProps(canvas, time);
    _drawWater(canvas, time);
    _drawRafts(canvas, time);
    _drawShot(canvas);
    _drawEffects(canvas);

    canvas.restore();
  }

  // ---------------------------------------------------------------------------
  // Decoration
  // ---------------------------------------------------------------------------

  void _buildDecor() {
    _decorBuilt = true;
    final rng = world.rng;
    // Keep props clear of the player raft and the enemy slots so nothing ever
    // draws on top of a crew member.
    final reserved = <double>[BattleConst.playerX, ...BattleConst.enemySlots];
    bool clear(double x) => reserved.every((r) => (x - r).abs() > 130);

    for (int i = 0; i < 7; i++) {
      final kind = map.props[rng.nextInt(map.props.length)];
      double x = 0;
      for (int tries = 0; tries < 12; tries++) {
        x = rng.range(280, BattleConst.worldW - 180);
        if (clear(x)) break;
      }
      if (!clear(x)) continue;
      _props.add(_Prop(kind: kind, x: x, scale: rng.range(0.78, 1.25), phase: rng.range(0, pi * 2)));
    }
    for (int i = 0; i < 8; i++) {
      _clouds.add(_Cloud(
        x: rng.range(0, BattleConst.worldW),
        y: rng.range(24, 110),
        w: rng.range(90, 165),
        opacity: rng.range(0.55, 0.95),
        speed: rng.range(2.5, 7.0),
      ));
    }
  }

  // ---------------------------------------------------------------------------
  // Sky / water
  // ---------------------------------------------------------------------------

  void _drawSky(Canvas canvas, double time) {
    final rect = Rect.fromLTWH(world.cam - 40, 0, world.viewWidth + 80, BattleConst.waterY + 4);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: map.sky,
        ).createShader(rect),
    );
  }

  void _drawClouds(Canvas canvas, double time) {
    for (final c in _clouds) {
      // Slow horizontal drift, wrapped so clouds never run out.
      final x = (c.x + time * c.speed) % (BattleConst.worldW + 400) - 200;
      final paint = Paint()..color = Colors.white.withOpacity(c.opacity);
      final h = c.w * 0.34;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, c.y, c.w * 0.62, h), Radius.circular(h)),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + c.w * 0.3, c.y - h * 0.34, c.w * 0.5, h * 0.9), Radius.circular(h)),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + c.w * 0.6, c.y - h * 0.1, c.w * 0.42, h * 0.75), Radius.circular(h)),
        paint,
      );
    }
  }

  void _drawWater(Canvas canvas, double time) {
    final top = BattleConst.waterY;
    final rect = Rect.fromLTWH(world.cam - 40, top, world.viewWidth + 80, BattleConst.worldH - top);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [map.water, map.waterDeep],
        ).createShader(rect),
    );

    // Two offset wave lines along the surface for a bit of motion.
    for (int layer = 0; layer < 2; layer++) {
      final path = Path();
      final amp = (layer == 0 ? 3.4 : 2.2) * map.chop;
      final yBase = top + (layer == 0 ? 2.0 : 9.0);
      final speed = layer == 0 ? 34.0 : -22.0;
      final startX = world.cam - 40;
      path.moveTo(startX, yBase);
      for (double x = startX; x <= startX + world.viewWidth + 80; x += 14) {
        final y = yBase + sin((x + time * speed) / 46 + layer) * amp;
        path.lineTo(x, y);
      }
      path.lineTo(startX + world.viewWidth + 80, top + 26);
      path.lineTo(startX, top + 26);
      path.close();
      canvas.drawPath(path, Paint()..color = Colors.white.withOpacity(layer == 0 ? 0.22 : 0.12));
    }
  }

  void _drawProps(Canvas canvas, double time) {
    for (final p in _props) {
      canvas.save();
      canvas.translate(p.x, BattleConst.waterY);
      canvas.scale(p.scale);
      switch (p.kind) {
        case SceneProp.palm:
          _palm(canvas, time, p.phase);
          break;
        case SceneProp.hut:
          _hut(canvas);
          break;
        case SceneProp.rock:
          _rock(canvas);
          break;
        case SceneProp.iceberg:
          _iceberg(canvas);
          break;
        case SceneProp.wreck:
          _wreck(canvas);
          break;
        case SceneProp.cactus:
          _cactus(canvas);
          break;
        case SceneProp.ember:
          _emberStack(canvas, time, p.phase);
          break;
        case SceneProp.buoy:
          _buoy(canvas, time, p.phase);
          break;
        case SceneProp.rig:
          _rig(canvas);
          break;
        case SceneProp.crane:
          _crane(canvas);
          break;
      }
      canvas.restore();
    }
  }

  void _palm(Canvas canvas, double time, double phase) {
    final sway = sin(time * 0.9 + phase) * 0.05;
    canvas.save();
    canvas.rotate(0.12 + sway);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(-7, -128, 14, 128), const Radius.circular(7)),
      Paint()..color = const Color(0xFF8A5F35),
    );
    canvas.restore();
    final canopy = Paint()..color = const Color(0xFF2F7D43);
    canvas.drawOval(Rect.fromCenter(center: const Offset(2, -140), width: 92, height: 50), canopy);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(-24, -128), width: 58, height: 30),
      Paint()..color = const Color(0xFF357F49),
    );
  }

  void _hut(Canvas canvas) {
    canvas.drawRect(Rect.fromLTWH(-30, -58, 60, 58), Paint()..color = const Color(0xFFC79A62));
    final roof = Path()
      ..moveTo(-46, -58)
      ..lineTo(0, -96)
      ..lineTo(46, -58)
      ..close();
    canvas.drawPath(roof, Paint()..color = const Color(0xFF7C5A33));
  }

  void _rock(Canvas canvas) {
    canvas.drawPath(
      Path()
        ..moveTo(-56, 4)
        ..quadraticBezierTo(-40, -40, -6, -38)
        ..quadraticBezierTo(34, -36, 56, 4)
        ..close(),
      Paint()..color = const Color(0xFF9AA3A6),
    );
  }

  void _iceberg(Canvas canvas) {
    canvas.drawPath(
      Path()
        ..moveTo(-58, 4)
        ..lineTo(-18, -74)
        ..lineTo(10, -40)
        ..lineTo(34, -88)
        ..lineTo(62, 4)
        ..close(),
      Paint()..color = const Color(0xFFE3F1F7),
    );
  }

  void _wreck(Canvas canvas) {
    canvas.save();
    canvas.rotate(-0.18);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(-64, -30, 128, 30), const Radius.circular(8)),
      Paint()..color = const Color(0xFF6E4B2C),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(-6, -96, 10, 70), const Radius.circular(5)),
      Paint()..color = const Color(0xFF5A3D24),
    );
    canvas.restore();
  }

  void _cactus(Canvas canvas) {
    final g = Paint()..color = const Color(0xFF4F8C4A);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(-9, -104, 18, 104), const Radius.circular(9)), g);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(-34, -74, 25, 12), const Radius.circular(6)), g);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(-34, -74, 12, 34), const Radius.circular(6)), g);
  }

  void _emberStack(Canvas canvas, double time, double phase) {
    _rock(canvas);
    for (int i = 0; i < 3; i++) {
      final t = (time * 0.5 + phase + i * 0.33) % 1.0;
      canvas.drawCircle(
        Offset(-14 + i * 14, -40 - t * 70),
        3.2,
        Paint()..color = const Color(0xFFFF8A3D).withOpacity((1 - t) * 0.85),
      );
    }
  }

  void _buoy(Canvas canvas, double time, double phase) {
    final bob = sin(time * 1.6 + phase) * 4;
    canvas.translate(0, bob);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(-11, -34, 22, 40), const Radius.circular(10)),
      Paint()..color = RT.red,
    );
    canvas.drawRect(Rect.fromLTWH(-11, -20, 22, 8), Paint()..color = Colors.white);
  }

  void _rig(Canvas canvas) {
    final steel = Paint()..color = const Color(0xFF5E7381);
    canvas.drawRect(Rect.fromLTWH(-52, -20, 104, 14), steel);
    for (final dx in [-40.0, -12.0, 16.0, 40.0]) {
      canvas.drawRect(Rect.fromLTWH(dx, -20, 8, 26), steel);
    }
    canvas.drawRect(Rect.fromLTWH(-20, -74, 40, 54), Paint()..color = const Color(0xFF445965));
  }

  void _crane(Canvas canvas) {
    final steel = Paint()..color = const Color(0xFF4E6472);
    canvas.drawRect(Rect.fromLTWH(-8, -132, 16, 132), steel);
    canvas.drawRect(Rect.fromLTWH(-8, -132, 84, 12), steel);
    canvas.drawRect(Rect.fromLTWH(64, -120, 4, 40), steel);
  }

  // ---------------------------------------------------------------------------
  // Rafts + crew
  // ---------------------------------------------------------------------------

  void _drawRafts(Canvas canvas, double time) {
    for (final raft in world.rafts) {
      final bob = world.bobOf(raft);
      canvas.save();
      canvas.translate(raft.x, bob);

      _ripple(canvas, raft, time);
      if (raft.loadout.hull.hasMast) _mast(canvas, raft);
      _hull(canvas, raft);

      for (int i = 0; i < raft.crew.length; i++) {
        final c = raft.crew[i];
        if (c.gone) continue;
        canvas.save();
        // The body's own displacement from its station — a knocked-back crew
        // member is drawn wherever the shove actually put them.
        canvas.translate(raft.loadout.crewOffset(i) + c.offset.dx, c.offset.dy);
        if (c.tilt != 0) {
          // Tumble about the feet, not about the middle of the body.
          final pivot = raft.deckY;
          canvas.translate(0, pivot);
          canvas.rotate(c.tilt);
          canvas.translate(0, -pivot);
        }
        // Defeated crew slide down into the water and fade out.
        if (!c.alive) {
          canvas.translate(0, c.sinkT * 44);
          canvas.saveLayer(
            Rect.fromLTWH(-60, -140, 120, 200),
            Paint()..color = Colors.white.withOpacity(1 - c.sinkT),
          );
        }
        _crewMember(canvas, raft, c, i, time);
        if (!c.alive) canvas.restore();
        canvas.restore();
      }

      canvas.restore();

      if (raft.playerIndex != 0 && raft.alive) _enemyLabel(canvas, raft, bob);
    }
  }

  void _ripple(Canvas canvas, Raft raft, double time) {
    final w = raft.loadout.width;
    final t = (time * 0.55 + raft.x * 0.01) % 1.0;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(0, BattleConst.waterY + 4),
        width: w * (0.75 + t * 0.5),
        height: 13 * (0.75 + t * 0.5),
      ),
      Paint()..color = Colors.white.withOpacity(0.3 * (1 - t)),
    );
  }

  void _hull(Canvas canvas, Raft raft) {
    final lo = raft.loadout;
    final w = lo.width;
    final h = w * lo.hull.thickness;
    final top = BattleConst.waterY - h * 0.55;
    final rect = Rect.fromLTWH(-w / 2, top, w, h);
    final radius = Radius.circular(h * lo.hull.rounding.clamp(0.0, 1.0) * 0.5 + 3);

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..color = lo.color,
    );
    // Inner shade along the bottom, matching the mockup's inset shadow.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-w / 2, top + h * 0.58, w, h * 0.42),
        radius,
      ),
      Paint()..color = Colors.black.withOpacity(0.14),
    );
    // Plank seam on timber-style hulls.
    if (lo.hull.rounding < 0.5) {
      canvas.drawRect(
        Rect.fromLTWH(-w / 2 + 6, top + h * 0.36, w - 12, 3),
        Paint()..color = Colors.black.withOpacity(0.12),
      );
    }
  }

  void _mast(Canvas canvas, Raft raft) {
    final lo = raft.loadout;
    final baseY = BattleConst.waterY - lo.width * lo.hull.thickness * 0.5;
    final dir = raft.facing.toDouble();
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-4 - dir * 26, baseY - 118, 9, 118),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFF8A5F35),
    );
    final sail = Path()
      ..moveTo(-dir * 26, baseY - 104)
      ..lineTo(-dir * 26 + dir * 46, baseY - 78)
      ..lineTo(-dir * 26 + dir * 30, baseY - 26)
      ..lineTo(-dir * 26, baseY - 26)
      ..close();
    canvas.drawPath(sail, Paint()..color = const Color(0xFFF2ECC8));
  }

  void _crewMember(Canvas canvas, Raft raft, Crew crew, int index, double time) {
    final lo = raft.loadout;
    final deck = BattleConst.waterY - lo.width * lo.hull.thickness * 0.55;
    final headR = 22.0;
    final headC = Offset(0, deck - 34 + sin(time * 1.7 + crew.bobPhase) * 1.4);
    final dir = raft.facing.toDouble();

    // Torso
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(-13, headC.dy + headR - 4, 26, 22),
        topLeft: const Radius.circular(8),
        topRight: const Radius.circular(8),
        bottomLeft: const Radius.circular(3),
        bottomRight: const Radius.circular(3),
      ),
      Paint()..color = raft.playerIndex == 0 ? const Color(0xFF2D4F8F) : lo.color,
    );

    // Head
    final skin = _skinFor(raft.look);
    canvas.drawCircle(headC, headR, Paint()..color = skin);
    canvas.drawArc(
      Rect.fromCircle(center: headC, radius: headR),
      0.3, pi * 0.75, false,
      Paint()..color = Colors.black.withOpacity(0.06)..style = PaintingStyle.stroke..strokeWidth = 7,
    );

    // Brows
    final brow = Paint()
      ..color = const Color(0xFF8A7448)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(headC + const Offset(-13, -8), headC + const Offset(-4, -11), brow);
    canvas.drawLine(headC + const Offset(4, -11), headC + const Offset(13, -8), brow);

    // Eyes
    for (final ex in [-7.0, 7.0]) {
      canvas.drawOval(
        Rect.fromCenter(center: headC + Offset(ex, 0), width: 12, height: 14),
        Paint()..color = Colors.white,
      );
      if (crew.alive) {
        canvas.drawCircle(headC + Offset(ex + dir * 1.5, 2), 3.4, Paint()..color = RT.ink);
      } else {
        final xp = Paint()
          ..color = RT.ink
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(headC + Offset(ex - 3, -3), headC + Offset(ex + 3, 3), xp);
        canvas.drawLine(headC + Offset(ex + 3, -3), headC + Offset(ex - 3, 3), xp);
      }
    }

    // Nose + mouth
    canvas.drawOval(
      Rect.fromCenter(center: headC + const Offset(0, 9), width: 8, height: 6),
      Paint()..color = const Color(0xFFDCC48B),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: headC + const Offset(0, 16), width: 15, height: 4),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFFB9955C),
    );

    _headgear(canvas, raft.look, headC, headR, dir);
  }

  Color _skinFor(CrewLook look) => switch (look) {
        CrewLook.player => const Color(0xFFEFD79F),
        CrewLook.raider => const Color(0xFFE8C98C),
        CrewLook.ducker => const Color(0xFFEFD79F),
        CrewLook.pirate => const Color(0xFFE0BD7C),
        CrewLook.captain => const Color(0xFFDCB877),
      };

  void _headgear(Canvas canvas, CrewLook look, Offset headC, double r, double dir) {
    switch (look) {
      case CrewLook.player:
      case CrewLook.ducker:
        break;
      case CrewLook.raider:
        // Red bandana
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromCenter(center: headC + Offset(0, -r * 0.72), width: r * 2.1, height: r * 0.62),
            topLeft: Radius.circular(r * 0.6),
            topRight: Radius.circular(r * 0.6),
          ),
          Paint()..color = const Color(0xFFC9483C),
        );
        break;
      case CrewLook.pirate:
      case CrewLook.captain:
        // Black tricorn + beard
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: headC + Offset(0, -r * 0.86), width: r * 2.7, height: r * 0.62),
            Radius.circular(r * 0.3),
          ),
          Paint()..color = const Color(0xFF1D1D20),
        );
        canvas.drawPath(
          Path()
            ..moveTo(headC.dx - r * 0.62, headC.dy + r * 0.42)
            ..quadraticBezierTo(headC.dx, headC.dy + r * 1.35, headC.dx + r * 0.62, headC.dy + r * 0.42)
            ..close(),
          Paint()..color = const Color(0xFF3B2A1C),
        );
        break;
    }
  }

  void _enemyLabel(Canvas canvas, Raft raft, double bob) {
    final lo = raft.loadout;
    final top = BattleConst.waterY - lo.width * lo.hull.thickness * 0.55 - 92 + bob;

    final tp = TextPainter(
      text: TextSpan(text: raft.label, style: RT.body(size: 10, color: RT.ink, weight: FontWeight.w800, letterSpacing: 1.2)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(raft.x - tp.width / 2, top - 14));

    // HP bar
    const barW = 62.0;
    final barRect = Rect.fromLTWH(raft.x - barW / 2, top, barW, 7);
    canvas.drawRRect(
      RRect.fromRectAndRadius(barRect, const Radius.circular(4)),
      Paint()..color = Colors.white.withOpacity(0.66),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(barRect.left, barRect.top, barW * raft.hpFrac, 7),
        const Radius.circular(4),
      ),
      Paint()..color = raft.hpFrac > 0.5 ? RT.green : (raft.hpFrac > 0.25 ? RT.orange : RT.red),
    );
  }

  // ---------------------------------------------------------------------------
  // Projectile + effects
  // ---------------------------------------------------------------------------

  void _drawShot(Canvas canvas) {
    final s = world.shot;
    if (s == null) return;
    for (int i = 0; i < s.trail.length; i++) {
      final t = i / max(1, s.trail.length);
      canvas.drawCircle(
        s.trail[i],
        2 + t * 3,
        Paint()..color = s.weapon.color.withOpacity(t * 0.4),
      );
    }
    final r = 9 * s.weapon.weight;
    canvas.drawCircle(s.pos, r + 2, Paint()..color = Colors.black.withOpacity(0.18));
    canvas.drawCircle(s.pos, r, Paint()..color = s.weapon.color);
  }

  void _drawEffects(Canvas canvas) {
    for (final fx in world.effects) {
      final p = fx.progress;
      switch (fx.kind) {
        case 'boom':
          final radius = fx.size * (0.25 + p * 1.35);
          canvas.drawCircle(
            fx.pos,
            radius,
            Paint()
              ..shader = RadialGradient(
                colors: [
                  Colors.white.withOpacity(1 - p),
                  const Color(0xFFFFB347).withOpacity((1 - p) * 0.85),
                  const Color(0x00FF7A3C),
                ],
                stops: const [0.0, 0.55, 1.0],
              ).createShader(Rect.fromCircle(center: fx.pos, radius: radius)),
          );
          break;
        case 'splash':
          canvas.drawOval(
            Rect.fromCenter(
              center: fx.pos,
              width: fx.size * (0.4 + p * 1.1),
              height: fx.size * 0.34 * (0.4 + p * 0.8),
            ),
            Paint()
              ..color = Colors.white.withOpacity((1 - p) * 0.7)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3,
          );
          break;
      }
    }
  }

  /// Trajectory preview dots, drawn by the aim overlay rather than the world
  /// pass so they sit above the rafts.
  void drawTrajectory(Canvas canvas, Size size, List<TrajectoryDot> dots, {required bool charging}) {
    if (dots.isEmpty) return;
    final scale = size.height / BattleConst.worldH;
    canvas.save();
    canvas.scale(scale);
    canvas.translate(-world.cam, 0);
    for (final d in dots) {
      canvas.drawCircle(
        d.pos,
        charging ? 4.0 : 3.0,
        Paint()..color = RT.red.withOpacity((1 - d.index / 180).clamp(0.15, 1.0)),
      );
    }
    canvas.restore();
  }
}

class _Prop {
  final SceneProp kind;
  final double x;
  final double scale;
  final double phase;
  const _Prop({required this.kind, required this.x, required this.scale, required this.phase});
}

class _Cloud {
  final double x;
  final double y;
  final double w;
  final double opacity;
  final double speed;
  const _Cloud({
    required this.x,
    required this.y,
    required this.w,
    required this.opacity,
    required this.speed,
  });
}
