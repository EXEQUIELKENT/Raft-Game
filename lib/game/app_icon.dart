import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'character_art.dart';
import 'characters.dart';

/// ---------------------------------------------------------------------------
/// The launcher icon, drawn rather than drawn *over*.
///
/// Everything else in this game is procedural — there is not one bitmap in
/// the whole project — and the icon was the single exception: a 192px sticker
/// PNG, the same file copied into every density bucket, with a white sticker
/// outline and transparent corners that a launcher mask cuts straight
/// through. Nothing about it tracked the game, so a change to the crew art
/// left the icon showing a character the game no longer has.
///
/// This draws the same character the battle does, from [CharacterArt], at
/// whatever size it is handed. The PNGs in `android/app/src/main/res` are
/// generated from it (see `tool/generate_app_icons.dart`), so regenerating
/// them is how the icon stays current.
///
/// ## Designing for 48 pixels
///
/// The icon is a launcher tile before it is a picture, and the smallest
/// bucket is 48px square. What survives that is ONE silhouette with a couple
/// of strong colour blocks; what does not is detail. So the composition is
/// deliberately top-heavy and short on parts: warm sky, a hard horizon, a
/// dark timber raft, and an outsized cartoon head above it with the game's
/// orange arcing overhead. Read at 48px it is a face on water under an arc.
/// Read at 192px the bandana, the grin and the planks are all there.
/// ---------------------------------------------------------------------------
class AppIcon {
  AppIcon._();

  /// The character the icon wears.
  ///
  /// A hat is not decoration here, it is the silhouette. The default player
  /// captain has [HeadGear.none], and a bare head at 48px is a circle with
  /// two dots — indistinguishable from every emoji-faced app on the home
  /// screen. The Drifter's straw hat is the best silhouette the roster
  /// has for this: a wide brim and a round crown, warm against the sky, and
  /// it says castaway-on-a-raft rather than generic. The tricorn was tried
  /// first and renders as a flat dark bar across the head at tile size.
  ///
  /// It also has to be a character the player can actually BE. The first
  /// pick was the Log Raider, whose bandana suited the tile but who is
  /// enemy-only — the icon would have advertised somebody you only ever
  /// shoot at.
  static const CrewLook look = CrewLook.drifter;

  /// Behind the adaptive foreground. A flat colour rather than a gradient
  /// because Android tints, masks and parallaxes this layer, and a gradient
  /// that slides under a mask reads as a rendering fault.
  static const Color adaptiveBackground = Color(0xFF2C8B99);

