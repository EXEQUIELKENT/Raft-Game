import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// This game's id on the shared backend.
///
/// The online server hosts more than one title from one deployment (see
/// its `GAMES` list). Everything account-, friend- and matchmaking-shaped
/// is filtered by this, which is what stops a Raft captain being paired
/// with a Battleship one — the relay carries opaque JSON lines and would
/// otherwise happily deliver one game's protocol into the other's client.
const String kGameId = 'raft';

/// Finds the game server on the local network without anybody typing an
/// address.
///
/// The server is this project's own PHP backend, so its path under the
/// web root is fixed — only WHICH machine answers varies. Discovery walks
/// the obvious candidates first (the address remembered from last time,
/// localhost, the Android-emulator host) and then sweeps every address on
/// the device's own /24 subnet, asking each one `ping` until exactly the
/// right service answers back.
///
/// The sweep costs a couple of seconds worst case: addresses are probed
/// in parallel batches with sub-second timeouts, and the search stops
/// dead at the first machine that lists this game in its `ping`.
class ServerDiscovery {
  /// Where api.php sits under any web root running this project.
  static const serverPath = '/Battle-Ship-Blitz-Mobile-Game/server';

  static const _probeTimeout = Duration(milliseconds: 700);

  /// How many addresses are probed at once. Wide enough that a full /24
  /// finishes in a handful of waves (~250 hosts / 32 ≈ 8 waves ≈ 5 s),
  /// narrow enough not to drown a phone's radio or trip stingy routers.
  static const _batchSize = 32;

  /// The server address baked into the build itself.
  ///
  /// Defaults to this project's own tunnel so a plain `flutter build` or
  /// `flutter run` — no flags needed — always finds it, from anywhere.
  /// Override for a different server without touching this file:
  ///
  ///   flutter build apk --release \
  ///     --dart-define=RAFT_SERVER=https://my-tunnel.example/server
  ///
  /// Release players never see an address — the app opens, pings this one
  /// machine, and FIND A MATCH just works, even far outside the builder's
  /// Wi-Fi where subnet sweeping is useless. Blank this default out again
  /// (empty string) to go back to LAN-only discovery for dev builds.
  static const bakedUrl = String.fromEnvironment(
    'RAFT_SERVER',
    defaultValue:
        'https://envious-dropbox-taste.ngrok-free.dev/Battle-Ship-Blitz-Mobile-Game/server',
  );

  /// Returns the base URL of the game server (no trailing slash, no
  /// `api.php`), or null if nothing out there answered. [known] — usually
  /// the address remembered from a previous session — is tried first so
  /// an unchanged network reconnects instantly instead of sweeping.
  Future<String?> discover({String? known}) async {
    for (final base in [
      bakedUrl,
      if (known != null) known,
    ]) {
      if (base.trim().isEmpty) continue;
      final normalized = _normalize(base);
      if (await _answers(normalized)) return normalized;
    }
    for (final base in _specials()) {
      if (await _answers(base)) return base;
    }
    // One subnet at a time — a phone on Wi-Fi and mobile data holds two,
    // and only one of them can see the server.
    for (final candidates in await _subnetCandidates()) {
      final hit = await _sweep(candidates);
      if (hit != null) return hit;
    }
    return null;
  }

  /// Addresses worth trying before any sweep: this very machine (desktop
  /// builds) and the Android emulator's alias for its host.
  Iterable<String> _specials() sync* {
    yield 'http://127.0.0.1$serverPath';
    yield 'http://10.0.2.2$serverPath';
  }

  /// True when this device has some route to the wider internet.
  ///
  /// A single DNS resolution is enough: it costs milliseconds, needs no
  /// third-party packages, and unlike pinging any one site it does not
  /// care WHICH provider the phone is on. A captive portal that answers
  /// DNS but drops traffic still counts as online here — the follow-up
  /// server probe is what actually decides reachability.
  Future<bool> hasInternet() async {
    if (kIsWeb) return true;
    try {
      final result = await InternetAddress.lookup('example.com')
          .timeout(const Duration(seconds: 4));
      return result.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Every other address of each IPv4 /24 this device belongs to, as one
  /// candidate list per interface. Loopback and link-local are excluded;
  /// the device's own address is skipped (it cannot be hosting Apache).
  Future<List<List<String>>> _subnetCandidates() async {
    if (kIsWeb) return const [];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      final perInterface = <List<String>>[];
      for (final iface in ifaces) {
        final candidates = <String>[];
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final octets = addr.address.split('.');
          if (octets.length != 4) continue;
          for (var i = 1; i <= 254; i++) {
            final host = '${octets[0]}.${octets[1]}.${octets[2]}.$i';
            if (host == addr.address) continue;
            candidates.add('http://$host$serverPath');
          }
        }
        // Ascending from .1, so gateways — common homes for servers —
        // are naturally probed first.
        if (candidates.isNotEmpty) perInterface.add(candidates);
      }
      return perInterface;
    } catch (_) {
      return const [];
    }
  }

  /// Probes a candidate list in parallel batches, returning the winner —
  /// or null once every batch came back silent.
  Future<String?> _sweep(List<String> candidates) async {
    for (var i = 0; i < candidates.length; i += _batchSize) {
      final batch = candidates.skip(i).take(_batchSize).toList();
      final answers = await Future.wait(
        batch.map((base) async => await _answers(base) ? base : null),
      );
      for (final base in answers) {
        if (base != null) return base;
      }
    }
    return null;
  }

  String _normalize(String url) {
    var base = url.trim();
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'http://$base';
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  String _endpoint(String base) {
    final b = _normalize(base);
    return b.endsWith('.php') ? b : '$b/api.php';
  }

  /// True when [base] is a server this game can actually use.
  ///
  /// One deployment serves several titles, so "is a game server" is not
  /// enough — it has to be one that knows about *this* game. `ping`
  /// advertises the list, and the check is for our own id inside it.
  /// (`service` is still the older single-game marker; it is deliberately
  /// not what we match on.)
  Future<bool> _answers(String base) async {
    if (kIsWeb) return false;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = _probeTimeout;
      final request = await client
          .postUrl(Uri.parse(_endpoint(base)))
          .timeout(_probeTimeout);
      request.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      request.write(jsonEncode({'a': 'ping'}));
      final response = await request.close().timeout(_probeTimeout);
      final text =
          await utf8.decoder.bind(response).join().timeout(_probeTimeout);
      final body = jsonDecode(text);
      if (body is! Map || body['ok'] != true) return false;
      final games = body['games'];
      return games is List && games.contains(kGameId);
    } catch (_) {
      return false;
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }
}
