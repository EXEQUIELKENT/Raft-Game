import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'ai.dart';
import 'audio.dart';
import 'maps.dart';
import 'models.dart';
import 'net.dart';
import 'physics.dart';
import 'save.dart';

enum GamePhase { building, aiming, firing, settling, turnTransition, gameOver }

enum GameMode { vsAi, local, hotspot }

class PlayerConfig {
  final String name;
  final int colorIndex;
  final int hatIndex;
  final bool isAi;
  final AiDifficulty aiDifficulty;
  final int? netId; // for hotspot: which network peer controls this player

  PlayerConfig({
    required this.name,
    this.colorIndex = 0,
    this.hatIndex = 0,
    this.isAi = false,
    this.aiDifficulty = AiDifficulty.normal,
    this.netId,
  });
}

class MatchSettings {
  MapDef map;
  int buildLimit;
  double startHp;
  double turnSeconds;
  double windStrength; // 0..1 multiplier
  List<String> enabledWeapons;

  MatchSettings({
    MapDef? map,
    this.buildLimit = 10,
    this.startHp = 100,
    this.turnSeconds = 30,
    this.windStrength = 0.5,
    List<String>? enabledWeapons,
  })  : map = map ?? GameMaps.all.first,
        enabledWeapons = enabledWeapons ?? Weapons.all.map((w) => w.id).toList();
}

class GameController extends ChangeNotifier {
  late PhysicsWorld world;
  MatchSettings settings;
  List<PlayerConfig> players;
  GameMode mode;
  NetService? net;

  GamePhase phase = GamePhase.building;
  int currentPlayer = 0;
  double wind = 0;
  double turnTimeLeft = 0;
  int round = 1;

  // aiming state (for human current player)
  double aimAngle = -pi / 4; // radians world
  double aimPower = 0.6;
  String selectedWeaponId = 'cannon';
  bool isCharging = false;

  // building state
  int buildingPlayer = 0;
  int piecesLeft = 0;

  // camera
  Offset camPos = Offset.zero;
  double camZoom = 1.0;
  Offset _camTarget = Offset.zero;
  double _camZoomTarget = 1.0;
  Projectile? _followedProjectile;

  // results
  int? winner;
  int damageDealtByHuman = 0;

  // AI
  AiShot? _pendingAiShot;
  double _aiThinkTime = 0;

  Timer? _ticker;
  double _accum = 0;
  DateTime _lastTick = DateTime.now();
  bool _disposed = false;
  double time = 0;
  int settleCountdown = 0;
  bool _gameEnded = false;
  String statusMessage = '';
  void Function(String kind, Map<String, dynamic> data)? onEvent;

  static const double worldW = 1100;
  static const double worldH = 760;

  GameController({
    required this.settings,
    required this.players,
    required this.mode,
    this.net,
    int? seed,
    bool skipBuildPhase = false,
  }) {
    final s = seed ?? DateTime.now().millisecondsSinceEpoch;
    world = PhysicsWorld(
      width: worldW,
      height: worldH,
      waterLevel: worldH - 150,
      seed: s,
      mapHazard: settings.map.hazard,
      environment: settings.map.terrain,
    );
    _setupWorld(s, skipBuildPhase: skipBuildPhase);
  }

  void _setupWorld(int seed, {bool skipBuildPhase = false}) {
    MapBuilder.build(world, settings.map, players.length, seed.toDouble());
    // wind: each map has its own base wind (e.g. Frosty Peaks is gustier
    // than Coconut Cove), randomized around by the player's wind setting.
    wind = (settings.map.windBase + world.rng.range(-1, 1) * settings.windStrength).clamp(-1.0, 1.0);
    world.wind = wind;

    // spawn characters
    for (int i = 0; i < players.length; i++) {
      final spawn = MapBuilder.spawnFor(world, i, players.length);
      world.addCharacter(pos: spawn, playerIndex: i, hp: settings.startHp);
    }

    piecesLeft = settings.buildLimit;
    buildingPlayer = 0;

    if (skipBuildPhase || settings.buildLimit == 0) {
      phase = GamePhase.aiming;
      _beginTurn(0, initial: true);
    } else {
      phase = GamePhase.building;
      statusMessage = '${players[0].name}: fortify your raft! ($piecesLeft left)';
    }

    // initial camera
    final c = world.charactersOf(0);
    camPos = c.isNotEmpty ? c.first.pos : Offset(worldW / 2, worldH / 2);
    _camTarget = camPos;
    _fitZoom();

    _hookNet();
    _startTicker();
  }

