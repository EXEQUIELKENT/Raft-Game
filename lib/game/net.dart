import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'multicast_lock.dart';
import 'online_api.dart';
import 'relay_link.dart';

/// TCP port used for hotspot (same Wi-Fi / mobile hotspot) matches.
const int kGamePort = 50505;

/// UDP port the room beacon is broadcast and listened for on.
const int kBeaconPort = 50506;

/// A room other players can find on the local network.
class RoomInfo {
  final String code;
  final String host;
  final String playerName;

  const RoomInfo({
    required this.code,
    required this.host,
    required this.playerName,
  });
}

/// A duplex channel carrying the game's JSON messages to the opponent.
///
/// Keeping the transport behind an interface is what lets a match be played
/// over a direct socket on a shared hotspot — or, later, over anything else
/// — without the game rules knowing or caring which one it is talking to.
abstract class GameLink {
  Stream<Map<String, dynamic>> get messages;
  void send(Map<String, dynamic> msg);
  Future<void> close();
}

/// Line-based JSON over a TCP socket.
///
/// Deliberately NOT a WebSocket. The previous implementation upgraded an
/// `HttpServer` connection to one, and that handshake is the first thing to
/// go wrong on a real hotspot: the upgrade needs a well-formed HTTP request,
/// and anything sitting in between (a carrier NAT, a captive-portal shim, a
/// VPN's tun interface, an OEM's power-saving proxy) is free to rewrite,
/// buffer or reject it — which is how two phones on the same hotspot ended up
/// unable to pair at all. A raw socket with one JSON object per line has no
/// handshake to break.
///
/// Framing is explicit because TCP is a stream, not a sequence of messages:
/// a `send` from either end can be split across packets or coalesced with the
/// next one, so the reader buffers and cuts on newlines. The old code read
/// whole WebSocket *messages*, which is why it got away without this.
class SocketLink implements GameLink {
  final Socket socket;
  final _in = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription? _sub;
  String _buffer = '';
  bool _closed = false;

  /// Fired exactly once when the connection goes away for any reason — peer
  /// closed it, app killed, network dropped.
  final void Function()? onClosed;

  SocketLink(this.socket, {this.onClosed}) {
    _sub = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen(_onData, onDone: close, onError: (_) => close());
  }

  void _onData(String chunk) {
    _buffer += chunk;
    int idx;
    while ((idx = _buffer.indexOf('\n')) >= 0) {
      final line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);
      if (line.isEmpty) continue;
      try {
        _in.add(Map<String, dynamic>.from(jsonDecode(line) as Map));
      } catch (_) {
        // Ignore malformed — a peer is not something to trust.
      }
    }
  }

  @override
  void send(Map<String, dynamic> msg) {
    try {
      socket.write('${jsonEncode(msg)}\n');
    } catch (_) {
      /* socket closed */
    }
  }

  @override
  Stream<Map<String, dynamic>> get messages => _in.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sub?.cancel();
      await socket.close();
    } catch (_) {}
    if (!_in.isClosed) await _in.close();
    onClosed?.call();
  }
}


/// Which transport a match is being carried over.
///
/// The distinction matters to almost nothing: both are [GameLink]s, and the
/// entire match protocol runs identically over either. It is here so the UI
/// can say the right words ("opponent disconnected" vs "reconnecting…") and
/// so a dropped LAN seat can be reopened for the peer to walk back into,
/// which has no meaning over the relay.
enum NetMode { none, hotspot, online }

/// One line of in-match chat.
///
/// Chat rides the ordinary match protocol as a `chat` message, so it works
/// over a hotspot socket and over the internet relay without either
/// transport knowing it exists.
class ChatLine {
  final String name;
  final String text;
  final bool mine;
  final DateTime at;

  ChatLine({
    required this.name,
    required this.text,
    required this.mine,
    DateTime? at,
  }) : at = at ?? DateTime.now();
}

