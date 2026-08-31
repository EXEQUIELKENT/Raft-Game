import 'dart:math';

import 'dart:ui';

import 'models.dart';

/// ---------------------------------------------------------------------------
/// Per-projectile weapon views.
///
/// Every [WeaponDef] has its own firearm: geometry (receiver, shaft barrel,
/// bell mouth, stock, drum, prongs, pump), grip layout — expressed as IK hand
/// targets on the weapon's local frame — and a firing animation spec (recoil
/// kick, muzzle climb, slide/pump travel, muzzle flash) that scales with the
/// projectile's weight and caliber. The renderer draws the weapon and solves
/// the arms against the grip targets; nothing is shared between calibers
/// except the resolution machinery.
///
/// ## Size match
/// The projectile renderer draws each ball at radius `9 * weight` — rounds
/// 18 to 28.8 units across, deliberately head-sized. A firearm sized to its
/// ammo is therefore a *launcher*: the shaft barrel is a hand-grippable tube
/// ([barrelThickness]) that flares at the muzzle into a bell mouth of [bore]
/// ≈ 98% of the round's full diameter ([boreFor]), with a rimmed opening you
/// can see the ball sit in. Small calibers get a blunderbuss cup; the anchor
/// gets a mortar mouth as big as a chest — which is the joke.
///
/// Weapon-local frame: the origin sits at the trigger grip (where the firing
/// hand closes), +x runs forward toward the muzzle, +y runs down. The barrel
/// shaft runs [barrelX0] → [barrelX1], the bell flares on to the rim at
/// [muzzleX].
/// ---------------------------------------------------------------------------

/// How the support (off) hand holds this particular firearm.
enum GripStyle {
  /// Hand cups under the trigger hand — light one-hand-ish guns.
  cup,

  /// Hand clamps a foregrip/pump handle under the barrel.
  foregrip,

  /// Hand grips a carry handle on TOP of the weapon, fingers curling down
  /// over it.
  topHandle,

  /// A second fist under the receiver front, hefting the weight.
  heft,
}

class WeaponView {
  final String id;

  /// The radius every projectile is drawn at in flight (`9 * weight` — see
  /// the shot renderer). Single source of truth, so the muzzle bore below is
  /// derived from exactly what the player sees fly out of it.
  static const double ballR = 9.0;

  // --- Geometry (world units) ---
  final double receiverX0;
  final double receiverX1;
  final double receiverH;

  /// Barrel shaft: start (at the receiver), end (where the bell begins).
  final double barrelX0;
  final double barrelX1;

  /// Bell-mouth bore diameter at the rim — 76% of the round's drawn
  /// diameter (see [boreFor]): the visible proof that this firearm is sized
  /// to the projectile it fires.
  final double bore;

  /// Hull-local x of the muzzle rim (end of the bell).
  final double muzzleX;

  /// A butt stock drawn behind the receiver (shoulder-fired guns).
  final double stockLen;

  /// An ammunition drum hanging under the receiver, radius (0 = none).
  final double drumR;

  /// Muzzle brake prongs splaying off the rim (0 = none).
  final double prongLen;

  /// Slide handle travel on fire (pump action, 0 = none).
  final double pumpTravel;
  final double pumpX0;
  final double pumpX1;

  // --- Grip layout (IK hand targets, weapon-local) ---
  final double gripX;
  final double gripY;

  /// The support hand's hold: its x along the weapon and resting palm y for
  /// cup/heft styles (a tube/foregrip grip hangs the palm off the shaft
  /// instead — see [supportPalmY]) — and the wrist bend that makes the arm
  /// match. Cup stacks sit well clear below the firing hand so the two
  /// fists read as two hands, not one blob.
  final double supportForeX;
  final double supportForeY;
  final GripStyle supportStyle;
  final double supportBend;

  /// How far forward of the shoulder the grip is carried while aiming —
  /// heavier guns sit closer (tucked into the shoulder).
  final double holdDist;

  // --- Firing animation ---
  final double kick;
  final double climb;
  final double recoilDur;
  final double flashR;
  final double flashDur;
  final double sway;

  // --- Variant & model details ---

  /// Which visual variant of this caliber's firearm this is (0 = default).
  /// Several calibers carry more than one model — see [_variantSets] — and
  /// each crew member is assigned one deterministically from their
  /// [WeaponView.variantForPhase] phase, so the deck shows a mixed rack.
  final int variant;

  /// Explicit shaft thickness; 0 derives a hand-wrappable tube from the
  /// bore. The AK's slim rifle barrel uses this.
  final double barrelT;

