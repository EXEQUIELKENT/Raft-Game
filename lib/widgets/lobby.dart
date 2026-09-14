import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared furniture for the two lobby screens — hotspot and online.
///
/// The LAYOUT here is lifted from Battleship Blitz, which has had these two
/// screens through several rounds of use: a header bar, then a single
/// scrolling column of titled cards ordered by what a player actually came
/// to do, each card carrying its own icon, subtitle and controls, with the
/// small print under the control rather than an error after the attempt.
/// What is NOT lifted is the look — every colour, font and shape below is
/// Raft's own (see [RT]), because the two games do not look alike and should
/// not start to.
///
/// The point of pulling it into one file is that both screens then agree
/// with each other. Before this the hotspot page and the online page each
/// invented their own card, their own field and their own section heading,
/// so the same idea was three shapes depending which screen you were on.

/// A room code rendered as separate tiles.
///
/// One character per tile rather than a single string, because a code's job
/// is to be read aloud across a table: tiles force the eye to take it one
/// character at a time, and they make a four-letter code legible from much
/// further away than text of the same size.
class CodeTiles extends StatelessWidget {
  final String code;
  final Color color;
  final Color textColor;
  final double size;

  const CodeTiles({
    super.key,
    required this.code,
    this.color = RT.cream,
    this.textColor = RT.ink,
    this.size = 46,
  });

  @override
  Widget build(BuildContext context) {
    final chars = code.trim().toUpperCase().split('');
    if (chars.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final ch in chars)
          Container(
            width: size,
            height: size * 1.08,
            margin: EdgeInsets.symmetric(horizontal: size * 0.07),
            alignment: Alignment.center,
            decoration: RT.pill(color: color, opacity: 1, radius: size * 0.26),
            child: Text(
              ch,
              style: RT.chunky(size: size * 0.54, color: textColor),
            ),
          ),
      ],
    );
  }
}

/// A room code at list size — boxed and set apart from whatever sits beside
/// it, so a code and a name never read as one string.
class CodePill extends StatelessWidget {
  final String code;
  final Color color;
  final Color textColor;

  const CodePill({
    super.key,
    required this.code,
    this.color = RT.cream,
    this.textColor = RT.ink,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: RT.pill(color: color, opacity: 1, radius: 8),
        child: Text(
          code.toUpperCase(),
          style: RT.chunky(size: 13, color: textColor).copyWith(
            letterSpacing: 2,
          ),
        ),
      );
}

/// One titled block of the lobby: an icon, a heading, a line saying what it
/// is for, and its controls.
///
/// Every block on both screens is one of these, so a player learns the shape
/// once. The subtitle is deliberately part of the card rather than optional
/// decoration — a lobby control that does not say what it does is the main
/// way these screens go wrong.
class LobbyCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final String? subtitle;
  final Widget child;
  final Color fill;

  const LobbyCard({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
    required this.child,
    this.subtitle,
    this.fill = RT.cream,
  });

  @override
  Widget build(BuildContext context) {
    final onDark = fill.computeLuminance() < 0.4;
    final ink = onDark ? RT.cream : RT.ink;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: RT.pill(color: fill, opacity: 1, radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: RT.ink, width: 2),
                ),
                child: Icon(icon, color: Colors.white, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: RT.chunky(size: 15, color: ink))),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              style: RT.body(size: 11.5, color: ink.withOpacity(0.75)),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// The small print under a control — the rule that saves a failed attempt
/// ("codes never use I, O, 0 or 1"), rather than an error message after one
/// has already been made.
class LobbyHint extends StatelessWidget {
  final String text;
  final TextAlign align;
  final Color? color;

  const LobbyHint(this.text, {super.key, this.align = TextAlign.left, this.color});

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: align,
        style: RT.body(
          size: 9,
          color: color ?? RT.ink.withOpacity(0.6),
          weight: FontWeight.w800,
        ).copyWith(letterSpacing: 0.6),
      );
}

/// A heading over a list, with an optional count beside it.
///
/// The count is a pill rather than being spelled into the heading, so the
/// eye can find how many without reading the words, and every section reads
/// the same way whether it carries a count or not.
class LobbySection extends StatelessWidget {
  final String text;
  final int? count;
  final Color color;

  const LobbySection(this.text, {super.key, this.count, this.color = RT.ink});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 2),
        child: Row(
          children: [
            Text(
              text,
              style: RT.body(size: 11, color: color, weight: FontWeight.w900)
                  .copyWith(letterSpacing: 1.1),
            ),
            if (count != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: RT.pill(color: RT.orange, opacity: 1, radius: 9),
                child: Text('$count',
                    style: RT.chunky(size: 11, color: Colors.white)),
              ),
            ],
          ],
        ),
      );
}

/// The lobby header: a back arrow, a title, and an optional busy spinner.
class LobbyHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final bool busy;

  const LobbyHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: RT.ink,
        padding: const EdgeInsets.fromLTRB(6, 8, 14, 10),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: RT.cream),
              onPressed: onBack,
            ),
            Expanded(
              child: Text(title, style: RT.chunky(size: 19, color: RT.cream)),
            ),
            if (busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(RT.cream),
                ),
              ),
          ],
        ),
      );
}

/// A row with a live spinner and a line of status text — what a panel that
/// is waiting on something else says while it waits.
class LobbyWaiting extends StatelessWidget {
  final String text;
  final Color color;

  const LobbyWaiting(this.text, {super.key, this.color = RT.yellow});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: RT.body(size: 11, color: color, weight: FontWeight.w800),
            ),
          ),
        ],
      );
}

/// The text field a code is typed into: wide letter spacing so a code being
/// read out lands one character at a time rather than as a word to spell.
InputDecoration lobbyInput(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: RT.chunky(size: 20, color: RT.ink.withOpacity(0.25))
          .copyWith(letterSpacing: 6),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: RT.ink, width: 2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: RT.orange, width: 3),
      ),
    );

/// One item settling onto the page shortly after the ones above it.
///
/// A lobby is a stack of cards that all arrive at once, which reads as a
/// snap. Staggering them by position turns the same content into something
/// that assembles itself.
class PopIn extends StatefulWidget {
  final Widget child;
  final Duration delay;

  const PopIn({super.key, required this.child, this.delay = Duration.zero});

  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void initState() {
    super.initState();
    // A delayed start rather than a delayed build, so the widget is in the
    // tree (and has its size) the whole time and the list does not reflow
    // as each item appears.
    Future<void>.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curve),
        child: widget.child,
      ),
    );
  }
}

/// Hands out increasing delays so a column of cards arrives one after
/// another. One instance per screen build.
class PopSequence {
  int _step = 0;

  /// Capped so a long list's last row is not kept waiting on all the others.
  Widget wrap(Widget child, {int maxSteps = 6}) {
    final i = _step.clamp(0, maxSteps);
    _step++;
    return PopIn(delay: Duration(milliseconds: 80 * i), child: child);
  }
}
