import 'ai.dart';
import 'characters.dart';
import 'models.dart';

/// ---------------------------------------------------------------------------
/// World bosses.
///
/// Before this, "boss" was a boolean on the last level of each world and it
/// meant the enemy had more HP. Six worlds ended the same way with a bigger
/// number.
///
/// A boss here is a named opponent with three things nobody else has:
///
///  1. **A signature round** from [Weapons.boss] that does something to you
///     rather than merely to your HP — chills, tars, dazes or snares. That is
///     what makes each boss fight play differently instead of just lasting
///     longer.
///  2. **A trigger** for when the signature round comes out. Every boss holds
///     it back and telegraphs it, so a player can learn the fight.
///  3. **A shape**: which characters crew it, how many, and how good they are.
///
/// The balance rule that holds the whole thing together is in
/// [Weapons.boss]: a status round always hits for *less* than an ordinary
/// round of its weight. A boss buys disruption with damage. Combined with
/// every status lasting exactly one turn and [signatureCooldown] keeping the
/// special shot rationed, the worst a boss can do is take one turn's worth of
/// advantage away — never chain them, and never burst a healthy crew down.
/// ---------------------------------------------------------------------------

/// When a boss reaches for its signature round.
enum BossTrigger {
  /// Every Nth shot it takes. Predictable, so the player can count.
  everyNthShot,

  /// Once its own HP drops below a fraction — a second-wind moment.
  whenWounded,

  /// When the player is at high HP: it opens with disruption and stops
  /// bothering once you are already hurting. Deliberately the *kindest*
  /// pattern, used by the earliest boss.
  whenPlayerHealthy,
}

class BossDef {
  final String id;
  final String name;

  /// The title card line under the name.
  final String epithet;

  /// Which character stands at the boss's own station.
  final CrewLook look;

  /// The crew flanking them, in deck order.
  final List<CrewLook> escort;

  /// Signature round, from [Weapons.boss].
  final String signatureWeaponId;

  final BossTrigger trigger;

  /// For [BossTrigger.everyNthShot], the N. For [BossTrigger.whenWounded],
  /// unused. Kept as one field so the table stays readable.
  final int everyN;

  /// For [BossTrigger.whenWounded] / [whenPlayerHealthy], the HP fraction
  /// the check compares against.
  final double hpThreshold;

  /// Minimum turns between two signature shots, whatever the trigger says.
  /// This is the rationing that stops a wounded boss firing its special
  /// every single turn for the rest of the fight.
  final int signatureCooldown;

  /// Extra HP on top of the level's enemy HP, for the boss's own body only.
  final double bonusHp;

  final AiDifficulty difficulty;

  /// Lines the boss says in its speech bubble: on entry, on landing its
  /// signature, and when badly hurt.
  final String openingLine;
  final String signatureLine;
  final String woundedLine;

  const BossDef({
    required this.id,
    required this.name,
    required this.epithet,
    required this.look,
    required this.escort,
    required this.signatureWeaponId,
    required this.trigger,
    required this.difficulty,
    required this.openingLine,
    required this.signatureLine,
    required this.woundedLine,
    this.everyN = 3,
    this.hpThreshold = 0.5,
    this.signatureCooldown = 2,
    this.bonusHp = 30,
  });

  WeaponDef get signature => Weapons.byId(signatureWeaponId);

  /// Whether the signature comes out this turn.
  ///
  /// [shotsTaken] is how many shots this boss has fired, [selfHp] and
  /// [playerHp] are 0..1 fractions, and [turnsSinceSignature] enforces the
  /// cooldown. Pure so the balance tests can drive it directly.
  bool wantsSignature({
    required int shotsTaken,
    required double selfHp,
    required double playerHp,
    required int turnsSinceSignature,
  }) {
    if (turnsSinceSignature < signatureCooldown) return false;
    // The very first shot is never the special one, whatever the trigger
    // says: the player gets one ordinary exchange to see what a normal round
    // from this boss looks like before anything is taken away from them.
    // This applies to ALL triggers — a wounded boss that spawned already
    // hurt, or a healthy-player trigger that is satisfied from the opening
    // bell, would otherwise disrupt before the player had seen anything.
    if (shotsTaken <= 0) return false;
    return switch (trigger) {
      BossTrigger.everyNthShot => shotsTaken % everyN == 0,
      BossTrigger.whenWounded => selfHp <= hpThreshold,
      BossTrigger.whenPlayerHealthy => playerHp >= hpThreshold,
    };
  }
}

class Bosses {
  Bosses._();

