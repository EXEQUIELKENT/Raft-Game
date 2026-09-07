import 'package:flutter/material.dart';

import '../game/characters.dart';
import '../game/controller.dart';
import '../game/match_store.dart';
import '../game/maps.dart';
import '../game/net.dart';
import '../game/raft.dart';
import '../game/save.dart';
import 'game_screen.dart';

/// Launching a networked match, shared by both transports.
///
/// A hotspot match and an online one are the same match: the host settles the
/// map, the starting HP, the seed and BOTH rafts, sends them in one `start`
/// message, and each device builds an identical [GameController] from it.
/// Only the [GameLink] underneath differs, so this file has no idea which one
/// is carrying it.
///
/// Both rafts travel in that message on purpose. Every device simulates the
/// whole battle locally and only exchanges shots, so the two simulations have
/// to start from byte-identical state. Reading the host's raft from *this*
/// device's save — which is what the code did before there was anything but
/// hotspot — gave each side a different hull for the host, and a hull decides
/// the deck's height-field and therefore where the crew stand: the same shot
/// then hit on one screen and missed on the other.
class NetMatchSetup {
  final MatchSettings settings;
  final List<PlayerConfig> players;
  final int seed;

  const NetMatchSetup({
    required this.settings,
    required this.players,
    required this.seed,
  });

  /// The host's `start` payload: everything the guest needs to build the
  /// identical match.
  static Map<String, dynamic> startPayload({
    required MapDef map,
    required double startHp,
    required int seed,
    required RaftLoadout hostRaft,
    required RaftLoadout guestRaft,
    required String hostName,
    CrewLook hostLook = CrewLook.player,
    CrewLook guestLook = CrewLook.raider,
  }) =>
      {
        't': 'start',
        'map': map.id,
        'hp': startHp,
        'seed': seed,
        'hostName': hostName,
        'host': _raftJson(hostRaft),
        'guest': _raftJson(guestRaft),
        // Who each side sails as. Characters differ in more than colour —
        // build changes the drawn body and voice changes what it sounds
        // like — so like the rafts they have to travel in the start message
        // rather than being read from each device's own save.
        'hostLook': hostLook.name,
        'guestLook': guestLook.name,
      };

  /// Rebuilds the match from a `start` message. Every field is optional and
  /// falls back to something playable: a malformed or older message must not
  /// strand a player on a black screen.
  static NetMatchSetup fromStart(
    Map<String, dynamic> msg, {
    required String guestName,
  }) {
    final hp = msg['hp'];
    final seed = msg['seed'];
    return NetMatchSetup(
      settings: MatchSettings(
        map: GameMaps.byId(msg['map'] as String? ?? GameMaps.all.first.id),
        startHp: hp is num ? hp.toDouble() : 100,
        turnSeconds: 30,
      ),
      players: [
        PlayerConfig(
          name: (msg['hostName'] as String?)?.toUpperCase() ?? 'HOST',
          loadout: _raftFrom(msg['host'], fallbackColor: 0),
          look: _lookFrom(msg['hostLook'], CrewLook.player),
          netId: 0,
        ),
        PlayerConfig(
          name: guestName.toUpperCase(),
          loadout: _raftFrom(msg['guest'], fallbackColor: 1),
          look: _lookFrom(msg['guestLook'], CrewLook.raider),
          netId: 1,
        ),
      ],
      seed: seed is int ? seed : DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// The host's own view of the match it just announced.
  static NetMatchSetup forHost({
    required MapDef map,
    required double startHp,
    required int seed,
    required RaftLoadout hostRaft,
    required RaftLoadout guestRaft,
    required String hostName,
    required String guestName,
    CrewLook hostLook = CrewLook.player,
    CrewLook guestLook = CrewLook.raider,
  }) =>
      NetMatchSetup(
        settings: MatchSettings(map: map, startHp: startHp, turnSeconds: 30),
        players: [
          PlayerConfig(
              name: hostName.toUpperCase(),
              loadout: hostRaft,
              look: hostLook,
              netId: 0),
          PlayerConfig(
              name: guestName.toUpperCase(),
              loadout: guestRaft,
              look: guestLook,
              netId: 1),
        ],
        seed: seed,
      );

  static Map<String, dynamic> _raftJson(RaftLoadout lo) => {
        'hull': lo.hull.id,
        'size': lo.size.id,
        'color': lo.colorIndex,
      };

  /// Reads a character id out of a start message, falling back for an older
  /// or malformed one rather than throwing — a message from a build that
  /// predates the roster simply gets the default cast.
  static CrewLook lookOf(Object? raw, CrewLook fallback) => _lookFrom(raw, fallback);

  static CrewLook _lookFrom(Object? raw, CrewLook fallback) {
    if (raw is! String) return fallback;
    for (final l in CrewLook.values) {
      if (l.name == raw) return l;
    }
    return fallback;
  }

  static RaftLoadout _raftFrom(Object? raw, {required int fallbackColor}) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    return RaftLoadout.custom(
      hullId: m['hull'] as String? ?? 'tube',
      sizeId: m['size'] as String? ?? 'medium',
      colorIndex: (m['color'] as num?)?.toInt() ?? fallbackColor,
    );
  }
}

/// Builds the controller and pushes the battle, replacing the lobby.
///
/// The controller is created here rather than inside [GameScreen] so it can
/// take over `net.onMessage` before the first frame — a shot arriving during
/// the route transition would otherwise land while the lobby still owned the
/// callback, and be dropped.
void launchNetMatch(
  BuildContext context, {
  required NetService net,
  required NetMatchSetup setup,
  Map<String, dynamic>? startPayload,
  Map<String, dynamic>? restore,
}) {
  final mode = net.mode == NetMode.online ? GameMode.online : GameMode.hotspot;
  final controller = GameController(
    settings: setup.settings,
    players: setup.players,
    mode: mode,
    net: net,
    seed: setup.seed,
  );
  // Put a resumed match back where it left off before the first frame, so
  // nobody sees a full-health opening state flash past.
  if (restore != null) controller.restoreState(restore);
  // Track it from here on, so closing the app mid-battle is recoverable.
  if (startPayload != null) {
    MatchStore.instance.attach(controller, net, start: startPayload);
  }
  Navigator.pushReplacement(
    context,
    MaterialPageRoute(
      builder: (_) => GameScreen(
        settings: setup.settings,
        players: setup.players,
        mode: mode,
        seed: setup.seed,
        controller: controller,
      ),
    ),
  );
}

/// The raft this device sails, as configured in the campaign/customiser.
RaftLoadout myRaft() => SaveService.instance.data.raftLoadout;

/// The character this device sails as.
CrewLook myLook() => Cast.byId(SaveService.instance.data.character).look;

/// The display name this device goes by.
String myName() {
  final n = SaveService.instance.data.playerName.trim();
  return n.isEmpty ? 'Captain' : n;
}
