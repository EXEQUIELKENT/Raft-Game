import 'package:flutter/material.dart';

import '../game/audio.dart';
import '../game/build.dart';
import '../game/controller.dart';
import '../theme.dart';

/// Laying out your raft, on the raft, over the water it is about to fight on.
///
/// An overlay rather than a separate screen, and deliberately so: the raft
/// being edited is the one visible underneath, at the scale it will be
/// fought at — so a wall two blocks high is seen against the crew who will
/// stand behind it rather than judged from a diagram.
///
/// It used to hedge that: the raft was underneath, but the editing happened
/// on a grid panel floating in the middle of the screen, which meant reading
/// two pictures of the same raft and translating between them. The grid is
/// gone. The cells are marked on the deck itself (see the renderer's build
/// ghosts) and taps land on the world, so this widget is now only the things
/// a tap on the raft cannot be: which material is loaded, what it costs,
/// what is wrong, and when you are done.
///
/// Everything here therefore keeps to the EDGES. The middle of the screen
/// belongs to the raft, because the middle of the screen is what the player
/// is actually editing.
class BuildOverlay extends StatefulWidget {
  final GameController ctrl;

  /// The currently loaded material, owned by the game screen — the tap that
  /// spends it lands on the world behind this overlay, not on the overlay.
  final BuildMaterial selected;
  final ValueChanged<BuildMaterial> onSelect;

  /// Keys on the two bars, so the game screen can keep a tap on them from
  /// ALSO placing a block on the deck behind. Both this overlay and the
  /// world's pointer listener are in the same hit-test path, so a tap
  /// reaches both unless the bar's rectangle is excluded by name — the same
  /// mechanism the weapon bar and the fire button already use.
  final Key topBarKey;
  final Key bottomBarKey;

  const BuildOverlay({
    super.key,
    required this.ctrl,
    required this.selected,
    required this.onSelect,
    required this.topBarKey,
    required this.bottomBarKey,
  });

  @override
  State<BuildOverlay> createState() => _BuildOverlayState();
}

class _BuildOverlayState extends State<BuildOverlay> {
  @override
  Widget build(BuildContext context) {
    // Listens to the controller directly rather than relying on whatever
    // mounts it to rebuild: the plan lives on the controller, so an edit
    // made by tapping the raft has to reach the budget shown up here.
    return AnimatedBuilder(
      animation: widget.ctrl,
      builder: (_, __) => _panel(),
    );
  }

  Widget _panel() {
    final plan = widget.ctrl.editingPlan;
    if (plan == null) return const SizedBox.shrink();

    // Not a dimming scrim, and not a full-screen surface. The raft under
    // here is the thing being edited, so the overlay covers only the top and
    // bottom strips — everything between them is left untouched, both to
    // look at and to tap.
    return Positioned.fill(
      child: SafeArea(
        child: Stack(
          children: [
            Positioned(top: 0, left: 0, right: 0, child: _topBar(plan)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (plan.problem != null) _problem(plan.problem!),
                  const SizedBox(height: 8),
                  _bottomBar(plan),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Title, the instruction, and what is left to spend — one strip across
  /// the top, clear of the water the raft sits in.
  Widget _topBar(BuildPlan plan) {
    final spent = plan.cost;
    final over = spent > BuildPlan.budget;
    return Padding(
      key: widget.topBarKey,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Flexible, not fixed: the instruction is a full sentence and the
          // screen is a phone on its side. Left to size itself it overflowed
          // the row on narrow devices and pushed the budget off the edge.
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: RT.pill(color: RT.ink, opacity: 0.82, radius: 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('BUILD YOUR RAFT',
                        style: RT.chunky(size: 16, color: RT.cream)),
                    const SizedBox(height: 2),
                    // The instruction, because the gesture is the one thing
                    // a player cannot discover by looking: the marked cells
                    // say where, not what to do.
                    Text('Tap the marked deck to build · tap a block to remove',
                        style: RT.body(
                            size: 10,
                            color: RT.cream.withOpacity(0.75),
                            weight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // The budget as what is left rather than what is spent: a player
          // deciding whether one more iron block fits wants the remainder.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration:
                RT.pill(color: over ? RT.red : RT.yellow, opacity: 1, radius: 14),
            child: Text(
              over
                  ? 'OVER BY ${spent - BuildPlan.budget}'
                  : '${BuildPlan.budget - spent} LEFT',
              style:
                  RT.chunky(size: 14, color: over ? Colors.white : RT.ink),
            ),
          ),
        ],
      ),
    );
  }

  Widget _problem(String text) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: RT.pill(color: RT.red, opacity: 1, radius: 12),
          child: Text(text,
              textAlign: TextAlign.center,
              style: RT.chunky(size: 12, color: Colors.white)),
        ),
      );

  /// The palette and the way out, on one row along the bottom so the deck
  /// above it stays clear.
  Widget _bottomBar(BuildPlan plan) {
    final ok = plan.isValid;
    return Container(
      key: widget.bottomBarKey,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: RT.ink.withOpacity(0.82),
        border: const Border(top: BorderSide(color: RT.ink, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [for (final def in MaterialDef.all) _swatch(def)],
              ),
            ),
          ),
          const SizedBox(width: 10),
          ChunkyButton(
              label: ok ? 'SET SAIL' : 'CANNOT SAIL',
              icon: Icons.sailing,
              color: ok ? RT.orange : Colors.grey.shade600,
              width: 172,
              height: 52,
              fontSize: 16,
              // A plan that cannot stand is refused rather than quietly
              // repaired: the player is looking at it, and deleting their
              // blocks for them is worse than saying which ones will not
              // hold.
              onPressed: ok
                  ? () {
                      AudioService.instance.sfx('click');
                      widget.ctrl.commitBuild();
                    }
                  : null,
          ),
        ],
      ),
    );
  }

  Widget _swatch(MaterialDef def) {
    final on = widget.selected == def.kind;
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx('click');
        widget.onSelect(def.kind);
      },
      child: Container(
        width: 76,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: RT.card(
          color: on ? RT.cream : RT.cream.withOpacity(0.55),
          radius: 12,
          border: on ? 4 : 2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 20,
              decoration: BoxDecoration(
                color: def.color,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: def.shade, width: 2),
              ),
            ),
            const SizedBox(height: 4),
            Text(def.name,
                style: RT.chunky(size: 10, color: RT.ink),
                textAlign: TextAlign.center),
            // Cost and toughness together: the whole decision is the ratio
            // between them, and splitting them would hide it.
            Text('${def.cost}c · ${def.hp.round()}hp',
                style: RT.body(
                    size: 9,
                    color: RT.ink.withOpacity(0.65),
                    weight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}
