import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ai.dart';
import 'audio.dart';
import 'battle.dart';
import 'maps.dart';
import 'models.dart';
import 'net.dart';
import 'raft.dart';
import 'save.dart';

/// Turn-based phases. There is no build phase and no physics settling any
/// more — a shot flies, resolves, and the turn passes.
enum GamePhase { aiming, firing, resolving, turnTransition, gameOver }

enum GameMode { vsAi, local, hotspot }

class PlayerConfig {
  final String name;
  final bool isAi;
  final AiDifficulty aiDifficulty;

  /// Raft hull/size/colour and crew count for this seat.
  final RaftLoadout loadout;

  /// Cosmetic archetype used by the renderer and the label above the raft.
  final CrewLook look;

  /// Which network peer controls this player, for hotspot play.
  final int? netId;

  /// Campaign "Power Shots" upgrade — multiplies launch speed. 1.0 = stock.
  final double powerMultiplier;

  /// Innate aim sloppiness for AI seats (design's per-type `jitter`).
  final double aimJitter;

  PlayerConfig({
    required this.name,
    required this.loadout,
    this.look = CrewLook.player,
    this.isAi = false,
    this.aiDifficulty = AiDifficulty.normal,
    this.netId,
    this.powerMultiplier = 1.0,
    this.aimJitter = 10,
  });
}

class MatchSettings {
  MapDef map;
  double startHp;
  double turnSeconds;
  List<String> enabledWeapons;

  /// Per-player starting HP by index; falls back to [startHp].
  List<double>? startHpPerPlayer;

  /// Ammo the human player carries into this battle, by weapon id. Weapons
  /// absent from the map fall back to their [WeaponDef.startAmmo].
  Map<String, int>? ammo;

  MatchSettings({
    MapDef? map,
    this.startHp = 100,
    this.turnSeconds = 30,
    List<String>? enabledWeapons,
    this.startHpPerPlayer,
    this.ammo,
  })  : map = map ?? GameMaps.all.first,
        enabledWeapons = enabledWeapons ?? Weapons.all.map((w) => w.id).toList();

  double startHpFor(int playerIndex) {
    final list = startHpPerPlayer;
    if (list != null && playerIndex < list.length) return list[playerIndex];
    return startHp;
  }
}

class GameController extends ChangeNotifier {
  late BattleWorld world;
  MatchSettings settings;
  List<PlayerConfig> players;
  GameMode mode;
  NetService? net;

  GamePhase phase = GamePhase.aiming;
  int currentPlayer = 0;
  double turnTimeLeft = 0;
  int round = 1;

  /// Aim state for the current shooter, in the design's units.
  double aimAngle = 45;
  double aimPower = 70;
  bool aimFine = false;
  String selectedWeaponId = 'tennis';
  bool isCharging = false;

  /// Remaining rounds by weapon id for the human side. Infinite weapons are
  /// absent from this map entirely.
  final Map<String, int> ammo = {};

  int? winner;
  int damageDealtByHuman = 0;
  int shotsFired = 0;
  int shotsHit = 0;

  Timer? _ticker;
  DateTime _lastTick = DateTime.now();
  double _accum = 0;
  bool _disposed = false;
  bool _gameEnded = false;
  double time = 0;
  String statusMessage = '';

  /// Set the instant a shot is committed for this turn, cleared by
  /// [_beginTurn]. The single guard that stops a double-tap, a racing network
  /// message and the AI from all queueing a shot for the same turn.
  bool _shotCommitted = false;

  double _aiThinkTime = 0;
  bool _aiShotQueued = false;
  double _resolveTimer = 0;
  double _transitionTimer = 0;

  void Function(String kind, Map<String, dynamic> data)? onEvent;

  GameController({
    required this.settings,
    required this.players,
    required this.mode,
    this.net,
    int? seed,
  }) {
    _setup(seed ?? DateTime.now().millisecondsSinceEpoch);
  }

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------