  /// One per campaign world, keyed by world id. Ordered gentlest to nastiest,
  /// and the trigger patterns escalate with them: the first boss only
  /// disrupts you while you are healthy, the last one does it on a clock.
  static const Map<String, BossDef> byWorld = {
    'ocean': BossDef(
      id: 'squall',
      name: 'Squall Sadie',
      epithet: 'Queen of the Shallow Water',
      look: CrewLook.captain,
      escort: [CrewLook.ducker, CrewLook.raider],
      signatureWeaponId: 'netshot',
      // The gentlest pattern in the game: she only tangles you while you are
      // still on full health, and leaves you alone once you are hurting.
      trigger: BossTrigger.whenPlayerHealthy,
      hpThreshold: 0.75,
      signatureCooldown: 3,
      bonusHp: 20,
      difficulty: AiDifficulty.hard,
      openingLine: 'Nice raft. Mine now.',
      signatureLine: 'Sit still!',
      woundedLine: 'Lucky shot...',
    ),
    'island': BossDef(
      id: 'palma',
      name: 'Queen Palma',
      epithet: 'Ruler of the Reef',
      look: CrewLook.captain,
      escort: [CrewLook.pirate, CrewLook.ducker, CrewLook.raider],
      signatureWeaponId: 'sandburst',
      trigger: BossTrigger.everyNthShot,
      everyN: 4,
      signatureCooldown: 3,
      bonusHp: 25,
      difficulty: AiDifficulty.hard,
      openingLine: 'Off my reef.',
      signatureLine: 'Eyes shut, sailor!',
      woundedLine: 'You are ruining the beach.',
    ),
    'mountains': BossDef(
      id: 'glacier',
      name: 'The Glacier King',
      epithet: 'He Who Waits Out The Thaw',
      look: CrewLook.furlined,
      escort: [CrewLook.icebreaker, CrewLook.furlined],
      signatureWeaponId: 'frost',
      trigger: BossTrigger.everyNthShot,
      everyN: 3,
      signatureCooldown: 2,
      bonusHp: 35,
      difficulty: AiDifficulty.hard,
      openingLine: 'You will freeze before I tire.',
      signatureLine: 'Hold still. Get cold.',
      woundedLine: 'The ice remembers this.',
    ),
    'desert': BossDef(
      id: 'duke',
      name: 'Dune Baron Duke',
      epithet: 'Owner of Water He Has Never Seen',
      look: CrewLook.nomad,
      escort: [CrewLook.duneRunner, CrewLook.duneRunner, CrewLook.pirate],
      signatureWeaponId: 'sandburst',
      trigger: BossTrigger.whenWounded,
      hpThreshold: 0.6,
      signatureCooldown: 2,
      bonusHp: 40,
      difficulty: AiDifficulty.hard,
      openingLine: 'This water is leased. From me.',
      signatureLine: 'Taste the dunes!',
      woundedLine: 'Sand in my gears!',
    ),
    'volcano': BossDef(
      id: 'vixen',
      name: 'The Volcano Vixen',
      epithet: 'Keeper of the Burning Straits',
      look: CrewLook.stoker,
      escort: [CrewLook.ashwalker, CrewLook.stoker, CrewLook.gunner],
      signatureWeaponId: 'tarpot',
      trigger: BossTrigger.everyNthShot,
      everyN: 3,
      signatureCooldown: 2,
      bonusHp: 45,
      difficulty: AiDifficulty.hard,
      openingLine: 'Everything here burns eventually.',
      signatureLine: 'Stick around!',
      woundedLine: 'You will not outlast the mountain.',
    ),
    'city': BossDef(
      id: 'chaos',
      name: 'Captain Chaos',
      epithet: 'Last Captain Standing',
      look: CrewLook.neonRunner,
      escort: [CrewLook.dockhand, CrewLook.gunner, CrewLook.captain],
      signatureWeaponId: 'tarpot',
      trigger: BossTrigger.everyNthShot,
      everyN: 2,
      // The tightest rotation in the game, and still gated: at N=2 with a
      // cooldown of 2, the special lands at most every other turn, which
      // leaves every alternate turn completely clean.
      signatureCooldown: 2,
      hpThreshold: 0.5,
      bonusHp: 60,
      difficulty: AiDifficulty.expert,
      openingLine: 'You made it further than the rest.',
      signatureLine: 'Down you go!',
      woundedLine: 'No. Not to a castaway.',
    ),
  };

  static BossDef? forWorld(String worldId) => byWorld[worldId];

  static List<BossDef> get all => byWorld.values.toList();
}
