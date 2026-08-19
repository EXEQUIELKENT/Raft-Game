import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Raft Rumble theme — "Raft Duel": pirate/nautical, sky-to-sea gradients,
/// borderless chunky buttons with a color-matched drop shadow, frosted
/// white pill chips for HUD readouts. Ported from the Claude Design mockup.
class RT {
  RT._();

  // Core palette
  static const Color ink = Color(0xFF16323F);         // navy-teal text/outline
  static const Color sky1 = Color(0xFF77BFE3);         // horizon sky blue
  static const Color sky2 = Color(0xFFC6E6F3);         // pale sky/cloud blue
  static const Color sky3 = Color(0xFFE7D9A0);         // sand highlight
  static const Color sea1 = Color(0xFF2C8B99);         // mid sea teal
  static const Color sea2 = Color(0xFF175F6B);         // deep sea teal
  static const Color sand = Color(0xFFE0D193);
  static const Color cream = Color(0xFFFFF6E8);
  static const Color red = Color(0xFFE0574F);
  static const Color orange = Color(0xFFFF6B4A);       // primary accent / CTA
  static const Color yellow = Color(0xFFFFD34D);       // gold / coins
  static const Color coin = yellow;
  static const Color green = Color(0xFF4EC06A);
  static const Color blue = Color(0xFF3F7FC9);
  static const Color purple = Color(0xFF8A5FB0);
  static const Color pink = Color(0xFFC05A86);

  // Player colors — kept distinct/vivid for gameplay legibility.
  static const List<Color> playerColors = [
    Color(0xFFE0574F), // red
    Color(0xFF3F7FC9), // blue
    Color(0xFF4EC06A), // green
    Color(0xFFFFB020), // amber
  ];

  static const List<Color> playerDark = [
    Color(0xFFA83A34),
    Color(0xFF2A5A94),
    Color(0xFF34903F),
    Color(0xFFCC8400),
  ];

  /// Chunky display text (Baloo 2) — used for titles, buttons, HUD numbers.
  /// [outline] draws an 8-direction ink outline for text sitting directly on
  /// a gradient/photo background; leave it at 0 for text already inside a
  /// white/colored card, where a simple soft shadow reads better.
  static TextStyle chunky({
    double size = 20,
    Color color = Colors.white,
    double outline = 0,
    FontWeight weight = FontWeight.w800,
    double letterSpacing = 0.2,
  }) {
    return GoogleFonts.baloo2(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: 1.0,
      shadows: outline > 0
          ? [
              Shadow(color: ink, offset: Offset(-outline, 0)),
              Shadow(color: ink, offset: Offset(outline, 0)),
              Shadow(color: ink, offset: Offset(0, -outline)),
              Shadow(color: ink, offset: Offset(0, outline)),
              Shadow(color: ink, offset: Offset(-outline, -outline)),
              Shadow(color: ink, offset: Offset(outline, outline)),
              Shadow(color: ink, offset: Offset(-outline, outline)),
              Shadow(color: ink, offset: Offset(outline, -outline)),
            ]
          : [
              Shadow(color: ink.withOpacity(0.22), offset: const Offset(0, 3)),
            ],
    );
  }

  /// Rounder, lighter-weight body text (Nunito) — subtitles, descriptions,
  /// stat labels, anything secondary to a [chunky] headline.
  static TextStyle body({
    double size = 13,
    Color color = ink,
    FontWeight weight = FontWeight.w700,
    double letterSpacing = 0.2,
  }) {
    return GoogleFonts.nunito(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: 1.3,
    );
  }

  /// Tropical hero gradient: sky blue -> pale sky -> sand -> sea teal.
  /// Kept as `RT.sunset` so every existing `gradient: RT.sunset` reference
  /// picks up the new look without touching each call site.
  static const LinearGradient sunset = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.42, 0.58, 1.0],
    colors: [sky1, sky2, sky3, sea1],
  );

  /// Deep-water gradient for battle/ocean-heavy screens.
  static const LinearGradient ocean = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [sea1, sea2],
  );

  static BoxDecoration card({Color color = cream, double radius = 20, double border = 2.5}) {
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      border: border > 0 ? Border.all(color: ink.withOpacity(0.14), width: border) : null,
      boxShadow: const [
        BoxShadow(color: Color(0x33000000), offset: Offset(0, 5), blurRadius: 0),
      ],
    );
  }

  /// Frosted translucent-white pill, for HUD chips floating over the world
  /// canvas (health readouts, wind, status messages) — mirrors the
  /// mockup's `rgba(255,255,255,.8)` chip style.
  static BoxDecoration pill({Color color = Colors.white, double opacity = 0.85, double radius = 16}) {
    return BoxDecoration(
      color: color.withOpacity(opacity),
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [
        BoxShadow(color: Color(0x2A000000), offset: Offset(0, 3), blurRadius: 6),
      ],
    );
  }
}

/// Chunky cartoon button with press animation + haptic + click sound.
/// Borderless, solid-fill, with a color-matched offset drop shadow —
/// matches the mockup's flatter chunky-button style.
class ChunkyButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final Color? textColor;
  final VoidCallback? onPressed;
  final double width;
  final double height;
  final double fontSize;

  const ChunkyButton({
    super.key,
    required this.label,
    this.icon,
    this.color = RT.orange,
    this.textColor,
    this.onPressed,
    this.width = 260,
    this.height = 60,
    this.fontSize = 22,
  });

  @override
  State<ChunkyButton> createState() => _ChunkyButtonState();
}

class _ChunkyButtonState extends State<ChunkyButton> {
  bool _down = false;

  Color _darken(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness(max(0.0, hsl.lightness - 0.16)).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final base = enabled ? widget.color : Colors.grey.shade400;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTapUp: enabled
          ? (_) {
              setState(() => _down = false);
              widget.onPressed!();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: widget.width,
        height: widget.height,
        transform: Matrix4.translationValues(0, _down ? 6 : 0, 0),
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(20),
          boxShadow: _down
              ? [BoxShadow(color: _darken(base), offset: const Offset(0, 2))]
              : [BoxShadow(color: _darken(base), offset: const Offset(0, 7))],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, color: widget.textColor ?? Colors.white, size: widget.fontSize + 4),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                widget.label,
                overflow: TextOverflow.ellipsis,
                style: RT.chunky(size: widget.fontSize, color: widget.textColor ?? Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Comic starburst painter for explosions / logos.
class StarburstPainter extends CustomPainter {
  final Color color;
  final int points;
  final double wobble;
  const StarburstPainter({required this.color, this.points = 14, this.wobble = 0.35});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final center = Offset(size.width / 2, size.height / 2);
    final r1 = size.width / 2;
    final r2 = r1 * (1 - wobble);
    final path = Path();
    final rnd = Random(7);
    for (int i = 0; i < points * 2; i++) {
      final angle = (i / (points * 2)) * 2 * pi - pi / 2;
      final r = (i.isEven ? r1 : r2) * (0.9 + rnd.nextDouble() * 0.2);
      final p = center + Offset(cos(angle) * r, sin(angle) * r);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
