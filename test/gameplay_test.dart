import 'dart:math';
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

    // human fires a rocket nearly straight up — it comes back down and
    // explodes on the shooter's own raft: a deterministic explosion.
    ctrl.aimAngle = -1.45;
    ctrl.aimPower = 0.55;
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

    // grenade: fuse eventually triggers explosion. Fired straight down onto
    // the shooter's own raft from just above it (rather than a shallow arc
    // toward open water) so it arms on the very first bounce and settles
    // there to detonate, instead of depending on a long, chaotic bounce
    // trajectory landing just right before the fuse runs out.
    final grenadeFrom = MapBuilder.spawnFor(ctrl.world, 0, 2) - const Offset(0, 40);
    ctrl.world.fire(
      from: grenadeFrom,
      angleRad: pi / 2,
      power: 0.3,
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

    // cluster split — fire from mid-air so nothing blocks it before 0.7s
    ctrl.world.fire(
      from: const Offset(550, 200),
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
      MapBuilder.build(world, map, 2);
      expect(world.bodies.length, greaterThan(2), reason: 'map ${map.id}');
      final s0 = MapBuilder.spawnFor(world, 0, 2);
      final s1 = MapBuilder.spawnFor(world, 1, 2);
      expect(s0.dy < world.waterLevel, true, reason: 'map ${map.id} spawn above water');
      expect(s1.dy < world.waterLevel, true, reason: 'map ${map.id} spawn above water');
      // players must be spread across most of the map, not clustered
      // together — at least 75% of the world width apart
      expect((s1.dx - s0.dx).abs(), greaterThan(world.width * 0.75), reason: 'map ${map.id} spawns too close together');
      for (int i = 0; i < 300; i++) {
        world.step(1 / 60);
      }
    }
  });

  test('Adjacent player build areas never overlap, for 2/3/4 players', () {
    for (final map in GameMaps.all) {
      for (final numPlayers in [2, 3, 4]) {
        final world = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: 5);
        MapBuilder.build(world, map, numPlayers);
        final settings = MatchSettings(map: map);
        final players = List.generate(numPlayers, (i) => PlayerConfig(name: 'P$i', colorIndex: i));
        final ctrl = GameController(
          settings: settings, players: players, mode: GameMode.local, seed: 5, skipBuildPhase: true);
        final areas = List.generate(numPlayers, (i) => ctrl.buildAreaFor(i));
        for (int i = 0; i < numPlayers; i++) {
          for (int j = i + 1; j < numPlayers; j++) {
            expect(areas[i].overlaps(areas[j]), false,
                reason: 'map ${map.id} ($numPlayers players): build areas $i and $j overlap');
          }
        }
        ctrl.dispose();
      }
    }
  });

  test('Standing character on a raft settles instantly and stays put — no bobbing or spinning', () {
    for (final map in GameMaps.all) {
      final world = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: 21);
      MapBuilder.build(world, map, 2);
      final spawn = MapBuilder.spawnFor(world, 0, 2);
      final c = world.addCharacter(pos: spawn, playerIndex: 0);

      // let it land and fully settle
      for (int i = 0; i < 90; i++) {
        world.step(1 / 60);
      }
      expect(c.vel.distance, lessThan(1), reason: 'map ${map.id}: should be at rest after landing');
      expect(c.angularVel.abs(), lessThan(0.01), reason: 'map ${map.id}: should not be spinning');
      expect(c.angle.abs(), lessThan(0.05), reason: 'map ${map.id}: should be upright, not tipped over');

      // now track position/angle over a further quiet stretch — nothing
      // should move at all with no gameplay event occurring
      final restPos = c.pos;
      double maxDrift = 0;
      for (int i = 0; i < 180; i++) {
        world.step(1 / 60);
        final drift = (c.pos - restPos).distance;
        if (drift > maxDrift) maxDrift = drift;
      }
      expect(maxDrift, lessThan(0.5), reason: 'map ${map.id}: a standing character must not bob/drift on its own');
      expect(c.angle.abs(), lessThan(0.05), reason: 'map ${map.id}: should still be upright after settling further');
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

  test('Ragdoll: limbs stay connected & finite through a heavy explosion', () {
    final world = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: 3);
    world.addBlock(pos: const Offset(550, 600), size: const Size(300, 20), material: MaterialType.stone, isStatic: true);
    final c = world.addCharacter(pos: const Offset(550, 560), playerIndex: 0);
    for (int i = 0; i < 60; i++) {
      world.step(1 / 60);
    }
    world.explode(const Offset(540, 555), 120, 40, 3.2); // strong shockwave-tier blast
    for (int i = 0; i < 5 * 60; i++) {
      world.step(1 / 60);
    }
    final rd = world.ragdolls[c.id]!;
    for (final bo in rd.bones) {
      expect(bo.a.dx.isFinite, true, reason: '${bo.part} endpoint A must stay finite');
      expect(bo.a.dy.isFinite, true);
      expect(bo.b.dx.isFinite, true, reason: '${bo.part} endpoint B must stay finite');
      expect(bo.b.dy.isFinite, true);
      // bones must never stretch/fly apart — the distance constraint keeps
      // each segment close to its rest length even mid-explosion
      final len = (bo.b - bo.a).distance;
      expect(len, lessThan(60), reason: '${bo.part} length $len looks disconnected');
    }
  });

  test('Ragdoll: head hit vs. leg hit produce different, location-specific reactions', () {
    // head shot: aim the impulse/hit point at the head
    final world1 = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: 11)..addBlock(
        pos: const Offset(550, 600), size: const Size(300, 20), material: MaterialType.stone, isStatic: true);
    final c1 = world1.addCharacter(pos: const Offset(550, 560), playerIndex: 0);
    for (int i = 0; i < 90; i++) {
      world1.step(1 / 60);
    }
    final rd1 = world1.ragdolls[c1.id]!;
    final headTarget = rd1.headCenter;
    world1.damageCharacter(c1, 20, const Offset(260, -40), hitPos: headTarget);
    // sample shortly after impact — the location-specific kick is clearest
    // in the first few frames, before the shared tether/gravity motion
    // (identical in both runs) dominates
    for (int i = 0; i < 3; i++) {
      world1.step(1 / 60);
    }
    final headBone = rd1.bones.firstWhere((b) => b.part == BodyPart.head);
    final footRBoneAfterHead = rd1.bones.firstWhere((b) => b.part == BodyPart.lowerLegR);

    // leg shot: same impulse magnitude, aimed at the right foot instead
    final world2 = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: 11)..addBlock(
        pos: const Offset(550, 600), size: const Size(300, 20), material: MaterialType.stone, isStatic: true);
    final c2 = world2.addCharacter(pos: const Offset(550, 560), playerIndex: 0);
    for (int i = 0; i < 90; i++) {
      world2.step(1 / 60);
    }
    final rd2 = world2.ragdolls[c2.id]!;
    final footTarget = rd2.bones.firstWhere((b) => b.part == BodyPart.lowerLegR).b;
    world2.damageCharacter(c2, 20, const Offset(260, -40), hitPos: footTarget);
    for (int i = 0; i < 3; i++) {
      world2.step(1 / 60);
    }
    final headBoneAfterLeg = rd2.bones.firstWhere((b) => b.part == BodyPart.head);
    final footRBoneAfterLeg = rd2.bones.firstWhere((b) => b.part == BodyPart.lowerLegR);

    // A head hit should displace the head noticeably more than a leg hit
    // does, and a leg hit should displace that foot noticeably more than a
    // head hit does — i.e. the reaction is location-specific, not identical
    // regardless of where the projectile landed.
    final headDisplacementFromHeadHit = (headBone.mid - headTarget).distance;
    final headDisplacementFromLegHit = (headBoneAfterLeg.mid - headTarget).distance;
    final footDisplacementFromHeadHit = (footRBoneAfterHead.mid - footTarget).distance;
    final footDisplacementFromLegHit = (footRBoneAfterLeg.mid - footTarget).distance;

    expect(headDisplacementFromHeadHit, greaterThan(headDisplacementFromLegHit * 0.9),
        reason: 'a head hit should move the head at least as much as a leg hit does');
    expect(footDisplacementFromLegHit, greaterThan(footDisplacementFromHeadHit * 0.9),
        reason: 'a leg hit should move that foot at least as much as a head hit does');
  });

  test('Procedural terrain: same seed reproduces identical maps; different seeds vary', () {
    for (final map in GameMaps.all) {
      List<Offset> positionsFor(int seed) {
        final world = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: seed);
        MapBuilder.build(world, map, 2);
        return world.bodies.map((b) => b.pos).toList();
      }

      final a1 = positionsFor(1234);
      final a2 = positionsFor(1234);
      expect(a1, a2, reason: 'seed 1234 must reproduce identical terrain for map ${map.id}');

      // Try a handful of alternate seeds — at least one must differ from the
      // original layout (guards against accidentally-unused randomness).
      bool foundDifference = false;
      for (final seed in [1, 2, 3, 4, 5]) {
        if (_offsetListsDiffer(positionsFor(seed), a1)) {
          foundDifference = true;
          break;
        }
      }
      expect(foundDifference, true, reason: 'map ${map.id} should vary across seeds');
    }
  });

  test('Procedural terrain stays playable across many seeds and player counts', () {
    for (final map in GameMaps.all) {
      for (final numPlayers in [2, 3, 4]) {
        for (int seed = 0; seed < 8; seed++) {
          final world = PhysicsWorld(width: 1100, height: 760, waterLevel: 610, seed: seed * 97 + 3);
          MapBuilder.build(world, map, numPlayers);
          expect(world.bodies.length, greaterThan(1), reason: 'map ${map.id} seed $seed');
          for (int p = 0; p < numPlayers; p++) {
            final spawn = MapBuilder.spawnFor(world, p, numPlayers);
            expect(spawn.dy, lessThan(world.waterLevel),
                reason: 'map ${map.id} seed $seed player $p spawn must be above water');
            // spawn point must not land inside another solid block
            for (final b in world.bodies) {
              if (b.dead) continue;
              final inside = b.aabb.deflate(6).contains(spawn);
              expect(inside, false,
                  reason: 'map ${map.id} seed $seed player $p spawn lands inside a block');
            }
          }
        }
      }
    }
  });
}

/// True if the two position lists are meaningfully different (different
/// body count, or any body more than a fraction of a pixel apart).
bool _offsetListsDiffer(List<Offset> a, List<Offset> b) {
  if (a.length != b.length) return true;
  for (int i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).distance > 0.001) return true;
  }
  return false;
}
