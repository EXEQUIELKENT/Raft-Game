import 'dart:math';
import 'dart:ui';

/// Building your own raft, block by block, out of what you can afford.
///
/// This is the alternative to picking a prefab hull. A prefab is one fixed
/// silhouette with a fixed deck profile and a fixed amount of punishment it
/// can take; a built raft is a grid of blocks the player chose, each with its
/// own toughness, and each of which can be shot off. The structure IS the
/// cover, so a match against a built raft is partly about dismantling it.
///
/// Deliberately a plain grid rather than free placement. A height-field deck
/// (see `DeckProfile`) can express one surface height per x, which is what
/// the crew walk on and what every collision path already understands — a
/// grid of stacked blocks maps onto that exactly, where an arbitrary polygon
/// would not, and would need every one of those paths rewritten.

/// What a block is made of.
enum BuildMaterial {
  /// Bundled reed. Almost free, almost useless — a screen, not a wall.
  thatch,

  /// Beachcombed timber. Cheap and honest.
  driftwood,

  /// Sawn plank. The middle of the range in every respect.
  plank,

  /// A sealed barrel. Tough for its price, and buoyant, so it is the cheap
  /// way to get height.
  barrel,

  /// Plated iron. Expensive enough that a whole raft of it is out of reach,
  /// which is the point: it is for the one or two places that matter.
  iron,
}

/// The numbers behind a material.
///
/// [hp] is sized against the weapon table, which runs 14 to 74 damage: thatch
/// falls to anything, driftwood takes a light round or one heavy one, and
/// iron needs several of the heaviest. [cost] is what makes that a decision
/// rather than a preference — an all-iron raft does not fit in the budget.
class MaterialDef {
  final BuildMaterial kind;
  final String name;
  final String blurb;
  final double hp;
  final int cost;
  final Color color;
  final Color shade;

  const MaterialDef({
    required this.kind,
    required this.name,
    required this.blurb,
    required this.hp,
    required this.cost,
    required this.color,
    required this.shade,
  });

  static const thatch = MaterialDef(
    kind: BuildMaterial.thatch,
    name: 'Thatch',
    blurb: 'Falls to a stiff breeze. Free, and worth it.',
    hp: 18,
    cost: 1,
    color: Color(0xFFD9BE76),
    shade: Color(0xFFA98E4C),
  );

  static const driftwood = MaterialDef(
    kind: BuildMaterial.driftwood,
    name: 'Driftwood',
    blurb: 'Whatever washed up. Cheap and honest.',
    hp: 45,
    cost: 2,
    color: Color(0xFFB9946A),
    shade: Color(0xFF836444),
  );

  static const plank = MaterialDef(
    kind: BuildMaterial.plank,
    name: 'Plank',
    blurb: 'Sawn and square. Middle of the range.',
    hp: 80,
    cost: 4,
    color: Color(0xFFC58A4E),
    shade: Color(0xFF8C5C2E),
  );

  static const barrel = MaterialDef(
    kind: BuildMaterial.barrel,
    name: 'Barrel',
    blurb: 'Sealed and buoyant — the cheap way to get height.',
    hp: 110,
    cost: 6,
    color: Color(0xFF9A6A3C),
    shade: Color(0xFF6B4526),
  );

  static const iron = MaterialDef(
    kind: BuildMaterial.iron,
    name: 'Iron',
    blurb: 'Shrugs off an anchor. You cannot afford many.',
    hp: 230,
    cost: 14,
    color: Color(0xFF7E868F),
    shade: Color(0xFF505860),
  );

  static const all = [thatch, driftwood, plank, barrel, iron];

  static MaterialDef of(BuildMaterial m) =>
      all.firstWhere((d) => d.kind == m, orElse: () => plank);
}

/// One block in a built raft.
class BuildCell {
  final BuildMaterial material;
  double hp;

  /// Seconds left of this block's reaction to being struck — a shudder, the
  /// same treatment the channel obstacles get. Not a white flash: a block
  /// can be hit several times before it goes, and a full-box strobe at that
  /// rate reads as flicker rather than as impact.
  double flash = 0;

