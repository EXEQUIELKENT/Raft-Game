import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// Platform layout, containment and navigation: the deck height-field every
/// hull ships with, the rail lips that keep living bodies aboard, and the
/// guarantees that keep ragdolls out of the sky and out of the geometry.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
  });

  RaftLoadout loadout({
    String hull = 'tube',
    String size = 'medium',
    int color = 0,
  }) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  GameController newMatch({String hull = 'log', String size = 'medium', int seed = 42}) {
    return GameController(
      settings: MatchSettings(map: GameMaps.all.first, startHp: 100, turnSeconds: 30),
      players: [
        PlayerConfig(name: 'P1', loadout: loadout(hull: hull, size: size)),
        PlayerConfig(
          name: 'P2',
          loadout: loadout(hull: hull, size: size, color: 1),
          isAi: true,
          aiDifficulty: AiDifficulty.easy,
        ),
      ],
      mode: GameMode.vsAi,
      seed: seed,
    );
  }

  void tick(GameController ctrl, int frames, {double dt = 1 / 60}) {
    for (int i = 0; i < frames; i++) {
      ctrl.world.update(dt);
    }
  }

  group('Deck profiles (raft scaling + platform variety)', () {
    test('Every hull builds a valid, contiguous profile at every size', () {
      for (final hull in RaftHull.all) {
        for (final size in RaftSize.all) {
          for (final facing in [1, -1]) {
            final lo = RaftLoadout.custom(
              hullId: hull.id,
              sizeId: size.id,
              colorIndex: 0,
            );
            final profile = DeckProfile.forLoadout(lo, facing: facing);
            expect(profile.isValid, true,
                reason: '${hull.id}/${size.id}: segments must be ordered and gap-free');
            for (final s in profile.segments) {
              expect(s.x0, greaterThanOrEqualTo(-lo.deckHalf - 0.01),
                  reason: '${hull.id}/${size.id}: segment starts inside the deck');
              expect(s.x1, lessThanOrEqualTo(lo.deckHalf + 0.01),
                  reason: '${hull.id}/${size.id}: segment ends inside the deck');
              expect(max(s.rise0, s.rise1), lessThanOrEqualTo(24.0),
                  reason: '${hull.id}/${size.id}: rises stay reachable');
            }
          }
        }
      }
    });

    test('Crew are berthed on level ground, inside the rails', () {
      // Crew now stand *on* the deck structure rather than being kept off it,
      // so the guarantee is that every berth sits on a flat patch — never
      // part-way up a ramp, where a character would stand on a slope — and
      // inside the rails.
      for (final hull in RaftHull.all) {
        for (final size in RaftSize.all) {
          for (final facing in [1, -1]) {
            final lo = RaftLoadout.custom(hullId: hull.id, sizeId: size.id, colorIndex: 0);
            final profile = DeckProfile.forLoadout(lo, facing: facing);
            expect(profile.stations.length, lo.crewCount,
                reason: '${hull.id}/${size.id}: one berth per crew member');

            for (final st in profile.stations) {
              expect(st.x.abs(), lessThanOrEqualTo(lo.deckHalf + 0.01),
                  reason: '${hull.id}/${size.id}: berth inside the rails');
              // The declared berth height matches the height-field there...
              expect(profile.riseAt(st.x), closeTo(st.rise, 0.01),
                  reason: '${hull.id}/${size.id}: berth height matches the deck');
              // ...and the ground is level across a body's width, so nobody
              // is posted standing on a slope.
              expect(profile.riseAt(st.x - 7), closeTo(st.rise, 0.6),
                  reason: '${hull.id}/${size.id}: berth is on flat ground (aft side)');
              expect(profile.riseAt(st.x + 7), closeTo(st.rise, 0.6),
                  reason: '${hull.id}/${size.id}: berth is on flat ground (fore side)');
            }
          }
        }
      }
    });

    test('Multi-level hulls spread their crew across different heights', () {
      // The point of the deck plans: a galleon crew fights from the castle,
      // the waist and the forecastle rather than lining up along one plank.
      final galleon = RaftLoadout.custom(hullId: 'galleon', sizeId: 'large', colorIndex: 0);
      final heights = DeckProfile.forLoadout(galleon, facing: 1)
          .stations
          .map((s) => s.rise)
          .toSet();
      expect(heights.length, greaterThan(1),
          reason: 'a full galleon crew should not all stand on one level');

      // The starter tube is deliberately the flat one, for contrast.
      final tube = RaftLoadout.custom(hullId: 'tube', sizeId: 'large', colorIndex: 0);
      final tubeProfile = DeckProfile.forLoadout(tube, facing: 1);
      expect(tubeProfile.stations.every((s) => s.rise == 0), true,
          reason: 'the pool tube is one flat ring');
    });

    test('Every hull has its own deck plan', () {
      // Five hulls, five silhouettes: no two share a set of deck heights.
      final shapes = <String, String>{};
      for (final hull in RaftHull.all) {
        final lo = RaftLoadout.custom(hullId: hull.id, sizeId: 'large', colorIndex: 0);
        final p = DeckProfile.forLoadout(lo, facing: 1);
        // Sample the height-field across the deck as the hull's signature.
        final sig = [
          for (double f = -0.95; f <= 0.95; f += 0.1)
            p.riseAt(lo.deckHalf * f).toStringAsFixed(0),
        ].join(',');
        expect(shapes.containsKey(sig), false,
            reason: '${hull.id} has the same deck shape as ${shapes[sig]}');
        shapes[sig] = hull.id;
      }
    });

    test('Left-firing rafts mirror: the high ground stays behind the shooter', () {
      final lo = loadout(hull: 'galleon', size: 'large');
      final righty = DeckProfile.forLoadout(lo, facing: 1);
      final lefty = DeckProfile.forLoadout(lo, facing: -1);

      // Each layout has a raised block seated on its own stern rail: the
      // right-firing raft's at negative x, the mirrored one at positive x.
      expect(
        righty.segments.any((s) => s.isFlat && s.rise0 >= 12 && s.x0 <= -lo.deckHalf + 0.01),
        true,
        reason: 'right-firing raft keeps its castle aft',
      );
      expect(
        lefty.segments.any((s) => s.isFlat && s.rise0 >= 12 && s.x1 >= lo.deckHalf - 0.01),
        true,
        reason: 'mirrored raft keeps its castle aft on its own facing',
      );
      expect(lefty.isValid, true, reason: 'mirroring preserves the sort order');
    });

    test('surfaceY reads the height-field: raised aft, flat mid, null past rails', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;

      expect(raft.surfaceY(0), 0.0, reason: 'mid-deck is the flat main deck');
      expect(raft.surfaceY(-raft.deckHalf + 6), lessThan(0),
          reason: 'the stern castle is raised above the main deck');
      expect(raft.surfaceY(raft.deckHalf + 1), isNull, reason: 'past the rail is open water');
      expect(raft.surfaceY(-raft.deckHalf - 1), isNull);
      ctrl.dispose();
    });
  });

  group('Containment (physics + navigation)', () {
    test('A living body shoved at the rail bounces back aboard', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;
      final c = raft.crew.first;
      final station = raft.loadout.crewOffset(0);

      // Standing at the lip (pose coordinates are station-local), shoved
      // hard toward it.
      final edge = raft.deckHalf - 6 - station;
      c.ragdoll = true;
      c.pose = RagdollPose.standingAt(Offset(edge, 0));
      c.pose!.applyImpulse(c.pose!.hip.pos, const Offset(4, -0.5));

      tick(ctrl, 240);

      expect(c.drowned, false, reason: 'the rail lip keeps living bodies aboard');
      expect(c.alive, true);
      final hip = station + (c.pose?.hip.pos.dx ?? c.offset.dx);
      expect(hip, lessThan(raft.deckHalf),
          reason: 'the body ends up back inside the rails');
      ctrl.dispose();
    });

    test('A corpse at the rail still drifts over and drowns', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;
      final c = raft.crew.first;
      final station = raft.loadout.crewOffset(0);
      c.hp = 0;

      // Dead at the lip, killed toward the stern rail.
      final edge = -(raft.deckHalf - 10) - station;
      c.pose = RagdollPose.standingAt(Offset(edge, 0));
      c.startDeath(const Offset(-1, 0), 4.0, railDir: -1);

      for (int i = 0; i < 600 && !c.drowned; i++) {
        ctrl.world.update(1 / 60);
      }
      expect(c.drowned, true,
          reason: 'corpses are not stopped by the lip — death ends in the water');
      ctrl.dispose();
    });

    test('A heavy hit on the biggest deck never escapes the raft', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;

      for (final c in raft.crew) {
        c.knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('anchor')));
      }

      tick(ctrl, 90);

      for (final c in raft.crew) {
        expect(c.drowned, false,
            reason: 'even the anchor cannot sweep a body off a 260-wide deck');
        final hipX = raft.stationX(raft.crew.indexOf(c)) +
            (c.pose?.hip.pos.dx ?? c.offset.dx);
        expect(hipX.abs(), lessThan(raft.deckHalf),
            reason: 'the body is still over the planks');
      }

      // And everyone eventually recovers to their berth — which on a galleon
      // is up on the castle or the forecastle, not the main deck.
      tick(ctrl, 900);
      for (int i = 0; i < raft.crew.length; i++) {
        expect(raft.atStation(i), true, reason: "crew $i walked back home");
        expect(raft.crew[i].offset, raft.restOffset(i));
      }
      ctrl.dispose();
    });

    test('The rail catches a body knocked off a raised tier, not just the main deck', () {
      // The lip's height window has to be measured from the deck surface at
      // that rail. Measured from the main deck plane instead, a crew member
      // berthed on a raised forecastle already starts above the window, so a
      // shove toward the bow sailed them clean over a rail that should have
      // stopped them.
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;

      // The crew member berthed highest, shoved hard at their nearest rail.
      var idx = 0;
      for (int i = 1; i < raft.crew.length; i++) {
        if (raft.restOffset(i).dy < raft.restOffset(idx).dy) idx = i;
      }
      expect(raft.restOffset(idx).dy, lessThan(-4),
          reason: 'the fixture needs someone up on a platform');

      // Put them right at the rail on their own raised tier, sliding outward:
      // exactly the state the lip exists to catch.
      final c = raft.crew[idx];
      final station = raft.stationX(idx);
      final side = station >= 0 ? 1.0 : -1.0;
      final railX = side * (raft.deckHalf - 2);
      final railSurface = raft.surfaceY(railX)!;
      expect(railSurface, lessThan(-4),
          reason: 'this rail must sit on a raised tier for the test to bite');

      c.ragdoll = true;
      c.pose = RagdollPose.standingAt(Offset(railX - station, railSurface));
      for (final p in c.pose!.points) {
        p.setVel(Offset(side * 3.0, 0));
      }

      tick(ctrl, 240);
      expect(c.drowned, false,
          reason: 'the rail on a raised tier should bounce them back aboard');
      ctrl.dispose();
    });

    test('Point speeds are hard-capped: no ragdoll launches into the sky', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;
      final c = raft.crew.first;

      c.knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('anchor')),
          hitLocal: const Offset(0, -55));
      // A second stacked impulse right after the first: the old worst case.
      tick(ctrl, 10);
      c.knock(const Offset(0.6, -0.4), Crew.impactForce(Weapons.byId('anchor')),
          hitLocal: const Offset(4, -30));

      for (int i = 0; i < 300; i++) {
        ctrl.world.update(1 / 60);
        final p = c.pose;
        if (p == null) break;
        for (final point in p.points) {
          expect(point.vel.distance, lessThanOrEqualTo(BattleConst.bodyMaxSpeed + 0.01),
              reason: 'constraint solver must not inject energy');
          expect(point.pos.dy, greaterThan(-260),
              reason: 'bodies stay within the world scale');
        }
      }
      expect(c.drowned, false);
      ctrl.dispose();
    });

    test('A body knocked onto another level climbs back to its own berth', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;

      // Pick a crew member berthed somewhere other than the main deck, and
      // dump them cold on the *main deck* — so the walk home is a real
      // traverse across the height-field, not a nudge.
      final idx = List.generate(raft.crew.length, (i) => i)
          .firstWhere((i) => raft.restOffset(i).dy < -4, orElse: () => 0);
      expect(raft.restOffset(idx).dy, lessThan(-4),
          reason: 'the galleon should berth someone above the main deck');

      final c = raft.crew[idx];
      final station = raft.stationX(idx);
      // Pose coordinates are station-local: raft-local x minus the berth slot.
      c.ragdoll = true;
      c.pose = RagdollPose.standingAt(Offset(-station, 0));

      tick(ctrl, 300);
      expect(c.ragdoll, false, reason: 'settled and stood up');
      expect(c.pose, isNull);
      // Wherever the collapse left them — platform, ramp or main deck — they
      // are standing ON the surface, not sunk through it.
      final surface = raft.surfaceY(station + c.offset.dx)!;
      expect(c.offset.dy, closeTo(surface, 2.5),
          reason: 'feet rest on the local surface');

      // Then the walk home: back along the deck and up to their own berth.
      tick(ctrl, 1200);
      expect(raft.atStation(idx), true, reason: 'back at their berth');
      expect(c.offset, raft.restOffset(idx));
      expect(c.walkAmp, 0);
      ctrl.dispose();
    });

    test('Launches stay out of the sky: rise is capped on every point', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;
      final c = raft.crew.first;

      // Worst case: the heaviest shell, dead-centre head shot, then a
      // stacked second hit mid-flight.
      c.knock(const Offset(0.2, -0.98), Crew.impactForce(Weapons.byId('anchor')),
          hitLocal: const Offset(0, -55));
      for (int i = 0; i < 240; i++) {
        ctrl.world.update(1 / 60);
        if (i == 12) {
          c.knock(const Offset(0.0, -1.0), Crew.impactForce(Weapons.byId('anchor')),
              hitLocal: const Offset(0, -50));
        }
        final p = c.pose;
        if (p == null) break;
        for (final point in p.points) {
          expect(point.pos.dy, greaterThan(-100),
              reason: 'no point may fly more than ~30 units above the deck');
        }
        expect(p.hip.pos.dy, greaterThan(-50),
            reason: 'the body hops, it does not launch');
      }
      ctrl.dispose();
    });

    test('The watchdog force-resolves a ragdoll that never settles', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final raft = ctrl.world.raftOf(0)!;

      // Over the deck: held forever -> stood up, not left hanging.
      final a = raft.crew.first;
      a.ragdoll = true;
      a.pose = RagdollPose.standingAt(Offset.zero);
      a.ragdollTime = BattleConst.ragdollWatchdog + 1;
      ctrl.world.update(1 / 60);
      expect(a.getUpT >= 0 || !a.ragdoll, true,
          reason: 'the watchdog initiates recovery on the next tick');
      tick(ctrl, 60);
      expect(a.ragdoll, false, reason: 'and the recovery completes');
      expect(a.pose, isNull);

      // Past the rail: held forever -> the sea takes them.
      final b = raft.crew.last;
      b.ragdoll = true;
      b.pose = RagdollPose.standingAt(const Offset(4000, 0));
      b.ragdollTime = BattleConst.ragdollWatchdog + 1;
      ctrl.world.update(1 / 60);
      expect(b.drowned, true, reason: 'watchdog drowned the straggler');
      expect(b.ragdoll, false);
      ctrl.dispose();
    });
  });

  group('Turn gating (no firing from mid-air)', () {
    test('A tumbling shooter cannot fire; the turn resumes when they stand', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final me = ctrl.world.raftOf(0)!;
      expect(me.activeCrew!.ready, true, reason: 'sanity: standing crew can act');
      expect(ctrl.canHumanAct, true);

      // The shooter takes a splash mid-turn and goes flying.
      me.crew[me.activeIndex].knock(const Offset(1, 0),
          Crew.impactForce(Weapons.byId('anchor')));
      expect(me.activeCrew!.ready, false);
      expect(ctrl.canHumanAct, false, reason: 'no firing from mid-air');

      // The fire path is rejected outright, not just muted in the UI.
      ctrl.humanFire();
      expect(ctrl.world.shot, isNull);
      expect(ctrl.phase, GamePhase.aiming);

      // The turn holds while they recover, then fully resumes.
      for (int i = 0; i < 300 && !me.activeCrew!.ready; i++) {
        ctrl.world.update(1 / 60);
      }
      expect(me.activeCrew!.ready, true, reason: 'the shooter is back on their feet');
      // Pump the controller's aiming loop so the wait clears.
      for (int i = 0; i < 10; i++) {
        ctrl.world.update(1 / 60);
      }
      expect(ctrl.canHumanAct, true, reason: 'the turn resumes on their feet');
      ctrl.humanFire();
      expect(ctrl.world.shot, isNotNull, reason: 'and they can finally fire');
      ctrl.dispose();
    });

    test('The active slot rotates to a crew member who is on their feet', () {
      final ctrl = newMatch(hull: 'galleon', size: 'large');
      final me = ctrl.world.raftOf(0)!;
      expect(me.activeIndex, 0);

      // Shooter down, crewmate ready: the shot passes to the crewmate.
      me.crew[0].knock(const Offset(1, 0), Crew.impactForce(Weapons.byId('anchor')));
      expect(me.ensureActiveReady(), true);
      expect(me.activeIndex, 1);

      // Everyone down: nobody can act yet.
      for (final c in me.crew) {
        c.ragdoll = true;
        c.pose = RagdollPose.standingAt(Offset.zero);
      }
      expect(me.ensureActiveReady(), false);
      ctrl.dispose();
    });
  });
}
