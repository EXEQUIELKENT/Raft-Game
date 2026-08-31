import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'battle.dart';
import 'maps.dart';
import 'models.dart';
import 'weapon_views.dart';

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

/// How a drawn fist closes on the part it holds — see [_gripFist].
enum FistWrap { stub, tube }

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

    // Screen shake: whole-scene jitter from impacts, while the world's
    // shake energy decays. Two detuned sines read as a camera rattle rather
    // than a slide.
    if (world.shake > 0.3) {
      final a = world.shake;
      canvas.translate(
        (sin(time * 53.3) + sin(time * 27.1) * 0.6) * a * 0.9,
        (cos(time * 47.7) + sin(time * 33.2) * 0.6) * a * 0.5,
      );
    }

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

    // Firearm view: whichever projectile type is equipped defines the model
    // geometry, the grip layout and the firing animation. Each crew member
    // carries their own variant of the caliber (see [_variantSets]).
    final equippedId = crew.equipped ?? weapon?.id;
    final wv = WeaponView.forCrew(equippedId, weapon,
        variant: WeaponView.variantForPhase(crew.bobPhase, equippedId ?? 'tennis'));
    final accent = Weapons.byId(wv.id).color;

    // Equip lift: 1 raised in the grip, 0 lowered to the hip mid-swap.
    final lift = crew.swapping ? ((crew.swapT - 0.5).abs() * 2).clamp(0.0, 1.0) : 1.0;

    // Firing state per view: recoil window, muzzle flash window and pump
    // travel each scale with the caliber being fired.
    double recoil = 0, flashT = 0, pumpT = 0;
    final liveShot = world.shot;
    if (liveShot != null && liveShot.owner == raft.playerIndex && index == raft.activeIndex) {
      final dt = world.elapsed - liveShot.firedAt;
      if (dt >= 0) {
        if (dt < wv.recoilDur) {
          final u = 1 - dt / wv.recoilDur;
          recoil = u * u * (3 - 2 * u); // snap, then decay
        }
        if (dt < wv.flashDur) flashT = (1 - dt / wv.flashDur).clamp(0.0, 1.0);
        if (wv.pumpTravel > 0 && dt < 0.34) pumpT = sin(pi * dt / 0.34);
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
    // Recoil crouches the body — scaled by the caliber's kick, so a tennis
    // ball barely moves the stance and an anchor shot drives the heels in.
    final hipY = footY - legLen + recoil * wv.kick * 0.4;
    final shoulderY = hipY - torsoH;
    final headC = Offset(0, shoulderY - headR - 2);

    final skin = _skinFor(raft.look);
    final suit = raft.playerIndex == 0 ? const Color(0xFF2D4F8F) : lo.color;
    const boot = Color(0xFF23262B);
    const metal = Color(0xFF3B3F45);

    final gunSide = dir >= 0 ? 1.0 : -1.0;
    // A survived torso hit gets a clutch: they stay on their feet, hunch
    // over the wound and press it with the free hand while the wince plays.
    final grabbing = crew.grabT > 0 && crew.alive;
    final leanBack = recoil * 0.16;
    // The upper-body block's common lean: recoil rocks the torso back about
    // the hips, walking adds a slight forward hunch, and a fresh torso hit
    // doubles them over the wound. Arms, torso, weapon and head all draw
    // inside it so they pivot as one.
    final lean = -leanBack * gunSide +
        crew.walkAmp * 0.04 * gunSide -
        (grabbing ? 0.09 : 0) * gunSide;
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
      _taperedLimb(canvas, Offset(foot.dx * 0.8, hipY + hipBobWalk),
          Offset(foot.dx, footY + foot.dy), 12, 9, boot);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(foot.dx, footY + foot.dy + 3), width: 15, height: 9),
          const Radius.circular(4.5),
        ),
        Paint()..color = boot,
      );
    }

    // ---- Arms + firearm -------------------------------------------------
    // The equipped [WeaponView] supplies the grip layout: the firing hand
    // closes on the trigger grip, the support hand solves (analytic IK) to
    // its grip target — foregrip, pump handle or stacked rear heft, chosen
    // per caliber — and the weapon frame hangs off the firing hand.
    final gunShoulder = Offset(gunSide * (torsoW / 2 - 5), shoulderY + 5);
    final suppShoulder = Offset(-gunSide * (torsoW / 2 - 5), shoulderY + 5);
    final sway = sin(time * 1.4 + crew.bobPhase) * 1.6 * wv.sway;

    // Weapon frame transform: weapon-local (0,0) is the forward face of the
    // trigger grip. The frame rotates to the aim line while engaged and is
    // carried at low ready otherwise; the swap ([lift]) drops it toward the
    // hip and steepens the carry angle so the model changes off the
    // shoulder line.
    final bool levelled = (aiming || recoil > 0) && lift > 0.2;
    double bodyAng;
    Offset gripBody;
    if (levelled) {
      final angleRad = aimAngleDeg * pi / 180;
      final aimDir = Offset(gunSide * cos(angleRad), -sin(angleRad));
      // Near max elevation the pure aim-line offset lands the grip inside
      // the head's own silhouette (both hands + weapon read as jammed into
      // the face) — blend in sideways clearance as the shot steepens so it
      // swings out beside the head instead. See [ArmIK.headClearance].
      final steep = sin(angleRad).clamp(0.0, 1.0);
      gripBody = gunShoulder +
          aimDir * wv.holdDist +
          Offset(gunSide * steep * ArmIK.headClearance, 0);
      // Local +x must point along the aim. Screen y-down: a positive canvas
      // rotation tips the muzzle toward the ground, so right-facing aims
      // rotate by NEGATIVE elevation, and a left-facing raft's aim line is
      // the same ray past vertical (angleRad - pi) — never `pi - angleRad`,
      // which mirrors the muzzle height. The bell mouth and receiver
      // underside (the grip hangs at +y) stay below the tube line either
      // way.
      bodyAng = gunSide > 0 ? -angleRad : angleRad - pi;
    } else {
      // Low ready: grip at the hip, muzzle angled down-and-forward, with a
      // walk-cycle sway. Mid-swap the weapon drops toward the other hip.
      final lowered = 1 - lift;
      gripBody = gunShoulder +
          Offset(gunSide * 6, 16 + lowered * 8 + sway * 0.2);
      final restA = 0.9 - crew.walkAmp * 0.12 * sin(crew.walkPhase * pi * 2) + lowered * 0.5;
      bodyAng = gunSide > 0 ? restA : pi - restA;
    }

    // Recoil-aware weapon frame: the whole assembly kicks back along the
    // barrel and the muzzle climbs about the grip. Computed once here and
    // fed to the model, the arms, and the fists alike — because the hands
    // share the weapon's transform, they can never be left hanging when
    // the gun slides.
    final drawnAng = bodyAng - gunSide * recoil * wv.climb;
    final drawnOrigin =
        gripBody - Offset(cos(drawnAng), sin(drawnAng)) * (recoil * wv.kick);

    // Weapon-local -> body space. MUST stay in lockstep with the canvas
    // transform used to draw the firearm below: translate(origin), rotate,
    // scale(1, facing) — grip-centered.
    Offset toBody(double wx, double wy) {
      final p = Offset(wx - wv.gripX, (wy - wv.gripY) * gunSide);
      final c = cos(drawnAng), s = sin(drawnAng);
      return drawnOrigin + Offset(p.dx * c - p.dy * s, p.dx * s + p.dy * c);
    }

    // Support-hand target: choke-up measured from the support SHOULDER
    // (the arm's pivot), along the weapon from its rear — so the hand can
    // rest anywhere on the gun, including behind the grip. Long guns get
    // held short near the receiver, short guns right at the foregrip. At
    // the extreme it degenerates to a rear heft — which is how the
    // cartoon-scale rig actually holds a cannon. The y is the fist's palm
    // CENTRE ([WeaponView.supportPalmY]), not the barrel centre-line, so
    // the solved wrist welds onto the drawn palm instead of stopping short
    // above it.
    final pumpBack = pumpT * wv.pumpTravel;
    final suppAxis = Offset(cos(drawnAng), sin(drawnAng));
    final suppT = ArmIK.chokeUp(
      anchor: drawnOrigin,
      axis: suppAxis,
      shoulder: suppShoulder,
      preferredT: wv.supportForeX - pumpBack - wv.gripX,
      minT: wv.receiverX0 - wv.gripX,
      maxT: (wv.muzzleX - wv.gripX) * 0.85,
    );
    final suppLocal = Offset(wv.gripX + suppT, wv.supportPalmY);
    var suppHand = toBody(suppLocal.dx, suppLocal.dy);

    // Torso clutch: the free hand abandons its grip point and presses the
    // wound instead — the lean above already doubles the body over it.
    if (grabbing) {
      suppHand = Offset(-gunSide * 3.5, shoulderY + torsoH * 0.66);
    }

    // The hands only look right if the arms don't: both elbows break
    // downward/outward under the weapon's weight, solved in the same
    // torso-local space the arms are drawn in, so wrists stay welded to
    // their fists through recoil lean and walk hunch.
    final suppBend = gunSide * wv.supportBend;
    final (suppElbow, suppHandSolved) = ArmIK.solve(suppShoulder, suppHand, bend: suppBend);
    final gunHand = toBody(wv.gripX, wv.gripY);
    final (gunElbow, _) = ArmIK.solve(gunShoulder, gunHand, bend: gunSide);

    // ---- Arms + torso: one leaned block ----
    // The whole upper body — shoulders, arms, torso, weapon and fists —
    // draws inside the torso's recoil lean, so they pivot as one rigid
    // unit and wrists can never detach from grips mid-kick. Within it the
    // order is depth order: far upper arm, torso, far forearm reaching
    // across the chest, near arm, then the weapon with both fists wrapped
    // last, on top.
    canvas.save();
    canvas.translate(0, hipY);
    canvas.rotate(lean);
    canvas.translate(0, -hipY);

    _taperedLimb(canvas, suppShoulder, suppElbow, 13, 11, suit);

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

    // Elbow: a shallow dark crease over the joint so the IK kink reads as
    // a bent arm, not a sharp fold.
    void elbows(Offset e) {
      canvas.drawCircle(
        e,
        5.4,
        Paint()
          ..color = Colors.black.withOpacity(0.14)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    _taperedLimb(canvas, suppElbow, suppHandSolved, 8, 6.5, skin);
    elbows(suppElbow);
    _taperedLimb(canvas, gunShoulder, gunElbow, 13, 11, suit);
    _taperedLimb(canvas, gunElbow, gunHand, 8, 6.5, skin);
    elbows(gunElbow);

    // ---- The equipped firearm + gripping hands ----
    // One transform carries the model AND both fists: the weapon-local
    // positions are identical for hands and geometry, so a fist can't
    // drift off its grip — at any aim angle, facing, or mid-recoil.
    if (crew.alive) {
      canvas.save();
      canvas.translate(drawnOrigin.dx, drawnOrigin.dy);
      canvas.rotate(drawnAng);
      canvas.scale(1, gunSide);
      canvas.translate(-wv.gripX, -wv.gripY);
      _firearm(canvas, wv, accent, metal, pumpT: pumpT);
      // Fists stay character-sized, but one closing on a mortar barrel
      // reads a touch bigger than one on the pop pistol.
      final handScale = (wv.bore / (2 * WeaponView.ballR)).clamp(1.0, 1.3);
      final tubeHalf = wv.barrelThickness / 2;
      final isTube = wv.supportStyle == GripStyle.foregrip;
      final isTop = wv.supportStyle == GripStyle.topHandle;
      // Support hand (far side) closes first — its palm centre is where
      // the IK wrist landed — then the firing hand sits over its grip on
      // the near side. Layering both over the model is what reads as
      // "barrel passing through a wrapped fist". While a torso clutch has
      // the free hand pressed to the wound, the weapon rides one-handed.
      if (!grabbing) {
        _gripFist(
          canvas,
          suppLocal,
          skin,
          wrap: isTube || isTop ? FistWrap.tube : FistWrap.stub,
          tubeHalf: tubeHalf,
          tubeCenterDy: isTube || isTop ? wv.supportPalmY.abs() : 0,
          gripTopY: wv.stubTopY,
          foregrip: isTube,
          over: isTop,
          scale: handScale,
        );
      }
      _gripFist(
        canvas,
        Offset(wv.gripX, wv.gripY),
        skin,
        wrap: FistWrap.stub,
        gripTopY: wv.stubTopY,
        thumb: true,
        scale: handScale,
      );
      canvas.restore();

      // Muzzle flash at the true muzzle tip — size and burn time come from
      // the view, so the mortar barks and the pop pistol snaps.
      if (flashT > 0) {
        final tip = toBody(wv.muzzleX, 0);
        final r = wv.flashR * flashT;
        canvas.drawCircle(
          tip,
          r,
          Paint()
            ..shader = RadialGradient(colors: [
              Colors.white.withOpacity(flashT),
              accent.withOpacity(flashT * 0.7),
              accent.withOpacity(0),
            ]).createShader(Rect.fromCircle(center: tip, radius: max(0.01, r))),
        );
        // Spreaders and cannons show a bright ring past the prongs.
        if (wv.prongLen > 0) {
          canvas.drawCircle(
            tip,
            r * 1.4,
            Paint()
              ..color = accent.withOpacity(flashT * 0.3)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        }
      }
    }

    // The clutching hand pressed over the wound — drawn after the torso,
    // before the injuries so the marks show around the pressed palm.
    if (grabbing) {
      final press = suppHandSolved;
      canvas.drawCircle(press, 6.4, Paint()..color = skin);
      canvas.drawLine(
        press + const Offset(-3.4, 1.2), press + const Offset(3.4, 1.2),
        Paint()
          ..color = Colors.black.withOpacity(0.24)
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round,
      );
    }

    // Bruises and cuts show off how much punishment they've taken.
    _drawInjuries(
      canvas,
      crew,
      torC: Offset(0, hipY - torsoH / 2),
      legC: Offset((feet[0].dx + feet[1].dx) / 2, footY + 2),
      armC: Offset(gunSide * 4, shoulderY + 14),
      headC: headC,
      dir: dir,
    );

    // ---- Head ----
    final headC2 = headC + Offset(-recoil * 2.5 * gunSide, recoil * 2.6);
    canvas.drawCircle(headC2, headR, Paint()..color = skin);
    canvas.drawArc(
      Rect.fromCircle(center: headC2, radius: headR),
      0.3, pi * 0.75, false,
      Paint()..color = Colors.black.withOpacity(0.06)..style = PaintingStyle.stroke..strokeWidth = 5,
    );

    // Face: expression-driven by combat state — see [_face]. Lining up a
    // shot is a focused squint, not chatter; the recoil itself grits the
    // teeth, and idle fidgets only surface when nothing is urgent.
    _face(canvas, headC2, headR, dir, crew,
        time: time, aiming: aiming, firing: recoil > 0);

    _headgear(canvas, raft.look, headC2, headR, dir);

    canvas.restore();
    canvas.restore();
  }

  /// Fist body + knuckle shading shared by the wraps below: a rounded palm
  /// block with a soft outline so hands read against the weapon, not as
  /// flat blobs on top of it.
  void _fistBody(Canvas canvas, Offset c, double w, double h, Color skin) {
    final r = RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: w, height: h),
      Radius.circular((w < h ? w : h) * 0.42),
    );
    canvas.drawRRect(r, Paint()..color = skin);
    canvas.drawRRect(
      r,
      Paint()
        ..color = Colors.black.withOpacity(0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  /// How a fist closes on the part it holds.
  ///
  /// - [FistWrap.stub]: around a near-vertical grip — palm centered on the
  ///   grip point, three knuckle creases on the muzzle-facing side, and a
  ///   thumb running up the stub to press under the receiver ([gripTopY]).
  ///   The stub pokes out above and below the fist.
  /// - [FistWrap.tube]: around the barrel/foregrip — [at] is the fist's
  ///   palm centre, hanging [tubeCenterDy] below the tube's centre-line
  ///   (exactly where the IK wrist lands); the palm tucks under the shaft
  ///   and three finger bands curl up OVER the tube (with visible shaft
  ///   segments between them), so the tube reads as passing through a
  ///   closed hand. With [over] the palm rides on TOP of the tube instead
  ///   (carry-handle holds) and the bands curl down over it.
  /// [scale] grows the whole fist slightly for fatter tubes — a fist
  /// gripping a 16-unit mortar barrel shouldn't look like the fist on a
  /// 10-unit pop gun.
  void _gripFist(
    Canvas canvas,
    Offset at,
    Color skin, {
    required FistWrap wrap,
    double tubeHalf = 0,
    double tubeCenterDy = 0,
    double gripTopY = 0,
    bool foregrip = false,
    bool over = false,
    bool thumb = false,
    double scale = 1.0,
  }) {
    final shade = Color.lerp(skin, Colors.black, 0.22)!;
    final crease = Paint()
      ..color = Colors.black.withOpacity(0.22)
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;

    if (wrap == FistWrap.stub) {
      // Palm around the grip stub, centered on the grip point.
      _fistBody(canvas, at, 10.5 * scale, 9.2, skin);
      // Knuckle creases on the muzzle-facing side of the palm.
      canvas.drawLine(at + Offset(0.6 * scale, -2.4), at + Offset(4.9 * scale, -2.6), crease);
      canvas.drawLine(at + Offset(0.9 * scale, -0.4), at + Offset(5.1 * scale, -0.6), crease);
      canvas.drawLine(at + Offset(0.9 * scale, 1.6), at + Offset(4.9 * scale, 1.4), crease);
      if (thumb) {
        // Thumb running up the stub to brace under the receiver.
        final top = gripTopY > 0 ? gripTopY + 0.6 : at.dy - 4.6;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(at.dx + 1.4, top, 4.4 * scale, (at.dy + 1.4) - top),
            const Radius.circular(1.9),
          ),
          Paint()..color = skin,
        );
      }
    } else {
      // Palm mass against the tube — [at] IS the palm centre, so the
      // solved wrist welds straight onto it. Under-barrel holds tuck the
      // palm below the shaft; carry-handle holds ride above it.
      _fistBody(canvas, at, 11.0 * scale, 8.6, skin);
      // Fingers curling over the barrel — bands from just past the tube's
      // far edge down into the palm (or mirrored, for a top grip), with
      // visible tube segments poking through between them.
      final bandTop = over ? at.dy - 2.2 : at.dy - tubeCenterDy - tubeHalf - 1.7;
      final bandBottom = over ? at.dy + tubeCenterDy + tubeHalf + 1.7 : at.dy + 2.2;
      for (final fx in [-3.2, -0.1, 3.0]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(at.dx + fx * scale - 1.4, bandTop, 2.8 * scale, bandBottom - bandTop),
            const Radius.circular(1.4),
          ),
          Paint()..color = shade,
        );
      }
      if (foregrip) {
        // Thumb hooking the muzzle-side underside of the grip.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: at + Offset(5.0 * scale, 0.4),
              width: 4.6,
              height: 3.0,
            ),
            const Radius.circular(1.5),
          ),
          Paint()..color = skin,
        );
      }
    }
  }
  /// The equipped firearm, drawn in weapon-local coordinates: origin at the
  /// trigger grip, +x toward the muzzle, +y down. A blunderbuss silhouette
  /// sized by the [WeaponView]: a slim shaft barrel flaring into a bell
  /// mouth wide enough for the round it fires, a bore-dark opening ringed in
  /// the caliber's accent colour, and furniture (receiver, stock, drum,
  /// grip, prongs, pump) in proportion to the bore.
  void _firearm(
    Canvas canvas,
    WeaponView wv,
    Color accent,
    Color metal, {
    double pumpT = 0,
  }) {
    final t = wv.barrelThickness;
    final half = wv.bore / 2;
    const wood = Color(0xFF8A5F35);
    final darkMetal = Color.lerp(metal, Colors.black, 0.42)!;

    // Butt stock behind the receiver — a shoulder wedge on the heavies.
    if (wv.stockLen > 0) {
      final stockH = wv.receiverH * 0.46;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(wv.receiverX0 - wv.stockLen,
              wv.receiverHalf * 0.14 - stockH * 0.5, wv.stockLen + 3, stockH),
          const Radius.circular(2.5),
        ),
        Paint()..color = wood,
      );
    }

    // Ammunition drum hanging under the receiver (drawn first so the
    // mechanism boxes sit over its mounting).
    if (wv.drumR > 0) {
      final drumC = Offset(
        (wv.receiverX1 + wv.barrelX0) / 2,
        wv.receiverHalf + wv.drumR * 0.62 - 1,
      );
      canvas.drawCircle(drumC, wv.drumR, Paint()..color = darkMetal);
      canvas.drawCircle(drumC, wv.drumR * 0.55, Paint()..color = accent);
    }

    // Shaft barrel: slim, so both fists can actually close around it.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(wv.barrelX0, -t / 2, wv.barrelX1 - wv.barrelX0, t),
        Radius.circular(t / 2.4),
      ),
      Paint()..color = metal,
    );
    // Top-light along the shaft so the tube reads round, not flat.
    canvas.drawLine(
      Offset(wv.barrelX0 + 1.5, -t / 2 + 1.2),
      Offset(wv.barrelX1 - 1.5, -t / 2 + 1.2),
      Paint()
        ..color = Colors.white.withOpacity(0.25)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );

    // Wooden handguard furniture over the front of the shaft (AK pattern).
    if (wv.woodFurniture) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(wv.barrelX0 + 1, -t / 2 - 1.2,
              (wv.barrelX1 - wv.barrelX0) * 0.62, t + 2.4),
          const Radius.circular(2.5),
        ),
        Paint()..color = wood,
      );
    }

    // Bell mouth: the flare that matches the muzzle to the round's size.
    final bell = Path()
      ..moveTo(wv.barrelX1 - 1, -t / 2 + 0.5)
      ..quadraticBezierTo(wv.muzzleX - half * 0.5, -t / 2, wv.muzzleX - 2, -half)
      ..lineTo(wv.muzzleX - 2, half)
      ..quadraticBezierTo(wv.muzzleX - half * 0.5, t / 2, wv.barrelX1 - 1, t / 2 - 0.5)
      ..close();
    canvas.drawPath(bell, Paint()..color = Color.lerp(metal, Colors.white, 0.12)!);

    // The bore itself: a dark recessed opening at the muzzle plane...
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(wv.muzzleX - 2.6, -half + 0.6, 3.0, wv.bore - 1.2),
        Radius.circular(half * 0.5),
      ),
      Paint()..color = darkMetal,
    );
    // ...rimmed in the caliber's accent, so the muzzle reads at a glance
    // as the right size for the projectile.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(wv.muzzleX - 1.6, -half, 1.9, wv.bore),
        Radius.circular(half * 0.55),
      ),
      Paint()..color = accent,
    );

    // Muzzle prongs / brake fins splaying off the bell (spreaders, cannon).
    if (wv.prongLen > 0) {
      final prong = Paint()
        ..color = metal
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round;
      for (final s in [-1.0, 1.0]) {
        canvas.drawLine(
          Offset(wv.muzzleX - 1.5, s * (half - 0.5)),
          Offset(wv.muzzleX + wv.prongLen, s * (half + 2.8)),
          prong,
        );
      }
    }

    // Receiver — the boxy action housing the round.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
            wv.receiverX0, -wv.receiverHalf, wv.receiverX1 - wv.receiverX0, wv.receiverH),
        const Radius.circular(3),
      ),
      Paint()..color = metal,
    );
    // Caliber accent band on the receiver, tying the gun to its round.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(wv.receiverX0 + 1.5, -wv.receiverHalf + 2.0,
            wv.receiverX1 - wv.receiverX0 - 3.0, 2.6),
        const Radius.circular(1.3),
      ),
      Paint()..color = accent.withOpacity(0.85),
    );

    // Pump slide — hangs under the shaft, runs its cycle rearward on fire
    // (the support-hand target tracks the same offset).
    if (wv.pumpTravel > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(wv.pumpX0 - pumpT * wv.pumpTravel, t / 2 - 1.0,
              wv.pumpX1 - wv.pumpX0, 4.8),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xFF23262B),
      );
    }

    // Foregrip block under the shaft where the support hand clamps.
    if (wv.supportStyle == GripStyle.foregrip) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(wv.supportForeX - 2.4, t / 2 - 1, 4.8, 5.4),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xFF23262B),
      );
    }

    // Trigger grip: a stub dropping out of the receiver's underside —
    // hand-sized, not barrel-sized, which is what keeps the fists looking
    // right next to a wide gun.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(wv.gripX - 3.8, wv.stubTopY, 7.6, 10.4),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF23262B),
    );

    // Carry handle above the barrel (top-handle holds grip this).
    if (wv.handleX > 0) {
      final railY = -t / 2 - 4.6;
      canvas.drawLine(
        Offset(wv.handleX - 3.2, -t / 2), Offset(wv.handleX - 3.2, railY),
        Paint()..color = const Color(0xFF23262B)..strokeWidth = 2.4,
      );
      canvas.drawLine(
        Offset(wv.handleX + 3.2, -t / 2), Offset(wv.handleX + 3.2, railY),
        Paint()..color = const Color(0xFF23262B)..strokeWidth = 2.4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(wv.handleX - 4.6, railY - 1.6, 9.2, 3.0),
          const Radius.circular(1.5),
        ),
        Paint()..color = const Color(0xFF23262B),
      );
    }

    // Rifle front sight post (AK-pattern models).
    if (wv.sightX > 0) {
      final paint = Paint()
        ..color = const Color(0xFF23262B)
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(wv.sightX, -t / 2), Offset(wv.sightX, -t / 2 - 4.6), paint);
      canvas.drawLine(
        Offset(wv.sightX - 2.2, -t / 2 - 4.6), Offset(wv.sightX + 2.2, -t / 2 - 4.6),
        paint,
      );
    }
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

    // Support arm behind the torso — unless a torso hit left them clutching
    // the wound, in which case the hand grabs the spot instead of flailing.
    if (crew.grabT > 0) {
      final grab = (pose.neck.pos + pose.hip.pos) / 2 +
          Offset(dir >= 0 ? 4 : -4, 2);
      _limb(canvas, pose.neck.pos, grab, 8.5, suit);
      canvas.drawCircle(grab, 5.2, Paint()..color = skin);
      canvas.drawLine(
        grab + const Offset(-2.4, 0), grab + const Offset(2.4, 0),
        Paint()
          ..color = Colors.black.withOpacity(0.2)
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round,
      );
    } else {
      _limb(canvas, pose.neck.pos, pose.handL.pos, 8.5, suit);
      canvas.drawCircle(pose.handL.pos, 5.0, Paint()..color = skin);
    }

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

    // Gun arm in front, still holding the equipped firearm — the same view
    // the standing body draws, aimed across the body along the line between
    // the two hands, so a limp wrist reads as a limp gun rather than
    // dropping it.
    limbTo(pose.neck, pose.handR, 8.5, suit);
    if (weapon != null || crew.equipped != null) {
      final equippedId = crew.equipped ?? weapon!.id;
      final wv = WeaponView.forCrew(equippedId, weapon,
          variant: WeaponView.variantForPhase(crew.bobPhase, equippedId));
      final aim = pose.handR.pos - pose.handL.pos;
      final u = aim.distance > 1 ? aim / aim.distance : Offset(dir, 0);
      canvas.save();
      canvas.translate(pose.handR.pos.dx, pose.handR.pos.dy);
      canvas.rotate(atan2(u.dy, u.dx));
      canvas.scale(1, dir >= 0 ? 1 : -1);
      canvas.translate(-wv.gripX, -wv.gripY);
      _firearm(canvas, wv, Weapons.byId(wv.id).color, metal);
      // The firing hand stays wrapped around the grip mid-tumble — same
      // fist, same frame and caliber scale as the standing pose.
      _gripFist(
        canvas,
        Offset(wv.gripX, wv.gripY),
        skin,
        wrap: FistWrap.stub,
        gripTopY: wv.stubTopY,
        thumb: true,
        scale: (wv.bore / (2 * WeaponView.ballR)).clamp(1.0, 1.3),
      );
      canvas.restore();
    }

    // Bruises and cuts show off how much punishment they've taken.
    _drawInjuries(
      canvas,
      crew,
      torC: (pose.neck.pos + pose.hip.pos) / 2,
      legC: (pose.footL.pos + pose.footR.pos) / 2,
      armC: (pose.handL.pos + pose.handR.pos) / 2,
      headC: pose.head.pos,
      dir: dir,
    );

    // Head, tilted with the spine so a snapped-back head reads — the full
    // face and headgear, same as standing, so the ragdoll is unmistakably
    // the same character mid-tumble rather than a simplified stand-in.
    final hAxis = pose.head.pos - pose.neck.pos;
    var hAng = atan2(hAxis.dy, hAxis.dx) + pi / 2; // 0 = upright, π = inverted
    // Never draw the face upside down: wrap the tilt to the *closest*
    // upright orientation, so a body mid-backflip shows a face that reads
    // as a wobble rather than an inverted skull. Fully upside-down bodies
    // snap the head back near upright, exactly like a cartoony knockdown.
    while (hAng > pi / 2) hAng -= pi;
    while (hAng < -pi / 2) hAng += pi;
    canvas.save();
    canvas.translate(pose.head.pos.dx, pose.head.pos.dy);
    canvas.rotate(hAng * 0.6);
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
    _face(canvas, Offset.zero, headR, dir, crew,
        time: time, aiming: false, firing: false);
    _headgear(canvas, raft.look, Offset.zero, headR, dir);
    canvas.restore();
  }

  /// Draws the face — brows, eyes, nose and mouth — centred at [origin] in
  /// the caller's current canvas space. Shared by the standing pose and the
  /// ragdoll so a knocked-down character keeps reading as the exact same
  /// crew member, expression included, mid-tumble.
  ///
  /// The expression is driven by the crew member's live combat state,
  /// highest priority first:
  ///  1. dead — X eyes, same as before.
  ///  2. [Crew.hitReactT] > 0 — a pained wince, set the instant a hit is
  ///     survived (see [BattleWorld._resolve]); this is what a ragdoll shows
  ///     while it's still being thrown by the blow that triggered it.
  ///  3. [firing] — gritted teeth for the whole recoil: the mouth is busy
  ///     with effort, never with chatter.
  ///  4. [Crew.gloatT] > 0 — a satisfied grin the instant their own shot
  ///     lands on an enemy.
  ///  5. [aiming] — a focused squint: narrowed eyes, furrowed brows, a firm
  ///     mouth. Deliberately silent — lining up a shot is concentration.
  ///  6. low HP — a worried look and a faster, nervier blink.
  ///  7. an idle micro-activity ([Crew.idle]) — yawn, whistle (with floating
  ///     music notes), brief chatter, a wandering gaze, or a brow waggle
  ///     with a smirk — whatever [Crew.updateIdle] last picked.
  ///  8. otherwise — a neutral idle face with periodic blinking.
  void _face(
    Canvas canvas,
    Offset origin,
    double headR,
    double dir,
    Crew crew, {
    required double time,
    required bool aiming,
    required bool firing,
  }) {
    final dead = !crew.alive;
    final pain = dead ? 0.0 : (crew.hitReactT / BattleConst.hitReactTime).clamp(0.0, 1.0);
    final gloat = dead || pain > 0 ? 0.0 : (crew.gloatT / BattleConst.gloatTime).clamp(0.0, 1.0);
    final lowHp = !dead && pain <= 0 && gloat <= 0 && crew.hpFrac < BattleConst.lowHpFace;
    // Idle fidgets only surface when nothing more urgent is on the face —
    // and the active shooter keeps a straight face while aiming (the world
    // also stops picking new activities for them).
    final idleAct = (!dead && pain <= 0 && gloat <= 0 && !aiming && !firing)
        ? crew.idle
        : CrewIdle.none;
    // 0..1 progress through the current activity, so expressions can ease
    // in and out over its lifetime.
    final idleK = idleAct == CrewIdle.none
        ? 0.0
        : (1 - (crew.idleT / (crew.idleDur == 0 ? 1 : crew.idleDur))).clamp(0.0, 1.0);
    final yawnEnv = idleAct == CrewIdle.yawn ? sin(pi * idleK) : 0.0;
    final wag =
        idleAct == CrewIdle.browWaggle ? sin(time * 7 + crew.bobPhase * 4) : 0.0;

    // Blink: a short, sharp close on a per-character cycle (offset by
    // [Crew.bobPhase] so the crew doesn't blink in lockstep) rather than any
    // extra state — low HP roughly doubles the rate, a nervous flutter, and
    // a pained or dead face never blinks over itself. A yawn squeezes the
    // lids shut with the same envelope as the mouth.
    double blink = 0;
    if (!dead && pain <= 0) {
      final period = lowHp ? 1.7 : 3.4;
      final phase = (time + crew.bobPhase * 2.7) % period;
      const closeDur = 0.11;
      if (phase < closeDur) blink = sin((phase / closeDur) * pi);
    }
    if (yawnEnv > 0) blink = max(blink, yawnEnv * 0.9);

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
    } else if (aiming) {
      // Furrowed in concentration — inner ends pulled down toward the nose.
      canvas.drawLine(origin + const Offset(-8, -4.6), origin + const Offset(-2.5, -6.2), browPaint);
      canvas.drawLine(origin + const Offset(2.5, -6.2), origin + const Offset(8, -4.6), browPaint);
    } else if (idleAct == CrewIdle.yawn) {
      // Raised high — sleepy surprise.
      canvas.drawLine(origin + const Offset(-8, -6.4), origin + const Offset(-2.5, -8.2), browPaint);
      canvas.drawLine(origin + const Offset(2.5, -8.2), origin + const Offset(8, -6.4), browPaint);
    } else if (idleAct == CrewIdle.browWaggle) {
      // Alternating bobs — the well-well-well.
      final l = wag * 2.2;
      final r = -wag * 2.2;
      canvas.drawLine(origin + Offset(-8, -5 + l), origin + Offset(-2.5, -6.5 + l), browPaint);
      canvas.drawLine(origin + Offset(2.5, -6.5 + r), origin + Offset(8, -5 + r), browPaint);
    } else if (lowHp) {
      // Inner ends lift — the classic worried tent.
      canvas.drawLine(origin + const Offset(-8, -6.5), origin + const Offset(-2.5, -4.2), browPaint);
      canvas.drawLine(origin + const Offset(2.5, -4.2), origin + const Offset(8, -6.5), browPaint);
    } else {
      canvas.drawLine(origin + const Offset(-8, -5), origin + const Offset(-2.5, -6.5), browPaint);
      canvas.drawLine(origin + const Offset(2.5, -6.5), origin + const Offset(8, -5), browPaint);
    }

    // ---- Eyes ----
    // Where the pupils sit: pinned toward the enemy while aiming (through a
    // squint), wandering side to side while idly looking around, otherwise
    // tracking the facing direction with the blink dip.
    Offset pupilShift;
    double squint = 0;
    if (aiming) {
      pupilShift = Offset(dir * 0.8, 1.0);
      squint = 0.42;
    } else if (idleAct == CrewIdle.lookAround) {
      final scan = sin(time * 2.8 + crew.bobPhase * 3);
      pupilShift = Offset(dir * 1.0 + scan * 2.6, 1.0 * (1 - blink));
    } else {
      pupilShift = Offset(dir * 1.0, 1.2 * (1 - blink));
    }
    for (final ex in [-4.4, 4.4]) {
      final c = origin + Offset(ex, 0);
      final openH = dead ? 9.0 : max(0.8, 9.0 * (1 - blink * 0.94) * (1 - squint));
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
        c + pupilShift,
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
    } else if (yawnEnv > 0) {
      // The big slow yawn — a tall oval that blooms, then closes.
      canvas.drawOval(
        Rect.fromCenter(
          center: origin + const Offset(0, 10.5),
          width: 6.5,
          height: 2.2 + yawnEnv * 7.5,
        ),
        Paint()..color = RT.ink.withOpacity(0.7),
      );
    } else if (idleAct == CrewIdle.whistle) {
      // Puckered lips, with two little notes drifting off the mouth.
      canvas.drawOval(
        Rect.fromCenter(center: origin + const Offset(0, 10), width: 3.4, height: 3.8),
        Paint()..color = RT.ink.withOpacity(0.75),
      );
      _musicNotes(canvas, origin, dir, headR, time);
    } else if (idleAct == CrewIdle.chatter) {
      // A brief bout of idle chatter — flapping open/closed, so the deck
      // doesn't read as a row of frozen mannequins.
      final open = sin(time * 11 + crew.bobPhase * 5).abs();
      canvas.drawOval(
        Rect.fromCenter(center: origin + const Offset(0, 10), width: 8, height: 2.4 + open * 4.2),
        Paint()..color = RT.ink.withOpacity(0.7),
      );
    } else if (lowHp) {
      // A tiny worried "o".
      canvas.drawOval(
        Rect.fromCenter(center: origin + const Offset(0, 10), width: 4.4, height: 4.4),
        Paint()..color = mouthColor,
      );
    } else if (idleAct == CrewIdle.browWaggle) {
      // A lopsided smirk to match the waggle.
      final path = Path()
        ..moveTo(origin.dx - 4.6, origin.dy + 10.2)
        ..quadraticBezierTo(origin.dx + 1, origin.dy + 8.4, origin.dx + 5, origin.dy + 9.2);
      canvas.drawPath(
        path,
        Paint()
          ..color = mouthColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round,
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

  /// Bruises and cuts across the whole body, scaled by how much HP the
  /// crew member has lost ([Crew.injuryLevel]). Marks are jittered per
  /// character (from their [Crew.bobPhase]) so the same character shows the
  /// same scars, but they never match their raft mates. Drawn in the
  /// caller's current canvas space — body-local for a standing crew member,
  /// station-local for a ragdoll.
  void _drawInjuries(
    Canvas canvas,
    Crew crew, {
    required Offset torC,
    required Offset legC,
    required Offset armC,
    required Offset headC,
    required double dir,
  }) {
    final level = crew.injuryLevel;
    if (level <= 0) return;
    final rng = Random((crew.bobPhase * 1000).round() ^ 0xC0FFEE);
    double rx(double spread) => rng.nextDouble() * spread - spread / 2;

    final bruise = Paint()..color = const Color(0xFF6D3B8E).withOpacity(0.5);
    final dark = Paint()..color = const Color(0xFF4A2470).withOpacity(0.45);
    final cut = Paint()
      ..color = const Color(0xFFC0392B).withOpacity(0.8)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    // Bruise spots: one on the torso when scuffed, an arm/leg when worse,
    // and a shiner on the cheek when properly battered.
    final spots = <(Offset, double)>[
      (torC + Offset(rx(8), rx(6)), rng.nextDouble() * 2.2 + 2.0),
      if (level >= 2)
        (legC + Offset(rx(6), rx(3)), rng.nextDouble() * 2.2 + 1.8),
      if (level >= 2)
        (armC + Offset(rx(5), rx(4)), rng.nextDouble() * 2.0 + 1.6),
      if (level >= 3)
        (headC + Offset(dir * 3.2 + rx(2), rx(3) + 1), rng.nextDouble() * 1.8 + 1.4),
      if (level >= 3)
        (torC + Offset(rx(10), rx(6)), rng.nextDouble() * 2.0 + 1.8),
    ];
    for (final (at, r) in spots) {
      canvas.drawCircle(at, r, bruise);
      canvas.drawCircle(at + Offset(0.5, 0.4), r * 0.55, dark);
    }

    // Cuts appear once they're properly hurt, another when battered.
    if (level >= 2) {
      final c = torC + Offset(rx(6), rx(4));
      canvas.drawLine(c + const Offset(-2.4, -1), c + const Offset(2.4, 1), cut);
    }
    if (level >= 3) {
      final c = legC + Offset(rx(5), 1.2);
      canvas.drawLine(c + const Offset(-2.2, -0.8), c + const Offset(2.2, 0.9), cut);
    }
  }

  /// Two little music notes drifting up from a whistling mouth — drawn in
  /// the face's head-local space, fading as they rise.
  void _musicNotes(Canvas canvas, Offset origin, double dir, double headR, double time) {
    for (final k in [0.0, 0.45]) {
      final rise = (time * 10 + k * 12) % 12;
      final a = (1 - rise / 12).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = RT.ink.withOpacity(0.5 * a)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final c = origin +
          Offset(
            dir * (headR * 0.85 + 3) + sin(time * 3 + k * 5) * 1.5,
            -headR * 0.3 - rise - k * 3,
          );
      canvas.drawCircle(c, 1.8, paint);
      canvas.drawLine(c + const Offset(1.6, -0.6), c + const Offset(1.6, -6.2), paint);
      canvas.drawLine(c + const Offset(1.6, -6.2), c + const Offset(4.0, -7.4), paint);
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

  /// A tapered, capped "bone" — like [_limb], but narrows from [widthA] at
  /// [a] to [widthB] at [b] instead of holding one uniform stroke width.
  ///
  /// Two segments sharing a joint — an upper arm ending at some width, a
  /// forearm starting at a smaller one — leave a visible rim of the wider
  /// segment's color at the seam once both are drawn (the narrower cap
  /// only partly covers the wider one underneath), which reads as a
  /// sleeve cuff instead of the two colors hard-cutting mid-joint. Both
  /// ends get a round cap sized to match their local width, so the taper
  /// reads as one smooth capsule rather than a cut-off wedge, and a soft
  /// shading line runs down one long edge for a hint of roundness without
  /// a gradient.
  void _taperedLimb(
    Canvas canvas,
    Offset a,
    Offset b,
    double widthA,
    double widthB,
    Color color,
  ) {
    final rA = widthA / 2, rB = widthB / 2;
    final delta = b - a;
    final len = delta.distance;
    final paint = Paint()..color = color;
    if (len < 1e-3) {
      canvas.drawCircle(a, max(rA, rB), paint);
      return;
    }
    final unit = delta / len;
    final perp = Offset(-unit.dy, unit.dx);
    final p1 = a + perp * rA;
    final p2 = b + perp * rB;
    final p3 = b - perp * rB;
    final p4 = a - perp * rA;
    canvas.drawPath(
      Path()
        ..moveTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..lineTo(p3.dx, p3.dy)
        ..lineTo(p4.dx, p4.dy)
        ..close(),
      paint,
    );
    canvas.drawCircle(a, rA, paint);
    canvas.drawCircle(b, rB, paint);
    canvas.drawLine(
      p4, p3,
      Paint()
        ..color = Colors.black.withOpacity(0.13)
        ..strokeWidth = min(rA, rB) * 0.7
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
    final r = WeaponView.ballR * s.weapon.weight;
    canvas.drawCircle(s.pos, r + 2, Paint()..color = Colors.black.withOpacity(0.18));
    canvas.drawCircle(s.pos, r, Paint()..color = s.weapon.color);
  }

  void _drawEffects(Canvas canvas) {
    for (final fx in world.effects) {
      final p = fx.progress;
      switch (fx.kind) {
        case 'boom':
          // The gradient is cached on the fx (progress-bucketed); drawing a
          // unit-radius circle through a scaled transform skips the per-frame
          // shader rebuild that hitched on explosive volleys.
          final radius = fx.size * (0.25 + p * 1.35);
          canvas.save();
          canvas.translate(fx.pos.dx, fx.pos.dy);
          canvas.scale(radius);
          canvas.drawCircle(Offset.zero, 1, fx.paintFor(radius));
          canvas.restore();
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
        case 'shock':
          // Expanding blast ring — a squashed ellipse so it reads as a
          // pressure wave skimming the deck/water.
          final sr = fx.size * (0.15 + p * 0.85);
          canvas.drawOval(
            Rect.fromCenter(
              center: fx.pos,
              width: sr * 2,
              height: sr,
            ),
            Paint()
              ..color = Colors.white.withOpacity((1 - p) * 0.7)
              ..style = PaintingStyle.stroke
              ..strokeWidth = (1 - p) * 4 + 1.5,
          );
          canvas.drawOval(
            Rect.fromCenter(
              center: fx.pos,
              width: sr * 1.3,
              height: sr * 0.65,
            ),
            Paint()
              ..color = fx.color.withOpacity((1 - p) * 0.35)
              ..style = PaintingStyle.stroke
              ..strokeWidth = (1 - p) * 3 + 1,
          );
          break;
        case 'fire':
          // Hot fireball core — same cached-gradient path as 'boom'.
          final fr = fx.size * (0.4 + p * 1.1);
          canvas.save();
          canvas.translate(fx.pos.dx, fx.pos.dy);
          canvas.scale(fr);
          canvas.drawCircle(Offset.zero, 1, fx.paintFor(fr));
          canvas.restore();
          break;
        case 'spark':
          // An ember thrown out of the blast.
          canvas.drawCircle(
            fx.pos,
            1.2 + 2.2 * (1 - p),
            Paint()..color = fx.color.withOpacity((1 - p) * 0.85),
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
