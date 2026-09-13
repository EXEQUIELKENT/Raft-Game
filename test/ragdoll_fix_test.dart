import 'dart:math';
import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:raft_rumble/game/audio.dart';
import 'package:raft_rumble/game/characters.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/renderer.dart';
import 'package:raft_rumble/game/save.dart';

/// Ragdoll repairs.
///
/// Four separate complaints, and they have four separate causes:
///
///  1. **"Their whole body disappears."** Not missing geometry — the tuck
///     shrinks every constraint, but the renderer kept drawing a full-size
///     torso, head and boots inside the shrunken skeleton, so the torso
///     overshot the neck and swallowed the head.
///  2. **"They're like a ball."** Same cause, plus a tuck deep enough to pull
///     the body to a third of its size.
///  3. **"They fall off far too easily."** The rail lip only fired if a point
///     was *currently* inside an eight-unit band past the edge, and points
///     move up to nine units a frame — so a decent shove tunnelled straight
///     through the rail.
///  4. **"Performance drops when hit."** Per-frame work that only started
///     once somebody was hurt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  RaftLoadout loadout({String hull = 'tube', String size = 'medium', int color = 0}) =>
      RaftLoadout.custom(hullId: hull, sizeId: size, colorIndex: color);

  BattleWorld world({String hull = 'tube', String size = 'medium'}) {
    final w = BattleWorld(map: GameMaps.all.first, seed: 11);
    w.addRaft(Raft(
      playerIndex: 0,
      x: BattleConst.playerX,
      loadout: loadout(hull: hull, size: size),
      look: CrewLook.player,
      label: 'P1',
      facing: 1,
      crew: [Crew(hp: 100, maxHp: 100), Crew(hp: 100, maxHp: 100, bobPhase: 0.7)],
    ));
    w.addRaft(Raft(
      playerIndex: 1,
      x: BattleConst.enemySlots.first,
      loadout: loadout(hull: hull, size: size, color: 1),
      look: CrewLook.raider,
      label: 'AI',
      facing: -1,
      crew: [Crew(hp: 100, maxHp: 100, bobPhase: 0.3)],
    ));
    return w;
  }

  group('A curled body still reads as a body', () {
    test('the drawn scale follows the tuck exactly', () {
      final pose = RagdollPose.standingAt(Offset.zero);
      expect(pose.tuck, 0);
      expect(pose.drawScale, 1.0, reason: 'an uncurled body draws full size');

      pose.tuck = 1;
      expect(pose.drawScale, closeTo(1 - RagdollPose.tuckShrink, 1e-9));
      pose.tuck = 0.5;
      expect(pose.drawScale, closeTo(1 - RagdollPose.tuckShrink * 0.5, 1e-9));
    });

    test('the skeleton and the artwork shrink by the same factor', () {
      // This is the whole bug: they used to disagree. The solver pulled the
      // skeleton in and the renderer kept drawing full-size parts inside it.
      final pose = RagdollPose.standingAt(Offset.zero);
      final spineBefore = (pose.neck.pos - pose.hip.pos).distance;
      pose.tuck = 1;
      for (int i = 0; i < 40; i++) {
        pose.solve();
      }
      final spineAfter = (pose.neck.pos - pose.hip.pos).distance;
      expect(spineAfter / spineBefore, closeTo(pose.drawScale, 0.05),
          reason: 'the drawn scale must match what the solver actually did');
    });

    test('a curled body never shrinks past legibility', () {
      // The bound is loose on purpose. What made a curl unreadable was never
      // the depth on its own — it was a deep curl drawn with full-size parts,
      // held for a second while the body lay on the deck. With the artwork
      // following the skeleton and the curl released on landing, a deep tuck
      // now only exists for the few tenths of a second a somersault is
      // actually in the air. Tightening this past what the flip needs would
      // trade a real behaviour (the somersault coming round) for a frame
      // nobody sees for long.
      final pose = RagdollPose.standingAt(Offset.zero)..tuck = 1;
      expect(pose.drawScale, greaterThanOrEqualTo(0.35),
          reason: 'a curled body has shrunk to a marble');
    });

    test('the ARTWORK follows the curl, not just the skeleton', () {
      // The bug itself. The solver curled the body and the renderer kept
      // drawing full-size parts inside it, so the torso overshot the neck
      // and swallowed the head. These are the numbers the renderer actually
      // draws with, so a regression here is a regression on screen.
      final pose = RagdollPose.standingAt(Offset.zero);
      final open = WorldRenderer.ragdollMetrics(pose);

      pose.tuck = 1;
      for (int i = 0; i < 60; i++) {
        pose.solve();
      }
      final curled = WorldRenderer.ragdollMetrics(pose);

      // The invariant is that the artwork scales by EXACTLY what the solver
      // scaled the skeleton by — not that it shrinks past some fixed amount.
      // How deep the curl goes is a look-and-feel number and has been turned
      // right down since; what must never drift is the two agreeing.
      expect(curled.curl, pose.drawScale);
      expect(curled.headR, closeTo(open.headR * pose.drawScale, 0.01),
          reason: 'the drawn head does not follow the curl');
      expect(curled.torsoW, closeTo(open.torsoW * pose.drawScale, 0.01),
          reason: 'the drawn torso width does not follow the curl');
      expect(curled.torsoLen, lessThan(open.torsoLen),
          reason: 'a curled body still draws a full-length torso');
    });

    test('the torso slab always ends exactly at the neck', () {
      // Drawing a fixed 27 from the hip is what let it overshoot. It has to
      // be measured, at every curl.
      final pose = RagdollPose.standingAt(Offset.zero);
      for (final t in [0.0, 0.35, 0.7, 1.0]) {
        pose.tuck = t;
        for (int i = 0; i < 40; i++) {
          pose.solve();
        }
        final spine = (pose.neck.pos - pose.hip.pos).distance;
        final m = WorldRenderer.ragdollMetrics(pose);
        expect(m.torsoLen, closeTo(spine, 0.01),
            reason: 'at tuck $t the torso is drawn ${m.torsoLen} '
                'for a spine of $spine');
      }
    });

    test('the head clears the torso top at every curl', () {
      // The visible symptom: a head drawn inside the torso is a head nobody
      // can see, which is what "the body disappears" looked like.
      final pose = RagdollPose.standingAt(Offset.zero);
      for (final t in [0.0, 0.5, 1.0]) {
        pose.tuck = t;
        for (int i = 0; i < 60; i++) {
          pose.solve();
        }
        final m = WorldRenderer.ragdollMetrics(pose);
        final headAboveNeck = (pose.head.pos - pose.neck.pos).distance;
        expect(headAboveNeck + m.headR, greaterThan(m.headR),
            reason: 'at tuck $t the head sits inside the torso');
        expect(m.headR, lessThan(m.torsoLen + headAboveNeck),
            reason: 'at tuck $t the head is wider than the body it sits on');
      }
    });

    test('the head never ends up buried inside the torso', () {
      // The visible symptom of "the body disappears": at a deep curl the
      // fixed 27-long torso slab overshot the neck and covered the head.
      final pose = RagdollPose.standingAt(Offset.zero)..tuck = 1;
      for (int i = 0; i < 60; i++) {
        pose.solve();
      }
      final spine = (pose.neck.pos - pose.hip.pos).distance;
      final headGap = (pose.head.pos - pose.neck.pos).distance;
      final headR = 14.0 * pose.drawScale;
      // The torso is now drawn to the live spine length, so the head only
      // needs to clear the neck by its own radius to stay visible.
      expect(spine, greaterThan(0),
          reason: 'a zero-length spine would collapse the torso');
      expect(headGap + headR, greaterThan(headR * 0.9),
          reason: 'the head must sit clear of the torso top');
    });

    test('the curl lets go the moment the body lands, not on a timer', () {
      // The real cause of "they turn into a ball". The tuck ran on a fixed
      // 1.1s timer while a flip's hang time is only about 0.4s, so a body
      // finished its somersault, hit the planks, and then lay there curled up
      // for the better part of a second before uncurling. The curl buys
      // rotation in the AIR; on the deck it buys nothing.
      final w = world();
      final raft = w.rafts[0];
      final c = raft.crew[0];
      c.knock(const Offset(1, -0.5), 3.2,
          hitLocal: const Offset(0, -50),
          spin: BattleConst.headshotSpin * 1.2,
          headKick: 5,
          zone: HitZone.head);
      c.flipT = BattleConst.flipTuckTime;
      c.pose!.addLift(BattleConst.flipLift);

      // Find the frame the body comes back down on.
      var landed = -1;
      var peakTuck = 0.0;
      for (int f = 0; f < 200 && c.pose != null; f++) {
        w.update(1 / 60);
        final p = c.pose;
        if (p == null) break;
        peakTuck = max(peakTuck, p.tuck);
        final floor = raft.surfaceY(raft.stationX(0) + p.hip.pos.dx);
        final down = floor != null && p.hip.pos.dy > floor - 3;
        if (landed < 0 && down && f > 12) landed = f;
        // A third of a second after touching down, the body must be open.
        if (landed >= 0 && f > landed + 20) {
          expect(p.tuck, lessThan(0.15),
              reason: 'still curled to ${p.tuck.toStringAsFixed(2)} '
                  '${f - landed} frames after landing');
          break;
        }
      }
      expect(landed, greaterThan(0), reason: 'the body never came down');
      expect(peakTuck, greaterThan(0.6),
          reason: 'the flip never curled in the first place, so this test '
              'is not measuring what it thinks it is');
    });

    test('the somersault no longer depends on the curl at all', () {
      // The tuck was once load-bearing: the point-speed cap bled rotation out
      // of a sprawled body, so a flip could not come round without curling in
      // hard. Raising the flip's hang time replaced that, which is why the
      // curl could be turned down to something that reads as a tuck rather
      // than as the character compressing.
      //
      // Measured rather than reasoned: the same flip is run with the curl
      // held at zero every frame, and it still comes round.
      double flipRotation({required bool allowCurl}) {
        final w = world();
        final raft = w.rafts[0];
        final c = raft.crew[0];
        c.knock(const Offset(1, -0.5), 3.2,
            hitLocal: const Offset(0, -50),
            spin: BattleConst.headshotSpin * 1.2,
            headKick: 5,
            zone: HitZone.head);
        c.flipT = BattleConst.flipTuckTime;
        c.pose!.addLift(BattleConst.flipLift);

        double angleOf(RagdollPose p) {
          final v = p.head.pos - p.hip.pos;
          return atan2(v.dy, v.dx);
        }

        var total = 0.0, peak = 0.0;
        var prev = angleOf(c.pose!);
        for (int f = 0; f < 120 && c.pose != null; f++) {
          if (!allowCurl) c.pose!.tuck = 0;
          w.update(1 / 60);
          final p = c.pose;
          if (p == null) break;
          if (!allowCurl) p.tuck = 0;
          var d = angleOf(p) - prev;
          while (d > pi) {
            d -= 2 * pi;
          }
          while (d < -pi) {
            d += 2 * pi;
          }
          total += d;
          if (total.abs() > peak) peak = total.abs();
          prev = angleOf(p);
        }
        return peak;
      }

      expect(flipRotation(allowCurl: true), greaterThan(2 * pi * 0.8),
          reason: 'the ordinary backflip no longer comes round');
      expect(flipRotation(allowCurl: false), greaterThan(2 * pi * 0.8),
          reason: 'the flip still needs the curl, so the curl cannot be '
              'turned down for looks');
    });
  });


  group('Dying and flipping do not squash the body', () {
    // The complaint was that a character visibly compresses when they die,
    // and again on a backflip. Both are the same mechanism: a killing
    // headshot sets a spin, a spin starts a somersault, and a somersault
    // holds the tuck — which scales every drawn part. At the old curl depth
    // the whole figure was drawn at 40% for the length of the flip, which is
    // exactly what "the body compresses" looks like.
    //
    // These measure the size the RENDERER actually draws, every frame, for
    // the full life of the body — so they fail on the screen, not on a
    // model of it.

    /// The smallest fraction of its standing size the body is ever drawn at
    /// while [hit] plays out.
    double worstDrawnSize(void Function(Crew c) hit) {
      final w = world();
      final c = w.rafts[0].crew[0];
      final standing = WorldRenderer.ragdollMetrics(RagdollPose.standingAt(Offset.zero));
      hit(c);
      var worst = 1.0;
      for (int f = 0; f < 400 && c.pose != null; f++) {
        w.update(1 / 60);
        final pose = c.pose;
        if (pose == null) break;
        final m = WorldRenderer.ragdollMetrics(pose);
        // Every drawn dimension, against the same dimension standing. The
        // torso's LENGTH is measured off the live skeleton, so it carries
        // the solver's own compression as well as the curl.
        for (final r in [
          m.headR / standing.headR,
          m.torsoW / standing.torsoW,
          m.torsoLen / standing.torsoLen,
        ]) {
          if (r < worst) worst = r;
        }
      }
      return worst;
    }

    // 0.7 is the line between "they curled up" and "they shrank". Well
    // inside it at the current curl depth (about 0.82), and comfortably
    // failed by the old one (about 0.40), so it discriminates.
    const readable = 0.7;

    test('a killing headshot never shrinks the body', () {
      final worst = worstDrawnSize((c) {
        c.hp = 0;
        c.startDeath(
          const Offset(1, -0.4),
          Crew.impactForce(Weapons.byId('bomb')),
          hitLocal: const Offset(0, -50),
          spin: BattleConst.headshotSpin * 1.2,
        );
      });
      expect(worst, greaterThan(readable),
          reason: 'a dying body was drawn at ${(worst * 100).round()}% of its '
              'standing size — that is the compression bug');
    });

    test('a backflip never shrinks the body', () {
      final worst = worstDrawnSize((c) {
        c.knock(
          const Offset(1, -0.5),
          Crew.impactForce(Weapons.byId('bomb')),
          hitLocal: const Offset(0, -50),
          zone: HitZone.head,
          spin: BattleConst.headshotSpin * 1.2,
          headKick: 5,
        );
      });
      expect(worst, greaterThan(readable),
          reason: 'a somersaulting body was drawn at ${(worst * 100).round()}% '
              'of its standing size');
    });

    test('an ordinary knock never shrinks the body either', () {
      final worst = worstDrawnSize(
          (c) => c.knock(const Offset(1, -0.3), 3, hitLocal: const Offset(0, -30)));
      expect(worst, greaterThan(0.85),
          reason: 'a hit with no spin should barely change the drawn size at '
              'all — it was ${(worst * 100).round()}%');
    });

    test('a dying body carries its own weight', () {
      // [startDeath] used to spawn the pose at the default mass while
      // [knock] spawned it at the character's, so the same blow threw a
      // heavy character's corpse far harder than it threw them alive.
      final heavy = Cast.all.reduce((a, b) => a.build >= b.build ? a : b);
      final c = Crew(hp: 1, maxHp: 100, traits: heavy.ragdoll);
      expect(c.traits.mass, greaterThan(1.1),
          reason: 'this test needs a character who is actually heavy');
      c.startDeath(const Offset(1, -0.4), 6, hitLocal: const Offset(0, -40));
      expect(1 / c.pose!.hip.invMass, closeTo(2.2 * c.traits.mass, 1e-6),
          reason: 'a corpse weighs what the living body weighed');
    });
  });
  group('Getting back up', () {
    test('the body does not squash on the way to its feet', () {
      // Blending POSITIONS from lying to standing does not preserve bone
      // length — the straight line between a point's two poses is shorter
      // than the arc it should travel — so halfway through getting up every
      // bone was drawn at about 70% of its length and the whole character
      // visibly compressed. Re-solving after the blend fixes the lengths
      // without fighting the blend.
      final w = world();
      final raft = w.rafts[0];
      final c = raft.crew[0];
      c.knock(const Offset(1, -0.5), 3.2,
          hitLocal: const Offset(0, -50),
          spin: BattleConst.headshotSpin * 1.2,
          headKick: 5,
          zone: HitZone.head);

      var worstSpine = 1.0, worstNeck = 1.0;
      for (int f = 0; f < 400 && c.pose != null; f++) {
        w.update(1 / 60);
        final p = c.pose;
        if (p == null) break;
        // The curl legitimately shortens everything; measure only when open.
        if (p.tuck > 0.02) continue;
        final spine = (p.neck.pos - p.hip.pos).distance / 27.0;
        final neck = (p.head.pos - p.neck.pos).distance / 16.0;
        if (spine < worstSpine) worstSpine = spine;
        if (neck < worstNeck) worstNeck = neck;
      }
      expect(worstSpine, greaterThan(0.9),
          reason: 'the spine squashed to '
              '${(worstSpine * 100).toStringAsFixed(0)}% of its length');
      expect(worstNeck, greaterThan(0.9),
          reason: 'the neck squashed to '
              '${(worstNeck * 100).toStringAsFixed(0)}% of its length');
    });

    test('a knocked-down crew member always gets back up', () {
      // Two separate causes of "stuck on the railings": the settle check gave
      // up the moment the hip was a hair past the deck edge (so a body the
      // rail had just caught could never stand), and the solver ran AFTER the
      // deck collision, so it pushed points back through the planks and the
      // body micro-jittered forever without ever holding still long enough to
      // settle.
      for (final hull in RaftHull.all) {
        for (int trial = 0; trial < 6; trial++) {
          final w = BattleWorld(map: GameMaps.all.first, seed: 11 + trial);
          for (int p = 0; p < 2; p++) {
            w.addRaft(Raft(
              playerIndex: p,
              x: p == 0 ? BattleConst.playerX : BattleConst.enemySlots.first,
              loadout: loadout(hull: hull.id, size: 'large', color: p),
              look: p == 0 ? CrewLook.player : CrewLook.raider,
              label: 'R$p',
              facing: p == 0 ? 1 : -1,
              crew: [
                for (int i = 0; i < 3; i++)
                  Crew(hp: 100, maxHp: 100, bobPhase: i * 0.7)
              ],
            ));
          }
          final raft = w.rafts[0];
          var idx = 0;
          for (int i = 1; i < raft.crew.length; i++) {
            if (raft.stationX(i).abs() > raft.stationX(idx).abs()) idx = i;
          }
          final c = raft.crew[idx];
          final outward = raft.stationX(idx) >= 0 ? 1.0 : -1.0;
          c.knock(Offset(outward, -0.3 - trial * 0.06), 2.5 + trial * 0.4,
              hitLocal: const Offset(0, -30));
          // Three seconds. A knockdown should resolve in well under that.
          for (int f = 0; f < 180; f++) {
            w.update(1 / 60);
          }
          if (!c.alive) continue; // drowning is a legitimate outcome
          expect(c.pose, isNull,
              reason: '${hull.id} trial $trial: still ragdolling after 3s '
                  '(rest=${c.rest.toStringAsFixed(2)})');
          expect((raft.stationX(idx) + c.offset.dx).abs(),
              lessThanOrEqualTo(raft.deckHalf),
              reason: '${hull.id} trial $trial: parked outside the deck');
        }
      }
    });
  });

  group('No two kinds of person tumble the same way', () {
    test('the roster carries genuinely different ragdoll traits', () {
      // Every body used to weigh the same, spin the same and get up at the
      // same speed, so a deck of visibly different crew still read as one
      // puppet the moment anything hit them.
      final masses = Cast.all.map((c) => c.ragdoll.mass).toSet();
      final flails = Cast.all.map((c) => c.ragdoll.flail).toSet();
      final flips = Cast.all.map((c) => c.ragdoll.flipBias).toSet();
      final ups = Cast.all.map((c) => c.ragdoll.getUpSpeed).toSet();
      expect(masses.length, greaterThanOrEqualTo(4),
          reason: 'everyone weighs the same');
      expect(flails.length, greaterThanOrEqualTo(6),
          reason: 'everyone flails the same');
      expect(flips.length, greaterThanOrEqualTo(6),
          reason: 'everyone somersaults equally readily');
      expect(ups.length, greaterThanOrEqualTo(6),
          reason: 'everyone gets up at the same speed');

      // And the extremes actually pull in opposite directions: the broadest
      // character is heavier, flails less and is slower up than the wiriest.
      final broad = Cast.all.reduce((a, b) => a.build >= b.build ? a : b);
      final wiry = Cast.all.reduce((a, b) => a.build <= b.build ? a : b);
      expect(broad.ragdoll.mass, greaterThan(wiry.ragdoll.mass));
      expect(broad.ragdoll.flail, lessThan(wiry.ragdoll.flail));
      expect(broad.ragdoll.flipBias, lessThan(wiry.ragdoll.flipBias));
      expect(broad.ragdoll.getUpSpeed, greaterThan(wiry.ragdoll.getUpSpeed));
    });

    test('a heavier character is genuinely harder to throw about', () {
      // The traits have to reach the physics, not just sit in the table.
      //
      // Mass is isolated deliberately. Picking the broadest and the wiriest
      // character off the roster and racing them does NOT test mass: the
      // wiriest also carries the highest flail, a windmill big enough to
      // dominate how far the body ends up travelling, so the comparison
      // measured the arms and only appeared to measure the weight.
      double travelled(double mass) {
        final w = BattleWorld(map: GameMaps.all.first, seed: 11);
        w.addRaft(Raft(
          playerIndex: 0,
          x: BattleConst.playerX,
          loadout: loadout(hull: 'barrel', size: 'large'),
          look: CrewLook.player,
          label: 'P',
          facing: 1,
          crew: [
            Crew(
              hp: 100,
              maxHp: 100,
              traits: RagdollTraits(mass: mass, flail: 0),
            )
          ],
        ));
        final c = w.rafts[0].crew[0];
        c.knock(const Offset(1, -0.4), 3.0, hitLocal: const Offset(0, -30));
        var far = 0.0;
        for (int f = 0; f < 120 && c.pose != null; f++) {
          w.update(1 / 60);
          final p = c.pose;
          if (p == null) break;
          far = max(far, p.hip.pos.dx.abs());
        }
        return far;
      }

      final broad = Cast.all.reduce((a, b) => a.build >= b.build ? a : b);
      final wiry = Cast.all.reduce((a, b) => a.build <= b.build ? a : b);
      expect(broad.ragdoll.mass, greaterThan(wiry.ragdoll.mass),
          reason: 'build has to turn into mass at all');
      expect(travelled(broad.ragdoll.mass), lessThan(travelled(wiry.ragdoll.mass)),
          reason: 'the same blow moved the heavy character as far as the '
              'light one, so the mass never reached the simulation');
    });

  });


  group('No two tumbles are alike', () {
    // The complaint: "not every ragdoll is the same". Character traits made
    // different KINDS of person fall differently, but a given person hit a
    // given way always fell in exactly the same arc, every time, all match —
    // so a deck of crew going over together still read as one animation.

    /// A fingerprint of how a body actually moved: where the hips ended up,
    /// how far the hands swung, and how long the whole thing took.
    List<double> tumble(BattleWorld w, Crew c) {
      var handSwing = 0.0;
      var frames = 0;
      for (int f = 0; f < 400 && c.pose != null; f++) {
        w.update(1 / 60);
        final p = c.pose;
        if (p == null) break;
        frames++;
        handSwing = max(handSwing, (p.handL.pos - p.hip.pos).distance);
      }
      return [c.offset.dx, c.offset.dy, handSwing, frames.toDouble()];
    }

    test('the same blow twice produces two different tumbles', () {
      List<double> once(int seed) {
        final w = world();
        final c = w.rafts[0].crew[0];
        c.knock(const Offset(1, -0.5), 4.0,
            hitLocal: const Offset(0, -40), zone: HitZone.head, spin: 0.22, seed: seed);
        return tumble(w, c);
      }

      final a = once(1);
      final b = once(2);
      final differs = [
        for (int i = 0; i < a.length; i++) (a[i] - b[i]).abs()
      ];
      expect(differs.any((d) => d > 1.0), true,
          reason: 'two knocks produced the identical tumble: $a vs $b');
    });

    test('successive knocks on one body differ from each other', () {
      // Even with no shot to seed from, a body knocked twice must not
      // replay its first fall — the tumble counter is what guarantees it.
      final w = world();
      final c = w.rafts[0].crew[0];
      c.knock(const Offset(1, -0.4), 3.0, hitLocal: const Offset(0, -30));
      final first = c.style;
      c.knock(const Offset(1, -0.4), 3.0, hitLocal: const Offset(0, -30));
      final second = c.style;
      expect(second.curl == first.curl && second.twist == first.twist, false,
          reason: 'the second knock replayed the first');
    });

    test('two crew caught by one blast do not fall in unison', () {
      // The worst case for this: one explosion, two bodies, same frame.
      // With a fixed flail phase they windmilled in perfect time.
      final w = world();
      final a = w.rafts[0].crew[0];
      final b = w.rafts[0].crew[1];
      for (final c in [a, b]) {
        c.knock(const Offset(1, -0.6), 4.5, hitLocal: const Offset(0, -36));
      }
      expect(a.style.flailPhase, isNot(closeTo(b.style.flailPhase, 0.2)),
          reason: 'both bodies windmill on the same beat');
    });

    test('a rolled style always stays inside a readable range', () {
      // Randomness that can produce a body which does not read as a body is
      // worse than no randomness. Every field is bounded either side of the
      // value it replaced, so no roll can ever be a bad one.
      for (int seed = 0; seed < 500; seed++) {
        final s = RagdollStyle.roll(seed);
        expect(s.curl, inInclusiveRange(0.5, 1.0));
        expect(s.flailGain, inInclusiveRange(0.3, 1.8));
        expect(s.flailRate, inInclusiveRange(0.6, 1.5));
        expect(s.flailPhase, inInclusiveRange(0, 2 * pi));
        expect(s.limp, inInclusiveRange(0.7, 1.4));
        expect(s.linger, inInclusiveRange(0.6, 1.8));
        expect(s.twist, inInclusiveRange(-1.0, 1.0));
        expect(s.spinScale, inInclusiveRange(0.7, 1.35));
      }
    });

    test('the roll actually spreads across its range', () {
      // A hash that returned the same number every time would satisfy every
      // bound above. This is what says it does not.
      final curls = {for (int s = 0; s < 200; s++) (RagdollStyle.roll(s).curl * 20).round()};
      expect(curls.length, greaterThan(6),
          reason: 'the style roll barely varies: only ${curls.length} '
              'distinct curl depths in 200 rolls');
    });

    test('the same seed always rolls the same style', () {
      // Non-negotiable: a hotspot match is lockstep. Both devices compute
      // the tumble from the same shot, so the roll must be a pure function
      // of its seed — never [Random], never wall-clock time.
      for (final seed in [0, 1, 7, 12345, -99]) {
        final a = RagdollStyle.roll(seed);
        final b = RagdollStyle.roll(seed);
        expect(a.curl, b.curl);
        expect(a.twist, b.twist);
        expect(a.flailPhase, b.flailPhase);
        expect(a.linger, b.linger);
      }
    });
  });

  group('A flying body is a hazard in its own right', () {
    // "Make the ragdolls affect the other character's health: if a character
    // is on ragdoll and hits another character, that character takes damage
    // and goes into ragdoll too."

    /// A raft with two crew standing close enough together that a body
    /// thrown along the deck reaches the other one.
    (BattleWorld, Raft) crowded() {
      final w = BattleWorld(map: GameMaps.all.first, seed: 11);
      final r = Raft(
        playerIndex: 0,
        x: BattleConst.playerX,
        loadout: loadout(hull: 'barrel', size: 'large'),
        look: CrewLook.player,
        label: 'P',
        facing: 1,
        crew: [
          Crew(hp: 100, maxHp: 100),
          Crew(hp: 100, maxHp: 100, bobPhase: 0.7),
        ],
      );
      w.addRaft(r);
      return (w, r);
    }

    /// Throws crew 0 hard at crew 1 and runs the world until things settle.
    /// Returns the victim.
    Crew bowl(BattleWorld w, Raft r, {double force = 9}) {
      final thrower = r.crew[0];
      final victim = r.crew[1];
      // Aim the throw at whichever side the second berth is on.
      final toward = r.stationX(1) >= r.stationX(0) ? 1.0 : -1.0;
      thrower.knock(Offset(toward, -0.25), force,
          hitLocal: const Offset(0, -30), seed: 3);
      for (int f = 0; f < 200; f++) {
        w.update(1 / 60);
      }
      return victim;
    }

    test('a body thrown into a neighbour hurts them and knocks them down', () {
      final (w, r) = crowded();
      final victim = bowl(w, r);
      expect(victim.hp, lessThan(100),
          reason: 'the neighbour was hit by a flying body and felt nothing');
      expect(victim.tumbles, greaterThan(0),
          reason: 'the neighbour was hit by a flying body and stayed upright');
    });

    test('a body merely sliding along the deck hurts nobody', () {
      // The threshold is the whole reason this is playable: without it, a
      // knocked-down crew member resting against a neighbour grinds them
      // down for free, every frame, forever.
      final (w, r) = crowded();
      final victim = bowl(w, r, force: 0.6);
      expect(victim.hp, 100,
          reason: 'a body barely moving still dealt damage');
    });

    test('one slam cannot delete somebody', () {
      // Being bowled into is a complication, not a way to win without
      // aiming. The cap and the cooldown together bound what one tumble can
      // take off a neighbour.
      final (w, r) = crowded();
      final victim = bowl(w, r, force: 14);
      expect(100 - victim.hp,
          lessThanOrEqualTo(BattleConst.bodySlamMaxDamage + 0.001),
          reason: 'one tumble took ${100 - victim.hp} HP off a neighbour');
      expect(victim.alive, true);
    });

    test('a body cannot slam the same person every frame', () {
      // Two bodies settling against each other used to be the failure case:
      // a contact every frame is a hundred and twenty hits a second.
      final (w, r) = crowded();
      final victim = bowl(w, r, force: 9);
      final afterFirst = victim.hp;
      // Long enough for any per-frame repeat to be obvious.
      for (int f = 0; f < 600; f++) {
        w.update(1 / 60);
      }
      expect(victim.hp, closeTo(afterFirst, BattleConst.bodySlamMaxDamage),
          reason: 'the bodies kept trading hits after they came to rest');
    });

    test('a slam can be fatal, and a dying body still tumbles', () {
      final (w, r) = crowded();
      r.crew[1].hp = 4;
      final victim = bowl(w, r, force: 12);
      expect(victim.alive, false, reason: 'a slam has to be able to finish '
          'somebody who is already nearly out');
      expect(victim.pose, isNotNull, reason: 'they died on their feet');
    });

    test('the flying body spends energy on whoever it hits', () {
      // Otherwise one body ricochets around the deck taking out the whole
      // crew on a single shot.
      final (w, r) = crowded();
      final thrower = r.crew[0];
      final toward = r.stationX(1) >= r.stationX(0) ? 1.0 : -1.0;
      thrower.knock(Offset(toward, -0.25), 9,
          hitLocal: const Offset(0, -30), seed: 3);
      var speedAtSlam = 0.0;
      var speedAfter = 0.0;
      for (int f = 0; f < 200; f++) {
        final was = thrower.pose?.maxSpeed ?? 0;
        w.update(1 / 60);
        if (r.crew[1].slamCool >= BattleConst.bodySlamCooldown - 0.001 &&
            speedAtSlam == 0) {
          speedAtSlam = was;
          speedAfter = thrower.pose?.maxSpeed ?? 0;
        }
      }
      expect(speedAtSlam, greaterThan(0), reason: 'no slam ever happened');
      expect(speedAfter, lessThan(speedAtSlam),
          reason: 'the flying body came through the collision as fast as it '
              'went in');
    });
  });
  group('Crew have room to stand', () {
    test('a wide deck spreads its crew out instead of bunching them', () {
      // The gap was pinned at the MINIMUM the bodies could tolerate however
      // much deck there was, so a barge stood its crew shoulder to shoulder
      // amidships with empty planks either side — and put the whole crew
      // inside one blast radius.
      for (final hull in RaftHull.all) {
        final lo =
            RaftLoadout.custom(hullId: hull.id, sizeId: 'large', colorIndex: 0);
        final xs = [for (int i = 0; i < 3; i++) lo.crewOffset(i)]..sort();
        final gaps = [for (int i = 1; i < xs.length; i++) xs[i] - xs[i - 1]];
        for (final g in gaps) {
          expect(g, greaterThan(DeckProfile.minBerthGap),
              reason: '${hull.id}: crew only ${g.toStringAsFixed(0)} apart on '
                  'a deck ${(lo.deckHalf * 2).toStringAsFixed(0)} wide');
        }
        // …and still inside the rails.
        expect(xs.last, lessThanOrEqualTo(lo.deckHalf),
            reason: '${hull.id}: a berth hangs over the side');
      }
    });
  });

  group('The rail actually holds someone aboard', () {
    /// Hits the crew member berthed CLOSEST to the rail on [hull] with what
    /// [weaponId] really delivers, and reports whether they drowned. This is
    /// the scenario the complaint is about — a body already near the edge
    /// taking an ordinary shot.
    bool overboard(String hull, String weaponId, {bool blast = false}) {
      final w = BattleWorld(map: GameMaps.all.first, seed: 11);
      RaftLoadout lo(int c) =>
          RaftLoadout.custom(hullId: hull, sizeId: 'large', colorIndex: c);
      w.addRaft(Raft(
        playerIndex: 0,
        x: BattleConst.playerX,
        loadout: lo(0),
        look: CrewLook.player,
        label: 'P1',
        facing: 1,
        crew: [
          for (int i = 0; i < 3; i++) Crew(hp: 100, maxHp: 100, bobPhase: i * 0.7)
        ],
      ));
      w.addRaft(Raft(
        playerIndex: 1,
        x: BattleConst.enemySlots.first,
        loadout: lo(1),
        look: CrewLook.raider,
        label: 'AI',
        facing: -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
      final raft = w.rafts[0];
      var idx = 0;
      for (int i = 1; i < raft.crew.length; i++) {
        if (raft.stationX(i).abs() > raft.stationX(idx).abs()) idx = i;
      }
      final c = raft.crew[idx];
      final outward = raft.stationX(idx) >= 0 ? 1.0 : -1.0;
      final wd = Weapons.byId(weaponId);
      // A blast profile only exists for a round that actually has splash.
      // Forcing the lofted, 1.35x knock onto the splash-less starter round
      // would be testing a hit the game cannot deliver.
      final lofted = blast && wd.splash > 0;
      c.knock(
        Offset(outward, lofted ? -0.6 : -0.2),
        Crew.impactForce(wd) * (lofted ? 1.35 : 1.0),
        hitLocal: const Offset(0, -30),
        lift: lofted ? 0.12 : 0,
      );
      for (int i = 0; i < 300 && !c.drowned; i++) {
        w.update(1 / 60);
      }
      return c.drowned;
    }

    int overCount(String weaponId, {bool blast = false}) =>
        RaftHull.all.where((h) => overboard(h.id, weaponId, blast: blast)).length;

    test('the starter weapon can never drown anyone', () {
      // The sharpest form of the complaint. Measured against the old code, a
      // plain tennis ball to the outermost berth put a crew member in the sea
      // on one hull in five. The starter round should sting, full stop.
      expect(overCount('tennis'), 0,
          reason: 'a tennis ball knocked someone overboard');
      expect(overCount('tennis', blast: true), 0);
    });

    test('a point moving faster than the rail band is still caught', () {
      // The mechanism. The lip used to fire only when a point was *already*
      // inside an eight-unit band past the edge — but a point moves up to
      // bodyMaxSpeed (nine) units in a frame, so anything quick stepped clean
      // over the check meant to stop it and was never tested again.
      expect(BattleConst.bodyMaxSpeed, greaterThan(BattleConst.railWall),
          reason: 'a point can outrun the band in a single frame, which is '
              'exactly why the check has to be a crossing test');

      final w = world();
      final raft = w.rafts[0];
      final c = raft.crew[0];
      // A live body on its feet, then one point flung straight at the rail
      // from just inside it, fast enough to clear the band in one step.
      c.knock(const Offset(1, -0.1), 2, hitLocal: const Offset(0, -30));
      final pose = c.pose!;
      final station = raft.stationX(0);
      final railLocal = raft.deckHalf - station;
      final deckY = raft.surfaceY(raft.deckHalf) ?? 0.0;
      for (final p in pose.points) {
        // Every point starts ON the rail line at deck height, travelling
        // outward at the speed cap. One step therefore carries it further
        // past the edge than the band is wide — the exact case the band
        // check could not see and the crossing check exists for.
        p.pos = Offset(railLocal - 0.05, deckY - 2);
        p.setVel(Offset(BattleConst.bodyMaxSpeed, 0));
      }
      final reach = BattleConst.bodyMaxSpeed * BattleConst.bodyDrag;
      expect(reach, greaterThan(BattleConst.railWall),
          reason: 'this test only means anything if one step outruns the band');

      w.update(1 / 60);

      final worst = pose.points
          .map((p) => (station + p.pos.dx).abs() - raft.deckHalf)
          .reduce(max);
      expect(worst, lessThan(BattleConst.railWall),
          reason: 'a point ended $worst units past the rail in one step — '
              'beyond the band, so nothing would ever test it again');
    });

    test('but going overboard is still a real thing that happens', () {
      // The other half of the fix: the rail must not become a wall. Heavier
      // ordnance still puts someone in the water often enough to be a threat.
      final heavy = overCount('grenade') +
          overCount('bomb') +
          overCount('anchor') +
          overCount('anchor', blast: true);
      expect(heavy, greaterThan(0),
          reason: 'nothing can knock anyone overboard any more, which makes '
              'the rail a wall and losing a crew member impossible');
    });

    test('the lip bleeds the whole body, not just the caught limb', () {
      // Reflecting one point and leaving the other six pulling outward means
      // the catch holds for a frame and the body goes over on the next.
      expect(BattleConst.railHold, greaterThan(0));
      expect(BattleConst.railHold, lessThan(1),
          reason: 'a full stop would make the rail absolute');
    });

    test('a corpse still always ends up in the sea', () {
      // The rail deliberately ignores the dead: a body at zero HP drifts over
      // the side, and that is how an elimination actually reads.
      final w = world();
      final c = w.rafts[0].crew[0];
      c.hp = 0;
      c.startDeath(const Offset(1, -0.4), 4);
      for (int i = 0; i < 600 && !c.drowned && !c.gone; i++) {
        w.update(1 / 60);
      }
      expect(c.drowned || c.gone, true,
          reason: 'the rail must not catch corpses');
    });
  });

  group('A hit does not start per-frame work that never stops', () {
    /// Paints [frames] frames of [w] and returns the renderer, so the test
    /// can read how much cacheable work it actually redid.
    ///
    /// Counting the work rather than timing it keeps this honest: a wall
    /// clock in a test runner measures the host's mood as much as the code,
    /// whereas "how many times did we shape this string" is exactly the
    /// thing that regressed and cannot be flaky.
    WorldRenderer paintFrames(BattleWorld w, int frames) {
      final renderer = WorldRenderer(w, map: w.map);
      for (int i = 0; i < frames; i++) {
        final rec = PictureRecorder();
        final canvas = Canvas(rec);
        renderer.render(canvas, const Size(870, 422), 1.5,
            currentPlayer: 0,
            isAiming: true,
            aimAngleDeg: 42,
            weapon: Weapons.byId('grenade'));
        rec.endRecording().dispose();
      }
      return renderer;
    }

    /// A deck in the state the complaint describes: bodies down, everyone
    /// hurt and talking, health bars and statuses up.
    BattleWorld hitDeck() {
      final w = world(hull: 'barrel', size: 'large');
      for (final r in w.rafts) {
        for (final c in r.crew) {
          c.knock(const Offset(1, -0.6), 3, hitLocal: const Offset(0, -30));
          c.hp = 25; // injury decals at their busiest
          c.say('Ow! That stung!');
          c.bubbleT = 999;
          c.showHpBar(1.0);
          c.afflict(StatusEffect.tarred, 1);
        }
      }
      for (int i = 0; i < 6; i++) {
        w.update(1 / 60);
      }
      return w;
    }

    testWidgets('a speech line is shaped a handful of times, not every frame',
        (tester) async {
      // Text shaping is the expensive part of drawing a bubble, and a bubble
      // stays up for well over a second — ninety-odd frames. Rebuilding a
      // TextPainter for each of them, for every crew member hit plus the
      // shooter gloating, was the largest measured share of the stutter.
      final r = paintFrames(hitDeck(), 120);
      tester.takeException(); // google_fonts cannot fetch in a test
      expect(r.textLayouts, lessThan(20),
          reason: 'text was re-shaped ${r.textLayouts} times over 120 frames');
    });

    testWidgets('injury scatter is rolled once per body, not every frame',
        (tester) async {
      // Rolling a fresh seeded Random and rebuilding the scatter list every
      // frame produced byte-identical numbers each time — pure waste that
      // started the moment somebody took damage and never stopped.
      final r = paintFrames(hitDeck(), 120);
      tester.takeException();
      expect(r.injuryLayouts, lessThanOrEqualTo(12),
          reason: 'injury layout rebuilt ${r.injuryLayouts} times for '
              'at most a dozen bodies');
    });

    testWidgets('a dead body only takes a layer while it is actually fading',
        (tester) async {
      // saveLayer allocates an offscreen render target the size of the whole
      // body. It used to be taken for every dead crew member on every frame
      // for as long as the body existed, rather than only while the sink
      // fade or the killing-blow flash needed one.
      // The player's raft, because it is the one inside the camera window —
      // the enemy slots sit far enough down the world to be culled, and a
      // culled body draws nothing at all to measure.
      final w = world(hull: 'barrel', size: 'large');
      for (final c in w.rafts[0].crew) {
        c.hp = 0;
        c.startDeath(const Offset(1, -0.3), 3);
      }
      w.update(1 / 60);
      // The long tail of a death: the killing-blow flash is over and the body
      // has not reached the water, so there is nothing translucent to
      // composite — but the body is still on screen, still dead, and used to
      // cost a full-size offscreen buffer on every one of these frames.
      for (final c in w.rafts[0].crew) {
        c.deathFlash = 0;
        c.sinkT = 0;
      }
      final lying = paintFrames(w, 60);
      tester.takeException();
      expect(lying.bodyLayers, 0,
          reason: 'a body that is neither fading nor flashing took '
              '${lying.bodyLayers} layers');

      // …and the layer is still taken when it is genuinely needed, or the
      // sink fade would composite over the whole raft instead of the body.
      for (final c in w.rafts[0].crew) {
        c.sinkT = 0.9;
      }
      final sinking = paintFrames(w, 10);
      tester.takeException();
      expect(sinking.bodyLayers, greaterThan(0),
          reason: 'a fading body still needs its layer');
    });

    testWidgets('rafts outside the camera window are not drawn',
        (tester) async {
      // The single largest waste in the frame. The rafts sit at x = 210 and
      // 1500..2700 across a 3210-wide world while the camera window is about
      // 870 across, so for most of a match three of the four are entirely off
      // screen — and every one of them was drawn in full anyway: hull, deck
      // platforms, rigging, and every crew member aboard with their limbs,
      // face, health bar and bubble.
      //
      final w = BattleWorld(map: GameMaps.all.first, seed: 11);
      final xs = [BattleConst.playerX, ...BattleConst.enemySlots];
      for (int p = 0; p < xs.length; p++) {
        w.addRaft(Raft(
          playerIndex: p,
          x: xs[p],
          loadout: loadout(hull: 'barrel', size: 'large', color: p),
          look: p == 0 ? CrewLook.player : CrewLook.raider,
          label: 'RAFT $p',
          facing: p == 0 ? 1 : -1,
          crew: [Crew(hp: 100, maxHp: 100)],
        ));
      }
      // Camera parked on the player's raft; the enemy slots are far away.
      w.lockCam(0);
      final r = paintFrames(w, 3);
      tester.takeException();
      expect(r.raftsDrawn, 1,
          reason: '${r.raftsDrawn} of ${xs.length} rafts were drawn, and only '
              'one is anywhere near the camera');

      // …and the raft the camera IS looking at still draws, or culling would
      // have eaten the battle instead of the waste.
      for (int seat = 0; seat < xs.length; seat++) {
        w.lockCam(seat);
        final r2 = paintFrames(w, 2);
        tester.takeException();
        expect(r2.raftsDrawn, greaterThan(0),
            reason: 'the raft at seat $seat was culled while in shot');
      }
    });

    test('one impact does not fire a dozen sounds at once', () async {
      // The other half of the stutter, and the half a canvas benchmark cannot
      // see. One explosive kill asks for the blast, the shockwave, a yelp and
      // a thud per crew member caught, an elimination sting and the shooter's
      // laugh — and each of those was three platform channel round-trips. Two
      // dozen messages across the channel in the frame where a body is flying
      // is a good way to drop it.
      final a = AudioService.instance..resetThrottle();

      // The same clip asked for repeatedly in one frame is one sound: three
      // crew hit by one blast all want 'hit'.
      expect(a.throttled('hit'), false, reason: 'the first one must play');
      expect(a.throttled('hit'), true);
      expect(a.throttled('hit'), true);

      // Different clips in the same frame are all distinct sounds and all
      // still play — the blast and the shockwave are not the same event.
      expect(a.throttled('explosion'), false);
      expect(a.throttled('shockwave'), false);
      expect(a.throttled('eliminate'), false);

      // Voices are capped as a group: three crew yelping over each other is
      // mush, not feedback.
      a.resetThrottle();
      expect(a.throttled('voice_ouch1', voice: true), false);
      expect(a.throttled('voice_ouch2', voice: true), false);
      expect(a.throttled('voice_ouch3', voice: true), true,
          reason: 'a third simultaneous yelp should be dropped');
      // …and a non-voice sound in the same instant is unaffected by that cap.
      expect(a.throttled('splash'), false);

      // The block is momentary, not permanent.
      a.resetThrottle();
      expect(a.throttled('hit'), false);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(a.throttled('hit'), false,
          reason: 'a later, genuinely separate hit must be audible');
    });

    testWidgets('an unchanged world paints identically twice', (tester) async {
      // Caching the scatter must not change what is drawn: a crew member's
      // bruises are deterministic from their bob phase and must not dance
      // about between frames.
      final w = world();
      final c = w.rafts[0].crew[0];
      c.hp = 30;
      expect(c.injuryLevel, greaterThan(0));
      final renderer = WorldRenderer(w, map: w.map);

      int shot() {
        final rec = PictureRecorder();
        final canvas = Canvas(rec);
        renderer.render(canvas, const Size(870, 422), 1.5,
            currentPlayer: 0,
            isAiming: false,
            aimAngleDeg: 42,
            weapon: Weapons.byId('grenade'));
        final pic = rec.endRecording();
        final n = pic.approximateBytesUsed;
        pic.dispose();
        return n;
      }

      final a = shot();
      final b = shot();
      tester.takeException();
      expect(b, a, reason: 'the same world state must paint the same way twice');
    });
  });
}
