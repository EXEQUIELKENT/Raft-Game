import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/audio.dart';
import '../game/battle.dart';
import '../game/campaign.dart';
import '../game/controller.dart';
import '../game/models.dart';
import '../game/renderer.dart';
import '../game/save.dart';
import '../theme.dart';

class GameScreen extends StatefulWidget {
  final MatchSettings settings;
  final List<PlayerConfig> players;
  final GameMode mode;
  final int? seed;
  final GameController? controller;

  /// When set, this match is a campaign battle: the result panel shows
  /// stars/doubloons earned and campaign navigation instead of the generic
  /// rematch buttons, and a win is recorded exactly once.
  final CampaignLevel? campaignLevel;

  const GameScreen({
    super.key,
    required this.settings,
    required this.players,
    required this.mode,
    this.seed,
    this.controller,
    this.campaignLevel,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late GameController ctrl;
  late WorldRenderer renderer;

  // ---------------------------------------------------------------------------
  // Pull-back aiming.
  //
  // Raw Listener pointer events rather than a GestureDetector: a pan
  // recognizer waits for the pointer to cross Flutter's ~18px slop before it
  // reports anything, which reads as lag on a gesture that should feel like a
  // direct slingshot pull. The design's own dead zone (16 world units) is the
  // only threshold left.
  // ---------------------------------------------------------------------------
  Offset? _dragOrigin;
  Offset? _dragCurrent;
  bool _charging = false;
  int? _activePointerId;

  /// Widgets that own their own taps and must not also drive aiming.
  final GlobalKey _weaponBarKey = GlobalKey();
  final GlobalKey _nudgeBarKey = GlobalKey();
  final GlobalKey _topBarKey = GlobalKey();

  /// Desktop only: the battle is driven by a pull-back drag, which a mouse
  /// can do perfectly well, but aiming to the nearest degree with a mouse is
  /// miserable. These keys drive the same nudge buttons the touch HUD uses.
  final FocusNode _keyFocus = FocusNode();

  // HUD rebuild throttling: the world canvas repaints every tick on its own,
  // but the surrounding HUD has no reason to rebuild 60x a second when nothing
  // it displays has changed.
  GamePhase? _lastPhase;
  int _lastPlayer = -1;
  int _lastTurnSec = -1;
  String _lastStatus = '';
  int? _lastWinner;
  int _lastAngle = -1;
  int _lastPower = -1;
  String _lastWeapon = '';
  List<int> _lastHp = const [];

  int? _campaignStars;
  int? _campaignReward;

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
        );
    renderer = WorldRenderer(ctrl.world, map: ctrl.settings.map);
    ctrl.addListener(_onUpdate);
  }

  @override
  void dispose() {
    _keyFocus.dispose();
    if (widget.controller == null) {
      ctrl.dispose();
    } else {
      ctrl.removeListener(_onUpdate);
    }
    AudioService.instance.playMusic('music_menu');
    super.dispose();
  }