  /// The legacy square icon: full bleed, no transparency, its own rounded
  /// corners.
  ///
  /// Full bleed matters. The old icon drew a sticker with clear corners, so
  /// every launcher that masks to a circle or squircle cut through empty
  /// pixels and left the art floating inside a notch of background.
  static void paintLegacy(Canvas canvas, double size) {
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size, size),
      Radius.circular(size * 0.22),
    );
    canvas.save();
    canvas.clipRRect(r);
    _scene(canvas, size);
    canvas.restore();
  }

  /// The adaptive foreground: the same scene, transparent outside it, with
  /// the art pulled into the middle.
  ///
  /// Android draws this on a 108dp canvas and guarantees only the central
  /// 66dp survives masking — so the art is scaled to sit inside that circle
  /// and nothing that matters goes near the edge.
  static void paintAdaptiveForeground(Canvas canvas, double size) {
    final u = size / 100.0;
    // The drawn content, in scene units — which is NOT the scene's own
    // square. The sky and sea are dropped in this mode, so what is left
    // runs from the bandana tail out to the shot, and it sits high and
    // right of centre.
    //
    // Scaling the square about its middle, as this first did, therefore
    // left the art off-centre and pushed the ball out past the circle
    // Android guarantees to show. Centring the CONTENT and sizing it to
    // that circle is what actually keeps all of it.
    // Wide on the left for the straw hat brim, which reaches further out
    // than the head does.
    const box = Rect.fromLTRB(10, 14, 101, 82);
    // 66dp of the 108dp canvas: the largest circle Android GUARANTEES
    // every OEM mask leaves visible. Sizing to the 72dp viewport instead
    // left a few dozen pixels of the shot outside it — a coin toss per
    // device, for no gain worth having.
    const visible = 66 / 108;
    final radius = size * visible / 2;
    final corner =
        Offset(box.width / 2 * u, box.height / 2 * u).distance;
    final scale = radius / corner;

    canvas.save();
    canvas.translate(size / 2, size / 2);
    canvas.scale(scale);
    canvas.translate(-box.center.dx * u, -box.center.dy * u);
    _scene(canvas, size, transparent: true);
    canvas.restore();
  }

  /// The round icon, for launchers that ask for one specifically.
  static void paintRound(Canvas canvas, double size) {
    canvas.save();
    canvas.clipPath(Path()
      ..addOval(Rect.fromCircle(
          center: Offset(size / 2, size / 2), radius: size / 2)));
    _scene(canvas, size);
    canvas.restore();
  }

  /// The picture itself, in a unit square scaled to [size].
  ///
  /// [transparent] leaves out the sky and sea, for the adaptive foreground
  /// that has a background layer of its own underneath.
  static void _scene(Canvas canvas, double size, {bool transparent = false}) {
    final u = size / 100.0; // one unit = 1% of the icon
    final ch = Cast.of(look);

    // Sea level, and the horizon that separates the two colour blocks. High
    // enough that the water is a band rather than a backdrop — the face has
    // to own the middle.
    const seaY = 66.0;

    if (!transparent) {
      // Warm sky: the game's own sunset, which is what the menus and the
      // battle sky already are.
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size, seaY * u),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [RT.sky1, RT.sky2, RT.sky3],
            stops: [0, 0.55, 1],
          ).createShader(Rect.fromLTWH(0, 0, size, seaY * u)),
      );

      // No sun. There were two attempts at one and both made the icon
      // worse: centred and warm it sat behind the head at almost exactly
      // skin tone and the two merged into a shapeless blob; moved up and
      // right it landed on the tip of the bandana's tail and turned a
      // pirate into Father Christmas. The head needs plain sky behind it.

      // Sea: two flat bands, the darker one first, with a scalloped crest
      // between them. Flat because banding is what survives downscaling.
      canvas.drawRect(
        Rect.fromLTWH(0, seaY * u, size, size - seaY * u),
        Paint()..color = RT.sea2,
      );
      final crest = Path()..moveTo(0, seaY * u);
      for (int i = 0; i < 4; i++) {
        final x0 = i * 25.0 * u;
        crest.quadraticBezierTo(
          x0 + 12.5 * u, (seaY - 5) * u,
          x0 + 25 * u, seaY * u,
        );
      }
      crest
        ..lineTo(size, (seaY + 12) * u)
        ..lineTo(0, (seaY + 12) * u)
        ..close();
      canvas.drawPath(crest, Paint()..color = RT.sea1);
    }

    // The raft: a dark timber slab the character stands on, wider than the
    // body so it reads as a platform rather than a shadow.
    final deckY = 72.0 * u;
    const timber = Color(0xFF8A5A32);
    const timberDark = Color(0xFF6B4525);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(50 * u, deckY + 5 * u),
            width: 62 * u,
            height: 11 * u),
        Radius.circular(4 * u),
      ),
      Paint()..color = timber,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(50 * u, deckY + 9 * u),
            width: 62 * u,
            height: 4 * u),
        Radius.circular(2 * u),
      ),
      Paint()..color = timberDark,
    );
    // Plank seams, the one piece of fine detail — it simply disappears at
    // 48px rather than turning to mud, which is the right way to lose.
    final seam = Paint()
      ..color = timberDark
      ..strokeWidth = 1.1 * u;
    for (final dx in [-20.0, -7.0, 7.0, 20.0]) {
      canvas.drawLine(
        Offset((50 + dx) * u, deckY),
        Offset((50 + dx) * u, deckY + 9 * u),
        seam,
      );
    }

    // Shoulders, under the head, in the character's own outfit colours.
    // Outlined, like every chunky element in the game's own UI: at icon
    // sizes an ink keyline is what separates the body from the water
    // behind it, and without one the whole lower half turned to soup.
    final line = Paint()
      ..color = RT.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6 * u
      ..strokeJoin = StrokeJoin.round;

    final shoulders = RRect.fromRectAndCorners(
      Rect.fromCenter(
          center: Offset(50 * u, deckY - 3 * u), width: 40 * u, height: 20 * u),
      topLeft: Radius.circular(10 * u),
      topRight: Radius.circular(10 * u),
    );
    canvas.drawRRect(shoulders, Paint()..color = ch.outfit);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(50 * u, deckY - 4 * u),
            width: 40 * u,
            height: 5 * u),
        Radius.circular(2.5 * u),
      ),
      Paint()..color = ch.accent,
    );
    canvas.drawRRect(shoulders, line);

    // The head: oversized, a cartoon proportion, and the one shape that has
    // to survive being 20 pixels across. Set left of centre to open up the
    // top-right corner for the shot, which otherwise had nowhere to go that
    // was not already bandana.
    final headC = Offset(42 * u, 43 * u);
    final headR = 20.0 * u;
    canvas.drawCircle(headC, headR, Paint()..color = ch.skin);
    canvas.drawArc(
      Rect.fromCircle(center: headC, radius: headR),
      0.35,
      pi * 0.7,
      false,
      Paint()
        ..color = Colors.black.withOpacity(0.07)
        ..style = PaintingStyle.stroke
        ..strokeWidth = headR * 0.22,
    );
    canvas.drawCircle(headC, headR, line);

    // A grin and two bright eyes: the expression is fixed here, because the
    // battle's expression system is driven by combat state and an icon has
    // none. Cheerful is the right resting face for the game.
    final ink = Paint()..color = RT.ink;
    for (final s in [-1.0, 1.0]) {
      canvas.drawCircle(
          headC + Offset(s * headR * 0.36, -headR * 0.08), headR * 0.17, ink);
      canvas.drawCircle(
        headC + Offset(s * headR * 0.36 + headR * 0.06, -headR * 0.15),
        headR * 0.06,
        Paint()..color = Colors.white,
      );
    }
    canvas.drawArc(
      Rect.fromCenter(
          center: headC + Offset(0, headR * 0.36),
          width: headR * 0.8,
          height: headR * 0.52),
      0.2,
      2.74,
      false,
      Paint()
        ..color = RT.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = headR * 0.13
        ..strokeCap = StrokeCap.round,
    );

    // The hat, from the same painter the battle and the roster picker use —
    // which is the whole reason this file draws a character instead of a
    // picture of one.
    CharacterArt.headgear(canvas, look, headC, headR, 1);

    // The shot, LAST and clear of the head. It is the only mark that says
    // what the game IS rather than who is in it, so it goes on top of
    // everything — an earlier version drew it first and the head and the
    // bandana swallowed it whole.
    //
    // Dots on a parabola rather than a drawn line, because that is the
    // game's own trajectory preview and because a continuous stroke from
    // the deck up to a ball read unmistakably as a fishing rod. A dotted
    // arc that rises AND falls cannot be read as anything but a lobbed
    // shot, which is the entire game in one mark.
    Offset shotAt(double t) {
      // A real parabola, launched up and to the right off the deck.
      const x0 = 56.0, y0 = 58.0, vx = 44.0, vy = -74.0, g = 96.0;
      return Offset((x0 + vx * t) * u, (y0 + vy * t + 0.5 * g * t * t) * u);
    }

    for (int i = 1; i <= 5; i++) {
      final p = shotAt(i / 7);
      final r = (1.6 + i * 0.42) * u;
      canvas.drawCircle(p, r + 1.5 * u, Paint()..color = RT.ink);
      canvas.drawCircle(p, r, Paint()..color = RT.cream);
    }

    final ball = shotAt(6 / 7);
    canvas.drawCircle(ball, 8.4 * u, Paint()..color = RT.ink);
    canvas.drawCircle(ball, 6.2 * u, Paint()..color = RT.orange);
    canvas.drawCircle(ball + Offset(-2 * u, -2 * u), 2 * u,
        Paint()..color = Colors.white.withOpacity(0.7));
  }
}
