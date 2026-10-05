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
/// one diagonal read: the pirate — black tricorn, black beard, broad grin —
/// on a lashed timber raft at the lower left, cutlass raised, his mortar's
/// iron shot arcing to the right where it lands in a burst on the Rival
/// Captain's raft at the far horizon. Read at 48px it is a face, an iron
/// ball and an explosion. Read at 192px the tricorn, the beard, the grin, the cutlass, the
/// mortar, the planks and the duel across the water are all there.
/// ---------------------------------------------------------------------------
class AppIcon {
  AppIcon._();

  /// The hero the icon wears: the playable Pirate.
  ///
  /// A hat is not decoration here, it is the silhouette. The default player
  /// captain has [HeadGear.none], and a bare head at 48px is a circle with
  /// two dots — indistinguishable from every emoji-faced app on the home
  /// screen. The Drifter's straw hat used to be the best silhouette the
  /// roster had for this: warm against the sky, and it said castaway on a
  /// raft rather than generic.
  ///
  /// It does not any more. The pull of a duel scene is a PIRATE — and the
  /// roster has a playable one: black tricorn, full beard, plum coat with
  /// red trim. The tricorn was tried first and rendered as a flat dark bar
  /// across the head at tile size, back when it sat on a small head in flat
  /// light. On an oversized head, rim-lit against a sunset, it reads as a
  /// wide black hat with a gold-trimmed crown — the strongest silhouette in
  /// the cast.
  ///
  /// It also has to be a character the player can actually BE. The first
  /// pick was the Log Raider, whose bandana suited the tile but who is
  /// enemy-only — the icon would have advertised somebody you only ever
  /// shoot at.
  static const CrewLook hero = CrewLook.pirate;

  /// Kept so the game-customisation link stays readable: the icon wears a
  /// member of the cast, drawn from the same painters.
  static const CrewLook look = hero;

