import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/renderer.dart';
import 'package:raft_rumble/game/save.dart';

/// Paints the whole battle scene with the renderer in a given body state.
/// The renderer draws characters procedurally from live physics state, so
/// the only honest check that every new drawing path (ragdolls, health
/// bars, the death sequence, the recoil pose) is exception-free is to
/// actually paint it.
class _RendererPainter extends CustomPainter {
  final WorldRenderer renderer;
  final int currentPlayer;
  final bool isAiming;

  _RendererPainter(this.renderer, {required this.currentPlayer, required this.isAiming});

  @override
  void paint(Canvas canvas, Size size) {
    renderer.render(
      canvas, size, 1.5,
      currentPlayer: currentPlayer,
      isAiming: isAiming,
      aimAngleDeg: 42,
      weapon: Weapons.byId('grenade'),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

WorldRenderer _battle(BattleWorld world) => WorldRenderer(world, map: world.map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
    // Widget tests have no network; without this google_fonts tries to
    // fetch webfonts and the paint pass reports fetch failures.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  RaftLoadout loadout({int color = 0}) =>
      RaftLoadout.custom(hullId: 'tube', sizeId: 'medium', colorIndex: color);

  BattleWorld freshWorld() {
    final world = BattleWorld(map: GameMaps.all.first, seed: 3);
    world.addRaft(Raft(
      playerIndex: 0, x: BattleConst.playerX, loadout: loadout(),
      look: CrewLook.player, label: 'P1', facing: 1,
      crew: [Crew(hp: 100, maxHp: 100, bobPhase: 0), Crew(hp: 100, maxHp: 100, bobPhase: 0.7)],
    ));
    world.addRaft(Raft(
      playerIndex: 1, x: BattleConst.enemySlots.first, loadout: loadout(color: 1),
      look: CrewLook.raider, label: 'AI', facing: -1,
      crew: [Crew(hp: 100, maxHp: 100, bobPhase: 0.3), Crew(hp: 100, maxHp: 100, bobPhase: 1.1)],
    ));
    return world;
  }

  Future<void> paint(
    WidgetTester tester,
    BattleWorld world, {
    int currentPlayer = -1,
    bool isAiming = false,
  }) async {
    await tester.pumpWidget(
      CustomPaint(
        size: const ui.Size(870, 422),
        painter: _RendererPainter(_battle(world), currentPlayer: currentPlayer, isAiming: isAiming),
      ),
    );
    await tester.pump();
  }

  testWidgets('idle crews, rafts and scenery paint clean', (tester) async {
    final world = freshWorld();
    await paint(tester, world);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a live ragdoll, its get-up and the walk home all paint clean', (tester) async {
    final world = freshWorld();
    final c = world.raftOf(1)!.crew.first;
    c.knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('grenade')),
        hitLocal: const Offset(0, -55));
    await paint(tester, world);
    expect(tester.takeException(), isNull, reason: 'mid-flight ragdoll');

    tick(world);
    c.getUpT = 0; // force the stand-up blend to be visible
    await paint(tester, world);
    expect(tester.takeException(), isNull, reason: 'getting up');

    c.pose = null;
    c.ragdoll = false;
    c.getUpT = -1;
    c.offset = const Offset(24, 0);
    c.walkAmp = 1;
    c.walkPhase = 0.4;
    await paint(tester, world);
    expect(tester.takeException(), isNull, reason: 'walking back to station');
  });

  testWidgets('the death sequence paints clean at every stage', (tester) async {
    final world = freshWorld();
    final foe = world.raftOf(1)!;

    // Dead on the deck: white flash + X-eyed ragdoll.
    final dead = foe.crew.first;
    dead.hp = 0;
    dead.startDeath(const Offset(1, 0), 4.0, railDir: 1, hitLocal: const Offset(0, -50));
    await paint(tester, world);
    expect(tester.takeException(), isNull, reason: 'killing-blow flash + tumble');

    // Drowned: floating, then sinking with bubbles and the wisp.
    dead.drowned = true;
    dead.ragdoll = false;
    dead.deathFlash = 0;
    for (final t in [0.05, 0.4, 0.6, 0.85, 0.99]) {
      dead.sinkT = t;
      await paint(tester, world);
      expect(tester.takeException(), isNull, reason: 'sinking at sinkT=$t');
    }

    // And the gone body is skipped entirely.
    dead.sinkT = 1;
    await paint(tester, world);
    expect(tester.takeException(), isNull, reason: 'gone');
  });

  testWidgets('dynamic health bars paint clean while standing and ragdolled', (tester) async {
    final world = freshWorld();
    final foe = world.raftOf(1)!;
    foe.crew.first.hp = 55;
    foe.crew.first.showHpBar(1.0);
    foe.crew.last.hp = 30;
    foe.crew.last.showHpBar(0.8);
    foe.crew.last.knock(const Offset(-1, 0), Crew.impactForce(Weapons.byId('bomb')));
    await paint(tester, world);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the shooter paints the recoil pose and muzzle flash', (tester) async {
    final world = freshWorld();
    world.fire(
      from: world.raftOf(0)!.muzzle(aimAngleDeg: 42, weapon: Weapons.byId('grenade')),
      angleDeg: 42, power: 70, facing: 1,
      weapon: Weapons.byId('grenade'), owner: 0,
    );
    // firedAt = elapsed, so the first painted frames sit inside the flash.
    await paint(tester, world, currentPlayer: 0, isAiming: false);
    expect(tester.takeException(), isNull, reason: 'muzzle flash + kickback');

    await paint(tester, world, currentPlayer: 0, isAiming: true);
    expect(tester.takeException(), isNull, reason: 'aim pose while the shot is live');
  });

  testWidgets('every firearm model paints in aim, rest, recoil and swap states',
      (tester) async {
    for (final weapon in Weapons.all) {
      final world = BattleWorld(map: GameMaps.all.first, seed: 9);
      world.addRaft(Raft(
        playerIndex: 0, x: BattleConst.playerX,
        loadout: RaftLoadout.custom(hullId: 'tube', sizeId: 'medium', colorIndex: 0),
        look: CrewLook.player, label: 'P1', facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      world.addRaft(Raft(
        playerIndex: 1, x: BattleConst.enemySlots.first,
        loadout: RaftLoadout.custom(hullId: 'tube', sizeId: 'medium', colorIndex: 1),
        look: CrewLook.raider, label: 'AI', facing: -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      final crew = world.raftOf(0)!.crew.first;

      // Idle carry with this weapon equipped.
      crew.equip(weapon.id);
      await paint(tester, world);
      expect(tester.takeException(), isNull, reason: '${weapon.id}: rest carry');

      // Aiming pose (grip targets solved at the live aim angle).
      await paint(tester, world, currentPlayer: 0, isAiming: true);
      expect(tester.takeException(), isNull, reason: '${weapon.id}: aiming');

      // Recoil + muzzle flash: fire, then paint inside the kick window.
      world.fire(
        from: world.raftOf(0)!.muzzle(aimAngleDeg: 20, weapon: weapon),
        angleDeg: 20, power: 70, facing: 1,
        weapon: weapon, owner: 0,
      );
      await paint(tester, world, currentPlayer: 0, isAiming: false);
      expect(tester.takeException(), isNull, reason: '${weapon.id}: recoil + flash');

      // Mid-swap: the firearm lowered to the hip.
      crew.equip(Weapons.byId('tennis').id == weapon.id ? 'grenade' : 'tennis');
      crew.swapT = 0.5;
      await paint(tester, world);
      expect(tester.takeException(), isNull, reason: '${weapon.id}: lowered mid-swap');
    }
  });

  testWidgets('a ragdolled crew member paints holding their equipped firearm',
      (tester) async {
    final world = freshWorld();
    final c = world.raftOf(1)!.crew.first;
    c.equip('bomb');
    c.knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('grenade')),
        hitLocal: const Offset(0, -40));
    await paint(tester, world);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deck platforms, ramps and rail lips paint on every hull', (tester) async {
    for (final hull in RaftHull.all) {
      for (final facing in [1, -1]) {
        final world = BattleWorld(map: GameMaps.all.first, seed: 5);
        world.addRaft(Raft(
          playerIndex: 0,
          x: BattleConst.playerX,
          loadout: RaftLoadout.custom(hullId: hull.id, sizeId: 'large', colorIndex: 0),
          look: CrewLook.player, label: 'P1', facing: facing,
          crew: [Crew(hp: 100, maxHp: 100)],
        ));
        world.addRaft(Raft(
          playerIndex: 1,
          x: BattleConst.enemySlots.first,
          loadout: RaftLoadout.custom(hullId: hull.id, sizeId: 'medium', colorIndex: 1),
          look: CrewLook.raider, label: 'AI', facing: -facing,
          crew: [Crew(hp: 100, maxHp: 100)],
        ));
        // A body lying across a platform edge: the drawBounds cover it.
        final c = world.raftOf(0)!.crew.first;
        c.knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('anchor')),
            hitLocal: const Offset(0, -50));
        tick(world);

        await paint(tester, world);
        expect(tester.takeException(), isNull, reason: '${hull.id} facing=$facing');
      }
    }
  });
}

void tick(BattleWorld world) {
  for (int i = 0; i < 20; i++) {
    world.update(1 / 60);
  }
}