/// One device's account of an interrupted match, offered to the peer when the
/// two reconnect.
///
/// An online match needs nothing like this. The relay is a server: it held the
/// history while a device was away, so a returning player simply reads on from
/// their cursor and catches up on everything they missed.
///
/// A hotspot match has no server and no history. Whatever was sent while a
/// device was dead was written into a socket that no longer existed, and is
/// gone for good — there is nothing to replay and nobody holding a
/// authoritative copy. So the two devices reconcile with each other instead:
/// each states how far it got, and both adopt the further-on account.
class ResumeOffer {
  /// Identifies the match, so a stale snapshot is never pasted onto a
  /// different one — same room, same seed.
  final String key;

  /// How many turns this device has begun. [GameController] bumps it once per
  /// turn and never resets it mid-match, so the higher number is strictly the
  /// later state. It is the only ordering the two devices can agree on
  /// without a server.
  final int seq;

  /// The state to restore if this account wins.
  final Map<String, dynamic> state;

  const ResumeOffer({
    required this.key,
    required this.seq,
    required this.state,
  });
}
/// Hotspot / local Wi-Fi multiplayer.
///
/// The host runs a TCP listener and, until somebody joins, broadcasts a room
/// beacon over UDP once a second. A joiner scans for beacons for a few
/// seconds and gets a list of rooms to tap — which removes the single
/// biggest source of "it doesn't work" reports, namely typing a 12-digit IP
/// address off another phone's screen. Typing one is still possible, as a
/// fallback for networks that drop broadcast.
///
/// Message shapes (`t` is the type tag, matching the game controller's
/// protocol):
///   hello     — greeting / handshake, carries the sender's name
///   start     — host launches the match (map, hp, seed)
///   fire      — a shot (a, p, w, pl)
///   endTurn   — turn handoff confirmation (pl, seq)
///   rematch   — restart, seed from the host
class NetService {
  NetService._();
  static final NetService instance = NetService._();

  /// A second, independent service — two of these is two devices.
  ///
  /// Production code uses [instance]: one device, one radio, one match. A
  /// test driving both ends of a real match in one process genuinely needs
  /// two, and faking that by mutating the singleton between calls would not
  /// exercise the thing that matters (two links running at once).
  @visibleForTesting
  factory NetService.forTest() = NetService._;

  bool isHost = false;
  bool connected = false;
  String status = '';

  /// Every IPv4 address this device has, one per active interface. A phone
  /// hosting a hotspot while still on mobile data has two, and there is no
  /// guarantee which one `NetworkInterface.list` hands back first — the old
  /// code took `.first` and cheerfully advertised an address the joiner had
  /// no route to. Everything that needs an address now sees all of them.
  List<String> localIps = const [];
  String get hostAddress => localIps.isNotEmpty ? localIps.first : '';

  /// Rooms the last scan turned up, and whether a scan is in flight.
  List<RoomInfo> foundRooms = [];
  bool isSearching = false;

  /// The opponent's name, once the handshake has happened.
  String peerName = 'Opponent';

  /// The character id the opponent sails as, from their greeting. Empty
  /// until the handshake lands. The HOST is the one that needs it: it builds
  /// the start payload for both sides, so without this the guest's chosen
  /// character would be silently replaced by a default.
  String peerLook = '';

  /// Set once the greeting has been exchanged in BOTH directions. A TCP
  /// connection being up is not the same thing as the two games being ready
  /// to start, and pressing START in between used to launch one side into a
  /// match the other never received.
  bool handshakeDone = false;

  void Function(Map<String, dynamic> msg)? onMessage;
  void Function()? onConnected;
  void Function()? onDisconnected;

  /// Which transport is carrying the current match.
  NetMode mode = NetMode.none;

  /// True while a match is running over either transport — the one thing
  /// the game controller needs to know to switch on networked turn rules.
  bool get isNetworked => mode != NetMode.none;

  /// False while the opponent has gone quiet on an online match. The relay
  /// reports how long ago they last touched the server (a socket would just
  /// drop); this is deliberately NOT a disconnect, because the same channel
  /// is how we learn they came back.
  bool peerPresent = true;

  /// In-match chat, oldest first. Fed by `chat` messages over whichever
  /// transport is live.
  final List<ChatLine> chat = [];

  /// Fired when [peerPresent] changes, and when a chat line arrives.
  void Function(bool present)? onPeerPresence;
  void Function()? onChat;