  BuildCell(this.material) : hp = MaterialDef.of(material).hp;

  BuildCell._raw(this.material, this.hp);

  MaterialDef get def => MaterialDef.of(material);
  bool get broken => hp <= 0;

  /// How battered it looks, 0 (untouched) to 1 (about to go).
  double get wear =>
      def.hp <= 0 ? 0 : (1 - (hp / def.hp)).clamp(0.0, 1.0);

  BuildCell copy() => BuildCell._raw(material, hp);
}

/// A built raft: a grid of blocks sitting on the deck.
///
/// Column 0 is the aft-most, row 0 sits on the planks and rows grow upward.
/// The grid is addressed in the raft's own hull-local space, so it mirrors
/// with the hull's facing for free.
class BuildPlan {
  /// Grid size. Fixed rather than per-hull so a plan can be carried between
  /// rafts, and so the build screen is the same shape every time.
  static const int cols = 9;
  static const int rows = 4;

  /// Block size in world units. A crew member is about 29 across and 58
  /// tall, so a block is roughly waist-high and a stack of two is something
  /// to stand behind.
  static const double cellW = 26;
  static const double cellH = 24;

  /// What a player has to spend. Sized so a full grid of driftwood is
  /// affordable and a full grid of plank is not — the budget has to force a
  /// shape, or everyone builds the same solid rectangle.
  static const int budget = 60;

  /// Row-major, `rows * cols` long; null is empty space.
  final List<BuildCell?> cells;

  BuildPlan._(this.cells);

  BuildPlan.empty() : cells = List<BuildCell?>.filled(cols * rows, null);

  /// A plain two-block-high bar across the middle — what a player gets if
  /// they open the build screen and press start without touching anything.
  factory BuildPlan.starter() {
    final p = BuildPlan.empty();
    for (int c = 2; c < cols - 2; c++) {
      p.set(c, 0, BuildMaterial.driftwood);
    }
    p.set(cols ~/ 2, 1, BuildMaterial.plank);
    return p;
  }

  static int _index(int col, int row) => row * cols + col;

  bool inside(int col, int row) =>
      col >= 0 && col < cols && row >= 0 && row < rows;

  BuildCell? at(int col, int row) =>
      inside(col, row) ? cells[_index(col, row)] : null;

  void set(int col, int row, BuildMaterial? m) {
    if (!inside(col, row)) return;
    cells[_index(col, row)] = m == null ? null : BuildCell(m);
  }

  /// A deep copy, so a plan handed to a live match cannot be edited from the
  /// build screen behind its back.
  BuildPlan copy() => BuildPlan._([for (final c in cells) c?.copy()]);

  /// What this plan costs.
  int get cost {
    var total = 0;
    for (final c in cells) {
      if (c != null) total += c.def.cost;
    }
    return total;
  }

  int get blockCount => cells.where((c) => c != null).length;

  bool get withinBudget => cost <= budget;

