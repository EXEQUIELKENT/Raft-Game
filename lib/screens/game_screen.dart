import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/audio.dart';
import '../game/battle.dart';
import '../game/build.dart';
import '../game/campaign.dart';
import '../game/controller.dart';
import '../game/desktop.dart';
import '../game/models.dart';
import '../game/renderer.dart';
import '../game/save.dart';
import '../game/tutorial.dart';
import '../theme.dart';
import '../widgets/build_overlay.dart';

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

  /// The walk pads' own key, so a finger on them never also starts an aim
  /// drag — same exclusion the weapon bar and nudge bar already use.
  final GlobalKey _walkBarKey = GlobalKey();
  final GlobalKey _fireBtnKey = GlobalKey();
  final GlobalKey _topBarKey = GlobalKey();

  /// The build overlay's two bars, for the same exclusion.
  final GlobalKey _buildTopKey = GlobalKey();
  final GlobalKey _buildBottomKey = GlobalKey();

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

  /// Whether the in-match chat panel is expanded. Collapsed by default so
  /// it never covers the deck a player is aiming at.
  bool _chatOpen = false;

  /// The transient message at the top of the screen.
  ///
  /// The status line used to live in a permanent pill in the bottom bar,
  /// which meant it always showed something — even the idle "Pull back and
  /// release" — and it sat in the same row as the nudge buttons, making the
  /// whole right-hand group wide enough to squeeze the weapon bar. It is a
  /// toast now: it appears for real events, fades after a couple of
  /// seconds, and gets out of the way.
  String _toastText = '';

  /// The controller's clock when the toast was raised.
  double _toastStart = 0;

  /// The last status the controller reported, so a change can be told from
  /// a status merely still being current.
  String _seenStatus = '';

  /// Opacity step of the toast, quantised so its fade does not rebuild the
  /// whole HUD sixty times a second.
  int _toastBucket = 0;

  /// Whether the fine-tune nudge buttons are showing. They are hidden by
  /// default: the pull-back drag already sets angle and power, and on a
  /// phone the four buttons were a big chunk of the bottom bar.
  bool _fineTune = false;

  int? _campaignStars;
  int? _campaignReward;

  /// First-run lesson state. Present only when this match was launched as a
  /// tutorial ([MatchSettings.tutorial]): the script the card shows, the
  /// solved hint for the final step, and the first-completion reward once
  /// the practice raft goes down.
  TutorialProgress? _tutorial;
  ({double angle, double power})? _tutorialHint;
  int _tutorialReward = 0;

  /// How many battle screens are currently alive.
  ///
  /// Advancing to the next campaign level is a [Navigator.pushReplacement],
  /// and Flutter builds the incoming route before it disposes the outgoing
  /// one — so the new level's `initState` asked for the battle track and
  /// then the old level's `dispose` handed the music back to the menu a
  /// moment later, over the top of the battle that had just started. The
  /// menu theme then played for the whole level.
  ///
  /// Counting live screens is what makes the handover safe: the music only
  /// goes back to the menu when the LAST battle screen goes away, so a
  /// level-to-level transition (1 -> 2 -> 1) never releases it.
  static int _liveBattles = 0;

  @override
  void initState() {
    super.initState();
    _liveBattles++;
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
    if (widget.settings.tutorial) {
      _tutorial = TutorialProgress();
      // Solved from the live match, so the hint matches the player's own
      // hull and the fixed tutorial seed makes it the same numbers always.
      _tutorialHint = solveTutorialShot(ctrl);
    }
  }

  @override
  void dispose() {
    _keyFocus.dispose();
    if (widget.controller == null) {
      ctrl.dispose();
    } else {
      ctrl.removeListener(_onUpdate);
    }
    // Only the last battle screen to leave gives the music back. See
    // [_liveBattles].
    _liveBattles--;
    if (_liveBattles <= 0) {
      _liveBattles = 0;
      AudioService.instance.playMusic('music_menu');
    }
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
        // 1..9 pick a weapon, matching the HUD order. The shelf grew to
        // eight rounds, so the old 1..5 left the last three unreachable
        // from the keyboard.
        final label = event.logicalKey.keyLabel;
        if (label.length == 1 && label.codeUnitAt(0) >= 0x31 && label.codeUnitAt(0) <= 0x39) {
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
    // A turn arriving for the local player — the chat panel shuts for it.
    final yourTurnBegan = ctrl.canHumanAct && _lastPlayer != ctrl.currentPlayer;

    // The toast: a real event raises it, and it fades on its own clock.
    // Idle prompts ("Your turn", "Salty Sam is aiming…") are not events and
    // never raise it — the player can read the board for those.
    var toastDirty = false;
    if (ctrl.statusMessage != _seenStatus) {
      _seenStatus = ctrl.statusMessage;
      if (_isEventStatus(ctrl.statusMessage)) {
        _toastText = ctrl.statusMessage;
        _toastStart = ctrl.time;
        toastDirty = true;
      }
    }
    // The toast runs on the controller's own clock, so it is timed from the
    // moment it was raised rather than by an absolute deadline: a rematch
    // resets that clock, and a deadline would then hold the toast up for
    // ever. The clamp covers the same backwards jump.
    final elapsed = (ctrl.time - _toastStart).clamp(0.0, toastLife);
    final remaining = toastLife - elapsed;
    final bucket = remaining <= 0
        ? 0
        : ((remaining / toastFade).clamp(0.0, 1.0) * 8).round().clamp(1, 8);
    if (bucket != _toastBucket) {
      _toastBucket = bucket;
      toastDirty = true;
    }

    var tutorialDirty = false;
    if (_tutorial != null && !_tutorial!.completed) tutorialDirty = _trackTutorial();

    final dirty = _lastPhase != ctrl.phase ||
        _lastPlayer != ctrl.currentPlayer ||
        _lastTurnSec != turnSec ||
        _lastStatus != ctrl.statusMessage ||
        _lastWinner != ctrl.winner ||
        _lastAngle != angle ||
        _lastPower != power ||
        _lastWeapon != ctrl.selectedWeaponId ||
        _charging ||
        hpChanged ||
        tutorialDirty ||
        toastDirty;

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
      // The chat panel folds itself away the moment a turn comes to you:
      // a 230x172 box over the right-hand side is exactly where the player
      // is about to be aiming.
      if (_chatOpen && yourTurnBegan) _chatOpen = false;
      setState(() {});
    }
    if (enteringGameOver && widget.campaignLevel != null) _recordCampaignResult();
  }

  /// Feeds the tutorial script from the running match. Every fired shot is
  /// accounted for in order (the aim readout still holds the fired values
  /// when the update runs), the sinking step trips when the practice raft
  /// goes down, and a player victory completes the lesson whatever step is
  /// showing. Returns true when the card needs repainting.
  bool _trackTutorial() {
    final t = _tutorial!;
    var changed = false;
    while (t.shotsSeen < ctrl.shotsFired) {
      t.shotsSeen++;
      if (t.noteShotFired(ctrl.aimPower)) changed = true;
    }
    if (t.step == TutorialStep.sink && !(ctrl.world.raftOf(1)?.alive ?? true)) {
      if (t.noteTargetSunk()) changed = true;
    }
    if (ctrl.phase == GamePhase.gameOver && ctrl.winner == 0) {
      if (t.noteVictory()) {
        changed = true;
        unawaited(_completeTutorial());
      }
    }
    return changed;
  }

  Future<void> _completeTutorial() async {
    _tutorialReward = await Tutorial.complete();
    if (mounted) setState(() {});
  }

  /// How long a toast stays up, and how long it takes to fade out at the end.
  static const double toastLife = 2.0;
  static const double toastFade = 0.45;

  /// Whether a status message is worth interrupting for.
  ///
  /// The idle prompts are the board speaking, not an event: "Your turn" and
  /// "Salty Sam is aiming…" are visible from the turn order and the camera
  /// itself. Everything else — a shot away, a hit, a body still recovering,
  /// a crew member tangled up — is something that happened.
  static bool _isEventStatus(String status) {
    if (status.isEmpty) return false;
    if (status == 'Pull back and release') return false;
    if (status == 'Your turn') return false;
    if (status.endsWith(' is aiming…')) return false;
    return true;
  }

  /// The toast itself: a small pill at the top of the screen, over the
  /// water rather than over the controls.
  Widget _buildToast() {
    if (_toastBucket == 0 || _toastText.isEmpty) return const SizedBox.shrink();
    // The tutorial card owns the top of the screen in a lesson, so the
    // toast stands aside rather than stacking on it.
    if (_tutorial != null && !_tutorial!.completed) return const SizedBox.shrink();
    return Positioned(
      top: 62,
      left: 0,
      right: 0,
      child: Center(
        child: Opacity(
          opacity: _toastBucket / 8,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8 * _ui),
            decoration: RT.pill(color: RT.ink, opacity: 0.72, radius: 14),
            child: Text(_toastText,
                style: RT.body(
                    size: 13 * _ui,
                    color: Colors.white,
                    weight: FontWeight.w800)),
          ),
        ),
      ),
    );
  }

  void _recordCampaignResult() {
    final level = widget.campaignLevel;
    if (level == null || ctrl.winner != 0) return; // only victories earn stars
    final me = ctrl.world.raftOf(0);
    final breakTotal = ctrl.world.breakablesTotal;
    final result = Campaign.starsForResult(
      level,
      rounds: ctrl.round,
      weaponsFired: ctrl.humanWeaponsUsed,
      flawless: me != null && me.living.length == me.crew.length,
      breakFraction:
          breakTotal == 0 ? 0 : ctrl.world.breakablesBroken / breakTotal,
    );
    final reward =
        SaveService.instance.recordCampaignLevel(level: level, stars: result.stars);
    if (!mounted) return;
    setState(() {
      _campaignStars = result.stars;
      _campaignReward = reward;
      _starRoundsMet = result.roundsMet;
      _starRounds = ctrl.round;
      _starRoundTarget = level.star2Rounds;
      _starObjectiveMet = result.objectiveMet;
      _starObjectiveLabel = level.star3.title;
    });
  }

  // Per-objective breakdown for the result panel's star rows.
  bool _starRoundsMet = false;
  int _starRounds = 0;
  int _starRoundTarget = 0;
  bool _starObjectiveMet = false;
  String _starObjectiveLabel = '';

  // ---------------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------------

  List<Rect> _excludedRects() {
    final rects = <Rect>[];
    for (final key in [
      _weaponBarKey,
      _nudgeBarKey,
      _topBarKey,
      _walkBarKey,
      _fireBtnKey,
      // The build bars own their taps too — a finger on the material
      // palette or on SET SAIL must not also land a block on the deck
      // behind it.
      _buildTopKey,
      _buildBottomKey,
    ]) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      rects.add(box.localToGlobal(Offset.zero) & box.size);
    }
    return rects;
  }

  /// True while the player is laying out their raft.
  bool get _building => ctrl.buildPhase && !ctrl.inIntro;

  /// Turns a screen point into a world point.
  ///
  /// The scene transform is the whole of what the painter does before it
  /// draws: fit the world's height to the screen, then pan by the camera
  /// (see [WorldRenderer.render]). Inverting it here is what lets the
  /// player edit the raft by touching the raft, rather than by touching a
  /// diagram of it somewhere else on the screen.
  Offset _worldAt(Offset local, Size size) {
    final scale = size.height / BattleConst.viewH;
    return Offset(local.dx / scale + ctrl.world.cam, local.dy / scale + ctrl.world.camY);
  }

  /// Places or clears a block from a tap on the raft itself.
  ///
  /// Tapping an empty cell builds in the selected material; tapping a block
  /// takes it away. One gesture both ways, so there is no eraser mode to
  /// get stuck in — and the thing being tapped is the actual raft, at the
  /// size it will be fought at, with the crew standing on it.
  void _buildTap(Offset local, Size size) {
    final raft = ctrl.world.raftOf(ctrl.localPlayerIndex);
    final plan = ctrl.editingPlan;
    if (raft == null || plan == null) return;

    final w = _worldAt(local, size);
    final deckTop = raft.waterLine - raft.loadout.deckRise;
    final lx = w.dx - raft.x;
    final ly = w.dy - ctrl.world.bobOf(raft);

    final col = BuildPlan.columnAt(lx);
    if (col < 0 || !raft.buildColumnOnDeck(col)) return;
    final row = ((deckTop - ly) / BuildPlan.cellH).floor();
    if (row < 0 || row >= BuildPlan.rows) return;

    AudioService.instance.sfx('click');
    ctrl.setBlock(col, row, plan.at(col, row) != null ? null : buildMaterial);
    setState(() {});
  }

  /// The material the next tap on the raft lays down. Owned here rather than
  /// inside [BuildOverlay] because the tap that uses it lands on the world
  /// behind the overlay, not on the overlay itself.
  BuildMaterial buildMaterial = BuildMaterial.driftwood;

  void _onPointerDown(PointerDownEvent e) {
    if (_activePointerId != null) return;
    for (final rect in _excludedRects()) {
      if (rect.contains(e.position)) return;
    }
    // A tap skips the opening sweep. An unskippable cinematic is a nuisance
    // by the third match, and this one plays before every single one.
    if (ctrl.inIntro) {
      ctrl.skipIntro();
      return;
    }
    if (_building) {
      _buildTap(e.localPosition, context.size ?? MediaQuery.sizeOf(context));
      return;
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
    if ((current - origin).distance < BattleConst.deadzone) {
      // …but a tap is now how you take the helm: tapping one of your own crew
      // hands them the turn, and the walk controls below move them about the
      // deck. Anything else (open water, an enemy, a body still tumbling)
      // falls through and does nothing, exactly as it did before.
      ctrl.selectCrewAt(_worldFromLocal(current));
      return;
    }
    if (SaveService.instance.data.vibration) HapticFeedback.heavyImpact();
    ctrl.humanFire();
  }

  /// Screen point -> world point, the inverse of what the renderer does when
  /// it scales the world to the viewport and slides it by the camera.
  Offset _worldFromLocal(Offset local) {
    final screen = MediaQuery.sizeOf(context);
    final scale = screen.height / BattleConst.viewH;
    return Offset(local.dx / scale + ctrl.world.cam, local.dy / scale + ctrl.world.camY);
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
            // The stack fills the screen on its own account, rather than
            // taking its size from whichever children happen to be in it.
            //
            // It used to size itself from its children, and a Stack holding
            // nothing but Positioned ones collapses. That is exactly what
            // the build phase produces — the scene and the build overlay are
            // both Positioned.fill and the battle HUD is held back — so once
            // the HUD returned at SET SAIL the stack came back 0x0. The
            // world then painted into nothing: `viewWidth` became
            // `0 / 0`, the camera went NaN with it, and the whole match
            // rendered as a flat teal void.
            //
            // Every non-positioned child here wants the full screen anyway:
            // the HUD, and the game-over scrim.
            fit: StackFit.expand,
            children: [
              // The world gets a layer of its own.
              //
              // Without the boundary the scene and the HUD are one layer, and
              // the scene repaints every single frame by definition — so the
              // health bar, the weapon chips and the fire button were being
              // re-rasterised sixty times a second to show exactly what they
              // showed before. Split off, the HUD only costs anything on the
              // frames it actually changes on.
              //
              // `willChange` is the other half: it tells the raster cache not
              // to try to cache this picture. Cached content that is thrown
              // away and rebuilt every frame is worse than uncached, because
              // the cache pays to store it first.
              Positioned.fill(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: ctrl,
                    builder: (_, __) => CustomPaint(
                      painter: _ScenePainter(ctrl, renderer),
                      isComplex: true,
                      willChange: true,
                    ),
                  ),
                ),
              ),
              // The build overlay sits over the world it is editing, so a
              // wall is judged against the crew who will stand behind it.
              if (_building)
                BuildOverlay(
                  ctrl: ctrl,
                  selected: buildMaterial,
                  onSelect: (m) => setState(() => buildMaterial = m),
                  topBarKey: _buildTopKey,
                  bottomBarKey: _buildBottomKey,
                ),
              // The battle HUD is hidden while building, not drawn behind
              // it. It used to sit ON TOP of the overlay — the health bar
              // over the title, the walk arrows under the palette, a FIRE
              // button for a turn that has not started — which made the
              // build screen unreadable and let a stray tap drive the match
              // instead of the raft.
              if (!_building) SafeArea(child: _buildHud()),
              // The toast sits above the HUD, over the water rather than over
              // the controls, and only ever up for a couple of seconds.
              if (!_building) _buildToast(),
              if (_tutorial != null &&
                  !_tutorial!.completed &&
                  ctrl.phase != GamePhase.gameOver)
                _buildTutorialCard(),
              if (ctrl.net?.isNetworked ?? false) _chatOverlay(),
              if (ctrl.phase == GamePhase.aiming && ctrl.canHumanAct)
                _pullReadout(),
              if (ctrl.phase == GamePhase.gameOver) _buildResult(),
            ],
          ),
        ),
      ),
    );
  }


  // ------------------------------------------------------------------ chat

  /// Chat, shown only in a networked match.
  ///
  /// Lines ride the ordinary match protocol (see `NetService.sendChat`), so
  /// this widget neither knows nor cares whether the opponent is across the
  /// room on a hotspot or across the world on the relay.
  Widget _chatOverlay() {
    final net = ctrl.net!;
    return Positioned(
      right: 12,
      top: 92,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (_chatOpen)
              Container(
                width: 230,
                constraints: const BoxConstraints(maxHeight: 172),
                padding: const EdgeInsets.all(10),
                decoration: RT.pill(color: RT.ink, opacity: 0.72, radius: 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      child: net.chat.isEmpty
                          ? Text('Say something…',
                              style: RT.body(
                                  size: 11, color: Colors.white.withOpacity(0.6)))
                          : ListView(
                              shrinkWrap: true,
                              reverse: true,
                              children: [
                                for (final line in net.chat.reversed)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      '${line.mine ? "You" : line.name}: ${line.text}',
                                      style: RT.body(
                                        size: 11,
                                        color: line.mine
                                            ? RT.yellow
                                            : Colors.white,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 6),
                    // Quick lines rather than a keyboard: the battle is a
                    // landscape, one-thumb game and an on-screen keyboard
                    // would cover the deck the player is aiming at.
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        for (final phrase in _quickChat)
                          GestureDetector(
                            onTap: () {
                              AudioService.instance.sfx('click');
                              net.sendChat(phrase);
                              setState(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 5),
                              decoration: RT.pill(opacity: 0.9, radius: 9),
                              child: Text(phrase,
                                  style: RT.body(
                                      size: 10,
                                      color: RT.ink,
                                      weight: FontWeight.w800)),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                AudioService.instance.sfx('click');
                setState(() => _chatOpen = !_chatOpen);
              },
              child: Container(
                padding: const EdgeInsets.all(9),
                decoration: RT.pill(opacity: 0.85, radius: 12),
                child: Icon(
                  _chatOpen ? Icons.close : Icons.chat_bubble,
                  size: 18,
                  color: RT.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const List<String> _quickChat = [
    'Nice shot!',
    'So close',
    'Good game',
    'Ouch!',
    'My turn',
  ];
  // ---------------------------------------------------------------------------
  // Tutorial script card
  // ---------------------------------------------------------------------------

  /// The lesson card for a tutorial match: which step is showing, what to do,
  /// and the solved hint on the final step. Sits top-centre, clear of the
  /// health bar (left) and the chips (right).
  ///
  /// Deliberately only the step text and the progress dots. The card used
  /// to carry a "LEARN THE ROPES" header and a "STEP 1 OF 3" caption as
  /// well, which is three lines of chrome for one line of instruction — and
  /// the dots already say which step this is.
  Widget _buildTutorialCard() {
    final t = _tutorial!;
    final stepIndex = TutorialStep.values.indexOf(t.step);
    final hint = _tutorialHint;
    final String body;
    switch (t.step) {
      case TutorialStep.shoot:
        body = 'Pull back on the water, then release — fire your first shot '
            'anywhere. Tap a crew member to switch who is aiming.';
      case TutorialStep.power:
        body =
            'Power is range. Pull further back and fire a shot over ${TutorialConfig.powerThreshold.round()}% power.';
      case TutorialStep.sink:
        body = hint == null
            ? 'Lob over the rock and sink the practice raft.'
            : 'Lob over the rock and sink the practice raft. Try about ${hint.angle.round()}° and ${hint.power.round()}% power.';
    }
    return Positioned(
      top: 62,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 430),
          margin: const EdgeInsets.symmetric(horizontal: 70),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: RT.pill(color: RT.ink, opacity: 0.78, radius: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < TutorialStep.values.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    i < stepIndex
                        ? Icons.check_circle
                        : (i == stepIndex
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked),
                    size: 13,
                    color: i <= stepIndex ? RT.yellow : Colors.white.withOpacity(0.45),
                  ),
                ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(body,
                    textAlign: TextAlign.center,
                    style: RT.body(size: 12, color: Colors.white, weight: FontWeight.w700)),
              ),
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
        const Spacer(),
        _bottomBar(),
      ],
    );
  }

  /// How much the HUD shrinks on a short screen.
  ///
  /// A phone held in landscape is 360–400 logical pixels tall, and the HUD
  /// was drawn at desktop sizes: the fire button alone ate a sixth of the
  /// screen's height, and the walk pads, weapon chips and readouts squeezed
  /// the world into a sliver between them. Everything structural below
  /// scales by this factor — a phone lands around 0.8, tablets and desktop
  /// windows at 1.0 — so the controls stay thumb-sized without crowding the
  /// crews off the water.
  double get _ui => (MediaQuery.sizeOf(context).height / 470).clamp(0.78, 1.0);

  Widget _topBar() {
    final me = ctrl.world.raftOf(ctrl.localPlayerIndex);
    return Padding(
      key: _topBarKey,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _roundBtn(() => Navigator.pop(context), icon: Icons.arrow_back_ios_new, size: 40 * _ui),
          const SizedBox(width: 8),
          // Player health, at a fixed width and claiming no share of the
          // free space.
          //
          // It was briefly Flexible, to stop the bar overflowing on a narrow
          // screen — but a flex child takes its share of the leftover width
          // whether it needs it or not, and at flex 3 against the chips'
          // flex 1 it swallowed three quarters of the row. The chips then
          // had nowhere to go but left. The overflow it was guarding against
          // came from the chips anyway, and they scroll now.
          //
          // One bar with the number inside it, not a labelled panel with a
          // number above it: "YOUR RAFT" and a separate readout said the
          // same thing twice and cost a third of the bar's width.
          SizedBox(
            width: 130 * _ui,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: RT.pill(opacity: 0.8, radius: 14),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: me?.hpFrac ?? 0,
                      minHeight: 20,
                      backgroundColor: RT.ink.withOpacity(0.14),
                      valueColor: AlwaysStoppedAnimation(
                        (me?.hpFrac ?? 0) > 0.5 ? RT.green : ((me?.hpFrac ?? 0) > 0.25 ? RT.orange : RT.red),
                      ),
                    ),
                  ),
                  Text('${(me?.hp ?? 0).round()}',
                      style: RT.body(
                          size: 11, color: RT.ink, weight: FontWeight.w800)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // The readouts, held against the RIGHT edge and allowed to scroll
          // off to the left if they cannot all fit.
          //
          // Only two chips are left: the wind (which changes the shot and
          // must be read) and one combined chip carrying the crew left, the
          // opponents still over the horizon and — in a survival level —
          // the round. The aim readout and the purse used to sit here too;
          // the first now lives on the floating card above the shooter, and
          // the second belongs on the results screen, not over the water.
          //
          // Expanded rather than Flexible, and this is the whole of it: a
          // Flexible box only claims its share of the free space, so on a
          // wide window the chips ended up sitting just after the health
          // bar with half the screen empty to their right. Expanded takes
          // everything that is left, so the box it right-aligns inside
          // actually reaches the edge of the screen.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  _windChip(),
                  const SizedBox(width: 8),
                  _crewChip(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The one status chip: how much enemy crew is left, how many opponents
  /// are still over the horizon, and — in a survival level — the round
  /// counter. Everything the player needs to know about the state of the
  /// fight, in one pill, instead of three.
  Widget _crewChip() {
    final foes = ctrl.offscreenFoes;
    final parts = <String>['${ctrl.foesLeft} CREW LEFT'];
    if (foes > 0) parts.add('$foes OVER HORIZON');
    if (ctrl.settings.roundLimit > 0) {
      parts.add('ROUND ${ctrl.round}/${ctrl.settings.roundLimit}');
    }
    return _infoChip(parts.join(' · '));
  }

  Widget _infoChip(String text) => Container(
        padding: EdgeInsets.symmetric(horizontal: 12 * _ui, vertical: 9 * _ui),
        decoration: RT.pill(opacity: 0.82, radius: 13),
        child: Text(text, style: RT.body(size: 12 * _ui, color: RT.ink, weight: FontWeight.w800)),
      );

  /// This turn's wind: an arrow for the direction and a 1–5 strength number.
  /// Positive wind blows seaward (+x, downrange for the player); negative
  /// blows back landward. Calm air shows no arrow at all — just the word.
  /// A storm flies its own icon: the gusts run past the ordinary cap, so
  /// the number alone would undersell it.
  Widget _windChip() {
    final w = ctrl.world.wind;
    final calm = Wind.calm(w);
    final storm = ctrl.world.storm;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * _ui, vertical: 9 * _ui),
      decoration: RT.pill(
          color: calm && !storm ? Colors.white : RT.sea2,
          opacity: 0.85,
          radius: 13),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (storm)
            Icon(Icons.thunderstorm, size: 14 * _ui, color: Colors.white)
          else if (!calm)
            Icon(w > 0 ? Icons.arrow_forward : Icons.arrow_back,
                size: 14 * _ui, color: Colors.white),
          if (!calm || storm) SizedBox(width: 4 * _ui),
          Text(calm && !storm ? 'CALM' : '${storm ? 'STORM ' : 'WIND '}${Wind.pips(w)}',
              style: RT.body(
                  size: 12 * _ui,
                  color: calm && !storm ? RT.ink : Colors.white,
                  weight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    // Controls that are not yours to press are dimmed, not hidden. The
    // fire button has always kept its place on screen so a thumb resting
    // there is never surprised, and the same reasoning covers the weapon
    // bar: fading them to a third clears the view without moving anything
    // under a thumb that is already resting there.
    final yours = ctrl.canHumanAct || ctrl.canSteer;
    final dim = yours ? 1.0 : 0.3;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 14 * _ui),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Expanded, for two reasons at once. It has to be able to give up
          // width, because the weapon bar grows with however many rounds the
          // match enables and a rigid one pushed the fire button off the
          // right-hand edge. And it has to CLAIM the leftover width, because
          // this is what holds the fire button and the nudge pad against the
          // right edge — a plain gap here left them stranded in the middle
          // of a wide window with the whole right half of the screen empty.
          Expanded(
            child: Opacity(
              opacity: dim,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Only on your own turn, and only while there is somebody on
                  // their feet to walk — the pads would be a lie otherwise.
                  if (ctrl.canSteer) ...[
                    _walkBar(),
                    const SizedBox(height: 8),
                  ],
                  _weaponBar(),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Never flexible: aiming and firing are the controls the turn
          // cannot be taken without.
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Opacity(opacity: dim, child: _nudgeBar()),
              const SizedBox(height: 10),
              _fireButton(),
            ],
          ),
        ],
      ),
    );
  }

  /// The rounds on hand.
  ///
  /// Scrollable, because a match can enable every weapon in the game and
  /// the bar is pinned to the bottom-left corner of a phone in landscape.
  /// The key sits on the scroll view rather than on the inner row so the
  /// rect excluded from aim-drags is the part actually on screen.
  Widget _weaponBar() {
    final weapons = ctrl.availableWeapons;
    return SingleChildScrollView(
      key: _weaponBarKey,
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final w in weapons) ...[
            _weaponChip(w),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  /// A weapon chip.
  ///
  /// A row of eight of these used to run the width of a phone, because each
  /// one carried its name. The name is only on the SELECTED chip now: the
  /// colour dot says which round it is, the count says how many are left,
  /// and the name of the one in your hand is the only one worth reading.
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
          padding: EdgeInsets.symmetric(
              horizontal: selected ? 13 * _ui : 10 * _ui, vertical: 9 * _ui),
          decoration: selected
              ? RT.card(color: RT.orange, radius: 16, border: 0)
              : RT.pill(opacity: 0.9, radius: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: (selected ? 22.0 : 18.0) * _ui,
                height: (selected ? 22.0 : 18.0) * _ui,
                decoration: BoxDecoration(color: w.color, shape: BoxShape.circle),
              ),
              if (selected) ...[
                const SizedBox(width: 8),
                Text(w.chipLabel,
                    style: RT.body(
                        size: 10,
                        color: Colors.white,
                        weight: FontWeight.w800,
                        letterSpacing: 0.8)),
              ],
              const SizedBox(width: 6),
              Text(label,
                  style: RT.body(
                      size: 11,
                      color: (selected ? Colors.white : RT.ink).withOpacity(0.78),
                      weight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }

  /// The fine-tune controls: four buttons that nudge the angle and the power
  /// by a degree and a percent.
  ///
  /// They are hidden behind a small toggle by default. The pull-back drag
  /// already sets angle and power together, so the buttons are a second way
  /// of doing something the primary control does better — but they are the
  /// only way to adjust *after* letting go of a drag, so they cannot go
  /// away entirely.
  ///
  /// On a desktop they do not appear at all: the keyboard already nudges
  /// (WASD or the arrows, Shift for the coarse step), and four buttons on a
  /// mouse-driven layout are a fifth of the bottom bar for nothing.
  Widget _nudgeBar() {
    if (Desktop.isDesktop) return const SizedBox.shrink();
    final shown = _fineTune;
    return Row(
      key: _nudgeBarKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The toggle: a small button that opens and closes the four nudges.
        _roundBtn(
          () => setState(() => _fineTune = !_fineTune),
          icon: Icons.tune,
          size: 30,
        ),
        if (shown) ...[
          const SizedBox(width: 6),
          _roundBtn(() => ctrl.nudgeAngle(-1), icon: Icons.keyboard_arrow_down),
          const SizedBox(width: 6),
          _roundBtn(() => ctrl.nudgeAngle(1), icon: Icons.keyboard_arrow_up),
          const SizedBox(width: 6),
          _roundBtn(() => ctrl.nudgePower(-1), icon: Icons.remove),
          const SizedBox(width: 6),
          _roundBtn(() => ctrl.nudgePower(1), icon: Icons.add),
        ],
      ],
    );
  }

  /// Walk controls for the crew member the player has the helm of.
  ///
  /// Held, not tapped: the crew member walks for exactly as long as a finger
  /// is down, which is what makes repositioning feel like steering rather
  /// than nudging. Releasing hands the body back to the simulation, which
  /// walks them home the same way it does after a knockdown.
  Widget _walkBar() {
    Widget pad(String glyph, int dir) => Listener(
          onPointerDown: (_) {
            AudioService.instance.sfx('click');
            ctrl.setWalk(dir);
            setState(() {});
          },
          onPointerUp: (_) {
            ctrl.setWalk(0);
            setState(() {});
          },
          onPointerCancel: (_) {
            ctrl.setWalk(0);
            setState(() {});
          },
          child: Container(
            key: dir < 0 ? _walkBarKey : null,
            width: 52 * _ui,
            height: 46 * _ui,
            alignment: Alignment.center,
            decoration: RT.pill(
              color: ctrl.walkDir == dir ? RT.orange : RT.ink,
              opacity: ctrl.walkDir == dir ? 0.95 : 0.58,
              radius: 14,
            ),
            child: Text(glyph,
                style: RT.chunky(size: 22 * _ui, color: Colors.white)),
          ),
        );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pad('◀', -1),
        const SizedBox(width: 8),
        pad('▶', 1),
      ],
    );
  }


  /// The FIRE button.
  ///
  /// Pull-and-release on the world is still the main way to shoot, and it is
  /// the expressive one — it sets angle and power together. This is the
  /// other half: line the shot up with the angle and power nudges, then
  /// press a button you can actually see. It fires the shot exactly as
  /// currently aimed, which is what the readout above has been showing all
  /// along.
  ///
  /// Greyed rather than hidden when it cannot fire, so its place on screen
  /// never moves and a thumb resting there is never surprised.
  Widget _fireButton() {
    final live = ctrl.canFire;
    return Listener(
      onPointerDown: (_) {
        if (!live) {
          AudioService.instance.sfx('click');
          return;
        }
        if (SaveService.instance.data.vibration) HapticFeedback.heavyImpact();
        ctrl.humanFire();
        setState(() {});
      },
      child: Container(
        key: _fireBtnKey,
        width: 96 * _ui,
        height: 64 * _ui,
        alignment: Alignment.center,
        decoration: RT.pill(
          color: live ? RT.orange : RT.ink,
          opacity: live ? 0.96 : 0.45,
          radius: 20,
        ),
        child: Text(
          'FIRE',
          style: RT.chunky(
            size: 21 * _ui,
            color: live ? Colors.white : Colors.white.withOpacity(0.5),
          ),
        ),
      ),
    );
  }
  /// A small round control. Give it [glyph] or [icon], whichever the mark
  /// exists as.
  ///
  /// The distinction matters now that the typefaces ship with the app. While
  /// Baloo 2 was being fetched over the network and usually failing, every
  /// label fell back to a system font that had the whole of the Geometric
  /// Shapes block; now that the real font loads, the glyphs it does not
  /// contain are down to per-platform fallback, which is not something to
  /// build a button out of. Baloo 2 has U+25C0/U+25B6 (the walk pads) but
  /// not U+25BE/U+25B4 — so the nudge arrows are icons, which ship with the
  /// app and look the same everywhere.
  Widget _roundBtn(
    VoidCallback onTap, {
    String? glyph,
    IconData? icon,
    double size = 36,
  }) {
    assert(glyph != null || icon != null);
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx('click');
        onTap();
        setState(() {});
      },
      child: Container(
        width: size * _ui,
        height: size * _ui,
        alignment: Alignment.center,
        decoration: RT.pill(opacity: 0.85, radius: 12),
        child: icon != null
            ? Icon(icon, size: size * _ui * 0.62, color: RT.ink)
            : Text(glyph!,
                style: RT.chunky(size: size * _ui * 0.42, color: RT.ink)),
      ),
    );
  }

  /// The Force/Angle readout — a white rounded card with the two stats side
  /// by side and a thin divider between them, fixed at the TOP-LEFT of the
  /// character who is lining up the shot, mirroring the aiming pop-up from
  /// the reference design. It stays put (it does not follow the drag
  /// gesture) so the numbers are always readable in the same place while
  /// you pull.
  Widget _pullReadout() {
    final raft = ctrl.currentRaft;
    final screen = MediaQuery.sizeOf(context);
    final scale = screen.height / BattleConst.viewH;
    final cam = ctrl.world.cam;
    final camY = ctrl.world.camY;
    // Anchor on the shooter's head — a little above-and-left of the crew
    // member currently taking the turn.
    double worldX = 0, worldY = 0;
    if (raft != null && raft.activeIndex >= 0 && raft.activeIndex < raft.crew.length) {
      final head = raft.crewPos(raft.activeIndex) - const Offset(0, 30);
      worldX = head.dx;
      worldY = head.dy;
    }
    final sx = (worldX - cam) * scale;
    final sy = (worldY - camY) * scale;
    // Compact card — it floats over the action, so it stays small and never
    // covers the shooter or the pull gesture.
    final cardW = 152.0 * _ui;
    final cardH = 50.0 * _ui;
    final left = (sx - cardW + 8).clamp(8.0, (screen.width - cardW - 8).clamp(8.0, screen.width));
    final top = (sy - cardH - 10).clamp(8.0, screen.height - cardH - 8);
    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Color(0x26000000), offset: Offset(0, 4), blurRadius: 10),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _forceAngleStat('${ctrl.aimPower.round()}%', ctrl.aimFine ? 'FINE' : 'FORCE'),
              Container(
                width: 1.2,
                height: 22,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                color: RT.ink.withOpacity(0.12),
              ),
              _forceAngleStat('${ctrl.aimAngle.round()}°', 'ANGLE'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _forceAngleStat(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: RT.chunky(size: 16, color: RT.ink)),
        const SizedBox(height: 1),
        Text(label,
            style: RT.body(size: 8, color: RT.ink.withOpacity(0.45), weight: FontWeight.w800, letterSpacing: 1.2)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Result panel
  // ---------------------------------------------------------------------------

  Widget _buildResult() {
    final seat = ctrl.localPlayerIndex;
    final won = ctrl.winner == seat && !ctrl.players[seat].isAi;
    final level = widget.campaignLevel;
    final isTutorial = widget.settings.tutorial;
    final kicker = isTutorial
        ? (won ? 'TRAINING COMPLETE' : 'TARGET STILL FLOATING')
        : level != null
            ? (won ? 'BATTLE ${level.indexInWorld + 1} CLEARED' : 'RAFT SUNK')
            : (won ? 'VICTORY' : 'DEFEAT');
    final title = isTutorial
        ? (won ? 'You sunk the practice raft!' : 'Give it another go')
        : level != null
            ? (won ? '${level.captainName} defeated!' : 'Sunk by ${level.captainName}')
            : (won ? 'You rule the water' : 'Bail out and retry');
    final showReward = level != null && won && _campaignReward != null;
    final showTutorialReward = isTutorial && won && _tutorialReward > 0;

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
                const SizedBox(height: 8),
                _objectiveRow(
                  'WIN IN $_starRoundTarget ROUNDS ($_starRounds)',
                  _starRoundsMet,
                ),
                const SizedBox(height: 4),
                _objectiveRow(_starObjectiveLabel, _starObjectiveMet),
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
                  if (showTutorialReward) ...[
                    const SizedBox(width: 10),
                    Expanded(child: _statTile('+$_tutorialReward', 'COINS', gold: true)),
                  ],
                ],
              ),
              // The purse, which used to sit in the top bar over the water.
              // It is a between-battles number, not a battle number, so it
              // belongs here with the rest of the accounting.
              const SizedBox(height: 8),
              Text('${SaveService.instance.data.doubloons} DOUBLOONS IN YOUR PURSE',
                  style: RT.body(
                      size: 10,
                      color: RT.ink.withOpacity(0.5),
                      weight: FontWeight.w800,
                      letterSpacing: 1.2)),
              const SizedBox(height: 14),
              _xpPanel(),
              const SizedBox(height: 14),
              if (isTutorial) ..._tutorialButtons(won)
              else if (level != null) ..._campaignButtons(level, won)
              else ..._quickButtons(),
            ],
          ),
        ),
      ),
    );
  }

  /// XP earned, the bar, and anything the crossed levels handed over.
  ///
  /// Levelling used to happen silently: XP went up, a level occasionally
  /// ticked over, and nothing on screen said so or gave you anything. Every
  /// level now carries a reward and this is where the player is told about
  /// it — the rewards themselves are already banked by [SaveService], so
  /// dismissing this card never costs anything.
  Widget _xpPanel() {
    final save = SaveService.instance.data;
    final svc = SaveService.instance;
    if (svc.lastXpGain <= 0) return const SizedBox.shrink();
    final ups = svc.lastLevelUps;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: RT.ink.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('LV ${save.level}',
                  style: RT.chunky(size: 14, color: RT.ink)),
              const SizedBox(width: 6),
              Text(save.rank,
                  style: RT.body(
                      size: 10,
                      color: RT.ink.withOpacity(0.55),
                      weight: FontWeight.w800,
                      letterSpacing: 1.2)),
              const Spacer(),
              Text('+${svc.lastXpGain} XP',
                  style: RT.chunky(size: 14, color: RT.green)),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: save.levelProgress,
              minHeight: 8,
              backgroundColor: RT.ink.withOpacity(0.12),
              valueColor: const AlwaysStoppedAnimation(RT.orange),
            ),
          ),
          if (ups.isNotEmpty) ...[
            const SizedBox(height: 9),
            for (final r in ups)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    const Icon(Icons.arrow_upward, size: 13, color: RT.orange),
                    const SizedBox(width: 5),
                    Text('LEVEL ${r.level}',
                        style: RT.body(
                            size: 10,
                            color: RT.ink,
                            weight: FontWeight.w800,
                            letterSpacing: 1)),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(r.headline,
                          overflow: TextOverflow.ellipsis,
                          style: RT.body(
                              size: 11,
                              color: RT.ink.withOpacity(0.75),
                              weight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// One star-objective line on the result panel: what the star wanted and
  /// whether this victory earned it.
  Widget _objectiveRow(String label, bool met) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(met ? Icons.check_circle : Icons.cancel,
            size: 15, color: met ? RT.green : RT.ink.withOpacity(0.35)),
        const SizedBox(width: 6),
        Text(label,
            style: RT.body(
                size: 10,
                color: met ? RT.ink : RT.ink.withOpacity(0.5),
                weight: FontWeight.w800,
                letterSpacing: 0.8)),
      ],
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

  /// The lesson is over: replay it, or head out. No campaign navigation —
  /// a tutorial has no next level — and no rematch negotiation either,
  /// because there is nobody on the other end of the wire.
  List<Widget> _tutorialButtons(bool won) => [
        ChunkyButton(
          label: won ? 'PLAY AGAIN' : 'TRY AGAIN',
          icon: Icons.refresh,
          color: RT.orange,
          width: 240,
          height: 52,
          fontSize: 18,
          onPressed: () {
            AudioService.instance.sfx('click');
            final (settings, players) = Tutorial.match();
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => GameScreen(
                    settings: settings,
                    players: players,
                    mode: GameMode.vsAi,
                    seed: TutorialConfig.seed),
              ),
            );
          },
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

  List<Widget> _quickButtons() => [        ChunkyButton(
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
    renderer.render(
      canvas, size, ctrl.time,
      currentPlayer: ctrl.currentPlayer,
      isAiming: ctrl.phase == GamePhase.aiming,
      aimAngleDeg: ctrl.aimAngle,
      weapon: ctrl.selectedWeapon,
      // While laying out a raft, show the player where blocks may go — on
      // the raft itself, which is the only place the question makes sense.
      buildTarget: ctrl.buildPhase && !ctrl.inIntro
          ? ctrl.world.raftOf(ctrl.localPlayerIndex)
          : null,
      // Crew chatter is a setting: the bubbles are half the life of the
      // game, and also a white box over the action.
      chatter: SaveService.instance.data.crewChatter,
    );

    // Trajectory preview for the human shooter, drawn over the scene.
    if (ctrl.phase != GamePhase.aiming || !ctrl.canHumanAct) return;
    if (!SaveService.instance.data.showTrajectory && !ctrl.isCharging) return;
    final raft = ctrl.currentRaft;
    if (raft == null) return;
    // A dazed shooter has no arc — sand in the eyes. It takes nothing off
    // the shot itself, it just makes the player aim by eye for one turn,
    // which is the game underneath the aim assist.
    if (raft.activeCrew?.status == StatusEffect.dazed) return;
    final dots = ctrl.world.trajectory(
      // Same origin the shot will actually spawn from (the drawn muzzle at
      // the live aim angle), so the dots lie exactly on the flight path.
      from: raft.muzzle(aimAngleDeg: ctrl.aimAngle, weapon: ctrl.selectedWeapon),
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
