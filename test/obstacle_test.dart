import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// Obstacles in the channel.
///
/// Every battle was fought across empty water, so the only thing between two
/// rafts was distance: once you had the range, the same shot worked all
/// match. These put something solid in the middle, so a line has to be found
/// as well as a range.
///
/// The rules that matter are about fairness rather than about hitting
/// things. A field that can block every possible arc, that sits on top of
/// somebody's raft, or that differs between the two devices in a hotspot
/// match would each be worse than plain water.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  BattleWorld world({MapDef? map, int seed = 7}) {
    final w = BattleWorld(map: map ?? GameMaps.all.first, seed: seed);
    for (int i = 0; i < 2; i++) {
      w.addRaft(Raft(
        playerIndex: i,
        x: i == 0 ? BattleConst.playerX : BattleConst.enemySlots.first,
        loadout:
            RaftLoadout.custom(hullId: 'log', sizeId: 'medium', colorIndex: i),
        look: i == 0 ? CrewLook.player : CrewLook.raider,
        label: 'R$i',
        facing: i == 0 ? 1 : -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
    }
    return w;
  }

  /// Fires and steps until the shot resolves.
  ShotOutcome? fireAt(BattleWorld w, Offset from,
      {double angle = 0, double power = 90}) {
    w.fire(
      from: from,
      angleDeg: angle,
      power: power,
      weapon: Weapons.starter,
      facing: 1,
      owner: 0,
    );
    ShotOutcome? out;
    for (int i = 0; i < 600 && out == null; i++) {
      out = w.stepShot();
    }
    return out;
  }

  group('The field itself', () {
    test('every scene puts something in the channel', () {
      for (final map in GameMaps.all) {
        expect(world(map: map).obstacles, isNotEmpty,
            reason: '${map.id} is still open water');
      }
    });


    test('each scene builds its obstacles out of its own materials', () {
      // The shapes alone were not enough: a rock was the same grey lump in
      // the tropics, in the ice and on the lava flow, so six scenes that
      // differ in every other colour were dropping identical objects into
      // the water.
      final stones = <int, String>{};
      final timbers = <int, String>{};
      for (final map in GameMaps.all) {
        final s = map.stone.value;
        final t = map.timber.value;
        expect(stones.containsKey(s), false,
            reason: '${map.id} has the same stone as ${stones[s]}');
        expect(timbers.containsKey(t), false,
            reason: '${map.id} has the same timber as ${timbers[t]}');
        stones[s] = map.id;
        timbers[t] = map.id;
        // A shade has to be a shade — visibly darker than the face it sits
        // beside, or the obstacle reads flat.
        expect(map.stoneShade.computeLuminance(),
            lessThan(map.stone.computeLuminance()),
            reason: '${map.id}: the stone shade is not darker than the stone');
        expect(map.timberShade.computeLuminance(),
            lessThan(map.timber.computeLuminance()),
            reason: '${map.id}: the timber shade is not darker than the timber');
      }
    });

    test('every scene fields a genuinely different set of obstacles', () {
      // Same colours on the same shapes would still be the same field.
      final sets = <String, String>{};
      for (final map in GameMaps.all) {
        final key = (map.obstacles.map((o) => o.name).toList()..sort()).join(',');
        expect(sets.containsKey(key), false,
            reason: '${map.id} fields exactly the same kinds as ${sets[key]}');
        sets[key] = map.id;
      }
    });
    test('nothing is ever placed on top of a raft', () {
      // The one placement bug that would actually ruin a match: an obstacle
      // over a berth hides the crew and blocks every shot at them.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 40; seed++) {
          final w = world(map: map, seed: seed);
          for (final o in w.obstacles) {
            for (final raft in w.rafts) {
              expect((o.pos.dx - raft.x).abs(),
                  greaterThan(raft.hullHalf + o.halfW),
                  reason: '${map.id} seed $seed: a ${o.kind.name} sits on a '
                      'raft');
            }
          }
        }
      }
    });


    test('nothing is ever placed on the falls', () {
      // An obstacle sits ON the water at its own centre, which is right on a
      // flat terrace and wrong on a slope: across the width of a wreck the
      // surface can drop sixty units, so one end hangs clear in the air and
      // the other is buried. The obstacle band and the main falls overlap by
      // most of their length, so this is not a rare corner — before the
      // placement searched for flat water, about one obstacle in eight
      // landed on the slope.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 60; seed++) {
          final w = world(map: map, seed: seed);
          for (final o in w.obstacles) {
            expect(w.water.onFalls(o.pos.dx, margin: o.halfW), false,
                reason: '${map.id} seed $seed: a ${o.kind.name} straddles a '
                    'falls');
          }
        }
      }
    });

    test('both ends of an obstacle meet the water', () {
      // The symptom the rule above exists to prevent, measured directly on
      // the drawn box rather than on the placement: whatever the terrain
      // does, neither edge may float or sink.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 60; seed++) {
          final w = world(map: map, seed: seed);
          for (final o in w.obstacles) {
            for (final edge in [o.pos.dx - o.halfW, o.pos.dx + o.halfW]) {
              final gap = o.rect.bottom - w.waterAt(edge);
              // The box bottom sits a touch under the surface on purpose so
              // nothing appears to hover; anything beyond that is the box
              // disagreeing with the water it is meant to be floating on.
              expect(gap, inInclusiveRange(-1, 12),
                  reason: '${map.id} seed $seed: a ${o.kind.name} edge is '
                      '${gap.toStringAsFixed(0)} units out of the water');
            }
          }
        }
      }
    });

    test('keeping clear of the falls does not empty the channel', () {
      // The lazy fix is to reject any roll that lands on the slope, which
      // quietly thins the field wherever a falls happens to sit. Searching
      // the slot for flat water instead keeps it stocked.
      var obstacles = 0;
      var worlds = 0;
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 40; seed++) {
          obstacles += world(map: map, seed: seed).obstacles.length;
          worlds++;
        }
      }
      expect(obstacles / worlds, greaterThan(2.2),
          reason: 'only ${(obstacles / worlds).toStringAsFixed(1)} obstacles '
              'per match survive the falls clearance');
    });
    test('obstacles never overlap each other', () {
      // Two boxes sharing space read as one strange shape, and the gap
      // between them becomes impossible to judge.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 40; seed++) {
          final obs = world(map: map, seed: seed).obstacles;
          for (int i = 0; i < obs.length; i++) {
            for (int j = i + 1; j < obs.length; j++) {
              final gap = (obs[i].pos.dx - obs[j].pos.dx).abs() -
                  obs[i].halfW -
                  obs[j].halfW;
              expect(gap, greaterThan(0),
                  reason: '${map.id} seed $seed: ${obs[i].kind.name} and '
                      '${obs[j].kind.name} overlap');
            }
          }
        }
      }
    });

    test('the channel is never walled off completely', () {
      // The fairness guarantee. Whatever is rolled, the solid width has to
      // leave real gaps, or a match can open in a state no amount of aiming
      // can solve.
      final span =
          BattleConst.obstacleBandEnd - BattleConst.obstacleBandStart;
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 40; seed++) {
          final obs = world(map: map, seed: seed).obstacles;
          final solid = obs.fold<double>(0, (sum, o) => sum + o.halfW * 2);
          expect(solid, lessThan(span * 0.55),
              reason: '${map.id} seed $seed: obstacles cover '
                  '${(solid / span * 100).round()}% of the channel');
        }
      }
    });

    test('at most one mast, because a mast has to be gone over', () {
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 60; seed++) {
          final masts = world(map: map, seed: seed)
              .obstacles
              .where((o) => o.kind == ObstacleKind.mast)
              .length;
          expect(masts, lessThanOrEqualTo(1),
              reason: '${map.id} seed $seed has $masts masts');
        }
      }
    });

    test('every obstacle stands out of the water, not under it', () {
      // Against the water at ITS OWN x: the sea is terraced, so an obstacle
      // just past a falls floats a good drop below one before it.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 20; seed++) {
          final w = world(map: map, seed: seed);
          for (final o in w.obstacles) {
            final surface = w.waterAt(o.pos.dx);
            expect(o.rect.top, lessThan(surface - 10),
                reason: '${map.id}: a ${o.kind.name} is submerged');
            expect(o.rect.bottom, greaterThan(surface - 2),
                reason: '${map.id}: a ${o.kind.name} hovers above the water');
          }
        }
      }
    });


    test('heights are randomised, not fixed per kind', () {
      // Fixed heights mean the field is the same set of silhouettes every
      // match, and the arc that cleared one crate clears every crate for
      // ever — the "learn it once" problem the obstacles exist to break,
      // moved up a level.
      final byKind = <ObstacleKind, Set<int>>{};
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 40; seed++) {
          for (final o in world(map: map, seed: seed).obstacles) {
            byKind.putIfAbsent(o.kind, () => <int>{}).add(o.halfH.round());
          }
        }
      }
      expect(byKind, isNotEmpty);
      byKind.forEach((kind, heights) {
        expect(heights.length, greaterThan(4),
            reason: '${kind.name} is always about the same height '
                '(${heights.length} distinct)');
      });
    });

    test('nothing ever reaches the top of the world', () {
      // The cap is measured against the sky ACTUALLY above each obstacle,
      // not a fixed height — the sea is terraced, so one on a raised terrace
      // has markedly less room above it, and a flat cap let the tall kinds
      // run clean off the top of the frame there.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 60; seed++) {
          final w = world(map: map, seed: seed);
          for (final o in w.obstacles) {
            expect(o.rect.top,
                greaterThanOrEqualTo(BattleConst.obstacleSkyMargin - 1),
                reason: '${map.id} seed $seed: a ${o.kind.name} reaches '
                    '${o.rect.top.round()} — off the top of the world');
          }
        }
      }
    });

    test('no kind is stretched out of its own proportions', () {
      // The roll and the mid-channel bonus compound. Unclamped they reach
      // about two and a half times a kind's base, which turns a slender buoy
      // into a needle and stops it reading as the thing it is meant to be.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 60; seed++) {
          final w = world(map: map, seed: seed);
          for (final o in w.obstacles) {
            final base = BattleConst.obstacleSizes[o.kind.name]!.$2;
            final height = w.waterAt(o.pos.dx) - o.rect.top;
            expect(height / base,
                lessThanOrEqualTo(BattleConst.obstacleStretchMax + 0.02),
                reason: '${map.id} seed $seed: a ${o.kind.name} is '
                    '${(height / base).toStringAsFixed(2)}x its base height');
          }
        }
      }
    });


    test('no kind is stretched out of recognition', () {
      // Scaling alone does not know what a thing IS: stretched to the same
      // multiple, a slender mast still reads as a mast while a crate becomes
      // a door and a rock becomes a menhir.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 40; seed++) {
          final w = world(map: map, seed: seed);
          for (final o in w.obstacles) {
            final height = w.waterAt(o.pos.dx) - o.rect.top;
            final aspect = height / (o.halfW * 2);
            final cap = BattleConst.obstacleMaxAspect[o.kind.name]!;
            expect(aspect, lessThanOrEqualTo(cap + 0.02),
                reason: '${map.id} seed $seed: a ${o.kind.name} is '
                    '${aspect.toStringAsFixed(1)} times as tall as it is '
                    'wide, past its limit of $cap');
          }
        }
      }
    });
    test('the field is genuinely tall', () {
      // The whole point of raising them: a crew member stands about a
      // hundred units, so anything the player has to shoot over should be
      // well clear of that rather than ankle-height scenery.
      var tallest = 0.0;
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 40; seed++) {
          final w = world(map: map, seed: seed);
          for (final o in w.obstacles) {
            tallest = max(tallest, w.waterAt(o.pos.dx) - o.rect.top);
          }
        }
      }
      expect(tallest, greaterThan(200),
          reason: 'the tallest obstacle anywhere is only ${tallest.round()} '
              'units — barely twice a crew member');
    });

    test('the tall ones stand in mid-channel', () {
      // Height only changes how you aim when it is in the middle. Near
      // either raft the shot is low anyway and a small lump already blocks
      // it; mid-channel the shot is at the top of its arc, so that is where
      // real height has to be to make anybody aim differently.
      final mid =
          (BattleConst.obstacleBandStart + BattleConst.obstacleBandEnd) / 2;
      final halfSpan =
          (BattleConst.obstacleBandEnd - BattleConst.obstacleBandStart) / 2;
      var middleSum = 0.0, middleN = 0;
      var edgeSum = 0.0, edgeN = 0;
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 60; seed++) {
          for (final o in world(map: map, seed: seed).obstacles) {
            // Measured against the kind's own base, so this compares
            // placement rather than which kinds happen to be tall.
            final base = BattleConst.obstacleSizes[o.kind.name]!.$2;
            final ratio = (BattleConst.waterY - o.rect.top) / base;
            if ((o.pos.dx - mid).abs() < halfSpan * 0.35) {
              middleSum += ratio;
              middleN++;
            } else if ((o.pos.dx - mid).abs() > halfSpan * 0.7) {
              edgeSum += ratio;
              edgeN++;
            }
          }
        }
      }
      expect(middleN, greaterThan(20));
      expect(edgeN, greaterThan(20));
      expect(middleSum / middleN, greaterThan(edgeSum / edgeN * 1.15),
          reason: 'mid-channel obstacles are no taller than the ones at the '
              'edges, so the height is not where it does any work');
    });
    test('the same seed builds the identical field', () {
      // Non-negotiable for hotspot play: both devices build the world from
      // one seed and exchange only shots. A field that differed between them
      // would have each player watching a different match.
      for (final map in GameMaps.all) {
        final a = world(map: map, seed: 123).obstacles;
        final b = world(map: map, seed: 123).obstacles;
        expect(a.length, b.length);
        for (int i = 0; i < a.length; i++) {
          expect(a[i].kind, b[i].kind);
          expect(a[i].pos, b[i].pos);
          expect(a[i].halfW, b[i].halfW);
        }
      }
    });

    test('different seeds build different fields', () {
      final fields = <String>{};
      for (int seed = 0; seed < 30; seed++) {
        fields.add(world(seed: seed)
            .obstacles
            .map((o) => '${o.kind.name}@${o.pos.dx.round()}')
            .join(','));
      }
      expect(fields.length, greaterThan(10),
          reason: 'the channel looks the same match after match');
    });
  });

  group('Shots and obstacles', () {
    test('a shot into an obstacle stops there instead of flying through', () {
      final w = world();
      final first = w.obstacles.first;
      final out = fireAt(w, Offset(first.pos.dx - 140, first.pos.dy));
      expect(out, isNotNull, reason: 'the shot never resolved');
      expect(first.struckT, greaterThan(0),
          reason: 'the shot passed straight through the obstacle');
    });

    test('a fast round cannot tunnel through a narrow obstacle', () {
      // A buoy is thirteen units to a side and a fast shot covers more than
      // that in one frame. Tested on the sweep directly, because the bug is
      // a frame the collision never sees.
      final r =
          Rect.fromCenter(center: const Offset(700, 260), width: 26, height: 62);
      final t = BattleWorld.segmentRectT(
          const Offset(600, 260), const Offset(800, 260), r);
      expect(t, isNotNull, reason: 'a fast shot tunnelled through a buoy');
      expect(t, closeTo((r.left - 600) / 200, 1e-6),
          reason: 'the hit is reported at the wrong point along the sweep');
    });

    test('a shot that misses the box reports no hit', () {
      final r = Rect.fromLTRB(100, 100, 200, 200);
      expect(
          BattleWorld.segmentRectT(
              const Offset(0, 0), const Offset(90, 90), r),
          isNull);
      expect(
          BattleWorld.segmentRectT(
              const Offset(0, 400), const Offset(400, 400), r),
          isNull);
    });


    test('a round ricochets off an obstacle instead of vanishing on it', () {
      // A rock is a rock. A ball that hits one and disappears reads as the
      // shot being deleted rather than deflected — and it makes the field
      // something to play around rather than something to play WITH: a
      // deliberate carom off a crate is a real shot.
      final w = world();
      final rock = Obstacle(
        kind: ObstacleKind.rock,
        pos: const Offset(700, 250),
        halfW: 42,
        halfH: 40,
        maxHits: 0,
        bobPhase: 0,
      );
      w.obstacles
        ..clear()
        ..add(rock);

      w.fire(
        from: Offset(rock.pos.dx - 200, rock.pos.dy),
        angleDeg: 0,
        power: 95,
        weapon: Weapons.starter,
        facing: 1,
        owner: 0,
      );
      // Approaching from the left, so the shot is travelling right.
      expect(w.shot!.vel.dx, greaterThan(0));

      ShotOutcome? out;
      var bounced = false;
      for (int f = 0; f < 600 && out == null; f++) {
        out = w.stepShot();
        final s = w.shot;
        if (s != null && s.bounces > 0) bounced = true;
      }
      expect(bounced, true,
          reason: 'the shot burst on the rock instead of bouncing off it');
      expect(rock.struckT, greaterThan(0));
    });

    test('a bounce sends the round back the way it came', () {
      // Reflected about the face it entered through. Getting this wrong at a
      // corner sends the ball onward through the obstacle, which looks like
      // the collision simply failed.
      final w = world();
      final rock = Obstacle(
        kind: ObstacleKind.rock,
        pos: const Offset(700, 250),
        halfW: 42,
        halfH: 40,
        maxHits: 0,
        bobPhase: 0,
      );
      w.obstacles
        ..clear()
        ..add(rock);

      w.fire(
        from: Offset(rock.pos.dx - 200, rock.pos.dy),
        angleDeg: 0,
        power: 95,
        weapon: Weapons.starter,
        facing: 1,
        owner: 0,
      );
      double? afterBounce;
      ShotOutcome? out;
      for (int f = 0; f < 600 && out == null; f++) {
        out = w.stepShot();
        final s = w.shot;
        if (s != null && s.bounces > 0 && afterBounce == null) {
          afterBounce = s.vel.dx;
        }
      }
      expect(afterBounce, isNotNull, reason: 'it never bounced');
      expect(afterBounce, lessThan(0),
          reason: 'the round carried on through the rock it hit');
    });

    test('a round that has spent its bounces bursts instead', () {
      // Otherwise a ball can rattle around the channel for ever.
      final w = world();
      final rock = Obstacle(
        kind: ObstacleKind.rock,
        pos: const Offset(700, 250),
        halfW: 42,
        halfH: 40,
        maxHits: 0,
        bobPhase: 0,
      );
      w.obstacles
        ..clear()
        ..add(rock);
      w.fire(
        from: Offset(rock.pos.dx - 200, rock.pos.dy),
        angleDeg: 0,
        power: 95,
        weapon: Weapons.starter,
        facing: 1,
        owner: 0,
      );
      w.shot!.bounces = 2;
      ShotOutcome? out;
      for (int f = 0; f < 600 && out == null; f++) {
        out = w.stepShot();
      }
      expect(out, isNotNull, reason: 'the shot never resolved');
      expect(rock.struckT, greaterThan(0));
    });

    test('a bouncing round still breaks a breakable obstacle', () {
      // Bouncing must not make the crate immortal — it takes the hit on the
      // way past.
      final w = world();
      final crate = Obstacle(
        kind: ObstacleKind.crate,
        pos: const Offset(700, 250),
        halfW: 28,
        halfH: 40,
        maxHits: 3,
        bobPhase: 0,
      );
      w.obstacles
        ..clear()
        ..add(crate);
      for (int shot = 0; shot < 3; shot++) {
        expect(crate.broken, false);
        w.fire(
          from: Offset(crate.pos.dx - 200, crate.pos.dy),
          angleDeg: 0,
          power: 95,
          weapon: Weapons.starter,
          facing: 1,
          owner: 0,
        );
        ShotOutcome? out;
        for (int f = 0; f < 600 && out == null; f++) {
          out = w.stepShot();
        }
      }
      expect(crate.broken, true, reason: 'three hits did not break a crate');
    });
    test('a breakable obstacle opens a hole after enough hits', () {
      // The escape hatch: rather than aim around an awkward obstacle you can
      // spend turns removing it.
      final w = world();
      final crate = Obstacle(
        kind: ObstacleKind.crate,
        pos: const Offset(700, 262),
        halfW: 28,
        halfH: 38,
        maxHits: 3,
        bobPhase: 0,
      );
      w.obstacles
        ..clear()
        ..add(crate);

      for (int shot = 0; shot < 3; shot++) {
        expect(crate.broken, false, reason: 'broke after only $shot hits');
        fireAt(w, Offset(crate.pos.dx - 140, crate.pos.dy));
      }
      expect(crate.broken, true, reason: 'three hits did not break a crate');

      // ...and once broken it stops blocking anything.
      w.fire(
        from: Offset(crate.pos.dx - 140, crate.pos.dy),
        angleDeg: 0,
        power: 90,
        weapon: Weapons.starter,
        facing: 1,
        owner: 0,
      );
      var gotPast = false;
      ShotOutcome? out;
      for (int i = 0; i < 600 && out == null; i++) {
        out = w.stepShot();
        final s = w.shot;
        if (s != null && s.pos.dx > crate.pos.dx + crate.halfW) gotPast = true;
      }
      expect(gotPast, true, reason: 'a broken crate still blocked the shot');
    });

    test('an immovable obstacle never breaks, however much you shoot it', () {
      final w = world();
      final rock = Obstacle(
        kind: ObstacleKind.rock,
        pos: const Offset(700, 272),
        halfW: 42,
        halfH: 22,
        maxHits: 0,
        bobPhase: 0,
      );
      w.obstacles
        ..clear()
        ..add(rock);
      for (int shot = 0; shot < 6; shot++) {
        fireAt(w, Offset(rock.pos.dx - 140, rock.pos.dy));
      }
      expect(rock.broken, false);
      expect(rock.destructible, false);
    });


    test('the field actually changes where you can aim', () {
      // The point of the whole feature. An obstacle that no realistic shot
      // ever meets is scenery, and scenery is what the horizon props already
      // are — so this sweeps the player's entire aiming space and counts how
      // much of it the field touches.
      //
      // Both bounds matter. Too little and the obstacles are decoration;
      // too much and a player cannot find a line at all.
      var total = 0;
      var blocked = 0;
      var landed = 0;
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 4; seed++) {
          final w = world(map: map, seed: seed);
          final from = w.rafts[0].crewPos(0);
          for (double angle = 10; angle <= 80; angle += 10) {
            for (double power = 40; power <= 100; power += 10) {
              for (final o in w.obstacles) {
                o.struckT = 0;
              }
              final out = fireAt(w, from, angle: angle, power: power);
              total++;
              if (w.obstacles.any((o) => o.struckT > 0)) {
                blocked++;
              } else if (out != null && out.damage > 0) {
                landed++;
              }
            }
          }
        }
      }
      final share = blocked / total;
      expect(share, greaterThan(0.05),
          reason: 'only ${(share * 100).toStringAsFixed(1)}% of shots meet an '
              'obstacle — the field is decoration');
      expect(share, lessThan(0.45),
          reason: '${(share * 100).toStringAsFixed(1)}% of the aiming space is '
              'blocked — there is barely a line left');
      expect(landed, greaterThan(20),
          reason: 'only $landed of $total aims still reach the enemy');
    });

    test('a flat shot is stopped far more often than a lobbed one', () {
      // The point of making the middle tall. Before, the field only caught
      // shots that were already going to miss: a flat drive straight across
      // the channel — the cheapest, most repeatable shot in the game — sailed
      // through. Now the flat line has to be given up and the arc raised.
      //
      // Measured as a ratio rather than an absolute, so retuning the heights
      // does not need this number retuned with it. What must stay true is
      // the SHAPE: low aims meet the field, high aims mostly clear it.
      int blockedAt(double angle) {
        var blocked = 0;
        for (final map in GameMaps.all) {
          for (int seed = 0; seed < 4; seed++) {
            final w = world(map: map, seed: seed);
            final from = w.rafts[0].crewPos(0);
            for (double power = 50; power <= 100; power += 10) {
              for (final o in w.obstacles) {
                o.struckT = 0;
              }
              fireAt(w, from, angle: angle, power: power);
              if (w.obstacles.any((o) => o.struckT > 0)) blocked++;
            }
          }
        }
        return blocked;
      }

      const tries = 6 * 4 * 6; // maps x seeds x power steps
      final flat = blockedAt(12);
      final lobbed = blockedAt(55);

      // The shape: low aims meet the field, high aims mostly clear it.
      expect(flat, greaterThan(lobbed * 2),
          reason: 'a flat shot is blocked $flat times and a lob $lobbed — the '
              'field does not push anybody to aim higher');
      // And the strength. A field low enough to shoot flat over only ever
      // caught shots that were going to miss anyway. At the old heights
      // roughly two thirds of flat aims met something; the point of raising
      // the middle is that a flat drive across the channel is now no longer
      // a shot at all.
      expect(flat, greaterThan(tries * 0.8),
          reason: 'only $flat of $tries flat shots meet anything — flat '
              'aiming still works, so nobody has to raise their arc');
    });
    test('a high enough arc still clears everything', () {
      // The other half of fairness: obstacles complicate the line, they do
      // not remove it. A steep lob from the player raft has to get across on
      // every scene and every field.
      for (final map in GameMaps.all) {
        for (int seed = 0; seed < 8; seed++) {
          final w = world(map: map, seed: seed);
          final tallest = w.obstacles.map((o) => o.rect.top).reduce(min);
          w.fire(
            // From the crew member who would actually be firing. A fixed
            // height is wrong now the sea is terraced: on a raised player
            // terrace that point is under water.
            from: w.rafts[0].crewPos(0),
            angleDeg: 72,
            power: 100,
            weapon: Weapons.starter,
            facing: 1,
            owner: 0,
          );
          var peak = double.infinity;
          var crossedAll = false;
          ShotOutcome? out;
          for (int i = 0; i < 900 && out == null; i++) {
            out = w.stepShot();
            final s = w.shot;
            if (s == null) break;
            peak = min(peak, s.pos.dy);
            if (s.pos.dx > BattleConst.obstacleBandEnd) crossedAll = true;
          }
          expect(crossedAll, true,
              reason: '${map.id} seed $seed: a steep lob could not get past '
                  'the obstacle field (peaked at $peak, tallest top '
                  '$tallest)');
        }
      }
    });
  });
}
