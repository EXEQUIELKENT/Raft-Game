import 'package:flutter_test/flutter_test.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/game/tutorial.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The first-run lesson: a scripted 3-shot match (shoot, power, sink) on the
/// ocean map against a practice target that never shoots back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
    SharedPreferences.setMockInitialValues({});
  });

  GameController newTutorial() {
    final (settings, players) = Tutorial.match();
    return GameController(
      settings: settings,
      players: players,
      mode: GameMode.vsAi,
      seed: TutorialConfig.seed,
    );
  }

  group('Tutorial.match', () {
    test('Builds a tennis-only lesson on the ocean map against one weak dummy', () {
      final (settings, players) = Tutorial.match();

      expect(settings.tutorial, true);
      expect(settings.map.id, 'ocean');
      expect(settings.enabledWeapons, ['tennis']);
      expect(settings.startHpFor(1), TutorialConfig.dummyHp);

      expect(players.length, 2);
      expect(players[0].isAi, false);
      expect(players[0].powerMultiplier, TutorialConfig.powerMultiplier);
      final dummy = players[1];
      expect(dummy.isAi, true);
      expect(dummy.passive, true, reason: 'the practice target never shoots back');
      expect(dummy.loadout.crewCount, 1);
    });

    test('One starter tennis ball is exactly lethal to the dummy', () {
      expect(Weapons.starter.damage, TutorialConfig.dummyHp,
          reason: 'step 3 ends in one clean hit');
    });
  });

  group('TutorialProgress', () {
    test('Advances shoot, then power, then sink — one step per shot', () {
      final p = TutorialProgress();
      expect(p.step, TutorialStep.shoot);

      // A monster first pull still only finishes step 1: step 2 wants its
      // own deliberate heave.
      expect(p.noteShotFired(100), true);
      expect(p.step, TutorialStep.power);

      expect(p.noteShotFired(40), false);
      expect(p.step, TutorialStep.power);

      expect(p.noteShotFired(TutorialConfig.powerThreshold), true);
      expect(p.step, TutorialStep.sink);
    });

    test('Sinking the target finishes the lesson; victory finishes it early', () {
      final sunk = TutorialProgress()
        ..step = TutorialStep.sink;
      expect(sunk.noteTargetSunk(), true);
      expect(sunk.completed, true);
      expect(sunk.noteShotFired(90), false, reason: 'a done lesson ignores everything');

      final lucky = TutorialProgress();
      expect(lucky.noteVictory(), true,
          reason: 'sinking the target on shot one still counts');
      expect(lucky.completed, true);
    });
  });

  group('Solved hint', () {
    test('The solved shot sinks the dummy in one hit', () {
      final ctrl = newTutorial();
      final hint = solveTutorialShot(ctrl);
      final me = ctrl.world.raftOf(0)!;
      final foe = ctrl.world.raftOf(1)!;

      ctrl.world.fire(
        from: me.muzzle(aimAngleDeg: hint.angle, weapon: Weapons.starter),
        angleDeg: hint.angle,
        power: hint.power,
        facing: me.facing,
        weapon: Weapons.starter,
        owner: 0,
        powerMultiplier: TutorialConfig.powerMultiplier,
      );
      ShotOutcome? outcome;
      for (int i = 0; i < 400 && outcome == null; i++) {
        outcome = ctrl.world.stepShot();
      }

      expect(outcome, isNotNull, reason: 'the hinted shot resolves');
      expect(outcome!.hitSomething, true,
          reason: 'the hint clears the mid-channel rock and lands on the target');
      expect(foe.alive, false, reason: 'one clean hit sinks the 20 HP dummy');
      ctrl.dispose();
    });
  });

  group('Passive dummy', () {
    test('The dummy holds its turn and hands it over without ever firing', () {
      final ctrl = newTutorial();
      expect(ctrl.currentPlayer, 0);

      ctrl.beginTurnForTest(1);
      // Think time runs 0.9–1.8s plus the turn transition back: 5 simulated
      // seconds covers it with room to spare.
      for (int i = 0; i < 300; i++) ctrl.stepForTest(1 / 60);

      expect(ctrl.world.shot, isNull, reason: 'the practice target never fires');
      expect(ctrl.currentPlayer, 0, reason: 'the turn comes back to the player');
      ctrl.dispose();
    });
  });

  group('Full lesson', () {
    test('Firing the hinted shot wins the lesson and records nothing', () {
      final ctrl = newTutorial();
      final hint = solveTutorialShot(ctrl);

      ctrl.stepForTest(1 / 60);
      ctrl.aimAngle = hint.angle;
      ctrl.aimPower = hint.power;
      ctrl.humanFire();
      expect(ctrl.phase, GamePhase.firing);

      var frames = 0;
      while (ctrl.phase != GamePhase.gameOver && frames < 1200) {
        ctrl.stepForTest(1 / 60);
        frames++;
      }

      expect(ctrl.phase, GamePhase.gameOver, reason: 'the dummy went down');
      expect(ctrl.winner, 0);
      expect(SaveService.instance.data.wins, 0,
          reason: 'a lesson is not a played match: no wins recorded');
      expect(ctrl.shotsFired, 1);
      ctrl.dispose();
    });

    test('Completing pays the reward once and persists the flag', () async {
      expect(await Tutorial.complete(), TutorialConfig.reward);
      expect(SaveService.instance.data.tutorialDone, true);
      expect(SaveService.instance.data.doubloons, TutorialConfig.reward);

      expect(await Tutorial.complete(), 0,
          reason: 'replays pay nothing');
      expect(SaveService.instance.data.doubloons, TutorialConfig.reward);

      final raw = SaveService.instance.data.toJson();
      final back = SaveData()..fromJson(raw);
      expect(back.tutorialDone, true, reason: 'the flag survives a save round-trip');
    });
  });
}
