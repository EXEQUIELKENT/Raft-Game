import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'game/audio.dart';
import 'game/desktop.dart';
import 'game/match_store.dart';
import 'game/save.dart';
import 'screens/main_menu.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SaveService.instance.load();
  await AudioService.instance.init();
  // Loaded here rather than in a lobby, so a snapshot is available (and
  // writable — flushNow needs the prefs handle) no matter which screen the
  // player opens first.
  await MatchStore.instance.load();

  // Orientation is a phone/tablet concept. Desktop and web builds have no
  // platform channel behind setPreferredOrientations, so asking for it there
  // only buys a MissingPluginException in the log — and the desktop window
  // is sized for landscape by [Desktop.configureWindow] anyway.
  if (Desktop.isMobile) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
  await Desktop.configureWindow();

  runApp(const RaftRumbleApp());
}

class RaftRumbleApp extends StatefulWidget {
  const RaftRumbleApp({super.key});

  @override
  State<RaftRumbleApp> createState() => _RaftRumbleAppState();
}

class _RaftRumbleAppState extends State<RaftRumbleApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Going to the background is the last moment a killed app is still
    // running, so an online battle's snapshot is written now rather than
    // waiting for a turn that may never come. See [MatchStore].
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(MatchStore.instance.flushNow());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Raft Rumble',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: RT.sea2,
        colorScheme: ColorScheme.fromSeed(seedColor: RT.orange, brightness: Brightness.light),
      ),
      home: const MainMenuScreen(),
    );
  }
}