  /// True when nothing is floating: every block either sits on the deck
  /// (row 0) or has a block directly beneath it.
  ///
  /// Checked at build time rather than simulated, because a plan that cannot
  /// stand is a plan the player should be told about while they can still
  /// fix it — not one that collapses the moment the match opens.
  bool get isSupported {
    for (int row = 1; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        if (at(col, row) != null && at(col, row - 1) == null) return false;
      }
    }
    return true;
  }

  bool get isValid => withinBudget && isSupported && blockCount > 0;

  /// Why a plan cannot be used, in words the build screen can show, or null
  /// when it is fine.
  String? get problem {
    if (blockCount == 0) return 'Place at least one block.';
    if (!withinBudget) return 'Over budget by ${cost - budget}.';
    if (!isSupported) return 'Some blocks have nothing underneath them.';
    return null;
  }

  // --- Live structure ------------------------------------------------------

  /// Total width the grid occupies, in world units.
  static double get width => cols * cellW;

  /// Hull-local x of a column's centre.
  static double columnX(int col) => (col - (cols - 1) / 2) * cellW;

  /// Which column covers hull-local [x], or -1 when none does.
  static int columnAt(double x) {
    final col = ((x / cellW) + (cols - 1) / 2).round();
    return (col >= 0 && col < cols) ? col : -1;
  }

  /// How far the intact structure rises above the deck at hull-local [x].
  ///
  /// The top of the tallest UNBROKEN run from the deck up. A gap stops the
  /// run: once a block is shot out, anything above it is no longer standing
  /// on something, so it cannot be walked on either — which is what makes
  /// shooting the bottom out of a tower worth doing.
  double riseAt(double x) {
    final col = columnAt(x);
    if (col < 0) return 0;
    var rise = 0.0;
    for (int row = 0; row < rows; row++) {
      final cell = at(col, row);
      if (cell == null || cell.broken) break;
      rise = (row + 1) * cellH;
    }
    return rise;
  }

  /// The block at hull-local ([x], [yAboveDeck]), or null.
  ///
  /// [yAboveDeck] is measured upward from the planks, matching [riseAt].
  BuildCell? cellAtPoint(double x, double yAboveDeck) {
    final col = columnAt(x);
    if (col < 0) return null;
    final row = (yAboveDeck / cellH).floor();
    final cell = at(col, row);
    return (cell == null || cell.broken) ? null : cell;
  }

  /// Applies [damage] to the block at a point. Returns what it hit, or null
  /// if there was nothing there.
  BuildCell? damageAt(double x, double yAboveDeck, double damage) {
    final col = columnAt(x);
    if (col < 0) return null;
    final row = (yAboveDeck / cellH).floor();
    final cell = at(col, row);
    if (cell == null || cell.broken) return null;
    cell.hp -= damage;
    if (cell.hp <= 0) {
      cell.hp = 0;
      _collapseAbove(col, row);
    }
    return cell;
  }

  /// Brings down anything left unsupported by a block breaking.
  ///
  /// Everything above a hole in a column goes, rather than the one block
  /// that broke: those blocks were standing on it. Modelling them falling
  /// and re-landing would need a second physics system for a case the player
  /// reads as "the tower came down" either way.
  void _collapseAbove(int col, int row) {
    for (int r = row + 1; r < rows; r++) {
      final above = at(col, r);
      if (above == null) break;
      above.hp = 0;
    }
  }

  /// Every intact block, as (col, row, cell) — for drawing and for tests.
  Iterable<(int, int, BuildCell)> get standing sync* {
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final c = at(col, row);
        if (c != null && !c.broken) yield (col, row, c);
      }
    }
  }

  /// How much of the structure is still up, 0..1 by block count. Drives the
  /// "how wrecked is it" readout.
  double get intactFraction {
    final total = blockCount;
    if (total == 0) return 0;
    return standing.length / total;
  }

  /// The tallest intact column, in world units. What the AI would have to
  /// clear to reach the crew behind it.
  double get peakRise {
    var peak = 0.0;
    for (int col = 0; col < cols; col++) {
      peak = max(peak, riseAt(columnX(col)));
    }
    return peak;
  }

  // --- Persistence ---------------------------------------------------------

  /// Compact enough to live in a save file and to cross a hotspot link: one
  /// character per cell, '.' for empty.
  String encode() {
    final buf = StringBuffer();
    for (final c in cells) {
      buf.write(c == null ? '.' : _codes[c.material]!);
    }
    return buf.toString();
  }

  static BuildPlan decode(String s) {
    final p = BuildPlan.empty();
    for (int i = 0; i < p.cells.length && i < s.length; i++) {
      final m = _byCode[s[i]];
      if (m != null) p.cells[i] = BuildCell(m);
    }
    return p;
  }

  static const _codes = {
    BuildMaterial.thatch: 't',
    BuildMaterial.driftwood: 'd',
    BuildMaterial.plank: 'p',
    BuildMaterial.barrel: 'b',
    BuildMaterial.iron: 'i',
  };

  static final _byCode = {
    for (final e in _codes.entries) e.value: e.key,
  };
}
