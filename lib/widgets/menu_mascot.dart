import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../game/battle.dart';
import '../game/characters.dart';
import '../game/maps.dart';
import '../game/models.dart';
import '../game/renderer.dart';
import '../game/save.dart';

/// The character on the main menu: an actual crew member, on an actual raft.
///
/// It has been three things now. First a hand-assembled stack of [Container]s
/// — a bare circle, two floating eyebrow bars, a nose dot, a rectangle body
/// and an orange pill — which resembled nothing in the game. Then a painter
/// that borrowed the roster's [CharacterArt] for the hat and approximated
/// the rest: closer, and still an approximation, with stick arms and no
/// legs, no weapon, no boots, none of the shading the real crew have.
///
/// The third version is the only one that can be right by construction: it
/// builds a one-raft [BattleWorld] and draws it with the same
/// [WorldRenderer] the battle uses, with every layer but the rafts held
/// out. There is no second drawing of a character anywhere, so there is
/// nothing left to drift — the menu shows the crew rig, the hull, the
/// rigging, the equipped firearm and the idle animations exactly as the
/// match does, because it IS the match's renderer.
///
/// Copying [_crewMember] instead was the alternative, and it is thirteen
/// hundred lines of rig, IK, weapon geometry and expression logic. A copy
/// of that would have been wrong within a week.
class MenuMascot extends StatefulWidget {
  /// Whose captain to draw. Defaults to the one the player has equipped,
  /// which is the whole point of it being on the menu; naming one is for
  /// tests and for any screen that wants a specific character.
  final CrewLook? look;

  /// How much of the world to fit across the widget, in world units. The
  /// default frames one raft and its crew.
  final double shownWidth;

  const MenuMascot({super.key, this.look, this.shownWidth = 175});

  @override
  State<MenuMascot> createState() => _MenuMascotState();
}

class _MenuMascotState extends State<MenuMascot>
    with SingleTickerProviderStateMixin {
  late BattleWorld _world;
  late WorldRenderer _renderer;
  late CrewLook _look;
  Ticker? _ticker;
  Duration _last = Duration.zero;
  double _time = 0;

  @override
  void initState() {
    super.initState();
    _build();
    // Vsync-driven, like the battle's own loop: the crew blink, breathe and
    // fidget on the menu exactly as they do on the water.
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0 || dt > 0.25) return;
    _time += dt;
    _world.update(dt);
    setState(() {});
  }

  /// The smallest legal world that still contains a crew member.
  void _build() {
    _look = widget.look ?? Cast.byId(SaveService.instance.data.character).look;
    final save = SaveService.instance.data;
    final map = GameMaps.all.first;
    _world = BattleWorld(map: map, seed: 11);

    final loadout = save.raftLoadout;
    final raft = Raft(
      playerIndex: 0,
      x: BattleConst.playerX,
      loadout: loadout,
      look: _look,
      label: '',
      facing: 1,
      // One, and centred on the deck: a mascot is a portrait, and a row of
      // three would each be a third of the size.
      crew: [Crew(hp: 100, maxHp: 100)],
    );
    // Holding something, because the crew in a match always are, and the
    // hands and stance are built around the weapon they carry.
    raft.crew.first.equipInstant(Weapons.starter.id);
    _world.addRaft(raft);

    _renderer = WorldRenderer(_world, map: map)
      // Only the raft. The menu has its own sky, its own sea and its own
      // clouds behind this already.
      ..skipLayers = const {
        'sky',
        'clouds',
        'props',
        'water',
        'obstacles',
        'shot',
        'effects',
      };
  }

  @override
  void didUpdateWidget(MenuMascot old) {
    super.didUpdateWidget(old);
    if (old.look != widget.look) {
      setState(_build);
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 168,
      height: 158,
      child: CustomPaint(
        painter: _MascotPainter(_renderer, _world, _time, widget.shownWidth),
      ),
    );
  }
}

class _MascotPainter extends CustomPainter {
  final WorldRenderer renderer;
  final BattleWorld world;
  final double time;
  final double shownWidth;

  const _MascotPainter(this.renderer, this.world, this.time, this.shownWidth);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final raft = world.rafts.first;

    // The renderer scales the world's full height to whatever height it is
    // handed, so handing it exactly [BattleConst.worldH] makes its internal
    // scale 1 and leaves it drawing in world units. The framing is then
    // done out here, where it is one zoom and one offset rather than a
    // second coordinate system inside the renderer.
    final zoom = size.width / shownWidth;
    world.cam = raft.x - shownWidth / 2;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // Sit the waterline just below the bottom edge, so the hull is cut off
    // by the frame the way it is cut off by the sea.
    canvas.translate(0, size.height * 0.97 - BattleConst.waterY * zoom);
    canvas.scale(zoom);
    renderer.render(
      canvas,
      Size(shownWidth, BattleConst.worldH),
      time,
      // Not the current shooter: an aiming pose is a character concentrating
      // on something off-screen, which is the wrong thing for a menu.
      currentPlayer: -1,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MascotPainter old) =>
      old.time != time || old.world != world;
}