  /// The captain on the far raft: the Rival Captain himself, not a
  /// silhouette — tricorn, eyepatch and gold trim, wheeling away from the
  /// incoming shot with his arms up. Enemy-only and proud of it: he is the
  /// reason the tile says DUEL.
  static const CrewLook rival = CrewLook.captain;

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
    // runs from the cutlass tip (top) and the tricorn's port corner (left)
    // out to the burst on the enemy raft (right) and the hero deck
    // (bottom), and it sits low and left, weighted toward the pirate.
    //
    // Scaling the square about its middle, as this first did, therefore
    // left the art off-centre and pushed the shot out past the circle
    // Android guarantees to show. Centring the CONTENT and sizing it to
    // that circle is what actually keeps all of it.
    const box = Rect.fromLTRB(2, 6, 98, 88);
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
  /// that has a background layer of its own underneath. Everything else —
  /// both crews, both hulls and the mortar — is painted in this pass, so
  /// the adaptive tile is the whole duel and not the hero on blank teal.
  static void _scene(Canvas canvas, double size, {bool transparent = false}) {
    final u = size / 100.0; // one unit = 1% of the icon
    final ch = Cast.of(hero);
    final foe = Cast.of(rival);

    // Common paints shared by the whole scene.
    final inkLine = Paint()
      ..color = RT.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2 * u
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    // Grounds both hulls: white collars where timber meets water, painted
    // with the hulls so both icon modes keep them.
    final foam = Paint()..color = Colors.white.withValues(alpha: 0.8);

    // Sea level, and the horizon that separates the two colour blocks. High
    // enough that the water is a band rather than a backdrop — the crews
    // have to own the middle.
    const seaY = 68.0;

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

      // A pair of thin clouds off to the sides, clear of the hero's
      // tricorn — the plain disc behind the head stays plain, and the
      // sky stops being a flat gradient with nothing in it.
      void cloud(Offset at, double w) {
        final h = w * 0.30;
        final r = Rect.fromCenter(center: at, width: w, height: h);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, Radius.circular(h * 0.5)),
          Paint()..color = Colors.white.withValues(alpha: 0.75),
        );
        canvas.drawCircle(at + Offset(-w * 0.18, -h * 0.22), h * 0.42,
            Paint()..color = Colors.white.withValues(alpha: 0.75));
        canvas.drawCircle(at + Offset(w * 0.16, -h * 0.26), h * 0.48,
            Paint()..color = Colors.white.withValues(alpha: 0.75));
      }

      cloud(Offset(80 * u, 17 * u), 20 * u);
      cloud(Offset(58 * u, 28 * u), 13 * u);
      // One small cream gull for scale, high above the shot's arc —
      // always a bird, never a brushstroke the burst could be confused for.
      final gull = Paint()
        ..color = RT.ink.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * u
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCenter(
            center: Offset(60 * u, 10 * u), width: 7 * u, height: 3.4 * u),
        pi * 1.1,
        pi * 0.8,
        false,
        gull,
      );
      canvas.drawArc(
        Rect.fromCenter(
            center: Offset(66 * u, 10 * u), width: 7 * u, height: 3.4 * u),
        pi * 1.1,
        pi * 0.8,
        false,
        gull,
      );

      // Sun glitter on the water: a few short cream dashes between the
      // hulls, where no face or timber competes with them.
      final glitter = Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..strokeWidth = 1.6 * u
        ..strokeCap = StrokeCap.round;
      for (final g in [Offset(52, 74), Offset(60, 79), Offset(69, 75)]) {
        canvas.drawLine(
          Offset((g.dx - 3) * u, g.dy * u),
          Offset((g.dx + 3) * u, g.dy * u),
          glitter,
        );
      }
      // The reason there is no sun disc: two attempts were made and both
      // made the icon worse — centred and warm it sat behind the head at
      // almost exactly skin tone, and up and right it landed on the tip of
      // the cutlass and turned a pirate into Father Christmas.

      // The sea stays two flat bands with a scalloped crest — flat because
      // banding is what survives downscaling. The hulls get their foam
      // collars where they are drawn, so both icon modes ground them.
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

    // The hero raft: the game's log hull, not a slab — four lashed logs
    // with rounded ends, a darker waterline strake, and lashings that read
    // as bands rather than seams. Wide under the crew and pushed left of
    // centre: the right half of the tile belongs to the shot and where it
    // lands, and the diagonal from pirate to burst is the composition.
    //
    // Positions shared by everything standing on this deck.
    final deckY = 74.0 * u;
    const deckCx = 31.0;
    const timber = Color(0xFF8A5A32);
    const timberDark = Color(0xFF6B4525);
    const timberDeep = Color(0xFF4A2E14);
    const rope = Color(0xFFD9C79A);
    final hullL = 9.0 * u;
    final hullR = 53.0 * u;
    final hullTop = deckY - 4 * u;
    final hullBot = deckY + 6 * u;
    // Four logs: rounded barrel ends sticking out past the lashings.
    for (int i = 0; i < 4; i++) {
      final y = hullTop + (hullBot - hullTop) * (i + 0.5) / 4;
      final h = (hullBot - hullTop) / 4 + 0.6 * u;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset((deckCx + (i.isEven ? 0.7 : -0.7)) * u, y),
              width: (hullR - hullL) * u,
              height: h),
          Radius.circular(h * 0.5),
        ),
        Paint()..color = i.isEven ? timber : timberDark,
      );
    }
    // Waterline strake along the lee side.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(hullL, hullBot - 2.6 * u, hullR, hullBot),
        Radius.circular(1.3 * u),
      ),
      Paint()..color = timberDeep,
    );
    canvas.drawLine(
      Offset(hullL, hullBot - 1.1 * u),
      Offset(hullR, hullBot - 1.1 * u),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 1.1 * u,
    );
    // Three rope lashings binding the logs — pale bands, dark edge lines.
    for (final lx in [15.0, 31.0, 47.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(lx * u, (hullTop + hullBot) / 2),
              width: 3.4 * u,
              height: (hullBot - hullTop) + 1.2 * u),
          Radius.circular(1.4 * u),
        ),
        Paint()..color = rope,
      );
      canvas.drawLine(
        Offset((lx - 1.7) * u, hullTop - 0.4 * u),
        Offset((lx - 1.7) * u, hullBot + 0.4 * u),
        Paint()
          ..color = timberDeep
          ..strokeWidth = 0.9 * u,
      );
      canvas.drawLine(
        Offset((lx + 1.7) * u, hullTop - 0.4 * u),
        Offset((lx + 1.7) * u, hullBot + 0.4 * u),
        Paint()
          ..color = timberDeep
          ..strokeWidth = 0.9 * u,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(hullL, hullTop, hullR, hullBot),
        Radius.circular(3.2 * u),
      ),
      inkLine,
    );
    // Foam collar where the hero hull cuts the water.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(deckCx * u, hullBot + 1.2 * u),
            width: (hullR - hullL) * 0.94 * u,
            height: 2.6 * u),
        Radius.circular(1.3 * u),
      ),
      foam,
    );

    // A pennant on the hero's own stern — the player's red, answering the
    // rival's across the water. Short, so it stays a colour accent rather
    // than a second flag competing with the duel.
    canvas.drawLine(
      Offset(12 * u, 70 * u),
      Offset(12 * u, 58 * u),
      Paint()
        ..color = RT.ink
        ..strokeWidth = 1.6 * u,
    );
    canvas.drawPath(
      Path()
        ..moveTo(12 * u, 58 * u)
        ..lineTo(19 * u, 60.6 * u)
        ..lineTo(12 * u, 63.2 * u)
        ..close(),
      Paint()..color = RT.red,
    );

    // The mortar: the game's own deck mortar, not a cannon — a squat
    // iron bell on a timber bed with iron bands, two wheels and a wedge,
    // mouth open high to the sky it fires into. It sits forward of the
    // pirate, aimed along the shot's first step.
    final muzzle = Offset(47 * u, 52 * u);
    final mortarBase = Offset(41 * u, 70 * u);
    // Timber bed under the bell.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(39 * u, 69 * u), width: 13 * u, height: 5 * u),
        Radius.circular(1.6 * u),
      ),
      Paint()..color = timberDark,
    );
    // The bell: a tapered tube from breech low-left to mouth high-right.
    final bellAxis = muzzle - mortarBase;
    final bellLen = bellAxis.distance;
    final bellDir = bellAxis / bellLen;
    final bellSide = Offset(-bellDir.dy, bellDir.dx);
    final bell = Path()
      ..moveTo(mortarBase.dx + bellSide.dx * 4.6 * u,
          mortarBase.dy + bellSide.dy * 4.6 * u)
      ..lineTo(muzzle.dx + bellSide.dx * 2.6 * u,
          muzzle.dy + bellSide.dy * 2.6 * u)
      ..arcToPoint(
        Offset(muzzle.dx - bellSide.dx * 2.6 * u,
            muzzle.dy - bellSide.dy * 2.6 * u),
        radius: Radius.circular(2.6 * u),
      )
      ..lineTo(mortarBase.dx - bellSide.dx * 4.6 * u,
          mortarBase.dy - bellSide.dy * 4.6 * u)
      ..arcToPoint(
        Offset(mortarBase.dx + bellSide.dx * 4.6 * u,
            mortarBase.dy + bellSide.dy * 4.6 * u),
        radius: Radius.circular(4.4 * u),
      )
      ..close();
    canvas.drawPath(bell, Paint()..color = const Color(0xFF3D5866));
    canvas.drawPath(bell, inkLine);
    // Iron bands ringing the bell.
    for (final t in [0.3, 0.62]) {
      final bc = mortarBase + bellAxis * t;
      final hw = (4.6 - 2.0 * t) * u;
      canvas.drawLine(
        bc + bellSide * hw,
        bc - bellSide * hw,
        Paint()
          ..color = const Color(0xFF22333D)
          ..strokeWidth = 1.7 * u,
      );
    }
    // The open mouth: a dark ellipse at the muzzle with a lit rim.
    canvas.drawCircle(muzzle, 2.7 * u, Paint()..color = const Color(0xFF141E24));
    canvas.drawCircle(
        muzzle,
        2.7 * u,
        Paint()
          ..color = const Color(0xFF9FB6C4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1 * u);
    // Wedge and wheels under the bed.
    canvas.drawPath(
      Path()
        ..moveTo(34 * u, 71.5 * u)
        ..lineTo(42 * u, 71.5 * u)
        ..lineTo(34 * u, 75 * u)
        ..close(),
      Paint()..color = timber,
    );
    for (final wx in [35.0, 44.0]) {
      canvas.drawCircle(
          Offset(wx * u, 73.5 * u), 3.1 * u, Paint()..color = timberDeep);
      canvas.drawCircle(Offset(wx * u, 73.5 * u), 3.1 * u, inkLine);
      canvas.drawCircle(
          Offset(wx * u, 73.5 * u), 0.9 * u, Paint()..color = RT.cream);
    }
    // Powder smoke curling out of the mouth — the shot just left.
    final smoke = Paint()..color = Colors.white.withValues(alpha: 0.85);
    canvas.drawCircle(muzzle + Offset(2.4 * u, -2.6 * u), 2.6 * u, smoke);
    canvas.drawCircle(muzzle + Offset(4.8 * u, -5.2 * u), 3.4 * u, smoke);
    canvas.drawCircle(
        muzzle + Offset(8.0 * u, -8.0 * u),
        4.2 * u,
        Paint()..color = Colors.white.withValues(alpha: 0.45));

    // The rival raft: smaller, darker, lower in the water, flying the
    // enemy red pennant from a sternpost. Without it the icon is a boat
    // ride; with it, the tile says DUEL.
    final foeDeckY = 66.0 * u;
    const foeCx = 80.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(foeCx * u, foeDeckY + 2 * u),
            width: 26 * u,
            height: 7 * u),
        Radius.circular(3 * u),
      ),
      Paint()..color = timberDark,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(foeCx * u, foeDeckY + 4.2 * u),
            width: 26 * u,
            height: 2.6 * u),
        Radius.circular(1.3 * u),
      ),
      Paint()..color = timberDeep,
    );
    for (final dx in [-7.0, 0.0, 7.0]) {
      canvas.drawLine(
        Offset((foeCx + dx) * u, foeDeckY - 1.2 * u),
        Offset((foeCx + dx) * u, foeDeckY + 3.4 * u),
        Paint()
          ..color = timberDeep
          ..strokeWidth = 0.9 * u,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(foeCx * u, foeDeckY + 2 * u),
            width: 26 * u,
            height: 7 * u),
        Radius.circular(3 * u),
      ),
      inkLine,
    );
    // Foam collar where the rival hull cuts the water.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(foeCx * u, foeDeckY + 6 * u),
            width: 24 * u,
            height: 2.2 * u),
        Radius.circular(1.1 * u),
      ),
      foam,
    );
    // Sternpost and red pennant, flying to port — clear of the blast that
    // lands on the starboard end of his deck, and clear of the captain's
    // hat now that he stands on it.
    canvas.drawLine(
      Offset(67.5 * u, 65 * u),
      Offset(67.5 * u, 53 * u),
      Paint()
        ..color = RT.ink
        ..strokeWidth = 1.7 * u
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      Path()
        ..moveTo(67.5 * u, 53 * u)
        ..lineTo(61 * u, 56 * u)
        ..lineTo(67.5 * u, 59 * u)
        ..close(),
      Paint()..color = RT.red,
    );

    // The Rival Captain himself: the enemy-only captain from the roster —
    // navy coat with gold trim, eyepatch, tricorn — legs planted on his
    // deck, wheeling away from the incoming shot with both arms thrown
    // up. He is the reason the tile says DUEL.
    final foeHeadC = Offset(78 * u, 51 * u);
    final foeHeadR = 7.5 * u;

    // Legs: sea boots astride the deck, dark.
    for (final lx in [74.5, 83.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(lx * u, foeDeckY - 2.5 * u),
              width: 3.4 * u,
              height: 6 * u),
          Radius.circular(1.4 * u),
        ),
        Paint()..color = const Color(0xFF3B2A1C),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(lx * u, foeDeckY - 2.5 * u),
              width: 3.4 * u,
              height: 6 * u),
          Radius.circular(1.4 * u),
        ),
        inkLine,
      );
    }
    // Navy coat with a gold-trim bar at the collar.
    final foeCoat = Path()
      ..moveTo(72 * u, foeDeckY - 1 * u)
      ..lineTo(73.5 * u, foeDeckY - 10 * u)
      ..quadraticBezierTo(79 * u, foeDeckY - 13 * u, 84 * u, foeDeckY - 10 * u)
      ..lineTo(85.5 * u, foeDeckY - 1 * u)
      ..quadraticBezierTo(79 * u, foeDeckY + 1 * u, 72 * u, foeDeckY - 1 * u)
      ..close();
    canvas.drawPath(foeCoat, Paint()..color = foe.outfit);
    canvas.drawPath(foeCoat, inkLine);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(78.8 * u, foeDeckY - 9.5 * u),
            width: 9 * u,
            height: 2.2 * u),
        Radius.circular(1.1 * u),
      ),
      Paint()..color = foe.accent,
    );
    // Both arms thrown up — the OH-NO that sells the hit.
    void foeArm(Offset fist) {
      final shoulder = Offset(78.8 * u, foeDeckY - 8.5 * u);
      canvas.drawLine(
        shoulder,
        fist,
        Paint()
          ..color = RT.ink
          ..strokeWidth = 4.4 * u
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        shoulder,
        fist,
        Paint()
          ..color = foe.outfit
          ..strokeWidth = 3.0 * u
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(fist, 1.9 * u, Paint()..color = foe.skin);
      canvas.drawCircle(fist, 1.9 * u, inkLine);
    }

    foeArm(Offset(70.5 * u, 47 * u));
    foeArm(Offset(88 * u, 47.5 * u));

    // Head: umber skin, wide shocked eyes and an open yell, drawn before
    // the shared painter adds his eyepatch and tricorn.
    canvas.drawCircle(foeHeadC, foeHeadR, Paint()..color = foe.skin);
    canvas.drawCircle(foeHeadC, foeHeadR, inkLine);
    // One wide shocked eye — the shared painter covers the other with his
    // eyepatch.
    canvas.drawCircle(
        foeHeadC + Offset(-foeHeadR * 0.34, -foeHeadR * 0.08),
        foeHeadR * 0.24,
        Paint()..color = Colors.white);
    canvas.drawCircle(
        foeHeadC + Offset(-foeHeadR * 0.34, -foeHeadR * 0.08),
        foeHeadR * 0.12,
        Paint()..color = RT.ink);
    canvas.drawOval(
      Rect.fromCenter(
          center: foeHeadC + Offset(0, foeHeadR * 0.42),
          width: foeHeadR * 0.72,
          height: foeHeadR * 0.9),
      Paint()..color = RT.ink,
    );
    CharacterArt.headgear(canvas, rival, foeHeadC, foeHeadR, -1);

    // The hero: the playable Pirate, full figure — legs planted on the
    // deck, plum coat with red trim, bronze skin, cutlass raised high in
    // the aft fist and the forward fist pumping the air. Drawn from the
    // same [CharacterDef] the battle uses: outfit and accent come from the
    // roster, the tricorn and beard from the shared [CharacterArt] painter.
    // Outlined, like every chunky element in the game's own UI: at icon
    // sizes an ink keyline is what separates the body from the water
    // behind it, and without one the whole lower half turned to soup.
    final line = Paint()
      ..color = RT.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4 * u
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    // Legs: sea boots astride the deck, dark brown.
    const boot = Color(0xFF3B2A1C);
    for (final lx in [24.0, 38.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(lx * u, deckY - 5 * u),
              width: 6.4 * u,
              height: 12 * u),
          Radius.circular(2.6 * u),
        ),
        Paint()..color = boot,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(lx * u, deckY - 5 * u),
              width: 6.4 * u,
              height: 12 * u),
          Radius.circular(2.6 * u),
        ),
        line,
      );
    }

    // Coat: plum, flaring to the knees, with a red-trim collar and a
    // gold baldric slanting to the hip.
    final coat = Path()
      ..moveTo(22 * u, deckY - 1 * u)
      ..lineTo(24 * u, deckY - 21 * u)
      ..quadraticBezierTo(31 * u, deckY - 26 * u, 38 * u, deckY - 21 * u)
      ..lineTo(40 * u, deckY - 1 * u)
      ..quadraticBezierTo(31 * u, deckY + 2 * u, 22 * u, deckY - 1 * u)
      ..close();
    canvas.drawPath(coat, Paint()..color = ch.outfit);
    canvas.drawPath(coat, line);
    // Red-trim collar V at the throat, sitting just below the chin so the
    // beard keeps it — the head overlaps the coat's top, and anything
    // higher ends up behind the jaw.
    canvas.drawPath(
      Path()
        ..moveTo(26 * u, deckY - 14 * u)
        ..lineTo(31 * u, deckY - 7 * u)
        ..lineTo(36 * u, deckY - 14 * u)
        ..lineTo(36 * u, deckY - 11 * u)
        ..lineTo(31 * u, deckY - 4.5 * u)
        ..lineTo(26 * u, deckY - 11 * u)
        ..close(),
      Paint()..color = ch.accent,
    );
    // Gold baldric slanting across the visible chest.
    canvas.drawLine(
      Offset(24 * u, deckY - 14 * u),
      Offset(38 * u, deckY - 5 * u),
      Paint()
        ..color = RT.yellow
        ..strokeWidth = 2.4 * u,
    );

    // Arms: plum sleeves, bronze fists. The aft arm rises beside the head
    // to the cutlass; the forward arm pumps skyward beside the cheek —
    // triumph, not aiming, so the shot's arc stays the only line leaving
    // the raft. Both are drawn as ink-outlined sleeves with the fists on
    // top; the aft one goes behind the head, the forward one in front of
    // it, so neither ever covers the eyes or the grin.
    void sleeve(Offset shoulder, Offset fist) {
      canvas.drawLine(
        shoulder,
        fist,
        Paint()
          ..color = RT.ink
          ..strokeWidth = 7.4 * u
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        shoulder,
        fist,
        Paint()
          ..color = ch.outfit
          ..strokeWidth = 5.2 * u
          ..strokeCap = StrokeCap.round,
      );
    }

    void fist(Offset at) {
      canvas.drawCircle(at, 3.1 * u, Paint()..color = ch.skin);
      canvas.drawCircle(at, 3.1 * u, line);
    }

    final fistAft = Offset(12 * u, 30 * u);
    sleeve(Offset(24 * u, deckY - 14 * u), fistAft);
    fist(fistAft);
    // The forward arm rises BESIDE the head, not behind it: the cheek
    // needs empty sky around it, so shoulder and fist both move starboard
    // of the jaw and the sleeve passes clear of the tricorn's brim.
    final fistFore = Offset(52 * u, 27 * u);
    sleeve(Offset(39 * u, deckY - 14 * u), fistFore);
    fist(fistFore);

    // The cutlass: steel blade angled up to port, brass guard, dark grip —
    // the blade tip is the highest mark in the tile. It rises just off the
    // tricorn's port corner: the mid-blade passes behind the brim (the head
    // is painted after it) and the tip emerges into clear sky above it.
    final cutTip = Offset(10 * u, 11 * u);
    final cutBase = fistAft + Offset(0.6 * u, -1.4 * u);
    final cutSide = Offset(1.5 * u, 0.35 * u);
    final blade = Path()
      ..moveTo(cutBase.dx + cutSide.dx, cutBase.dy + cutSide.dy)
      ..lineTo(cutTip.dx + cutSide.dx * 0.5, cutTip.dy + cutSide.dy * 0.5)
      ..lineTo(cutTip.dx - cutSide.dx * 0.5, cutTip.dy - cutSide.dy * 0.5)
      ..lineTo(cutBase.dx - cutSide.dx, cutBase.dy - cutSide.dy)
      ..close();
    canvas.drawPath(blade, Paint()..color = const Color(0xFFE8ECF2));
    canvas.drawPath(blade, line);
    canvas.drawLine(
      cutBase + Offset(-1.2 * u, 1.6 * u),
      cutTip + Offset(-0.6 * u, 0.8 * u),
      Paint()
        ..color = const Color(0xFF9FB6C4)
        ..strokeWidth = 0.9 * u,
    );
    // Guard and grip across the fist.
    canvas.drawLine(
      fistAft + Offset(-2.8 * u, 0.4 * u),
      fistAft + Offset(2.8 * u, -0.8 * u),
      Paint()
        ..color = RT.yellow
        ..strokeWidth = 2.0 * u
        ..strokeCap = StrokeCap.round,
    );

    // The head: oversized, a cartoon proportion, and the one shape that has
    // to survive being 20 pixels across. Set left of centre to open up the
    // top-right corner for the shot. It sits HIGH on the coat — the chin
    // clears the collar trim entirely, so the red V reads instead of
    // vanishing under the beard.
    final headC = Offset(31 * u, 38 * u);
    final headR = 17.0 * u;
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

    // The shot, launched from the mortar's mouth and landing on the far
    // end of the rival's deck — clear of both heads. It is the only mark
    // that says what the game IS rather than who is in it, so it goes on
    // top of everything: an earlier version drew it first and the head
    // and the hat swallowed it whole.
    //
    // Dots on a parabola rather than a drawn line, because that is the
    // game's own trajectory preview and because a continuous stroke from
    // the muzzle up to the burst read unmistakably as a fishing rod. A
    // dotted arc that rises AND falls cannot be read as anything but a
    // lobbed shot, which is the entire game in one mark.
    Offset shotAt(double t) {
      // A real parabola, launched up and to the right off the muzzle,
      // apexing above the rival's upflung fist and coming down on the open
      // port end of his deck — beside him, not through him.
      const x0 = 47.0, y0 = 50.0, vx = 24.0, vy = -44.0, g = 74.0;
      return Offset((x0 + vx * t) * u, (y0 + vy * t + 0.5 * g * t * t) * u);
    }

    for (int i = 1; i <= 5; i++) {
      final p = shotAt(i / 6);
      final r = (1.7 + i * 0.45) * u;
      canvas.drawCircle(p, r + 1.4 * u, Paint()..color = RT.ink);
      canvas.drawCircle(p, r, Paint()..color = RT.cream);
    }
    // The iron ball itself, larger than the trail dots and rim-lit —
    // drawn at t=0.8 so it stops well short of the rival's head.
    final ballC = shotAt(0.8);
    canvas.drawCircle(ballC, 4.6 * u, Paint()..color = RT.ink);
    canvas.drawCircle(ballC, 3.2 * u, Paint()..color = const Color(0xFF3D5866));
    canvas.drawCircle(
        ballC + Offset(-1 * u, -1 * u), 1 * u,
        Paint()..color = Colors.white.withValues(alpha: 0.8));

    // The impact: the game's own comic starburst, the same jagged star the
    // menus put behind their logo, in the palette the battle explosions
    // wear — yellow rays, orange core, and an ink outline so it can never
    // be mistaken for a sun. A smooth glowing ball here once read as
    // sunset; a jagged outlined burst reads as something that went boom.
    // It lands on the open port end of the rival's deck, clear of his
    // head and his upflung fist — he recoils FROM it, not inside it.
    final burstC = shotAt(1);
    final burst = Path();
    final rnd = Random(7);
    const rays = 12;
    for (int i = 0; i < rays * 2; i++) {
      final angle = (i / (rays * 2)) * 2 * pi - pi / 2;
      final r = (i.isEven ? 8.0 : 4.0) * u * (0.9 + rnd.nextDouble() * 0.2);
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
    // Splinters and smoke knocked off the rival deck — the hit lands.
    final debris = Paint()
      ..color = timberDark
      ..strokeWidth = 1.7 * u
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(burstC + Offset(-7 * u, -8 * u),
        burstC + Offset(-9.5 * u, -12 * u), debris);
    canvas.drawLine(burstC + Offset(6 * u, -8.5 * u),
        burstC + Offset(8.5 * u, -12.5 * u), debris);
    canvas.drawLine(burstC + Offset(0 * u, -9.5 * u),
        burstC + Offset(0.5 * u, -14 * u), debris);
    canvas.drawCircle(
        burstC + Offset(4 * u, -11 * u),
        2.2 * u,
        Paint()..color = Colors.white.withValues(alpha: 0.7));
    canvas.drawCircle(
        burstC + Offset(-5 * u, -12 * u),
        2.8 * u,
        Paint()..color = Colors.white.withValues(alpha: 0.55));
  }
}
