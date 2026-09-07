import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Thrown for anything the online server refuses or cannot answer. The
/// message is already written for a player to read — the API hands back
/// human sentences ("No captain with that code.") rather than codes.
class OnlineError implements Exception {
  final String message;

  /// True when the request never reached the server at all, as opposed to
  /// being rejected by it. The lobby uses this to say "can't reach the
  /// server" instead of blaming the player's input.
  final bool offline;

  /// HTTP status the server answered with, where there was one.
  final int status;

  const OnlineError(this.message, {this.offline = false, this.status = 0});

  /// The saved token means nothing to this server — it was issued by a
  /// different one, or the account behind it is gone. Recoverable by
  /// registering again, which is what [OnlineService.ensureAccount] does.
  bool get needsSignIn => status == 401;

  @override
  String toString() => message;
}

/// Thin JSON-over-HTTP client for `server/api.php`.
///
/// Deliberately built on `dart:io`'s own [HttpClient] rather than pulling
/// in `package:http`: the whole surface is one POST with a JSON body, and
/// this project pins its dependency versions on purpose.
class OnlineApi {
  /// Where the game's server lives, e.g.
  /// `http://192.168.1.7/Battle-Ship-Blitz-Mobile-Game/server`. Set from the
  /// online lobby and remembered in local storage.
  String baseUrl = '';

  /// Which title this client is.
  ///
  /// One deployment serves more than one game (see the server's `GAMES`
  /// list), so the address alone does not say who is calling. This is sent
  /// with every request; the server files a new account under it at
  /// `register` time and derives it from the token thereafter. It is the
  /// single thing keeping Raft captains from being matched against — or
  /// even able to search for — Battleship ones on a shared server.
  String game = 'raft';

  /// This installation's login token, handed out by `register` and kept
  /// in local storage from then on.
  String? token;

  bool get configured => baseUrl.trim().isNotEmpty;

  /// One [HttpClient] reused for every call, instead of a fresh one per
  /// request.
  ///
  /// `relay_poll` alone fires roughly once every few seconds for as long
  /// as a match is running, and a new [HttpClient] each time meant a
  /// full TCP handshake (and, over HTTPS, a TLS handshake on top of
  /// that) paid before the request's own round trip even started — pure
  /// added latency, and the single biggest one on the online path since
  /// it lands on every poll and every shot fired. Keeping one client
  /// open lets it pool a persistent connection per host and reuse it
  /// turn after turn.
  HttpClient? _client;

  HttpClient _httpClient() => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    // Long enough that the pooled connection survives the gap between
    // an ordinary lobby/matchmaking call and the next one a few seconds
    // later; a live match's own poll-then-immediately-repoll loop never
    // goes idle long enough for this to matter.
    ..idleTimeout = const Duration(seconds: 30)
    // A live match holds one connection almost permanently in `relay_poll`
    // (server-side hold up to 8s, immediately re-issued) while `relay_send`
    // fires opportunistically on top of it. Left at the default of 1, the
    // pool has exactly one warm connection and a concurrent send has to
    // either wait for the held poll to finish or open a fresh one anyway —
    // so the "reuse a pooled connection" win this client exists for was
    // only reliable by luck. A small explicit ceiling keeps a send and a
    // poll each able to hold their own warm connection instead of
    // contending for the one the pool happened to keep.
    ..maxConnectionsPerHost = 4;

  /// Drops the pooled connection. Call when finished talking to the
  /// server for good (see [OnlineService.dispose]) — never between
  /// ordinary calls, which would defeat the reuse [_httpClient] exists
  /// for.
  void close() {
    _client?.close(force: true);
    _client = null;
  }

  /// The endpoint URL, tolerating a base that does or doesn't already
  /// point at `api.php` and with or without a trailing slash — people
  /// paste all three shapes.
  Uri get _endpoint {
    var base = baseUrl.trim();
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'http://$base';
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (!base.endsWith('.php')) base = '$base/api.php';
    return Uri.parse(base);
  }

  /// Calls one action. [timeout] is generous for the long-polling relay
  /// endpoint, which deliberately holds the connection open.
  Future<Map<String, dynamic>> call(
    String action, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 12),
    bool authed = true,
  }) async {
    if (!configured) {
      throw const OnlineError(
        'No game server set — enter its address first.',
        offline: true,
      );
    }
    final payload = <String, dynamic>{'a': action, 'game': game, ...args};
    if (authed && token != null) payload['token'] = token;

    final client = _httpClient();
    try {
      final request = await client.postUrl(_endpoint).timeout(timeout);
      request.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      // Encoded to bytes and the length set explicitly, rather than
      // `request.write(jsonEncode(payload))`: without a known
      // `contentLength`, `dart:io` has no choice but to send the body
      // chunked — an extra length-prefix frame on every single request,
      // on the hottest path this client has (every shot fired, every
      // relay poll). Every payload here is one small JSON object built
      // and finished before anything is written, so the length is always
      // known up front; there is nothing chunked encoding buys here.
      final payload8 = utf8.encode(jsonEncode(payload));
      request.contentLength = payload8.length;
      request.add(payload8);
      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join().timeout(timeout);

      Map<String, dynamic> body;
      try {
        body = Map<String, dynamic>.from(jsonDecode(text) as Map);
      } catch (_) {
        // A PHP fatal error or an Apache error page — HTML, not JSON.
        // Saying so beats "FormatException: Unexpected character".
        throw OnlineError(
          response.statusCode >= 500
              ? 'The game server hit an error. Check its logs.'
              : 'That address does not look like the game server.',
          offline: true,
        );
      }
      if (body['ok'] != true) {
        throw OnlineError(
          (body['error'] as String?) ?? 'The server refused that.',
          status: response.statusCode,
        );
      }
      return body;
    } on OnlineError {
      rethrow;
    } on TimeoutException {
      throw const OnlineError('The game server did not answer in time.',
          offline: true);
    } on SocketException catch (e) {
      throw OnlineError(_friendly(e), offline: true);
    } on HttpException {
      // A connection torn down mid-request: a network handover, the server
      // restarting, or this client being closed under an in-flight call.
      // It has to arrive as an OnlineError like every other transport
      // failure, or it escapes RelayLink's poll loop — which only counts
      // OnlineErrors toward its retry budget — as an unhandled async error.
      throw const OnlineError('Lost the connection to the game server.',
          offline: true);
    } on HandshakeException {
      throw const OnlineError('Could not establish a secure connection.',
          offline: true);
    }
    // Deliberately no `finally { client.close(...) }` here any more —
    // the client outlives this single call so its connection can be
    // pooled and reused by the next one. See [close] for real teardown.
  }

  String _friendly(SocketException e) {
    final s = e.toString();
    if (s.contains('refused')) {
      return 'Nothing is listening there — is the server running?';
    }
    if (s.contains('Failed host lookup')) {
      return 'Cannot find that address. Check the server URL.';
    }
    if (s.contains('unreachable') || s.contains('Network is unreachable')) {
      return 'No route to the server — check this device is online.';
    }
    return 'Cannot reach the game server.';
  }
}
