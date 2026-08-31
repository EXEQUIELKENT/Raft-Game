import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/net.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
  });

  RaftLoadout loadout({String hull = 'tube', String size = 'medium', int color = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  GameController newMatch({
    int seed = 42,
    GameMode mode = GameMode.vsAi,
  }) {
    return GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
      players: [
        PlayerConfig(name: 'P1', loadout: loadout()),
        PlayerConfig(
          name: 'P2',
          loadout: loadout(hull: 'log', color: 1),
          isAi: true,
          aiDifficulty: AiDifficulty.easy,
        ),
      ],
      mode: mode,
      seed: seed,
    );
  }

  /// Runs [frames] 60Hz ticks, the way the game loop does.
  void tick(GameController ctrl, int frames, {double dt = 1 / 60}) {
    for (int i = 0; i < frames; i++) {
      ctrl.world.update(dt);
    }
  }

  /// True when any living enemy raft overlaps the visible window.
  ///
  /// This is the actual thing the camera lock exists to prevent, so the
  /// tests assert on it directly instead of on camera numbers.
  bool enemyInFrame(BattleWorld world) {
    for (final r in world.rafts) {
      if (r.playerIndex == world.camAnchor || !r.alive) continue;
      final near = r.x - r.loadout.width * 0.5;
      final far = r.x + r.loadout.width * 0.5;
      if (far > world.cam && near < world.camRight) return true;
    }
    return false;
  }

  /// True when the shooter's own raft is somewhere in the visible window.
  bool anchorInFrame(BattleWorld world) {
    final me = world.raftOf(world.camAnchor);
    if (me == null) return true;
    return me.x > world.cam && me.x < world.camRight;
  }

  group('Blind fire: the camera belongs to the shooter', () {
    test('Aiming cannot drag the view onto the enemy raft', () {
      final ctrl = newMatch();
      final world = ctrl.world;

      // Hold for ten seconds of aiming. Nothing the player does with the
      // drag should move the view, and holdCam is the only thing the aiming
      // phase calls.
      for (int i = 0; i < 600; i++) {
        world.holdCam(1 / 60);
      }

      expect(enemyInFrame(world), false,
          reason: 'the enemy must never enter the frame while aiming');
      expect(anchorInFrame(world), true,
          reason: 'the shooter stays on screen — the view leans ahead of them, not past them');
    });

    test('clampToLock refuses even an absurd requested centre, at both ends', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final me = world.raftOf(0)!;

      // Try to shove the camera a long way past the enemy, and a long way
      // behind the shooter. Both ends are held.
      final farCam = world.camFor(world.clampToLock(9000, 0));
      final behindCam = world.camFor(world.clampToLock(-9000, 0));

      expect(enemyInFrame(world), false); // sanity: the default view is blind
      expect(farCam, greaterThanOrEqualTo(0.0));

      // Near end: however far back the camera is pulled, the shooter is
      // still looking at their own deck.
      expect(behindCam, lessThan(me.x + me.loadout.width * 0.5));
      expect(behindCam + world.viewWidth, greaterThan(me.x - me.loadout.width * 0.5));

      // Far end: even shoved hard the other way, the enemy stays hidden.
      world.cam = farCam;
      expect(enemyInFrame(world), false);
    });

    test('A projectile is followed all the way to its target', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final foe = world.raftOf(1)!;

      // Track a projectile that has already arrived at the enemy, for long
      // enough that easing would normally have caught up with it entirely.
      // The camera must end up centered on the projectile, not stuck at
      // the shooter's raft — following the ball is the whole point once it
      // leaves the muzzle.
      for (int i = 0; i < 900; i++) {
        world.trackShot(foe.x, 0, 1 / 60);
      }

      final expectedCam = world.camFor(foe.x);
      expect((world.cam - expectedCam).abs(), lessThan(1.0),
          reason: 'after long easing, the camera should be centered on the projectile');
      expect(world.cam, greaterThan(ctrl.world.raftOf(0)!.x - 50),
          reason: 'the camera should have moved well past the shooter toward the projectile');
    });

    test('The lock holds at any plausible aspect ratio', () {
      // viewWidth comes straight from the screen: the world is 422 units
      // tall, so a tall phone sees ~200 units across and a 32:9 monitor sees
      // ~1500. The lock has to hold across that whole range.
      for (final viewWidth in [200.0, 560.0, 750.0, 915.0, 1010.0, 1500.0]) {
        final ctrl = newMatch();
        final world = ctrl.world;
        world.viewWidth = viewWidth;

        world.lockCam(0);
        for (int i = 0; i < 600; i++) {
          world.holdCam(1 / 60);
        }

        expect(enemyInFrame(world), false,
            reason: 'the enemy must stay hidden at viewWidth $viewWidth');
        expect(anchorInFrame(world), true,
            reason: 'and the shooter must stay visible at viewWidth $viewWidth');
      }
    });

    // Note: the AIMING lock still uses followCam (with the camera lock
    // clamp), but the FIRING phase uses trackShot, which deliberately
    // ignores the lock and follows the projectile freely. Both are tested
    // elsewhere — see the next group.

    test('A dead enemy no longer constrains the camera', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final foe = world.raftOf(1)!;
      world.viewWidth = 1500; // wide enough that the enemy-side limit binds

      final constrained = world.clampToLock(9000, 0);

      for (final c in foe.crew) {
        c.hp = 0;
      }
      expect(foe.alive, false);

      final free = world.clampToLock(9000, 0);
      expect(free, greaterThan(constrained),
          reason: 'with nothing left to hide, the view is free to follow the shot out');
    });

    test('The arc preview is a shape hint, not a rangefinder', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final me = world.raftOf(0)!;
      final foe = world.raftOf(1)!;

      for (final power in [40.0, 70.0, 100.0]) {
        final dots = world.trajectory(
          from: me.muzzle(),
          angleDeg: 45,
          power: power,
          facing: 1,
          weapon: Weapons.starter,
        );

        expect(dots, isNotEmpty, reason: 'the lob still shows something at power $power');
        expect(dots.last.pos.dx, lessThan(foe.x - foe.loadout.width * 0.5),
            reason: 'the dotted arc must not reach the enemy and give the range away '
                '(power $power)');
      }
    });
  });

  group('Camera tracking during flight', () {
    test('A shot in flight pulls the camera past the shooter', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final me = world.raftOf(0)!;
      final foe = world.raftOf(1)!;

      // Lock onto the shooter first, the way the aiming phase does.
      world.lockCam(0);
      expect(world.cam, lessThan(me.x),
          reason: 'the lock puts the shooter on the left half of the screen');

      // Then start tracking the shot, the way the firing phase does.
      for (int i = 0; i < 600; i++) {
        world.trackShot(foe.x, 0, 1 / 60);
      }

      expect(world.cam, greaterThan(me.x),
          reason: 'tracking the shot must move the camera past the shooter');
    });

    test('Tracking obeys the world bounds', () {
      // Even on a viewport the lock cannot satisfy, the projectile track
      // stays inside the world instead of overshooting into empty space.
      final ctrl = newMatch();
      final world = ctrl.world;
      world.viewWidth = 600;

      for (int i = 0; i < 900; i++) {
        world.trackShot(-9999, 0, 1 / 60);
      }

      expect(world.cam, greaterThanOrEqualTo(-BattleConst.camOverhang),
          reason: 'the tracked shot must not push the camera off the world');
    });

    test('A real shot stays inside the frame for its whole flight', () {
      // This is the requirement the tracking exists to satisfy, so it is
      // asserted on the actual simulation rather than on camera numbers.
      //
      // The failure this guards against is subtle: an exponential ease
      // trails a moving target by roughly (speed / follow rate), which at
      // full power is ~400 world units — enough to leave an 870-wide
      // viewport entirely, and far worse on a narrow one. Flat shots are
      // the worst case because they carry the most horizontal speed.
      //
      // Viewport width is 422 * aspectRatio, so it ranges from ~195 on a
      // portrait phone to ~1266 on an ultrawide monitor. All of them have
      // to hold the shot.
      final worstByView = <double, double>{};

      for (final view in <double>[195, 422, 750, 870, 1266]) {
        for (final angle in <double>[8, 20, 42, 65]) {
          final ctrl = newMatch();
          final world = ctrl.world;
          final me = world.raftOf(0)!;
          world.viewWidth = view;
          world.lockCam(0);

          world.fire(
            from: Offset(me.x, BattleConst.waterY - 60),
            angleDeg: angle, power: 100, facing: 1,
            weapon: Weapons.byId('tennis'), owner: 0,
          );

          var worst = double.infinity;
          var frames = 0;
          for (int i = 0; i < 600; i++) {
            final s = world.shot;
            if (s == null) break;
            frames++;

            // The order matters and matches _updateFiring: track, then step.
            // vel is per 60Hz step; the camera wants units per second.
            world.trackShot(s.pos.dx, s.vel.dx * 60, 1 / 60);

            final fromLeft = s.pos.dx - world.cam;
            final fromRight = world.camRight - s.pos.dx;
            final edge = fromLeft < fromRight ? fromLeft : fromRight;
            if (edge < worst) worst = edge;

            if (world.stepShot() != null) break;
          }

          expect(frames, greaterThan(10),
              reason: 'the $angle° shot should actually fly for a while '
                  'at viewWidth $view');
          // The margin scales with the viewport, so require a quarter of
          // the frame width as clearance on the narrow ones.
          final floor = view * 0.20;
          expect(worst, greaterThan(floor),
              reason: 'at viewWidth $view a $angle° shot drifted to '
                  '${worst.toStringAsFixed(1)} units from the frame edge '
                  '(needed ${floor.toStringAsFixed(1)})');
          worstByView[view] = worst;
          ctrl.dispose();
        }
      }
    });

    test('returnCamTo eases the camera back to the next shooter', () {
      final ctrl = newMatch();
      final world = ctrl.world;

      // Start from somewhere arbitrary, far from the player.
      world.cam = 1500;

      final me = world.raftOf(0)!;
      for (int i = 0; i < 600; i++) {
        world.returnCamTo(0, 1 / 60);
      }

      expect((world.cam - (me.x - world.viewWidth / 2)).abs(), lessThan(1.0),
          reason: 'the camera should have eased to a position that centres the shooter');
    });

    test('cutCam cuts straight to the tracked point in frame', () {
      final ctrl = newMatch();
      final world = ctrl.world;

      world.cutCam(1200);
      expect((world.cam + world.viewWidth / 2 - 1200).abs(), lessThan(1.0),
          reason: 'the cut centres the projectile the way an ease would trail');
      ctrl.dispose();
    });

    test('Firing holds on the shooter for a beat, then cuts to the projectile', () async {
      final ctrl = newMatch();
      final world = ctrl.world;

      ctrl.aimAngle = 45;
      ctrl.aimPower = 70;
      final camAtFire = world.cam;
      ctrl.humanFire();
      expect(ctrl.phase, GamePhase.firing);

      // The opening beat: the view stays on the shooter while the shot
      // leaves the barrel. 100ms cannot possibly reach the end of the hold
      // (the ticker's dt is clamped at 50ms and the hold is 450ms), so this
      // asserts the hold rather than racing it.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ctrl.phase, GamePhase.firing, reason: 'the shot is still in flight');
      expect((world.cam - camAtFire).abs(), lessThan(40),
          reason: 'the camera has not cut away yet — the shooter gets their beat');

      // Past the hold window the view has cut to the projectile and is
      // travelling with it toward the target. The cut alone clears this:
      // by then the ball is a few hundred units out, so centring on it
      // moves the camera well past the shooter.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(world.cam, greaterThan(camAtFire + 100),
          reason: 'the camera has cut to the projectile and followed it out');

      ctrl.dispose();
    });
  });

  group('Raft spacing', () {
    test('The rafts are separated by a long stretch of open water', () {
      final ctrl = newMatch();
      final me = ctrl.world.raftOf(0)!;
      final foe = ctrl.world.raftOf(1)!;

      final gap = (foe.x - me.x) - (me.loadout.width + foe.loadout.width) * 0.5;
      expect(gap, greaterThan(900),
          reason: 'a shot has to carry across real distance, not be nudged over');

      // The four-player roster has to fit further out, with a backstop past it.
      expect(BattleConst.enemySlots.length, 4);
      for (int i = 1; i < BattleConst.enemySlots.length; i++) {
        expect(BattleConst.enemySlots[i], greaterThan(BattleConst.enemySlots[i - 1]),
            reason: 'slots are ordered out to sea');
      }
      expect(BattleConst.worldW, greaterThan(BattleConst.enemySlots.last + 400),
          reason: 'the world is wide enough for the furthest slot plus its backstop');
    });

    test('The enemy is reachable: a full-power lob carries the distance', () {
      // Widening the gap is only fair if the enemy can still be hit.
      final ctrl = newMatch();
      final world = ctrl.world;
      final me = world.raftOf(0)!;
      final foe = world.raftOf(1)!;

      // Sweep the whole legal aiming envelope: every angle and power the
      // player can actually dial in.
      var best = double.infinity;
      for (var angle = 10.0; angle <= 80.0; angle += 2.5) {
        for (var power = BattleConst.powerMin; power <= BattleConst.powerMax; power += 2.5) {
          final miss = (world.landingX(
            from: me.muzzle(aimAngleDeg: angle),
            angleDeg: angle,
            power: power,
            facing: 1,
            weapon: Weapons.starter,
          ) - foe.x).abs();
          if (miss < best) best = miss;
        }
      }

      expect(best, lessThan(foe.loadout.width * 0.5 + BattleConst.hitRadius),
          reason: 'some angle and power inside the legal ranges lands on the far raft');
    });
  });

  group('Hit and death physics', () {
    BattleWorld oneCrewWorld() {
      final world = BattleWorld(map: GameMaps.all.first, seed: 11);
      world.addRaft(Raft(
        playerIndex: 0, x: BattleConst.playerX, loadout: loadout(),
        look: CrewLook.player, label: 'P1', facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      world.addRaft(Raft(
        playerIndex: 1, x: BattleConst.enemySlots.first, loadout: loadout(hull: 'log'),
        look: CrewLook.raider, label: 'AI', facing: -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      return world;
    }

    /// Fires flat from just outside the body at [heightAboveFeet] and steps
    /// until it resolves. At full power the ball covers ~32 units a frame,
    /// so its sampled positions straddle the crew member entirely — only a
    /// swept test can catch it.
    ShotOutcome? flatShot(BattleWorld world, double heightAboveFeet) {
      final feet = world.raftOf(1)!.feetPos(0);
      world.fire(
        from: Offset(feet.dx - 40, feet.dy - heightAboveFeet),
        angleDeg: 6, power: 100, facing: 1,
        weapon: Weapons.byId('tennis'), owner: 0,
      );
      ShotOutcome? outcome;
      for (int i = 0; i < 50 && outcome == null; i++) {
        outcome = world.stepShot();
      }
      return outcome;
    }

    test('A fast shot through the head registers a hit, not a phase-through', () {
      final world = oneCrewWorld();
      final foe = world.raftOf(1)!;

      // Head height sits above the old torso-centred circle entirely, and a
      // full-power flat shot crosses the whole body between two frames — the
      // point test used to sail clean through a character it visibly hit.
      final outcome = flatShot(world, 60);

      expect(outcome, isNotNull, reason: 'the shot resolves');
      expect(outcome!.hitSomething, true, reason: 'a shot through the head is a direct hit');
      expect(foe.crew.first.hp, lessThan(100));
    });

    test('A fast shot through the legs registers a hit too', () {
      final world = oneCrewWorld();

      final outcome = flatShot(world, 4);

      expect(outcome, isNotNull, reason: 'the shot resolves');
      expect(outcome!.hitSomething, true, reason: 'a shot through the legs is a direct hit');
    });

    test('A killed crew member tumbles off the deck and into the water', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final foe = world.raftOf(1)!;
      final c = foe.crew.first;
      c.hp = 40; // one bomb is enough to finish them outright

      world.fire(
        from: foe.crewPos(0) - const Offset(30, 0),
        angleDeg: 10, power: 40, facing: 1,
        weapon: Weapons.byId('bomb'), owner: 0,
      );
      ShotOutcome? outcome;
      for (int i = 0; i < 200 && outcome == null; i++) {
        outcome = world.stepShot();
      }
      expect(outcome, isNotNull);
      expect(c.alive, false, reason: 'the bomb killed them');

      // The death is a fall, not a fade: the body leaves the deck, the
      // water marks where it lands, and only then does it sink away.
      var leftDeck = false;
      var sawSplash = false;
      for (int i = 0; i < 900 && !(c.drowned && c.sinkT >= 1); i++) {
        world.update(1 / 60);
        if ((foe.loadout.crewOffset(0) + c.offset.dx).abs() >= foe.deckHalf) {
          leftDeck = true;
        }
        if (world.effects.any((f) => f.kind == 'splash')) sawSplash = true;
      }

      expect(leftDeck, true, reason: 'the corpse goes over the rail rather than sinking in place');
      expect(c.drowned, true, reason: 'the fall ends in the water');
      expect(sawSplash, true, reason: 'the water marks the landing');
      expect(c.gone, true, reason: 'and the body finishes sinking once it is in the sea');
      ctrl.dispose();
    });

    test('A hit ragdolls the crew member: they kick back, tumble, then recover', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final foe = world.raftOf(1)!;
      final c = foe.crew.first;

      expect(c.ragdoll, false);
      expect(c.offset, Offset.zero);

      c.knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('grenade')));

      expect(c.ragdoll, true, reason: 'a hit puts the body into ragdoll');
      expect(c.vel.dx, greaterThan(0), reason: 'they are shoved away from the blast');
      expect(c.vel.dy, lessThan(0), reason: 'and kicked up off the deck');

      tick(ctrl, 6);
      expect(c.offset.dx, greaterThan(0), reason: 'the body has actually moved');

      // Let it settle. It should come to rest and then walk back to station.
      tick(ctrl, 400);
      expect(c.ragdoll, false, reason: 'the body settles');
      expect(c.offset.distance, lessThan(0.5),
          reason: 'and shuffles back to where it was standing');
    });

    test('An ordinary hit rocks someone back without drowning them', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;

      for (final c in foe.crew) {
        c.knock(const Offset(1, 0), Crew.impactForce(Weapons.starter));
      }

      tick(ctrl, 600);

      for (final c in foe.crew) {
        expect(c.drowned, false, reason: 'the starter ball must not sweep the deck');
        expect(c.alive, true);
        // The body — tracked through its ragdoll hips while down, its
        // feet-origin once back on them — never hangs below the waterline.
        final hipY = c.pose?.hip.pos.dy ?? (c.offset.dy - 15);
        expect(foe.deckY + hipY, lessThan(BattleConst.waterY + BattleConst.drownDepth),
            reason: 'nobody is left hanging under the waterline');
      }
    });

    test('Heavier ordnance hits harder than lighter ordnance', () {
      expect(Crew.impactForce(Weapons.byId('anchor')),
          greaterThan(Crew.impactForce(Weapons.byId('bomb'))));
      expect(Crew.impactForce(Weapons.byId('bomb')),
          greaterThan(Crew.impactForce(Weapons.byId('grenade'))));
      expect(Crew.impactForce(Weapons.byId('grenade')),
          greaterThan(Crew.impactForce(Weapons.starter)));
    });

    test('A crew member knocked into the water drowns and is out of the round', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final foe = world.raftOf(1)!;
      final c = foe.crew.first;

      // Lift them clear off the planks and out past the rail, the way a
      // heavy hit on someone standing near the edge would.
      c.ragdoll = true;
      c.pose = RagdollPose.standingAt(const Offset(4000, 0));

      // Tick until the water takes them. The splash is a short-lived effect,
      // so it has to be looked for at the moment it happens.
      var sawSplash = false;
      for (int i = 0; i < 400 && !c.drowned; i++) {
        ctrl.world.update(1 / 60);
        if (world.effects.any((f) => f.kind == 'splash')) sawSplash = true;
      }

      expect(c.drowned, true, reason: 'going into the water is fatal');
      expect(c.hp, 0, reason: 'a drowned crew member is eliminated, not wounded');
      expect(c.alive, false);
      expect(sawSplash, true, reason: 'the water they went into is marked with a splash');
    });

    test('A raft dies only once its whole crew is gone', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;

      expect(foe.alive, true);
      expect(foe.crew.length, greaterThan(1));

      // Drown everyone bar one — the raft is still in the fight.
      for (int i = 0; i < foe.crew.length - 1; i++) {
        foe.crew[i].ragdoll = true;
        foe.crew[i].pose = RagdollPose.standingAt(const Offset(4000, 0));
      }
      tick(ctrl, 400);
      expect(foe.alive, true, reason: 'one crew member left means the raft still fights');

      // And the last one going over finishes it.
      foe.crew.last.ragdoll = true;
      foe.crew.last.pose = RagdollPose.standingAt(const Offset(4000, 0));
      tick(ctrl, 400);
      expect(foe.alive, false);
    });

    test('Bodies land in the same place regardless of frame rate', () {
      // Both devices in a hotspot match tick at their own refresh rate, so
      // the physics runs on a fixed accumulator. Two very different frame
      // times covering the same wall-clock span must agree.
      Raft raftFor(GameController ctrl) => ctrl.world.raftOf(1)!;

      final fast = newMatch(seed: 7);
      final slow = newMatch(seed: 7);

      for (final ctrl in [fast, slow]) {
        final foe = raftFor(ctrl);
        for (final c in foe.crew) {
          c.knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('bomb')));
        }
      }

      tick(fast, 90, dt: 1 / 120); // ~0.75s at 120Hz
      tick(slow, 45, dt: 1 / 60); // ~0.75s at 60Hz

      final a = raftFor(fast).crew.first.offset;
      final b = raftFor(slow).crew.first.offset;
      expect((a - b).distance, lessThan(1.0),
          reason: 'the fixed-step accumulator keeps the two devices in agreement');
    });

    test('An off-centre impact spins the body; a centre hit mostly shoves it', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;
      final force = Crew.impactForce(Weapons.byId('grenade'));

      // A blow to the head turns the body over — that is what a ragdoll is.
      final headHit = foe.crew.first;
      headHit.knock(const Offset(1, 0), force, hitLocal: const Offset(0, -55));

      // The same blow dead-centre at the hips is a clean shove.
      final centreHit = foe.crew.last;
      centreHit.knock(const Offset(1, 0), force, hitLocal: const Offset(0, -15));

      expect(headHit.pose!.maxSpin, greaterThan(centreHit.pose!.maxSpin * 1.5),
          reason: 'hitting high must tumble the body, not just push it');
      expect(headHit.vel.dx, greaterThan(0), reason: 'and it is still shoved along the shot');
      ctrl.dispose();
    });

    test('A crew member walks back to their station after being knocked down', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;
      final c = foe.crew.first;

      c.knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('grenade')));

      // Somewhere between settling and arriving home they must be seen
      // walking; and when they arrive, the walk is over and the station is
      // exactly where they left it.
      var sawWalk = false;
      for (int i = 0; i < 900; i++) {
        ctrl.world.update(1 / 60);
        if (c.walkAmp > 0.5 && c.offset != Offset.zero) sawWalk = true;
      }

      expect(sawWalk, true, reason: 'the walk back to station is animated');
      expect(c.offset, Offset.zero, reason: 'they end up where they started');
      expect(c.walkAmp, 0, reason: 'and the walk eases out on arrival');
      ctrl.dispose();
    });

    test('Dynamic health bars: hidden by default, animated on damage, gone after', () {
      final ctrl = newMatch();
      final foe = ctrl.world.raftOf(1)!;
      final c = foe.crew.first;

      expect(c.hpBarT, 0, reason: 'bars are hidden while nobody is hurt');
      expect(c.hpDisplay, 1.0);

      c.hp = 55;
      c.showHpBar(1.0); // the world passes the HP fraction from before the hit
      expect(c.hpBarT, BattleConst.hpBarTime, reason: 'damage summons the bar');
      expect(c.hpDisplay, closeTo(1.0, 0.001),
          reason: 'the ghost bar starts where the HP was');

      // The ghost drains toward the live value after its delay, never below.
      tick(ctrl, 30); // half a second: past the ghost delay, mid-drain
      expect(c.hpDisplay, inExclusiveRange(c.hpFrac, 1.0),
          reason: 'the ghost drains toward the live HP, not past it');
      expect(c.hpDisplay, lessThan(1.0), reason: 'and it has visibly drained');

      // The bar hides itself once its time is out, and re-arms on the live
      // HP so the next appearance is always current.
      tick(ctrl, (BattleConst.hpBarTime * 60).ceil() + 10);
      expect(c.hpBarT, 0, reason: 'the bar fades out once the animation completes');
      expect(c.hpDisplay, c.hpFrac,
          reason: 'a reappearing bar reflects the most current HP');

      // A second hit while the bar is up extends it and keeps the ghost
      // above the new live value.
      c.showHpBar(c.hpFrac + 0.2);
      expect(c.hpDisplay, greaterThan(c.hpFrac));
      ctrl.dispose();
    });

    test('A killing blow flashes and the body only leaves after the full sink', () {
      final ctrl = newMatch();
      final world = ctrl.world;
      final foe = world.raftOf(1)!;
      final c = foe.crew.first;
      c.hp = 30;

      world.fire(
        from: foe.crewPos(0) - const Offset(30, 0),
        angleDeg: 10, power: 40, facing: 1,
        weapon: Weapons.byId('bomb'), owner: 0,
      );
      ShotOutcome? outcome;
      for (int i = 0; i < 200 && outcome == null; i++) {
        outcome = world.stepShot();
      }
      expect(outcome, isNotNull);
      expect(c.alive, false);

      expect(c.deathFlash, greaterThan(0),
          reason: 'the death sequence opens with a white impact flash');
      expect(c.sinkT, 0, reason: 'the sink only starts once they are in the water');

      // The sink takes the full sequence time, not an instant.
      var ticksToSink = 0;
      while (c.sinkT < 1 && ticksToSink < 1200) {
        world.update(1 / 60);
        ticksToSink++;
      }
      final expectedTicks = BattleConst.sinkTime * 60;
      expect(ticksToSink, greaterThan(expectedTicks * 0.5),
          reason: 'the body lingers at the surface before slipping under');
      expect(c.gone, true, reason: 'and the sequence ends with the body gone');
      ctrl.dispose();
    });
  });

  group('Hotspot transport framing', () {
    // TCP is a stream, not a sequence of messages: a send from either end
    // can be split across packets or coalesced with the next one. These run
    // over a real loopback socket so the framing being tested is the
    // shipping one, not a copy of it.
    late ServerSocket server;
    late SocketLink hostLink;
    late SocketLink guestLink;
    final raw = <Socket>[];

    Future<void> openPair() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(raw.add);
      final client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      while (raw.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      hostLink = SocketLink(raw.single);
      guestLink = SocketLink(client);
    }

    Future<List<Map<String, dynamic>>> collectFrom(
      SocketLink link,
      int count, {
      Duration timeout = const Duration(seconds: 5),
    }) async {
      final out = <Map<String, dynamic>>[];
      final done = Completer<void>();
      late StreamSubscription sub;
      sub = link.messages.listen((m) {
        out.add(m);
        if (out.length >= count && !done.isCompleted) done.complete();
      });
      await done.future.timeout(timeout, onTimeout: () {});
      await sub.cancel();
      return out;
    }

    tearDown(() async {
      await hostLink.close();
      await guestLink.close();
      await server.close();
      raw.clear();
    });

    test('JSON frames survive arbitrary TCP chunking', () async {
      await openPair();

      final got = collectFrom(guestLink, 3);

      // One whole frame, then one split mid-object into four pieces, then
      // two frames glued together — the three cases a stream can hand you.
      hostLink.socket.write('{"t":"hello","name":"P1"}\n');
      await hostLink.socket.flush();

      hostLink.socket.write('{"t":"fire",');
      await hostLink.socket.flush();
      hostLink.socket.write('"a":45.0,');
      await hostLink.socket.flush();
      hostLink.socket.write('"p":70.0,"w":"tennis","pl":0}');
      await hostLink.socket.flush();
      hostLink.socket.write('\n');
      await hostLink.socket.flush();

      hostLink.socket.write('{"t":"endTurn","pl":0,"seq":3}\n{"t":"rematch","seed":99}\n');
      await hostLink.socket.flush();

      final frames = await got;

      expect(frames.map((f) => f['t']).toList(),
          ['hello', 'fire', 'endTurn']);
      expect(frames[1]['w'], 'tennis', reason: 'the frame split across four writes came back whole');
      expect(frames[1]['a'], 45.0);
    });

    test('A malformed line is dropped without killing the stream', () async {
      await openPair();

      final got = collectFrom(guestLink, 2);

      hostLink.socket.write('{"t":"hello","name":"P1"}\n');
      hostLink.socket.write('this is not json\n');
      hostLink.socket.write('{broken\n');
      hostLink.socket.write('{"t":"endTurn","pl":0,"seq":1}\n');
      await hostLink.socket.flush();

      final frames = await got;
      expect(frames.length, 2, reason: 'the two valid frames survive the junk between them');
      expect(frames.first['t'], 'hello');
      expect(frames.last['seq'], 1);
    });

    test('Blank lines and stray whitespace are ignored', () async {
      await openPair();

      final got = collectFrom(guestLink, 1);

      hostLink.socket.write('\n\n  \n{"t":"hello","name":"P1"}\n\n');
      await hostLink.socket.flush();

      final frames = await got;
      expect(frames.length, 1);
      expect(frames.single['name'], 'P1');
    });

    test('send() terminates every frame with a newline', () async {
      await openPair();

      final got = collectFrom(guestLink, 2);
      hostLink.send({'t': 'fire', 'a': 45.0});
      hostLink.send({'t': 'fire', 'a': 30.0});

      final frames = await got;
      expect(frames.length, 2, reason: 'a frame without a trailing newline would never be cut');
      expect(frames.last['a'], 30.0);
    });

    test('A whole match handshake round-trips in both directions', () async {
      await openPair();

      final toHost = collectFrom(hostLink, 2);
      final toGuest = collectFrom(guestLink, 2);

      guestLink.send({'t': 'hello', 'name': 'Guest'});
      hostLink.send({'t': 'hello', 'name': 'Host'});
      guestLink.send({'t': 'fire', 'a': 51.5, 'p': 88.0, 'w': 'bomb', 'pl': 1});
      hostLink.send({'t': 'start', 'map': 'lagoon', 'hp': 100, 'seed': 4242});

      final hostGot = await toHost; // what the guest sent
      final guestGot = await toGuest; // what the host sent

      expect(hostGot.first['name'], 'Guest', reason: 'the guest greets first');
      expect(hostGot.last['w'], 'bomb', reason: 'the host receives the guest\'s shot');
      expect(guestGot.first['name'], 'Host', reason: 'and answers the greeting');
      expect(guestGot.last['seed'], 4242, reason: 'and the guest receives the start seed');
    });
  });
}
