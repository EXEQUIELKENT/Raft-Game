import 'package:flutter/material.dart';

import '../game/audio.dart';
import '../game/character_art.dart';
import '../game/characters.dart';
import '../game/save.dart';
import '../theme.dart';

/// Picking who you sail as.
///
/// The old screen offered a hat name and a circle of colour, neither of which
/// appeared anywhere in a battle. This one picks an actual [CharacterDef] out
/// of the roster and previews it with [CharacterArt] — the same painter the
/// battle renderer uses — so what you choose here is literally what stands on
/// your deck, hat, face marking, outfit and all.
///
/// Characters unlock by captain level, which is one of the things the levelling
/// rework put on the other end of the XP bar.
class CharactersScreen extends StatefulWidget {
  const CharactersScreen({super.key});

  @override
  State<CharactersScreen> createState() => _CharactersScreenState();
}

class _CharactersScreenState extends State<CharactersScreen> {
  void _saveAndPop() {
    AudioService.instance.sfx('click');
    SaveService.instance.save();
    Navigator.pop(context);
  }

  void _pick(CharacterDef c, bool unlocked) {
    AudioService.instance.sfx(unlocked ? 'click' : 'bounce');
    if (!unlocked) return;
    setState(() => SaveService.instance.data.character = c.id);
  }

  @override
  Widget build(BuildContext context) {
    final save = SaveService.instance.data;
    final selected = Cast.byId(save.character);
    final level = save.level;

    // Grouped by theme so the roster reads as families rather than a wall of
    // heads — and so a locked group tells you what the next sea looks like.
    final byTheme = <CharacterTheme, List<CharacterDef>>{};
    for (final c in Cast.playable) {
      byTheme.putIfAbsent(c.theme, () => []).add(c);
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _saveAndPop();
      },
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: RT.sunset),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: _saveAndPop,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration:
                              RT.card(color: Colors.white, radius: 12, border: 3),
                          child: const Icon(Icons.arrow_back, color: RT.ink),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('YOUR CHARACTER',
                          style: RT.chunky(size: 24, outline: 3)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        decoration:
                            RT.card(color: RT.yellow, radius: 12, border: 3),
                        child: Text('LV $level · ${save.rank}',
                            style: RT.chunky(
                                size: 12, color: const Color(0xFF6B4A00))),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _preview(selected),
                        const SizedBox(height: 14),
                        for (final entry in byTheme.entries) ...[
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8, top: 4),
                            child: Text(entry.key.label,
                                style: RT.chunky(size: 15, outline: 2.5)),
                          ),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final c in entry.value)
                                _tile(c, c.unlockLevel <= level,
                                    c.id == selected.id),
                            ],
                          ),
                          const SizedBox(height: 14),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview(CharacterDef c) => Container(
        padding: const EdgeInsets.all(16),
        decoration: RT.card(),
        child: Row(
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: c.outfit.withOpacity(0.16),
                shape: BoxShape.circle,
                border: Border.all(color: RT.ink, width: 4),
              ),
              child: CustomPaint(painter: _PortraitPainter(c)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name.toUpperCase(),
                      style: RT.chunky(size: 20, color: RT.ink)),
                  const SizedBox(height: 4),
                  Text(c.blurb,
                      style: RT.body(
                          size: 12,
                          color: RT.ink.withOpacity(0.72),
                          weight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _chip(c.theme.label, c.accent),
                      _chip(_voiceLabel(c), c.outfit),
                      _chip(_buildLabel(c), RT.ink.withOpacity(0.5)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  static String _voiceLabel(CharacterDef c) => switch (c.voice) {
        VoiceType.low => 'Deep voice',
        VoiceType.mid => 'Even voice',
        VoiceType.high => 'High voice',
      };

  static String _buildLabel(CharacterDef c) =>
      c.build >= 1.06 ? 'Broad' : (c.build <= 0.96 ? 'Wiry' : 'Average');

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.18),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: color.withOpacity(0.7), width: 2),
        ),
        child: Text(text,
            style: RT.body(
                size: 10, color: RT.ink, weight: FontWeight.w800)),
      );

  Widget _tile(CharacterDef c, bool unlocked, bool selected) {
    return GestureDetector(
      onTap: () => _pick(c, unlocked),
      child: Opacity(
        opacity: unlocked ? 1 : 0.55,
        child: Container(
          width: 92,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: RT.card(
            color: selected ? RT.yellow : Colors.white,
            radius: 14,
            border: selected ? 4 : 3,
          ),
          child: Column(
            children: [
              SizedBox(
                height: 52,
                width: 52,
                child: unlocked
                    ? CustomPaint(painter: _PortraitPainter(c))
                    : const Icon(Icons.lock, color: RT.ink, size: 26),
              ),
              const SizedBox(height: 4),
              Text(
                c.name.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: RT.body(
                    size: 9, color: RT.ink, weight: FontWeight.w800),
              ),
              if (!unlocked)
                Text('LV ${c.unlockLevel}',
                    style: RT.body(
                        size: 9,
                        color: RT.ink.withOpacity(0.6),
                        weight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Head-and-shoulders portrait, drawn with the battle's own [CharacterArt] so
/// the picker can never show something the deck does not.
class _PortraitPainter extends CustomPainter {
  final CharacterDef c;
  const _PortraitPainter(this.c);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide * 0.3;
    final headC = Offset(size.width / 2, size.height * 0.46);

    // Shoulders, so a hat has a body to sit over.
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height * 0.92),
          width: r * 3.0,
          height: r * 1.8,
        ),
        topLeft: Radius.circular(r * 0.7),
        topRight: Radius.circular(r * 0.7),
      ),
      Paint()..color = c.outfit,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height * 0.86),
          width: r * 3.0,
          height: r * 0.34,
        ),
        Radius.circular(r * 0.17),
      ),
      Paint()..color = c.accent,
    );

    canvas.drawCircle(headC, r, Paint()..color = c.skin);

    // Eyes: a plain neutral pair. The battle's expression system drives these
    // from live combat state, which a portrait has none of.
    final eye = Paint()..color = RT.ink;
    for (final s in [-1.0, 1.0]) {
      canvas.drawCircle(headC + Offset(s * r * 0.33, -r * 0.06), r * 0.13, eye);
    }
    canvas.drawArc(
      Rect.fromCenter(
          center: headC + Offset(0, r * 0.34), width: r * 0.7, height: r * 0.4),
      0.25,
      2.64,
      false,
      Paint()
        ..color = RT.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.1
        ..strokeCap = StrokeCap.round,
    );

    CharacterArt.headgear(canvas, c.look, headC, r, 1);
  }

  @override
  bool shouldRepaint(_PortraitPainter old) => old.c.look != c.look;
}
