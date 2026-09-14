import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/save.dart';

/// What the AI shoots at, and with what.
///
/// "The AI is bad at aiming, even on high difficulty" turned out not to be
/// about aim at all. Measured against a stationary crew member the solver
/// already lands within a unit of its target at every range, on every hull,
/// with obstacles and terraces in — hard and expert hit 100% of the time.
///
/// What it did badly was CHOOSE. It picked a crew member with `nextInt` over
/// the living ones and reached for a heavy round on a fixed coin flip, so a
/// hard opponent spread its fire evenly across a full-health deck and never
/// finished anybody. Spreading damage is the least effective thing a shooter
/// can do: nobody is removed, so nobody stops shooting back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  /// A fixed roll, so a test asserts the SCORING rather than the dice.
  double Function() fixed(double v) => () => v;

  AiTarget t(
    int i, {
    required double hp,
    double hpFrac = 1,
    int neighbours = 0,
    double railGap = 999,
  }) =>
      AiTarget(
        index: i,
        hp: hp,
        hpFrac: hpFrac,
        splashNeighbours: neighbours,
        railGap: railGap,
      );

  group('Choosing a target', () {
    test('a shot that can finish somebody takes it', () {
      // The whole point. A crew member removed stops shooting back, and a
      // raft is beaten when its crew are gone — so a killing blow is worth
      // more than any amount of damage spread across healthy people.
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final pick = ai.chooseTarget(
        [
          t(0, hp: 100, hpFrac: 1.0),
          t(1, hp: 8, hpFrac: 0.08), // one hit from gone
          t(2, hp: 90, hpFrac: 0.9),
        ],
        weaponDamage: 25,
        splashRadius: 0,
        roll: fixed(0),
      );
      expect(pick, 1, reason: 'it walked past somebody it could finish');
    });

    test('otherwise it works on whoever is nearest to being finished', () {
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final pick = ai.chooseTarget(
        [
          t(0, hp: 100, hpFrac: 1.0),
          t(1, hp: 40, hpFrac: 0.4),
          t(2, hp: 80, hpFrac: 0.8),
        ],
        weaponDamage: 20, // finishes nobody
        splashRadius: 0,
        roll: fixed(0),
      );
      expect(pick, 1);
    });

    test('a splash round prefers a crew member with company', () {
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final pick = ai.chooseTarget(
        [
          t(0, hp: 100, hpFrac: 1.0, neighbours: 0),
          t(1, hp: 100, hpFrac: 1.0, neighbours: 2),
        ],
        weaponDamage: 20,
        splashRadius: 60,
        roll: fixed(0),
      );
      expect(pick, 1, reason: 'it ignored two crew standing together');
    });

    test('but a kill still beats a splash on two healthy targets', () {
      // Two wounded crew is not better than one gone.
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final pick = ai.chooseTarget(
        [
          t(0, hp: 6, hpFrac: 0.06, neighbours: 0),
          t(1, hp: 100, hpFrac: 1.0, neighbours: 2),
        ],
        weaponDamage: 25,
        splashRadius: 60,
        roll: fixed(0),
      );
      expect(pick, 0);
    });

    test('somebody on the rail is worth more than their health says', () {
      // A body knocked off the deck drowns, which removes them whatever
      // their HP — so the edge of the deck is a real target in itself.
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final pick = ai.chooseTarget(
        [
          t(0, hp: 100, hpFrac: 1.0, railGap: 400),
          t(1, hp: 100, hpFrac: 1.0, railGap: 4),
        ],
        weaponDamage: 20,
        splashRadius: 0,
        roll: fixed(0),
      );
      expect(pick, 1);
    });

    test('easy still picks at random', () {
      // The bottom of a difficulty ladder has to play badly, and "shoots
      // whoever" is the most readable way to do that — far better than an
      // opponent that aims well and then misses on purpose.
      final ai = AiController(AiDifficulty.easy, seed: 1);
      final options = [
        t(0, hp: 100, hpFrac: 1.0),
        t(1, hp: 2, hpFrac: 0.02),
        t(2, hp: 100, hpFrac: 1.0),
      ];
      final picks = <int>{};
      for (final r in [0.0, 0.4, 0.9]) {
        picks.add(ai.chooseTarget(options,
            weaponDamage: 50, splashRadius: 0, roll: fixed(r)));
      }
      expect(picks.length, greaterThan(1),
          reason: 'easy always made the same choice, so it is not random');
      expect(picks.contains(0) || picks.contains(2), true,
          reason: 'easy never picked a healthy target, so it is not random');
    });

    test('a harder opponent is less swayed by the dice', () {
      // Normal is meant to make the obvious choice most of the time and the
      // wrong one often enough to stay beatable; expert should be almost
      // impossible to talk out of the right answer.
      final options = [
        t(0, hp: 100, hpFrac: 1.0),
        t(1, hp: 55, hpFrac: 0.55),
      ];
      var normalWrong = 0;
      var expertWrong = 0;
      for (int i = 0; i < 100; i++) {
        final r = i / 100;
        // The noise is added per option, so a high roll favours whichever
        // option is scored last; sweeping it covers both ends.
        if (AiController(AiDifficulty.normal, seed: i).chooseTarget(options,
                weaponDamage: 20, splashRadius: 0, roll: fixed(r)) !=
            1) {
          normalWrong++;
        }
        if (AiController(AiDifficulty.expert, seed: i).chooseTarget(options,
                weaponDamage: 20, splashRadius: 0, roll: fixed(r)) !=
            1) {
          expertWrong++;
        }
      }
      expect(expertWrong, lessThanOrEqualTo(normalWrong),
          reason: 'expert is talked out of the right target more often than '
              'normal is');
    });

    test('an empty or single list is handled', () {
      final ai = AiController(AiDifficulty.expert, seed: 1);
      expect(ai.chooseTarget([],
          weaponDamage: 10, splashRadius: 0, roll: fixed(0)), 0);
      expect(
          ai.chooseTarget([t(3, hp: 10)],
              weaponDamage: 10, splashRadius: 0, roll: fixed(0)),
          3);
    });
  });

  group('Choosing a weapon', () {
    test('it reaches for something that will finish the job', () {
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final arsenal = Weapons.all.toList();
      final wounded = t(0, hp: 12, hpFrac: 0.12);
      final picked = ai.chooseWeapon(arsenal, wounded, roll: fixed(0));
      expect(picked.damage, greaterThanOrEqualTo(wounded.hp),
          reason: 'it chose a round that cannot finish a nearly-dead target');
    });

    test('it does not spend the heaviest round it owns to do it', () {
      // Among the rounds that WILL finish them, the lightest is the right
      // one — the heavy one is worth keeping for somebody this cannot reach.
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final arsenal = Weapons.all.where((w) => w.damage >= 12).toList();
      if (arsenal.length < 2) return;
      final heaviest =
          arsenal.reduce((a, b) => a.damage >= b.damage ? a : b);
      final picked = ai.chooseWeapon(
        arsenal,
        t(0, hp: 11, hpFrac: 0.11),
        roll: fixed(0),
      );
      expect(picked.damage, lessThanOrEqualTo(heaviest.damage));
    });

    test('with nothing to finish, it brings the biggest hit it has', () {
      final ai = AiController(AiDifficulty.expert, seed: 1);
      final arsenal = Weapons.all.toList();
      final picked = ai.chooseWeapon(
        arsenal,
        t(0, hp: 10000, hpFrac: 1.0),
        roll: fixed(0),
      );
      final heaviest = arsenal.reduce((a, b) => a.damage >= b.damage ? a : b);
      expect(picked.damage, heaviest.damage);
    });

    test('easy keeps its old coin flip', () {
      final ai = AiController(AiDifficulty.easy, seed: 1);
      final arsenal = Weapons.all.toList();
      final picked = ai.chooseWeapon(
        arsenal,
        t(0, hp: 5, hpFrac: 0.05),
        roll: fixed(0),
      );
      expect(picked.id, arsenal.first.id,
          reason: 'easy should still lead with the starter');
    });

    test('no arsenal falls back to the starter', () {
      final ai = AiController(AiDifficulty.expert, seed: 1);
      expect(ai.chooseWeapon([], t(0, hp: 5), roll: fixed(0)).id,
          Weapons.starter.id);
    });
  });
}