  /// Weapon-local x of a rifle-style front sight post (0 = none).
  final double sightX;

  /// Weapon-local x of a carry handle above the barrel (0 = none); drawn
  /// for [GripStyle.topHandle] holds.
  final double handleX;

  /// Wooden handguard furniture over the front of the shaft (AK-style).
  final bool woodFurniture;

  const WeaponView({
    required this.id,
    required this.receiverX0,
    required this.receiverX1,
    required this.receiverH,
    required this.barrelX0,
    required this.barrelX1,
    required this.bore,
    required this.muzzleX,
    this.stockLen = 0,
    this.drumR = 0,
    this.prongLen = 0,
    this.pumpTravel = 0,
    this.pumpX0 = 0,
    this.pumpX1 = 0,
    this.variant = 0,
    this.barrelT = 0,
    this.sightX = 0,
    this.handleX = 0,
    this.woodFurniture = false,
    required this.gripX,
    required this.gripY,
    required this.supportForeX,
    required this.supportForeY,
    required this.supportStyle,
    this.supportBend = 1,
    required this.holdDist,
    required this.kick,
    required this.climb,
    required this.recoilDur,
    required this.flashR,
    required this.flashDur,
    required this.sway,
  });

  /// Bell-mouth bore for [w]: ~98% of the round's drawn diameter
  /// (`2 * [ballR] * weight`), so the firearm opening reads as sized for
  /// the exact caliber — the ball visibly fills the mouth it launches
  /// from.
  static double boreFor(WeaponDef w) => 2 * ballR * w.weight * 0.98;

  /// Shaft thickness: a hand-wrappable tube (50% of the bell bore + walls)
  /// — slim enough that a fist closes around it, fat enough to look like
  /// it carries the round — unless the model pins its own (the AK's slim
  /// rifle barrel).
  double get barrelThickness => barrelT > 0 ? barrelT : bore * 0.50 + 1.4;

  /// Weapon-local y of the support fist's palm CENTRE — the IK wrist
  /// target. A foregrip hangs the palm just under the shaft so fingers can
  /// curl up over it; a top handle raises the palm above the weapon so
  /// fingers curl down; cup/heft stacks sit at [supportForeY], clear below
  /// the firing hand.
  double get supportPalmY => switch (supportStyle) {
        GripStyle.foregrip => barrelThickness / 2 + 3.0,
        GripStyle.topHandle => -(barrelThickness / 2 + 3.5),
        _ => supportForeY,
      };

  /// Bell-mouth rim height, slightly wider than the bore for a read at a
  /// glance.
  double get flare => bore + 1.0;

  /// Half the receiver height — grip, drum and stock geometry hang off it.
  double get receiverHalf => receiverH / 2;

  /// Top edge of the trigger-grip stub: just under the receiver.
  double get stubTopY => receiverHalf - 0.6;

  /// Muzzle opening (center of the rim band) in weapon-local coordinates —
  /// the muzzle flash and shot exit both happen here.
  Offset get muzzle => Offset(muzzleX - 1.6, 0);

  /// Support-fist target: the grip/pump handle position, sliding rearward
  /// with the pump cycle.
  Offset supportTarget(double pumpT) =>
      Offset(supportForeX - pumpT * pumpTravel, supportPalmY);

  // Bores below are `2 * ballR * weight * 0.98` for each weapon's caliber
  // (see [boreFor]) — the muzzle mouth matches the ball it fires, and the
  // bell flare spans ~45% of the bore so it reads as a flare, not a wall.

  static const WeaponView _tennis = WeaponView(
    id: 'tennis',
    receiverX0: -2, receiverX1: 6, receiverH: 18,
    barrelX0: 6, barrelX1: 20, bore: 17.6, muzzleX: 29,
    gripX: 0, gripY: 12.5,
    supportForeX: -2, supportForeY: 18.5,
    supportStyle: GripStyle.cup,
    holdDist: 14,
    kick: 3.5, climb: 0.22, recoilDur: 0.20,
    flashR: 13, flashDur: 0.10, sway: 0.8,
  );

  /// The grenade launcher is an AK-pattern rifle: slim barrel, wooden
  /// handguard and stock, front sight post, curved magazine — firing the
  /// round out of a grenade-launcher cup at the muzzle. Held like a real
  /// rifle: firing hand at the pistol grip, support hand clamping the
  /// handguard.
  static const WeaponView _grenade = WeaponView(
    id: 'grenade',
    receiverX0: -12, receiverX1: 8, receiverH: 20.5,
    barrelX0: 8, barrelX1: 26, bore: 20.3, muzzleX: 34,
    barrelT: 9,
    stockLen: 11,
    drumR: 6.5,
    sightX: 28,
    woodFurniture: true,
    gripX: -8, gripY: 14,
    supportForeX: 13, supportForeY: 0,
    supportStyle: GripStyle.foregrip,
    holdDist: 14,
    kick: 5.5, climb: 0.30, recoilDur: 0.30,
    flashR: 16, flashDur: 0.16, sway: 1.1,
  );

