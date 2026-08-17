import 'dart:math';
import 'package:flutter/material.dart';

/// Raft Rumble theme — Style 2: Vibrant Comic / Candy
class RT {
  RT._();

  // Core palette
  static const Color ink = Color(0xFF2B1B3D);        // thick outline color
  static const Color sky1 = Color(0xFFFF9D5C);       // sunset orange
  static const Color sky2 = Color(0xFFFF5E8A);       // pink
  static const Color sky3 = Color(0xFF7B4FB3);       // purple
  static const Color sea1 = Color(0xFF3EC6E0);       // candy teal
  static const Color sea2 = Color(0xFF1B7FB8);       // deep blue
  static const Color sand = Color(0xFFFFE3A3);
  static const Color cream = Color(0xFFFFF6E8);
  static const Color red = Color(0xFFFF4757);
  static const Color orange = Color(0xFFFF8C1A);
  static const Color yellow = Color(0xFFFFD32A);
  static const Color green = Color(0xFF2ED573);
  static const Color blue = Color(0xFF3B9CFF);
  static const Color purple = Color(0xFF9B59D0);
  static const Color pink = Color(0xFFFF6BC1);

  // Player colors
  static const List<Color> playerColors = [
    Color(0xFFFF4757), // red
    Color(0xFF3B9CFF), // blue
    Color(0xFF2ED573), // green
    Color(0xFFFFB020), // amber
  ];

  static const List<Color> playerDark = [
    Color(0xFFC02836),
    Color(0xFF2270C9),
    Color(0xFF1DA452),
    Color(0xFFCC8400),
  ];

  /// Chunky comic text style with outline-ish shadow
  static TextStyle chunky({
    double size = 20,
    Color color = Colors.white,
    double outline = 0,
    FontWeight weight = FontWeight.w900,
    double letterSpacing = 1.2,
  }) {
    return TextStyle(
      fontFamily: 'RaftRumble',
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
          : const [
              Shadow(color: Color(0x55000000), offset: Offset(0, 3), blurRadius: 0),
            ],
    );
  }

  /// Sunset gradient used across menus
  static const LinearGradient sunset = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [sky1, sky2, sky3],
  );

  /// Ocean gradient
  static const LinearGradient ocean = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [sea1, sea2],
  );

  static BoxDecoration card({Color color = cream, double radius = 20, double border = 4}) {
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: ink, width: border),
      boxShadow: const [
        BoxShadow(color: Color(0x55000000), offset: Offset(0, 5), blurRadius: 0),
      ],
    );
  }
}

/// Chunky cartoon button with press animation + haptic + click sound
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
    return hsl.withLightness(max(0.0, hsl.lightness - 0.14)).toColor();
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
        transform: Matrix4.translationValues(0, _down ? 5 : 0, 0),
        decoration: BoxDecoration(
          color: base,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: RT.ink, width: 4),
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
                style: RT.chunky(size: widget.fontSize, color: widget.textColor ?? Colors.white, outline: 2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Comic starburst painter for explosions / logos
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
