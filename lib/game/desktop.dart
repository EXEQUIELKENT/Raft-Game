import 'package:flutter/foundation.dart';

/// ---------------------------------------------------------------------------
/// Desktop (Windows/macOS/Linux) support.
///
/// The game was written for phones: it locks the device to landscape and
/// drives everything through touch. None of that is wrong on a desktop, but
/// a few things have to be asked for differently — an orientation request has
/// no meaning (and no platform channel) on Windows, and a mouse-and-keyboard
/// player needs the same controls a thumb has.
///
/// Everything here is deliberately dependency-free: `flutter run -d windows`
/// and `flutter build windows` work with nothing added to pubspec.
/// ---------------------------------------------------------------------------

/// Platform shorthands, gathered so the rest of the app never has to spell
/// out `defaultTargetPlatform == TargetPlatform.windows` chains.
class Desktop {
  Desktop._();

  static bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  static bool get isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  static bool get isLinux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  static bool get isDesktop => isWindows || isMacOS || isLinux;

  static bool get isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Prepare the desktop window before the first frame.
  ///
  /// The window's opening size and its minimum size are set by the native
  /// runner (`windows/runner/main.cpp` and the WM_GETMINMAXINFO handler in
  /// `win32_window.cpp`), because Flutter exposes no framework API for either
  /// and pulling in a window-management plugin for two numbers is not worth
  /// the extra build surface. Nothing to do at runtime; the hook exists so
  /// `main()` reads as one place that knows about desktop concerns.
  static Future<void> configureWindow() async {}
}
