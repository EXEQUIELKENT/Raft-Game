import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'game/audio.dart';
import 'game/desktop.dart';
import 'game/save.dart';
import 'screens/main_menu.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SaveService.instance.load();
  await AudioService.instance.init();

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

class RaftRumbleApp extends StatelessWidget {
  const RaftRumbleApp({super.key});

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
