import 'dart:math';

import 'package:flutter/material.dart';

import 'characters.dart';

/// ---------------------------------------------------------------------------
/// Character art.
///
/// The hat and face-marking painters, split out of the scene renderer so the
/// customisation screen can draw the exact same character the battle does.
/// A roster picker that drew its own approximation of a character would drift
/// from the real thing the first time a hat was tweaked — and the whole point
/// of a picker is that what you choose is what you get.
///
/// Everything here is a pure function of a [CharacterDef] and a head circle
/// (centre + radius + facing), so it composes into any canvas at any scale.
/// ---------------------------------------------------------------------------
class CharacterArt {
  CharacterArt._();

  /// Hat, hood and helmet, drawn from [CharacterDef.gear] rather than from
  /// who the character is — so the roster can grow without this switch doing.
  ///
  /// [dir] is the facing, so brims and visors point the way the body does.
  static void headgear(
      Canvas canvas, CrewLook look, Offset headC, double r, double dir) {
    final ch = Cast.of(look);
    faceMark(canvas, ch, headC, r, dir);
    final band = ch.accent;
    final cloth = ch.outfit;
    final dark = Color.lerp(cloth, Colors.black, 0.35)!;

    switch (ch.gear) {
      case HeadGear.none:
        break;

      case HeadGear.bandana:
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 0.72),
                width: r * 2.1,
                height: r * 0.62),
            topLeft: Radius.circular(r * 0.6),
            topRight: Radius.circular(r * 0.6),
          ),
          Paint()..color = band,
        );
        // Knot tail trailing behind the head.
        canvas.drawPath(
          Path()
            ..moveTo(headC.dx - dir * r * 0.95, headC.dy - r * 0.72)
            ..lineTo(headC.dx - dir * r * 1.5, headC.dy - r * 0.35)
            ..lineTo(headC.dx - dir * r * 0.95, headC.dy - r * 0.3)
            ..close(),
          Paint()..color = Color.lerp(band, Colors.black, 0.18)!,
        );
        break;

      case HeadGear.tricorn:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 0.86),
                width: r * 2.7,
                height: r * 0.62),
            Radius.circular(r * 0.3),
          ),
          Paint()..color = const Color(0xFF1D1D20),
        );
        // Upturned front corner and a band, so it reads as a tricorn rather
        // than a slab.
        canvas.drawPath(
          Path()
            ..moveTo(headC.dx + dir * r * 1.35, headC.dy - r * 0.86)
            ..lineTo(headC.dx + dir * r * 1.05, headC.dy - r * 1.5)
            ..lineTo(headC.dx + dir * r * 0.55, headC.dy - r * 0.95)
            ..close(),
          Paint()..color = const Color(0xFF2A2A30),
        );
        canvas.drawLine(
          Offset(headC.dx - r * 1.2, headC.dy - r * 0.86),
          Offset(headC.dx + r * 1.2, headC.dy - r * 0.86),
          Paint()
            ..color = band
            ..strokeWidth = r * 0.16,
        );
        break;

      case HeadGear.strawHat:
        canvas.drawOval(
          Rect.fromCenter(
              center: headC + Offset(0, -r * 0.62),
              width: r * 3.1,
              height: r * 0.5),
          Paint()..color = const Color(0xFFE0C989),
        );
        canvas.drawOval(
          Rect.fromCenter(
              center: headC + Offset(0, -r * 0.95),
              width: r * 1.5,
              height: r * 0.85),
          Paint()..color = const Color(0xFFD4B972),
        );
        canvas.drawLine(
          Offset(headC.dx - r * 0.72, headC.dy - r * 0.78),
          Offset(headC.dx + r * 0.72, headC.dy - r * 0.78),
          Paint()
            ..color = band
            ..strokeWidth = r * 0.18,
        );
        break;

      case HeadGear.ushanka:
        // Fur cap with the ear flaps down.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 0.78),
                width: r * 2.3,
                height: r * 0.95),
            Radius.circular(r * 0.45),
          ),
          Paint()..color = cloth,
        );
        for (final s in [-1.0, 1.0]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: headC + Offset(s * r * 0.92, -r * 0.1),
                  width: r * 0.55,
                  height: r * 1.0),
              Radius.circular(r * 0.28),
            ),
            Paint()..color = band,
          );
        }
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 1.05),
                width: r * 2.35,
                height: r * 0.45),
            Radius.circular(r * 0.22),
          ),
          Paint()..color = band,
        );
        break;

      case HeadGear.hood:
        // A shell behind and over the head, open at the face so the
        // expression still reads.
        canvas.drawPath(
          Path()
            ..moveTo(headC.dx + dir * r * 0.85, headC.dy - r * 0.55)
            ..quadraticBezierTo(headC.dx, headC.dy - r * 1.85,
                headC.dx - dir * r * 1.15, headC.dy - r * 0.2)
            ..quadraticBezierTo(headC.dx - dir * r * 1.3, headC.dy + r * 0.8,
                headC.dx - dir * r * 0.5, headC.dy + r * 0.95)
            ..lineTo(headC.dx - dir * r * 0.55, headC.dy - r * 0.2)
            ..close(),
          Paint()..color = cloth,
        );
        canvas.drawPath(
          Path()
            ..moveTo(headC.dx + dir * r * 0.85, headC.dy - r * 0.55)
            ..quadraticBezierTo(headC.dx, headC.dy - r * 1.6,
                headC.dx - dir * r * 0.75, headC.dy - r * 0.35),
          Paint()
            ..color = band
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.2,
        );
        break;

      case HeadGear.turban:
        for (int i = 0; i < 3; i++) {
          canvas.drawOval(
            Rect.fromCenter(
              center: headC + Offset(dir * i * r * 0.06, -r * (0.68 + i * 0.26)),
              width: r * (2.25 - i * 0.34),
              height: r * 0.52,
            ),
            Paint()..color = i.isEven ? cloth : Color.lerp(cloth, band, 0.4)!,
          );
        }
        break;

      case HeadGear.wideBrim:
        canvas.drawOval(
          Rect.fromCenter(
              center: headC + Offset(dir * r * 0.15, -r * 0.6),
              width: r * 3.4,
              height: r * 0.42),
          Paint()..color = dark,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 0.98),
                width: r * 1.35,
                height: r * 0.8),
            Radius.circular(r * 0.2),
          ),
          Paint()..color = dark,
        );
        break;

      case HeadGear.hardHat:
        canvas.drawPath(
          Path()
            ..addArc(
              Rect.fromCenter(
                  center: headC + Offset(0, -r * 0.55),
                  width: r * 2.2,
                  height: r * 1.9),
              pi,
              pi,
            )
            ..close(),
          Paint()..color = band,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(dir * r * 0.25, -r * 0.55),
                width: r * 2.8,
                height: r * 0.3),
            Radius.circular(r * 0.15),
          ),
          Paint()..color = band,
        );
        // Centre ridge.
        canvas.drawLine(
          Offset(headC.dx, headC.dy - r * 1.45),
          Offset(headC.dx, headC.dy - r * 0.6),
          Paint()
            ..color = Color.lerp(band, Colors.black, 0.25)!
            ..strokeWidth = r * 0.16,
        );
        break;

      case HeadGear.visor:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(dir * r * 0.12, -r * 0.15),
                width: r * 2.1,
                height: r * 0.62),
            Radius.circular(r * 0.3),
          ),
          Paint()..color = band.withOpacity(0.85),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 0.62),
                width: r * 2.15,
                height: r * 0.42),
            Radius.circular(r * 0.2),
          ),
          Paint()..color = dark,
        );
        break;

      case HeadGear.beanie:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 0.8),
                width: r * 2.05,
                height: r * 0.9),
            Radius.circular(r * 0.4),
          ),
          Paint()..color = cloth,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 0.5),
                width: r * 2.15,
                height: r * 0.32),
            Radius.circular(r * 0.16),
          ),
          Paint()..color = band,
        );
        break;

      case HeadGear.crown:
        final base = headC.dy - r * 0.72;
        final p = Path()..moveTo(headC.dx - r * 1.0, base);
        for (int i = 0; i < 3; i++) {
          final x0 = headC.dx - r * 1.0 + r * 0.67 * i;
          p.lineTo(x0 + r * 0.33, base - r * 0.62);
          p.lineTo(x0 + r * 0.67, base);
        }
        p.close();
        canvas.drawPath(p, Paint()..color = const Color(0xFFE8B33D));
        break;

      case HeadGear.capBackwards:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(0, -r * 0.78),
                width: r * 2.0,
                height: r * 0.78),
            Radius.circular(r * 0.36),
          ),
          Paint()..color = cloth,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(-dir * r * 1.25, -r * 0.72),
                width: r * 0.9,
                height: r * 0.28),
            Radius.circular(r * 0.14),
          ),
          Paint()..color = band,
        );
        break;

      case HeadGear.gasMask:
        // Filter cup over the muzzle of the face plus a strap. This
        // character's expression reads through the body and the brows
        // rather than the mouth.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: headC + Offset(dir * r * 0.3, r * 0.28),
                width: r * 1.5,
                height: r * 1.0),
            Radius.circular(r * 0.4),
          ),
          Paint()..color = dark,
        );
        canvas.drawCircle(
          headC + Offset(dir * r * 0.72, r * 0.34),
          r * 0.3,
          Paint()..color = band,
        );
        canvas.drawLine(
          Offset(headC.dx - r * 1.0, headC.dy - r * 0.1),
          Offset(headC.dx + r * 0.6, headC.dy - r * 0.1),
          Paint()
            ..color = dark
            ..strokeWidth = r * 0.2,
        );
        break;
    }
  }

  /// Beards, patches, goggles and paint — the marks that sit on the face
  /// itself. Drawn under the headgear so a hat brim can overlap them.
  static void faceMark(
      Canvas canvas, CharacterDef ch, Offset headC, double r, double dir) {
    switch (ch.mark) {
      case FaceMark.none:
        break;

      case FaceMark.beard:
        canvas.drawPath(
          Path()
            ..moveTo(headC.dx - r * 0.62, headC.dy + r * 0.42)
            ..quadraticBezierTo(headC.dx, headC.dy + r * 1.35,
                headC.dx + r * 0.62, headC.dy + r * 0.42)
            ..close(),
          Paint()..color = const Color(0xFF3B2A1C),
        );
        break;

      case FaceMark.stubble:
        canvas.drawPath(
          Path()
            ..moveTo(headC.dx - r * 0.58, headC.dy + r * 0.42)
            ..quadraticBezierTo(headC.dx, headC.dy + r * 0.92,
                headC.dx + r * 0.58, headC.dy + r * 0.42)
            ..close(),
          Paint()..color = Colors.black.withOpacity(0.16),
        );
        break;

      case FaceMark.moustache:
        canvas.drawPath(
          Path()
            ..moveTo(headC.dx - r * 0.45, headC.dy + r * 0.3)
            ..quadraticBezierTo(
                headC.dx, headC.dy + r * 0.62, headC.dx + r * 0.45, headC.dy + r * 0.3)
            ..quadraticBezierTo(headC.dx, headC.dy + r * 0.42,
                headC.dx - r * 0.45, headC.dy + r * 0.3)
            ..close(),
          Paint()..color = const Color(0xFF4A3524),
        );
        break;

      case FaceMark.eyePatch:
        final eye = headC + Offset(dir * r * 0.34, -r * 0.12);
        canvas.drawLine(
          Offset(headC.dx - r * 0.95, headC.dy - r * 0.5),
          Offset(headC.dx + r * 0.95, headC.dy - r * 0.28),
          Paint()
            ..color = const Color(0xFF1D1D20)
            ..strokeWidth = r * 0.13,
        );
        canvas.drawOval(
          Rect.fromCenter(center: eye, width: r * 0.66, height: r * 0.56),
          Paint()..color = const Color(0xFF1D1D20),
        );
        break;

      case FaceMark.goggles:
        // Pushed up on the forehead, which is where goggles live when
        // somebody is busy shooting.
        for (final s in [-1.0, 1.0]) {
          canvas.drawCircle(
            headC + Offset(s * r * 0.36, -r * 0.55),
            r * 0.32,
            Paint()..color = const Color(0xFF9FD8E8).withOpacity(0.9),
          );
          canvas.drawCircle(
            headC + Offset(s * r * 0.36, -r * 0.55),
            r * 0.32,
            Paint()
              ..color = const Color(0xFF4A3B2C)
              ..style = PaintingStyle.stroke
              ..strokeWidth = r * 0.13,
          );
        }
        canvas.drawLine(
          Offset(headC.dx - r * 0.9, headC.dy - r * 0.55),
          Offset(headC.dx + r * 0.9, headC.dy - r * 0.55),
          Paint()
            ..color = const Color(0xFF4A3B2C)
            ..strokeWidth = r * 0.12,
        );
        break;

      case FaceMark.scar:
        canvas.drawLine(
          headC + Offset(dir * r * 0.5, -r * 0.55),
          headC + Offset(dir * r * 0.28, r * 0.15),
          Paint()
            ..color = const Color(0xFFB4695C)
            ..strokeWidth = r * 0.1
            ..strokeCap = StrokeCap.round,
        );
        break;

      case FaceMark.snorkel:
        canvas.drawLine(
          headC + Offset(-dir * r * 0.85, r * 0.4),
          headC + Offset(-dir * r * 0.95, -r * 1.15),
          Paint()
            ..color = const Color(0xFFFFE28A)
            ..strokeWidth = r * 0.2
            ..strokeCap = StrokeCap.round,
        );
        break;

      case FaceMark.warPaint:
        for (final s in [-1.0, 1.0]) {
          canvas.drawRect(
            Rect.fromCenter(
                center: headC + Offset(s * r * 0.42, -r * 0.05),
                width: r * 0.22,
                height: r * 0.7),
            Paint()..color = ch.accent.withOpacity(0.75),
          );
        }
        break;
    }
  }
}
