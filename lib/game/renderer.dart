import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart' hide MaterialType;
import '../theme.dart';
import 'maps.dart';
import 'physics.dart';

/// Renders the game world in vibrant comic style with thick outlines.
class WorldRenderer {
  final PhysicsWorld world;
  final MapDef map;
  final List<Color> charColors;
  final List<int> charHats;
  /// 0 = low, 1 = medium, 2 = high. Drives glow/blur effects and particle
  /// density so the GRAPHICS QUALITY setting has a visible, and
  /// performance-relevant, effect.
  final int quality;

  WorldRenderer(this.world, {required this.map, required this.charColors, required this.charHats, this.quality = 1});

  bool get _lowQuality => quality <= 0;
  bool get _highQuality => quality >= 2;

  void render(Canvas canvas, Size viewSize, Offset camPos, double camZoom, double time) {
    canvas.save();
    // screen shake
    final shake = world.screenShake;
    if (shake > 0) {
      final r = Random((time * 1000).toInt() % 1000);
      canvas.translate((r.nextDouble() - 0.5) * shake, (r.nextDouble() - 0.5) * shake);
    }
    // camera transform
    canvas.translate(viewSize.width / 2, viewSize.height / 2);
    canvas.scale(camZoom);
    canvas.translate(-camPos.dx, -camPos.dy);

    _drawBackground(canvas, time);
    _drawHazards(canvas, time);

    // bodies: statics first, then blocks, characters, debris on top
    final sorted = [...world.bodies]..sort((a, b) {
        int rank(PhysBody x) => x.isStatic
            ? 0
            : x.type == BodyType.block
                ? 1
                : x.type == BodyType.character
                    ? 2
                    : 1;
        return rank(a).compareTo(rank(b));
      });
    for (final b in sorted) {
      if (b.dead) continue;
      switch (b.type) {
        case BodyType.block:
          _drawBlock(canvas, b, time);
          break;
        case BodyType.character:
          _drawCharacter(canvas, b, time);
          break;
        case BodyType.debris:
          _drawDebris(canvas, b);
          break;
        case BodyType.projectile:
          break;
      }
    }

    _drawEdgeForeground(canvas, time);

    // projectiles
    for (final p in world.projectiles) {
      _drawProjectile(canvas, p, time);
    }

    // particles
    for (int i = 0; i < world.particles.length; i++) {
      // On low quality, skip every other particle to cut fill-rate/overdraw.
      if (_lowQuality && i.isOdd) continue;
      final pt = world.particles[i];
      final t = (pt.life / pt.maxLife).clamp(0.0, 1.0);
      final paint = Paint()..color = pt.color.withOpacity(t);
      if (pt.glow && !_lowQuality) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, _highQuality ? 6 : 4);
      }
      canvas.drawCircle(pt.pos, pt.size * t, paint);
    }

    canvas.restore();

    // floating texts drawn in world space but after restore of shake? keep in world
    canvas.save();
    canvas.translate(viewSize.width / 2, viewSize.height / 2);
    canvas.scale(camZoom);
    canvas.translate(-camPos.dx, -camPos.dy);
    for (final t in world.texts) {
      final alpha = (t.life / 1.2).clamp(0.0, 1.0);
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: RT.chunky(size: t.size, color: t.color.withOpacity(alpha), outline: 2.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, t.pos - Offset(tp.width / 2, tp.height / 2));
    }
    canvas.restore();
  }

  // -------------------------------------------------------------------------

  void _drawBackground(Canvas canvas, double time) {
    // sky
    final skyRect = Rect.fromLTWH(-400, -600, world.width + 800, world.waterLevel + 600);
    canvas.drawRect(skyRect, Paint()..color = const Color(0x00000000));
    // (gradient painted by widget behind canvas — here just sun + clouds)
    // sun
    final sunPos = Offset(world.width * 0.78, 110);
    canvas.drawCircle(
        sunPos, 55, Paint()..color = const Color(0xFFFFF3B0));
    if (_lowQuality) {
      canvas.drawCircle(sunPos, 44, Paint()..color = const Color(0xFFFFD32A));
    } else {
      canvas.drawCircle(
          sunPos,
          44,
          Paint()
            ..color = const Color(0xFFFFD32A)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, _highQuality ? 14 : 10));
    }
    // clouds (ashy grey over the volcano, fluffy white everywhere else)
    final cloudColor = map.terrain == 'lava' ? const Color(0xFF8A828C) : Colors.white;
    final cloudPaint = Paint()..color = cloudColor.withOpacity(0.85);
    for (int i = 0; i < 4; i++) {
      final cx = (i * 380 + (time * 12) % (world.width + 400)) - 100;
      final cy = 70.0 + (i % 3) * 55;
      _cloud(canvas, Offset(cx.toDouble(), cy), cloudPaint, 0.8 + (i % 2) * 0.3);
    }

    switch (map.terrain) {
      case 'sand':
        _drawDesertGround(canvas);
        break;
      case 'lava':
        _drawLavaGround(canvas);
        break;
      default:
        _drawOceanGround(canvas);
    }
  }

  void _drawOceanGround(Canvas canvas) {
    // distant islands silhouettes
    final islPaint = Paint()..color = const Color(0xFF6B3FA0).withOpacity(0.35);
    canvas.drawOval(Rect.fromCenter(center: Offset(world.width * 0.2, world.waterLevel - 4), width: 260, height: 60), islPaint);
    canvas.drawOval(Rect.fromCenter(center: Offset(world.width * 0.72, world.waterLevel - 2), width: 340, height: 76), islPaint);

    // water body
    final waterRect = Rect.fromLTWH(-400, world.waterLevel, world.width + 800, world.height - world.waterLevel + 600);
    canvas.drawRect(
        waterRect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF3EC6E0), Color(0xFF1B5F9E)],
          ).createShader(waterRect));
  }

  void _drawDesertGround(Canvas canvas) {
    // distant dune silhouettes
    final dunePaint = Paint()..color = const Color(0xFFCB8A3E).withOpacity(0.4);
    canvas.drawOval(Rect.fromCenter(center: Offset(world.width * 0.2, world.waterLevel + 6), width: 300, height: 70), dunePaint);
    canvas.drawOval(Rect.fromCenter(center: Offset(world.width * 0.72, world.waterLevel + 10), width: 360, height: 84), dunePaint);

    // sand stretching to the horizon
    final groundRect = Rect.fromLTWH(-400, world.waterLevel, world.width + 800, world.height - world.waterLevel + 600);
    canvas.drawRect(
        groundRect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF2C879), Color(0xFFC17A34)],
          ).createShader(groundRect));
  }

  void _drawLavaGround(Canvas canvas) {
    // distant volcanic ridge silhouettes
    final ridgePaint = Paint()..color = const Color(0xFF2B141E).withOpacity(0.55);
    canvas.drawOval(Rect.fromCenter(center: Offset(world.width * 0.18, world.waterLevel - 6), width: 280, height: 64), ridgePaint);
    canvas.drawOval(Rect.fromCenter(center: Offset(world.width * 0.76, world.waterLevel - 2), width: 320, height: 72), ridgePaint);

    // molten lava sea
    final lavaRect = Rect.fromLTWH(-400, world.waterLevel, world.width + 800, world.height - world.waterLevel + 600);
    canvas.drawRect(
        lavaRect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFF8A3D), Color(0xFF7A1414)],
          ).createShader(lavaRect));
  }

  void _drawEdgeForeground(Canvas canvas, double time) {
    switch (map.terrain) {
      case 'sand':
        _drawDesertForeground(canvas, time);
        break;
      case 'lava':
        _drawLavaForeground(canvas, time);
        break;
      default:
        _drawOceanForeground(canvas, time);
    }
  }

  void _drawOceanForeground(Canvas canvas, double time) {
    // animated wave line
    final path = Path();
    final paint = Paint()..color = Colors.white.withOpacity(0.5);
    path.moveTo(-400, world.waterLevel);
    for (double x = -400; x <= world.width + 400; x += 16) {
      final y = world.waterLevel + sin(x / 40 + time * 2.2) * 5 + sin(x / 17 - time * 3.1) * 2.5;
      path.lineTo(x, y);
    }
    path.lineTo(world.width + 400, world.waterLevel + 26);
    path.lineTo(-400, world.waterLevel + 26);
    path.close();
    canvas.drawPath(path, paint..color = const Color(0xFF9FE4F5).withOpacity(0.85));
  }

  void _drawDesertForeground(Canvas canvas, double time) {
    // loose sand crest — slower, gentler undulation than water, no foam
    final path = Path();
    final paint = Paint()..color = const Color(0xFFE8C07D).withOpacity(0.8);
    path.moveTo(-400, world.waterLevel);
    for (double x = -400; x <= world.width + 400; x += 16) {
      final y = world.waterLevel + sin(x / 70 + time * 0.6) * 3;
      path.lineTo(x, y);
    }
    path.lineTo(world.width + 400, world.waterLevel + 26);
    path.lineTo(-400, world.waterLevel + 26);
    path.close();
    canvas.drawPath(path, paint);
  }

  void _drawLavaForeground(Canvas canvas, double time) {
    // bubbling, glowing lava crest
    final path = Path();
    final glow = 0.7 + sin(time * 3.5) * 0.15;
    final paint = Paint()..color = const Color(0xFFFFD23D).withOpacity(glow);
    if (!_lowQuality) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, _highQuality ? 5 : 3);
    }
    path.moveTo(-400, world.waterLevel);
    for (double x = -400; x <= world.width + 400; x += 14) {
      final y = world.waterLevel + sin(x / 30 + time * 4.5) * 6 + sin(x / 13 - time * 6.0) * 3;
      path.lineTo(x, y);
    }
    path.lineTo(world.width + 400, world.waterLevel + 26);
    path.lineTo(-400, world.waterLevel + 26);
    path.close();
    canvas.drawPath(path, paint);
  }

  void _cloud(Canvas canvas, Offset c, Paint paint, double s) {
    canvas.drawCircle(c, 26 * s, paint);
    canvas.drawCircle(c + Offset(28 * s, 6 * s), 20 * s, paint);
    canvas.drawCircle(c - Offset(28 * s, 8 * s), 18 * s, paint);
    canvas.drawRect(Rect.fromCenter(center: c + Offset(0, 12 * s), width: 76 * s, height: 22 * s), paint);
  }

  void _drawHazards(Canvas canvas, double time) {
    for (final h in world.hazards) {
      final flick = 0.75 + sin(time * 14) * 0.15;
      final paint = Paint()..color = const Color(0xFFFF8C1A).withOpacity(0.35 * flick);
      if (!_lowQuality) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, _highQuality ? 16 : 12);
      }
      canvas.drawCircle(h.center, h.radius * flick, paint);
    }
  }

  // -------------------------------------------------------------------------

  void _drawBlock(Canvas canvas, PhysBody b, double time) {
    canvas.save();
    canvas.translate(b.pos.dx, b.pos.dy);
    canvas.rotate(b.angle);
    final rect = Rect.fromCenter(center: Offset.zero, width: b.size.width, height: b.size.height);
    final spec = _matColors(b.material);
    final frozen = b.frozenUntil > world.elapsed;

    Color fill = spec.$1;
    Color dark = spec.$2;
    if (frozen) {
      fill = Color.lerp(fill, const Color(0xFF7DD8FF), 0.55)!;
      dark = Color.lerp(dark, const Color(0xFF4FA8D9), 0.55)!;
    }

    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(b.isStatic ? 4 : 7));
    // outline
    canvas.drawRRect(rrect, Paint()..color = RT.ink);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(3), Radius.circular(b.isStatic ? 2 : 5)),
      Paint()..color = fill,
    );
    // inner shading
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(rect.left + 3, rect.top + 3, rect.width - 6, rect.height * 0.35), const Radius.circular(4)),
      Paint()..color = Colors.white.withOpacity(0.28),
    );

    // material details
    final dp = Paint()..color = dark;
    if (b.material == MaterialType.wood || b.material == MaterialType.raft) {
      // plank lines
      final lines = max(1, (b.size.height / 22).floor());
      for (int i = 1; i <= lines; i++) {
        final y = rect.top + rect.height * i / (lines + 1);
        canvas.drawLine(Offset(rect.left + 5, y), Offset(rect.right - 5, y), dp..strokeWidth = 2.5);
      }
      // nails
      canvas.drawCircle(Offset(rect.left + 9, rect.top + 9), 2.5, dp);
      canvas.drawCircle(Offset(rect.right - 9, rect.bottom - 9), 2.5, dp);
    } else if (b.material == MaterialType.metal) {
      // rivets
      for (final p in [
        Offset(rect.left + 8, rect.top + 8),
        Offset(rect.right - 8, rect.top + 8),
        Offset(rect.left + 8, rect.bottom - 8),
        Offset(rect.right - 8, rect.bottom - 8),
      ]) {
        canvas.drawCircle(p, 3, dp);
      }
      canvas.drawLine(Offset(rect.left + 6, 0), Offset(rect.right - 6, 0), dp..strokeWidth = 2);
    } else if (b.material == MaterialType.stone) {
      canvas.drawCircle(Offset(rect.left + rect.width * 0.3, rect.top + rect.height * 0.35), 4, dp);
      canvas.drawCircle(Offset(rect.left + rect.width * 0.65, rect.top + rect.height * 0.6), 3, dp);
    } else if (b.material == MaterialType.glass) {
      // shine streak
      canvas.drawLine(Offset(rect.left + 8, rect.bottom - 8), Offset(rect.right - 14, rect.top + 8),
          Paint()..color = Colors.white.withOpacity(0.7)..strokeWidth = 4);
    }

    // damage cracks — visible states 100/75/50/25
    final frac = b.damageFrac;
    if (frac < 0.99 && !b.isStatic) {
      final crackPaint = Paint()
        ..color = RT.ink.withOpacity(0.85)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final rnd = Random(b.id);
      final cracks = frac < 0.25 ? 5 : frac < 0.5 ? 3 : frac < 0.75 ? 2 : 1;
      for (int i = 0; i < cracks; i++) {
        final sx = rect.left + rnd.nextDouble() * rect.width;
        final sy = rect.top + rnd.nextDouble() * rect.height;
        final path = Path()..moveTo(sx, sy);
        double cx = sx, cy = sy;
        for (int sgm = 0; sgm < 3; sgm++) {
          cx += (rnd.nextDouble() - 0.5) * rect.width * 0.4;
          cy += rnd.nextDouble() * rect.height * 0.35;
          path.lineTo(cx, cy);
        }
        canvas.drawPath(path, crackPaint);
      }
    }

    // frozen shimmer
    if (frozen) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.deflate(3), const Radius.circular(5)),
        Paint()..color = Colors.white.withOpacity(0.25 + sin(time * 6) * 0.08),
      );
    }

    canvas.restore();
  }

  (Color, Color) _matColors(MaterialType m) {
    switch (m) {
      case MaterialType.wood: return (const Color(0xFFB5793B), const Color(0xFF8A5726));
      case MaterialType.stone: return (const Color(0xFF9AA5B1), const Color(0xFF6E7987));
      case MaterialType.metal: return (const Color(0xFF7FB3D9), const Color(0xFF527E9E));
      case MaterialType.glass: return (const Color(0xFFBFECFF), const Color(0xFF8CC6E8));
      case MaterialType.raft: return (const Color(0xFF9C6B30), const Color(0xFF6E4A1E));
      default: return (const Color(0xFFB5793B), const Color(0xFF8A5726));
    }
  }

  // -------------------------------------------------------------------------

  void _drawCharacter(Canvas canvas, PhysBody b, double time) {
    final idx = b.playerIndex.clamp(0, charColors.length - 1);
    final color = charColors[idx];
    final dark = Color.lerp(color, Colors.black, 0.3)!;
    final ragdoll = b.vel.distance > 60 || b.angularVel.abs() > 1.0 || b.dead;
    final idle = sin(time * 3 + b.id) * 1.5;

    canvas.save();
    canvas.translate(b.pos.dx, b.pos.dy);
    canvas.rotate(b.angle);

    final w = b.size.width, h = b.size.height;
    final bodyRect = Rect.fromCenter(center: const Offset(0, 4), width: w, height: h * 0.62);

    // drop shadow
    canvas.drawOval(Rect.fromCenter(center: Offset(0, h / 2 + 4), width: w * 1.1, height: 8),
        Paint()..color = Colors.black.withOpacity(0.18));

    final outlinePaint = Paint()..color = RT.ink;

    // legs
    if (!ragdoll) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(-6, h * 0.32 + idle * 0.3), width: 9, height: 14), const Radius.circular(4)),
          outlinePaint);
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(6, h * 0.32 - idle * 0.3), width: 9, height: 14), const Radius.circular(4)),
          outlinePaint);
    } else {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(-8, h * 0.32), width: 9, height: 14), const Radius.circular(4)),
          outlinePaint);
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(9, h * 0.28), width: 9, height: 14), const Radius.circular(4)),
          outlinePaint);
    }

    // body (chunky rounded)
    canvas.drawRRect(RRect.fromRectAndRadius(bodyRect, const Radius.circular(12)), outlinePaint);
    canvas.drawRRect(RRect.fromRectAndRadius(bodyRect.deflate(3), const Radius.circular(9)), Paint()..color = color);
    // belly highlight
    canvas.drawOval(Rect.fromCenter(center: const Offset(0, 10), width: w * 0.5, height: h * 0.3),
        Paint()..color = Colors.white.withOpacity(0.25));

    // head
    final headC = Offset(0, -h * 0.32 + (ragdoll ? 0 : idle));
    canvas.drawCircle(headC, w * 0.52, outlinePaint);
    canvas.drawCircle(headC, w * 0.52 - 3, Paint()..color = const Color(0xFFFFDFC4));

    // eyes
    final eyeY = headC.dy - 2;
    if (b.dead) {
      // X X eyes
      final xp = Paint()
        ..color = RT.ink
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      for (final ex in [-6.0, 6.0]) {
        canvas.drawLine(Offset(headC.dx + ex - 3, eyeY - 3), Offset(headC.dx + ex + 3, eyeY + 3), xp);
        canvas.drawLine(Offset(headC.dx + ex + 3, eyeY - 3), Offset(headC.dx + ex - 3, eyeY + 3), xp);
      }
    } else if (ragdoll) {
      // dizzy spiral-ish: big white eyes with small pupils up
      for (final ex in [-6.0, 6.0]) {
        canvas.drawCircle(Offset(headC.dx + ex, eyeY), 4.5, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(headC.dx + ex, eyeY - 1.5), 2, outlinePaint);
      }
    } else {
      for (final ex in [-6.0, 6.0]) {
        canvas.drawCircle(Offset(headC.dx + ex, eyeY), 4, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(headC.dx + ex + 1, eyeY), 2, outlinePaint);
      }
    }

    // mouth
    final mouthPaint = Paint()
      ..color = RT.ink
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    if (b.dead) {
      canvas.drawArc(Rect.fromCenter(center: Offset(headC.dx, eyeY + 12), width: 10, height: 8), pi, -pi, false, mouthPaint);
    } else if (ragdoll) {
      canvas.drawCircle(Offset(headC.dx, eyeY + 9), 3.5, mouthPaint..style = PaintingStyle.fill);
    } else {
      canvas.drawArc(Rect.fromCenter(center: Offset(headC.dx, eyeY + 6), width: 12, height: 9), 0.2, pi - 0.4, false, mouthPaint);
    }

    // hat / bandana
    final hat = idx < charHats.length ? charHats[idx] : 0;
    _drawHat(canvas, headC, w * 0.52, hat, color, dark);

    // hp ring (small arc above head when damaged)
    if (b.hp < b.maxHp && !b.dead) {
      final frac = (b.hp / b.maxHp).clamp(0.0, 1.0);
      final arcRect = Rect.fromCircle(center: headC, radius: w * 0.62);
      canvas.drawArc(arcRect, -pi / 2 + pi * 0.7, pi * 1.6, false,
          Paint()..color = Colors.white.withOpacity(0.4)..strokeWidth = 3..style = PaintingStyle.stroke);
      canvas.drawArc(arcRect, -pi / 2 + pi * 0.7, pi * 1.6 * frac, false,
          Paint()..color = frac > 0.5 ? RT.green : frac > 0.25 ? RT.orange : RT.red..strokeWidth = 3..style = PaintingStyle.stroke..strokeCap = StrokeCap.round);
    }

    // frozen tint
    if (b.frozenUntil > world.elapsed) {
      canvas.drawCircle(headC, w * 0.6, Paint()..color = const Color(0xFF7DD8FF).withOpacity(0.4));
    }
    if (b.burnUntil > world.elapsed) {
      canvas.drawCircle(const Offset(0, -6), w * 0.7,
          Paint()..color = const Color(0xFFFF8C1A).withOpacity(0.3 + sin(time * 12) * 0.1));
    }

    canvas.restore();
  }

  void _drawHat(Canvas canvas, Offset headC, double r, int hat, Color color, Color dark) {
    final outline = Paint()..color = RT.ink;
    switch (hat % 5) {
      case 0: // bandana
        final rect = Rect.fromCenter(center: headC - Offset(0, r * 0.55), width: r * 2.05, height: r * 0.7);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)), outline);
        canvas.drawRRect(RRect.fromRectAndRadius(rect.deflate(2.5), const Radius.circular(4)), Paint()..color = dark);
        // knot
        canvas.drawCircle(headC + Offset(r * 0.9, -r * 0.55), 4.5, outline);
        canvas.drawCircle(headC + Offset(r * 0.9, -r * 0.55), 2.5, Paint()..color = dark);
        break;
      case 1: // captain hat
        final rect = Rect.fromCenter(center: headC - Offset(0, r * 0.75), width: r * 1.7, height: r * 0.75);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)), outline);
        canvas.drawRRect(RRect.fromRectAndRadius(rect.deflate(2.5), const Radius.circular(4)), Paint()..color = const Color(0xFF2B3A67));
        canvas.drawCircle(headC - Offset(0, r * 0.75), 4, Paint()..color = RT.yellow);
        break;
      case 2: // propeller cap
        final rect = Rect.fromCenter(center: headC - Offset(0, r * 0.6), width: r * 1.8, height: r * 0.6);
        canvas.drawArc(rect, pi, pi, true, outline);
        canvas.drawArc(Rect.fromCenter(center: headC - Offset(0, r * 0.6), width: r * 1.8 - 5, height: r * 0.6 - 5), pi, pi, true, Paint()..color = color);
        canvas.drawRect(Rect.fromCenter(center: headC - Offset(0, r * 1.15), width: r * 1.3, height: 5), outline);
        canvas.drawRect(Rect.fromCenter(center: headC - Offset(0, r * 1.15), width: r * 1.3 - 3, height: 3), Paint()..color = RT.yellow);
        break;
      case 3: // viking helm
        final rect = Rect.fromCenter(center: headC - Offset(0, r * 0.62), width: r * 1.8, height: r * 0.85);
        canvas.drawArc(rect, pi, pi, true, outline);
        canvas.drawArc(Rect.fromCenter(center: headC - Offset(0, r * 0.62), width: r * 1.8 - 5, height: r * 0.85 - 5), pi, pi, true,
            Paint()..color = const Color(0xFF9AA5B1));
        // horns
        for (final s in [-1.0, 1.0]) {
          final hp = Path()
            ..moveTo(headC.dx + s * r * 0.8, headC.dy - r * 0.6)
            ..quadraticBezierTo(headC.dx + s * r * 1.5, headC.dy - r * 1.3, headC.dx + s * r * 1.15, headC.dy - r * 1.5)
            ..quadraticBezierTo(headC.dx + s * r * 1.1, headC.dy - r * 1.0, headC.dx + s * r * 0.55, headC.dy - r * 0.75)
            ..close();
          canvas.drawPath(hp, outline);
          canvas.drawPath(hp, Paint()..color = const Color(0xFFFFF6E8)..style = PaintingStyle.fill..strokeWidth = 0);
        }
        break;
      case 4: // fish hat!
        final fp = Path()
          ..moveTo(headC.dx - r * 0.9, headC.dy - r * 0.7)
          ..quadraticBezierTo(headC.dx, headC.dy - r * 1.9, headC.dx + r * 0.9, headC.dy - r * 0.7)
          ..close();
        canvas.drawPath(fp, outline);
        canvas.drawPath(fp, Paint()..color = const Color(0xFF3EC6E0));
        canvas.drawCircle(headC + Offset(r * 0.35, -r * 1.0), 3.5, outline);
        break;
    }
  }

  // -------------------------------------------------------------------------

  void _drawDebris(Canvas canvas, PhysBody b) {
    final color = world.debrisColors[b.id] ?? const Color(0xFFB5793B);
    canvas.save();
    canvas.translate(b.pos.dx, b.pos.dy);
    canvas.rotate(b.angle);
    final rect = Rect.fromCenter(center: Offset.zero, width: b.size.width, height: b.size.height);
    canvas.drawRect(rect, Paint()..color = RT.ink);
    canvas.drawRect(rect.deflate(1.8), Paint()..color = color);
    canvas.restore();
  }

  void _drawProjectile(Canvas canvas, Projectile p, double time) {
    // trail
    for (int i = 0; i < p.trail.length; i++) {
      final t = i / p.trail.length;
      canvas.drawCircle(
          p.trail[i],
          p.radius * 0.6 * t,
          Paint()..color = p.weapon.color.withOpacity(0.35 * t));
    }
    canvas.save();
    canvas.translate(p.pos.dx, p.pos.dy);
    final ang = atan2(p.vel.dy, p.vel.dx);
    canvas.rotate(ang);
    // body
    canvas.drawCircle(Offset.zero, p.radius, Paint()..color = RT.ink);
    canvas.drawCircle(Offset.zero, p.radius - 2.5, Paint()..color = p.weapon.color);
    canvas.drawCircle(Offset(-p.radius * 0.3, -p.radius * 0.3), p.radius * 0.3, Paint()..color = Colors.white.withOpacity(0.6));
    // rocket flame
    if (p.weapon.behavior == 'rocket') {
      final flick = 1 + sin(time * 30) * 0.3;
      final flame = Path()
        ..moveTo(-p.radius, 0)
        ..lineTo(-p.radius - 14 * flick, -5)
        ..lineTo(-p.radius - 20 * flick, 0)
        ..lineTo(-p.radius - 14 * flick, 5)
        ..close();
      canvas.drawPath(flame, Paint()..color = const Color(0xFFFFD32A));
      if (!_lowQuality) {
        canvas.drawPath(flame, Paint()..color = const Color(0xFFFF8C1A).withOpacity(0.7)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      }
    }
    if (p.weapon.behavior == 'grenade' && p.fuse > 0) {
      // spark
      canvas.drawCircle(Offset(0, -p.radius - 4), 3.5 + sin(time * 40) * 1.5, Paint()..color = RT.yellow);
    }
    canvas.restore();
  }
}
