import 'ai.dart';
import 'battle.dart';
import 'characters.dart';
import 'controller.dart';
import 'maps.dart';
import 'models.dart';
import 'raft.dart';
import 'save.dart';

/// ---------------------------------------------------------------------------
/// First-run tutorial: a scripted 3-shot lesson on the ocean map against a
/// practice target that never shoots back.
///
/// Three beats, in order:
///   1. `shoot` — pull back and release to fire. Anything counts.
///   2. `power` — power is range: fire a shot over [powerThreshold].
///   3. `sink` — lob over the mid-channel rock and sink the target raft.
///
/// Built entirely on the ordinary match machinery: the tutorial *is* a
/// vs-AI match ([Tutorial.match] returns the same pair campaign levels do),
/// with a passive dummy for an opponent and a fixed seed so the layout, the
/// solved hint and the flight are identical every run. Nothing about the
/// turn flow is special-cased beyond the dummy holding its turn.
///
/// A lucky early hit can end the match before all three steps are done —
/// sinking the target on shot one still teaches the lesson, so a player
/// victory completes the tutorial whatever step is showing.
/// ---------------------------------------------------------------------------

class TutorialConfig {
  TutorialConfig._();

  /// Fixed seed: the same obstacles, the same hint, the same flight, every
  /// run — and the test suite can pin the solved shot to a real hit.
  static const int seed = 7;

  /// Step 2 wants a genuinely committed pull: comfortably past lobbing
  /// distance, short of a full-power heave.
  static const double powerThreshold = 70;

  /// Exactly one starter tennis ball: the lesson is one clean hit.
  static const double dummyHp = 20;

  /// Doubloons for finishing the tutorial the first time.
  static const int reward = 10;

  /// Stock launch physics, whatever the account owns: the solved hint is
  /// computed at 1.0 and the match fires at 1.0, so the two can never
  /// disagree about where a shot goes.
  static const double powerMultiplier = 1.0;
}

enum TutorialStep { shoot, power, sink }

/// Where a player is in the script, advanced by observing the match.
///
/// At most one step is consumed per fired shot: a first pull that happens
/// to clear the power bar still only finishes step 1 — step 2 wants its own
/// deliberate heave.
class TutorialProgress {
  TutorialStep step = TutorialStep.shoot;

  /// Shots the overlay has already accounted for. The screen feeds every
  /// fired shot through [noteShotFired] in order.
  int shotsSeen = 0;

  bool completed = false;

  bool noteShotFired(double power) {
    if (completed) return false;
    if (step == TutorialStep.shoot) {
      step = TutorialStep.power;
      return true;
    }
    if (step == TutorialStep.power && power >= TutorialConfig.powerThreshold) {
      step = TutorialStep.sink;
      return true;
    }
    return false;
  }

  /// The practice raft went down with the lesson's final step showing: done.
  bool noteTargetSunk() {
    if (completed || step != TutorialStep.sink) return false;
    completed = true;
    return true;
  }

  /// A player victory ends the lesson whatever step is showing — sinking the
  /// target early is skipping ahead by being good, not failing the script.
  bool noteVictory() {
    if (completed) return false;
    completed = true;
    return true;
  }
}

/// The solved shot for the final step: what the AI planner (no jitter, stock
/// physics) fires from the player's own muzzle at the target's crew.
///
/// Solved live from the running match rather than baked in, so it stays
/// right whatever hull the player's campaign raft is. The fixed tutorial
/// seed makes it the same numbers every run regardless.
({double angle, double power}) solveTutorialShot(GameController ctrl) {
  final me = ctrl.world.raftOf(0)!;
  final foe = ctrl.world.raftOf(1)!;
  final ai = AiController(AiDifficulty.normal, seed: TutorialConfig.seed);
  final shot = ai.plan(
    from: me.muzzle(aimAngleDeg: 45, weapon: Weapons.starter),
    targetPos: foe.crewPos(0),
    facing: me.facing,
    arsenal: [Weapons.starter],
    muzzleAt: (a) => me.muzzle(aimAngleDeg: a, weapon: Weapons.starter),
    baseJitter: 0,
    powerMultiplier: TutorialConfig.powerMultiplier,
    // The lesson's first turn has fixed air (fixed seed), and the solver
    // compensates for it exactly like the real flight does.
    wind: ctrl.world.wind,
  );
  return (angle: shot.angle, power: shot.power);
}

class Tutorial {
  Tutorial._();

  /// The tutorial as a launchable match — the same shape as
  /// [Campaign.matchFor], shared by the menu button and the replay button so
  /// they can never drift apart.
  static (MatchSettings, List<PlayerConfig>) match() {
    final save = SaveService.instance.data;
    final settings = MatchSettings(
      map: GameMaps.byId('ocean'),
      startHp: 100,
      turnSeconds: 30,
      enabledWeapons: const ['tennis'],
      startHpPerPlayer: const [100, TutorialConfig.dummyHp],
      tutorial: true,
    );
    final players = [
      PlayerConfig(
        name: 'YOU',
        loadout: save.raftLoadout,
        look: Cast.byId(save.character).look,
        powerMultiplier: TutorialConfig.powerMultiplier,
      ),
      PlayerConfig(
        name: 'TARGET',
        loadout: RaftLoadout.custom(
          hullId: 'tube',
          sizeId: 'small',
          colorIndex: 1,
          hpBonus: 0,
        ),
        look: CrewLook.player,
        isAi: true,
        aiDifficulty: AiDifficulty.easy,
        aimJitter: 0,
        passive: true,
      ),
    ];
    return (settings, players);
  }

  /// Marks the lesson done, paying the first-completion reward. Returns the
  /// doubloons awarded (0 on a replay).
  static Future<int> complete() async {
    final save = SaveService.instance.data;
    if (save.tutorialDone) return 0;
    save.tutorialDone = true;
    save.doubloons += TutorialConfig.reward;
    await SaveService.instance.save();
    return TutorialConfig.reward;
  }
}