  /// Grenade variant: the old drum-fed lobber — a fat tube with a pump
  /// slide, held under the barrel.
  static const WeaponView _grenadeLobber = WeaponView(
    id: 'grenade',
    variant: 1,
    receiverX0: -6, receiverX1: 5, receiverH: 20.5,
    barrelX0: 5, barrelX1: 22, bore: 20.3, muzzleX: 32,
    stockLen: 4.5,
    drumR: 6.5,
    pumpTravel: 4.5, pumpX0: 12.5, pumpX1: 17.5,
    gripX: -3, gripY: 14,
    supportForeX: 15, supportForeY: 0,
    supportStyle: GripStyle.foregrip,
    holdDist: 15,
    kick: 5.5, climb: 0.30, recoilDur: 0.30,
    flashR: 16, flashDur: 0.16, sway: 1.1,
  );

  /// Tennis variant: a sawn-off carbine — short barrel, big bell, no
  /// stock, cupped two-hand hold.
  static const WeaponView _tennisShorty = WeaponView(
    id: 'tennis',
    variant: 1,
    receiverX0: -3, receiverX1: 6, receiverH: 18,
    barrelX0: 6, barrelX1: 15, bore: 17.6, muzzleX: 24,
    gripX: -2.5, gripY: 13,
    supportForeX: -2, supportForeY: 18.5,
    supportStyle: GripStyle.cup,
    holdDist: 13,
    kick: 3.5, climb: 0.22, recoilDur: 0.20,
    flashR: 12, flashDur: 0.10, sway: 0.8,
  );

  static const WeaponView _bomb = WeaponView(
    id: 'bomb',
    receiverX0: -10, receiverX1: 3, receiverH: 24,
    barrelX0: 3, barrelX1: 24, bore: 23.8, muzzleX: 36,
    stockLen: 9.5,
    drumR: 8,
    gripX: -6, gripY: 15.5,
    supportForeX: 1, supportForeY: 17.5,
    supportStyle: GripStyle.heft,
    supportBend: -1,
    holdDist: 14,
    kick: 8, climb: 0.38, recoilDur: 0.38,
    flashR: 19, flashDur: 0.20, sway: 1.3,
  );

  static const WeaponView _cluster = WeaponView(
    id: 'cluster',
    receiverX0: -4, receiverX1: 6, receiverH: 19.5,
    barrelX0: 6, barrelX1: 19, bore: 19.4, muzzleX: 28,
    stockLen: 4,
    drumR: 6,
    prongLen: 4.5,
    handleX: 11,
    gripX: -2.5, gripY: 13.5,
    supportForeX: 11, supportForeY: 0,
    supportStyle: GripStyle.topHandle,
    holdDist: 14.5,
    kick: 5, climb: 0.26, recoilDur: 0.28,
    flashR: 15, flashDur: 0.14, sway: 1.0,
  );

  static const WeaponView _anchor = WeaponView(
    id: 'anchor',
    receiverX0: -10, receiverX1: 8, receiverH: 28.5,
    barrelX0: 8, barrelX1: 30, bore: 28.2, muzzleX: 44,
    stockLen: 10,
    prongLen: 5,
    gripX: -5, gripY: 18.5,
    supportForeX: 19, supportForeY: 0,
    supportStyle: GripStyle.foregrip,
    holdDist: 15.5,
    kick: 9.5, climb: 0.45, recoilDur: 0.45,
    flashR: 23, flashDur: 0.22, sway: 1.4,
  );

  /// Default model per caliber (what [forId] hands out — tests, previews).
  static const Map<String, WeaponView> _all = {
    'tennis': _tennis,
    'grenade': _grenade,
    'bomb': _bomb,
    'cluster': _cluster,
    'anchor': _anchor,
  };

  /// The visual variants each caliber can show up with: crew members are
  /// assigned one deterministically from their bob phase, so a deck carries
  /// a mixed rack instead of five identical guns.
  static const Map<String, List<WeaponView>> _variantSets = {
    'tennis': [_tennis, _tennisShorty],
    'grenade': [_grenade, _grenadeLobber],
  };

