import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../game/audio.dart';
import '../game/controller.dart';
import '../game/maps.dart';
import '../game/models.dart';
import '../game/physics.dart';
import '../game/renderer.dart';
import '../game/save.dart';
import '../theme.dart';

class GameScreen extends StatefulWidget {
  final MatchSettings settings;
  final List<PlayerConfig> players;
  final GameMode mode;
  final int? seed;
  final bool skipBuildPhase;
  final GameController? controller;

  const GameScreen({
    super.key,
    required this.settings,
    required this.players,
    required this.mode,
    this.seed,
    this.skipBuildPhase = false,
    this.controller,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late GameController ctrl;
  late WorldRenderer renderer;

  // gesture state
  Offset? _dragStart;
  double _startAngle = 0;
  double _startPower = 0.6;
  bool _charging = false;

  // building state
  PieceDef _selectedPiece = PieceDef.catalogue.first;
  Offset? _ghostPos;
  double _ghostRot = 0;
  bool _rotating = false;

  @override
  void initState() {
    super.initState();
    AudioService.instance.playMusic('music_battle');
    ctrl = widget.controller ??
        GameController(
          settings: widget.settings,
          players: widget.players,
          mode: widget.mode,
          seed: widget.seed,
          skipBuildPhase: widget.skipBuildPhase,
        );
    renderer = WorldRenderer(
      ctrl.world,
      map: ctrl.settings.map,
      charColors: widget.players.map((p) => RT.playerColors[p.colorIndex % RT.playerColors.length]).toList(),
      charHats: widget.players.map((p) => p.hatIndex).toList(),
    );
    ctrl.addListener(_onUpdate);
  }

  void _onUpdate() {
    if (ctrl.phase == GamePhase.firing || ctrl.phase == GamePhase.settling) {
      // rebind renderer world (world object persists but be safe)
      renderer = WorldRenderer(
        ctrl.world,
        map: ctrl.settings.map,
        charColors: widget.players.map((p) => RT.playerColors[p.colorIndex % RT.playerColors.length]).toList(),
        charHats: widget.players.map((p) => p.hatIndex).toList(),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      ctrl.dispose();
    } else {
      ctrl.removeListener(_onUpdate);
    }
    AudioService.instance.playMusic('music_menu');
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Input handling
  // ---------------------------------------------------------------------------

  void _onPanStart(DragStartDetails d) {
    if (ctrl.phase == GamePhase.building && ctrl.canHumanBuild) {
      _ghostPos = _toWorld(d.localPosition);
      return;
    }
    if (!ctrl.canHumanAct) return;
    _dragStart = d.localPosition;
    _startAngle = ctrl.aimAngle;
    _startPower = ctrl.aimPower;
    _charging = true;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (ctrl.phase == GamePhase.building && ctrl.canHumanBuild) {
      setState(() => _ghostPos = _toWorld(d.localPosition));
      return;
    }
    if (!ctrl.canHumanAct || _dragStart == null) return;
    final sens = SaveService.instance.data.sensitivity;
    final delta = (d.localPosition - _dragStart!) / ctrl.camZoom;
    // horizontal drag -> angle, vertical drag -> power
    final me = ctrl.world.charactersOf(ctrl.currentPlayer);
    if (me.isEmpty) return;
    final facingLeft = _enemiesOf(ctrl.currentPlayer).isNotEmpty &&
        _enemiesOf(ctrl.currentPlayer).first.pos.dx < me.first.pos.dx;

    double newAngle = _startAngle - delta.dx * 0.006 * sens;
    double newPower = (_startPower - delta.dy * 0.004 * sens).clamp(0.1, 1.0);

    // constrain angle to upper hemisphere facing enemies
    if (facingLeft) {
      newAngle = newAngle.clamp(pi * 0.5, pi * 0.98);
      if (newAngle > pi * 0.5 && newAngle < pi * 0.55) newAngle = pi * 0.55;
    } else {
      newAngle = newAngle.clamp(-pi * 0.98, -pi * 0.02);
    }
    setState(() {
      ctrl.aimAngle = newAngle;
      ctrl.aimPower = newPower;
    });
  }

  void _onPanEnd(DragEndDetails d) {
    _charging = false;
    _dragStart = null;
  }

  List<PhysBody> _enemiesOf(int player) {
    final list = <PhysBody>[];
    for (int i = 0; i < ctrl.players.length; i++) {
      if (i != player) list.addAll(ctrl.world.charactersOf(i));
    }
    return list;
  }

  Offset _toWorld(Offset local) {
    final size = MediaQuery.of(context).size;
    return (local - Offset(size.width / 2, size.height / 2)) / ctrl.camZoom + ctrl.camPos;
  }

  void _placeGhost() {
    if (_ghostPos == null) return;
    final ok = ctrl.placeBuildingPiece(_ghostPos!.dx, _ghostPos!.dy, _ghostRot, _selectedPiece);
    if (ok) {
      if (SaveService.instance.data.vibration) HapticFeedback.mediumImpact();
      setState(() => _ghostPos = null);
    } else {
      AudioService.instance.sfx('bounce');
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: widget.settings.map.sky,
          ),
        ),
        child: GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: Stack(
            children: [
              // world
              Positioned.fill(
                child: CustomPaint(
                  painter: _GamePainter(ctrl, renderer),
                ),
              ),
              // building ghost
              if (ctrl.phase == GamePhase.building && ctrl.canHumanBuild && _ghostPos != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GhostPainter(ctrl, _selectedPiece, _ghostPos!, _ghostRot),
                  ),
                ),
              // aim indicator
              if (ctrl.phase == GamePhase.aiming && ctrl.world.charactersOf(ctrl.currentPlayer).isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _AimPainter(ctrl),
                  ),
                ),
              // HUD
              SafeArea(child: _buildHud()),
              // building UI
              if (ctrl.phase == GamePhase.building) SafeArea(child: _buildBuildUi()),
              // turn transition overlay
              if (ctrl.phase == GamePhase.turnTransition) _buildTransition(),
              // game over
              if (ctrl.phase == GamePhase.gameOver) _buildGameOver(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHud() {
    return Column(
      children: [
        // top bar: player health cards + wind + timer
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              _pauseBtn(),
              const SizedBox(width: 8),
              Expanded(child: _playerCards()),
              const SizedBox(width: 8),
              _windIndicator(),
            ],
          ),
        ),
        const Spacer(),
        // status message
        if (ctrl.statusMessage.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: RT.card(color: RT.ink.withOpacity(0.75), radius: 20, border: 0),
            child: Text(ctrl.statusMessage, style: RT.chunky(size: 15, color: Colors.white)),
          ),
        // bottom controls (aiming phase only)
        if (ctrl.phase == GamePhase.aiming && ctrl.canHumanAct) _buildControls(),
        if (ctrl.phase == GamePhase.aiming && !ctrl.canHumanAct)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: RT.card(color: Colors.white, radius: 16, border: 3),
              child: Text(
                ctrl.players[ctrl.currentPlayer].isAi ? '🤖 ${ctrl.players[ctrl.currentPlayer].name} is thinking…' : "Opponent's turn…",
                style: RT.chunky(size: 14, color: RT.ink),
              ),
            ),
          ),
      ],
    );
  }