  void _setup(int seed) {
    world = BattleWorld(map: settings.map, seed: seed);

    for (int i = 0; i < players.length; i++) {
      final p = players[i];
      final isPlayerSide = i == 0;
      final x = isPlayerSide
          ? BattleConst.playerX
          : BattleConst.enemySlots[(i - 1).clamp(0, BattleConst.enemySlots.length - 1)];
      final hp = settings.startHpFor(i) + p.loadout.hpBonus;
      world.addRaft(Raft(
        playerIndex: i,
        x: x,
        loadout: p.loadout,
        look: p.look,
        label: p.name.toUpperCase(),
        facing: isPlayerSide ? 1 : -1,
        crew: List.generate(
          p.loadout.crewCount,
          (c) => Crew(hp: hp, maxHp: hp, bobPhase: c * 0.7),
        ),
      ));
    }

    ammo.clear();
    for (final w in Weapons.all) {
      if (w.infinite) continue;
      if (!settings.enabledWeapons.contains(w.id)) continue;
      ammo[w.id] = settings.ammo?[w.id] ?? w.startAmmo;
    }
    selectedWeaponId = Weapons.starter.id;

    world.lockCam(0);
    _beginTurn(0, initial: true);
    _hookNet();
    _startTicker();
  }

  // ---------------------------------------------------------------------------
  // Net wiring
  // ---------------------------------------------------------------------------

  void _hookNet() {
    if (net == null) return;
    net!.onMessage = (msg) {
      switch (msg['t']) {
        case 'fire':
          _handleRemoteFire(msg);
          break;
        case 'endTurn':
          _handleRemoteEndTurn(msg);
          break;
        case 'rematch':
          _handleRemoteRematch(msg);
          break;
      }
    };
  }

  /// Both devices simulate the same turn and both end it locally, so each
  /// one's "your turn is over" is really a confirmation of what the other has
  /// already worked out. It is honoured exactly once, and only if it is about
  /// the turn actually being played — otherwise a message that arrives late
  /// (or one describing a turn this device has already moved past) would skip
  /// the next player's go.
  void _handleRemoteEndTurn(Map<String, dynamic> msg) {
    final seq = msg['seq'];
    if (seq is! int) return;
    if (_endedTurns.contains(seq)) return;
    final pl = msg['pl'];
    if (pl is int && pl != currentPlayer) return;
    if (phase != GamePhase.aiming) return;
    _endTurn(fromNetwork: true);
  }

  /// A rematch carries a seed only from the host, who is the one device that
  /// gets to decide it. A guest asking for one (no seed) makes the host pick
  /// and broadcast, so either side can restart the match and both still end
  /// up on the same world.
  void _handleRemoteRematch(Map<String, dynamic> msg) {
    final seed = msg['seed'];
    if (seed is int) {
      resetMatch(seed: seed);
      return;
    }
    if (mode == GameMode.hotspot && net != null && net!.isHost) {
      requestRematch();
    }
  }

  /// Deserialized network JSON is never trusted: a malformed, stale or
  /// out-of-turn message must be ignored rather than crash or fire a shot
  /// that doesn't belong to whoever is currently acting. [_doFire]
  /// re-validates everything again regardless.
  void _handleRemoteFire(Map<String, dynamic> msg) {
    final a = msg['a'], p = msg['p'], w = msg['w'], pl = msg['pl'];
    if (a is! num || p is! num || w is! String) {
      if (kDebugMode) debugPrint('[net] rejected malformed fire message: $msg');
      return;
    }
    if (pl is int && pl != currentPlayer) {
      if (kDebugMode) debugPrint('[net] rejected stale fire for player=$pl, current=$currentPlayer');
      return;
    }
    _doFire(a.toDouble(), p.toDouble(), Weapons.byId(w), fromNetwork: true);
  }

  int get myPlayerIndex {
    if (mode == GameMode.hotspot && net != null) return net!.isHost ? 0 : 1;
    return currentPlayer;
  }

  /// The seat that belongs to this device. The host is player 0 and the
  /// guest player 1 over a hotspot link; in every other mode the local human
  /// is player 0 (hot-seat play shares this device, and the campaign is
  /// single-player).
  int get localPlayerIndex =>
      (mode == GameMode.hotspot && net != null) ? (net!.isHost ? 0 : 1) : 0;

  /// True when this device is the one that should be running the turn clock.
  /// Outside hotspot play that is always true; over the wire only the device
  /// whose turn it is counts down, for the drift reason in [_updateAiming].
  bool get _ownsTurnClock =>
      mode != GameMode.hotspot || net == null || currentPlayer == myPlayerIndex;