  static WeaponView forId(String id) => _all[id] ?? _tennis;

  /// How many visual variants a caliber has (1 = single model).
  static int variantCount(String id) => _variantSets[id]?.length ?? 1;

  /// The [variant]-th model of a caliber (wraps safely).
  static WeaponView forVariant(String id, int variant) {
    final set = _variantSets[id];
    if (set == null || set.isEmpty) return forId(id);
    return set[variant % set.length];
  }

  /// Deterministic per-character variant pick: same crew member, same
  /// variant, every frame — and shared by the renderer and the shot-spawn
  /// maths so the muzzle never jumps between models.
  static int variantForPhase(double bobPhase, String id) =>
      ((bobPhase * 7.3).floor().abs()) % variantCount(id);

  /// The view for whatever a crew member currently has equipped, falling
  /// back to the shooter's selected weapon and then the starter. Pass
  /// [variant] (usually from [variantForPhase]) for the crew member's
  /// assigned model of that caliber.
  static WeaponView forCrew(String? equippedId, WeaponDef? selected,
      {int variant = 0}) {
    final id = equippedId ?? selected?.id ?? 'tennis';
    return forVariant(id, variant);
  }
}

/// Analytic two-bone IK: given a shoulder and a hand target, returns the
/// elbow position that reaches it, bending to the side [bend] picks. This is
/// what makes every grip target — pistol cup, barrel foregrip, stacked rear
/// heft — read as an actual held weapon rather than arms glued to a
/// rectangle.
///
/// The rig is a chunky cartoon: bones stretch proportionally (up to
/// [softStretch]) when a grip sits beyond nominal span, exactly like the
/// hand-drawn poses did, so hands always land *on* the weapon.
class ArmIK {
  /// Upper and forearm lengths for the chunky crew rig, at rest.
  static const double upper = 14;
  static const double fore = 14;

  /// How far bones may stretch past nominal span (1.0 = rigid).
  static const double softStretch = 1.14;

  /// Maximum hand distance from the shoulder.
  static double get reachMax => (upper + fore) * softStretch;

  /// Reach used when a support hand chokes up along a weapon: a hair inside
  /// [reachMax] so the IK never visibly fails after the pull-in.
  static double get supportReach => reachMax - 1.5;

  /// Slides a hand target along the weapon axis to the furthest point the
  /// support arm can actually reach — a real shooter chokes up on a long
  /// gun rather than holding it at an impossible stretch. Returns the chosen
  /// distance from the grip along [axis].
  static double chokeUp({
    required Offset anchor,
    required Offset axis,
    required Offset shoulder,
    required double preferredT,
    double minT = 0,
    double maxT = 999,
  }) {
    final v = anchor - shoulder;
    final vd = v.dx * axis.dx + v.dy * axis.dy;
    final vv = v.dx * v.dx + v.dy * v.dy;
    final disc = vd * vd - vv + supportReach * supportReach;
    final tReach = disc <= 0 ? minT.toDouble() : -vd + sqrt(disc);
    return min(preferredT, tReach).clamp(minT, maxT).toDouble();
  }

  static (Offset elbow, Offset hand) solve(
    Offset shoulder,
    Offset target, {
    double bend = 1,
    double maxBend = 9.0,
  }) {
    var delta = target - shoulder;
    var dist = delta.distance;
    var up = upper;
    var fo = fore;
    final minR = (upper - fore).abs() + 0.8;
    if (dist > reachMax) {
      // Beyond the stretch budget: the hand clamps to the reach limit and
      // both bones sit at full stretch.
      delta = delta / dist * reachMax;
      dist = reachMax;
      up *= softStretch;
      fo *= softStretch;
    } else if (dist > upper + fore) {
      // Partial stretch between nominal span and the budget.
      final k = dist / (upper + fore);
      up *= k;
      fo *= k;
    } else if (dist < minR) {
      delta = dist <= 1e-6 ? Offset(minR, 0) : delta / dist * minR;
      dist = minR;
    }
    final target2 = shoulder + delta;

    // Law of cosines for the elbow's position along the shoulder->hand line.
    final a = (up * up - fo * fo + dist * dist) / (2 * dist);
    // Clamp the perpendicular bulge: near-reach grips give an isosceles
    // triangle with huge elbow excursion (chicken wings). Real gun carries
    // are fairly straight — cap the bend.
    final h = min(sqrt(max(0.0, up * up - a * a)), maxBend);
    final u = delta / dist;
    final perp = Offset(-u.dy * bend, u.dx * bend);
    final elbow = shoulder + u * a + perp * h;
    return (elbow, target2);
  }
}