  Widget _pauseBtn() {
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx('click');
        _showPauseMenu();
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: RT.card(color: Colors.white, radius: 12, border: 3),
        child: const Icon(Icons.pause, color: RT.ink, size: 22),
      ),
    );
  }

  Widget _playerCards() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (int i = 0; i < ctrl.players.length; i++)
          Expanded(child: _playerCard(i)),
      ],
    );
  }

  Widget _playerCard(int i) {
    final p = ctrl.players[i];
    final chars = ctrl.world.charactersOf(i);
    final total = chars.fold<double>(0, (s, c) => s + max(0, c.hp));
    final maxTotal = ctrl.settings.startHp * max(1, chars.length);
    final frac = (total / max(maxTotal, 1)).clamp(0.0, 1.0);
    final active = i == ctrl.currentPlayer && ctrl.phase == GamePhase.aiming;
    final eliminated = chars.isEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: RT.card(
        color: eliminated ? Colors.grey.shade400 : (active ? RT.yellow : Colors.white),
        radius: 12,
        border: active ? 4 : 3,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: RT.playerColors[p.colorIndex % 4]),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  p.name,
                  overflow: TextOverflow.ellipsis,
                  style: RT.chunky(size: 11, color: RT.ink),
                ),
              ),
              if (active)
                Text('${ctrl.turnTimeLeft.ceil()}s', style: RT.chunky(size: 11, color: RT.red)),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 8,
              backgroundColor: RT.ink.withOpacity(0.2),
              valueColor: AlwaysStoppedAnimation(frac > 0.5 ? RT.green : frac > 0.25 ? RT.orange : RT.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _windIndicator() {
    final w = ctrl.wind;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: RT.card(color: Colors.white, radius: 12, border: 3),
      child: Row(
        children: [
          Icon(w.abs() < 0.05 ? Icons.air : (w > 0 ? Icons.east : Icons.west),
              size: 18, color: RT.blue),
          const SizedBox(width: 4),
          Text(w.abs() < 0.05 ? '—' : '${(w.abs() * 10).round()}',
              style: RT.chunky(size: 12, color: RT.ink)),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final weapons = ctrl.availableWeapons;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          // weapon wheel
          SizedBox(
            height: 64,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: weapons.length,
              itemBuilder: (_, i) {
                final w = weapons[i];
                final sel = ctrl.selectedWeaponId == w.id;
                return GestureDetector(
                  onTap: () {
                    AudioService.instance.sfx('click');
                    setState(() => ctrl.selectedWeaponId = w.id);
                  },
                  child: Container(
                    width: 56,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: RT.card(color: sel ? w.color : Colors.white, radius: 14, border: sel ? 4 : 3),
                    child: Icon(w.icon, color: sel ? Colors.white : w.color, size: 26),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // power meter
              _powerMeter(),
              // camera controls
              Column(
                children: [
                  _miniBtn(Icons.add, () => setState(() => ctrl.zoomCamera(0.12))),
                  const SizedBox(height: 6),
                  _miniBtn(Icons.remove, () => setState(() => ctrl.zoomCamera(-0.12))),
                  const SizedBox(height: 6),
                  _miniBtn(Icons.my_location, () => setState(() => ctrl.resetCameraToPlayer())),
                ],
              ),
              // FIRE button
              _fireButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _powerMeter() {
    return Column(
      children: [
        Text('POWER', style: RT.chunky(size: 11, color: Colors.white, outline: 2)),
        const SizedBox(height: 4),
        Container(
          width: 150,
          height: 26,
          decoration: RT.card(color: Colors.white, radius: 13, border: 3),
          child: Stack(
            children: [
              FractionallySizedBox(
                widthFactor: ctrl.aimPower,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(colors: [RT.green, RT.yellow, RT.red]),
                  ),
                ),
              ),
              Center(
                child: Text('${(ctrl.aimPower * 100).round()}%',
                    style: RT.chunky(size: 12, color: RT.ink)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text('↔ aim  ↕ power', style: RT.chunky(size: 10, color: Colors.white70)),
      ],
    );
  }

  Widget _miniBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx('click');
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: RT.card(color: Colors.white, radius: 10, border: 3),
        child: Icon(icon, size: 18, color: RT.ink),
      ),
    );
  }

  Widget _fireButton() {
    return GestureDetector(
      onTap: () {
        if (SaveService.instance.data.vibration) HapticFeedback.heavyImpact();
        ctrl.humanFire();
      },
      child: Container(
        width: 86,
        height: 86,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: RT.red,
          border: Border.all(color: RT.ink, width: 5),
          boxShadow: const [BoxShadow(color: Color(0xFF9E1B32), offset: Offset(0, 6))],
        ),
        child: Center(
          child: Text('FIRE!', style: RT.chunky(size: 20, color: Colors.white, outline: 2.5)),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Building UI
  // ---------------------------------------------------------------------------

  Widget _buildBuildUi() {
    final me = ctrl.buildingPlayerConfig;
    return Column(
      children: [
        const Spacer(),
        if (ctrl.canHumanBuild) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: RT.card(color: RT.ink.withOpacity(0.75), radius: 18, border: 0),
            child: Text(
              '${me.name} — place ${ctrl.piecesLeft} pieces! Tap to place, ⟳ to rotate',
              style: RT.chunky(size: 13, color: Colors.white),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // piece palette
                Expanded(
                  child: SizedBox(
                    height: 74,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: PieceDef.catalogue.length,
                      itemBuilder: (_, i) {
                        final p = PieceDef.catalogue[i];
                        final sel = _selectedPiece.id == p.id;
                        return GestureDetector(
                          onTap: () {
                            AudioService.instance.sfx('click');
                            setState(() {
                              _selectedPiece = p;
                              _ghostRot = 0;
                            });
                          },
                          child: Container(
                            width: 62,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: RT.card(color: sel ? RT.orange : Colors.white, radius: 12, border: sel ? 4 : 3),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(p.icon, size: 22, color: sel ? Colors.white : RT.ink),
                                Text(p.name.split(' ').first,
                                    style: RT.chunky(size: 9, color: sel ? Colors.white : RT.ink),
                                    overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Column(
                  children: [
                    _miniBtn(Icons.rotate_right, () => setState(() => _ghostRot += pi / 4)),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: _placeGhost,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: RT.card(color: RT.green, radius: 12, border: 3),
                        child: const Icon(Icons.check, color: Colors.white, size: 22),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    AudioService.instance.sfx('click');
                    ctrl.finishBuilding();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: RT.card(color: RT.red, radius: 12, border: 3),
                    child: Text('DONE', style: RT.chunky(size: 15, color: Colors.white, outline: 2)),
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: RT.card(color: Colors.white, radius: 16, border: 3),
              child: Text('${me.name} is building…', style: RT.chunky(size: 14, color: RT.ink)),
            ),
          ),
      ],
    );
  }

  Widget _buildTransition() {
    final next = ctrl.players[(ctrl.currentPlayer + 1) % ctrl.players.length];
    return Container(
      color: Colors.black.withOpacity(0.75),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 240, height: 180,
              child: CustomPaint(painter: StarburstPainter(color: RT.yellow, points: 14)),
            ),
            Transform.translate(
              offset: const Offset(0, -140),
              child: Column(
                children: [
                  Text('NEXT UP!', style: RT.chunky(size: 30, color: RT.red, outline: 4)),
                  Text(next.name, style: RT.chunky(size: 34, color: Colors.white, outline: 4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGameOver() {
    final won = ctrl.winner == 0 && !ctrl.players[0].isAi;
    return Container(
      color: Colors.black.withOpacity(0.7),
      child: Center(
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(24),
          decoration: RT.card(color: RT.cream, radius: 26, border: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 180, height: 120,
                child: CustomPaint(painter: StarburstPainter(color: won ? RT.yellow : Colors.grey, points: 14)),
              ),
              Transform.translate(
                offset: const Offset(0, -95),
                child: Icon(won ? Icons.emoji_events : Icons.sentiment_dissatisfied,
                    size: 60, color: won ? RT.orange : RT.ink),
              ),
              Transform.translate(
                offset: const Offset(0, -30),
                child: Column(
                  children: [
                    Text(ctrl.statusMessage, style: RT.chunky(size: 28, color: won ? RT.orange : RT.ink), textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text('Rounds: ${ctrl.round}  •  Damage: ${ctrl.damageDealtByHuman}',
                        style: RT.chunky(size: 13, color: RT.ink.withOpacity(0.7))),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ChunkyButton(
                label: 'REMATCH', icon: Icons.refresh, color: RT.green, width: 220, height: 52, fontSize: 18,
                onPressed: () {
                  AudioService.instance.sfx('click');
                  ctrl.resetMatch();
                },
              ),
              const SizedBox(height: 10),
              ChunkyButton(
                label: 'MAIN MENU', icon: Icons.home, color: RT.blue, width: 220, height: 52, fontSize: 18,
                onPressed: () {
                  AudioService.instance.sfx('click');
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPauseMenu() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: RT.cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: RT.ink, width: 4)),
        title: Text('PAUSED', style: RT.chunky(size: 26, color: RT.ink), textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChunkyButton(
              label: 'RESUME', icon: Icons.play_arrow, color: RT.green, width: 200, height: 50, fontSize: 17,
              onPressed: () {
                AudioService.instance.sfx('click');
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 10),
            ChunkyButton(
              label: 'RESTART', icon: Icons.refresh, color: RT.orange, width: 200, height: 50, fontSize: 17,
              onPressed: () {
                AudioService.instance.sfx('click');
                Navigator.pop(context);
                ctrl.resetMatch();
              },
            ),
            const SizedBox(height: 10),
            ChunkyButton(
              label: 'QUIT', icon: Icons.exit_to_app, color: RT.red, width: 200, height: 50, fontSize: 17,
              onPressed: () {
                AudioService.instance.sfx('click');
                Navigator.pop(context);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Painters
// =============================================================================

class _GamePainter extends CustomPainter {
  final GameController ctrl;
  final WorldRenderer renderer;
  _GamePainter(this.ctrl, this.renderer);

  @override
  void paint(Canvas canvas, Size size) {
    renderer.render(canvas, size, ctrl.camPos, ctrl.camZoom, ctrl.time);
  }

  @override
  bool shouldRepaint(covariant _GamePainter old) => true;
}

class _AimPainter extends CustomPainter {
  final GameController ctrl;
  _AimPainter(this.ctrl);

  @override
  void paint(Canvas canvas, Size size) {
    final chars = ctrl.world.charactersOf(ctrl.currentPlayer);
    if (chars.isEmpty) return;
    final me = chars.first;
    final showTrajectory = SaveService.instance.data.showTrajectory;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(ctrl.camZoom);
    canvas.translate(-ctrl.camPos.dx, -ctrl.camPos.dy);

    final weapon = Weapons.byId(ctrl.selectedWeaponId);
    final from = ctrl.muzzlePos;

    // aim arrow
    final dir = Offset(cos(ctrl.aimAngle), sin(ctrl.aimAngle));
    final arrowEnd = from + dir * 60;
    final paint = Paint()
      ..color = weapon.color
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(from, arrowEnd, paint);
    canvas.drawLine(from, arrowEnd, Paint()..color = RT.ink..strokeWidth = 8..strokeCap = StrokeCap.round..blendMode = BlendMode.dstOver);
    // arrowhead
    canvas.drawCircle(arrowEnd, 7, Paint()..color = RT.ink);
    canvas.drawCircle(arrowEnd, 5, Paint()..color = weapon.color);

    // trajectory preview (dotted)
    if (showTrajectory) {
      var pos = from;
      final speed = weapon.speed * (280 + ctrl.aimPower * 620);
      var vel = dir * speed;
      const dt = 1 / 20;
      final dotPaint = Paint()..color = Colors.white.withOpacity(0.85);
      for (int i = 0; i < 16; i++) {
        vel += Offset(ctrl.world.wind * 260, ctrl.world.gravity * weapon.gravity) * dt;
        pos += vel * dt;
        if (pos.dy > ctrl.world.waterLevel) break;
        canvas.drawCircle(pos, max(2.0, 4.5 - i * 0.18), dotPaint);
        // stop if hit something
        var hit = false;
        for (final b in ctrl.world.bodies) {
          if (b.dead || b.type == BodyType.debris) continue;
          if (b.aabb.contains(pos)) { hit = true; break; }
        }
        if (hit) break;
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AimPainter old) => true;
}

class _GhostPainter extends CustomPainter {
  final GameController ctrl;
  final PieceDef piece;
  final Offset pos;
  final double rot;
  _GhostPainter(this.ctrl, this.piece, this.pos, this.rot);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(ctrl.camZoom);
    canvas.translate(-ctrl.camPos.dx, -ctrl.camPos.dy);

    // build area
    final area = ctrl.buildAreaFor(ctrl.buildingPlayer);
    canvas.drawRect(area, Paint()..color = RT.green.withOpacity(0.12));
    canvas.drawRect(
        area,
        Paint()
          ..color = RT.green.withOpacity(0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);

    // ghost piece
    final valid = area.contains(pos);
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.rotate(rot);
    final rect = Rect.fromCenter(center: Offset.zero, width: piece.size.width, height: piece.size.height);
    canvas.drawRect(rect, Paint()..color = (valid ? RT.green : RT.red).withOpacity(0.5));
    canvas.drawRect(
        rect,
        Paint()
          ..color = valid ? RT.green : RT.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GhostPainter old) => true;
}