  /// The online match this link is carrying, and how far through its history
  /// we have read. Both are needed to resume after the app is killed:
  /// rebuilding a [RelayLink] at `since: 0` would replay every line the match
  /// has ever contained — re-firing every shot already taken.
  int? get relayMatchId {
    final l = _link;
    return l is RelayLink ? l.matchId : null;
  }

  int get relaySince {
    final l = _link;
    return l is RelayLink ? l.since : 0;
  }

  /// What this device will offer the peer when a dropped hotspot match is
  /// reconnected. Non-null is what makes a reconnect a *resume* rather than a
  /// new match: it is set while a match is running (by [MatchStore]) and by
  /// the lobby before it dials back into an interrupted one.
  ResumeOffer? resumeOffer;

  /// Fired once the two devices have agreed which account of the match to
  /// carry on from — with the winning state, whether it was ours or theirs,
  /// so there is exactly one path to apply it.
  void Function(Map<String, dynamic> state)? onResumeAgreed;

  /// Fired when a reconnect turned out not to be resumable after all: two
  /// different matches, or a peer with nothing saved.
  void Function(String reason)? onResumeFailed;

  /// The address this device dialled to join. A guest needs it to find the
  /// host again after either app dies; a host never dials and leaves it empty.
  String _hostAddress = '';
  String get joinedHostAddress => _hostAddress;

  /// Guards against a resume settling twice on one connection: both ends greet
  /// unprompted, and the host answers a `hello` with another one.
  bool _resumeSettled = false;

  /// True while [close] is tearing the link down on purpose, so the socket
  /// dying does not look like the peer vanishing and trigger a reconnect.
  bool _closing = false;
  bool _reconnecting = false;
  /// Bumped every time a resume is called off. A dial loop captures the value
  /// it started under and stops the moment it changes — which a sticky boolean
  /// could not do safely: a flag left set by one match ending would silently
  /// disable the automatic reconnect for every match after it in the session.
  int _resumeGen = 0;

  ServerSocket? _server;
  RawDatagramSocket? _udp;

  /// A socket of its own, separate from [_udp]. The beacon and the scanner
  /// used to share one field, so a device that was hosting and then scanned
  /// (to walk back into its own room) silently killed its own beacon out
  /// from under it: the scan overwrote [_udp] without stopping the beacon
  /// timer, and the scan's cleanup then closed it, leaving the timer firing
  /// sends on a closed socket forever.
  RawDatagramSocket? _scanUdp;
  GameLink? _link;

  Timer? _beaconTimer;
  Timer? _scanTimer;
  String _roomCode = '';
  String _selfName = 'Captain';

  static const _magic = 'RFMB1';

  bool get _networkAvailable => !kIsWeb;

  /// True on any target that can open a socket. Web cannot, and the desktop
  /// builds are legitimate peers on a LAN, so this is "not web" rather than
  /// "is mobile" — a Windows build can host a match for a phone.
  bool get supported => _networkAvailable;

