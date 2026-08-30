import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'battle.dart';
import 'maps.dart';
import 'models.dart';

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

  /// [currentPlayer]/[isAiming]/[aimAngleDeg]/[weapon] describe the live aim
  /// state from [GameController] (in `screens/game_screen.dart`). They drive
  /// the active shooter's arm: raised and tracking the drag while aiming,
  /// kicking back into a muzzle flash for a beat right after firing, and
  /// hanging relaxed at every other crew member and at every other time.
  void render(
    Canvas canvas,
    Size size,
    double time, {
    int currentPlayer = -1,
    bool isAiming = false,
    double aimAngleDeg = 45,
    WeaponDef? weapon,
  }) {
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
    _drawRafts(
      canvas, time,
      currentPlayer: currentPlayer,
      isAiming: isAiming,
      aimAngleDeg: aimAngleDeg,
      weapon: weapon,
    );
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
    // Keep props clear of the player raft and the enemy slots so nothing
    // ever draws on top of a crew member (the widest raft is 260 wide).
    final reserved = <double>[BattleConst.playerX, ...BattleConst.enemySlots];
    bool clear(double x) => reserved.every((r) => (x - r).abs() > 170);

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

  void _drawRafts(
    Canvas canvas,
    double time, {
    required int currentPlayer,
    required bool isAiming,
    required double aimAngleDeg,
    required WeaponDef? weapon,
  }) {
    for (final raft in world.rafts) {
      final bob = world.bobOf(raft);
      canvas.save();
      canvas.translate(raft.x, bob);

      _ripple(canvas, raft, time);
      if (raft.loadout.hull.hasMast) _mast(canvas, raft);
      _hull(canvas, raft);
      _platforms(canvas, raft);

      for (int i = 0; i < raft.crew.length; i++) {
        final c = raft.crew[i];
        if (c.gone) continue;
        canvas.save();
        final pose = c.pose;
        if (pose != null) {
          // A ragdoll is drawn straight from its verlet points, which are
          // stored station-local: x relative to the crew member's slot, y
          // relative to the *deck surface* (see [RagdollPose]) — the same
          // frame the physics in [BattleWorld._stepBody] works in. That
          // frame still has to be placed on the actual raft, so the deck
          // height goes into the translate here; omitting it (as before)
          // left every ragdoll rendering near world-y 0 — up near the sky —
          // instead of down on the raft where the physics actually put it.
          canvas.translate(raft.loadout.crewOffset(i), raft.deckY);
        } else {
          // The standing body's own displacement from its station — a crew
          // member walking back after a knock-down is drawn wherever the
          // shuffle actually is.
          canvas.translate(raft.loadout.crewOffset(i) + c.offset.dx, c.offset.dy);
        }
        // Defeated crew go through the death sequence: they never fade
        // while still airborne on the deck — the sink only starts once the
        // body is actually in the water (see BattleWorld's body stepper).
        // The fade layer covers the whole body in whatever pose it died.
        Rect bodyBounds = const Rect.fromLTWH(-130, -150, 260, 230);
        if (!c.alive) {
          if (pose != null) bodyBounds = pose.drawBounds;
          canvas.translate(0, _sinkDrop(c));
          canvas.saveLayer(
            bodyBounds.inflate(30),
            Paint()..color = Colors.white.withOpacity(_sinkOpacity(c.sinkT)),
          );
        }
        _crewMember(
          canvas, raft, c, i, time,
          currentPlayer: currentPlayer,
          isAiming: isAiming,
          aimAngleDeg: aimAngleDeg,
          weapon: weapon,
        );
        if (!c.alive) {
          // Killing-blow flash: a beat of pure white over the whole body,
          // blended onto what was just drawn.
          if (c.deathFlash > 0) {
            final f = (c.deathFlash / BattleConst.deathFlashTime).clamp(0.0, 1.0);
            canvas.drawRect(
              bodyBounds.inflate(30),
              Paint()
                ..color = Colors.white.withOpacity(f * 0.85)
                ..blendMode = BlendMode.srcATop,
            );
          }
          _deathFx(canvas, c, time);
          canvas.restore();
        } else if (c.hpBarT > 0) {
          // Dynamic health bar: hidden by default, summoned by damage, and
          // gone again once its animation finishes.
          _crewHealthBar(canvas, raft, c, pose);
        }
        canvas.restore();
      }

      canvas.restore();

      if (raft.playerIndex != 0 && raft.alive) _enemyLabel(canvas, raft, bob);
    }
  }

  /// Vertical offset of a sinking body: buoyancy first carries it up to bob
  /// at the surface, then it slips under on a smooth ease.
  double _sinkDrop(Crew c) {
    final t = c.sinkT;
    if (t <= BattleConst.sinkFloatFrac) {
      final u = t / BattleConst.sinkFloatFrac;
      return -(1 - u) * 18 - sin(world.elapsed * 2.6 + c.bobPhase) * 1.4 * u;
    }
    final u = ((t - BattleConst.sinkFloatFrac) / (1 - BattleConst.sinkFloatFrac)).clamp(0.0, 1.0);
    final eased = u * u * (3 - 2 * u);
    return 8 + eased * 52;
  }

  /// Opacity of a sinking body: solid while it floats, gone by the time it
  /// has fully slipped under.
  double _sinkOpacity(double t) {
    const startFade = 0.55;
    if (t <= startFade) return 1;
    return (1 - (t - startFade) / (1 - startFade)).clamp(0.0, 1.0);
  }

  /// Bubbles and the pale wisp that lift away while a crew member slips
  /// under — the tail end of the death sequence.
  void _deathFx(Canvas canvas, Crew c, double time) {
    if (c.sinkT > BattleConst.sinkFloatFrac) {
      for (int k = 0; k < 3; k++) {
        final ph = (time * 0.5 + k * 0.37 + c.bobPhase) % 1.0;
        final y = -8 - ph * 30;
        final x = sin(time * 1.7 + k * 2.1 + c.bobPhase) * 5 + (k - 1) * 6;
        canvas.drawCircle(
          Offset(x, y),
          2.0 + k * 0.7,
          Paint()..color = Colors.white.withOpacity((1 - ph) * 0.5),
        );
      }
    }
    const ghostStart = 0.35, ghostEnd = 0.9;
    if (c.sinkT > ghostStart && c.sinkT < ghostEnd) {
      final u = (c.sinkT - ghostStart) / (ghostEnd - ghostStart);
      final opacity = sin(u * pi) * 0.5;
      final y = -40 - u * 46;
      canvas.drawCircle(
        Offset(0, y),
        5 + u * 3,
        Paint()..color = Colors.white.withOpacity(opacity * 0.9),
      );
      canvas.drawCircle(
        Offset(0, y),
        10 + u * 6,
        Paint()..color = Colors.white.withOpacity(opacity * 0.35),
      );
    }
  }

  /// The per-crew dynamic health bar, drawn just above the character's head
  /// (standing or ragdoll). Hidden by default; a hit brings it up with a
  /// quick fade-in, a red ghost bar drains from the HP the character *had*
  /// down to the live value, and the whole thing fades out once the drain
  /// completes.
  void _crewHealthBar(Canvas canvas, Raft raft, Crew c, RagdollPose? pose) {
    final double cx;
    final double topY;
    if (pose != null) {
      // Deck-relative, same as the (now deck-shifted) outer translate.
      cx = pose.head.pos.dx;
      topY = pose.head.pos.dy - 14;
    } else {
      // This frame is *not* deck-shifted (the standing branch adds the deck
      // height internally, inside _crewMember's own save/restore), so it
      // has to be added back here explicitly.
      cx = 0;
      topY = raft.deckY - BattleConst.bodyHeight;
    }

    final shownFor = BattleConst.hpBarTime - c.hpBarT;
    double alpha = 1.0;
    if (shownFor < 0.12) alpha = shownFor / 0.12;
    if (c.hpBarT < BattleConst.hpBarFade) {
      alpha = min(alpha, c.hpBarT / BattleConst.hpBarFade);
    }
    alpha = alpha.clamp(0.0, 1.0);
    if (alpha <= 0) return;

    const barW = 46.0;
    const barH = 6.0;
    final y = topY - 15;
    final rect = Rect.fromLTWH(cx - barW / 2, y, barW, barH);
    const radius = Radius.circular(3);

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..color = Colors.white.withOpacity(0.78 * alpha),
    );

    // The ghost: HP the character had when the bar was summoned, draining
    // to the live value so the loss reads as motion, not a jump.
    final ghostW = barW * c.hpDisplay.clamp(0.0, 1.0);
    if (ghostW > barW * c.hpFrac) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(rect.left, y, ghostW, barH), radius),
        Paint()..color = RT.red.withOpacity(0.45 * alpha),
      );
    }

    final frac = c.hpFrac;
    if (frac > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(rect.left, y, barW * frac, barH), radius),
        Paint()
          ..color = (frac > 0.5 ? RT.green : (frac > 0.25 ? RT.orange : RT.red))
              .withOpacity(alpha),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()
        ..color = RT.ink.withOpacity(0.35 * alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
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

  /// The deck's raised platforms, drawn from the same [DeckProfile] the
  /// physics collides against — blocks render as solid slabs with a lit top
  /// and a shaded front wall, ramps as wedges. Coordinates are hull-local,
  /// rises measured up from the main deck plane (y-down, so negative).
  void _platforms(Canvas canvas, Raft raft) {
    final lo = raft.loadout;
    final deckTop = BattleConst.waterY - lo.width * lo.hull.thickness * 0.55;
    final w = lo.width;

    for (final s in raft.profile.segments) {
      final isRamp = !s.isFlat;
      final left = s.x0;
      final right = s.x1;
      final topL = deckTop - s.rise0;
      final topR = deckTop - s.rise1;

      final path = Path()
        ..moveTo(left, topL)
        ..lineTo(right, topR)
        ..lineTo(right, deckTop + 2)
        ..lineTo(left, deckTop + 2)
        ..close();

      final shade = Colors.black.withOpacity(isRamp ? 0.04 : 0.10);
      final planks = isRamp ? lo.color : Color.lerp(lo.color, Colors.white, 0.14)!;

      canvas.drawPath(path, Paint()..color = planks);
      // Lit walking surface along the top edge.
      canvas.drawLine(
        Offset(left, topL),
        Offset(right, topR),
        Paint()
          ..color = Colors.white.withOpacity(0.30)
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
      // Front face shading, deeper for solid blocks than ramps.
      canvas.drawPath(
        Path()
          ..moveTo(left, topL)
          ..lineTo(right, topR)
          ..lineTo(right, deckTop + 2)
          ..lineTo(left, deckTop + 2)
          ..close(),
        Paint()..color = shade,
      );
      // Plank seams on block tops, matching the hull's timber language.
      if (!isRamp) {
        final seam = Paint()..color = Colors.black.withOpacity(0.12);
        final span = right - left;
        final seams = (span / 14).floor().clamp(1, 4);
        for (int k = 1; k < seams; k++) {
          final x = left + span * k / seams;
          final y = deckTop - s.riseAt(x) - 0;
          canvas.drawLine(Offset(x, y), Offset(x, deckTop + 1), seam);
        }
        // A block reads solid: darker band along its foot.
        canvas.drawRect(
          Rect.fromLTWH(left, deckTop - 3, span, 5),
          Paint()..color = Colors.black.withOpacity(0.16),
        );
      }
      // Keep the planks' horizontal seam language but bound it to the hull.
      assert(right <= w / 2 + 0.01 && left >= -w / 2 - 0.01);
    }

    // Rail lips at both rails — the physical bumper living bodies bounce
    // off, drawn so the boundary reads before anyone tests it.
    final lip = Color.lerp(lo.color, const Color(0xFF23262B), 0.5)!;
    for (final side in [-1.0, 1.0]) {
      final x = side * raft.deckHalf;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x - 2.5,
            deckTop - BattleConst.railWallHeight,
            5,
            BattleConst.railWallHeight,
          ),
          const Radius.circular(2.5),
        ),
        Paint()..color = lip,
      );
    }
  }

  void _mast(Canvas canvas, Raft raft) {    final lo = raft.loadout;
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

  void _crewMember(
    Canvas canvas,
    Raft raft,
    Crew crew,
    int index,
    double time, {
    required int currentPlayer,
    required bool isAiming,
    required double aimAngleDeg,
    required WeaponDef? weapon,
  }) {
    final lo = raft.loadout;
    final dir = raft.facing.toDouble();
    final deck = BattleConst.waterY - lo.width * lo.hull.thickness * 0.55;

    if (crew.pose != null) {
      _ragdollBody(canvas, raft, crew, dir, weapon, time);
      return;
    }

    // The dead don't bob — they are lying where they fell.
    final bob = crew.alive ? sin(time * 1.7 + crew.bobPhase) * 1.4 : 0.0;

    canvas.save();
    canvas.translate(0, bob);

    // Is this the crew member currently lining up (or having just taken)
    // the shot for their raft?
    final isShooter = crew.alive && raft.playerIndex == currentPlayer && index == raft.activeIndex;
    final aiming = isShooter && isAiming;

    // Recoil: a short, sharp window right after this crew member's own shot
    // leaves the barrel, decaying from 1 (muzzle flash + kickback) to 0.
    // The whole body reads it, not just the arm: the torso leans away, the
    // head ducks, and the stance widens to absorb the shove.
    double recoil = 0;
    final liveShot = world.shot;
    if (liveShot != null && liveShot.owner == raft.playerIndex && index == raft.activeIndex) {
      const recoilDur = 0.26;
      final dt = world.elapsed - liveShot.firedAt;
      if (dt >= 0 && dt < recoilDur) {
        final u = 1 - dt / recoilDur;
        // Sharp attack, soft decay — a snap, not a slide.
        recoil = u * u * (3 - 2 * u);
      }
    }

    // -------------------------------------------------------------------
    // Layout: a small head over a chunkier, human-proportioned torso, on
    // two planted legs. Everything is built from thick rounded-cap "bone"
    // strokes (see [_limb]) rather than baked shapes, so the gun arm is
    // free to swing to any angle at runtime instead of needing a sprite
    // for every pose.
    // -------------------------------------------------------------------
    const legLen = 15.0;
    const torsoH = 27.0;
    const torsoW = 29.0;
    const headR = 14.0;

    final footY = deck;
    // Recoil crouches the body: the hips drop, compressing the legs a touch.
    final hipY = footY - legLen + recoil * 3.2;
    final shoulderY = hipY - torsoH;
    final headC = Offset(0, shoulderY - headR - 2);

    final skin = _skinFor(raft.look);
    final suit = raft.playerIndex == 0 ? const Color(0xFF2D4F8F) : lo.color;
    const boot = Color(0xFF23262B);
    const metal = Color(0xFF3B3F45);
    final accent = weapon?.color ?? RT.orange;

    final leanBack = recoil * 0.16;
    final hipBobWalk = sin(crew.walkPhase * pi * 2 * 2).abs() * 1.2 * crew.walkAmp;

    // ---- Legs ----
    // A wide, planted stance while aiming or absorbing recoil; a swing while
    // walking back to station; a relaxed idle otherwise.
    final stance = 8.0 + (aiming ? 2.0 : 0.0) + recoil * 4.0;
    final swing = sin(crew.walkPhase * pi * 2) * 7.0 * crew.walkAmp;
    final liftL = crew.walkAmp > 0
        ? max(0.0, sin(crew.walkPhase * pi * 2)) * 5.0 * crew.walkAmp
        : 0.0;
    final liftR = crew.walkAmp > 0
        ? max(0.0, sin(crew.walkPhase * pi * 2 + pi)) * 5.0 * crew.walkAmp
        : 0.0;
    final feet = [
      Offset(-stance + swing, -liftL),
      Offset(stance - swing, -liftR),
    ];
    for (final foot in feet) {
      _limb(canvas, Offset(foot.dx * 0.8, hipY + hipBobWalk),
          Offset(foot.dx, footY + foot.dy), 10, boot);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(foot.dx, footY + foot.dy + 3), width: 15, height: 9),
          const Radius.circular(4.5),
        ),
        Paint()..color = boot,
      );
    }

    // ---- Support arm (drawn first so it tucks behind the torso/gun arm) ----
    final gunSide = dir >= 0 ? 1.0 : -1.0;
    final gunShoulder = Offset(gunSide * (torsoW / 2 - 5), shoulderY + 5);
    final suppShoulder = Offset(-gunSide * (torsoW / 2 - 5), shoulderY + 5);
    final sway = sin(time * 1.4 + crew.bobPhase) * 1.6;

    late Offset gunElbow;
    late Offset gunHand;

    if (aiming || recoil > 0) {
      // Two-handed grip, levelled along the live aim angle. [recoil] eats
      // into the reach for a snappy kickback right as the shot goes out.
      final angleRad = aimAngleDeg * pi / 180;
      final aimDir = Offset(gunSide * cos(angleRad), -sin(angleRad));
      final reach = 24.0 - recoil * 7;
      gunHand = gunShoulder + aimDir * reach;
      gunElbow = gunShoulder + aimDir * (reach * 0.5) + const Offset(0, 3);

      final suppHand = gunHand - aimDir * 7 + const Offset(0, 3);
      final suppElbow = suppShoulder + (suppHand - suppShoulder) * 0.5 + const Offset(0, 5);
      _limb(canvas, suppShoulder, suppElbow, 9, suit);
      _limb(canvas, suppElbow, suppHand, 8, skin);
      canvas.drawCircle(suppHand, 5.5, Paint()..color = skin);
    } else {
      // Relaxed: both arms hang at the sides with a little idle sway, plus
      // a counter-swing while walking.
      final walkSwing = sin(crew.walkPhase * pi * 2 + pi) * 4.0 * crew.walkAmp;
      final suppElbow = suppShoulder + Offset(-gunSide * 3, 9 + sway * 0.3);
      final suppHand = suppShoulder + Offset(-gunSide * 2, 18 - sway * 0.3);
      _limb(canvas, suppShoulder, suppElbow, 9, suit);
      _limb(canvas, suppElbow, suppHand + Offset(0, walkSwing), 8, skin);
      canvas.drawCircle(suppHand + Offset(0, walkSwing), 5.5, Paint()..color = skin);

      gunElbow = gunShoulder + Offset(gunSide * 3, 9 - sway * 0.3);
      gunHand = gunShoulder + Offset(gunSide * 2, 18 + sway * 0.3);
    }

    // ---- Torso ----
    canvas.save();
    // Recoil leans the whole upper body back about the hips; walking adds
    // a slight forward hunch.
    canvas.translate(0, hipY);
    canvas.rotate(-leanBack * gunSide + crew.walkAmp * 0.04 * gunSide);
    canvas.translate(0, -hipY);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(-torsoW / 2, shoulderY, torsoW, torsoH),
        topLeft: const Radius.circular(11),
        topRight: const Radius.circular(11),
        bottomLeft: const Radius.circular(6),
        bottomRight: const Radius.circular(6),
      ),
      Paint()..color = suit,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-torsoW / 2, shoulderY + torsoH * 0.6, torsoW, torsoH * 0.4),
        const Radius.circular(6),
      ),
      Paint()..color = Colors.black.withOpacity(0.1),
    );

    // ---- Gun arm (over the torso, so it always reads in front) ----
    _limb(canvas, gunShoulder, gunElbow, 9, suit);
    _limb(canvas, gunElbow, gunHand, 8, skin);

    // ---- Sidearm — always in hand; levelled when aiming, carried angled
    // down-and-forward at rest so it never reads as drilling for oil
    // between the boots. ----
    if (weapon != null && crew.alive) {
      final bool levelled = aiming || recoil > 0;
      final Offset u;
      if (levelled) {
        // Along the live aim; the muzzle climbs as the shot kicks.
        final angleRad = aimAngleDeg * pi / 180;
        u = Offset(gunSide * cos(angleRad), -sin(angleRad));
      } else {
        final restAng =
            pi / 2 - gunSide * (0.42 + sin(crew.walkPhase * pi * 2) * 0.12 * crew.walkAmp);
        u = Offset(cos(restAng), sin(restAng));
      }
      final barrelLen = 12.0 + (weapon.weight - 1) * 6;

      _sidearm(canvas, gunHand, u, weapon, metal,
          kickRotate: -gunSide * recoil * 0.30, kickBack: recoil * 4.5);
      canvas.drawCircle(gunHand, 5.5, Paint()..color = skin);

      // Muzzle flash: only the first sliver of the recoil window, at the
      // kicked barrel tip.
      if (recoil > 0.7) {
        // Clamp: (1.0 - 0.7) / 0.3 rounds to 1.0000000000000002, which the
        // withOpacity assert rightly rejects.
        final flashT = ((recoil - 0.7) / 0.3).clamp(0.0, 1.0);
        final tip = gunHand + rotate(u, -gunSide * recoil * 0.30) * (17 + barrelLen);
        canvas.drawCircle(
          tip,
          7 * flashT,
          Paint()
            ..shader = RadialGradient(colors: [
              Colors.white.withOpacity(flashT),
              accent.withOpacity(flashT * 0.7),
              accent.withOpacity(0),
            ]).createShader(Rect.fromCircle(center: tip, radius: max(0.01, 7 * flashT))),
        );
      }
    }

    // ---- Head ----
    final headC2 = headC + Offset(-recoil * 2.5 * gunSide, recoil * 2.6);
    canvas.drawCircle(headC2, headR, Paint()..color = skin);
    canvas.drawArc(
      Rect.fromCircle(center: headC2, radius: headR),
      0.3, pi * 0.75, false,
      Paint()..color = Colors.black.withOpacity(0.06)..style = PaintingStyle.stroke..strokeWidth = 5,
    );

    // Face: expression-driven by combat state — see [_face]. Lining up a
    // shot (aiming, before the recoil hits) reads as a bit of idle
    // chatter/taunting; the recoil snap itself grits the teeth instead.
    _face(canvas, headC2, headR, dir, crew,
        time: time, talking: aiming && recoil <= 0, firing: recoil > 0.55);

    _headgear(canvas, raft.look, headC2, headR, dir);

    canvas.restore();
    canvas.restore();
  }

  /// The sidearm itself: a metal receiver, a barrel whose length reflects
  /// the weapon's weight, an accent-coloured muzzle cap, and a grip stub —
  /// drawn with the barrel pointing along [aimDir] from [hand]. Shared by
  /// the standing pose and the ragdoll so a knocked-out character is
  /// drawn holding the exact same gun, not a simplified stand-in.
  /// [kickRotate]/[kickBack] are the standing pose's recoil kick; the
  /// ragdoll never passes them.
  void _sidearm(
    Canvas canvas,
    Offset hand,
    Offset aimDir,
    WeaponDef weapon,
    Color metal, {
    double kickRotate = 0,
    double kickBack = 0,
  }) {
    final barrelLen = 12.0 + (weapon.weight - 1) * 6;
    canvas.save();
    canvas.translate(hand.dx, hand.dy);
    canvas.rotate(atan2(aimDir.dy, aimDir.dx));
    if (kickRotate != 0 || kickBack != 0) {
      canvas.rotate(kickRotate);
      canvas.translate(-kickBack, 0);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-4, -3.5, 9, 4), const Radius.circular(2)),
      Paint()..color = metal,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(5, -2.6, barrelLen, 3.2), const Radius.circular(1.6)),
      Paint()..color = metal,
    );
    canvas.drawRect(Rect.fromLTWH(5 + barrelLen, -2.6, 2.4, 3.2), Paint()..color = weapon.color);
    // Grip: a short stub below the receiver where the hand wraps.
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-1.5, 0.5, 5, 6), const Radius.circular(2)),
      Paint()..color = const Color(0xFF23262B),
    );
    canvas.restore();
  }

  /// Draws a crew member straight from their live ragdoll pose: limbs are
  /// stroked between the verlet points, so whatever tangle the physics
  /// produced is exactly what you see. The gun stays in the nearest hand.
  void _ragdollBody(
    Canvas canvas,
    Raft raft,
    Crew crew,
    double dir,
    WeaponDef? weapon,
    double time,
  ) {
    final pose = crew.pose!;
    final skin = _skinFor(raft.look);
    final suit = raft.playerIndex == 0 ? const Color(0xFF2D4F8F) : raft.loadout.color;
    const boot = Color(0xFF23262B);
    const metal = Color(0xFF3B3F45);

    void limbTo(RagdollPoint a, RagdollPoint b, double w, Color color) =>
        _limb(canvas, a.pos, b.pos, w, color);

    // Legs first (behind the torso). Each boot is oriented along its own
    // shin instead of sitting as a bare circle, so a sprawled leg still
    // reads as a booted foot, not a ball-joint.
    for (final foot in [pose.footL, pose.footR]) {
      limbTo(pose.hip, foot, 10, boot);
      final shin = foot.pos - pose.hip.pos;
      final shinAng = shin.distance > 1 ? atan2(shin.dy, shin.dx) : pi / 2;
      canvas.save();
      canvas.translate(foot.pos.dx, foot.pos.dy);
      canvas.rotate(shinAng + pi / 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 15, height: 9),
          const Radius.circular(4.5),
        ),
        Paint()..color = boot,
      );
      canvas.restore();
    }

    // Support arm behind the torso.
    limbTo(pose.neck, pose.handL, 8.5, suit);
    canvas.drawCircle(pose.handL.pos, 5.0, Paint()..color = skin);

    // Torso: a rounded slab spanning neck→hip, oriented along the spine —
    // same shape and shading band as the standing body.
    final spine = pose.neck.pos - pose.hip.pos;
    final spineAng = atan2(spine.dy, spine.dx);
    const torsoW = 29.0, torsoH = 27.0;
    canvas.save();
    canvas.translate(pose.hip.pos.dx, pose.hip.pos.dy);
    canvas.rotate(spineAng + pi / 2);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(-torsoW / 2, -torsoH, torsoW, torsoH),
        topLeft: const Radius.circular(11),
        topRight: const Radius.circular(11),
        bottomLeft: const Radius.circular(6),
        bottomRight: const Radius.circular(6),
      ),
      Paint()..color = suit,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-torsoW / 2, -torsoH * 0.4, torsoW, torsoH * 0.4),
        const Radius.circular(6),
      ),
      Paint()..color = Colors.black.withOpacity(0.1),
    );
    canvas.restore();

    // Gun arm in front, still holding the real sidearm — aimed across the
    // body along the line between the two hands, so a limp wrist reads as
    // a limp gun rather than dropping it.
    limbTo(pose.neck, pose.handR, 8.5, suit);
    if (weapon != null && crew.alive) {
      final aim = pose.handR.pos - pose.handL.pos;
      final u = aim.distance > 1 ? aim / aim.distance : Offset(dir, 0);
      _sidearm(canvas, pose.handR.pos, u, weapon, metal);
    }
    canvas.drawCircle(pose.handR.pos, 5.0, Paint()..color = skin);

    // Head, tilted with the spine so a snapped-back head reads — the full
    // face and headgear, same as standing, so the ragdoll is unmistakably
    // the same character mid-tumble rather than a simplified stand-in.
    final hAxis = pose.head.pos - pose.neck.pos;
    final hAng = atan2(hAxis.dy, hAxis.dx) + pi / 2;
    canvas.save();
    canvas.translate(pose.head.pos.dx, pose.head.pos.dy);
    canvas.rotate(hAng * 0.4);
    const headR = 14.0;
    canvas.drawCircle(Offset.zero, headR, Paint()..color = skin);
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: headR),
      0.3, pi * 0.75, false,
      Paint()..color = Colors.black.withOpacity(0.06)..style = PaintingStyle.stroke..strokeWidth = 5,
    );
    // Face: same expression logic as standing — a knockdown almost always
    // comes with a live [Crew.hitReactT], so the wince that triggered the
    // tumble is exactly what's still showing while the body flies.
    _face(canvas, Offset.zero, headR, dir, crew, time: time, talking: false, firing: false);
    _headgear(canvas, raft.look, Offset.zero, headR, dir);
    canvas.restore();
  }

  /// Draws the face — brows, eyes, nose and mouth — centred at [origin] in
  /// the caller's current canvas space. Shared by the standing pose and the
  /// ragdoll so a knocked-down character keeps reading as the exact same
  /// crew member, expression included, mid-tumble.
  ///
  /// The expression is driven entirely by the crew member's live combat
  /// state, highest priority first:
  ///  1. dead — X eyes, same as before.
  ///  2. [Crew.hitReactT] > 0 — a pained wince, set the instant a hit is
  ///     survived (see [BattleWorld._resolve]); this is what a ragdoll shows
  ///     while it's still being thrown by the blow that triggered it.
  ///  3. [firing] — gritted teeth on the sharp end of their own recoil.
  ///  4. [Crew.gloatT] > 0 — a satisfied grin the instant their own shot
  ///     lands on an enemy.
  ///  5. low HP with nothing more urgent happening — a worried look, and a
  ///     faster, nervier blink.
  ///  6. otherwise — a neutral idle face: periodic blinking, and (while
  ///     [talking]) a flapping mouth so lining up a shot doesn't read as a
  ///     frozen photo.
  void _face(
    Canvas canvas,
    Offset origin,
    double headR,
    double dir,
    Crew crew, {
    required double time,
    required bool talking,
    required bool firing,
  }) {
    final dead = !crew.alive;
    final pain = dead ? 0.0 : (crew.hitReactT / BattleConst.hitReactTime).clamp(0.0, 1.0);
    final gloat = dead || pain > 0 ? 0.0 : (crew.gloatT / BattleConst.gloatTime).clamp(0.0, 1.0);
    final lowHp = !dead && pain <= 0 && gloat <= 0 && crew.hpFrac < BattleConst.lowHpFace;

    // Blink: a short, sharp close on a per-character cycle (offset by
    // [Crew.bobPhase] so the crew doesn't blink in lockstep) rather than any
    // extra state — low HP roughly doubles the rate, a nervous flutter, and
    // a pained or dead face never blinks over itself.
    double blink = 0;
    if (!dead && pain <= 0) {
      final period = lowHp ? 1.7 : 3.4;
      final phase = (time + crew.bobPhase * 2.7) % period;
      const closeDur = 0.11;
      if (phase < closeDur) blink = sin((phase / closeDur) * pi);
    }

    // ---- Brows ----
    final browPaint = Paint()
      ..color = const Color(0xFF8A7448)
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    if (pain > 0) {
      // Drawn in hard and angled up toward the centre — a wince.
      canvas.drawLine(origin + const Offset(-8, -3), origin + const Offset(-2.5, -7.5), browPaint);
      canvas.drawLine(origin + const Offset(2.5, -7.5), origin + const Offset(8, -3), browPaint);
    } else if (firing) {
      // Drawn down flat over the eyes — a grimace of effort.
      canvas.drawLine(origin + const Offset(-8, -6.8), origin + const Offset(-2.5, -5.2), browPaint);
      canvas.drawLine(origin + const Offset(2.5, -5.2), origin + const Offset(8, -6.8), browPaint);
    } else if (lowHp) {
      // Inner ends lift — the classic worried tent.
      canvas.drawLine(origin + const Offset(-8, -6.5), origin + const Offset(-2.5, -4.2), browPaint);
      canvas.drawLine(origin + const Offset(2.5, -4.2), origin + const Offset(8, -6.5), browPaint);
    } else {
      canvas.drawLine(origin + const Offset(-8, -5), origin + const Offset(-2.5, -6.5), browPaint);
      canvas.drawLine(origin + const Offset(2.5, -6.5), origin + const Offset(8, -5), browPaint);
    }

    // ---- Eyes ----
    for (final ex in [-4.4, 4.4]) {
      final c = origin + Offset(ex, 0);
      final openH = dead ? 9.0 : max(0.8, 9.0 * (1 - blink * 0.94));
      canvas.drawOval(
        Rect.fromCenter(center: c, width: 7.5, height: openH),
        Paint()..color = Colors.white,
      );
      if (dead) {
        final xp = Paint()
          ..color = RT.ink
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(c + const Offset(-2, -2), c + const Offset(2, 2), xp);
        canvas.drawLine(c + const Offset(2, -2), c + const Offset(-2, 2), xp);
        continue;
      }
      if (pain > 0) {
        // Squeezed shut: an arced line stands in for the pupil.
        canvas.drawArc(
          Rect.fromCenter(center: c, width: 8, height: 8),
          pi * 0.15, pi * 0.7, false,
          Paint()
            ..color = RT.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8
            ..strokeCap = StrokeCap.round,
        );
        continue;
      }
      if (blink > 0.6) continue; // lids fully down — nothing more to draw
      canvas.drawCircle(
        c + Offset(dir * 1.0, 1.2 * (1 - blink)),
        2.2,
        Paint()..color = RT.ink,
      );
    }

    // ---- Nose ----
    canvas.drawOval(
      Rect.fromCenter(center: origin + const Offset(0, 5.5), width: 5, height: 3.6),
      Paint()..color = const Color(0xFFDCC48B),
    );

    // ---- Mouth ----
    const mouthColor = Color(0xFFB9955C);
    if (pain > 0) {
      // A small pained grimace.
      canvas.drawOval(
        Rect.fromCenter(center: origin + const Offset(0, 10), width: 6, height: 5),
        Paint()..color = RT.ink.withOpacity(0.7),
      );
    } else if (firing) {
      // Gritted teeth: a white bar with a centre notch.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: origin + const Offset(0, 9.6), width: 10.5, height: 3.6),
          const Radius.circular(1.2),
        ),
        Paint()..color = Colors.white,
      );
      canvas.drawLine(
        origin + const Offset(0, 8),
        origin + const Offset(0, 11.4),
        Paint()
          ..color = mouthColor
          ..strokeWidth = 1.2,
      );
    } else if (gloat > 0) {
      // A grin: an upward arc that widens in as it fades.
      final path = Path()
        ..moveTo(origin.dx - 5.2, origin.dy + 9)
        ..quadraticBezierTo(origin.dx, origin.dy + 10.5 + gloat * 3.5, origin.dx + 5.2, origin.dy + 9);
      canvas.drawPath(
        path,
        Paint()
          ..color = mouthColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round,
      );
    } else if (lowHp) {
      // A tiny worried "o".
      canvas.drawOval(
        Rect.fromCenter(center: origin + const Offset(0, 10), width: 4.4, height: 4.4),
        Paint()..color = mouthColor,
      );
    } else if (talking) {
      // Flapping open/closed — a bit of idle chatter/taunting while lined
      // up to fire, so the aiming pause doesn't read as a frozen photo.
      final open = sin(time * 11 + crew.bobPhase * 5).abs();
      canvas.drawOval(
        Rect.fromCenter(center: origin + const Offset(0, 10), width: 8, height: 2.4 + open * 4.2),
        Paint()..color = RT.ink.withOpacity(0.7),
      );
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: origin + const Offset(0, 10), width: 9.5, height: 2.6),
          const Radius.circular(2),
        ),
        Paint()..color = mouthColor,
      );
    }
  }

  /// A single thick, rounded-cap "bone" — the building block for every arm
  /// and leg. Always convex and reads as a limb at any rotation, which is
  /// what makes the gun arm safe to swing to an arbitrary angle at runtime
  /// instead of needing a pre-drawn pose per angle.
  void _limb(Canvas canvas, Offset a, Offset b, double width, Color color) {
    canvas.drawLine(
      a, b,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
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
    final top = BattleConst.waterY - lo.width * lo.hull.thickness * 0.55 - 104 + bob;

    final tp = TextPainter(
      text: TextSpan(text: raft.label, style: RT.body(size: 10, color: RT.ink, weight: FontWeight.w800, letterSpacing: 1.2)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(raft.x - tp.width / 2, top - 14));
    // HP is no longer shown here: every crew member carries a dynamic health
    // bar that only appears when they actually take damage (see
    // [_crewHealthBar]).
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
