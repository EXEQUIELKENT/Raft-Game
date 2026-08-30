import 'package:flutter/services.dart';

/// Thin wrapper around the Android `WifiManager.MulticastLock` acquired by
/// `MainActivity.kt`.
///
/// Holding it while a LAN beacon or scan is running keeps the Wi-Fi radio
/// from filtering out inbound broadcast packets in power-save — without it,
/// `scanRooms` sometimes simply never sees a beacon that a phone across the
/// room is genuinely sending, which is exactly the "hotspot multiplayer
/// doesn't work" symptom this is here to fix.
///
/// A no-op everywhere except a real Android device: the channel has no native
/// handler on iOS/desktop/web/tests, so every call is wrapped in a try/catch
/// and silently ignored there.
class MulticastLock {
  MulticastLock._();

  static const _channel = MethodChannel('raftrumble/multicast');

  static Future<void> acquire() async {
    try {
      await _channel.invokeMethod('acquire');
    } catch (_) {}
  }

  static Future<void> release() async {
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
  }
}
