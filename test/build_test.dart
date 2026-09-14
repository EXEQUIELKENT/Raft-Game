import 'dart:ui' show Offset;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:raft_rumble/game/ai.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/controller.dart';
import 'package:raft_rumble/game/build.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';
import 'package:raft_rumble/widgets/build_overlay.dart';

/// Building your own raft instead of picking a prefab one.
///
/// The structure IS the cover: it is what the crew stand on and what a shot
/// has to get through, so the two things that must hold are that it behaves
/// like a floor and that it behaves like a wall — and that shooting it away
/// changes both.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SaveService.instance.data = SaveData();
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  BattleWorld world({BuildPlan? plan}) {
    final w = BattleWorld(map: GameMaps.all.first, seed: 11);
    w.obstacles.clear();
    w.water = WaterProfile.flat;
    for (int p = 0; p < 2; p++) {
      final raft = Raft(
        playerIndex: p,
        x: p == 0 ? BattleConst.playerX : BattleConst.enemySlots.first,
        loadout:
            RaftLoadout.custom(hullId: 'barge', sizeId: 'large', colorIndex: p),
        look: p == 0 ? CrewLook.player : CrewLook.raider,
        label: 'R$p',
        facing: p == 0 ? 1 : -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      );
      if (p == 0 && plan != null) raft.build = plan;
      w.addRaft(raft);
    }
    return w;
  }

  group('A plan a player can actually use', () {
    test('the starter plan is valid', () {
      final p = BuildPlan.starter();
      expect(p.problem, isNull, reason: p.problem ?? '');
      expect(p.isValid, true);
      expect(p.blockCount, greaterThan(2));
    });

    test('an empty plan is refused, with a reason', () {
      final p = BuildPlan.empty();
      expect(p.isValid, false);
      expect(p.problem, isNotNull);
    });

    test('a floating block is refused', () {
      // Caught at build time rather than simulated: a plan that cannot stand
      // is something the player should be told about while they can still
      // fix it, not something that collapses when the match opens.
      final p = BuildPlan.empty();
      p.set(3, 2, BuildMaterial.plank); // nothing underneath
      expect(p.isSupported, false);
      expect(p.problem, contains('underneath'));
    });

    test('a stack standing on the deck is supported', () {
      final p = BuildPlan.empty();
      for (int r = 0; r < BuildPlan.rows; r++) {
        p.set(4, r, BuildMaterial.driftwood);
      }
      expect(p.isSupported, true);
    });

    test('the budget forces a choice', () {
      // If everything fit, everyone would build the same solid rectangle.
      final cheap = BuildPlan.empty();
      final dear = BuildPlan.empty();
      for (int c = 0; c < BuildPlan.cols; c++) {
        cheap.set(c, 0, BuildMaterial.driftwood);
        dear.set(c, 0, BuildMaterial.iron);
      }
      expect(cheap.withinBudget, true,
          reason: 'a single row of the cheap stuff has to be affordable');
      expect(dear.withinBudget, false,
          reason: 'a row of iron should be out of reach');
      expect(dear.problem, contains('budget'));
    });

    test('a full grid of the toughest material is never affordable', () {
      final p = BuildPlan.empty();
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          p.set(c, r, BuildMaterial.iron);
        }
      }
      expect(p.withinBudget, false);
    });

    test('a plan survives a round trip through text', () {
      // It has to reach a save file and cross a hotspot link.
      final p = BuildPlan.starter();
      p.set(0, 0, BuildMaterial.iron);
      p.set(1, 0, BuildMaterial.thatch);
      final back = BuildPlan.decode(p.encode());
      expect(back.encode(), p.encode());
      expect(back.cost, p.cost);
      expect(back.at(0, 0)!.material, BuildMaterial.iron);
      expect(back.at(1, 0)!.material, BuildMaterial.thatch);
    });

    test('a copy cannot be edited from underneath a live match', () {
      final p = BuildPlan.starter();
      final live = p.copy();
      p.set(4, 0, null);
      expect(live.at(4, 0), isNotNull,
          reason: 'the live plan changed when the editor did');
    });
  });



  group('The build phase', () {
    // Laying out your raft happens AFTER the opening sweep and before the
    // first turn: the camera shows you the opposition, then you decide what
    // to put between you and them. That order is the point — a wall is a
    // response to what you were just shown, not a decision made blind.
    GameController match({bool build = true}) => GameController(
          settings: MatchSettings(
            map: GameMaps.all.first,
            startHp: 100,
            buildYourRaft: build,
          ),
          players: [
            PlayerConfig(
                name: 'P1',
                loadout: RaftLoadout.custom(
                    hullId: 'barge', sizeId: 'large', colorIndex: 0)),
            PlayerConfig(
              name: 'P2',
              loadout: RaftLoadout.custom(
                  hullId: 'barge', sizeId: 'large', colorIndex: 1),
              isAi: true,
              aiDifficulty: AiDifficulty.easy,
            ),
          ],
          mode: GameMode.vsAi,
          seed: 7,
        );

    test('it opens only once the sweep is over', () {
      final ctrl = match();
      expect(ctrl.inIntro, true);
      expect(ctrl.buildPhase, false,
          reason: 'the build panel appeared over the opening sweep');
      ctrl.skipIntro();
      expect(ctrl.buildPhase, true, reason: 'the sweep ended into nothing');
      ctrl.dispose();
    });

    test('a match not set up for building goes straight to the turn', () {
      final ctrl = match(build: false);
      ctrl.skipIntro();
      expect(ctrl.buildPhase, false);
      expect(ctrl.canHumanAct, true);
      ctrl.dispose();
    });

    test('nothing can be fired while blocks are still going down', () {
      final ctrl = match();
      ctrl.skipIntro();
      expect(ctrl.canHumanAct, false);
      final inFlight = ctrl.world.shot;
      ctrl.humanFire();
      expect(identical(ctrl.world.shot, inFlight), true,
          reason: 'a shot went off during the build phase');
      ctrl.dispose();
    });

    test('the turn clock does not run either', () {
      final ctrl = match();
      ctrl.skipIntro();
      final before = ctrl.turnTimeLeft;
      for (int f = 0; f < 180; f++) {
        ctrl.frameForTest(1 / 60);
      }
      expect(ctrl.turnTimeLeft, closeTo(before, 0.01),
          reason: 'the first turn counted down while the player was building');
      ctrl.dispose();
    });

    test('edits show on the raft immediately', () {
      // The raft being edited is the one on the water, so an edit has to
      // reach it rather than living in a panel until committed.
      final ctrl = match();
      ctrl.skipIntro();
      final raft = ctrl.world.raftOf(0)!;
      expect(raft.build, isNotNull);
      ctrl.setBlock(4, 0, BuildMaterial.iron);
      expect(raft.build!.at(4, 0)!.material, BuildMaterial.iron);
      ctrl.dispose();
    });

    test('a plan that cannot stand is refused, not repaired', () {
      final ctrl = match();
      ctrl.skipIntro();
      // Clear it out, then float a block.
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.setBlock(c, r, null);
        }
      }
      ctrl.setBlock(3, 2, BuildMaterial.plank); // nothing underneath
      expect(ctrl.commitBuild(), false,
          reason: 'an unsupported plan was accepted');
      expect(ctrl.buildPhase, true, reason: 'it started the match anyway');
      expect(ctrl.editingPlan!.at(3, 2), isNotNull,
          reason: 'it silently deleted the player\'s block');
      ctrl.dispose();
    });

    test('committing starts the match and keeps the structure', () {
      final ctrl = match();
      ctrl.skipIntro();
      ctrl.setBlock(4, 0, BuildMaterial.iron);
      expect(ctrl.commitBuild(), true);
      expect(ctrl.buildPhase, false);
      expect(ctrl.canHumanAct, true, reason: 'the first turn never opened');
      final raft = ctrl.world.raftOf(0)!;
      expect(raft.build!.at(4, 0)!.material, BuildMaterial.iron,
          reason: 'the committed structure did not survive into the match');
      ctrl.dispose();
    });

    test('the committed plan is remembered for next time', () {
      final ctrl = match();
      ctrl.skipIntro();
      ctrl.setBlock(0, 0, BuildMaterial.iron);
      ctrl.commitBuild();
      expect(SaveService.instance.data.buildPlan, isNotNull);
      expect(SaveService.instance.data.buildPlan!.at(0, 0)!.material,
          BuildMaterial.iron);
      ctrl.dispose();
    });

    test('the saved plan is not the live one', () {
      // Editing next match's plan must not reach into last match's raft.
      final ctrl = match();
      ctrl.skipIntro();
      ctrl.setBlock(0, 0, BuildMaterial.iron);
      ctrl.commitBuild();
      final saved = SaveService.instance.data.buildPlan!;
      saved.set(0, 0, null);
      expect(ctrl.world.raftOf(0)!.build!.at(0, 0), isNotNull,
          reason: 'the live raft changed when the saved plan did');
      ctrl.dispose();
    });
  });

  group('The build overlay', () {
    GameController match() => GameController(
          settings: MatchSettings(
            map: GameMaps.all.first,
            startHp: 100,
            buildYourRaft: true,
          ),
          players: [
            PlayerConfig(
                name: 'P1',
                loadout: RaftLoadout.custom(
                    hullId: 'barge', sizeId: 'large', colorIndex: 0)),
            PlayerConfig(
              name: 'P2',
              loadout: RaftLoadout.custom(
                  hullId: 'barge', sizeId: 'large', colorIndex: 1),
              isAi: true,
              aiDifficulty: AiDifficulty.easy,
            ),
          ],
          mode: GameMode.vsAi,
          seed: 7,
        );

    Future<GameController> pump(WidgetTester tester) async {
      final ctrl = match();
      ctrl.skipIntro();
      await tester.binding.setSurfaceSize(const Size(500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            BuildOverlay(
              ctrl: ctrl,
              selected: BuildMaterial.driftwood,
              onSelect: (_) {},
              topBarKey: GlobalKey(),
              bottomBarKey: GlobalKey(),
            ),
          ]),
        ),
      ));
      await tester.pump();
      return ctrl;
    }

    testWidgets('it shows every material with its cost and toughness',
        (tester) async {
      // The whole decision is the ratio between the two, so they are on the
      // swatch together rather than behind a tooltip.
      final ctrl = await pump(tester);
      for (final def in MaterialDef.all) {
        expect(find.text(def.name), findsOneWidget,
            reason: '${def.name} is missing from the palette');
        expect(find.text('${def.cost}c · ${def.hp.round()}hp'), findsOneWidget,
            reason: '${def.name} does not show what it costs or takes');
      }
      ctrl.dispose();
    });

    testWidgets('it shows what is left to spend, not what is spent',
        (tester) async {
      // A player deciding whether one more iron block fits wants the
      // remainder, not the total.
      final ctrl = await pump(tester);
      final left = BuildPlan.budget - ctrl.editingPlan!.cost;
      expect(find.text('$left LEFT'), findsOneWidget);
      ctrl.dispose();
    });

    testWidgets('going over budget says so instead of silently refusing',
        (tester) async {
      final ctrl = await pump(tester);
      for (int c = 0; c < BuildPlan.cols; c++) {
        for (int r = 0; r < BuildPlan.rows; r++) {
          ctrl.setBlock(c, r, BuildMaterial.iron);
        }
      }
      await tester.pump();
      expect(find.textContaining('OVER BY'), findsOneWidget);
      expect(find.text('CANNOT SAIL'), findsOneWidget,
          reason: 'an unaffordable plan still offered to set sail');
      ctrl.dispose();
    });

    testWidgets('a valid plan offers to set sail', (tester) async {
      final ctrl = await pump(tester);
      expect(ctrl.editingPlan!.problem, isNull);
      expect(find.text('SET SAIL'), findsOneWidget);
      ctrl.dispose();
    });
  });
  group('The grid never hangs over the side', () {
    // The build grid is a fixed width so a plan carries between rafts and
    // the build screen is the same shape every time — which means a wide
    // plan on a narrow hull would put its end blocks over the water.
    test('a narrow hull simply does not build its outer columns', () {
      final w = BattleWorld(map: GameMaps.all.first, seed: 11);
      w.obstacles.clear();
      w.water = WaterProfile.flat;
      final plan = BuildPlan.empty();
      for (int c = 0; c < BuildPlan.cols; c++) {
        plan.set(c, 0, BuildMaterial.plank);
      }
      final raft = Raft(
        playerIndex: 0,
        x: BattleConst.playerX,
        loadout:
            RaftLoadout.custom(hullId: 'log', sizeId: 'small', colorIndex: 0),
        look: CrewLook.player,
        label: 'P',
        facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      );
      raft.build = plan;
      w.addRaft(raft);

      var onDeck = 0;
      for (int c = 0; c < BuildPlan.cols; c++) {
        final x = BuildPlan.columnX(c);
        if (raft.buildColumnOnDeck(c)) {
          onDeck++;
          expect(x.abs() + BuildPlan.cellW / 2, lessThanOrEqualTo(raft.deckHalf + 0.01));
        } else {
          // A column off the deck contributes no floor, so nothing can be
          // walked out over the water on it.
          final surface = raft.surfaceY(x);
          expect(surface == null || surface == 0, true,
              reason: 'column $c is off the deck but still a floor');
        }
      }
      expect(onDeck, greaterThan(0),
          reason: 'even the narrowest hull should build something');
    });

    test('a wide hull builds the whole grid', () {
      final w = BattleWorld(map: GameMaps.all.first, seed: 11);
      final raft = Raft(
        playerIndex: 0,
        x: BattleConst.playerX,
        loadout: RaftLoadout.custom(
            hullId: 'barge', sizeId: 'large', colorIndex: 0),
        look: CrewLook.player,
        label: 'P',
        facing: 1,
        crew: [Crew(hp: 100, maxHp: 100)],
      );
      w.addRaft(raft);
      for (int c = 0; c < BuildPlan.cols; c++) {
        expect(raft.buildColumnOnDeck(c), true,
            reason: 'a large barge should fit the whole grid');
      }
    });
  });
  group('The structure is a floor', () {
    test('crew stand on top of what was built', () {
      final p = BuildPlan.empty();
      p.set(4, 0, BuildMaterial.plank);
      p.set(4, 1, BuildMaterial.plank);
      final w = world(plan: p);
      final raft = w.rafts[0];
      final x = BuildPlan.columnX(4);
      // Two blocks up, measured as a rise above the planks.
      expect(-raft.surfaceY(x)!, closeTo(2 * BuildPlan.cellH, 0.01));
    });

    test('bare deck is unchanged where nothing was built', () {
      final p = BuildPlan.empty();
      p.set(0, 0, BuildMaterial.plank);
      final w = world(plan: p);
      final raft = w.rafts[0];
      final bare = BuildPlan.columnX(BuildPlan.cols - 1);
      final noBuild = world().rafts[0];
      expect(raft.surfaceY(bare), closeTo(noBuild.surfaceY(bare)!, 0.01));
    });

    test('a gap in a column stops the floor above it', () {
      // Once a block is shot out, what was above it is no longer standing on
      // anything — so it cannot be walked on either. That is what makes
      // taking the bottom out of a tower worth doing.
      final p = BuildPlan.empty();
      for (int r = 0; r < 3; r++) {
        p.set(4, r, BuildMaterial.plank);
      }
      final x = BuildPlan.columnX(4);
      expect(p.riseAt(x), closeTo(3 * BuildPlan.cellH, 0.01));

      // Knock out the bottom one.
      p.damageAt(x, BuildPlan.cellH * 0.5, 9999);
      expect(p.riseAt(x), 0,
          reason: 'the tower still reads as standing after its base went');
    });
  });

  group('The structure is a wall', () {
    /// Fires a flat shot into the built wall and returns what it hit.
    BuildCell? shootAt(BattleWorld w, int col, int row, {String weapon = 'bomb'}) {
      final raft = w.rafts[0];
      final cx = raft.x + BuildPlan.columnX(col);
      final cy = raft.deckY - (row + 0.5) * BuildPlan.cellH;
      w.fire(
        from: Offset(cx + 320, cy),
        angleDeg: 0,
        power: 95,
        weapon: Weapons.byId(weapon),
        facing: -1,
        owner: 1,
      );
      ShotOutcome? out;
      for (int f = 0; f < 900 && out == null; f++) {
        out = w.stepShot();
      }
      return raft.build?.at(col, row);
    }

    test('a shot damages the block it hits', () {
      final p = BuildPlan.empty();
      p.set(4, 0, BuildMaterial.iron);
      final w = world(plan: p);
      final before = p.at(4, 0)!.hp;
      shootAt(w, 4, 0);
      expect(p.at(4, 0)!.hp, lessThan(before),
          reason: 'the round went straight through the wall');
    });

    test('a weak material goes in one hit and a tough one does not', () {
      for (final (material, survives) in [
        (BuildMaterial.thatch, false),
        (BuildMaterial.iron, true),
      ]) {
        final p = BuildPlan.empty();
        p.set(4, 0, material);
        final w = world(plan: p);
        shootAt(w, 4, 0, weapon: 'bomb');
        expect(p.at(4, 0)!.broken, !survives,
            reason: '${material.name} came out of one bomb '
                '${p.at(4, 0)!.broken ? "destroyed" : "intact"}');
      }
    });

    test('breaking the base brings down what it was holding', () {
      final p = BuildPlan.empty();
      p.set(4, 0, BuildMaterial.thatch); // weak base
      p.set(4, 1, BuildMaterial.iron); // tough, but standing on nothing
      final w = world(plan: p);
      shootAt(w, 4, 0);
      expect(p.at(4, 0)!.broken, true);
      expect(p.at(4, 1)!.broken, true,
          reason: 'the block above stayed up with nothing under it');
    });

    test('it takes the damage instead of the crew behind it', () {
      // Cover has to work, or there is no reason to build anything.
      final p = BuildPlan.empty();
      for (int r = 0; r < BuildPlan.rows; r++) {
        p.set(4, r, BuildMaterial.iron);
      }
      final w = world(plan: p);
      final crew = w.rafts[0].crew[0];
      final before = crew.hp;
      // Fired at the wall, not over it.
      shootAt(w, 4, 1, weapon: 'tennis');
      expect(crew.hp, before,
          reason: 'the crew took damage through a solid iron wall');
    });

    test('how wrecked it is can be read off it', () {
      final p = BuildPlan.empty();
      for (int c = 2; c < 6; c++) {
        p.set(c, 0, BuildMaterial.thatch);
      }
      expect(p.intactFraction, 1.0);
      p.damageAt(BuildPlan.columnX(2), 5, 9999);
      expect(p.intactFraction, closeTo(0.75, 0.01));
    });
  });
}