  Future<List<String>> _localIps() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      final out = <String>[];
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback || out.contains(addr.address)) continue;
          out.add(addr.address);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  String _newCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random();
    return List.generate(4, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  // ---------------------------------------------------------------- HOST ---

  /// Starts hosting. Returns the room code, or null if it could not bind.
  ///
  /// [code] re-opens a specific room instead of minting a new one, which is
  /// how a host whose app was killed comes back to the *same* room: the guest
  /// is looking for that code, either in its saved snapshot or in a fresh scan.
  Future<String?> host({String playerName = 'Host', String? code}) async {
    if (!_networkAvailable) {
      status = 'Hotspot play needs a phone or desktop build.';
      return null;
    }
    await close();
    mode = NetMode.hotspot;
    isHost = true;
    _selfName = playerName;
    try {
      localIps = await _localIps();
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kGamePort);
      _server!.listen(_acceptSocket);
      _roomCode = (code != null && code.isNotEmpty) ? code : _newCode();
      await _startBeacon();
      status = localIps.isEmpty
          ? 'Hosting as $_roomCode — no Wi-Fi address found. Are you online?'
          : 'Hosting as $_roomCode. Share that code, or an IP below.';
      return _roomCode;
    } catch (e) {
      status = 'Could not host: ${_friendlyError(e)}';
      await close();
      return null;
    }
  }

  String get roomCode => _roomCode;

  void _acceptSocket(Socket socket) {
    // One seat, first come first served.
    if (_link != null) {
      socket.destroy();
      return;
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _link = SocketLink(socket, onClosed: _onLinkClosed);
    _link!.messages.listen(_handleIncoming);
    _stopBeacon();
    connected = true;
    status = 'Opponent connecting…';
    onConnected?.call();
    _greet();
  }

  /// Broadcasts this room once a second so joiners can find it with SCAN.
  ///
  /// Sent once per address in [localIps], each aimed at THAT address's own
  /// subnet-directed broadcast (e.g. 192.168.43.255 for a host at
  /// 192.168.43.1) rather than only the global 255.255.255.255. That
  /// distinction matters specifically on a phone hosting a hotspot: the
  /// global broadcast has no subnet of its own, so the OS routes it by the
  /// ordinary table — commonly the mobile-data interface, not the hotspot's
  /// AP interface. A directed broadcast targets an address only reachable
  /// through the interface actually attached to that subnet, so the more
  /// specific connected route wins. The global send happens too, as a
  /// harmless extra that still helps where it works.
  Future<void> _startBeacon() async {
    _stopBeacon();
    if (localIps.isEmpty) localIps = await _localIps();
    _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kBeaconPort);
    _udp!.broadcastEnabled = true;
    await MulticastLock.acquire();
    // Send one immediately rather than waiting out Timer.periodic's first
    // tick — a scan that started a moment ago should not have to wait a
    // full extra second to see this room.
    _sendBeaconOnce();
    _beaconTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sendBeaconOnce(),
    );
  }

  void _sendBeaconOnce() {
    // A phone hosting a hotspot while also on mobile data has two
    // interfaces, and one of them commonly has no route for its own
    // subnet-directed broadcast (ENETUNREACH) at any given moment. That
    // used to throw out of the whole loop, taking the remaining interfaces
    // and the global send with it and blanking the beacon entirely. Each
    // send is independent now.
    for (final ip in localIps) {
      final directed = _subnetBroadcastOf(ip);
      if (directed == null) continue;
      final bytes = utf8.encode(
        jsonEncode({
          'magic': _magic,
          'code': _roomCode,
          'host': ip,
          'name': _selfName,
        }),
      );
      try {
        _udp?.send(bytes, InternetAddress(directed), kBeaconPort);
      } catch (_) {}
    }
    if (localIps.isNotEmpty) {
      final bytes = utf8.encode(
        jsonEncode({
          'magic': _magic,
          'code': _roomCode,
          'host': localIps.first,
          'name': _selfName,
        }),
      );
      try {
        _udp?.send(bytes, InternetAddress('255.255.255.255'), kBeaconPort);
      } catch (_) {}
    }
  }

  /// The subnet-directed broadcast address for [ip], assuming a /24 — true of
  /// every common phone hotspot and home router. Null for anything not shaped
  /// like a plain dotted quad.
  ///
  /// KNOWN LIMITATION: a /16 or /22 network computes the wrong directed
  /// broadcast, and only the global send still reaches it — plenty of routers
  /// drop that. Doing it properly needs the real subnet mask, which Dart's
  /// dart:io has no portable way to read. Manual IP entry is the escape hatch.
  String? _subnetBroadcastOf(String ip) {
    final octets = ip.split('.');
    if (octets.length != 4) return null;
    return '${octets[0]}.${octets[1]}.${octets[2]}.255';
  }

  void _stopBeacon() {
    final wasActive = _udp != null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    try {
      _udp?.close();
    } catch (_) {}
    _udp = null;
    if (wasActive) unawaited(MulticastLock.release());
  }

  // ---------------------------------------------------------------- JOIN ---

  /// Listens for rooms for a few seconds.
  Future<void> scanRooms() async {
    if (!_networkAvailable) return;
    foundRooms = [];
    isSearching = true;
    if (localIps.isEmpty) localIps = await _localIps();
    try {
      // Its own socket — see the note on [_scanUdp].
      _scanUdp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kBeaconPort);
      // Not needed to receive a directed send, but some Android builds drop
      // inbound broadcast on a socket that never opted into it.
      _scanUdp!.broadcastEnabled = true;
      await MulticastLock.acquire();
      _scanTimer?.cancel();
      _scanUdp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = _scanUdp!.receive();
        if (dg == null) return;
        try {
          final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (msg['magic'] == _magic) {
            _ingestRoom(
              RoomInfo(
                code: msg['code'] as String,
                host: msg['host'] as String,
                playerName: msg['name'] as String? ?? 'Captain',
              ),
            );
          }
        } catch (_) {}
      });
      _scanTimer = Timer(const Duration(seconds: 6), stopScan);
    } catch (_) {
      isSearching = false;
    }
  }

  /// Folds one beacon into [foundRooms], keyed on CODE rather than host: a
  /// host with two live interfaces beacons the same room from each address,
  /// and deduping on host let both through as two separate rooms.
  ///
  /// The address is upgraded only when the new one is on this device's own
  /// subnet and the one already held is not — which is what makes a phone
  /// pick the hotspot address over the host's mobile-data address.
  void _ingestRoom(RoomInfo room) {
    final idx = foundRooms.indexWhere(
      (r) => r.code.toUpperCase() == room.code.toUpperCase(),
    );
    if (idx == -1) {
      foundRooms = [...foundRooms, room];
    } else if (foundRooms[idx].host != room.host &&
        _onOwnSubnet(room.host) &&
        !_onOwnSubnet(foundRooms[idx].host)) {
      final updated = [...foundRooms];
      updated[idx] = room;
      foundRooms = updated;
    }
  }

  bool _onOwnSubnet(String host) {
    final subnet = _subnetBroadcastOf(host);
    if (subnet == null) return false;
    return localIps.map(_subnetBroadcastOf).contains(subnet);
  }

  void stopScan() {
    final wasActive = _scanUdp != null;
    _scanTimer?.cancel();
    _scanTimer = null;
    isSearching = false;
    try {
      _scanUdp?.close();
    } catch (_) {}
    _scanUdp = null;
    if (wasActive) unawaited(MulticastLock.release());
  }

  /// Joins the room at [host]. Prefer passing the address a scan handed you;
  /// a manually typed address works exactly the same way.
  Future<bool> join(String host, {String playerName = 'Guest'}) async {
    if (!_networkAvailable) return false;
    await close();
    mode = NetMode.hotspot;
    isHost = false;
    _selfName = playerName;
    final target = host.trim();
    // Remembered so a dropped match can be dialled back into: the host keeps
    // its address across a relaunch, and the guest has no other way to find it
    // if broadcast is being swallowed by the network.
    _hostAddress = target;
    status = 'Connecting to $target…';
    try {
      final socket = await Socket.connect(
        target,
        kGamePort,
        timeout: const Duration(seconds: 5),
      );
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      _link = SocketLink(socket, onClosed: _onLinkClosed);
      _link!.messages.listen(_handleIncoming);
      connected = true;
      status = 'Connected!';
      onConnected?.call();
      _greet();
      return true;
    } catch (e) {
      status = 'Could not connect: ${_friendlyError(e)}';
      connected = false;
      return false;
    }
  }

  /// Turns a raw socket error into something a player can act on. "It
  /// doesn't work" is nearly always one of these four, and the raw Dart
  /// text ('SocketException: Connection refused, errno = 111') tells nobody
  /// anything.
  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('Permission denied') || s.contains('errno = 13')) {
      return 'Network permission denied. Allow local-network access and try again.';
    }
    if (s.contains('Connection refused') || s.contains('errno = 111')) {
      return 'No game at that address — is the host still hosting?';
    }
    if (s.contains('timed out') || s.contains('errno = 110')) {
      return 'Timed out — are both devices on the same Wi-Fi / hotspot?';
    }
    if (s.contains('unreachable') ||
        s.contains('errno = 101') ||
        s.contains('errno = 113')) {
      return 'Network unreachable — join the same Wi-Fi / hotspot first.';
    }
    if (s.contains('Failed host lookup') || s.contains('errno = 11004')) {
      return 'That is not a valid address. It should look like 192.168.1.5';
    }
    return 'Check that both devices share the same Wi-Fi or hotspot ($s)';
  }

  // -------------------------------------------------------------- RESUME ---

  /// Re-opens the room an interrupted match was played in, and waits.
  ///
  /// The host side of a hotspot resume. Same code, same port, beacon running
  /// again — from the guest's point of view the room simply reappeared, so
  /// both the saved address and a fresh SCAN lead back to it.
  Future<String?> resumeHost({
    required String playerName,
    required String roomCode,
    required ResumeOffer offer,
  }) async {
    resumeOffer = offer;
    final code = await host(playerName: playerName, code: roomCode);
    if (code != null) {
      status = 'Waiting for your opponent to rejoin room $code…';
    }
    return code;
  }

  /// Dials an interrupted match's host until they come back.
  ///
  /// The guest side. A single connect attempt is not enough here: the usual
  /// case is that BOTH apps were closed, so the host is very likely still
  /// starting up — failing on the first refused connection would make resume
  /// a coin toss on who happened to press the button first.
  /// The same loop serves the player pressing RESUME and the automatic
  /// reconnect after a drop, because [_resumeGen] — not the caller — is what
  /// decides whether a cancellation applies.
  Future<bool> resumeJoin(
    String host, {
    required String playerName,
    required ResumeOffer offer,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (host.trim().isEmpty) {
      status = 'No saved host address to reconnect to.';
      return false;
    }
    // Everything below belongs to this attempt. If [cancelResume] runs at any
    // point, the generation moves on and every check here fails at once.
    final gen = _resumeGen;
    resumeOffer = offer;
    final deadline = DateTime.now().add(timeout);
    int attempt = 0;
    while (_resumeGen == gen && DateTime.now().isBefore(deadline)) {
      if (await join(host, playerName: playerName)) {
        // Forfeiting while a connect was in flight still counts. Checking
        // only at the top of the loop would let the one attempt that happened
        // to succeed walk the player straight back into the match they just
        // left, because it returns before the condition is read again.
        if (_resumeGen != gen) {
          await close();
          return false;
        }
        return true;
      }
      if (_resumeGen != gen) break;
      attempt++;
      status = 'Waiting for the host to come back… (try $attempt)';
      // Gentle backoff: a relaunching app is usually up within a few seconds,
      // and hammering a phone's socket layer helps nobody.
      final ms = (400 * attempt).clamp(400, 2500);
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
    if (_resumeGen == gen) {
      status = 'Could not reach the host — they may have left the match.';
    }
    return false;
  }

  /// Gives up on reconnecting, so the player can forfeit and move on.
  void cancelResume() {
    _resumeGen++;
    resumeOffer = null;
  }

  /// The character this device sails as, sent in the greeting. Set by the
  /// lobby before it hosts or joins.
  String selfLook = '';

  /// Greets the peer, and offers our account of the match if we are resuming.
  ///
  /// Two messages with one job each: `hello` settles names and the handshake
  /// exactly as it always did, and `resume` — sent only when there is
  /// something to resume — carries the reconciliation. A peer that knows
  /// nothing about resuming simply ignores the second one.
  void _greet() {
    _resumeSettled = false;
    _send({
      't': 'hello',
      'name': _selfName,
      if (selfLook.isNotEmpty) 'look': selfLook,
      if (_roomCode.isNotEmpty) 'room': _roomCode,
    });
    final offer = resumeOffer;
    if (offer != null) {
      _send({
        't': 'resume',
        'key': offer.key,
        'seq': offer.seq,
        'state': offer.state,
      });
    }
  }

  /// Settles which of the two accounts of the match play continues from.
  ///
  /// Both devices run this against the other's offer and must reach the same
  /// answer without talking further, so the rule is a pure function of the two
  /// offers: the higher [ResumeOffer.seq] wins, and a tie goes to the host.
  /// A tie means both were at the same turn boundary — where, in lockstep,
  /// their states already agree — so the tiebreak only has to be *consistent*,
  /// not clever.
  void _handleResume(Map<String, dynamic> msg) {
    if (_resumeSettled) return;
    final mine = resumeOffer;
    if (mine == null) {
      // They are resuming and we are not. Saying so is much kinder than
      // silently playing on from a state only one device believes in.
      _send({'t': 'resumeNo', 'why': 'The other captain has no saved match.'});
      return;
    }
    if (msg['key'] != mine.key) {
      _send({'t': 'resumeNo', 'why': 'Those are two different battles.'});
      onResumeFailed?.call('That is a different battle to the one you saved.');
      return;
    }
    final theirSeq = (msg['seq'] as num?)?.toInt() ?? -1;
    final theirState = msg['state'];
    final takeTheirs = theirState is Map &&
        (theirSeq > mine.seq || (theirSeq == mine.seq && !isHost));
    _resumeSettled = true;
    status = 'Resuming against $peerName…';
    onResumeAgreed?.call(
      takeTheirs ? Map<String, dynamic>.from(theirState) : mine.state,
    );
  }

  /// Dials the host back after the link dropped mid-match, without the player
  /// having to do anything. Runs at most one loop at a time.
  void _scheduleReconnect() {
    if (_reconnecting || _closing) return;
    final offer = resumeOffer;
    if (offer == null || _hostAddress.isEmpty) return;
    _reconnecting = true;
    unawaited(() async {
      try {
        await resumeJoin(_hostAddress, playerName: _selfName, offer: offer);
      } finally {
        _reconnecting = false;
      }
    }());
  }

  // -------------------------------------------------------------- ONLINE ---

  /// Starts carrying a match over the internet relay instead of a socket.
  ///
  /// This is the whole of what internet play adds to the game. A hotspot
  /// match writes JSON lines into a TCP socket; an online match posts the
  /// identical lines to the server's `relay_send` and reads the opponent's
  /// back from `relay_poll`. Both are [GameLink]s, so the lobby handshake,
  /// the match start, firing, turn handoff, chat and the rematch all run
  /// unchanged and unaware of which one is underneath.
  ///
  /// Unlike [join], both ends greet unprompted: there is no "who connected
  /// to whom" over a relay, so each side sends its own `hello` and takes
  /// the seat matchmaking already assigned it via [asHost].
  Future<bool> startRelayMatch({
    required OnlineApi api,
    required int matchId,
    required bool asHost,
    String playerName = 'Captain',
    int since = 0,
  }) async {
    if (!_networkAvailable) {
      status = 'Online play is not available on this platform.';
      return false;
    }
    await close();
    mode = NetMode.online;
    isHost = asHost;
    peerPresent = true;
    _selfName = playerName;
    try {
      _link = RelayLink(
        api: api,
        matchId: matchId,
        since: since,
        onClosed: _onLinkClosed,
        onPeerPresence: _onRelayPeerPresence,
      );
      _link!.messages.listen(_handleIncoming);
      connected = true;
      status = 'Connected!';
      onConnected?.call();
      _send({'t': 'hello', 'name': _selfName});
      return true;
    } catch (e) {
      status = 'Could not join the match: $e';
      connected = false;
      mode = NetMode.none;
      return false;
    }
  }

  /// The opponent going quiet on an online match. Deliberately does NOT
  /// tear the link down: that same link is how their return arrives.
  void _onRelayPeerPresence(bool present) {
    if (peerPresent == present) return;
    peerPresent = present;
    status = present ? 'Connected to $peerName!' : 'Opponent lost connection…';
    onPeerPresence?.call(present);
  }

  /// Sends a chat line and echoes it locally, so the sender sees it
  /// immediately rather than waiting for a round trip that never comes
  /// (the relay only hands back the *other* player's lines).
  void sendChat(String text) {
    final t = text.trim();
    if (t.isEmpty || _link == null) return;
    chat.add(ChatLine(name: _selfName, text: t, mine: true));
    if (chat.length > 60) chat.removeAt(0);
    _send({'t': 'chat', 'm': t});
    onChat?.call();
  }
  // ------------------------------------------------------------ MESSAGES ---

  void _send(Map<String, dynamic> msg) {
    try {
      _link?.send(msg);
    } catch (_) {}
  }

  /// The public send path, used by the game controller for fire/endTurn/
  /// rematch. Silently does nothing when there is no link, so a caller never
  /// has to guard for it.
  void send(Map<String, dynamic> msg) => _send(msg);

  void _handleIncoming(Map<String, dynamic> msg) {
    // Resume traffic is between the two NetServices and never reaches the
    // game: by the time the controller exists, the question of which state to
    // play on from has already been settled.
    if (msg['t'] == 'resume') {
      _handleResume(msg);
      return;
    }
    if (msg['t'] == 'resumeNo') {
      onResumeFailed?.call(
          msg['why'] as String? ?? 'That match could not be resumed.');
      return;
    }
    if (msg['t'] == 'chat') {
      final text = (msg['m'] as String? ?? '').trim();
      if (text.isNotEmpty) {
        chat.add(ChatLine(name: peerName, text: text, mine: false));
        if (chat.length > 60) chat.removeAt(0);
        onChat?.call();
      }
      return;
    }
    if (msg['t'] == 'hello') {
      final name = msg['name'] as String?;
      if (name != null && name.isNotEmpty) peerName = name;
      // The host names the room in its greeting, which is how a guest comes
      // to know the code at all — and the code is half of the match identity
      // a later resume is checked against.
      final room = msg['room'];
      if (room is String && room.isNotEmpty) _roomCode = room;
      final look = msg['look'];
      if (look is String && look.isNotEmpty) peerLook = look;
      handshakeDone = true;
      connected = true;
      status = 'Connected to $peerName!';
      // Whoever is listening answers the greeting, so both ends end up
      // knowing the match is live — a single-sided handshake would let the
      // host press START before the guest's game was even listening.
      if (_server != null) {
        _send({
          't': 'hello',
          'name': _selfName,
          if (selfLook.isNotEmpty) 'look': selfLook,
          'room': _roomCode,
        });
      }
      onConnected?.call();
    }
    onMessage?.call(msg);
  }

  void _onLinkClosed() {
    _link = null;
    connected = false;
    handshakeDone = false;
    _resumeSettled = false;

    // A hotspot match we still hold a [ResumeOffer] for is not over — the
    // peer's app died, and walking back in is exactly what resume is for. So
    // the surviving device makes itself findable again rather than tearing
    // down: the host re-opens the room it is already listening on and starts
    // beaconing (the beacon was stopped the moment the guest first joined, so
    // without this the room is invisible to the very device trying to return),
    // and the guest dials the host back on its own.
    //
    // Doing nothing here is what made hotspot resume look impossible: by the
    // time the returning player pressed RESUME there was no longer anything
    // on the other side to reconnect *to*.
    if (!_closing && mode == NetMode.hotspot && resumeOffer != null) {
      status = 'Opponent dropped — waiting for them to reconnect…';
      if (isHost && _server != null) {
        unawaited(_startBeacon());
      } else if (!isHost) {
        _scheduleReconnect();
      }
      onDisconnected?.call();
      return;
    }
    status = 'Opponent disconnected';
    onDisconnected?.call();
  }

  Future<void> close() async {
    _closing = true;
    _stopBeacon();
    final scanWasActive = _scanUdp != null;
    _scanTimer?.cancel();
    _scanTimer = null;
    isSearching = false;
    try {
      _scanUdp?.close();
    } catch (_) {}
    _scanUdp = null;
    if (scanWasActive) unawaited(MulticastLock.release());
    try {
      await _link?.close();
    } catch (_) {}
    _link = null;
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
    connected = false;
    handshakeDone = false;
    _resumeSettled = false;
    foundRooms = [];
    _roomCode = '';
    mode = NetMode.none;
    peerPresent = true;
    chat.clear();
    // Deliberately NOT cleared: [resumeOffer] and [_hostAddress]. Both
    // host() and join() call close() first, so clearing them here would
    // destroy the resume on the way into the very connection meant to
    // restore it. Ending a match for good goes through [cancelResume].
    _closing = false;
  }
}