  /// Identifies the turn currently being played. Both devices in a hotspot
  /// match end every turn locally and tell the other about it; the token lets
  /// each side recognise the echo of a turn it has already ended and ignore
  /// it, instead of advancing a second time.
  int _turnSeq = 0;
  final Set<int> _endedTurns = {};

  // ---------------------------------------------------------------------------
  // Ticker
  // ---------------------------------------------------------------------------

  void _startTicker() {
    _lastTick = DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  void _tick() {
    if (_disposed) return;
    final now = DateTime.now();
    final dt = (now.difference(_lastTick).inMilliseconds / 1000.0).clamp(0.0, 0.05);
    _lastTick = now;
    time += dt;

    world.update(dt);

    switch (phase) {
      case GamePhase.aiming:
        _updateAiming(dt);
        break;
      case GamePhase.firing:
        _updateFiring(dt);
        break;
      case GamePhase.resolving:
        _updateResolving(dt);
        break;
      case GamePhase.turnTransition:
        _updateTransition(dt);
        break;
      case GamePhase.gameOver:
        break;
    }

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Turn flow
  // ---------------------------------------------------------------------------

  void _beginTurn(int player, {bool initial = false}) {
    currentPlayer = player;
    turnTimeLeft = settings.turnSeconds;
    phase = GamePhase.aiming;
    _shotCommitted = false;
    _aiShotQueued = false;
    _turnSeq++;

    final raft = world.raftOf(player);
    raft?.ensureActiveAlive();
    // The view belongs to whoever is firing — except over a hotspot link,
    // where each device shows only its own deck, so you watch incoming fire
    // arrive rather than being teleported to the enemy's side on their turn.
    // The cut is a hard one on purpose: the rafts are far enough apart that
    // easing across would just be a long sideways pan past the enemy.
    world.lockCam(mode == GameMode.hotspot ? localPlayerIndex : player);

    // A weapon the player has run out of must not stay selected into the next
    // turn, or the fire button would silently do nothing.
    if (!_hasAmmoFor(selectedWeaponId)) selectedWeaponId = Weapons.starter.id;

    statusMessage = players[player].isAi
        ? '${players[player].name} is aiming…'
        : (initial ? 'Pull back and release' : 'Your turn');

    if (!initial) AudioService.instance.sfx('turn');

    if (players[player].isAi) {
      _aiThinkTime = 0.9 + world.rng.range(0, 0.9);
    }
  }

  void _updateAiming(double dt) {
    // The camera stays on the shooter's own raft for the whole aiming phase.
    // It used to ease toward the shot's predicted landing point, which meant
    // a long drag panned the view all the way across to the enemy deck and
    // showed the player exactly where their shot was going. Shots are lobbed
    // blind now — see BattleWorld's camera lock.
    world.holdCam(dt);

    // Only the device whose turn it actually is owns the clock. In hotspot
    // both devices run the same simulation, but their frames never line up
    // exactly, so a shared countdown here would drift and let one side time
    // out a turn the other side was still playing.
    if (_ownsTurnClock) {
      turnTimeLeft -= dt;
      if (turnTimeLeft <= 0) {
        _endTurn();
        return;
      }
    }

    final p = players[currentPlayer];
    if (!p.isAi || _aiShotQueued) return;

    _aiThinkTime -= dt;
    if (_aiThinkTime > 0) return;

    final me = world.raftOf(currentPlayer);
    final targets = world.enemiesOf(currentPlayer);
    if (me == null || !me.alive || targets.isEmpty) return;

    // Aim at a living crew member on the nearest enemy raft.
    targets.sort((a, b) => (a.x - me.x).abs().compareTo((b.x - me.x).abs()));
    final targetRaft = targets.first;
    final liveIdx = [
      for (int i = 0; i < targetRaft.crew.length; i++)
        if (targetRaft.crew[i].alive) i
    ];
    if (liveIdx.isEmpty) return;
    final targetPos = targetRaft.crewPos(liveIdx[world.rng.nextInt(liveIdx.length)]);

    final arsenal = Weapons.all
        .where((w) => settings.enabledWeapons.contains(w.id))
        .toList();
    final shot = AiController(p.aiDifficulty).plan(
      from: me.muzzle,
      targetPos: targetPos,
      facing: me.facing,
      arsenal: arsenal.isEmpty ? [Weapons.starter] : arsenal,
      baseJitter: p.aimJitter,
      powerMultiplier: p.powerMultiplier,
    );

    _aiShotQueued = true;
    aimAngle = shot.angle;
    aimPower = shot.power;
    selectedWeaponId = shot.weapon.id;
    _doFire(shot.angle, shot.power, shot.weapon);
  }

  void _updateFiring(double dt) {
    final s = world.shot;
    // Track the projectile while it is in flight — both for the shooter and
    // for the opponent on the receiving end. The aiming-phase camera lock is
    // deliberately abandoned mid-flight: while the ball is in the air,
    // watching where it goes is the whole show.
    //
    // vel is in design units per 60Hz step; the camera works in units per
    // second, hence the * 60.
    if (s != null) world.trackShot(s.pos.dx, s.vel.dx * 60, dt);

    // Physics steps at a fixed 60Hz so flight is frame-rate independent.
    _accum += dt;
    const step = 1 / 60;
    int guard = 0;
    while (_accum >= step && guard < 4) {
      _accum -= step;
      guard++;
      final outcome = world.stepShot();
      if (outcome != null) {
        _onShotResolved(outcome);
        return;
      }
    }
    if (world.shot == null) {
      phase = GamePhase.resolving;
      _resolveTimer = 0.7;
    }
  }

  void _onShotResolved(ShotOutcome outcome) {
    phase = GamePhase.resolving;
    _resolveTimer = 0.75;

    if (outcome.hitSomething) {
      AudioService.instance.sfx('hit');
      shotsHit++;
    } else {
      AudioService.instance.sfx('splash');
    }
    if (outcome.damage > 0) {
      AudioService.instance.sfx('explosion');
      if (!players[currentPlayer].isAi) {
        damageDealtByHuman += outcome.damage.round();
      }
    }

    statusMessage = outcome.hitSomething
        ? (outcome.hitPlayerSide ? 'You got splashed!' : 'Direct hit!')
        : 'Splash — missed';

    onEvent?.call('shotResolved', {
      'hit': outcome.hitSomething,
      'damage': outcome.damage,
    });
  }

  void _updateResolving(double dt) {
    _resolveTimer -= dt;
    // While the splash / damage read-out plays, ease the camera back to
    // whoever is shooting next. In a single-player / local match that is
    // the next living opponent; over a hotspot link both devices watch
    // their own deck, so we ease to the local player's raft if they are
    // the one coming up.
    final next = _nextAlivePlayer();
    final camTarget = mode == GameMode.hotspot && net != null
        ? localPlayerIndex
        : next;
    world.returnCamTo(camTarget, dt);
    if (_resolveTimer > 0) return;
    if (_checkGameOver()) return;
    _endTurn();
  }

  void _endTurn({bool fromNetwork = false}) {
    if (phase == GamePhase.gameOver) return;
    if (_checkGameOver()) return;
    if (mode == GameMode.hotspot && net != null) {
      _endedTurns.add(_turnSeq);
      if (!fromNetwork) {
        net!.send({'t': 'endTurn', 'pl': currentPlayer, 'seq': _turnSeq});
      }
    }
    // The raft that just shot rotates to its next crew member, so a two-person
    // crew alternates who takes the shot rather than one doing all the work.
    world.raftOf(currentPlayer)?.advanceCrew();
    if (_nextAlivePlayer() == 0) round++;
    phase = GamePhase.turnTransition;
    _transitionTimer = mode == GameMode.local ? 1.2 : 0.45;
    statusMessage = '';
  }

  void _updateTransition(double dt) {
    _transitionTimer -= dt;
    if (_transitionTimer <= 0) _beginTurn(_nextAlivePlayer());
  }

  int _nextAlivePlayer() {
    for (int k = 1; k <= players.length; k++) {
      final idx = (currentPlayer + k) % players.length;
      if (world.raftOf(idx)?.alive ?? false) return idx;
    }
    return currentPlayer;
  }

  bool _checkGameOver() {
    if (_gameEnded) return true;
    final alive = <int>[];
    for (int i = 0; i < players.length; i++) {
      if (world.raftOf(i)?.alive ?? false) alive.add(i);
    }
    if (alive.length > 1 || players.length <= 1) return false;

    _gameEnded = true;
    winner = alive.isEmpty ? -1 : alive.first;
    phase = GamePhase.gameOver;
    statusMessage = winner == -1 ? 'DRAW!' : '${players[winner!].name} WINS!';

    // In hot-seat local play both seats share this device's single account, so
    // a win for either human seat counts for the account. Other modes key off
    // player 0 specifically, since that's the local player.
    final winnerIsHuman = winner != null && winner! >= 0 && !players[winner!].isAi;
    final humanWon = mode == GameMode.local ? winnerIsHuman : (winner == 0 && !players[0].isAi);
    AudioService.instance.sfx(humanWon ? 'victory' : 'defeat');

    final shouldRecord = mode == GameMode.local
        ? players.any((p) => !p.isAi)
        : !players[0].isAi;
    if (shouldRecord) {
      SaveService.instance.recordMatch(
        won: humanWon,
        damageDealt: damageDealtByHuman,
        mode: mode.name,
        map: settings.map.name,
      );
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Aiming + firing
  // ---------------------------------------------------------------------------

  bool get canHumanAct {
    if (phase != GamePhase.aiming || _shotCommitted) return false;
    if (currentPlayer < 0 || currentPlayer >= players.length) return false;
    if (players[currentPlayer].isAi) return false;
    if (mode == GameMode.hotspot && net != null) return currentPlayer == myPlayerIndex;
    return true;
  }

  Raft? get currentRaft => world.raftOf(currentPlayer);

  WeaponDef get selectedWeapon => Weapons.byId(selectedWeaponId);

  /// Weapons offered on the HUD: enabled for this match and either infinite
  /// or actually stocked.
  List<WeaponDef> get availableWeapons => Weapons.all
      .where((w) => settings.enabledWeapons.contains(w.id))
      .where((w) => w.infinite || (ammo[w.id] ?? 0) > 0 || w.id == selectedWeaponId)
      .toList();

  int ammoFor(String weaponId) {
    final w = Weapons.byId(weaponId);
    if (w.infinite) return -1; // sentinel: renders as ∞
    return ammo[weaponId] ?? 0;
  }

  bool _hasAmmoFor(String weaponId) {
    final w = Weapons.byId(weaponId);
    return w.infinite || (ammo[weaponId] ?? 0) > 0;
  }

  bool selectWeapon(String weaponId) {
    if (!_hasAmmoFor(weaponId)) return false;
    selectedWeaponId = weaponId;
    notifyListeners();
    return true;
  }

  /// Applies a pull-back drag. [dx]/[dy] are the pull vector (origin minus
  /// current finger), so pulling back and down aims forward and up.
  void applyPullAim(double dx, double dy) {
    if (!canHumanAct) return;
    final target = shapeAim(dx, dy);
    if (target == null) return;
    final eased = easeAim(aimAngle, aimPower, target);
    aimAngle = eased.angle.clamp(BattleConst.angleMin, BattleConst.angleMax);
    aimPower = eased.power.clamp(BattleConst.powerMin, BattleConst.powerMax);
    aimFine = target.fine;
    notifyListeners();
  }

  /// Fine adjustment from the ▾▴−+ buttons.
  void nudgeAngle(double delta) {
    if (!canHumanAct) return;
    aimAngle = (aimAngle + delta).clamp(BattleConst.angleMin, BattleConst.angleMax);
    notifyListeners();
  }

  void nudgePower(double delta) {
    if (!canHumanAct) return;
    aimPower = (aimPower + delta).clamp(BattleConst.powerMin, BattleConst.powerMax);
    notifyListeners();
  }

  void humanFire() {
    if (!canHumanAct) return;
    if (!_hasAmmoFor(selectedWeaponId)) return;
    final w = selectedWeapon;
    if (mode == GameMode.hotspot && net != null) {
      if (currentPlayer != myPlayerIndex) return;
      net!.send({'t': 'fire', 'a': aimAngle, 'p': aimPower, 'w': w.id, 'pl': currentPlayer});
    }
    _doFire(aimAngle, aimPower, w);
  }

  /// The single choke point every shot passes through — human release, AI plan
  /// or network message. None of those callers are trusted: UI maths can
  /// produce a stray NaN, and network JSON is attacker-adjacent even on a
  /// friendly hotspot link. The firing lock flips before any projectile work
  /// starts, so this can never create two shots for one turn.
  void _doFire(double angle, double power, WeaponDef weapon, {bool fromNetwork = false}) {
    if (_shotCommitted) {
      if (kDebugMode) debugPrint('[fire] rejected: already committed (network=$fromNetwork)');
      return;
    }
    if (phase != GamePhase.aiming) {
      if (kDebugMode) debugPrint('[fire] rejected: phase=$phase (network=$fromNetwork)');
      return;
    }
    if (!angle.isFinite || !power.isFinite) {
      if (kDebugMode) debugPrint('[fire] rejected: non-finite angle=$angle power=$power');
      return;
    }
    final raft = world.raftOf(currentPlayer);
    if (raft == null || !raft.alive) {
      if (kDebugMode) debugPrint('[fire] rejected: no living shooter for player=$currentPlayer');
      return;
    }
    final safeWeapon = Weapons.all.contains(weapon) ? weapon : Weapons.starter;
    final safeAngle = angle.clamp(BattleConst.angleMin, BattleConst.angleMax);
    final safePower = power.clamp(BattleConst.powerMin, BattleConst.powerMax);

    // Only the human side spends ammo; enemy loadouts are scripted per level.
    if (!players[currentPlayer].isAi && !safeWeapon.infinite) {
      final left = ammo[safeWeapon.id] ?? 0;
      if (left <= 0) {
        if (kDebugMode) debugPrint('[fire] rejected: out of ${safeWeapon.id}');
        return;
      }
      ammo[safeWeapon.id] = left - 1;
      if (ammo[safeWeapon.id] == 0) selectedWeaponId = Weapons.starter.id;
    }

    _shotCommitted = true;
    phase = GamePhase.firing;
    _accum = 0;
    aimAngle = safeAngle;
    aimPower = safePower;
    isCharging = false;

    if (kDebugMode) {
      debugPrint('[fire] player=$currentPlayer weapon=${safeWeapon.id} '
          'angle=${safeAngle.toStringAsFixed(1)} power=${safePower.toStringAsFixed(1)} '
          'network=$fromNetwork');
    }

    world.fire(
      from: raft.muzzle,
      angleDeg: safeAngle,
      power: safePower,
      facing: raft.facing,
      weapon: safeWeapon,
      owner: currentPlayer,
      powerMultiplier: players[currentPlayer].powerMultiplier,
    );

    shotsFired++;
    SaveService.instance.data.shotsFired++;
    AudioService.instance.sfx('fire');
    statusMessage = players[currentPlayer].isAi ? 'Return fire!' : 'Shot away!';
  }

  /// Restarts the match. In hotspot play this is negotiated rather than
  /// local: both devices must land on the same seed, so the host picks one
  /// and tells the guest.
  void requestRematch() {
    if (mode == GameMode.hotspot && net != null) {
      if (net!.isHost) {
        final seed = DateTime.now().millisecondsSinceEpoch;
        net!.send({'t': 'rematch', 'seed': seed});
        resetMatch(seed: seed);
      } else {
        net!.send({'t': 'rematch'});
      }
      return;
    }
    resetMatch();
  }

  /// Accuracy as a percentage string for the result panel.
  String get accuracyLabel =>
      shotsFired == 0 ? '—' : '${(shotsHit / shotsFired * 100).round()}%';

  /// Living enemy rafts currently off the edge of the view — drives the
  /// design's "N FOE AHEAD ▸" marker, which is what tells the player who
  /// they are lobbing at now that the camera never shows the enemy.
  int get offscreenFoes => world
      .enemiesOf(localPlayerIndex)
      .where((r) => !_isVisible(r.x))
      .length;

  bool _isVisible(double worldX) => worldX >= world.cam - 70 && worldX <= world.camRight + 70;

  /// Enemy crew still afloat — shown on the HUD so a blind battle still says
  /// what is left to hit.
  int get foesLeft =>
      world.enemiesOf(localPlayerIndex).fold(0, (n, r) => n + r.living.length);

  // ---------------------------------------------------------------------------

  void resetMatch({int? seed}) {
    _gameEnded = false;
    winner = null;
    round = 1;
    damageDealtByHuman = 0;
    shotsFired = 0;
    shotsHit = 0;
    _shotCommitted = false;
    _aiShotQueued = false;
    _turnSeq = 0;
    _endedTurns.clear();
    _accum = 0;
    aimAngle = 45;
    aimPower = 70;
    _setup(seed ?? DateTime.now().millisecondsSinceEpoch);
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    super.dispose();
  }
}