  // -------------------------------------------------------------------------
  // Net wiring
  // -------------------------------------------------------------------------

  void _hookNet() {
    if (net == null) return;
    net!.onMessage = (msg) {
      switch (msg['t']) {
        case 'fire':
          // remote player fired
          final w = Weapons.byId(msg['w']);
          _doFire(msg['a'], msg['p'], w, fromNetwork: true);
          break;
        case 'block':
          final piece = PieceDef.catalogue.firstWhere((e) => e.id == msg['id'], orElse: () => PieceDef.catalogue.first);
          _placeBlock(msg['x'], msg['y'], msg['r'], piece, players[msg['pl']], fromNetwork: true);
          break;
        case 'buildDone':
          _advanceBuilding(fromNetwork: true);
          break;
        case 'endTurn':
          if (phase == GamePhase.aiming) _endTurn(fromNetwork: true);
          break;
        case 'rematch':
          resetMatch(seed: msg['seed']);
          break;
      }
    };
  }

  /// Host -> applies incoming actions for remote players. Client -> sends local actions.
  bool get _isClient => net != null && !net!.isHost;

  int get myPlayerIndex {
    if (mode == GameMode.hotspot && net != null) {
      return net!.isHost ? 0 : 1;
    }
    return currentPlayer;
  }

  // -------------------------------------------------------------------------
  // Ticker
  // -------------------------------------------------------------------------

