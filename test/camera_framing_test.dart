import 'package:flutter_test/flutter_test.dart';

import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/maps.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/raft.dart';
import 'package:raft_rumble/game/save.dart';

/// The vertical camera on a terraced sea.
///
/// Two regressions are pinned here. A raft standing on a different terrace
/// from the camera anchor used to be cropped at the top (the view only ever
/// framed the anchor's own crew), and the view used to lag behind a rise or
/// fall because its easing changed rate abruptly part-way through the move.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SaveService.instance.data = SaveData());

  BattleWorld world(int seed, String hull) {
    final w = BattleWorld(map: GameMaps.all.first, seed: seed);
    for (int i = 0; i < 2; i++) {
      w.addRaft(Raft(
        playerIndex: i,
        x: i == 0 ? BattleConst.playerX : BattleConst.enemySlots.first,
        loadout:
            RaftLoadout.custom(hullId: hull, sizeId: 'medium', colorIndex: i),
        look: i == 0 ? CrewLook.player : CrewLook.raider,
        label: 'R$i',
        facing: i == 0 ? 1 : -1,
        crew: [Crew(hp: 100, maxHp: 100)],
      ));
    }
    w.viewWidth = 870;
    return w;
  }

  void settle(BattleWorld w, [int frames = 180]) {
    for (int f = 0; f < frames; f++) {
      w.update(1 / 60);
    }
  }

  group('Vertical camera framing', () {
    test('every raft in view is shown whole, whichever terrace it is on', () {
      for (final hull in ['log', 'galleon']) {
        for (int seed = 0; seed < 120; seed++) {
          final w = world(seed, hull);
          for (final raft in w.rafts) {
            // Camera sitting over this raft, anchor on the other one: the
            // case the opening sweep and a shot's flight both produce.
            w.camAnchor = raft.playerIndex == 0 ? 1 : 0;
            w.cam = w.camFor(raft.x);
            settle(w);
            final top = w.raftTopForTest(raft);
            expect(w.camY, lessThanOrEqualTo(top),
                reason: 'seed $seed ($hull): raft ${raft.playerIndex} is '
                    'cropped at the top (camY ${w.camY}, top $top)');
            expect(w.camY + BattleConst.viewH,
                greaterThanOrEqualTo(raft.waterLine),
                reason: 'seed $seed ($hull): raft ${raft.playerIndex} '
                    'has sunk below the bottom edge');
          }
        }
      }
    });

    test('the camera settles and stops, without creeping or overshooting', () {
      final w = world(3, 'log');
      w.camAnchor = 0;
      w.cam = w.camFor(w.rafts[1].x);
      settle(w, 240);
      final a = w.camY;
      settle(w, 30);
      expect(w.camY, closeTo(a, 0.01));
    });

    test('a large rise is one smooth move, not a sprint then a crawl', () {
      // Find a sea with a real step between the two rafts.
      for (int seed = 0; seed < 200; seed++) {
        final w = world(seed, 'log');
        final drop = (w.rafts[0].waterLine - w.rafts[1].waterLine).abs();
        if (drop < 50) continue;

        w.camAnchor = 0;
        w.cam = w.camFor(w.rafts[0].x);
        settle(w);
        final from = w.camY;
        w.cam = w.camFor(w.rafts[1].x);

        // Speed per frame, once the move is under way. It may rise and fall
        // but must never lurch: no frame may lose most of its speed to the
        // next while the camera is still well short of where it is going.
        var prev = 0.0;
        for (int f = 0; f < 90; f++) {
          final before = w.camY;
          w.update(1 / 60);
          final speed = (w.camY - before).abs();
          if (f > 3 && speed > 0.5) {
            expect(speed, greaterThan(prev * 0.5),
                reason: 'seed $seed: camera braked abruptly at frame $f');
          }
          prev = speed;
        }
        expect((w.camY - from).abs(), greaterThan(10),
            reason: 'the camera never moved to the other terrace');
        return;
      }
      fail('no seed produced a step between the rafts');
    });
  });
}
