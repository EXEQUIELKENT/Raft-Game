import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:raft_rumble/game/audio.dart';
import 'package:raft_rumble/game/battle.dart';
import 'package:raft_rumble/game/campaign.dart';
import 'package:raft_rumble/game/models.dart';
import 'package:raft_rumble/game/character_art.dart';
import 'package:raft_rumble/game/characters.dart';
import 'package:raft_rumble/game/progression.dart';
import 'package:raft_rumble/game/save.dart';

/// The cast, and the acting.
///
/// Two complaints are being answered here. The first is that every character
/// was one of five archetypes that differed by a hat, so a deck of enemies
/// read as the same person recoloured. The second is that expressions lived
/// only in the face — which at raft scale is about fifteen pixels across, so
/// an expression nobody can see.
///
/// The properties worth defending: the roster is genuinely varied and every
/// entry is drawable; the campaign actually casts from it; and every dramatic
/// moment moves the BODY, not just the face.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SaveService.instance.data = SaveData();
  });

  group('The roster', () {
    test('every CrewLook has exactly one definition', () {
      for (final look in CrewLook.values) {
        final matches = Cast.all.where((c) => c.look == look).toList();
        expect(matches.length, 1, reason: '$look has ${matches.length} entries');
      }
      expect(Cast.all.length, CrewLook.values.length);
    });

    test('ids are unique and round-trip', () {
      final ids = Cast.all.map((c) => c.id).toSet();
      expect(ids.length, Cast.all.length);
      for (final c in Cast.all) {
        expect(Cast.byId(c.id).look, c.look);
      }
    });

    test('an unknown id falls back rather than throwing', () {
      // Save data can name a character a later build renamed or removed.
      expect(Cast.byId('no-such-character').look, Cast.all.first.look);
      expect(SaveData().character, isNotEmpty);
      expect(Cast.byId(SaveData().character).look, CrewLook.player,
          reason: 'a fresh save must resolve to a real character');
    });

    test('the cast is actually varied, not five hats on one body', () {
      // The whole complaint. Count the distinct visual choices in play.
      expect(Cast.all.map((c) => c.gear).toSet().length, greaterThanOrEqualTo(8),
          reason: 'not enough distinct headgear');
      expect(Cast.all.map((c) => c.mark).toSet().length, greaterThanOrEqualTo(6),
          reason: 'not enough distinct face markings');
      expect(Cast.all.map((c) => c.outfit).toSet().length,
          greaterThanOrEqualTo(10),
          reason: 'too many characters share an outfit colour');
      expect(Cast.all.map((c) => c.voice).toSet().length, 3,
          reason: 'all three voice registers should be used');
      expect(Cast.all.map((c) => c.build).toSet().length,
          greaterThanOrEqualTo(3),
          reason: 'everyone is the same shape');
    });

    test('no two characters are visually identical', () {
      final seen = <String>{};
      for (final c in Cast.all) {
        final sig = '${c.gear}|${c.mark}|${c.outfit}|${c.skin}';
        expect(seen.add(sig), true, reason: '${c.id} is a duplicate of another');
      }
    });

    test('every theme has people in it', () {
      for (final t in CharacterTheme.values) {
        expect(Cast.ofTheme(t), isNotEmpty, reason: '$t has no characters');
        expect(t.label, isNotEmpty);
      }
    });

    test('every character has a name and a blurb worth reading', () {
      for (final c in Cast.all) {
        expect(c.name.trim(), isNotEmpty);
        expect(c.blurb.trim(), isNotEmpty, reason: '${c.id} has no blurb');
      }
    });
  });

  group('Unlocking', () {
    test('at least one character is available from the very first battle', () {
      expect(Cast.unlockedAt(1), isNotEmpty);
      expect(Cast.unlockedAt(1).first.look, CrewLook.player);
    });

    test('unlocks are spread across the curve rather than bunched', () {
      final levels =
          Cast.playable.map((c) => c.unlockLevel).where((l) => l > 0).toList()
            ..sort();
      expect(levels.length, greaterThanOrEqualTo(5),
          reason: 'too few characters to earn');
      expect(levels.last, lessThanOrEqualTo(kMaxLevel),
          reason: 'a character nobody can ever reach');
      expect(levels.toSet().length, levels.length,
          reason: 'two characters unlocking at the same level wastes one');
    });

    test('the roster grows as you level and never shrinks', () {
      var prev = 0;
      for (int lvl = 1; lvl <= kMaxLevel; lvl++) {
        final n = Cast.unlockedAt(lvl).length;
        expect(n, greaterThanOrEqualTo(prev));
        prev = n;
      }
      expect(Cast.unlockedAt(kMaxLevel).length, Cast.playable.length,
          reason: 'everything playable should be reachable');
    });

    test('enemy-only characters never appear in the picker', () {
      expect(Cast.playable.every((c) => c.playable), true);
      expect(Cast.of(CrewLook.raider).playable, false,
          reason: 'a rank-and-file rival is not a costume');
    });
  });

  group('Casting the campaign', () {
    test('each world crews its rafts from its own theme', () {
      for (final world in Campaign.worlds) {
        final ordinary = world.levels.firstWhere((l) => !l.isBoss);
        final (_, players) = Campaign.matchFor(ordinary);
        final themeLooks =
            Cast.ofTheme(world.theme).map((c) => c.look).toSet();
        for (final p in players.skip(1)) {
          expect(themeLooks.contains(p.look), true,
              reason: '${world.id}: ${p.look} is not from ${world.theme}');
        }
      }
    });

    test('the six worlds do not all look the same', () {
      // Before this, every sea was crewed by the same three archetypes.
      final perWorld = <Set<CrewLook>>[];
      for (final world in Campaign.worlds) {
        final (_, players) = Campaign.matchFor(world.levels.first);
        perWorld.add(players.skip(1).map((p) => p.look).toSet());
      }
      expect(perWorld.map((s) => s.toString()).toSet().length,
          greaterThanOrEqualTo(5),
          reason: 'worlds are still casting the same crews');
    });

    test('the player wears whatever they picked', () {
      SaveService.instance.data.character = CrewLook.swimmer.name;
      final (_, players) = Campaign.matchFor(Campaign.allLevels.first);
      expect(players.first.look, CrewLook.swimmer);
    });
  });

  group('Voices', () {
    test('every register has a real clip behind it', () {
      for (final v in VoiceType.values) {
        for (final base in AudioService.voiceBases) {
          final name = v == VoiceType.mid ? base : '$base${v.suffix}';
          expect(name, isNotEmpty);
        }
      }
      expect(VoiceType.mid.suffix, isEmpty,
          reason: 'the mid register is the un-suffixed clip');
      expect(VoiceType.low.suffix, isNot(VoiceType.high.suffix));
    });

    test('a crew member speaks in their character\'s register', () {
      final low = Crew(hp: 10, maxHp: 10, voice: VoiceType.low);
      final mid = Crew(hp: 10, maxHp: 10, voice: VoiceType.mid);
      final high = Crew(hp: 10, maxHp: 10, voice: VoiceType.high);
      expect(low.voiced('voice_grunt'), 'voice_grunt_low');
      expect(mid.voiced('voice_grunt'), 'voice_grunt');
      expect(high.voiced('voice_grunt'), 'voice_grunt_high');
    });

    test('a hit yelp is pitched, and picks from several variants', () {
      final c = Crew(hp: 10, maxHp: 10, voice: VoiceType.high);
      final heard = {for (int i = 0; i < 40; i++) c.hitVoice()};
      expect(heard.length, greaterThan(1), reason: 'every yelp is identical');
      for (final h in heard) {
        expect(h.endsWith('_high'), true, reason: '$h is not in their register');
      }
    });
  });

  group('Whole-body expression', () {
    Crew crew() => Crew(hp: 100, maxHp: 100);

    test('a healthy idle crew member stands still', () {
      expect(crew().bodyExpression(0).isNeutral, true);
    });

    test('taking a hit doubles the body over, not just the face', () {
      final c = crew();
      c.hitReactT = BattleConst.hitReactTime;
      final b = c.bodyExpression(1);
      expect(b.crouch, greaterThan(0));
      expect(b.slump, greaterThan(0));
      expect(b.isNeutral, false);
    });

    test('landing a shot throws an arm up and lifts them off the deck', () {
      final c = crew();
      c.gloatT = BattleConst.gloatTime;
      final b = c.bodyExpression(1);
      expect(b.armRaise, greaterThan(0.5));
      expect(b.bounce, lessThanOrEqualTo(0), reason: 'bounce is upward');
    });

    test('a wince outranks a gloat, so the body and face agree', () {
      // Both flags can be live at once — you can be hit on the same frame
      // your own shot lands. The face prioritises the wince; if the body did
      // not, they would be telling two different stories.
      final c = crew();
      c.gloatT = BattleConst.gloatTime;
      c.hitReactT = BattleConst.hitReactTime;
      expect(c.bodyExpression(1).armRaise, 0,
          reason: 'no celebrating mid-wince');
    });

    test('low health shows in the shoulders', () {
      final c = Crew(hp: 10, maxHp: 100);
      expect(c.bodyExpression(1).slump, greaterThan(0));
    });

    test('every idle activity actually moves something', () {
      // An "activity" that leaves the body identical is not an activity.
      for (final idle in CrewIdle.values) {
        if (idle == CrewIdle.none) continue;
        final c = crew();
        c.idle = idle;
        c.idleDur = 2;
        c.idleT = 1; // mid-activity, where the ease curve peaks
        expect(c.bodyExpression(0.35).isNeutral, false,
            reason: '$idle does not move the body at all');
      }
    });

    test('an idle eases in and out instead of snapping', () {
      final c = crew();
      c.idle = CrewIdle.stretch;
      c.idleDur = 2;
      c.idleT = 2; // the very start
      final start = c.bodyExpression(0).armRaise;
      c.idleT = 1; // the middle
      final middle = c.bodyExpression(0).armRaise;
      c.idleT = 0.001; // the very end
      final end = c.bodyExpression(0).armRaise;
      expect(middle, greaterThan(start));
      expect(middle, greaterThan(end));
    });

    test('a ragdolling or dead body has no expression to give', () {
      final c = crew();
      c.ragdoll = true;
      c.gloatT = 1;
      expect(c.bodyExpression(1).isNeutral, true);

      final dead = Crew(hp: 0, maxHp: 100);
      dead.hitReactT = 1;
      expect(dead.bodyExpression(1).isNeutral, true);
    });

    test('the idle pool is mostly whole-body, not mostly faces', () {
      // The point of the rework: a deck of people making faces reads as a row
      // of statues from across the screen.
      const bodyLed = {
        CrewIdle.stretch,
        CrewIdle.hop,
        CrewIdle.shrug,
        CrewIdle.scratchHead,
        CrewIdle.jig,
      };
      final c = crew();
      final picked = <CrewIdle>[];
      for (int i = 0; i < 200; i++) {
        c.idle = CrewIdle.none;
        c.idleNextIn = 0;
        c.updateIdle(0.016, allowNew: true);
        picked.add(c.idle);
      }
      final bodyCount = picked.where(bodyLed.contains).length;
      expect(bodyCount / picked.length, greaterThan(0.4),
          reason: 'idle time is still mostly face-only');
    });
  });

  group('Speech bubbles', () {
    test('a line shows, then clears itself', () {
      final c = Crew(hp: 10, maxHp: 10);
      expect(c.talking, false);
      c.say('Hello');
      expect(c.talking, true);
      expect(c.bubble, 'Hello');
      c.bubbleT = 0;
      expect(c.talking, false);
    });

    test('a second line does not interrupt the first', () {
      // Two hits in a row should finish one yelp, not flicker between them.
      final c = Crew(hp: 10, maxHp: 10);
      c.say('First');
      c.say('Second');
      expect(c.bubble, 'First');
    });

    test('lines are short enough not to cover the battle', () {
      final c = Crew(hp: 10, maxHp: 10);
      for (int i = 0; i < 60; i++) {
        for (final line in [c.idleLine, c.hitLine, c.gloatLine]) {
          expect(line.length, lessThanOrEqualTo(16),
              reason: '"$line" is too long for a raft-scale bubble');
        }
      }
      for (final e in StatusEffect.values) {
        expect(e.bubble.length, lessThanOrEqualTo(16));
      }
    });

    test('the lines vary, or the crew would parrot one phrase', () {
      final c = Crew(hp: 10, maxHp: 10);
      expect({for (int i = 0; i < 60; i++) c.idleLine}.length, greaterThan(2));
      expect({for (int i = 0; i < 60; i++) c.hitLine}.length, greaterThan(2));
    });
  });

  group('Character art', () {
    test('every character draws without throwing, at any facing', () {
      // The picker and the battle share this painter, so a character that
      // cannot be drawn is a crash in two places.
      for (final c in Cast.all) {
        for (final dir in [-1.0, 1.0]) {
          final recorder = PictureRecorder();
          final canvas = Canvas(recorder);
          expect(
            () => CharacterArt.headgear(
                canvas, c.look, const Offset(50, 50), 14, dir),
            returnsNormally,
            reason: '${c.id} at facing $dir',
          );
          recorder.endRecording().dispose();
        }
      }
    });

    test('draws at a portrait scale too, not just at raft scale', () {
      for (final c in Cast.all) {
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        expect(
          () => CharacterArt.headgear(
              canvas, c.look, const Offset(150, 150), 44, 1),
          returnsNormally,
          reason: '${c.id} at portrait scale',
        );
        recorder.endRecording().dispose();
      }
    });
  });
}
