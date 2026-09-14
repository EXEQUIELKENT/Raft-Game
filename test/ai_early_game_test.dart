import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// Whether the AI shoots as well at the start of a match as at the end.
///
/// It did not, and the shape of the fault is why it went unnoticed for so
/// long: the solver is exact, so every test that planned a shot and flew it
/// in isolation passed. The error only appeared once a shot was fired
/// through the real turn sequence, and only while more than one crew member
/// was alive — which reads, from the outside, as an opponent who cannot aim
/// early and suddenly can late.
///
/// The cause was that the planner and the fire path asked [Raft.muzzle] for
/// two different origins. Firing names the round being fired; planning did
/// not, and `muzzle` preferred whatever was already in the crew's hands — so
/// the plan was solved from the reach of LAST turn's weapon and the ball
/// left from this one's. A lone survivor has fired every turn, so their
/// equipped round already matched and the two agreed; rotating crew means a
/// shooter still holding the previous round, or nothing at all.
///
/// The measure here is therefore the plan's own ballistic answer — where the
/// launched trajectory crosses the target's plane, with no collision in the
/// way — because that isolates aim from everything downstream of it. A shot
/// that stops early on a crewmate's body is a targeting question, not an
/// aiming one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  /// Where a free trajectory from [p0] with per-frame velocity [v0] crosses
  /// `y == planeY` coming down. The same integrator the simulation uses,
  /// minus every obstacle — see the note above on why.
  double crossing(Offset p0, Offset v0, double planeY) {
    var p = p0, v = v0;
    for (int i = 0; i < 900; i++) {
      final next = p + v;
      if (next.dy > planeY && v.dy > 0) {
        final span = next.dy - p.dy;
        final t =
            span.abs() < 1e-9 ? 0.0 : ((planeY - p.dy) / span).clamp(0.0, 1.0);
        return p.dx + (next.dx - p.dx) * t;
      }
      p = next;
      v = Offset(v.dx, v.dy + BattleConst.gravity);
    }
    return p.dx;
  }

  /// Plays out matches and records every AI shot's aiming error, bucketed by
  /// how many of the player's crew were still standing when it was fired.
  ///
  /// A full crew is "early" and a lone survivor is "late", which is the
  /// comparison the whole file exists to make.
  Map<int, List<double>> errorsByCrewAlive(AiDifficulty difficulty,
      {int seeds = 6}) {
    final out = <int, List<double>>{};
    for (final map in GameMaps.all) {
      for (int seed = 0; seed < seeds; seed++) {
        final ctrl = GameController(
          settings: MatchSettings(map: map, startHp: 100),
          players: [
            PlayerConfig(
                name: 'P1',
                loadout: RaftLoadout.custom(
                    hullId: 'log', sizeId: 'large', colorIndex: 0)),
            PlayerConfig(
              name: 'P2',
              loadout: RaftLoadout.custom(
                  hullId: 'log', sizeId: 'large', colorIndex: 1),
              isAi: true,
              aiDifficulty: difficulty,
            ),
          ],
          mode: GameMode.vsAi,
          seed: seed,
        );
        if (ctrl.inIntro) ctrl.skipIntro();
        final foe = ctrl.world.raftOf(0)!;
        var guard = 0;
        while (ctrl.winner == null && guard++ < 20000) {
          final aiSeat = ctrl.players[ctrl.currentPlayer].isAi;
          if (!aiSeat && ctrl.canHumanAct) {
            // The human's shots only need to keep the match moving.
            ctrl.aimAngle = 45;
            ctrl.aimPower = 60;
            ctrl.humanFire();
          }
          final before = ctrl.world.shot;
          ctrl.stepForTest(1 / 60);
          final s = ctrl.world.shot;
          if (!aiSeat || before != null || s == null) continue;

          final aim = ctrl.lastAiAim!;
          final alive = foe.crew.where((c) => c.alive).length;
          // The shot has already taken its first step, so wind it back to
          // the launch state to read the plan's own answer.
          final v0 = Offset(s.vel.dx, s.vel.dy - BattleConst.gravity);
          final signed = (crossing(s.pos - v0, v0, aim.dy) - aim.dx) *
              ctrl.world.raftOf(1)!.facing;
          out.putIfAbsent(alive, () => []).add(signed);

          var g2 = 0;
          while (ctrl.world.shot != null && g2++ < 2000) {
            ctrl.stepForTest(1 / 60);
          }
        }
        ctrl.dispose();
      }
    }
    return out;
  }

  double median(List<double> v) {
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }

  group('The AI aims as well on turn one as on the last turn', () {
    test('a full crew is no harder to hit than a lone survivor', () {
      // The headline symptom, stated as the comparison a player makes: the
      // opponent who cannot hit anything early and suddenly snipes late.
      for (final difficulty in [AiDifficulty.hard, AiDifficulty.expert]) {
        final byAlive = errorsByCrewAlive(difficulty);
        expect(byAlive.keys.length, greaterThan(1),
            reason: 'the matches never reached a second stage, so this '
                'compares nothing');

        final scores = {
          for (final e in byAlive.entries)
            e.key: median(e.value.map((v) => v.abs()).toList())
        };
        final worst = scores.values.reduce(max);
        final best = scores.values.reduce(min);
        expect(worst - best, lessThan(8),
            reason: '${difficulty.name} aims differently depending on how far '
                'into the match it is: $scores — a full crew should be no '
                'harder to aim at than a lone survivor');
      }
    });

    test('the precise difficulties have no systematic overshoot', () {
      // The fault was a BIAS, not noise, which is why turning the difficulty
      // up never helped: difficulty only scales the jitter either side of
      // the plan, and the plan itself was long. So the place it shows most
      // plainly is the top of the ladder, where the jitter is nearly zero
      // and a ~28 unit median overshoot could only have come from the plan.
      //
      // Easy and normal are excluded on purpose rather than for being
      // awkward. [AiController.plan] softens a short roll to 60% of a long
      // one — a round that plops into the water well short reads as a
      // blunder where the same error long reads as a near miss — so those
      // two carry a deliberate long skew IN PROPORTION to their jitter,
      // around +17 units at normal. Asserting it away would be asserting
      // against the design. What distinguishes the bug is that its bias was
      // the same size at every difficulty, including the ones with no
      // jitter left to skew.
      for (final difficulty in [AiDifficulty.hard, AiDifficulty.expert]) {
        final byAlive = errorsByCrewAlive(difficulty, seeds: 4);
        for (final e in byAlive.entries) {
          final bias = median(e.value);
          expect(bias.abs(), lessThan(8),
              reason: '${difficulty.name} with ${e.key} crew alive lands a '
                  'median ${bias.round()} units ${bias > 0 ? "long" : "short"} '
                  '— at this difficulty the jitter is too small to explain a '
                  'bias, so it is coming from the plan');
        }
      }
    });

    test('an expert is genuinely precise, and an easy one is not', () {
      // The difficulty ladder has to survive the fix: a flat error is only
      // an improvement if it is also a SMALL one at the top.
      final expert = errorsByCrewAlive(AiDifficulty.expert, seeds: 4)
          .values
          .expand((v) => v)
          .map((v) => v.abs())
          .toList();
      final easy = errorsByCrewAlive(AiDifficulty.easy, seeds: 4)
          .values
          .expand((v) => v)
          .map((v) => v.abs())
          .toList();
      expect(median(expert), lessThan(10),
          reason: 'an expert should put the round on the target');
      expect(median(easy), greaterThan(median(expert) * 2),
          reason: 'easy and expert shoot alike, so difficulty does nothing');
    });
  });

  group('The planned muzzle is the muzzle it fires from', () {
    test('naming a weapon overrides what the crew happens to be holding', () {
      // The mechanism, tested directly: the planner asks where the round it
      // is about to fire will leave from, and must not be answered with
      // where the last round would have left from.
      final w = BattleWorld(map: GameMaps.all.first, seed: 3);
      final raft = Raft(
        playerIndex: 0,
        x: BattleConst.playerX,
        loadout:
            RaftLoadout.custom(hullId: 'log', sizeId: 'large', colorIndex: 0),
        look: CrewLook.player,
        label: 'ME',
        facing: 1,
        crew: [for (int k = 0; k < 3; k++) Crew(hp: 100, maxHp: 100)],
      );
      w.addRaft(raft);

      final anchor = Weapons.byId('anchor');
      raft.crew[raft.activeIndex].equipInstant('tennis');
      final planned = raft.muzzle(aimAngleDeg: 52, weapon: anchor);
      raft.crew[raft.activeIndex].equipInstant('anchor');
      final fired = raft.muzzle(aimAngleDeg: 52, weapon: anchor);

      expect((planned - fired).distance, lessThan(0.01),
          reason: 'the plan was built from the reach of the tennis ball and '
              'the anchor was fired from somewhere else');
    });

    test('an unarmed crew member still plans from the right muzzle', () {
      // The opening turn of a match, where nobody has equipped anything yet
      // — the case that made the AI worst on its very first shots.
      final w = BattleWorld(map: GameMaps.all.first, seed: 4);
      final raft = Raft(
        playerIndex: 0,
        x: BattleConst.playerX,
        loadout:
            RaftLoadout.custom(hullId: 'log', sizeId: 'large', colorIndex: 0),
        look: CrewLook.player,
        label: 'ME',
        facing: 1,
        crew: [for (int k = 0; k < 3; k++) Crew(hp: 100, maxHp: 100)],
      );
      w.addRaft(raft);

      final grenade = Weapons.byId('grenade');
      final planned = raft.muzzle(aimAngleDeg: 45, weapon: grenade);
      raft.crew[raft.activeIndex].equipInstant('grenade');
      expect((planned - raft.muzzle(aimAngleDeg: 45, weapon: grenade)).distance,
          lessThan(0.01));
    });
  });
}
