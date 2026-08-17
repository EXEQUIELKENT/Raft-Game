import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Hotspot / local Wi-Fi multiplayer.
/// Host runs a WebSocket server; client connects to host IP.
/// Host is authoritative for game setup; fire/build actions are exchanged as messages.
class NetService {
  NetService._();
  static final NetService instance = NetService._();

  bool isHost = false;
  bool connected = false;
  String status = '';
  String hostAddress = '';
  int playersInLobby = 0;

  HttpServer? _server;
  WebSocket? _hostPeer; // host's socket to client
  WebSocket? _clientSocket;

  void Function(Map<String, dynamic> msg)? onMessage;
  void Function()? onConnected;
  void Function()? onDisconnected;

  static const int port = 50505;

  Future<String?> localIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  /// HOST: start server and wait for client
  Future<bool> host() async {
    await close();
    isHost = true;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      hostAddress = await localIp() ?? '?';
      status = 'Waiting for opponent…';
      _server!.listen((req) async {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          _hostPeer = ws;
          connected = true;
          playersInLobby = 2;
          status = 'Opponent connected!';
          onConnected?.call();
          ws.listen(
            (data) => _handle(data),
            onDone: _handleDisconnect,
            onError: (_) => _handleDisconnect(),
          );
        }
      });
      return true;
    } catch (e) {
      status = 'Failed to host: $e';
      return false;
    }
  }

  /// CLIENT: join host by IP
  Future<bool> join(String ip) async {
    await close();
    isHost = false;
    status = 'Connecting to $ip…';
    try {
      _clientSocket = await WebSocket.connect('ws://$ip:$port').timeout(const Duration(seconds: 8));
      connected = true;
      status = 'Connected!';
      _clientSocket!.listen(
        (data) => _handle(data),
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
      );
      onConnected?.call();
      return true;
    } catch (e) {
      status = 'Could not connect: $e';
      connected = false;
      return false;
    }
  }

  void _handle(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      onMessage?.call(msg);
    } catch (e) {
      debugPrint('net parse error: $e');
    }
  }

  void _handleDisconnect() {
    connected = false;
    status = 'Opponent disconnected';
    onDisconnected?.call();
  }

  void send(Map<String, dynamic> msg) {
    final raw = jsonEncode(msg);
    try {
      if (isHost) {
        _hostPeer?.add(raw);
      } else {
        _clientSocket?.add(raw);
      }
    } catch (e) {
      debugPrint('net send error: $e');
    }
  }

  Future<void> close() async {
    connected = false;
    try { await _hostPeer?.close(); } catch (_) {}
    try { await _clientSocket?.close(); } catch (_) {}
    try { await _server?.close(force: true); } catch (_) {}
    _hostPeer = null;
    _clientSocket = null;
    _server = null;
  }
}
