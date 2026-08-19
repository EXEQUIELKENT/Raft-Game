import 'dart:math';

import 'package:flutter/material.dart';

import '../game/raft.dart';
import '../theme.dart';

/// A small live preview of a raft loadout — hull silhouette, colour and the
/// crew it carries — so the customization pickers show what you're choosing
/// rather than just naming it. Drawn with the same shape language the battle
/// renderer uses, so what you see here is what sails.
class RaftPreview extends StatelessWidget {
  final RaftLoadout loadout;
  final double height;

  const RaftPreview({super.key, required this.loadout, this.height = 132});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      // Without an explicit width this collapses to nothing: the only child is
      // a CustomPaint with no intrinsic size, and the parent columns use
      // CrossAxisAlignment.start, so nothing stretches it.
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [RT.sky2, RT.sea1],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: CustomPaint(painter: _RaftPreviewPainter(loadout)),
    );
  }
}

/// Kept as a private alias so match_setup_screen can use the short name.
class _RaftPreviewPainter extends CustomPainter {
  final RaftLoadout lo;
  _RaftPreviewPainter(this.lo);

  @override
  void paint(Canvas canvas, Size size) {
    // A page transition can hand this a zero-width box for a frame. Scaling by
    // zero and laying out text at a negative width both assert, so there is
    // nothing useful to draw until the box has real dimensions.
    if (size.width <= 1 || size.height <= 1) return;

    final cx = size.width / 2;
    final waterY = size.height * 0.72;

    // Water band
    canvas.drawRect(
      Rect.fromLTWH(0, waterY, size.width, size.height - waterY),
      Paint()..color = RT.sea2.withOpacity(0.55),
    );

    final w = lo.width;
    final h = w * lo.hull.thickness;

    // Fit the whole raft — hull, crew and any mast — inside the box on both
    // axes. Fitting width alone blows a short, wide preview far past its own
    // height, since the crew scale up with the hull.
    const crewRise = 56.0; // head top above the deck, in world units
    final contentH = crewRise + h + (lo.hull.hasMast ? 44 : 0);
    final scale = min(
      (size.width * 0.8) / w,
      (size.height * 0.66) / contentH,
    );

    canvas.save();
    canvas.translate(cx, 0);
    canvas.scale(scale);

    final deckTop = waterY / scale - h * 0.55;
    final radius = Radius.circular(h * lo.hull.rounding.clamp(0.0, 1.0) * 0.5 + 3);

    if (lo.hull.hasMast) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(-4 - 26, deckTop - 96, 9, 96),
          const Radius.circular(4),
        ),
        Paint()..color = const Color(0xFF8A5F35),
      );
      final sail = Path()
        ..moveTo(-26, deckTop - 86)
        ..lineTo(-26 + 40, deckTop - 62)
        ..lineTo(-26 + 26, deckTop - 20)
        ..lineTo(-26, deckTop - 20)
        ..close();
      canvas.drawPath(sail, Paint()..color = const Color(0xFFF2ECC8));
    }

    // Crew
    for (int i = 0; i < lo.crewCount; i++) {
      final dx = lo.crewOffset(i);
      final headC = Offset(dx, deckTop - 30);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(dx - 13, headC.dy + 18, 26, 22),
          const Radius.circular(7),
        ),
        Paint()..color = const Color(0xFF2D4F8F),
      );
      canvas.drawCircle(headC, 21, Paint()..color = const Color(0xFFEFD79F));
      for (final ex in [-7.0, 7.0]) {
        canvas.drawOval(
          Rect.fromCenter(center: headC + Offset(ex, 0), width: 11, height: 13),
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(headC + Offset(ex + 1, 2), 3.2, Paint()..color = RT.ink);
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: headC + const Offset(0, 14), width: 14, height: 4),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0xFFB9955C),
      );
    }

    // Hull
    final hullRect = Rect.fromLTWH(-w / 2, deckTop, w, h);
    canvas.drawRRect(RRect.fromRectAndRadius(hullRect, radius), Paint()..color = lo.color);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-w / 2, deckTop + h * 0.58, w, h * 0.42),
        radius,
      ),
      Paint()..color = Colors.black.withOpacity(0.14),
    );
    if (lo.hull.rounding < 0.5) {
      canvas.drawRect(
        Rect.fromLTWH(-w / 2 + 6, deckTop + h * 0.36, w - 12, 3),
        Paint()..color = Colors.black.withOpacity(0.12),
      );
    }

    canvas.restore();

    // Caption
    final tp = TextPainter(
      text: TextSpan(
        text: '${lo.hull.name} · ${lo.size.name} · ${lo.crewCount} crew',
        style: RT.body(size: 10, color: Colors.white, weight: FontWeight.w800),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: max(0.0, size.width - 12));
    tp.paint(canvas, Offset(cx - tp.width / 2, size.height - tp.height - 5));
  }

  @override
  bool shouldRepaint(covariant _RaftPreviewPainter old) =>
      old.lo.hull.id != lo.hull.id ||
      old.lo.size.id != lo.size.id ||
      old.lo.colorIndex != lo.colorIndex ||
      old.lo.crewCount != lo.crewCount;
}