  void _startTicker() {
    _lastTick = DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  void _tick() {
    if (_disposed) return;
    final now = DateTime.now();
    var dt = (now.difference(_lastTick).inMilliseconds / 1000.0).clamp(0.0, 0.05);
    _lastTick = now;
    time += dt;

    // fixed step physics at 60Hz
    if (phase == GamePhase.firing || phase == GamePhase.settling || phase == GamePhase.aiming || phase == GamePhase.building || phase == GamePhase.gameOver) {
      _accum += dt;
      const step = 1 / 60;
      int guard = 0;
      while (_accum >= step && guard < 4) {
        world.step(step);
        _accum -= step;
        guard++;
      }
      _processWorldEvents();
    }

    // phase logic
    switch (phase) {
      case GamePhase.firing:
        _updateFiring(dt);
        break;
      case GamePhase.settling:
        _updateSettling(dt);
        break;
      case GamePhase.aiming:
        _updateAiming(dt);
        break;
      case GamePhase.turnTransition:
        _updateTransition(dt);
        break;
      case GamePhase.gameOver:
        break;
      case GamePhase.building:
        break;
    }

    // camera easing
    camPos = Offset.lerp(camPos, _camTarget, (dt * 4.5).clamp(0.0, 1.0))!;
    camZoom = camZoom + (_camZoomTarget - camZoom) * (dt * 3).clamp(0.0, 1.0);

    notifyListeners();
  }

  void _processWorldEvents() {
    for (final e in world.events) {
      switch (e.kind) {
        case 'explosion':
          AudioService.instance.sfx('explosion');
          break;
        case 'blockDestroyed':
          final mat = e.data['material'] as String;
          AudioService.instance.sfx(switch (mat) {
            'wood' || 'raft' => 'break_wood',
            'stone' => 'break_stone',
            'metal' => 'break_metal',
            'glass' => 'break_glass',
            _ => 'break_wood',
          });
          break;
        case 'charHit':
          AudioService.instance.sfx('hit');
          if (e.data['by'] == 0 || (e.data['by'] is int && players[e.data['by'] as int].isAi == false)) {
            damageDealtByHuman += (e.data['dmg'] as num).round();
          }
          break;
        case 'eliminated':
          AudioService.instance.sfx('eliminate');
          _checkGameOver();
          break;
        case 'splash':
          AudioService.instance.sfx('splash');
          break;
        case 'bounce':
          AudioService.instance.sfx('bounce', volume: 0.6);
          break;
        case 'drill':
          AudioService.instance.sfx('drill', volume: 0.7);
          break;
        case 'fuse':
          AudioService.instance.sfx('burn', volume: 0.7);
          break;
        case 'fire':
          AudioService.instance.sfx('fire');
          break;
      }
      onEvent?.call(e.kind, e.data);
    }
  }

  // -------------------------------------------------------------------------
  // Turn flow
  // -------------------------------------------------------------------------

  void _beginTurn(int player, {bool initial = false}) {
    currentPlayer = player;
    // vary wind slightly each turn, drifting back toward the map's base wind
    // so a gusty map (e.g. Frosty Peaks) stays gusty over a long match
    if (!initial) {
      wind = (wind + world.rng.range(-0.25, 0.25) + (settings.map.windBase - wind) * 0.15).clamp(-1.0, 1.0);
      world.wind = wind;
    }
    turnTimeLeft = settings.turnSeconds;
    phase = GamePhase.aiming;
    final chars = world.charactersOf(player);
    if (chars.isNotEmpty) {
      _camTarget = chars.first.pos;
      _camZoomTarget = 1.0;
    }
    _fitZoom();
    statusMessage = "${players[player].name}'s turn";
    AudioService.instance.sfx('turn');

    final p = players[player];
    if (p.isAi) {
      _aiThinkTime = 1.0 + world.rng.range(0, 1.2);
      _pendingAiShot = null;
    }
  }

  void _updateAiming(double dt) {
    // turn timer
    turnTimeLeft -= dt;
    if (turnTimeLeft <= 0) {
      _endTurn();
      return;
    }

    final p = players[currentPlayer];
    if (p.isAi) {
      _aiThinkTime -= dt;
      if (_aiThinkTime <= 0 && _pendingAiShot == null) {
        final me = world.charactersOf(currentPlayer);
        final enemies = <PhysBody>[];
        for (int i = 0; i < players.length; i++) {
          if (i != currentPlayer) enemies.addAll(world.charactersOf(i));
        }
        if (me.isEmpty || enemies.isEmpty) return;
        final arsenal = players[currentPlayer].isAi
            ? Weapons.unlockedAt(3 + currentPlayer) // AI gets decent weapons
            : SaveService.instance.data.unlockedWeapons;
        final enabled = arsenal.where((w) => settings.enabledWeapons.contains(w.id)).toList();
        final ai = AiController(p.aiDifficulty);
        _pendingAiShot = ai.plan(world, me.first, enemies, enabled.isEmpty ? [Weapons.all.first] : enabled);
      }
      if (_pendingAiShot != null) {
        // animate aim toward target then fire
        final shot = _pendingAiShot!;
        aimAngle = shot.angle;
        aimPower = shot.power;
        selectedWeaponId = shot.weapon.id;
        _doFire(shot.angle, shot.power, shot.weapon);
        _pendingAiShot = null;
      }
    }
  }

  void _updateFiring(double dt) {
    // camera follows projectile
    if (world.projectiles.isNotEmpty) {
      final p = world.projectiles.first;
      _followedProjectile = p;
      _camTarget = p.pos;
      _camZoomTarget = 0.72;
    }
    if (!world.hasActiveProjectile) {
      phase = GamePhase.settling;
      settleCountdown = 0;
      _followedProjectile = null;
    }
  }

  void _updateSettling(double dt) {
    settleCountdown++;
    // zoom out to see the chaos
    _camZoomTarget = 0.62;
    // track fastest moving character (flying ragdolls are fun to watch)
    PhysBody? fastest;
    double best = 0;
    for (final b in world.bodies) {
      if (b.type == BodyType.character && !b.dead && b.vel.distance > best) {
        best = b.vel.distance;
        fastest = b;
      }
    }
    if (fastest != null && best > 80) {
      _camTarget = fastest.pos;
    }
    if (world.settled || settleCountdown > 60 * 6) {
      _endTurn();
    }
  }

  double _transitionTimer = 0;
  void _updateTransition(double dt) {
    _transitionTimer -= dt;
    if (_transitionTimer <= 0) {
      _beginTurn(_nextAlivePlayer());
    }
  }

  void _endTurn({bool fromNetwork = false}) {
    if (phase == GamePhase.gameOver) return;
    if (_checkGameOver()) return;
    if (mode == GameMode.hotspot && net != null && !fromNetwork) {
      net!.send({'t': 'endTurn'});
    }
    world.clearDynamicRemnants();
    if (_nextAlivePlayer() == 0) round++;
    // transition for local multiplayer privacy / clarity
    phase = GamePhase.turnTransition;
    _transitionTimer = mode == GameMode.local ? 1.6 : 0.6;
    statusMessage = '';
  }

  int _nextAlivePlayer() {
    for (int k = 1; k <= players.length; k++) {
      final idx = (currentPlayer + k) % players.length;
      if (world.charactersOf(idx).isNotEmpty) return idx;
    }
    return currentPlayer;
  }

  bool _checkGameOver() {
    if (_gameEnded) return true;
    final alive = <int>[];
    for (int i = 0; i < players.length; i++) {
      if (world.charactersOf(i).isNotEmpty) alive.add(i);
    }
    if (alive.length <= 1 && players.length > 1) {
      _gameEnded = true;
      winner = alive.isEmpty ? -1 : alive.first;
      phase = GamePhase.gameOver;
      statusMessage = winner == null || winner == -1 ? 'DRAW!' : '${players[winner!].name} WINS!';
      final humanWon = winner == 0 && !players[0].isAi;
      AudioService.instance.sfx(humanWon ? 'victory' : 'defeat');
      // record progression for human player 0
      if (!players[0].isAi) {
        SaveService.instance.recordMatch(
          won: humanWon,
          damageDealt: damageDealtByHuman,
          mode: mode.name,
          map: settings.map.name,
        );
      }
      return true;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Firing (human input or AI or network)
  // -------------------------------------------------------------------------

  Offset get muzzlePos {
    final chars = world.charactersOf(currentPlayer);
    if (chars.isEmpty) return Offset.zero;
    final c = chars.first.pos;
    return c + Offset(cos(aimAngle), sin(aimAngle)) * 30;
  }

  bool get canHumanAct {
    if (phase != GamePhase.aiming) return false;
    final p = players[currentPlayer];
    if (p.isAi) return false;
    if (mode == GameMode.hotspot && net != null) {
      return currentPlayer == myPlayerIndex;
    }
    return true;
  }

  void humanFire() {
    if (!canHumanAct || phase != GamePhase.aiming) return;
    final w = Weapons.byId(selectedWeaponId);
    if (mode == GameMode.hotspot && net != null && !_isClientLocalTurn()) {
      return;
    }
    if (mode == GameMode.hotspot && net != null) {
      net!.send({'t': 'fire', 'a': aimAngle, 'p': aimPower, 'w': w.id});
    }
    _doFire(aimAngle, aimPower, w);
  }

  bool _isClientLocalTurn() => currentPlayer == myPlayerIndex;

  void _doFire(double angle, double power, WeaponDef weapon, {bool fromNetwork = false}) {
    aimAngle = angle;
    aimPower = power;
    final from = muzzlePos;
    world.fire(from: from, angleRad: angle, power: power, weapon: weapon, owner: currentPlayer);
    SaveService.instance.data.shotsFired++;
    phase = GamePhase.firing;
    AudioService.instance.sfx('fire');
    if (weapon.behavior == 'rocket') AudioService.instance.sfx('whoosh', volume: 0.6);
  }

  // -------------------------------------------------------------------------
  // Building phase
  // -------------------------------------------------------------------------

  PlayerConfig get buildingPlayerConfig => players[buildingPlayer];

  bool get canHumanBuild {
    if (phase != GamePhase.building) return false;
    if (mode == GameMode.hotspot && net != null) {
      return buildingPlayer == myPlayerIndex;
    }
    return !players[buildingPlayer].isAi;
  }

  /// Build area: near the player's spawn
  Rect buildAreaFor(int player) {
    final spawn = MapBuilder.spawnFor(world, player, players.length);
    return Rect.fromCenter(center: Offset(spawn.dx, spawn.dy - 40), width: 300, height: 280);
  }

  bool placeBuildingPiece(double x, double y, double rot, PieceDef piece) {
    if (!canHumanBuild || piecesLeft <= 0) return false;
    if (mode == GameMode.hotspot && net != null) {
      net!.send({'t': 'block', 'id': piece.id, 'x': x, 'y': y, 'r': rot, 'pl': buildingPlayer});
    }
    return _placeBlock(x, y, rot, piece, players[buildingPlayer]);
  }

  bool _placeBlock(double x, double y, double rot, PieceDef piece, PlayerConfig player, {bool fromNetwork = false}) {
    final area = buildAreaFor(buildingPlayer);
    if (!area.contains(Offset(x, y))) return false;
    // avoid placing on existing bodies
    final testRect = Rect.fromCenter(center: Offset(x, y), width: piece.size.width, height: piece.size.height);
    for (final b in world.bodies) {
      if (b.dead) continue;
      if (b.aabb.inflate(-4).overlaps(testRect)) return false;
    }
    world.addBlock(
      pos: Offset(x, y),
      size: piece.size,
      material: piece.material,
      angle: rot,
      playerIndex: buildingPlayer,
    );
    piecesLeft--;
    SaveService.instance.data.blocksPlaced++;
    AudioService.instance.sfx('place');
    statusMessage = '${players[buildingPlayer].name}: fortify! ($piecesLeft left)';
    if (piecesLeft <= 0) _advanceBuilding(fromNetwork: fromNetwork);
    return true;
  }

  void finishBuilding({bool fromNetwork = false}) {
    if (mode == GameMode.hotspot && net != null && !fromNetwork) {
      net!.send({'t': 'buildDone'});
    }
    _advanceBuilding(fromNetwork: fromNetwork);
  }

  void _advanceBuilding({bool fromNetwork = false}) {
    // AI builds automatically
    final next = buildingPlayer + 1;
    if (next >= players.length) {
      // done building — auto-build for AI already handled; start battle
      phase = GamePhase.aiming;
      _beginTurn(0, initial: true);
      return;
    }
    buildingPlayer = next;
    piecesLeft = settings.buildLimit;
    if (players[buildingPlayer].isAi) {
      _aiBuild(buildingPlayer);
      _advanceBuilding(fromNetwork: fromNetwork);
    } else {
      statusMessage = '${players[buildingPlayer].name}: fortify your raft! ($piecesLeft left)';
      final spawn = MapBuilder.spawnFor(world, buildingPlayer, players.length);
      _camTarget = spawn;
      _camZoomTarget = 0.8;
    }
  }

  void _aiBuild(int player) {
    final spawn = MapBuilder.spawnFor(world, player, players.length);
    final dir = spawn.dx < worldW / 2 ? -1 : 1;
    final rnd = Random(player * 999);
    int placed = 0;
    int guard = 0;
    while (placed < settings.buildLimit && guard < 60) {
      guard++;
      final piece = PieceDef.catalogue[rnd.nextInt(PieceDef.catalogue.length)];
      final x = spawn.dx + dir * (30 + rnd.nextDouble() * 90) + (rnd.nextDouble() - 0.5) * 30;
      final y = spawn.dy - 20 - rnd.nextDouble() * 130;
      final rot = piece.size.width > piece.size.height ? 0.0 : (rnd.nextBool() ? 0.0 : pi / 2);
      final testRect = Rect.fromCenter(center: Offset(x, y), width: piece.size.width + 8, height: piece.size.height + 8);
      bool blocked = false;
      for (final b in world.bodies) {
        if (!b.dead && b.aabb.overlaps(testRect)) { blocked = true; break; }
      }
      if (blocked) continue;
      world.addBlock(pos: Offset(x, y), size: piece.size, material: piece.material, angle: rot, playerIndex: player);
      placed++;
    }
  }

  // -------------------------------------------------------------------------
  // Camera helpers
  // -------------------------------------------------------------------------

  void _fitZoom() {
    _camZoomTarget = 1.0;
  }

  void zoomCamera(double delta) {
    _camZoomTarget = (_camZoomTarget + delta).clamp(0.5, 1.6);
  }

  void panCamera(Offset delta) {
    if (phase == GamePhase.aiming) {
      _camTarget += delta / camZoom;
      _camTarget = Offset(
        _camTarget.dx.clamp(0, worldW),
        _camTarget.dy.clamp(0, worldH),
      );
    }
  }

  void resetCameraToPlayer() {
    final chars = world.charactersOf(currentPlayer);
    if (chars.isNotEmpty) {
      _camTarget = chars.first.pos;
      _camZoomTarget = 1.0;
    }
  }

  // -------------------------------------------------------------------------

  void resetMatch({int? seed}) {
    _gameEnded = false;
    winner = null;
    round = 1;
    damageDealtByHuman = 0;
    final s = seed ?? DateTime.now().millisecondsSinceEpoch;
    world = PhysicsWorld(
      width: worldW,
      height: worldH,
      waterLevel: worldH - 150,
      seed: s,
      mapHazard: settings.map.hazard,
      environment: settings.map.terrain,
    );
    _setupWorld(s, skipBuildPhase: settings.buildLimit == 0);
  }

  List<WeaponDef> get availableWeapons {
    final base = players[currentPlayer].isAi
        ? Weapons.all
        : SaveService.instance.data.unlockedWeapons;
    return base.where((w) => settings.enabledWeapons.contains(w.id)).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    super.dispose();
  }
}
