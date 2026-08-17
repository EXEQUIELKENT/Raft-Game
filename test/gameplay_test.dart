import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/physics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Full match smoke test: build, fire, physics, AI', () {
    final settings = MatchSettings(
      map: GameMaps.all.first,
      buildLimit: 5,
      startHp: 100,
      turnSeconds: 30,
    );
    final players = [
      PlayerConfig(name: 'P1', colorIndex: 0),
      PlayerConfig(name: 'AI', colorIndex: 1, isAi: true, aiDifficulty: AiDifficulty.normal),
    ];
    final ctrl = GameController(settings: settings, players: players, mode: GameMode.vsAi, seed: 12345);

    expect(ctrl.phase, GamePhase.building);
    expect(ctrl.world.charactersOf(0).length, 1);
    expect(ctrl.world.charactersOf(1).length, 1);

    // settle world
    for (int i = 0; i < 120; i++) {
      ctrl.world.step(1 / 60);
    }

    // place a block as player 0 (inside the build area, clear of the starter wall)
    final spawn = MapBuilder.spawnFor(ctrl.world, 0, 2);
    final ok = ctrl.placeBuildingPiece(spawn.dx + 40, spawn.dy - 90, 0, PieceDef.catalogue[0]);
    expect(ok, true);
    expect(ctrl.piecesLeft, 4);
    ctrl.finishBuilding(); // P1 done -> P2 building
    expect(ctrl.buildingPlayer, 1);
    ctrl.finishBuilding(); // P2 done -> battle begins
    expect(ctrl.phase, GamePhase.aiming);
    expect(ctrl.currentPlayer, 0);

    // human fires a rocket
    ctrl.aimAngle = -0.6;
    ctrl.aimPower = 0.8;
    ctrl.selectedWeaponId = 'rocket';
    ctrl.humanFire();
    expect(ctrl.phase, GamePhase.firing);
    expect(ctrl.world.projectiles.length, 1);

    // simulate ~12 seconds of physics
    int explosions = 0;
    for (int i = 0; i < 60 * 12; i++) {
      ctrl.world.step(1 / 60);
      for (final e in ctrl.world.events) {
        if (e.kind == 'explosion') explosions++;
      }
    }
    expect(explosions, greaterThanOrEqualTo(1));
    expect(ctrl.world.projectiles.length, 0);

    // AI planning works
    final aiShot = AiController(AiDifficulty.normal).plan(
      ctrl.world,
      ctrl.world.charactersOf(1).first,
      ctrl.world.charactersOf(0),
      Weapons.unlockedAt(3),
    );
    expect(aiShot.power, inInclusiveRange(0.1, 1.0));
    expect(aiShot.angle, isNot(0.0));

    // grenade: fuse eventually triggers explosion
    ctrl.world.fire(
      from: MapBuilder.spawnFor(ctrl.world, 0, 2),
      angleRad: -0.8,
      power: 0.7,
      weapon: Weapons.byId('grenade'),
      owner: 0,
    );
    for (int i = 0; i < 60 * 10 && ctrl.world.projectiles.isNotEmpty; i++) {
      ctrl.world.step(1 / 60);
      for (final e in ctrl.world.events) {
        if (e.kind == 'explosion') explosions++;
      }
    }
    expect(explosions, greaterThanOrEqualTo(2));

    // cluster split
    ctrl.world.fire(
      from: MapBuilder.spawnFor(ctrl.world, 0, 2),
      angleRad: -1.0,
      power: 0.6,
      weapon: Weapons.byId('cluster'),
      owner: 0,
    );
    bool split = false;
    for (int i = 0; i < 60 * 8 && !split; i++) {
      ctrl.world.step(1 / 60);
      for (final e in ctrl.world.events) {
        if (e.kind == 'split') split = true;
      }
    }
    expect(split, true);

    ctrl.dispose();
  });

  test('All 6 maps build without errors and spawn both players', () {
    for (final map in GameMaps.all) {
      final world = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: 99);
      MapBuilder.build(world, map, 2, 99);
      expect(world.bodies.length, greaterThan(2), reason: 'map ${map.id}');
      final s0 = MapBuilder.spawnFor(world, 0, 2);
      final s1 = MapBuilder.spawnFor(world, 1, 2);
      expect(s0.dy < world.waterLevel, true, reason: 'map ${map.id} spawn above water');
      expect(s1.dy < world.waterLevel, true, reason: 'map ${map.id} spawn above water');
      for (int i = 0; i < 300; i++) {
        world.step(1 / 60);
      }
    }
  });

  test('Knockback ragdoll: character hit by explosion moves & tumbles', () {
    final world = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: 7);
    world.addBlock(pos: const Offset(550, 600), size: const Size(300, 20), material: MaterialType.stone, isStatic: true);
    final c = world.addCharacter(pos: const Offset(550, 560), playerIndex: 1);
    for (int i = 0; i < 60; i++) {
      world.step(1 / 60);
    }
    final beforeHp = c.hp;
    world.explode(const Offset(520, 570), 100, 30, 2.0);
    expect(c.hp < beforeHp || c.vel.distance > 50 || c.dead, true);
    for (int i = 0; i < 180; i++) {
      world.step(1 / 60);
    }
  });
}
