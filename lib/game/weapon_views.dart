import 'dart:math';

import 'dart:ui';

import 'models.dart';

/// ---------------------------------------------------------------------------
/// Per-projectile weapon views.
///
/// Every [WeaponDef] has its own firearm: geometry (receiver, barrel, stock,
/// drum, prongs, pump), grip layout — expressed as IK hand targets on the
/// weapon's local frame — and a firing animation spec (recoil kick, muzzle
/// climb, slide/pump travel, muzzle flash) that scales with the projectile's
/// weight and caliber. The renderer draws the weapon and solves the arms
/// against the grip targets; nothing is shared between calibers except the
/// resolution machinery.
///
/// Weapon-local frame: the origin sits at the trigger grip (where the firing
/// hand closes), +x runs forward toward the muzzle, +y runs down. The muzzle
/// tip lands at [muzzleX].
/// ---------------------------------------------------------------------------

/// How the support (off) hand holds this particular firearm.
enum GripStyle {
  /// Hand cups under the trigger hand — light one-hand-ish guns.
  cup,

  /// Hand clamps a foregrip partway along the barrel.
  foregrip,

  /// Both hands stacked on the rear grip, hefting the weight.
  heft,
}

class WeaponView {
  final String id;

  // --- Geometry (world units) ---
  final double receiverX0;
  final double receiverX1;
  final double receiverH;
  final double barrelX0;
  final double barrelX1;

  /// Diameter of the muzzle opening. Sized from the projectile the weapon
  /// fires ([boreFor]), with the barrel walls adding to it — see
  /// [barrelThickness].
  final double bore;
  final double muzzleX;

  /// A butt stock drawn behind the grip (heavy shoulder-fired guns).
  final double stockLen;

  /// An ammunition drum drawn under the receiver, radius (0 = none).
  final double drumR;

  /// Muzzle prongs / brake, extending past the barrel (0 = none).
  final double prongLen;

  /// Slide handle travel on fire (pump action, 0 = none).
  final double pumpTravel;
  final double pumpX0;
  final double pumpX1;

  // --- Grip layout (IK targets, weapon-local) ---
  final double gripX;
  final double gripY;

  /// Where the trigger hand sits relative to the weapon origin, and the
  /// support-hand target. [gripReach] is how far forward of the shoulder
  /// the grip is held while aiming.
  final double supportForeX;
  final double supportForeY;
  final GripStyle supportStyle;

  /// Arm bend direction: +1 sags the elbow low (carry), −1 lifts it out
  /// (bracing a heavy weapon).
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

  /// Muzzle bore for [w], proportional to the round's drawn radius
  /// (`9 * weight` in the projectile renderer): the muzzle opening always
  /// reads as sized for the exact caliber the weapon fires.
  static double boreFor(WeaponDef w) => 9.0 * w.weight * 0.45;

  /// Outer barrel thickness: the bore plus the tube walls.
  double get barrelThickness => bore + 1.2;

  static const WeaponView _tennis = WeaponView(
    id: 'tennis',
    receiverX0: -2, receiverX1: 7, receiverH: 5,
    barrelX0: 7, barrelX1: 18, bore: 4.05, muzzleX: 20,
    gripX: 0, gripY: 1.5,
    supportForeX: -3, supportForeY: 4,
    supportStyle: GripStyle.cup,
    holdDist: 13,
    kick: 3.5, climb: 0.22, recoilDur: 0.20,
    flashR: 7, flashDur: 0.10, sway: 0.8,
  );

  static const WeaponView _grenade = WeaponView(
    id: 'grenade',
    receiverX0: -4, receiverX1: 8, receiverH: 6,
    barrelX0: 8, barrelX1: 23, bore: 4.7, muzzleX: 25,
    drumR: 4.2,
    pumpTravel: 4, pumpX0: 12, pumpX1: 16,
    gripX: -2, gripY: 1.5,
    supportForeX: 14, supportForeY: 0,
    supportStyle: GripStyle.foregrip,
    holdDist: 14,
    kick: 5.5, climb: 0.30, recoilDur: 0.30,
    flashR: 10, flashDur: 0.16, sway: 1.1,
  );

  static const WeaponView _bomb = WeaponView(
    id: 'bomb',
    receiverX0: -6, receiverX1: 6, receiverH: 7,
    barrelX0: 6, barrelX1: 15, bore: 5.5, muzzleX: 17,
    stockLen: 6,
    gripX: -4, gripY: 1.5,
    supportForeX: -2, supportForeY: 2.5,
    supportStyle: GripStyle.heft,
    supportBend: -1,
    holdDist: 12,
    kick: 8, climb: 0.38, recoilDur: 0.38,
    flashR: 13, flashDur: 0.20, sway: 1.3,
  );

  static const WeaponView _cluster = WeaponView(
    id: 'cluster',
    receiverX0: -3, receiverX1: 8, receiverH: 5,
    barrelX0: 8, barrelX1: 20, bore: 4.5, muzzleX: 24,
    drumR: 3.6,
    prongLen: 4,
    gripX: -1.5, gripY: 1.5,
    supportForeX: 9, supportForeY: 0,
    supportStyle: GripStyle.foregrip,
    holdDist: 14,
    kick: 5, climb: 0.26, recoilDur: 0.28,
    flashR: 11, flashDur: 0.14, sway: 1.0,
  );

  static const WeaponView _anchor = WeaponView(
    id: 'anchor',
    receiverX0: -5, receiverX1: 8, receiverH: 7,
    barrelX0: 8, barrelX1: 28, bore: 6.5, muzzleX: 32,
    prongLen: 4,
    gripX: -3, gripY: 1.5,
    supportForeX: 12, supportForeY: 0,
    supportStyle: GripStyle.foregrip,
    holdDist: 15,
    kick: 9.5, climb: 0.45, recoilDur: 0.45,
    flashR: 14, flashDur: 0.22, sway: 1.4,
  );

  static const Map<String, WeaponView> _all = {
    'tennis': _tennis,
    'grenade': _grenade,
    'bomb': _bomb,
    'cluster': _cluster,
    'anchor': _anchor,
  };

  static WeaponView forId(String id) => _all[id] ?? _tennis;

  /// The view for whatever a crew member currently has equipped, falling
  /// back to the shooter's selected weapon and then the starter.
  static WeaponView forCrew(String? equippedId, WeaponDef? selected) {
    if (equippedId != null) return forId(equippedId);
    if (selected != null) return forId(selected.id);
    return forId('tennis');
  }

  /// Forearm support: the foregrip/pump handle slides with the pump.
  Offset supportTarget(double pumpT) =>
      Offset(supportForeX + pumpT * pumpTravel, supportForeY);

  /// Muzzle tip in weapon-local coordinates.
  Offset get muzzle => Offset(muzzleX, 0);
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
    final h = sqrt(max(0.0, up * up - a * a));
    final u = delta / dist;
    final perp = Offset(-u.dy * bend, u.dx * bend);
    final elbow = shoulder + u * a + perp * h;
    return (elbow, target2);
  }
}
