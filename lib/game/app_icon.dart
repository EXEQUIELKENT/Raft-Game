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
/// one diagonal read: the captain — big straw hat, bigger grin — on a dark
/// timber raft at the lower left, his cannon's dotted shot climbing to the
/// right, and the burst where it lands on the enemy raft at the far
/// horizon. Read at 48px it is a face, an arc and a burst. Read at 192px
/// the wheel, the planks, the flag and the grin are all there.
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
    // runs from the far tip of the straw hat brim out to the burst on the
    // enemy raft, and it sits low and left, weighted toward the captain.
    //
    // Scaling the square about its middle, as this first did, therefore
    // left the art off-centre and pushed the shot out past the circle
    // Android guarantees to show. Centring the CONTENT and sizing it to
    // that circle is what actually keeps all of it.
    const box = Rect.fromLTRB(2, 14, 102, 84);
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
    // body so it reads as a platform rather than a shadow. Pushed left of
    // centre — the right half of the tile belongs to the shot and where it
    // lands, and the diagonal from captain to burst is the composition.
    final deckY = 72.0 * u;
    const timber = Color(0xFF8A5A32);
    const timberDark = Color(0xFF6B4525);
    const timberDeep = Color(0xFF503319);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(34 * u, deckY + 5 * u),
            width: 58 * u,
            height: 11 * u),
        Radius.circular(4 * u),
      ),
      Paint()..color = timber,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(34 * u, deckY + 9 * u),
            width: 58 * u,
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
    for (final dx in [-18.0, -6.0, 6.0, 18.0]) {
      canvas.drawLine(
        Offset((34 + dx) * u, deckY),
        Offset((34 + dx) * u, deckY + 9 * u),
        seam,
      );
    }

    // The enemy raft: small, dark and far away on the horizon, flying a
    // red flag. Without it the icon is a boat ride; with it, the tile says
    // DUEL — somebody over there is about to have a bad day. At 48px it is
    // a dark blob with a dot of red, which is exactly as much opponent as
    // a tile this size can carry.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(87 * u, 66.5 * u), width: 24 * u, height: 7 * u),
        Radius.circular(2.5 * u),
      ),
      Paint()..color = timberDark,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(87 * u, 69 * u), width: 24 * u, height: 3 * u),
        Radius.circular(1.5 * u),
      ),
      Paint()..color = timberDeep,
    );
    canvas.drawLine(
      Offset(94 * u, 63 * u),
      Offset(94 * u, 51 * u),
      Paint()
        ..color = RT.ink
        ..strokeWidth = 1.6 * u,
    );
    canvas.drawPath(
      Path()
        ..moveTo(94 * u, 51 * u)
        ..lineTo(100 * u, 54.2 * u)
        ..lineTo(94 * u, 57.4 * u)
        ..close(),
      Paint()..color = RT.red,
    );

    // The cannon: the one shape that says ARTILLERY rather than FISHING.
    // A wheel on the deck and a barrel angled up along the shot's first
    // dotted step. Drawn before the body so the captain stands behind it,
    // the way the battle's build screen seats a weapon.
    final gunC = Offset(57 * u, 66 * u);
    canvas.save();
    canvas.translate(57 * u, 63 * u);
    canvas.rotate(-38 * pi / 180);
    final barrel = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, -3.2 * u, 16 * u, 6.4 * u),
      Radius.circular(3.2 * u),
    );
    canvas.drawRRect(barrel, Paint()..color = const Color(0xFF3D5866));
    canvas.drawRRect(
      barrel,
      Paint()
        ..color = RT.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 * u,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(13 * u, -4.4 * u, 3 * u, 8.8 * u),
        Radius.circular(1.5 * u),
      ),
      Paint()..color = RT.ink,
    );
    canvas.restore();
    canvas.drawCircle(gunC, 5.5 * u, Paint()..color = timberDark);
    canvas.drawCircle(
      gunC,
      5.5 * u,
      Paint()
        ..color = RT.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 * u,
    );
    canvas.drawCircle(gunC, 1.7 * u, Paint()..color = RT.cream);

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
          center: Offset(34 * u, deckY - 3 * u), width: 40 * u, height: 20 * u),
      topLeft: Radius.circular(10 * u),
      topRight: Radius.circular(10 * u),
    );
    canvas.drawRRect(shoulders, Paint()..color = ch.outfit);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(34 * u, deckY - 4 * u),
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
    final headC = Offset(34 * u, 43 * u);
    final headR = 20.0 * u;
    canvas.drawCircle(headC, headR, Paint()..color = ch.skin);
    canvas.drawArc(
      Rect.fromCircle(center: headC, radius: headR),
      0.35,
      pi * 0.7,
      false,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.07)
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
    // hat swallowed it whole.
    //
    // Dots on a parabola rather than a drawn line, because that is the
    // game's own trajectory preview and because a continuous stroke from
    // the muzzle up to the burst read unmistakably as a fishing rod. A
    // dotted arc that rises AND falls cannot be read as anything but a
    // lobbed shot, which is the entire game in one mark.
    Offset shotAt(double t) {
      // A real parabola, launched up and to the right off the muzzle, and
      // tuned so its last step lands on the enemy's deck.
      const x0 = 69.0, y0 = 52.0, vx = 17.5, vy = -48.0, g = 110.0;
      return Offset((x0 + vx * t) * u, (y0 + vy * t + 0.5 * g * t * t) * u);
    }

    for (int i = 1; i <= 5; i++) {
      final p = shotAt(i / 6);
      final r = (1.7 + i * 0.45) * u;
      canvas.drawCircle(p, r + 1.5 * u, Paint()..color = RT.ink);
      canvas.drawCircle(p, r, Paint()..color = RT.cream);
    }

    // The impact: the game's own comic starburst, the same jagged star the
    // menus put behind their logo, in the palette the battle explosions
    // wear — yellow rays, orange core, and an ink outline so it can never
    // be mistaken for a sun. A smooth glowing ball here once read as
    // sunset; a jagged outlined burst reads as something that went boom.
    final burstC = shotAt(1);
    final burst = Path();
    final rnd = Random(7);
    const rays = 12;
    for (int i = 0; i < rays * 2; i++) {
      final angle = (i / (rays * 2)) * 2 * pi - pi / 2;
      final r = (i.isEven ? 12.0 : 5.8) * u * (0.9 + rnd.nextDouble() * 0.2);
      final p = burstC + Offset(cos(angle) * r, sin(angle) * r);
      if (i == 0) {
        burst.moveTo(p.dx, p.dy);
      } else {
        burst.lineTo(p.dx, p.dy);
      }
    }
    burst.close();
    canvas.drawPath(burst, Paint()..color = RT.yellow);
    canvas.drawPath(
      burst,
      Paint()
        ..color = RT.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * u
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(burstC, 5.4 * u, Paint()..color = RT.orange);
    canvas.drawCircle(burstC + Offset(-1.6 * u, -1.6 * u), 1.5 * u,
        Paint()..color = Colors.white.withValues(alpha: 0.75));
  }
}
