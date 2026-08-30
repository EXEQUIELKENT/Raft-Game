import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'multicast_lock.dart';

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

  /// Set once the greeting has been exchanged in BOTH directions. A TCP
  /// connection being up is not the same thing as the two games being ready
  /// to start, and pressing START in between used to launch one side into a
  /// match the other never received.
  bool handshakeDone = false;

  void Function(Map<String, dynamic> msg)? onMessage;
  void Function()? onConnected;
  void Function()? onDisconnected;

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
  Future<String?> host({String playerName = 'Host'}) async {
    if (!_networkAvailable) {
      status = 'Hotspot play needs a phone or desktop build.';
      return null;
    }
    await close();
    isHost = true;
    _selfName = playerName;
    try {
      localIps = await _localIps();
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, kGamePort);
      _server!.listen(_acceptSocket);
      _roomCode = _newCode();
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
    _send({'t': 'hello', 'name': _selfName, 'room': _roomCode});
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
    isHost = false;
    _selfName = playerName;
    final target = host.trim();
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
      _send({'t': 'hello', 'name': _selfName});
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
    if (msg['t'] == 'hello') {
      final name = msg['name'] as String?;
      if (name != null && name.isNotEmpty) peerName = name;
      handshakeDone = true;
      connected = true;
      status = 'Connected to $peerName!';
      // Whoever is listening answers the greeting, so both ends end up
      // knowing the match is live — a single-sided handshake would let the
      // host press START before the guest's game was even listening.
      if (_server != null) _send({'t': 'hello', 'name': _selfName, 'room': _roomCode});
      onConnected?.call();
    }
    onMessage?.call(msg);
  }

  void _onLinkClosed() {
    _link = null;
    connected = false;
    handshakeDone = false;
    status = 'Opponent disconnected';
    onDisconnected?.call();
  }

  Future<void> close() async {
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
    foundRooms = [];
    _roomCode = '';
  }
}