  /// Keyboard play, for the desktop build. A mouse can already perform the
  /// pull-back drag (it is the same pointer stream), so this only covers what
  /// a mouse does badly: single-degree aiming, and firing without dragging.
  void _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    const fine = 1.0;
    const coarse = 5.0;
    final step = HardwareKeyboard.instance.isShiftPressed ? coarse : fine;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.keyW:
        ctrl.nudgeAngle(step);
        return;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.keyS:
        ctrl.nudgeAngle(-step);
        return;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyD:
        ctrl.nudgePower(step);
        return;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyA:
        ctrl.nudgePower(-step);
        return;
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.enter:
        if (ctrl.phase == GamePhase.gameOver) {
          _rematch();
        } else {
          ctrl.humanFire();
        }
        return;
      case LogicalKeyboardKey.keyR:
        if (ctrl.phase == GamePhase.gameOver) _rematch();
        return;
      case LogicalKeyboardKey.escape:
        Navigator.pop(context);
        return;
      default:
        // 1..5 pick a weapon, matching the HUD order.
        final label = event.logicalKey.keyLabel;
        if (label.length == 1 && label.codeUnitAt(0) >= 0x31 && label.codeUnitAt(0) <= 0x35) {
          final i = int.parse(label) - 1;
          final weapons = ctrl.availableWeapons;
          if (i < weapons.length) setState(() => ctrl.selectWeapon(weapons[i].id));
        }
    }
  }

  void _rematch() {
    AudioService.instance.sfx('click');
    setState(() {
      _campaignStars = null;
      _campaignReward = null;
    });
    // Over a hotspot link both devices have to land on the same world, so
    // the rematch is negotiated rather than just local.
    ctrl.requestRematch();
  }

  void _onUpdate() {
    if (!mounted) return;
    final hp = [for (final r in ctrl.world.rafts) r.hp.round()];
    var hpChanged = hp.length != _lastHp.length;
    if (!hpChanged) {
      for (int i = 0; i < hp.length; i++) {
        if (hp[i] != _lastHp[i]) {
          hpChanged = true;
          break;
        }
      }
    }
    final turnSec = ctrl.turnTimeLeft.ceil();
    final angle = ctrl.aimAngle.round();
    final power = ctrl.aimPower.round();
    final enteringGameOver = _lastPhase != GamePhase.gameOver && ctrl.phase == GamePhase.gameOver;

    final dirty = _lastPhase != ctrl.phase ||
        _lastPlayer != ctrl.currentPlayer ||
        _lastTurnSec != turnSec ||
        _lastStatus != ctrl.statusMessage ||
        _lastWinner != ctrl.winner ||
        _lastAngle != angle ||
        _lastPower != power ||
        _lastWeapon != ctrl.selectedWeaponId ||
        _charging ||
        hpChanged;

    if (dirty) {
      _lastPhase = ctrl.phase;
      _lastPlayer = ctrl.currentPlayer;
      _lastTurnSec = turnSec;
      _lastStatus = ctrl.statusMessage;
      _lastWinner = ctrl.winner;
      _lastAngle = angle;
      _lastPower = power;
      _lastWeapon = ctrl.selectedWeaponId;
      _lastHp = hp;
      setState(() {});
    }
    if (enteringGameOver && widget.campaignLevel != null) _recordCampaignResult();
  }

  void _recordCampaignResult() {
    final level = widget.campaignLevel;
    if (level == null || ctrl.winner != 0) return; // only victories earn stars
    final me = ctrl.world.raftOf(0);
    final frac = me?.hpFrac ?? 0.0;
    final stars = Campaign.starsForHpFraction(frac);
    final reward = SaveService.instance.recordCampaignLevel(level: level, stars: stars);
    if (!mounted) return;
    setState(() {
      _campaignStars = stars;
      _campaignReward = reward;
    });
  }

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------

  List<Rect> _excludedRects() {
    final rects = <Rect>[];
    for (final key in [_weaponBarKey, _nudgeBarKey, _topBarKey]) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      rects.add(box.localToGlobal(Offset.zero) & box.size);
    }
    return rects;
  }

  void _onPointerDown(PointerDownEvent e) {
    if (_activePointerId != null) return;
    for (final rect in _excludedRects()) {
      if (rect.contains(e.position)) return;
    }
    if (!ctrl.canHumanAct) return;
    _activePointerId = e.pointer;
    setState(() {
      _dragOrigin = e.localPosition;
      _dragCurrent = e.localPosition;
      _charging = true;
      ctrl.isCharging = true;
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _activePointerId || !_charging) return;
    _dragCurrent = e.localPosition;
    final origin = _dragOrigin;
    if (origin == null) return;
    // Slingshot pull, measured against the shooter's facing: dragging *away*
    // from the direction of fire builds power, and dragging down lifts the
    // arc. A raft firing left is mirrored so the gesture feels identical from
    // either side.
    final facing = ctrl.currentRaft?.facing ?? 1;
    final pullBack = (origin.dx - e.localPosition.dx) * facing;
    final pullDown = e.localPosition.dy - origin.dy;
    ctrl.applyPullAim(pullBack, pullDown);
    // Force a repaint so the readout circle, angle chip and trajectory dots
    // all move with the finger. Without this they lag a frame behind the
    // gesture and feel "stuck" until the controller's notifyListeners fires.
    setState(() {});
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _activePointerId) return;
    _activePointerId = null;
    final origin = _dragOrigin;
    final current = _dragCurrent;
    final wasCharging = _charging;
    setState(() {
      _charging = false;
      ctrl.isCharging = false;
      _dragOrigin = null;
      _dragCurrent = null;
    });
    if (!wasCharging || origin == null || current == null) return;
    // Only a deliberate pull past the dead zone fires — a stray tap never does.
    if ((current - origin).distance < BattleConst.deadzone) return;
    if (SaveService.instance.data.vibration) HapticFeedback.heavyImpact();
    ctrl.humanFire();
  }

  /// A gesture the OS interrupts mid-drag must not fire — reset cleanly.
  void _onPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _activePointerId) return;
    _activePointerId = null;
    setState(() {
      _charging = false;
      ctrl.isCharging = false;
      _dragOrigin = null;
      _dragCurrent = null;
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _keyFocus,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        body: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: ctrl,
                  builder: (_, __) => CustomPaint(painter: _ScenePainter(ctrl, renderer)),
                ),
              ),
              SafeArea(child: _buildHud()),
              if (_charging && _dragCurrent != null) _pullReadout(),
              if (ctrl.phase == GamePhase.gameOver) _buildResult(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHud() {
    return Column(
      children: [
        _topBar(),
        if (ctrl.offscreenFoes > 0)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 22, top: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: RT.pill(color: RT.ink, opacity: 0.6, radius: 12),
                child: Text('${ctrl.offscreenFoes} FOE OVER THE HORIZON ▸',
                    style: RT.body(size: 11, color: Colors.white, weight: FontWeight.w800)),
              ),
            ),
          ),
        const Spacer(),
        _bottomBar(),
      ],
    );
  }

  Widget _topBar() {
    final save = SaveService.instance.data;
    final me = ctrl.world.raftOf(ctrl.localPlayerIndex);
    return Padding(
      key: _topBarKey,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _roundBtn('‹', () => Navigator.pop(context), size: 40),
          const SizedBox(width: 10),
          // Player health
          Container(
            width: 210,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: RT.pill(opacity: 0.8, radius: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('YOUR RAFT',
                        style: RT.body(size: 10, color: RT.ink, weight: FontWeight.w800, letterSpacing: 1.2)),
                    Text('${(me?.hp ?? 0).round()}',
                        style: RT.body(size: 10, color: RT.ink, weight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: me?.hpFrac ?? 0,
                    minHeight: 9,
                    backgroundColor: RT.ink.withOpacity(0.14),
                    valueColor: AlwaysStoppedAnimation(
                      (me?.hpFrac ?? 0) > 0.5 ? RT.green : ((me?.hpFrac ?? 0) > 0.25 ? RT.orange : RT.red),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          _infoChip('ANGLE ${ctrl.aimAngle.round()}° · PWR ${ctrl.aimPower.round()}%'),
          const SizedBox(width: 8),
          _infoChip('${_levelLabel()} · ${ctrl.foesLeft} CREW LEFT'),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: RT.pill(color: RT.yellow, opacity: 1, radius: 13),
            child: Text('◉ ${save.doubloons}',
                style: RT.body(size: 12, color: const Color(0xFF6B4A00), weight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  String _levelLabel() {
    final lv = widget.campaignLevel;
    return lv == null ? 'QUICK' : 'LV ${lv.indexInWorld + 1}';
  }

  Widget _infoChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: RT.pill(opacity: 0.82, radius: 13),
        child: Text(text, style: RT.body(size: 12, color: RT.ink, weight: FontWeight.w800)),
      );

  Widget _bottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _weaponBar(),
          const Spacer(),
          _nudgeBar(),
        ],
      ),
    );
  }

  Widget _weaponBar() {
    final weapons = ctrl.availableWeapons;
    return Row(
      key: _weaponBarKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final w in weapons) ...[
          _weaponChip(w),
          const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _weaponChip(WeaponDef w) {
    final selected = ctrl.selectedWeaponId == w.id;
    final count = ctrl.ammoFor(w.id);
    final label = count < 0 ? '×∞' : '×$count';
    final enabled = count != 0;
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx(enabled ? 'click' : 'bounce');
        if (enabled) setState(() => ctrl.selectWeapon(w.id));
      },
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: selected
              ? RT.card(color: RT.orange, radius: 16, border: 0)
              : RT.pill(opacity: 0.9, radius: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(color: w.color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(w.chipLabel,
                      style: RT.body(
                          size: 10,
                          color: selected ? Colors.white : RT.ink,
                          weight: FontWeight.w800,
                          letterSpacing: 0.8)),
                  Text(label,
                      style: RT.body(
                          size: 11,
                          color: (selected ? Colors.white : RT.ink).withOpacity(0.78),
                          weight: FontWeight.w800)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nudgeBar() {
    return Row(
      key: _nudgeBarKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        _roundBtn('▾', () => ctrl.nudgeAngle(-1)),
        const SizedBox(width: 6),
        _roundBtn('▴', () => ctrl.nudgeAngle(1)),
        const SizedBox(width: 6),
        _roundBtn('−', () => ctrl.nudgePower(-1)),
        const SizedBox(width: 6),
        _roundBtn('+', () => ctrl.nudgePower(1)),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: RT.pill(color: RT.ink, opacity: 0.58, radius: 16),
          child: Text(
            ctrl.statusMessage.isEmpty ? 'Pull back and release' : ctrl.statusMessage,
            style: RT.body(size: 13, color: Colors.white, weight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  Widget _roundBtn(String glyph, VoidCallback onTap, {double size = 36}) {
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx('click');
        onTap();
        setState(() {});
      },
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: RT.pill(opacity: 0.85, radius: 12),
        child: Text(glyph, style: RT.chunky(size: size * 0.42, color: RT.ink)),
      ),
    );
  }

  /// The design's radial pull readout, drawn at the finger while dragging.
  Widget _pullReadout() {
    final p = _dragCurrent!;
    return Positioned(
      left: p.dx - 75,
      top: p.dy - 75,
      child: IgnorePointer(
        child: Container(
          width: 150,
          height: 150,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF0D3C46).withOpacity(0.16),
            border: Border.all(color: Colors.white.withOpacity(0.45), width: 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${ctrl.aimPower.round()}%',
                  style: RT.chunky(size: 26, color: Colors.white)),
              Text('${ctrl.aimAngle.round()}°',
                  style: RT.body(size: 11, color: Colors.white, weight: FontWeight.w800, letterSpacing: 1.4)),
              const SizedBox(height: 4),
              Container(
                width: 76,
                height: 6,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: (ctrl.aimPower / 100).clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: RT.yellow,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(ctrl.aimFine ? 'FINE TUNE' : 'PULL FURTHER',
                  style: RT.body(size: 9, color: Colors.white.withOpacity(0.75), weight: FontWeight.w800, letterSpacing: 1.2)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Result panel
  // ---------------------------------------------------------------------------

  Widget _buildResult() {
    final seat = ctrl.localPlayerIndex;
    final won = ctrl.winner == seat && !ctrl.players[seat].isAi;
    final level = widget.campaignLevel;
    final kicker = level != null
        ? (won ? 'BATTLE ${level.indexInWorld + 1} CLEARED' : 'RAFT SUNK')
        : (won ? 'VICTORY' : 'DEFEAT');
    final title = level != null
        ? (won ? '${level.captainName} defeated!' : 'Sunk by ${level.captainName}')
        : (won ? 'You rule the water' : 'Bail out and retry');
    final showReward = level != null && won && _campaignReward != null;

    return Container(
      color: Colors.black.withOpacity(0.72),
      child: Center(
        child: Container(
          width: 360,
          padding: const EdgeInsets.fromLTRB(26, 24, 26, 22),
          decoration: RT.card(color: Colors.white, radius: 28, border: 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(won ? Icons.emoji_events : Icons.sentiment_dissatisfied,
                  size: 42, color: won ? RT.orange : RT.ink.withOpacity(0.35)),
              const SizedBox(height: 8),
              Text(kicker,
                  style: RT.body(size: 11, color: RT.ink.withOpacity(0.5), weight: FontWeight.w800, letterSpacing: 3)),
              const SizedBox(height: 4),
              Text(title, style: RT.chunky(size: 22, color: RT.ink), textAlign: TextAlign.center),
              if (level != null && won) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < 3; i++)
                      Icon(i < (_campaignStars ?? 0) ? Icons.star : Icons.star_border,
                          color: RT.yellow, size: 28),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _statTile('${ctrl.shotsFired}', 'SHOTS')),
                  const SizedBox(width: 10),
                  Expanded(child: _statTile(ctrl.accuracyLabel, 'ACCURACY')),
                  if (showReward) ...[
                    const SizedBox(width: 10),
                    Expanded(child: _statTile('+$_campaignReward', 'COINS', gold: true)),
                  ],
                ],
              ),
              const SizedBox(height: 18),
              if (level != null) ..._campaignButtons(level, won) else ..._quickButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statTile(String value, String label, {bool gold = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: gold ? RT.yellow.withOpacity(0.2) : RT.ink.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(value, style: RT.chunky(size: 20, color: gold ? const Color(0xFF8A6A06) : RT.ink)),
          const SizedBox(height: 2),
          Text(label,
              style: RT.body(
                  size: 9,
                  color: gold ? const Color(0xFFA3872E) : RT.ink.withOpacity(0.55),
                  weight: FontWeight.w800,
                  letterSpacing: 1)),
        ],
      ),
    );
  }

  List<Widget> _quickButtons() => [
        ChunkyButton(
          label: 'REMATCH', icon: Icons.refresh, color: RT.orange, width: 240, height: 52, fontSize: 18,
          onPressed: _rematch,
        ),
        const SizedBox(height: 10),
        ChunkyButton(
          label: 'MAIN MENU', icon: Icons.home, color: RT.blue, width: 240, height: 48, fontSize: 16,
          onPressed: () {
            AudioService.instance.sfx('click');
            Navigator.pop(context);
          },
        ),
      ];

  List<Widget> _campaignButtons(CampaignLevel level, bool won) {
    final all = Campaign.allLevels;
    final idx = all.indexWhere((l) => l.id == level.id);
    final next = won && idx >= 0 && idx + 1 < all.length ? all[idx + 1] : null;
    return [
      if (next != null)
        ChunkyButton(
          label: 'NEXT BATTLE', icon: Icons.arrow_forward, color: RT.orange, width: 240, height: 52, fontSize: 18,
          onPressed: () {
            AudioService.instance.sfx('click');
            final (settings, players) = Campaign.matchFor(next);
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => GameScreen(
                    settings: settings, players: players, mode: GameMode.vsAi, campaignLevel: next),
              ),
            );
          },
        ),
      if (next != null) const SizedBox(height: 10),
      ChunkyButton(
        label: won ? 'REPLAY' : 'TRY AGAIN', icon: Icons.refresh,
        color: next == null ? RT.orange : RT.green, width: 240, height: 48, fontSize: 16,
        onPressed: () {
          AudioService.instance.sfx('click');
          final (settings, players) = Campaign.matchFor(level);
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => GameScreen(
                  settings: settings, players: players, mode: GameMode.vsAi, campaignLevel: level),
            ),
          );
        },
      ),
      const SizedBox(height: 10),
      ChunkyButton(
        label: 'WORLD MAP', icon: Icons.map, color: RT.blue, width: 240, height: 48, fontSize: 16,
        onPressed: () {
          AudioService.instance.sfx('click');
          Navigator.pop(context);
        },
      ),
    ];
  }
}

class _ScenePainter extends CustomPainter {
  final GameController ctrl;
  final WorldRenderer renderer;
  _ScenePainter(this.ctrl, this.renderer);

  @override
  void paint(Canvas canvas, Size size) {
    renderer.render(canvas, size, ctrl.time);

    // Trajectory preview for the human shooter, drawn over the scene.
    if (ctrl.phase != GamePhase.aiming || !ctrl.canHumanAct) return;
    if (!SaveService.instance.data.showTrajectory && !ctrl.isCharging) return;
    final raft = ctrl.currentRaft;
    if (raft == null) return;
    final dots = ctrl.world.trajectory(
      from: raft.muzzle,
      angleDeg: ctrl.aimAngle,
      power: ctrl.aimPower,
      facing: raft.facing,
      weapon: ctrl.selectedWeapon,
      powerMultiplier: ctrl.players[ctrl.currentPlayer].powerMultiplier,
      // The "Spotter Scope" upgrade reveals more of the arc; dragging always
      // shows a longer preview than resting, as in the design.
      limit: SaveService.instance.data.trajectoryDots + (ctrl.isCharging ? 10 : 0),
    );
    renderer.drawTrajectory(canvas, size, dots, charging: ctrl.isCharging);
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) => true;
}
