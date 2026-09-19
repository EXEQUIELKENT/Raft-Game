import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'battle.dart';
import 'build.dart';
import 'character_art.dart';
import 'characters.dart';
import 'maps.dart';
import 'models.dart';
import 'raft.dart';
import 'weapon_views.dart';

/// ---------------------------------------------------------------------------
/// Scene renderer, drawn in the flat-vector style of the Claude Design mockup:
/// a sky-to-sand-to-sea gradient, drifting clouds, a few horizon props, and
/// big-headed crew sitting on their rafts.
///
/// The world is [BattleConst.worldW] x [BattleConst.worldH] in design units.
/// The canvas is scaled so [BattleConst.viewH] of that height fills the
/// screen — the dead sky above the band is cropped, which is what keeps the
/// crews a decent size on a short screen — and the view is panned by the
/// camera in x (fed back into the world as `viewWidth`, so the visible width
/// varies with device aspect) and in y ([BattleWorld.camY], which holds the
/// camera anchor's waterline steady on terraced seas).
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
    Raft? buildTarget,
  }) {
    _buildTarget = buildTarget;
    // A degenerate canvas is refused rather than divided by.
    //
    // `viewWidth` below is `size.width / scale`, and `scale` is proportional
    // to the height — so a zero-sized paint makes it `0 / 0`, and NaN does
    // not stay put. It is written straight onto the world, where the camera
    // clamp picks it up, and from that moment every frame is NaN: the match
    // renders as a flat void and never recovers, because nothing ever
    // divides its way back to a real number.
    //
    // Layout can legitimately hand over a zero size for a frame — during a
    // route transition, or while a parent is between measurements. Skipping
    // that frame costs nothing and cannot corrupt anything.
    if (size.width <= 0 || size.height <= 0) return;
    // The vertical camera must be on its target before anything is mapped:
    // see [BattleWorld.ensureCamY].
    world.ensureCamY();
    final scale = size.height / BattleConst.viewH;
    world.viewWidth = size.width / scale;
    if (!_decorBuilt) _buildDecor();

    canvas.save();
    canvas.scale(scale);
    canvas.translate(-world.cam, -world.camY);

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

    if (!skipLayers.contains('sky')) _drawSky(canvas, time);
    if (!skipLayers.contains('clouds')) _drawClouds(canvas, time);
    if (!skipLayers.contains('props')) _drawProps(canvas, time);
    if (!skipLayers.contains('water')) _drawWater(canvas, time);
    if (!skipLayers.contains('obstacles')) _drawObstacles(canvas, time);
    if (!skipLayers.contains('rafts')) {
      _drawRafts(
        canvas, time,
        currentPlayer: currentPlayer,
        isAiming: isAiming,
        aimAngleDeg: aimAngleDeg,
        weapon: weapon,
      );
    }
    if (!skipLayers.contains('shot')) _drawShot(canvas);
    if (!skipLayers.contains('effects')) _drawEffects(canvas);

    canvas.restore();
  }

  /// Layers to leave out of the scene.
  ///
  /// Two uses, and they are why this is a real setting rather than a debug
  /// flag. The main menu draws its mascot by rendering an actual raft and
  /// crew through this renderer with everything but `rafts` held out — so
  /// the character on the menu is the same drawing, from the same code, as
  /// the one you play (see `MenuMascot`). And a frame budget is only ever
  /// blown by one or two things, which reading the code is a poor way to
  /// find: rendering repeatedly with one layer held out names the culprit,
  /// and then says whether the fix worked (see `tool/bench.dart`).
  ///
  /// Empty for an ordinary battle frame.
  Set<String> skipLayers = const {};

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

    // A scene may legitimately have nothing on its horizon — the open blue
    // is empty by definition, and that is the point of it. Clouds still go
    // in below; it is only the shoreline props that are skipped.
    for (int i = 0; map.props.isNotEmpty && i < 7; i++) {
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

  /// How far past a raft's own hull anything attached to it can reach: a
  /// sprawled ragdoll, a flag, a speech bubble.
  static const double _raftCullMargin = 170;

  /// True when something [halfWidth] wide centred on [x] touches the camera
  /// window at all. The one place visibility is decided, so every culled
  /// thing uses the same margin logic.
  bool _visible(double x, double halfWidth) =>
      x + halfWidth >= world.cam - 8 &&
      x - halfWidth <= world.cam + world.viewWidth + 8;

  /// The sky and water gradients, built once.
  ///
  /// Both were rebuilt from scratch every frame. They are vertical gradients
  /// over a fixed band of the world — sky from 0 to the waterline, water from
  /// there to the bottom — so the colour at any pixel depends only on its y.
  /// Panning the camera cannot change them, which is why the shader can be
  /// built for a fixed rect and reused however far the view has scrolled.
  Paint? _skyPaint;
  Paint? _waterPaint;

  Paint _bandPaint(Paint? cached, double top, double bottom, List<Color> colors,
      void Function(Paint) store) {
    if (cached != null) return cached;
    final rect = Rect.fromLTWH(0, top, 1, bottom - top);
    final p = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: colors,
      ).createShader(rect);
    store(p);
    return p;
  }

  void _drawSky(Canvas canvas, double time) {
    // The window can lean above the world's top edge when the camera anchor
    // stands on a high terrace, and the gradient clamps there, so the sky is
    // drawn from wherever the view actually starts rather than from the
    // world's own top.
    final top = min(0.0, world.camY) - 40;
    final rect = Rect.fromLTWH(
        world.cam - 40, top, world.viewWidth + 80, BattleConst.waterY + 4 - top);
    canvas.drawRect(
      rect,
      _bandPaint(_skyPaint, 0, BattleConst.waterY + 4, map.sky,
          (p) => _skyPaint = p),
    );
  }

  void _drawClouds(Canvas canvas, double time) {
    for (final c in _clouds) {
      // Slow horizontal drift, wrapped so clouds never run out.
      final x = (c.x + time * c.speed) % (BattleConst.worldW + 400) - 200;
      if (!_visible(x + c.w * 0.5, c.w)) continue;
      // The clouds ride the vertical camera as well: the window slides up
      // and down over terraced seas, and decor pinned to the world's own
      // coordinates would be cropped away by the very move that keeps the
      // crews framed.
      final y = world.camY + c.y * 0.8;
      final paint = Paint()..color = Colors.white.withOpacity(c.opacity);
      final h = c.w * 0.34;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, c.w * 0.62, h), Radius.circular(h)),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + c.w * 0.3, y - h * 0.34, c.w * 0.5, h * 0.9), Radius.circular(h)),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + c.w * 0.6, y - h * 0.1, c.w * 0.42, h * 0.75), Radius.circular(h)),
        paint,
      );
    }
  }


  /// The solid obstacles floating in the channel.
  ///
  /// Every kind is drawn to fill its own collision box exactly — the box is
  /// what the physics uses, and a player judging an arc has to be looking at
  /// the same shape the shot will hit. Anything that overhangs the box would
  /// be a lie about where the hazard is.
  void _drawObstacles(Canvas canvas, double time) {
    for (final o in world.obstacles) {
      if (o.broken) continue;
      if (!_visible(o.pos.dx, o.halfW + 12)) continue;
      final r = o.rect;

      canvas.save();
      canvas.translate(o.pos.dx, o.pos.dy);
      // Floating kinds lean with the swell; anchored ones sit dead still.
      if (o.kind == ObstacleKind.buoy || o.kind == ObstacleKind.crate) {
        canvas.rotate(sin(time * 1.3 + o.bobPhase) * 0.05);
      }
      // Being hit shakes it. A shot now ricochets off rather than bursting,
      // so an obstacle can be struck several times in quick succession —
      // the old response was a bright white overlay on the whole box, which
      // at that rate reads as flicker rather than as impact. A solid thing
      // that gets hit should move, not light up.
      if (o.struckT > 0) {
        final k = (o.struckT / BattleConst.obstacleStruckTime).clamp(0.0, 1.0);
        canvas.translate(sin(o.struckT * 90) * 3.2 * k, 0);
      }
      canvas.translate(-o.pos.dx, -o.pos.dy);

      switch (o.kind) {
        case ObstacleKind.rock:
          _obstacleRock(canvas, r, map.stone, map.stoneShade);
        case ObstacleKind.iceberg:
          // Ice is the one material that does not take the scene's stone
          // colour: an iceberg IS the frozen scene, and tinting it to match
          // the rock beside it would make the two indistinguishable.
          _obstacleRock(canvas, r, const Color(0xFFD6EEF6), const Color(0xFF9EC9DA));
        case ObstacleKind.wreck:
          _obstacleWreck(canvas, r, map.timber, map.timberShade);
        case ObstacleKind.buoy:
          _obstacleBuoy(canvas, r, o);
        case ObstacleKind.crate:
          _obstacleCrate(canvas, r, map.timber, map.timberShade);
        case ObstacleKind.mast:
          _obstacleMast(canvas, r, time, o, map.timber, map.timberShade);
      }

      // Damage: a breakable obstacle cracks open as it takes hits, so you
      // can see how much more it will stand before the line opens up.
      if (o.destructible && o.wear > 0) {
        final crack = Paint()
          ..color = const Color(0xFF2A2520).withOpacity(0.25 + o.wear * 0.5)
          ..strokeWidth = 1.6 + o.wear * 1.6
          ..style = PaintingStyle.stroke;
        final steps = 1 + (o.wear * 3).round();
        for (int i = 0; i < steps; i++) {
          final y = r.top + r.height * (i + 1) / (steps + 1);
          canvas.drawLine(
            Offset(r.left + 2, y),
            Offset(r.right - 2, y + (i.isEven ? 3 : -3)),
            crack,
          );
        }
      }

      canvas.restore();
    }
  }

  /// A lumpy solid: three overlapping humps clipped to the box.
  void _obstacleRock(Canvas canvas, Rect r, Color top, Color shade) {
    canvas.save();
    canvas.clipRect(r);
    final body = Path()
      ..moveTo(r.left, r.bottom)
      ..lineTo(r.left + r.width * 0.16, r.top + r.height * 0.34)
      ..lineTo(r.left + r.width * 0.42, r.top)
      ..lineTo(r.left + r.width * 0.68, r.top + r.height * 0.26)
      ..lineTo(r.right, r.top + r.height * 0.5)
      ..lineTo(r.right, r.bottom)
      ..close();
    canvas.drawPath(body, Paint()..color = top);
    // Shaded right flank, so it reads as solid rather than as a cut-out.
    final side = Path()
      ..moveTo(r.left + r.width * 0.68, r.top + r.height * 0.26)
      ..lineTo(r.right, r.top + r.height * 0.5)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.left + r.width * 0.62, r.bottom)
      ..close();
    canvas.drawPath(side, Paint()..color = shade);
    canvas.restore();
  }

  /// A half-sunk hull: a low dark slab with a broken rib or two.
  void _obstacleWreck(Canvas canvas, Rect r, Color wood, Color shade) {
    canvas.save();
    canvas.clipRect(r);
    final hull = Path()
      ..moveTo(r.left, r.bottom)
      ..lineTo(r.left + r.width * 0.1, r.top + r.height * 0.35)
      ..lineTo(r.right - r.width * 0.14, r.top + r.height * 0.2)
      ..lineTo(r.right, r.bottom)
      ..close();
    canvas.drawPath(hull, Paint()..color = wood);
    final rib = Paint()
      ..color = shade
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (int i = 1; i <= 3; i++) {
      final x = r.left + r.width * (i / 4);
      canvas.drawLine(Offset(x, r.bottom), Offset(x - 3, r.top + r.height * 0.3), rib);
    }
    canvas.restore();
  }

  /// A channel marker: a tall float with a band and a little lamp.
  void _obstacleBuoy(Canvas canvas, Rect r, Obstacle o) {
    canvas.save();
    canvas.clipRect(r);
    final body = RRect.fromRectAndRadius(
      Rect.fromLTRB(r.left, r.top + r.height * 0.22, r.right, r.bottom),
      const Radius.circular(5),
    );
    canvas.drawRRect(body, Paint()..color = const Color(0xFFE0522C));
    canvas.drawRect(
      Rect.fromLTRB(r.left, r.top + r.height * 0.55, r.right, r.top + r.height * 0.72),
      Paint()..color = const Color(0xFFF6E9D8),
    );
    // Mast and lamp on top.
    canvas.drawRect(
      Rect.fromLTRB(r.center.dx - 1.6, r.top + r.height * 0.08,
          r.center.dx + 1.6, r.top + r.height * 0.26),
      Paint()..color = const Color(0xFF43403B),
    );
    canvas.drawCircle(Offset(r.center.dx, r.top + r.height * 0.06), 4,
        Paint()..color = const Color(0xFFFFC94D));
    canvas.restore();
  }

  /// A lashed cargo crate: planks, a cross-brace and a rope band.
  void _obstacleCrate(Canvas canvas, Rect r, Color wood, Color shade) {
    canvas.save();
    canvas.clipRect(r);
    canvas.drawRect(r, Paint()..color = wood);
    final line = Paint()
      ..color = shade
      ..strokeWidth = 2.4;
    canvas.drawLine(r.topLeft, r.bottomRight, line);
    canvas.drawLine(r.topRight, r.bottomLeft, line);
    canvas.drawRect(
      Rect.fromLTRB(r.left, r.top + 3, r.right, r.top + 9),
      Paint()..color = shade,
    );
    canvas.drawRect(
      Rect.fromLTRB(r.left, r.bottom - 9, r.right, r.bottom - 3),
      Paint()..color = shade,
    );
    canvas.restore();
  }

  /// A broken mast standing out of the water, with a tattered pennant.
  void _obstacleMast(Canvas canvas, Rect r, double time, Obstacle o,
      Color wood, Color shade) {
    canvas.save();
    canvas.clipRect(r);
    canvas.drawRect(r, Paint()..color = shade);
    canvas.drawRect(
      Rect.fromLTRB(r.left, r.top, r.left + r.width * 0.42, r.bottom),
      Paint()..color = wood,
    );
    // Cross-spar, so the silhouette reads as a mast and not a post.
    final sparY = r.top + r.height * 0.18;
    canvas.drawRect(
      Rect.fromLTRB(r.left - 14, sparY, r.right + 14, sparY + 4),
      Paint()..color = shade,
    );
    canvas.restore();
    // The pennant is allowed outside the box: it is cloth, it is obviously
    // not solid, and nothing about it invites you to aim at it.
    final wave = sin(time * 3 + o.bobPhase) * 3;
    final flag = Path()
      ..moveTo(r.right, r.top + 4)
      ..lineTo(r.right + 20, r.top + 8 + wave)
      ..lineTo(r.right, r.top + 14);
    canvas.drawPath(flag, Paint()..color = const Color(0xFFD9433C));
  }
  /// The sea, following whatever terraces this match was built with.
  ///
  /// Sampled along x rather than drawn as one rectangle, because the surface
  /// is no longer a straight line: a match can put one raft a good drop above
  /// the other, joined by a falls. Sampling is also what keeps the drawn
  /// surface and the simulated one honest with each other — both read the
  /// same [BattleWorld.waterAt], so a shot splashes down exactly where the
  /// water looks like it is.
  void _drawWater(Canvas canvas, double time) {
    final startX = world.cam - 40;
    final endX = startX + world.viewWidth + 80;
    // Gradient band measured from the HIGHEST water in the world, so the
    // same paint covers every terrace and the deep colour still lands at the
    // bottom of the world.
    final gradTop = BattleConst.waterY - world.water.maxRise;

    final body = Path()..moveTo(startX, BattleConst.worldH);
    for (double x = startX; x <= endX; x += 6) {
      body.lineTo(x, world.waterAt(x));
    }
    body
      ..lineTo(endX, world.waterAt(endX))
      ..lineTo(endX, BattleConst.worldH)
      ..close();
    canvas.drawPath(
      body,
      _bandPaint(_waterPaint, gradTop, BattleConst.worldH,
          [map.water, map.waterDeep], (p) => _waterPaint = p),
    );

    // The falls themselves, before the surface foam so the foam caps them.
    for (final step in world.water.steps) {
      if (step.right < startX - 40 || step.left > endX + 40) continue;
      _waterStep(canvas, step, time);
    }

    // Two offset wave lines along the surface for a bit of motion. They
    // ride the terraces too — a flat highlight across a stepped sea would
    // read as a seam.
    for (int layer = 0; layer < 2; layer++) {
      final path = Path();
      final amp = (layer == 0 ? 3.4 : 2.2) * map.chop;
      final drop = layer == 0 ? 2.0 : 9.0;
      final speed = layer == 0 ? 34.0 : -22.0;
      path.moveTo(startX, world.waterAt(startX) + drop);
      for (double x = startX; x <= endX; x += 14) {
        final y = world.waterAt(x) +
            drop +
            sin((x + time * speed) / 46 + layer) * amp;
        path.lineTo(x, y);
      }
      for (double x = endX; x >= startX; x -= 14) {
        path.lineTo(x, world.waterAt(x) + 26);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = Colors.white.withOpacity(layer == 0 ? 0.22 : 0.12),
      );
    }
  }

  /// Whatever joins two terraces, drawn to suit its kind.
  ///
  /// The surface itself is always a slope, because that is what the
  /// simulation uses — everything that touches the water reads the same
  /// [BattleWorld.waterAt], and a drawn sheer drop over a simulated ramp
  /// would be a lie about where the water is. What changes per kind is the
  /// material laid over that slope, and how wide the slope is in the first
  /// place (see `stepWidthScale`), which is what makes a weir feel abrupt
  /// and a shoal feel like a long wade.
  void _waterStep(Canvas canvas, WaterStep step, double time) {
    final leftY = world.waterAt(step.left - 1);
    final rightY = world.waterAt(step.right + 1);
    if ((leftY - rightY).abs() < 1) return;
    final downhillRight = leftY < rightY;
    final botY = max(leftY, rightY);

    switch (step.kind) {
      case WaterStepKind.falls:
        _stepWhiteWater(canvas, step, time, downhillRight, botY,
            band: 9, bright: 0.72, streaks: 9, foam: 7);
      case WaterStepKind.rapids:
        _stepRapids(canvas, step, time, downhillRight, botY);
      case WaterStepKind.weir:
        _stepWeir(canvas, step, time, downhillRight, botY);
      case WaterStepKind.ledge:
        _stepLedge(canvas, step, time, downhillRight, botY);
      case WaterStepKind.shoal:
        _stepShoal(canvas, step, time, downhillRight, botY);
      case WaterStepKind.iceShelf:
        _stepIce(canvas, step, time, downhillRight, botY);
    }
  }

  /// The surface across a step, as a path.
  Path _stepSurface(WaterStep step) {
    final p = Path()..moveTo(step.left, world.waterAt(step.left));
    for (double x = step.left; x <= step.right; x += 3) {
      p.lineTo(x, world.waterAt(x));
    }
    return p;
  }

  /// The shared white-water treatment: a band riding the slope, streaks
  /// running downhill, and churn at the foot. Every kind uses some of this;
  /// the parameters are what separate a cascade from a gentle run.
  void _stepWhiteWater(
    Canvas canvas,
    WaterStep step,
    double time,
    bool downhillRight,
    double botY, {
    required double band,
    required double bright,
    required int streaks,
    required int foam,
  }) {
    for (final (width, alpha) in [(band, bright * 0.42), (band * 0.5, bright)]) {
      canvas.drawPath(
        _stepSurface(step),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withOpacity(alpha),
      );
    }

    for (int i = 0; i < streaks; i++) {
      final u = ((i / streaks) + time * 0.45) % 1.0;
      final along = downhillRight ? u : 1 - u;
      final x = step.left + step.width * along;
      final y = world.waterAt(x);
      final ahead = downhillRight ? 7.0 : -7.0;
      final y2 = world.waterAt(x + ahead);
      final fade = sin(pi * u);
      canvas.drawLine(
        Offset(x, y + 1.5),
        Offset(x + ahead * 1.6, y2 + 5.5),
        Paint()
          ..color = Colors.white.withOpacity(0.55 * fade)
          ..strokeWidth = 1.8 + (i % 3) * 0.7
          ..strokeCap = StrokeCap.round,
      );
    }

    final footX = downhillRight ? step.right : step.left;
    final drift = downhillRight ? 1.0 : -1.0;
    for (int i = 0; i < foam; i++) {
      final u = ((time * 0.5) + i / foam) % 1.0;
      final fade = (1 - u) * (1 - u);
      canvas.drawCircle(
        Offset(footX + drift * u * 52,
            botY + 2.5 + sin(time * 3.4 + i * 1.7) * 1.8),
        (2.0 + (i % 3) * 1.4) * (0.4 + fade),
        Paint()..color = Colors.white.withOpacity(0.5 * fade + 0.08),
      );
    }

    // The lip: the bright line that makes an edge read as an edge.
    final lipX = downhillRight ? step.left : step.right;
    canvas.drawLine(
      Offset(lipX - 10, world.waterAt(lipX) + 1),
      Offset(lipX + 10, world.waterAt(lipX) + 1),
      Paint()
        ..color = Colors.white.withOpacity(0.8)
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round,
    );
  }

  /// A long shallow run of broken water: no lip, no plunge, just chop all
  /// the way down. Wide and busy rather than tall and loud.
  void _stepRapids(Canvas canvas, WaterStep step, double time,
      bool downhillRight, double botY) {
    canvas.drawPath(
      _stepSurface(step),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withOpacity(0.32),
    );
    // Standing waves: short crests pinned to the slope, each bobbing on its
    // own beat so the whole run seethes instead of scrolling as one sheet.
    const crests = 14;
    for (int i = 0; i < crests; i++) {
      final x = step.left + step.width * ((i + 0.5) / crests);
      final y = world.waterAt(x);
      final bob = sin(time * 5.5 + i * 1.9);
      final w = 5.0 + (i % 3) * 2.5;
      canvas.drawArc(
        Rect.fromCenter(
            center: Offset(x, y + 2 + bob * 1.2), width: w * 2, height: 7),
        pi,
        pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withOpacity(0.3 + (bob + 1) * 0.2),
      );
    }
  }

  /// Built, not grown: a straight concrete sill with a smooth glassy curtain
  /// folding over it and a hard churn in the pool below.
  void _stepWeir(Canvas canvas, WaterStep step, double time,
      bool downhillRight, double botY) {
    final lipX = downhillRight ? step.left : step.right;
    final lipY = world.waterAt(lipX);

    // The sill itself — the one transition that is a structure.
    final sill = Rect.fromLTRB(
      min(lipX, lipX + (downhillRight ? 7.0 : -7.0)),
      lipY - 3,
      max(lipX, lipX + (downhillRight ? 7.0 : -7.0)),
      botY + 6,
    );
    canvas.drawRect(sill, Paint()..color = map.stoneShade);
    canvas.drawRect(
      Rect.fromLTRB(sill.left, sill.top, sill.right, sill.top + 3.5),
      Paint()..color = map.stone,
    );

    // The curtain: smooth and glassy at the top, breaking up further down.
    canvas.drawPath(
      _stepSurface(step),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withOpacity(0.5),
    );
    // Hard churn in the plunge pool — a weir's pool is the violent part.
    final footX = downhillRight ? step.right : step.left;
    final drift = downhillRight ? 1.0 : -1.0;
    for (int i = 0; i < 10; i++) {
      final u = ((time * 0.75) + i / 10) % 1.0;
      final fade = (1 - u);
      canvas.drawCircle(
        Offset(footX + drift * u * 40,
            botY + 3 + sin(time * 6 + i * 2.1) * 3.0),
        (2.4 + (i % 4) * 1.2) * (0.5 + fade * 0.8),
        Paint()..color = Colors.white.withOpacity(0.62 * fade + 0.12),
      );
    }
  }

  /// A rock shelf stepping down in strata — the water is incidental, the
  /// rock is the feature.
  void _stepLedge(Canvas canvas, WaterStep step, double time,
      bool downhillRight, double botY) {
    final topY = min(world.waterAt(step.left - 1), world.waterAt(step.right + 1));
    const bands = 4;
    for (int i = 0; i < bands; i++) {
      final u = (i + 1) / bands;
      final y = topY + (botY - topY) * u;
      final inset = step.width * 0.5 * (downhillRight ? u : 1 - u);
      final l = downhillRight ? step.left : step.left + inset;
      final r = downhillRight ? step.right - inset : step.right;
      canvas.drawRect(
        Rect.fromLTRB(min(l, r), y - (botY - topY) / bands, max(l, r), y + 2),
        Paint()..color = i.isEven ? map.stone : map.stoneShade,
      );
    }
    // A thin skin of water running over it.
    canvas.drawPath(
      _stepSurface(step),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withOpacity(0.42),
    );
    for (int i = 0; i < 5; i++) {
      final u = ((i / 5) + time * 0.35) % 1.0;
      final along = downhillRight ? u : 1 - u;
      final x = step.left + step.width * along;
      canvas.drawLine(
        Offset(x, world.waterAt(x) + 1),
        Offset(x, world.waterAt(x) + 7),
        Paint()
          ..color = Colors.white.withOpacity(0.4 * sin(pi * u))
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  /// A shoal: a long pale ramp of sand or shingle showing through shallow
  /// water. The gentlest transition, and the one that reads as ground.
  void _stepShoal(Canvas canvas, WaterStep step, double time,
      bool downhillRight, double botY) {
    // The bar itself, under the water, fading out into the deeper side.
    final bar = _stepSurface(step)
      ..lineTo(step.right, botY + 20)
      ..lineTo(step.left, botY + 20)
      ..close();
    canvas.drawPath(bar, Paint()..color = map.shore.withOpacity(0.55));
    // The waterline over it: a soft bright edge, no drop.
    canvas.drawPath(
      _stepSurface(step),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withOpacity(0.4),
    );
    // Wash running up and back down the ramp.
    final phase = (sin(time * 1.1) + 1) / 2;
    for (int i = 0; i < 3; i++) {
      final u = ((phase + i / 3) % 1.0);
      final along = downhillRight ? 1 - u : u;
      final x = step.left + step.width * along;
      canvas.drawCircle(
        Offset(x, world.waterAt(x) + 3),
        3.5 * sin(pi * u),
        Paint()..color = Colors.white.withOpacity(0.35 * sin(pi * u)),
      );
    }
  }

  /// A calving ice edge: blocky, pale blue, with meltwater running off it.
  void _stepIce(Canvas canvas, WaterStep step, double time,
      bool downhillRight, double botY) {
    final topY = min(world.waterAt(step.left - 1), world.waterAt(step.right + 1));
    const ice = Color(0xFFDFF1F7);
    const iceShade = Color(0xFFA9CEDD);

    // The shelf: a squared-off block with a broken face, rather than a
    // smooth ramp — ice does not pour, it breaks.
    final face = Path()..moveTo(step.left, world.waterAt(step.left));
    for (double x = step.left; x <= step.right; x += step.width / 5) {
      // Stepped rather than smooth, so the edge reads as fractured.
      final y = world.waterAt(x);
      face.lineTo(x, y);
      face.lineTo(x + step.width / 10, y + (botY - topY) / 8);
    }
    face
      ..lineTo(step.right, botY + 16)
      ..lineTo(step.left, botY + 16)
      ..close();
    canvas.drawPath(face, Paint()..color = iceShade);

    canvas.drawPath(
      _stepSurface(step),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..color = ice,
    );
    // Meltwater: thin, cold, sparse.
    for (int i = 0; i < 4; i++) {
      final u = ((i / 4) + time * 0.3) % 1.0;
      final along = downhillRight ? u : 1 - u;
      final x = step.left + step.width * along;
      canvas.drawLine(
        Offset(x, world.waterAt(x) + 2),
        Offset(x, world.waterAt(x) + 11),
        Paint()
          ..color = Colors.white.withOpacity(0.5 * sin(pi * u))
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _drawProps(Canvas canvas, double time) {
    for (final p in _props) {
      // Scenery is scattered across the whole 3210-wide world; only a
      // fraction of it is ever in shot.
      if (!_visible(p.x, 120 * p.scale)) continue;
      canvas.save();
      canvas.translate(p.x, world.waterAt(p.x));
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
    raftsDrawn = 0;
    for (final raft in world.rafts) {
      // Cull rafts outside the visible window.
      //
      // The rafts sit at x = 210 and 1500..2700 across a 3210-wide world,
      // while the camera window is only about 870 across — so for most of a
      // match three of the four rafts are entirely off screen. Every one of
      // them was still being drawn in full: hull, deck platforms, rigging,
      // and every crew member aboard with their articulated limbs, face,
      // health bar and speech bubble. That was the single largest waste in
      // the frame, and it was being paid every frame of every match.
      //
      // The margin is deliberately generous — a knocked body sprawls well
      // past its raft, and bubbles and status badges sit above it — so
      // nothing pops in at the edge of the view.
      if (!_visible(raft.x, raft.loadout.width * 0.5 + _raftCullMargin)) {
        continue;
      }
      raftsDrawn++;
      final bob = world.bobOf(raft);
      canvas.save();
      canvas.translate(raft.x, bob);

      // Land does not leave a wake.
      if (raft.place.floats) _ripple(canvas, raft, time);
      if (raft.emplacement == Emplacement.raft) {
        if (raft.loadout.hull.hasMast) _mast(canvas, raft);
        _hull(canvas, raft);
      } else {
        _emplacementBase(canvas, raft, time);
      }
      _platforms(canvas, raft);
      _deckStructures(canvas, raft);
      _builtStructure(canvas, raft, time);
      if (identical(raft, _buildTarget)) _buildGhosts(canvas, raft);
      // Everything a working raft accumulates: fenders over the side, a
      // lantern, a flag, coiled rope, stowed oars. Drawn after the deck so
      // it sits on top of the planks, and before the crew so nobody is
      // hidden behind a barrel. All of it is placed from the raft's own
      // seat index and hull width, so it is stable frame to frame and
      // identical on both devices of a networked match.
      _rigging(canvas, raft, time);

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
          canvas.translate(raft.stationX(i), raft.deckY);
        } else {
          // The standing body's own displacement from its station — a crew
          // member walking back after a knock-down is drawn wherever the
          // shuffle actually is.
          canvas.translate(raft.stationX(i) + c.offset.dx, c.offset.dy);
        }
        // Defeated crew go through the death sequence: they never fade
        // while still airborne on the deck — the sink only starts once the
        // body is actually in the water (see BattleWorld's body stepper).
        // The fade layer covers the whole body in whatever pose it died.
        Rect bodyBounds = const Rect.fromLTWH(-130, -150, 260, 230);
        // A layer is only needed while the body is actually translucent, or
        // while the killing-blow flash is compositing over it — both of which
        // are short. It used to be taken for every dead crew member on every
        // frame for as long as the body existed, and saveLayer allocates an
        // offscreen render target the size of the whole body: with a couple
        // of bodies down that is several full-size buffers per frame, which
        // is a large part of why the frame rate fell over the moment shots
        // started landing.
        final fading = _sinkOpacity(c.sinkT) < 0.995 || c.deathFlash > 0;
        if (!c.alive) {
          if (pose != null) bodyBounds = pose.drawBounds;
          canvas.translate(0, _sinkDrop(c));
          if (fading) {
            bodyLayers++;
            canvas.saveLayer(
              bodyBounds.inflate(30),
              Paint()..color = Colors.white.withOpacity(_sinkOpacity(c.sinkT)),
            );
          }
        }
        _crewMember(
          canvas, raft, c, i, time,
          currentPlayer: currentPlayer,
          isAiming: isAiming,
          aimAngleDeg: aimAngleDeg,
          weapon: weapon,
        );
        if (!c.alive) {
          // Killing blow: a flare at the wound with embers coming off it,
          // rather than a beat of pure white over the whole figure.
          //
          // The old version was a full-body overlay at 0.85 alpha on a
          // 0.16s timer — a strobe, and it fired on the same frame the body
          // switched from its standing drawing to a ragdoll. Two
          // discontinuities landing together read as the character being
          // swapped out rather than killed. Pulling the eye to the point of
          // impact instead lets the body hand over underneath it, which is
          // what makes the change of drawing pass unnoticed.
          //
          // It is drawn AFTER the body and inside the same layer, so the
          // flare sits over the wound wherever the tumble has carried it.
          if (c.deathFlash > 0 && fading) {
            final u = 1 - (c.deathFlash / BattleConst.deathFlashTime).clamp(0.0, 1.0);
            // Up fast, down slow — a flare, not a square pulse.
            final f = u < 0.22 ? u / 0.22 : 1 - ((u - 0.22) / 0.78);
            final wound = _deathWoundPos(c);
            canvas.drawCircle(
              wound,
              14 + 26 * u,
              Paint()
                ..color = Colors.white.withOpacity(f * 0.55)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
            );
            canvas.drawCircle(
              wound,
              5 + 9 * u,
              Paint()..color = Colors.white.withOpacity(f * 0.8),
            );
          }
          _deathSparks(canvas, c, time);
          _deathFx(canvas, c, time);
          if (fading) canvas.restore();
        } else if (c.hpBarT > 0) {
          // Dynamic health bar: hidden by default, summoned by damage, and
          // gone again once its animation finishes.
          _crewHealthBar(canvas, raft, c, pose);
        }
        // A boss status stays visible for as long as it is costing the
        // player something. Unlike the health bar it does NOT time out —
        // an effect you cannot see is an effect that reads as the game
        // misbehaving when your shot lands short.
        if (c.alive && c.afflicted) _statusMark(canvas, raft, c, pose, time);
        if (c.alive && c.talking) _speechBubble(canvas, raft, c, pose);
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

  /// Where the killing blow landed, in the same space the body is drawn in.
  ///
  /// Carried along the SPINE rather than held at a fixed offset from the
  /// hip. The wound is recorded in the crew member's own upright frame, so
  /// on a body that is tumbling — which is every dead body here — a fixed
  /// world offset leaves the flare hanging above the corpse instead of
  /// staying on the part that was hit. Measuring it as a fraction of the
  /// hip-to-neck line means it rotates with the body for free.
  Offset _deathWoundPos(Crew c) {
    final pose = c.pose;
    if (pose == null) return c.deathWound;
    // How far up the standing spine the wound sat. The pose's origin is the
    // feet, its hip sits 15 above that, and the spine runs 27 further to the
    // neck — so a head shot at -48 comes out a little past the neck.
    const hipUp = 15.0;
    const spineLen = 27.0;
    final along = (-c.deathWound.dy - hipUp) / spineLen;
    return pose.hip.pos + (pose.neck.pos - pose.hip.pos) * along;
  }

  /// Embers thrown off a fresh kill.
  ///
  /// Deliberately drawn straight rather than pushed through the world's [Fx]
  /// list: these belong to a body that is moving, and an fx is a fixed world
  /// position, so spawned ones would be left hanging in the air behind a
  /// tumbling corpse. Drawing them relative to the wound keeps them with it.
  void _deathSparks(Canvas canvas, Crew c, double time) {
    if (c.deathSpark <= 0) return;
    final u = 1 - (c.deathSpark / BattleConst.deathSparkTime).clamp(0.0, 1.0);
    final wound = _deathWoundPos(c);
    const count = 9;
    for (int k = 0; k < count; k++) {
      // A fixed fan per crew member, so the same death always throws the
      // same sparks — no per-frame randomness to shimmer.
      final a = pi * 2 * (k / count) + c.bobPhase * 2.3;
      // Thrown out fast, then slowing, with a little gravity on them.
      final reach = 34 * (1 - (1 - u) * (1 - u));
      final p = wound +
          Offset(cos(a) * reach, sin(a) * reach * 0.7 + u * u * 20);
      canvas.drawCircle(
        p,
        (2.4 - u * 1.7).clamp(0.5, 2.4),
        Paint()
          ..color = Color.lerp(const Color(0xFFFFE9A8), const Color(0xFFE8743A), u)!
              .withOpacity((1 - u) * 0.9),
      );
    }
  }
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
  /// Laid-out text, reused across frames.
  ///
  /// Every entry costs one text shaping pass; without this the crew's speech
  /// bubbles and the raft name plates re-shaped their strings on every single
  /// frame. Opacity is quantised to sixteenths so a fading bubble reuses one
  /// of a handful of painters rather than forcing a fresh layout per frame.
  final Map<String, TextPainter> _textCache = {};

  TextPainter _text(
    String text, {
    required double size,
    required Color color,
    double alpha = 1,
    FontWeight weight = FontWeight.w800,
    double letterSpacing = 0,
    double maxWidth = double.infinity,
  }) {
    final bucket = (alpha.clamp(0.0, 1.0) * 16).round();
    final key = '$text|$size|${color.value}|$bucket|${weight.index}|$letterSpacing';
    final hit = _textCache[key];
    if (hit != null) return hit;
    // A battle only ever has a handful of distinct lines on screen, but the
    // cache is bounded anyway so a long match can never grow it without end.
    if (_textCache.length > 64) _textCache.clear();
    textLayouts++;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: RT.body(
          size: size,
          color: color.withOpacity(bucket / 16),
          weight: weight,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    _textCache[key] = tp;
    return tp;
  }

  /// A crew member's speech bubble.
  ///
  /// Deliberately small and quiet. Four rafts of two or three crew each can
  /// all be talking at once, and the one thing a bubble must never do is get
  /// between the player and the shot they are lining up — so it is 9pt, it
  /// is translucent, it sits well above the head where the trajectory arc
  /// does not run, and it never grows past a couple of words (the lines in
  /// [Crew] are all short by construction). It also fades over its last
  /// third rather than vanishing, which stops a deck of bubbles from
  /// flickering.
  void _speechBubble(Canvas canvas, Raft raft, Crew c, RagdollPose? pose) {
    final text = c.bubble;
    if (text == null) return;
    // Fade in over the first 12%, out over the last 30%.
    final fadeIn = ((1.6 - c.bubbleT) / 0.19).clamp(0.0, 1.0);
    final fadeOut = (c.bubbleT / 0.5).clamp(0.0, 1.0);
    final alpha = (fadeIn * fadeOut).clamp(0.0, 1.0);
    if (alpha <= 0.02) return;

    final cx = pose != null ? pose.head.pos.dx : 0.0;
    final headTop =
        pose != null ? pose.head.pos.dy : raft.deckY - BattleConst.bodyHeight;
    // Above the status badge when both are showing, so they never overlap.
    final y = headTop - (c.afflicted ? 44 : 28);

    // Laying text out means shaping it, which is expensive — and a bubble
    // fires on every hit, for every crew member hit plus the shooter
    // gloating, then redraws for a second and a half. Building a fresh
    // TextPainter every frame for each of those was a measurable share of
    // the stutter when shots landed. The cache quantises the fade so a line
    // is shaped a handful of times instead of ninety.
    final tp = _text(
      text,
      size: 9,
      color: RT.ink,
      alpha: alpha,
      weight: FontWeight.w800,
      letterSpacing: 0.2,
      maxWidth: 96,
    );

    final w = tp.width + 12;
    final h = tp.height + 7;
    final rect = Rect.fromCenter(center: Offset(cx, y), width: w, height: h);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(7)),
      Paint()..color = Colors.white.withOpacity(alpha * 0.88),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(7)),
      Paint()
        ..color = RT.ink.withOpacity(alpha * 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    // Tail pointing down at the speaker.
    canvas.drawPath(
      Path()
        ..moveTo(cx - 3.5, rect.bottom - 1)
        ..lineTo(cx, rect.bottom + 5)
        ..lineTo(cx + 3.5, rect.bottom - 1)
        ..close(),
      Paint()..color = Colors.white.withOpacity(alpha * 0.88),
    );
    tp.paint(canvas, Offset(cx - tp.width / 2, y - tp.height / 2));
  }

  /// The badge over an afflicted crew member, plus the fresh-hit flash.
  ///
  /// Sits above the head rather than on the body so it survives a tumble,
  /// and pulses gently so it reads as an ongoing condition rather than a
  /// one-off hit marker.
  void _statusMark(
      Canvas canvas, Raft raft, Crew c, RagdollPose? pose, double time) {
    final st = c.status;
    if (st == null) return;
    final cx = pose != null ? pose.head.pos.dx : 0.0;
    final topY = (pose != null
            ? pose.head.pos.dy
            : raft.deckY - BattleConst.bodyHeight) -
        26;
    final pulse = 0.72 + 0.28 * sin(time * 5.2 + c.bobPhase);
    final tint = st.tint;

    // A short white burst on the frame it lands, so the moment is unmissable.
    if (c.statusFlash > 0) {
      canvas.drawCircle(
        Offset(cx, topY + 18),
        30 * (1 - c.statusFlash / 0.6) + 8,
        Paint()..color = tint.withOpacity(c.statusFlash * 0.5),
      );
    }

    canvas.drawCircle(
        Offset(cx, topY), 8.5, Paint()..color = tint.withOpacity(pulse));
    canvas.drawCircle(
      Offset(cx, topY),
      8.5,
      Paint()
        ..color = RT.ink.withOpacity(0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // A tiny glyph per effect — no text at this scale, it would be unreadable.
    final glyph = Paint()
      ..color = RT.ink
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final o = Offset(cx, topY);
    switch (st) {
      case StatusEffect.chilled:
        for (int i = 0; i < 3; i++) {
          final a = i * pi / 3;
          canvas.drawLine(o + Offset(cos(a), sin(a)) * 4.5,
              o - Offset(cos(a), sin(a)) * 4.5, glyph);
        }
        break;
      case StatusEffect.tarred:
        canvas.drawCircle(o + const Offset(0, 1), 3.4, Paint()..color = RT.ink);
        break;
      case StatusEffect.dazed:
        canvas.drawArc(Rect.fromCircle(center: o, radius: 4.2), 0.6, pi * 1.4,
            false, glyph..style = PaintingStyle.stroke);
        break;
      case StatusEffect.snared:
        canvas.drawLine(o + const Offset(-4, -4), o + const Offset(4, 4), glyph);
        canvas.drawLine(o + const Offset(4, -4), o + const Offset(-4, 4), glyph);
        break;
    }
  }

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
        center: Offset(0, raft.waterLine + 4),
        width: w * (0.75 + t * 0.5),
        height: 13 * (0.75 + t * 0.5),
      ),
      Paint()..color = Colors.white.withOpacity(0.3 * (1 - t)),
    );
  }

  /// The hull's outline, as an actual path.
  ///
  /// Every hull used to be one rounded rectangle with different trim painted
  /// over it, so the fleet read as a single shape in five colours no matter
  /// how much detail went on top. At raft scale the silhouette is what you
  /// recognise a boat by, so this is where the hulls are actually made
  /// different: a ring, a bundle of logs, a plank deck on floats, a boat with
  /// a raked stem and a transom, and a tall ship with a high stern quarter.
  ///
  /// [bow] is +1 when the raft faces right, so stems and transoms end up on
  /// the correct ends.
  Path _hullPath(RaftLoadout lo, double w, double h, double top, double bow) {
    final half = w / 2;
    final bot = top + h;
    final p = Path();

    switch (lo.hull.shape) {
      case HullShape.ring:
        // A fat inflatable: fully rounded ends, belly sagging into the water.
        p.addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(-half, top, w, h),
          Radius.circular(h * 0.5),
        ));
        break;

      case HullShape.logs:
        // Round logs side by side: flat on top, scalloped underneath, and
        // the outer logs poking past the deck at both ends.
        final logs = max(4, (w / 26).round());
        final r = w / logs / 2;
        p.moveTo(-half - r * 0.5, top);
        p.lineTo(half + r * 0.5, top);
        p.lineTo(half + r * 0.5, top + h * 0.35);
        for (int i = logs - 1; i >= 0; i--) {
          final cx = -half + r + i * r * 2;
          p.arcToPoint(
            Offset(cx - r, top + h * 0.35),
            radius: Radius.circular(r),
            clockwise: true,
          );
        }
        p.lineTo(-half - r * 0.5, top + h * 0.35);
        p.close();
        break;

      case HullShape.pontoon:
        // A flat plank deck riding clear of the water on two round floats.
        final deckH = h * 0.42;
        p.addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(-half, top, w, deckH),
          const Radius.circular(3),
        ));
        final floatR = (h - deckH) * 0.5;
        for (final s in [-1.0, 1.0]) {
          p.addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(s * (half - w * 0.34) - w * 0.16, top + deckH,
                w * 0.32, floatR * 2),
            Radius.circular(floatR),
          ));
        }
        break;

      case HullShape.boat:
        // A proper little boat: raked stem forward, square transom aft, and
        // a sheer line that rises toward the bow.
        final stem = bow * half;
        final stern = -bow * half;
        p.moveTo(stern, top + h * 0.12);
        // Sheer along the deck, lifting toward the bow.
        p.quadraticBezierTo(0, top - h * 0.06, stem, top - h * 0.1);
        // Raked stem down to the forefoot.
        p.quadraticBezierTo(
            stem + bow * h * 0.16, top + h * 0.42, stem - bow * h * 0.1, bot);
        // Flat-ish keel.
        p.lineTo(stern + bow * h * 0.22, bot);
        // Transom.
        p.lineTo(stern, top + h * 0.12);
        p.close();
        break;

      case HullShape.carrack:
        // A tall ship: high stern castle quarter, tumblehome amidships, a
        // rounded forefoot and a sternpost standing proud of the deck.
        final stem = bow * half;
        final stern = -bow * half;
        p.moveTo(stern - bow * h * 0.06, top - h * 0.26);
        // Stern quarter drops to the deck line.
        p.lineTo(stern + bow * h * 0.10, top - h * 0.02);
        p.quadraticBezierTo(0, top - h * 0.10, stem, top - h * 0.02);
        // Bow: rounded forefoot rather than a knife stem.
        p.quadraticBezierTo(
            stem + bow * h * 0.2, top + h * 0.5, stem - bow * h * 0.14, bot);
        p.lineTo(stern + bow * h * 0.26, bot);
        // Sternpost back up, kicked out past the deck.
        p.quadraticBezierTo(stern - bow * h * 0.14, top + h * 0.55,
            stern - bow * h * 0.06, top - h * 0.26);
        p.close();
        break;
    }
    return p;
  }
  /// The base an emplacement stands on, in place of a raft's hull.
  ///
  /// Only the BASE differs — the floors above it are the shared deck-profile
  /// drawing, because they are the shared deck profile. What changes is what
  /// the thing is made of and how it meets the water: a beach shelves into
  /// it, a ledge drops sheer into it, lashed hulls sit in it separately.
  void _emplacementBase(Canvas canvas, Raft raft, double time) {
    final w = raft.hullHalf * 2;
    final waterY = raft.waterLine;
    final map = this.map;

    switch (raft.emplacement) {
      case Emplacement.raft:
        return; // drawn by _hull

      case Emplacement.island:
        // A sand mound: shelving beaches either side of a broad crown, with
        // the waterline cutting across it rather than it sitting on top.
        final crown = raft.deckY;
        final body = Path()
          ..moveTo(-w / 2 - 40, waterY + 16)
          ..quadraticBezierTo(-w / 2 + 20, crown + 6, -w * 0.24, crown)
          ..lineTo(w * 0.24, crown)
          ..quadraticBezierTo(w / 2 - 20, crown + 6, w / 2 + 40, waterY + 16)
          ..close();
        canvas.drawPath(body, Paint()..color = map.shore);
        // Wet sand where the water washes it — the line that makes it read
        // as land IN water rather than a shape floating on it.
        canvas.save();
        canvas.clipPath(body);
        canvas.drawRect(
          Rect.fromLTRB(-w, waterY - 5, w, waterY + 30),
          Paint()..color = Color.lerp(map.shore, map.waterDeep, 0.35)!,
        );
        canvas.restore();
        // A little scrub on the crown so it is not a bare dune.
        for (final gx in [-w * 0.16, w * 0.12]) {
          canvas.drawCircle(
            Offset(gx, crown - 3),
            7,
            Paint()..color = const Color(0xFF4E8C46),
          );
        }

      case Emplacement.ledge:
        // A rock shelf: sheer face, flat top, undercut at the waterline so
        // it reads as standing out of the sea rather than resting on it.
        final top = raft.deckY;
        final face = Path()
          ..moveTo(-w / 2, top)
          ..lineTo(w / 2, top)
          ..lineTo(w / 2 - 6, waterY + 34)
          ..lineTo(-w / 2 + 10, waterY + 34)
          ..close();
        canvas.drawPath(face, Paint()..color = map.stone);
        // Shaded right flank and strata across the face.
        canvas.save();
        canvas.clipPath(face);
        canvas.drawRect(
          Rect.fromLTRB(w * 0.18, top - 4, w, waterY + 40),
          Paint()..color = map.stoneShade,
        );
        final strata = Paint()
          ..color = map.stoneShade.withOpacity(0.55)
          ..strokeWidth = 2.5;
        for (double y = top + 12; y < waterY + 30; y += 13) {
          canvas.drawLine(Offset(-w, y), Offset(w, y + 2), strata);
        }
        canvas.restore();

      case Emplacement.flotilla:
        // Three hulls, each sitting a little differently in the water, with
        // rope between them. The gaps are real — they are the low tiers in
        // the plan — so the rope is spanning something.
        const parts = 3;
        for (int i = 0; i < parts; i++) {
          final cx = (-w / 2) + w * ((i + 0.5) / parts);
          final pw = w / parts * 0.86;
          final sit = [0.0, -5.0, 3.0][i];
          final rect = RRect.fromRectAndRadius(
            Rect.fromLTRB(
                cx - pw / 2, raft.deckY + sit, cx + pw / 2, waterY + 20 + sit),
            const Radius.circular(9),
          );
          canvas.drawRRect(rect, Paint()..color = raft.loadout.color);
          canvas.drawRRect(
            rect,
            Paint()
              ..color = Colors.black.withOpacity(0.18)
              ..strokeWidth = 2
              ..style = PaintingStyle.stroke,
          );
          // Lashing across to the next hull.
          if (i < parts - 1) {
            final nx = (-w / 2) + w * ((i + 1.5) / parts);
            final rope = Paint()
              ..color = const Color(0xFFCBB187)
              ..strokeWidth = 3
              ..strokeCap = StrokeCap.round;
            for (final dy in [4.0, 11.0]) {
              canvas.drawLine(
                Offset(cx + pw / 2, raft.deckY + sit + dy),
                Offset(nx - pw / 2, raft.deckY + dy),
                rope,
              );
            }
          }
        }

      case Emplacement.bay:
        // A cove: rock headlands at both ends with a sheltered floor between
        // them. Drawn as one mass so the walls read as part of the same
        // landform rather than two separate rocks.
        final floor = raft.deckY;
        final body = Path()
          ..moveTo(-w / 2 - 18, waterY + 26)
          ..lineTo(-w / 2 - 4, floor - 62)
          ..lineTo(-w * 0.28, floor - 62)
          ..lineTo(-w * 0.22, floor)
          ..lineTo(w * 0.22, floor)
          ..lineTo(w * 0.28, floor - 62)
          ..lineTo(w / 2 + 4, floor - 62)
          ..lineTo(w / 2 + 18, waterY + 26)
          ..close();
        canvas.drawPath(body, Paint()..color = map.stone);
        canvas.save();
        canvas.clipPath(body);
        // Shadow inside the cove, which is what sells it as sheltered.
        canvas.drawRect(
          Rect.fromLTRB(-w * 0.3, floor - 62, w * 0.3, floor + 8),
          Paint()..color = map.stoneShade.withOpacity(0.5),
        );
        canvas.drawRect(
          Rect.fromLTRB(-w, waterY - 4, w, waterY + 30),
          Paint()..color = Color.lerp(map.stone, map.waterDeep, 0.4)!,
        );
        canvas.restore();
    }
  }
  void _hull(Canvas canvas, Raft raft) {
    final lo = raft.loadout;
    final w = lo.width;
    final h = lo.hullHeight;
    final top = raft.waterLine - h * 0.55;
    final radius = Radius.circular(h * lo.hull.rounding.clamp(0.0, 1.0) * 0.5 + 3);

    // The hull's own outline — see [_hullPath]. Every hull used to be this
    // same rounded rectangle, which is why the fleet read as one shape in
    // five colours however much trim was painted on afterwards.
    final body = _hullPath(lo, w, h, top, raft.facing.toDouble());
    canvas.drawPath(body, Paint()..color = lo.color);
    // Inner shade along the bottom, clipped to the hull so the shading
    // follows whatever silhouette this hull actually has.
    canvas.save();
    canvas.clipPath(body);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-w / 2, top + h * 0.58, w, h * 0.42),
        radius,
      ),
      Paint()..color = Colors.black.withOpacity(0.14),
    );
    canvas.restore();
    // Plank seam on timber-style hulls.
    if (lo.hull.rounding < 0.5) {
      canvas.drawRect(
        Rect.fromLTWH(-w / 2 + 6, top + h * 0.36, w - 12, 3),
        Paint()..color = Colors.black.withOpacity(0.12),
      );
    }

    // Per-hull waterline detail. The deck above already differs; this is what
    // stops the five hulls sharing one bathtub outline down at the water.
    final trim = Color.lerp(lo.color, const Color(0xFF5A3D24), 0.5)!;
    switch (lo.hull.id) {
      case 'tube':
        // Inflatable ring: valve stub and a bright highlight along the top.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(-w * 0.30, top + h * 0.18, w * 0.60, h * 0.16),
            Radius.circular(h * 0.1),
          ),
          Paint()..color = Colors.white.withOpacity(0.22),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.36, top + h * 0.30, 9, h * 0.34),
            const Radius.circular(3),
          ),
          Paint()..color = trim,
        );
        break;

      case 'log':
        // Cut log ends along the hull, and the rope binding them together.
        final r = h * 0.44;
        final n = (w / (r * 2.2)).floor().clamp(3, 8);
        for (int k = 0; k < n; k++) {
          final c = Offset(-w / 2 + w * (k + 0.5) / n, top + h * 0.52);
          canvas.drawCircle(c, r, Paint()..color = trim);
          canvas.drawCircle(c, r * 0.42,
              Paint()..color = Color.lerp(trim, Colors.black, 0.3)!);
        }
        canvas.drawLine(
          Offset(-w / 2 + 4, top + h * 0.2),
          Offset(w / 2 - 4, top + h * 0.2),
          Paint()
            ..color = const Color(0xFFCBB68B)
            ..strokeWidth = 2.4,
        );
        break;

      case 'barrel':
        // Barrel float bellies hanging below the plank deck.
        final br = h * 0.5;
        final n = (w / (br * 2.4)).floor().clamp(2, 6);
        for (int k = 0; k < n; k++) {
          final c = Offset(-w / 2 + w * (k + 0.5) / n, top + h * 0.62);
          canvas.drawOval(
            Rect.fromCenter(center: c, width: br * 2.1, height: br * 1.7),
            Paint()..color = trim,
          );
          canvas.drawLine(
            Offset(c.dx - br * 0.9, c.dy),
            Offset(c.dx + br * 0.9, c.dy),
            Paint()
              ..color = Colors.black.withOpacity(0.22)
              ..strokeWidth = 1.6,
          );
        }
        break;

      case 'sloop':
      case 'galleon':
        // A real hull: a rubbing strake down the side, and a raked stem at
        // the bow so it reads as a ship with a front.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(-w / 2 + 3, top + h * 0.44, w - 6, 3.6),
            const Radius.circular(1.8),
          ),
          Paint()..color = trim,
        );
        final bow = raft.facing >= 0 ? 1.0 : -1.0;
        canvas.drawPath(
          Path()
            ..moveTo(bow * (w / 2 - 2), top + h * 0.06)
            ..lineTo(bow * (w / 2 + h * 0.16), top + h * 0.36)
            ..lineTo(bow * (w / 2 - 2), top + h * 0.62)
            ..close(),
          Paint()..color = trim,
        );
        if (lo.hull.id == 'galleon') {
          // Gun ports along the side of the biggest hull.
          final ports = (w / 46).floor().clamp(2, 5);
          final portH = min(h * 0.16, 9.0);
          for (int k = 0; k < ports; k++) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(-w / 2 + 16 + (w - 32) * k / (ports - 1) - portH / 2,
                    top + h * 0.16, portH, portH),
                const Radius.circular(1.5),
              ),
              Paint()..color = Colors.black.withOpacity(0.26),
            );
          }
        }
        break;
    }
  }


  /// The clutter that makes a raft look lived on.
  ///
  /// A hull, a deck and some platforms read as a *diagram* of a raft. What
  /// sells it as somebody's boat is the stuff hanging off it: fenders bumping
  /// the waterline, a lantern swinging on the stern post, a flag, a coil of
  /// rope, oars stowed along the rail, patches where it has been repaired.
  ///
  /// Every piece is per-hull, so the five hulls no longer differ only in
  /// outline: a pool tube gets a valve and a grab rope, a log raft gets
  /// lashings and a paddle, a barrel float gets bungs and a bailing bucket, a
  /// sloop gets rigging and a lantern, a galleon gets all of it plus a
  /// stern lamp and a name board.
  ///
  /// Placement is derived from the hull width and the raft's seat index —
  /// never from a random source — so decoration is stable across frames and
  /// byte-identical on both devices of a networked match.
  void _rigging(Canvas canvas, Raft raft, double time) {
    final lo = raft.loadout;
    final w = lo.width;
    final deckTop = raft.waterLine - lo.deckRise;
    final hullTop = deckTop;
    final hullH = lo.hullHeight;
    final dir = raft.facing.toDouble();
    final timber = Color.lerp(lo.color, const Color(0xFF5A3D24), 0.5)!;
    final rope = const Color(0xFFCBB68B);
    final dark = Color.lerp(lo.color, Colors.black, 0.35)!;
    // A gentle sway shared by everything that hangs, so the lantern and the
    // flag move together with the raft's own bob rather than independently.
    final sway = sin(time * 1.3 + raft.playerIndex * 1.7) * 0.09;

    void ropeCoil(double x, double y, double r) {
      for (int i = 0; i < 3; i++) {
        canvas.drawCircle(
          Offset(x, y - i * 1.6),
          r - i * 0.8,
          Paint()
            ..color = rope
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8,
        );
      }
    }

    /// A lantern hanging from [x], swinging with the raft.
    void lantern(double x, double y) {
      final hang = 11.0;
      final tip = Offset(x + sin(sway * 3) * hang * 0.5, y + hang);
      canvas.drawLine(
        Offset(x, y),
        tip,
        Paint()
          ..color = timber
          ..strokeWidth = 1.6,
      );
      // Warm pool of light first, so the body of the lamp sits inside it.
      canvas.drawCircle(
        tip + const Offset(0, 4),
        9,
        Paint()..color = const Color(0xFFFFD98A).withOpacity(0.35),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: tip + const Offset(0, 4), width: 7, height: 9),
          const Radius.circular(2),
        ),
        Paint()..color = const Color(0xFFFFD98A),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: tip + const Offset(0, 4), width: 7, height: 9),
          const Radius.circular(2),
        ),
        Paint()
          ..color = timber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }

    /// A pennant on a short staff at the stern.
    void flag(double x, double y, Color cloth) {
      final h = 22.0;
      canvas.drawLine(
        Offset(x, y),
        Offset(x, y - h),
        Paint()
          ..color = timber
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round,
      );
      // The pennant ripples: two waves along its length, phase-shifted by
      // the raft's own sway so neighbouring rafts never flap in lockstep.
      final p = Path()..moveTo(x, y - h);
      const seg = 4;
      for (int i = 1; i <= seg; i++) {
        final t = i / seg;
        p.lineTo(
          x - dir * 20 * t,
          y - h + sin(time * 5 + t * 3 + raft.playerIndex) * 2.2 * t + 1,
        );
      }
      for (int i = seg; i >= 0; i--) {
        final t = i / seg;
        p.lineTo(
          x - dir * 20 * t,
          y - h + 8 + sin(time * 5 + t * 3 + raft.playerIndex) * 2.2 * t,
        );
      }
      p.close();
      canvas.drawPath(p, Paint()..color = cloth);
    }

    /// A fender — a bumper slung over the side at the waterline.
    void fender(double x) {
      final y = hullTop + hullH * 0.42;
      canvas.drawLine(
        Offset(x, hullTop + 1),
        Offset(x, y - 4),
        Paint()
          ..color = rope
          ..strokeWidth = 1.4,
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y + 1), width: 8, height: 12),
        Paint()..color = dark,
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y - 1), width: 5, height: 4),
        Paint()..color = Colors.white.withOpacity(0.18),
      );
    }

    /// An oar or paddle stowed flat along the deck.
    void oar(double x0, double x1, double y) {
      canvas.drawLine(
        Offset(x0, y),
        Offset(x1, y),
        Paint()
          ..color = timber
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x1, y), width: 11, height: 6),
        Paint()..color = timber,
      );
    }

    switch (lo.hull.id) {
      case 'tube':
        // An inflatable: a valve, a grab rope looped around the ring, and a
        // patch where somebody has already fixed a puncture.
        final valve = Offset(-dir * (w / 2 - 10), hullTop + hullH * 0.3);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: valve, width: 7, height: 5),
            const Radius.circular(2),
          ),
          Paint()..color = dark,
        );
        // Grab rope: short loops along the outer face.
        final loops = (w / 34).floor().clamp(3, 7);
        for (int i = 0; i < loops; i++) {
          final x = -w / 2 + 14 + (w - 28) * i / (loops - 1);
          canvas.drawArc(
            Rect.fromCenter(
                center: Offset(x, hullTop + hullH * 0.2), width: 12, height: 12),
            0.15,
            pi * 0.7,
            false,
            Paint()
              ..color = rope
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.8,
          );
        }
        canvas.drawCircle(
          Offset(dir * (w * 0.18), hullTop + hullH * 0.5),
          5,
          Paint()..color = Colors.white.withOpacity(0.22),
        );
        ropeCoil(-dir * (w / 2 - 22), deckTop - 3, 5);
        break;

      case 'log':
        // Lashed timber: cross-lashings over the log ends, a paddle stowed
        // flat, and a coil of spare line.
        final lash = Paint()
          ..color = rope
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round;
        for (final s in [-1.0, 1.0]) {
          final x = s * (w / 2 - 12);
          canvas.drawLine(Offset(x - 6, hullTop + 2),
              Offset(x + 6, hullTop + hullH * 0.7), lash);
          canvas.drawLine(Offset(x + 6, hullTop + 2),
              Offset(x - 6, hullTop + hullH * 0.7), lash);
        }
        oar(-dir * (w * 0.34), -dir * (w * 0.06), deckTop - 2);
        ropeCoil(dir * (w * 0.3), deckTop - 3, 5);
        flag(-dir * (w / 2 - 14), deckTop - 2, lo.color);
        break;

      case 'barrel':
        // Sealed barrels: bungs on the ends, a bailing bucket, fenders.
        for (final s in [-1.0, 1.0]) {
          canvas.drawCircle(
            Offset(s * (w / 2 - 9), hullTop + hullH * 0.34),
            3.2,
            Paint()..color = dark,
          );
        }
        fender(dir * (w / 2 - 6));
        fender(-dir * (w / 2 - 6));
        // Bucket.
        final bx = dir * (w * 0.28);
        canvas.drawPath(
          Path()
            ..moveTo(bx - 6, deckTop - 11)
            ..lineTo(bx + 6, deckTop - 11)
            ..lineTo(bx + 4.5, deckTop - 1)
            ..lineTo(bx - 4.5, deckTop - 1)
            ..close(),
          Paint()..color = timber,
        );
        canvas.drawArc(
          Rect.fromCenter(
              center: Offset(bx, deckTop - 11), width: 12, height: 9),
          pi,
          pi,
          false,
          Paint()
            ..color = rope
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        ropeCoil(-dir * (w * 0.32), deckTop - 3, 5.5);
        break;

      case 'sloop':
        // A proper little boat: shrouds up to the mast, a lantern on the
        // stern post, fenders, and a coil by the bow cleat.
        final mastX = -dir * 26;
        final shroud = Paint()
          ..color = rope
          ..strokeWidth = 1.4;
        for (final s in [-1.0, 1.0]) {
          canvas.drawLine(
            Offset(mastX, raft.waterLine - lo.hullHeight * 0.5 - 96),
            Offset(mastX + s * (w * 0.26), deckTop - 1),
            shroud,
          );
        }
        lantern(-dir * (w / 2 - 12), deckTop - 20);
        fender(dir * (w / 2 - 7));
        ropeCoil(dir * (w * 0.3), deckTop - 3, 5);
        break;

      case 'galleon':
        // The full kit: shrouds, a stern lantern, a name board, gun-port
        // rigging, fenders down both sides and a flag at the taffrail.
        final mastX = -dir * 26;
        final shroud = Paint()
          ..color = rope
          ..strokeWidth = 1.4;
        for (int i = -2; i <= 2; i++) {
          if (i == 0) continue;
          canvas.drawLine(
            Offset(mastX, raft.waterLine - lo.hullHeight * 0.5 - 100),
            Offset(mastX + i * (w * 0.13), deckTop - 1),
            shroud,
          );
        }
        lantern(-dir * (w / 2 - 10), deckTop - 26);
        flag(-dir * (w / 2 - 20), deckTop - 4, lo.color);
        fender(dir * (w / 2 - 8));
        fender(dir * (w / 2 - 22));
        fender(-dir * (w / 2 - 8));
        // Name board along the stern quarter.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(-dir * (w * 0.26), hullTop + hullH * 0.3),
              width: w * 0.22,
              height: 7,
            ),
            const Radius.circular(2),
          ),
          Paint()..color = timber,
        );
        ropeCoil(dir * (w * 0.34), deckTop - 3, 6);
        break;
    }

    // Repair patches: every raft has taken a beating at some point. Placed
    // off the seat index so each raft in a fleet is patched differently, and
    // deliberately subtle — this is texture, not damage state.
    final patches = 1 + raft.playerIndex % 2;
    for (int i = 0; i < patches; i++) {
      final x = -w / 2 + w * (0.25 + 0.4 * i + raft.playerIndex * 0.07) % (w - 20);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x - w / 2 + 10, hullTop + hullH * (0.5 + 0.12 * i)),
            width: 12,
            height: 8,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = Colors.black.withOpacity(0.1),
      );
    }
  }
  /// The deck's raised platforms, drawn from the same [DeckProfile] the
  /// physics collides against — blocks render as solid slabs with a lit top
  /// and a shaded front wall, ramps as wedges. Coordinates are hull-local,
  /// rises measured up from the main deck plane (y-down, so negative).
  /// Walls and roofs: the built structures that sit ON a deck rather than
  /// being part of its shape.
  ///
  /// The hulls already differ in outline and in tier layout, but above the
  /// planks they were bare — every raft was an open platform, so the only
  /// thing between two crews was distance. A bulkhead to stand behind and a
  /// canopy overhead give a deck an interior to read.
  ///
  /// Deliberately drawn rather than built into [DeckProfile]. The profile is
  /// a height-field — one surface height per x — which can express a floor
  /// but not a wall or an overhang, so anything vertical here is scenery. It
  /// is placed against the real tiers and the real berths, so it never floats
  /// and never lands on somebody's head, but a shot passes through it.
  ///
  /// Chosen from the raft's own identity rather than rolled per frame: a
  /// deck that rearranged itself between frames would be worse than a bare
  /// one, and the same raft must look the same on both devices in a hotspot
  /// match.
  /// What the player built, block by block.
  ///
  /// Drawn from the live grid rather than from the plan they submitted, so a
  /// block that has been shot off is simply not there — the structure on
  /// screen is always the structure the physics is using.
  /// The raft currently being laid out, if any. See [_buildGhosts].
  Raft? _buildTarget;

  /// The empty cells a block could go in, drawn on the raft during the
  /// build phase.
  ///
  /// This replaces the floating grid panel the build screen used to put in
  /// the middle of the water. A diagram of the raft, drawn somewhere other
  /// than where the raft is, makes the player translate between two pictures
  /// to answer the only question that matters — is this wall tall enough to
  /// stand behind? Marking the real cells on the real deck, at the size the
  /// battle is fought at and with the crew standing right there, answers it
  /// by looking.
  ///
  /// Only empty, legal cells are marked. A filled cell already shows what is
  /// in it, and a column hanging off the end of a short hull is not somewhere
  /// a block can go at all (see [Raft.buildColumnOnDeck]) — outlining it
  /// would be an invitation to tap something that does nothing.
  void _buildGhosts(Canvas canvas, Raft raft) {
    final plan = raft.build;
    if (plan == null) return;
    final deckTop = raft.waterLine - raft.loadout.deckRise;

    final fill = Paint()..color = Colors.white.withOpacity(0.10);
    final edge = Paint()
      ..color = Colors.white.withOpacity(0.38)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    for (int col = 0; col < BuildPlan.cols; col++) {
      if (!raft.buildColumnOnDeck(col)) continue;
      for (int row = 0; row < BuildPlan.rows; row++) {
        if (plan.at(col, row) != null) continue;
        final box = Rect.fromLTWH(
          BuildPlan.columnX(col) - BuildPlan.cellW / 2 + 1,
          deckTop - (row + 1) * BuildPlan.cellH + 1,
          BuildPlan.cellW - 2,
          BuildPlan.cellH - 2,
        );
        final rr = RRect.fromRectAndRadius(box, const Radius.circular(3));
        canvas.drawRRect(rr, fill);
        canvas.drawRRect(rr, edge);
      }
    }
  }

  void _builtStructure(Canvas canvas, Raft raft, double time) {
    final plan = raft.build;
    if (plan == null) return;
    final deckTop = raft.waterLine - raft.loadout.deckRise;

    for (final (col, row, cell) in plan.standing) {
      if (!raft.buildColumnOnDeck(col)) continue;
      final def = cell.def;
      final cx = BuildPlan.columnX(col);
      final top = deckTop - (row + 1) * BuildPlan.cellH;
      final box = Rect.fromLTWH(
        cx - BuildPlan.cellW / 2,
        top,
        BuildPlan.cellW,
        BuildPlan.cellH,
      );

      canvas.save();
      // Being hit shakes the block. A block can be struck several times
      // before it goes, so this is a shudder rather than a white flash — at
      // that rate a full-box strobe reads as flicker, not impact.
      if (cell.flash > 0) {
        final k = (cell.flash / BattleConst.obstacleStruckTime).clamp(0.0, 1.0);
        canvas.translate(sin(cell.flash * 90) * 2.4 * k, 0);
      }

      // The block itself: face, a lit top edge, and a shaded right flank so
      // it reads as solid rather than as a flat tile.
      canvas.drawRect(box, Paint()..color = def.color);
      canvas.drawRect(
        Rect.fromLTRB(box.right - 5, box.top, box.right, box.bottom),
        Paint()..color = def.shade,
      );
      canvas.drawRect(
        Rect.fromLTRB(box.left, box.top, box.right, box.top + 3),
        Paint()..color = Color.lerp(def.color, Colors.white, 0.35)!,
      );

      // Material grain — what tells the five apart at a glance, without
      // needing to read a legend.
      final grain = Paint()
        ..color = def.shade.withOpacity(0.75)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      switch (cell.material) {
        case BuildMaterial.thatch:
          // Loose vertical stalks.
          for (double gx = box.left + 3; gx < box.right - 2; gx += 4) {
            canvas.drawLine(
              Offset(gx, box.top + 3),
              Offset(gx + 1.2, box.bottom - 2),
              grain,
            );
          }
        case BuildMaterial.driftwood:
          // A couple of long uneven boards.
          for (int i = 1; i <= 2; i++) {
            final gy = box.top + box.height * i / 3;
            canvas.drawLine(
              Offset(box.left + 2, gy),
              Offset(box.right - 4, gy + (i.isEven ? 1.5 : -1.5)),
              grain,
            );
          }
        case BuildMaterial.plank:
          // Neat sawn boards, evenly spaced.
          for (int i = 1; i < 3; i++) {
            final gy = box.top + box.height * i / 3;
            canvas.drawLine(
                Offset(box.left + 2, gy), Offset(box.right - 4, gy), grain);
          }
        case BuildMaterial.barrel:
          // Hoops around a curved body.
          canvas.drawOval(box.deflate(2.5), grain..style = PaintingStyle.stroke);
          for (int i = 1; i < 3; i++) {
            final gy = box.top + box.height * i / 3;
            canvas.drawLine(
                Offset(box.left + 3, gy), Offset(box.right - 5, gy), grain);
          }
          grain.style = PaintingStyle.fill;
        case BuildMaterial.iron:
          // Riveted plate.
          final rivet = Paint()..color = def.shade;
          for (final rx in [box.left + 4.5, box.right - 7.5]) {
            for (final ry in [box.top + 4.5, box.bottom - 4.5]) {
              canvas.drawCircle(Offset(rx, ry), 1.6, rivet);
            }
          }
      }

      // Damage: cracks open across the face as it takes hits, so how much
      // more it will stand is readable before it goes.
      if (cell.wear > 0.05) {
        final crack = Paint()
          ..color = const Color(0xFF241C14).withOpacity(0.2 + cell.wear * 0.55)
          ..strokeWidth = 1.2 + cell.wear * 1.8
          ..style = PaintingStyle.stroke;
        final steps = 1 + (cell.wear * 3).round();
        for (int i = 0; i < steps; i++) {
          final gy = box.top + box.height * (i + 1) / (steps + 1);
          canvas.drawLine(
            Offset(box.left + 1, gy),
            Offset(box.right - 1, gy + (i.isEven ? 2.5 : -2.5)),
            crack,
          );
        }
      }

      // Outline last, so neither the grain nor the cracks bleed over it.
      canvas.drawRect(
        box,
        Paint()
          ..color = const Color(0xFF2A2018).withOpacity(0.55)
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
      canvas.restore();
    }
  }
  void _deckStructures(Canvas canvas, Raft raft) {
    final lo = raft.loadout;
    final deckTop = raft.waterLine - lo.deckRise;
    final profile = raft.profile;

    var h = lo.hull.id.hashCode ^ (raft.playerIndex * 0x9E3779B1);
    h ^= (raft.x * 7.0).round();
    int roll(int n) {
      h ^= h >>> 13;
      h = (h * 0x85EBCA6B) & 0x7FFFFFFF;
      h ^= h >>> 11;
      return h % n;
    }

    /// True if a crew berth sits within [pad] of [x] — somewhere a wall
    /// would be standing in a person.
    bool clearOfBerths(double x, double pad) {
      for (final st in profile.stations) {
        if ((st.x - x).abs() < pad) return false;
      }
      return true;
    }

    // Built from whatever the emplacement is made of, so a hut on a rock
    // ledge is not painted in the raft fleet own colours.
    final base = _deckMaterial(raft);
    final timber = Color.lerp(base, const Color(0xFF3A2A1C), 0.42)!;
    final timberLit = Color.lerp(base, Colors.white, 0.20)!;
    final post = Color.lerp(base, const Color(0xFF23262B), 0.55)!;

    for (final s in profile.segments) {
      if (!s.isFlat) continue;
      final top = deckTop - s.rise0;
      final width = s.x1 - s.x0;
      if (width < 34) continue;

      switch (roll(4)) {
        case 0:
          // A ROOF: a canopy on corner posts, high enough to stand under.
          // Anything lower would slice through the crew beneath it, which is
          // exactly the sort of thing that looks like a rendering fault
          // rather than a building.
          const clear = 76.0;
          final eaves = top - clear;
          for (final px in [s.x0 + 4, s.x1 - 4]) {
            canvas.drawRect(
              Rect.fromLTRB(px - 2.5, eaves, px + 2.5, top),
              Paint()..color = post,
            );
          }
          // A shallow pitch, overhanging the posts a little at each end.
          final roof = Path()
            ..moveTo(s.x0 - 7, eaves)
            ..lineTo((s.x0 + s.x1) / 2, eaves - 13)
            ..lineTo(s.x1 + 7, eaves)
            ..close();
          canvas.drawPath(roof, Paint()..color = timber);
          canvas.drawLine(
            Offset(s.x0 - 7, eaves),
            Offset(s.x1 + 7, eaves),
            Paint()
              ..color = timberLit
              ..strokeWidth = 3.5,
          );
        case 1:
          // A WALL: a bulkhead across one end of the tier, kept off the
          // berths so nobody is standing inside it.
          final atLeft = roll(2) == 0;
          final wx = atLeft ? s.x0 + 6 : s.x1 - 6;
          if (!clearOfBerths(wx, 16)) break;
          const hgt = 34.0;
          canvas.drawRect(
            Rect.fromLTRB(wx - 4, top - hgt, wx + 4, top),
            Paint()..color = timber,
          );
          // Plank seams, so it reads as boards rather than a slab.
          for (int i = 1; i < 3; i++) {
            final y = top - hgt * i / 3;
            canvas.drawLine(
              Offset(wx - 4, y),
              Offset(wx + 4, y),
              Paint()
                ..color = Colors.black.withOpacity(0.18)
                ..strokeWidth = 1.2,
            );
          }
          // Capping rail along the top.
          canvas.drawRect(
            Rect.fromLTRB(wx - 6, top - hgt - 3, wx + 6, top - hgt),
            Paint()..color = timberLit,
          );
        case 2:
          // A BULWARK: a low solid wall running the length of the tier —
          // the thing a crew member ducks behind. Kept short so it never
          // hides a head.
          const hgt = 17.0;
          canvas.drawRect(
            Rect.fromLTRB(s.x0 + 2, top - hgt, s.x1 - 2, top - hgt + 4),
            Paint()..color = timberLit,
          );
          for (double px = s.x0 + 6; px < s.x1 - 4; px += 13) {
            canvas.drawRect(
              Rect.fromLTRB(px - 1.6, top - hgt, px + 1.6, top),
              Paint()..color = post,
            );
          }
        default:
          // Nothing on this tier. A deck with something on every level is as
          // uniform as a deck with nothing on any of them.
          break;
      }
    }
  }

  /// What an emplacement's walkable tiers are made of.
  ///
  /// The tier drawing is shared — the floors ARE the shared deck profile —
  /// but the material is not: an island wearing a raft's painted planks
  /// reads as a raft with sand round it rather than as land.
  Color _deckMaterial(Raft raft) => switch (raft.emplacement) {
        Emplacement.raft || Emplacement.flotilla => raft.loadout.color,
        Emplacement.island => map.shore,
        Emplacement.ledge || Emplacement.bay => map.stone,
      };
  void _platforms(Canvas canvas, Raft raft) {
    final lo = raft.loadout;
    final deckTop = raft.waterLine - lo.deckRise;
    // The emplacement own width, not the hull: an island is half again as
    // wide as the hull standing in for it, and its floors are laid out
    // across the width they actually occupy.
    final w = raft.hullHalf * 2;
    final surface = _deckMaterial(raft);

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
      final planks =
          isRamp ? surface : Color.lerp(surface, Colors.white, 0.14)!;

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
      } else if ((topL - topR).abs() >= 6) {
        // A real climb gets a real staircase: solid treads and risers cut
        // into the slope. The physics surface underneath is the same ramp it
        // always was — a tumbling body still slides down it — but a level
        // change now reads as stairs rather than a bare wedge, which is what
        // makes an upper deck look reachable.
        final up = topR < topL; // climbing toward the right
        final span = right - left;
        final steps = (span / 11).floor().clamp(2, 6);
        for (int k = 0; k < steps; k++) {
          final x0 = left + span * k / steps;
          final x1 = left + span * (k + 1) / steps;
          // Each tread sits at the height of the slope's far edge, so the
          // staircase always meets both tiers cleanly.
          final f = (up ? k + 1 : k) / steps;
          final y = topL + (topR - topL) * f;
          canvas.drawRect(
            Rect.fromLTRB(x0, y, x1, deckTop + 2),
            Paint()..color = k.isEven
                ? lo.color
                : Color.lerp(lo.color, Colors.white, 0.1)!,
          );
          canvas.drawRect(
            Rect.fromLTRB(x0, y, x1, y + 2),
            Paint()..color = Colors.white.withOpacity(0.3),
          );
          canvas.drawRect(
            Rect.fromLTRB(x0, y + 2, x0 + 1.4, deckTop),
            Paint()..color = Colors.black.withOpacity(0.14),
          );
        }
      } else {
        // A gentle slope keeps the old light tread hints.
        final tread = Paint()
          ..color = Colors.black.withOpacity(0.13)
          ..strokeWidth = 1.4;
        final steps = ((right - left) / 7).floor().clamp(1, 6);
        for (int k = 1; k < steps; k++) {
          final f = k / steps;
          final x = left + (right - left) * f;
          final y = topL + (topR - topL) * f;
          canvas.drawLine(Offset(x, y), Offset(x, y + 4), tread);
        }
      }

      // Per-tier furniture: what actually tells the five hulls apart at a
      // glance, on top of the shared plank language above.
      //
      // Rise-0 tiers get it too now. The guard used to require a raised tier,
      // which silently threw away everything that sits ON a surface rather
      // than being built into a wall — the galley table, the lashed barrel
      // stacks — because those live on the main deck by definition.
      if (!isRamp) {
        _deckFurniture(canvas, s, lo, deckTop, topL);
      }
      // Keep the planks' horizontal seam language but bound it to the hull.
      assert(right <= w / 2 + 0.01 && left >= -w / 2 - 0.01);
    }

    // Rail lips at both rails — the physical bumper living bodies bounce
    // off, drawn so the boundary reads before anyone tests it.
    final lip = Color.lerp(lo.color, const Color(0xFF23262B), 0.5)!;
    for (final side in [-1.0, 1.0]) {
      final x = side * raft.deckHalf;
      // Stand the post on whatever surface reaches that rail. Drawing it at
      // the main deck plane on a hull whose stern castle runs out to the edge
      // buried the post in the platform, so the boundary a body actually
      // bounces off was invisible exactly where it mattered most.
      final surface = deckTop - raft.profile.riseAt(x);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x - 2.5,
            surface - BattleConst.railWallHeight,
            5,
            BattleConst.railWallHeight,
          ),
          const Radius.circular(2.5),
        ),
        Paint()..color = lip,
      );
    }
  }

  /// Dresses one raised deck tier according to its [DeckStyle].
  ///
  /// The height-field is identical for every style — this is purely what a
  /// tier is *built out of*, and it is most of what makes a log raft read as
  /// lashed timber and a galleon as a proper ship rather than the same slab
  /// in a different colour. Drawn in hull-local coordinates, with [topY] the
  /// tier's walking surface and [deckTop] the main deck plane below it.
  void _deckFurniture(
    Canvas canvas,
    DeckSegment s,
    RaftLoadout lo,
    double deckTop,
    double topY,
  ) {
    final left = s.x0;
    final right = s.x1;
    final span = right - left;
    final wallH = deckTop - topY;
    final timber = Color.lerp(lo.color, const Color(0xFF5A3D24), 0.45)!;
    final rope = const Color(0xFFCBB68B);

    switch (s.style) {
      case DeckStyle.lashed:
        // Rope bindings wrapping the platform onto the logs beneath.
        final bind = Paint()
          ..color = rope
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round;
        final knots = (span / 26).floor().clamp(1, 4);
        for (int k = 0; k < knots; k++) {
          final x = left + span * (k + 0.5) / knots;
          canvas.drawLine(Offset(x - 4, topY + 1), Offset(x + 4, deckTop - 1), bind);
          canvas.drawLine(Offset(x + 4, topY + 1), Offset(x - 4, deckTop - 1), bind);
        }
        break;

      case DeckStyle.barrels:
        // Barrel ends showing through the front wall of the platform.
        final r = min(wallH * 0.42, 7.0);
        if (r > 2) {
          final n = (span / (r * 2.6)).floor().clamp(1, 5);
          for (int k = 0; k < n; k++) {
            final c = Offset(left + span * (k + 0.5) / n, deckTop - r - 1);
            canvas.drawCircle(c, r, Paint()..color = timber);
            canvas.drawCircle(c, r * 0.55,
                Paint()..color = Color.lerp(timber, Colors.black, 0.25)!);
            canvas.drawCircle(
              c,
              r,
              Paint()
                ..color = Colors.black.withOpacity(0.18)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2,
            );
          }
        }
        break;

      case DeckStyle.castle:
        // Railing posts with a top rail along the castle's outer edge — the
        // detail that makes a raised tier read as somewhere crew stand.
        final railY = topY - 9;
        final post = Paint()
          ..color = timber
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round;
        final posts = (span / 16).floor().clamp(2, 6);
        for (int k = 0; k <= posts; k++) {
          final x = left + span * k / posts;
          canvas.drawLine(Offset(x, topY), Offset(x, railY), post);
        }
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, railY - 1.6, span, 3.2),
            const Radius.circular(1.6),
          ),
          Paint()..color = timber,
        );
        break;

      case DeckStyle.cargo:
        // A roped-down crate stack. Cargo tiers carry no crew, so this is
        // the one piece of deck furniture that is purely scenery.
        final crateH = min(wallH * 0.9, 14.0);
        final crates = (span / 18).floor().clamp(1, 3);
        for (int k = 0; k < crates; k++) {
          final cw = span / crates - 4;
          final x = left + 2 + (span / crates) * k;
          final rect = Rect.fromLTWH(x, topY - crateH, cw, crateH);
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(2)),
            Paint()..color = timber,
          );
          canvas.drawLine(
            Offset(rect.left, rect.center.dy),
            Offset(rect.right, rect.center.dy),
            Paint()
              ..color = rope
              ..strokeWidth = 1.6,
          );
        }
        break;


      case DeckStyle.cabin:
        // A deck house. Its roof IS the tier above — crew posted up there are
        // standing on this, which is what makes a raft feel like two floors
        // rather than one deck with a box on it.
        canvas.drawRect(
          Rect.fromLTRB(left, topY, right, deckTop),
          Paint()..color = Color.lerp(lo.color, Colors.white, 0.1)!,
        );
        // Corner posts.
        for (final x in [left + 2.0, right - 2.0]) {
          canvas.drawRect(
            Rect.fromLTWH(x - 1.6, topY, 3.2, wallH),
            Paint()..color = timber,
          );
        }
        // A shuttered window, and a doorway into the dark.
        final midY = topY + wallH * 0.42;
        if (span > 34) {
          final wx = left + span * 0.3;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: Offset(wx, midY), width: 13, height: min(wallH * 0.5, 11)),
              const Radius.circular(2),
            ),
            Paint()..color = const Color(0xFF7FC7D9),
          );
          canvas.drawLine(Offset(wx, midY - 6), Offset(wx, midY + 6),
              Paint()..color = timber..strokeWidth = 1.6);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: Offset(wx, midY), width: 13, height: min(wallH * 0.5, 11)),
              const Radius.circular(2),
            ),
            Paint()
              ..color = timber
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.8,
          );
        }
        final dx = left + span * 0.72;
        final doorH = min(wallH * 0.78, 20.0);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(dx - 6, deckTop - doorH, 12, doorH),
            topLeft: const Radius.circular(5),
            topRight: const Radius.circular(5),
          ),
          Paint()..color = const Color(0xFF2E2118),
        );
        canvas.drawCircle(
            Offset(dx + 3.4, deckTop - doorH * 0.45), 1.4, Paint()..color = rope);
        break;

      case DeckStyle.roof:
        // The upper floor of the deckhouse — crew stand ON this, so it is
        // drawn as a storey you can walk on rather than a peaked roof over
        // your head: sided wall, an overhanging eave board along the top, and
        // rafter ends poking out under it.
        canvas.drawRect(
          Rect.fromLTRB(left, topY, right, deckTop),
          Paint()..color = Color.lerp(lo.color, Colors.white, 0.16)!,
        );
        // Horizontal siding.
        final boards = (wallH / 6).floor().clamp(1, 5);
        for (int k = 1; k <= boards; k++) {
          final y = topY + wallH * k / (boards + 1);
          canvas.drawLine(
            Offset(left + 1, y),
            Offset(right - 1, y),
            Paint()
              ..color = Colors.black.withOpacity(0.08)
              ..strokeWidth = 1.2,
          );
        }
        // Rafter ends, then the eave board over them.
        final rafters = (span / 15).floor().clamp(2, 6);
        for (int k = 0; k <= rafters; k++) {
          final x = left + span * k / rafters;
          canvas.drawRect(
            Rect.fromLTWH(x - 1.4, topY + 2, 2.8, 3.4),
            Paint()..color = timber,
          );
        }
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left - 5, topY - 1.5, span + 10, 4),
            const Radius.circular(2),
          ),
          Paint()..color = timber,
        );
        break;

      case DeckStyle.galley:
        // Somewhere the crew actually live: a table with a stool either side,
        // a tankard and a lamp.
        final tY = topY - 9;
        final tx0 = left + span * 0.22;
        final tx1 = left + span * 0.78;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(tx0, tY, tx1, tY + 3.4),
            const Radius.circular(1.7),
          ),
          Paint()..color = timber,
        );
        for (final x in [tx0 + 3.0, tx1 - 3.0]) {
          canvas.drawRect(
              Rect.fromLTWH(x - 1.2, tY + 3, 2.4, topY - tY - 3),
              Paint()..color = timber);
        }
        // Stools.
        for (final x in [tx0 - 6.0, tx1 + 6.0]) {
          if (x < left || x > right) continue;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(x, topY - 4), width: 8, height: 2.6),
              const Radius.circular(1.3),
            ),
            Paint()..color = timber,
          );
          canvas.drawRect(Rect.fromLTWH(x - 0.9, topY - 4, 1.8, 4),
              Paint()..color = timber);
        }
        // A tankard, and a lamp with a warm pool of light.
        canvas.drawRect(Rect.fromLTWH(tx0 + 7, tY - 5, 4, 5),
            Paint()..color = const Color(0xFFD9D2C0));
        final lampAt = Offset(tx1 - 8, tY - 5);
        canvas.drawCircle(
            lampAt, 7, Paint()..color = const Color(0xFFFFD98A).withOpacity(0.3));
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: lampAt, width: 5, height: 7),
            const Radius.circular(2),
          ),
          Paint()..color = const Color(0xFFFFD98A),
        );
        break;

      case DeckStyle.barrelStack:
        // Barrels standing on their ends, lashed in a row, with a second
        // course stacked where there is room.
        final br = min(span / 5, 8.0);
        final n = (span / (br * 2.3)).floor().clamp(1, 5);
        for (int k = 0; k < n; k++) {
          final cx = left + span * (k + 0.5) / n;
          final by = topY - br * 1.5;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: Offset(cx, by + br * 0.75),
                  width: br * 1.8,
                  height: br * 2.4),
              Radius.circular(br * 0.5),
            ),
            Paint()..color = timber,
          );
          for (final hy in [by + br * 0.2, by + br * 1.3]) {
            canvas.drawLine(
              Offset(cx - br * 0.9, hy),
              Offset(cx + br * 0.9, hy),
              Paint()
                ..color = Colors.black.withOpacity(0.22)
                ..strokeWidth = 1.4,
            );
          }
          canvas.drawOval(
            Rect.fromCenter(
                center: Offset(cx, by - br * 0.4), width: br * 1.6, height: br * 0.7),
            Paint()..color = Color.lerp(timber, Colors.white, 0.18)!,
          );
        }
        // One lashing rope across the whole row.
        canvas.drawLine(
          Offset(left + 2, topY - br * 1.1),
          Offset(right - 2, topY - br * 1.1),
          Paint()
            ..color = rope
            ..strokeWidth = 1.8,
        );
        break;

      case DeckStyle.planks:
        break;
    }
  }

  void _mast(Canvas canvas, Raft raft) {    final lo = raft.loadout;
    final baseY = raft.waterLine - lo.hullHeight * 0.5;
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
    final deck = raft.waterLine - lo.deckRise;

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
        // Pump slides cycle once; a winch crank spins its wheel through a
        // full turn on the same beat, so both actions animate off one clock.
        if ((wv.pumpTravel > 0 || wv.crankR > 0) && dt < 0.34) {
          pumpT = wv.crankR > 0 ? (dt / 0.34) : sin(pi * dt / 0.34);
        }
      }
    }

    // -------------------------------------------------------------------
    // Layout: a small head over a chunkier, human-proportioned torso, on
    // two planted legs. Everything is built from thick rounded-cap "bone"
    // strokes (see [_taperedLimb]) rather than baked shapes, so the gun arm is
    // free to swing to any angle at runtime instead of needing a sprite
    // for every pose.
    // -------------------------------------------------------------------
    const legLen = 15.0;
    const torsoH = 27.0;
    const torsoW = 29.0;
    const headR = 14.0;

    // How the whole body is carrying itself — a wince doubles them over, a
    // gloat throws an arm up and bounces them off the deck, tar sags the
    // shoulders. Computed in the simulation ([Crew.bodyExpression]) so the
    // face and the body can never tell two different stories, and applied
    // here to the actual skeleton rather than as an afterthought overlay.
    final bx = crew.bodyExpression(time);

    final footY = deck;
    // Recoil crouches the body — scaled by the caliber's kick, so a tennis
    // ball barely moves the stance and an anchor shot drives the heels in.
    // The expression's own crouch rides on top: negative values (a stretch)
    // lift the hips and put them up on their toes.
    final hipY = footY -
        legLen * (1 - bx.crouch * 0.42) +
        recoil * wv.kick * 0.4 +
        bx.bounce;
    final shoulderY = hipY - torsoH * (1 - bx.slump * 0.14);
    final headC = Offset(
      bx.tremble * 0.5 + bx.headTilt * 3.2,
      shoulderY - headR - 2 + bx.slump * 2.4,
    );

    final skin = _skinFor(raft.look);
    final suit = _outfitFor(raft);
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
        (grabbing ? 0.09 : 0) * gunSide +
        // The expression's lean is in body space, so it flips with the
        // facing exactly like the recoil rock does.
        bx.lean * gunSide;
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
    // Torso twist while the weapon is up. A shooter turns into the target, so
    // the off shoulder comes round toward the gun side; drawn side-on, that
    // shows as the far shoulder sitting much closer to the near one.
    //
    // This is not just flavour. The off shoulder is otherwise a full torso
    // width *behind* the weapon, and with the arms only [ArmIK.upper] +
    // [ArmIK.fore] long the support hand could not reach any foregrip: it
    // choked all the way back down the weapon and landed on top of the firing
    // fist, so every crew member appeared to hold their gun one-handed with a
    // blob of hands at the grip. The twist is what puts the off hand out on
    // the barrel where it belongs.
    final twist = (aiming || recoil > 0) && lift > 0.2 ? 0.66 : 0.0;
    final suppShoulder = Offset(
      -gunSide * (torsoW / 2 - 5) + gunSide * (torsoW - 10) * twist,
      shoulderY + 5 + twist * 7.0,
    );
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
      // Near max elevation the pure aim-line offset lands the weapon inside
      // the head's own silhouette (both hands + weapon read as jammed into
      // the face) — blend in sideways clearance as the shot steepens so it
      // swings out beside the head instead. See [ArmIK.headClearance].
      final steep = sin(angleRad).clamp(0.0, 1.0);
      // Local +x must point along the aim. Screen y-down: a positive canvas
      // rotation tips the muzzle toward the ground, so right-facing aims
      // rotate by NEGATIVE elevation, and a left-facing raft's aim line is
      // the same ray past vertical (angleRad - pi) — never `pi - angleRad`,
      // which mirrors the muzzle height.
      bodyAng = gunSide > 0 ? -angleRad : angleRad - pi;
      // Carry the weapon by its BARREL LINE, not by its grip.
      //
      // The grip hangs [WeaponView.gripY] *below* the bore (that is what the
      // weapon-local frame means), so putting the grip itself on the ray out
      // of the shoulder lifts the whole receiver a grip's height above the
      // shoulder — straight across the chin. Anchoring the bore on that ray
      // and hanging the grip off it underneath puts the gun where a shooter
      // actually holds one, and leaves the face clear at every elevation.
      final barrelAnchor = gunShoulder +
          aimDir * wv.holdDist +
          Offset(gunSide * steep * ArmIK.headClearance, 0);
      gripBody = barrelAnchor + _weaponDown(bodyAng, gunSide) * wv.gripY;
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
    final Offset suppLocal;
    if (wv.supportStyle == GripStyle.crank) {
      // A crank hold is anchored to the wheel, not slid along the barrel:
      // the fist orbits the rim as the action is worked, so choking up
      // along the weapon axis would pull it off the thing it is turning.
      suppLocal = wv.supportTarget(pumpT);
    } else {
      final suppT = ArmIK.chokeUp(
        anchor: drawnOrigin,
        axis: suppAxis,
        shoulder: suppShoulder,
        preferredT: wv.supportForeX - pumpBack - wv.gripX,
        minT: wv.receiverX0 - wv.gripX,
        maxT: (wv.muzzleX - wv.gripX) * 0.85,
      );
      suppLocal = Offset(wv.gripX + suppT, wv.supportPalmY);
    }
    var suppHand = toBody(suppLocal.dx, suppLocal.dy);

    // Torso clutch: the free hand abandons its grip point and presses the
    // wound instead — the lean above already doubles the body over it.
    if (grabbing) {
      suppHand = Offset(-gunSide * 3.5, shoulderY + torsoH * 0.66);
    } else if (bx.armRaise > 0 && (!aiming || Crew.fireFlourishes.contains(crew.idle))) {
      // The free arm goes up: a fist punched overhead for a gloat, a big
      // overhead reach for a stretch, a hand to the temple for a scratch.
      // Only while NOT aiming — a raised arm mid-shot would fight the grip
      // IK for the same limb and read as a broken pose — with the firing
      // flourish excepted, since it plays AFTER the trigger and the aim gate
      // coming back for the next turn would otherwise chop the arm down
      // mid-gesture.
      //
      // Height AND reach, because height alone put every one of them in the
      // same place: with two dozen activities in the pool, a wave, a salute
      // and somebody pointing across the water were one drawing.
      final up = Offset(
        -gunSide * 10.0 + gunSide * bx.armReach.clamp(-1.0, 1.0) * 24.0,
        shoulderY - 28.0 * bx.armRaise,
      );
      suppHand = Offset.lerp(suppHand, up, bx.armRaise.clamp(0.0, 1.0))!;
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

    // Depth: the support arm is on the far side of the body, so it is drawn
    // a shade darker than the near arm. Without this both arms read as one
    // flat tangle in front of the chest — the single biggest reason the old
    // pose looked wrong when the hands crossed.
    final farSuit = Color.lerp(suit, Colors.black, 0.22)!;
    final farSkin = Color.lerp(skin, Colors.black, 0.18)!;

    _taperedLimb(canvas, suppShoulder, suppElbow, 13, 10.5, farSuit);
    // Deltoid cap: rounds the arm into the shoulder so the bone does not
    // read as a stick pinned to the torso edge.
    canvas.drawCircle(suppShoulder, 6.5, Paint()..color = farSuit);

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

    // Sash and belt. The sash is the character's own trim colour and the
    // belt is the raft's, which is what keeps sides readable now that the
    // torso belongs to the character rather than the hull: two rival crews
    // can wear completely different outfits and still be told apart by the
    // stripe at their waist.
    canvas.drawPath(
      Path()
        ..moveTo(-gunSide * torsoW / 2, shoulderY + torsoH * 0.12)
        ..lineTo(gunSide * torsoW / 2, shoulderY + torsoH * 0.52)
        ..lineTo(gunSide * torsoW / 2, shoulderY + torsoH * 0.72)
        ..lineTo(-gunSide * torsoW / 2, shoulderY + torsoH * 0.32)
        ..close(),
      Paint()..color = _accentFor(raft).withOpacity(0.9),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-torsoW / 2, shoulderY + torsoH * 0.78, torsoW, 4),
        const Radius.circular(2),
      ),
      Paint()..color = lo.color,
    );

    // Elbow joint: a filled cap in the *sleeve* colour sized to the upper
    // arm's end, then a shallow crease over it. Filling the joint is what
    // removes the notch that a bare taper leaves at a sharp bend — the
    // forearm's narrower cap used to under-cover the upper arm's, so a
    // hard-bent elbow showed a visible bite out of the limb.
    void elbowJoint(Offset e, Color sleeve) {
      canvas.drawCircle(e, 5.2, Paint()..color = sleeve);
      canvas.drawCircle(
        e,
        5.4,
        Paint()
          ..color = Colors.black.withOpacity(0.14)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    // Forearms start at the sleeve width the upper arm ended on, so the
    // skin/sleeve transition reads as a rolled cuff instead of a step.
    elbowJoint(suppElbow, farSuit);
    _taperedLimb(canvas, suppElbow, suppHandSolved, 9.5, 6.8, farSkin);

    _taperedLimb(canvas, gunShoulder, gunElbow, 13, 10.5, suit);
    canvas.drawCircle(gunShoulder, 6.5, Paint()..color = suit);
    elbowJoint(gunElbow, suit);
    _taperedLimb(canvas, gunElbow, gunHand, 9.5, 6.8, skin);

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

    CharacterArt.headgear(canvas, raft.look, headC2, headR, dir);

    canvas.restore();
    canvas.restore();
  }

  /// The weapon-local "down" direction (from the bore toward the grip stub)
  /// expressed in body space, for a weapon drawn at [bodyAng] on [gunSide].
  ///
  /// Mirrors exactly what the drawing transform does to a local (0, 1):
  /// translate to the origin, rotate by the body angle, scale y by the facing.
  /// Shared by the renderer and [Raft.muzzle] so the drawn gun and the actual
  /// shot-spawn point can never disagree about which way is down.
  static Offset weaponDown(double bodyAng, double gunSide) =>
      Offset(-gunSide * sin(bodyAng), gunSide * cos(bodyAng));

  Offset _weaponDown(double bodyAng, double gunSide) =>
      weaponDown(bodyAng, gunSide);

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

    // Raked box magazine under the receiver — the rifle/carbine feed, and
    // visually the opposite of the round drum above.
    if (wv.magLen > 0) {
      canvas.save();
      canvas.translate((wv.receiverX0 + wv.receiverX1) / 2 + 1, wv.receiverHalf - 1);
      canvas.rotate(wv.magTilt);
      final magW = wv.receiverH * 0.30;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(-magW / 2, 0, magW, wv.magLen),
          const Radius.circular(2),
        ),
        Paint()..color = darkMetal,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(-magW / 2 + 1.1, wv.magLen * 0.45, magW - 2.2, 2.0),
          const Radius.circular(1),
        ),
        Paint()..color = accent.withOpacity(0.8),
      );
      canvas.restore();
    }

    // Winch crank behind the breech — the harpoon gun's loading action, and
    // the thing its off hand actually holds ([GripStyle.crank]).
    if (wv.crankR > 0) {
      final c = Offset(wv.crankX, wv.supportForeY);
      canvas.drawCircle(c, wv.crankR, Paint()..color = darkMetal);
      canvas.drawCircle(c, wv.crankR * 0.52, Paint()..color = metal);
      canvas.drawCircle(c, wv.crankR * 0.2, Paint()..color = accent);
      // Spokes, and an arm back up to the receiver so the wheel reads
      // mounted rather than floating.
      final spoke = Paint()
        ..color = metal
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      for (int k = 0; k < 4; k++) {
        final a = k * pi / 4 + 0.3;
        canvas.drawLine(
          c + Offset(cos(a), sin(a)) * wv.crankR * 0.25,
          c + Offset(cos(a), sin(a)) * wv.crankR * 0.86,
          spoke,
        );
      }
      canvas.drawLine(
        c + Offset(0, -wv.crankR * 0.7),
        Offset(wv.crankX + 2, wv.receiverHalf - 1),
        Paint()
          ..color = darkMetal
          ..strokeWidth = 3.0
          ..strokeCap = StrokeCap.round,
      );
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

    // Vented cooling shroud over the shaft — the heavy cannon's signature.
    // Slots are cut as gaps in a sleeve, so the barrel shows through.
    if (wv.shroudVents > 0) {
      final x0 = wv.barrelX0 + 2;
      final x1 = wv.barrelX1 - 1.5;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x0, -t / 2 - 1.8, x1 - x0, t + 3.6),
          const Radius.circular(3),
        ),
        Paint()..color = Color.lerp(metal, Colors.white, 0.05)!,
      );
      final slotPaint = Paint()..color = darkMetal;
      final pitch = (x1 - x0) / (wv.shroudVents + 1);
      for (int k = 1; k <= wv.shroudVents; k++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x0 + pitch * k - 1.4, -t / 2 - 0.4, 2.8, t + 0.8),
            const Radius.circular(1.4),
          ),
          slotPaint,
        );
      }
    }

    // Revolver cylinder between breech and barrel — the spreader's feed.
    if (wv.cylinderR > 0) {
      final c = Offset(wv.barrelX0 + 1.5, 0);
      canvas.drawCircle(c, wv.cylinderR, Paint()..color = darkMetal);
      canvas.drawCircle(c, wv.cylinderR * 0.78, Paint()..color = metal);
      // Chambers around the rim, so it reads as a revolver at a glance.
      for (int k = 0; k < 6; k++) {
        final a = k * pi / 3 + 0.25;
        canvas.drawCircle(
          c + Offset(cos(a), sin(a)) * wv.cylinderR * 0.5,
          wv.cylinderR * 0.19,
          Paint()..color = accent.withOpacity(0.9),
        );
      }
    }

    // Folding bipod under the barrel — only the heaviest launcher carries one.
    if (wv.bipodX > 0) {
      final legPaint = Paint()
        ..color = darkMetal
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      final top = Offset(wv.bipodX, t / 2);
      for (final s in [-1.0, 1.0]) {
        canvas.drawLine(top, top + Offset(s * 7.0, 13.0), legPaint);
      }
      canvas.drawCircle(top, 2.2, Paint()..color = metal);
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

    // Optical sight riding the receiver — the bomb cannon's signature. Drawn
    // after the receiver so its mounts sit on top of the housing.
    if (wv.scopeLen > 0) {
      final y = -wv.receiverHalf - 3.4;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(wv.scopeX - wv.scopeLen / 2, y - 2.6, wv.scopeLen, 5.2),
          const Radius.circular(2.6),
        ),
        Paint()..color = darkMetal,
      );
      // Objective bell at the muzzle end and a glint of glass in it.
      canvas.drawCircle(Offset(wv.scopeX + wv.scopeLen / 2, y), 3.4,
          Paint()..color = darkMetal);
      canvas.drawCircle(Offset(wv.scopeX + wv.scopeLen / 2, y), 2.0,
          Paint()..color = accent.withOpacity(0.85));
      // Mounts down to the receiver.
      final mount = Paint()
        ..color = darkMetal
        ..strokeWidth = 2.2;
      for (final dx in [-wv.scopeLen * 0.3, wv.scopeLen * 0.28]) {
        canvas.drawLine(Offset(wv.scopeX + dx, y + 2.2),
            Offset(wv.scopeX + dx, -wv.receiverHalf), mount);
      }
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
  /// The dimensions a tumbling body is actually drawn at.
  ///
  /// Pulled out as a pure function of the pose because the bug it fixes is
  /// precisely a disagreement between the skeleton and the artwork: the
  /// solver curls the body up, and the renderer used to keep drawing a
  /// full-size torso, head and boots inside it — the torso overshooting the
  /// neck and burying the head, which is what "the whole body disappears and
  /// they turn into a ball" actually was. Exposing the maths is what lets a
  /// test pin it rather than merely pin the model it is supposed to follow.
  
  static ({double curl, double torsoLen, double torsoW, double headR})
      ragdollMetrics(RagdollPose pose) {
    final curl = pose.drawScale;
    return (
      curl: curl,
      // Measured, not assumed: the slab always ends exactly at the neck.
      torsoLen: max(9.0, (pose.neck.pos - pose.hip.pos).distance),
      torsoW: 29.0 * curl,
      headR: 14.0 * curl,
    );
  }

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
    final suit = _outfitFor(raft);
    const boot = Color(0xFF23262B);
    const metal = Color(0xFF3B3F45);

    // How far the physics body is curled, as a scale factor on every drawn
    // part. This is the fix for the ragdoll turning into an unreadable blob:
    // a tuck shrinks every CONSTRAINT (that is what buys the rotation for a
    // somersault), but the drawn torso, head and boots used to keep their
    // full standing size. At a deep tuck the neck sat about nine units from
    // the hip while the torso slab was still drawn twenty-seven long, so the
    // torso overshot the neck and swallowed the head, and a fourteen-radius
    // head sat centred inside it. That is what "the body disappears and they
    // turn into a ball" actually was — not missing geometry, but every part
    // drawn at full size inside a third of the space.
    //
    // Scaling the art by the same factor the solver scales the skeleton
    // keeps a curled body reading as a curled *person*.
    final m = ragdollMetrics(pose);
    final curl = m.curl;

    // The body's own frame: along the spine, and across it. Every limb root
    // is placed in this frame rather than at a bare physics point, which is
    // what stops a tumbling character reading as a stick figure — the
    // ragdoll used to hang both arms off the single neck point and both legs
    // off the single hip point, so a knocked-down crew member turned into a
    // cruder character than the one standing a frame earlier.
    final spineVec = pose.neck.pos - pose.hip.pos;
    final spineLen = spineVec.distance;
    final su = spineLen > 1e-3
        ? spineVec / spineLen
        : const Offset(0, -1); // hip -> neck
    final sp = Offset(-su.dy, su.dx); // across the shoulders

    // Two-bone IK in the body's own scale. Solving in world units would put
    // the elbow outside a curled body, because the IK's bone lengths are
    // fixed while the skeleton shrinks with the tuck; dividing into unscaled
    // space, solving, and scaling back shortens the bones by exactly the
    // same factor everything else uses.
    (Offset, Offset) armIK(Offset shoulder, Offset target, double bend) {
      final safe = curl < 0.05 ? 0.05 : curl;
      final (e, h) = ArmIK.solve(
        shoulder,
        shoulder + (target - shoulder) / safe,
        bend: bend,
      );
      return (
        shoulder + (e - shoulder) * safe,
        shoulder + (h - shoulder) * safe,
      );
    }

    final farSuit = Color.lerp(suit, Colors.black, 0.22)!;
    final farSkin = Color.lerp(skin, Colors.black, 0.18)!;

    // Shoulders sit either side of the spine just below the neck, exactly as
    // they do on the standing rig (torso half-width less the sleeve inset).
    final shoulderNear = pose.neck.pos - su * (5 * curl) + sp * (9.5 * curl);
    final shoulderFar = pose.neck.pos - su * (5 * curl) - sp * (9.5 * curl);

    void elbowJoint(Offset e, Color sleeve) {
      canvas.drawCircle(e, 5.2 * curl, Paint()..color = sleeve);
      canvas.drawCircle(
        e,
        5.4 * curl,
        Paint()
          ..color = Colors.black.withOpacity(0.14)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 * curl,
      );
    }

    /// One articulated arm: sleeve to the elbow, skin to the fist.
    void drawArm(Offset shoulder, Offset elbow, Offset wrist, Color sleeve,
        Color hide) {
      _taperedLimb(canvas, shoulder, elbow, 13 * curl, 10.5 * curl, sleeve);
      canvas.drawCircle(shoulder, 6.5 * curl, Paint()..color = sleeve);
      elbowJoint(elbow, sleeve);
      _taperedLimb(canvas, elbow, wrist, 9.5 * curl, 6.8 * curl, hide);
      canvas.drawCircle(wrist, 5.0 * curl, Paint()..color = hide);
    }

    Offset arm(Offset shoulder, Offset hand, double bend, Color sleeve, Color hide) {
      final (elbow, wrist) = armIK(shoulder, hand, bend);
      drawArm(shoulder, elbow, wrist, sleeve, hide);
      return wrist;
    }

    // The gun hand is solved up front, because the weapon has to be drawn
    // BEHIND the torso and the arm in front of it. A tumbling body's arm
    // folds right up against the chest — the hand ends up a few units from
    // the neck rather than out at arm's length — so a weapon drawn on top,
    // as the standing pose draws it, lies straight across the character and
    // hides the person the player is trying to read.
    final (gunElbow, gunWrist) = armIK(shoulderNear, pose.handR.pos, 1);

    // Legs first (behind the torso), rooted at a pelvis rather than a point:
    // each thigh starts offset across the spine toward its own foot, so the
    // legs splay from hips the way the standing pose's do instead of both
    // sprouting from one spot.
    // The far leg is shaded down like the far arm. Both legs are the same
    // near-black, and on a body lying with its feet together they merged into
    // one shapeless mass; a little depth separation is what makes them read
    // as two legs again.
    final farBoot = Color.lerp(boot, Colors.black, 0.35)!;
    for (final entry in [(pose.footL, farBoot), (pose.footR, boot)]) {
      final foot = entry.$1;
      final shade = entry.$2;
      final toFoot = foot.pos - pose.hip.pos;
      final across = sp.dx * toFoot.dx + sp.dy * toFoot.dy;
      final anchor = pose.hip.pos + sp * (across * 0.35);
      _taperedLimb(canvas, anchor, foot.pos, 12 * curl, 9 * curl, shade);
      final shin = foot.pos - anchor;
      final shinAng = shin.distance > 1 ? atan2(shin.dy, shin.dx) : pi / 2;
      canvas.save();
      canvas.translate(foot.pos.dx, foot.pos.dy);
      canvas.rotate(shinAng + pi / 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset.zero, width: 15 * curl, height: 9 * curl),
          Radius.circular(4.5 * curl),
        ),
        Paint()..color = shade,
      );
      canvas.restore();
    }

    // Support arm behind the torso — unless a torso hit left them clutching
    // the wound, in which case the hand grabs the spot instead of flailing.
    if (crew.grabT > 0) {
      final grab = (pose.neck.pos + pose.hip.pos) / 2 + sp * (4 * curl * dir) +
          su * (-2 * curl);
      final press = arm(shoulderFar, grab, -1, farSuit, farSkin);
      canvas.drawLine(
        press + sp * (-2.4 * curl), press + sp * (2.4 * curl),
        Paint()
          ..color = Colors.black.withOpacity(0.2)
          ..strokeWidth = 1.4 * curl
          ..strokeCap = StrokeCap.round,
      );
    } else {
      arm(shoulderFar, pose.handL.pos, -1, farSuit, farSkin);
    }

    // The equipped firearm, drawn BEHIND the torso.
    //
    // The standing pose draws it in front, where the arm holds it out clear
    // of the body. A tumbling arm folds up against the chest instead, so in
    // front meant a large weapon lying straight across the character and
    // hiding them. Behind, it reads as still gripped — poking out either
    // side of the body — without covering the person.
    if (weapon != null || crew.equipped != null) {
      final equippedId = crew.equipped ?? weapon!.id;
      final wv = WeaponView.forCrew(equippedId, weapon,
          variant: WeaponView.variantForPhase(crew.bobPhase, equippedId));
      final aim = pose.handR.pos - pose.handL.pos;
      final u = aim.distance > 1 ? aim / aim.distance : Offset(dir, 0);
      canvas.save();
      // Anchored on the SOLVED wrist, not the raw physics hand: those two
      // part company whenever the tumble throws a hand past arm's reach, and
      // the gun would then hang in space beside the fist gripping it.
      canvas.translate(gunWrist.dx, gunWrist.dy);
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


    // Torso: a rounded slab spanning neck→hip, oriented along the spine —
    // same shape, shading band, sash and belt as the standing body.
    //
    // Its LENGTH is the live spine distance rather than a constant. Drawing
    // a fixed twenty-seven from the hip is what let a curled torso overshoot
    // the neck and bury the head; measuring it means the slab always ends
    // exactly where the neck is, curled or sprawled.
    final spineAng = atan2(spineVec.dy, spineVec.dx);
    final torsoH = m.torsoLen;
    final torsoW = m.torsoW;
    canvas.save();
    canvas.translate(pose.hip.pos.dx, pose.hip.pos.dy);
    canvas.rotate(spineAng + pi / 2);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(-torsoW / 2, -torsoH, torsoW, torsoH),
        topLeft: Radius.circular(11 * curl),
        topRight: Radius.circular(11 * curl),
        bottomLeft: Radius.circular(6 * curl),
        bottomRight: Radius.circular(6 * curl),
      ),
      Paint()..color = suit,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-torsoW / 2, -torsoH * 0.4, torsoW, torsoH * 0.4),
        Radius.circular(6 * curl),
      ),
      Paint()..color = Colors.black.withOpacity(0.1),
    );
    // The sash and belt the standing body wears. Without them a knocked-down
    // character loses the trim that says whose crew they are, at exactly the
    // moment the player is looking at them.
    canvas.drawPath(
      Path()
        ..moveTo(-torsoW / 2, -torsoH * 0.88)
        ..lineTo(torsoW / 2, -torsoH * 0.48)
        ..lineTo(torsoW / 2, -torsoH * 0.28)
        ..lineTo(-torsoW / 2, -torsoH * 0.68)
        ..close(),
      Paint()..color = _accentFor(raft).withOpacity(0.9),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-torsoW / 2, -torsoH * 0.22, torsoW, 4 * curl),
        Radius.circular(2 * curl),
      ),
      Paint()..color = raft.loadout.color,
    );
    canvas.restore();

    // Gun arm, over the torso: the fist lands on the grip of the weapon
    // passing behind the body, so it still reads as held rather than
    // dropped.
    drawArm(shoulderNear, gunElbow, gunWrist, suit, skin);

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
    // The head follows the neck, continuously.
    //
    // This used to be wrapped into the nearest upright orientation to avoid
    // ever drawing an inverted face — but wrapping by π is a DISCONTINUITY:
    // as a somersaulting body turned smoothly past ninety degrees the drawn
    // head snapped through half a turn, twice per revolution. That visible
    // jerk, on top of the head visibly refusing to travel with the body it
    // is attached to, is most of what made a tumble look wrong.
    //
    // Rotating by the raw angle is safe precisely because it only ever wraps
    // by a full 2π, which is visually identical — the same reason the torso
    // has always been able to use its spine angle directly.
    final hAng = atan2(hAxis.dy, hAxis.dx) + pi / 2;
    canvas.save();
    canvas.translate(pose.head.pos.dx, pose.head.pos.dy);
    canvas.rotate(hAng);
    // Scaled with the curl like everything else — a full-size head on a
    // curled body is most of what read as "a ball".
    final headR = m.headR;
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
    CharacterArt.headgear(canvas, raft.look, Offset.zero, headR, dir);
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
    // Idle fidgets only surface when nothing more urgent is on the face.
    //
    // A firing flourish is the exception to both gates: it exists precisely
    // for the beat after the trigger, when the shot is away and the shooter
    // is free to gloat about it. It has to survive `firing` (which is the
    // recoil window, and overlaps the start of every flourish) and `aiming`
    // (which comes back the moment the next turn opens, and would otherwise
    // cut the pose off halfway through).
    final flourishing = Crew.fireFlourishes.contains(crew.idle);
    final idleAct =
        (!dead && pain <= 0 && gloat <= 0 && (flourishing || (!aiming && !firing)))
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

    // The scatter is a pure function of the crew member's phase and how hurt
    // they are, so it is computed once and kept. It used to allocate a
    // seeded Random, run nine draws off it and build a fresh record list on
    // every frame for every injured body — work that produced byte-identical
    // numbers each time. That cost appeared the moment somebody took a hit
    // and never went away, which is exactly the shape of the complaint.
    final layout = _injuryCache.putIfAbsent(
      (crew.bobPhase * 1000).round() * 4 + level,
      () {
        injuryLayouts++;
        return _InjuryLayout.build(crew.bobPhase, level);
      },
    );

    void spot(Offset base, Offset jitter, double r) {
      final at = base + jitter;
      canvas.drawCircle(at, r, _bruisePaint);
      canvas.drawCircle(at + const Offset(0.5, 0.4), r * 0.55, _bruiseDarkPaint);
    }

    // Bruise spots: one on the torso when scuffed, an arm/leg when worse,
    // and a shiner on the cheek when properly battered.
    spot(torC, layout.torso, layout.torsoR);
    if (level >= 2) {
      spot(legC, layout.leg, layout.legR);
      spot(armC, layout.arm, layout.armR);
    }
    if (level >= 3) {
      spot(headC, layout.head + Offset(dir * 3.2, 0), layout.headR);
      spot(torC, layout.torso2, layout.torso2R);
    }

    // Cuts appear once they're properly hurt, another when battered.
    if (level >= 2) {
      final c = torC + layout.cutTorso;
      canvas.drawLine(
          c + const Offset(-2.4, -1), c + const Offset(2.4, 1), _cutPaint);
    }
    if (level >= 3) {
      final c = legC + layout.cutLeg;
      canvas.drawLine(
          c + const Offset(-2.2, -0.8), c + const Offset(2.2, 0.9), _cutPaint);
    }
  }

  /// Injury scatter per (crew phase, injury level). Bounded because both
  /// inputs are: a battle has a handful of crew and four injury levels.
  final Map<int, _InjuryLayout> _injuryCache = {};

  /// Work done that a cache is supposed to make rare, counted so the tests
  /// can pin it without measuring wall-clock time. Each of these used to
  /// happen on every frame for as long as a body was hurt, talking or down,
  /// which is what made the frame rate fall the moment shots started landing.
  
  int textLayouts = 0;
  
  int injuryLayouts = 0;
  
  int bodyLayers = 0;

  /// Rafts actually drawn last frame, after culling. Counted so a test can
  /// pin the cull directly rather than inferring it from something else.
  
  int raftsDrawn = 0;

  static final Paint _bruisePaint = Paint()
    ..color = const Color(0xFF6D3B8E).withOpacity(0.5);
  static final Paint _bruiseDarkPaint = Paint()
    ..color = const Color(0xFF4A2470).withOpacity(0.45);
  static final Paint _cutPaint = Paint()
    ..color = const Color(0xFFC0392B).withOpacity(0.8)
    ..strokeWidth = 1.5
    ..strokeCap = StrokeCap.round;

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

  /// A tapered, capped "bone" — the building block for every arm and leg.
  /// Narrows from [widthA] at [a] to [widthB] at [b] rather than holding one
  /// uniform stroke width. Always convex, so it reads as a limb at any
  /// rotation — which is what makes the gun arm safe to swing to an
  /// arbitrary angle at runtime instead of needing a pre-drawn pose per
  /// angle.
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
  /// Scratch drawing objects, reused instead of reallocated.
  ///
  /// The limb painters ran `Paint()` and `Path()` on every call, and a limb
  /// is drawn about ten times per body per frame — so a deck of crew churned
  /// thousands of short-lived objects a second. That never showed up in an
  /// average frame time (0.7ms) but it landed as GC pauses on individual
  /// frames: measured worst-case frames of 27–55ms against that 0.7ms
  /// typical. A stutter is a tail-latency problem, and this was the tail.
  ///
  /// Safe to reuse because the canvas snapshots a paint's state at the draw
  /// call and reads a path immediately — neither is retained afterwards.
  final Paint _limbPaint = Paint();
  final Path _limbPath = Path();

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
    final paint = _limbPaint
      ..color = color
      ..style = PaintingStyle.fill
      ..shader = null
      ..strokeWidth = 0;
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
      _limbPath
        ..reset()
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
      p4,
      p3,
      _creasePaint..strokeWidth = min(rA, rB) * 0.7,
    );
  }

  /// The shading crease down a limb. Constant but for its width, so it is
  /// built once instead of on every limb of every body of every frame.
  static final Paint _creasePaint = Paint()
    ..color = Colors.black.withOpacity(0.13)
    ..strokeCap = StrokeCap.round;

  Color _skinFor(CrewLook look) => Cast.of(look).skin;

  /// The character's own outfit colour, with the raft's colour kept as trim.
  ///
  /// The torso used to be "blue if you, otherwise the raft hull's colour",
  /// which made every enemy on a red raft the same red person. Letting the
  /// character own the outfit is what makes a parka-wrapped icebreaker and a
  /// soot-blackened stoker read as different people at a glance; the raft
  /// colour moves to the sash and cuffs, where it still says which side a
  /// body belongs to without flattening the cast.
  Color _outfitFor(Raft raft) => Cast.of(raft.look).outfit;

  Color _accentFor(Raft raft) => Cast.of(raft.look).accent;


  void _enemyLabel(Canvas canvas, Raft raft, double bob) {
    final lo = raft.loadout;
    final top = raft.waterLine - lo.deckRise - 104 + bob;

    // Cached: a raft's name never changes mid-match, so re-shaping it every
    // frame for every raft was pure waste.
    final tp = _text(raft.label,
        size: 10, color: RT.ink, weight: FontWeight.w800, letterSpacing: 1.2);
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
    _projectile(canvas, s, r);
  }

  /// The round itself.
  ///
  /// Ordinary ordnance is a coloured ball, as it always was. A boss's
  /// signature round is not: it spins, it trails, and it is shaped like the
  /// thing it does. That silhouette in the air is the ONLY warning the
  /// player gets that this shot is about to take a turn's advantage away
  /// from them, so it has to be legible at a glance and never mistakable for
  /// an ordinary round.
  void _projectile(Canvas canvas, Shot s, double r) {
    final c = s.weapon.color;
    // Spin rate follows the flight, so a shard cartwheels visibly and a
    // heavy tar pot wallows.
    final spin = (world.elapsed - s.firedAt) * (6.5 / max(0.4, s.weapon.weight));

    switch (s.weapon.projectile) {
      case 'shard':
        // A frost shard: a four-pointed spike that glitters as it turns.
        canvas.save();
        canvas.translate(s.pos.dx, s.pos.dy);
        canvas.rotate(spin);
        final p = Path();
        for (int i = 0; i < 4; i++) {
          final a = i * pi / 2;
          p.moveTo(0, 0);
          p.lineTo(cos(a) * r * 2.1, sin(a) * r * 2.1);
          p.lineTo(cos(a + 0.42) * r * 0.75, sin(a + 0.42) * r * 0.75);
          p.close();
        }
        canvas.drawPath(p, Paint()..color = c);
        canvas.drawCircle(Offset.zero, r * 0.6, Paint()..color = Colors.white.withOpacity(0.85));
        canvas.restore();
        break;

      case 'blob':
        // A tar pot: a fat wobbling drop with a drip hanging off the back.
        final wob = sin(spin * 1.6) * r * 0.16;
        canvas.drawOval(
          Rect.fromCenter(
              center: s.pos, width: r * 2.3 + wob, height: r * 2.1 - wob),
          Paint()..color = c,
        );
        canvas.drawCircle(
          s.pos - Offset(s.vel.dx, s.vel.dy) * 0.22,
          r * 0.55,
          Paint()..color = c.withOpacity(0.7),
        );
        canvas.drawCircle(
          s.pos + Offset(-r * 0.4, -r * 0.5),
          r * 0.32,
          Paint()..color = Colors.white.withOpacity(0.35),
        );
        break;

      case 'ember':
        // Burning grit: a hot core inside a flickering halo.
        final flick = 0.75 + 0.25 * sin(spin * 3.1);
        canvas.drawCircle(
            s.pos, r * 1.9 * flick, Paint()..color = c.withOpacity(0.35));
        canvas.drawCircle(s.pos, r * 1.15, Paint()..color = c);
        canvas.drawCircle(
            s.pos, r * 0.55, Paint()..color = Colors.white.withOpacity(0.9));
        break;

      case 'net':
        // A weighted net, drawn as a spinning mesh square with corner shot.
        canvas.save();
        canvas.translate(s.pos.dx, s.pos.dy);
        canvas.rotate(spin * 0.6);
        final half = r * 1.7;
        final mesh = Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6;
        for (int i = -1; i <= 1; i++) {
          canvas.drawLine(Offset(i * half * 0.7, -half),
              Offset(i * half * 0.7, half), mesh);
          canvas.drawLine(Offset(-half, i * half * 0.7),
              Offset(half, i * half * 0.7), mesh);
        }
        for (final sx in [-1.0, 1.0]) {
          for (final sy in [-1.0, 1.0]) {
            canvas.drawCircle(Offset(sx * half, sy * half), r * 0.42,
                Paint()..color = Color.lerp(c, Colors.black, 0.4)!);
          }
        }
        canvas.restore();
        break;

      case 'disc':
        // A saw disc: a toothed wheel, edge-on to the flight path.
        canvas.save();
        canvas.translate(s.pos.dx, s.pos.dy);
        canvas.rotate(spin * 1.8);
        canvas.drawCircle(Offset.zero, r * 1.5, Paint()..color = c);
        final teeth = Paint()..color = Color.lerp(c, Colors.black, 0.35)!;
        for (int i = 0; i < 8; i++) {
          final a = i * pi / 4;
          canvas.drawCircle(
              Offset(cos(a), sin(a)) * r * 1.5, r * 0.38, teeth);
        }
        canvas.drawCircle(Offset.zero, r * 0.45,
            Paint()..color = Colors.white.withOpacity(0.8));
        canvas.restore();
        break;

      default:
        canvas.drawCircle(s.pos, r, Paint()..color = c);
    }
  }

  void _drawEffects(Canvas canvas) {
    for (final fx in world.effects) {
      // An impact away from the camera still spawns its full set of effects.
      // Drawing them costs the most of anything on screen, and they are the
      // one thing that only appears when something is hit.
      if (!_visible(fx.pos.dx, fx.size * 2)) continue;
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
    final scale = size.height / BattleConst.viewH;
    canvas.save();
    canvas.scale(scale);
    canvas.translate(-world.cam, -world.camY);
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

/// Where one crew member's bruises and cuts sit on their body.
///
/// Deterministic from their bob phase, so a given character always carries
/// the same marks in the same places — and computed once rather than
/// re-rolled from a fresh seeded [Random] on every frame.
class _InjuryLayout {
  final Offset torso, leg, arm, head, torso2, cutTorso, cutLeg;
  final double torsoR, legR, armR, headR, torso2R;

  const _InjuryLayout({
    required this.torso,
    required this.leg,
    required this.arm,
    required this.head,
    required this.torso2,
    required this.cutTorso,
    required this.cutLeg,
    required this.torsoR,
    required this.legR,
    required this.armR,
    required this.headR,
    required this.torso2R,
  });

  factory _InjuryLayout.build(double bobPhase, int level) {
    final rng = Random((bobPhase * 1000).round() ^ 0xC0FFEE);
    double rx(double spread) => rng.nextDouble() * spread - spread / 2;
    // Drawn in the same order the old inline code drew them, so a character's
    // marks land exactly where they always did.
    final torso = Offset(rx(8), rx(6));
    final torsoR = rng.nextDouble() * 2.2 + 2.0;
    final leg = level >= 2 ? Offset(rx(6), rx(3)) : Offset.zero;
    final legR = level >= 2 ? rng.nextDouble() * 2.2 + 1.8 : 0.0;
    final arm = level >= 2 ? Offset(rx(5), rx(4)) : Offset.zero;
    final armR = level >= 2 ? rng.nextDouble() * 2.0 + 1.6 : 0.0;
    final head = level >= 3 ? Offset(rx(2), rx(3) + 1) : Offset.zero;
    final headR = level >= 3 ? rng.nextDouble() * 1.8 + 1.4 : 0.0;
    final torso2 = level >= 3 ? Offset(rx(10), rx(6)) : Offset.zero;
    final torso2R = level >= 3 ? rng.nextDouble() * 2.0 + 1.8 : 0.0;
    final cutTorso = level >= 2 ? Offset(rx(6), rx(4)) : Offset.zero;
    final cutLeg = level >= 3 ? Offset(rx(5), 1.2) : Offset.zero;
    return _InjuryLayout(
      torso: torso, leg: leg, arm: arm, head: head, torso2: torso2,
      cutTorso: cutTorso, cutLeg: cutLeg,
      torsoR: torsoR, legR: legR, armR: armR, headR: headR, torso2R: torso2R,
    );
  }
}
