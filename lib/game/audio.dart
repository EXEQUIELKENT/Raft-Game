import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'save.dart';

/// Central audio service: music loops + pooled one-shot SFX.
///
/// Fully defensive: in environments without the audioplayers platform
/// implementation (unit/widget tests, headless runs) every operation is a
/// no-op instead of throwing. Player construction itself can trigger async
/// platform calls that complete with MissingPluginException *after* the
/// constructor returns, so we never construct players until init() succeeds.
class AudioService {
  static final AudioService instance = AudioService._();

  AudioPlayer? _music;
  final List<AudioPlayer> _pool = [];
  int _poolIndex = 0;
  String? _currentMusic;
  bool _ready = false;
  bool _available = true;

  AudioService._();

  Future<void> init() async {
    if (_ready || !_available) return;
    try {
      final music = AudioPlayer(playerId: 'music');
      final pool = <AudioPlayer>[
        for (int i = 0; i < 6; i++) AudioPlayer(playerId: 'sfx$i'),
      ];
      await music.setReleaseMode(ReleaseMode.loop);
      for (final p in pool) {
        await p.setReleaseMode(ReleaseMode.stop);
      }
      _music = music;
      _pool.addAll(pool);
      _ready = true;
    } catch (e) {
      debugPrint('audio unavailable: $e');
      _available = false;
      _music = null;
      _pool.clear();
    }
  }

  double get _sfxVol => SaveService.instance.data.sfxVolume;
  double get _musicVol => SaveService.instance.data.musicVolume;

  Future<void> playMusic(String name) async {
    final m = _music;
    if (!_ready || !_available || m == null) return;
    if (_currentMusic == name) return;
    _currentMusic = name;
    try {
      await m.stop();
      await m.setVolume(_musicVol);
      await m.play(AssetSource('sfx/$name.wav'));
    } catch (e) {
      debugPrint('music error: $e');
    }
  }

  Future<void> stopMusic() async {
    _currentMusic = null;
    final m = _music;
    if (!_available || m == null) return;
    try {
      await m.stop();
    } catch (_) {}
  }

  Future<void> updateVolumes() async {
    final m = _music;
    if (!_ready || !_available || m == null) return;
    try {
      await m.setVolume(_musicVol);
    } catch (_) {}
  }

  void sfx(String name, {double volume = 1.0}) {
    if (!_ready || !_available || _sfxVol <= 0.01 || _pool.isEmpty) return;
    final p = _pool[_poolIndex];
    _poolIndex = (_poolIndex + 1) % _pool.length;
    () async {
      try {
        await p.stop();
        await p.setVolume((volume * _sfxVol).clamp(0.0, 1.0));
        await p.play(AssetSource('sfx/$name.wav'));
      } catch (_) {}
    }();
  }

  void dispose() {
    if (!_available) return;
    try {
      _music?.dispose();
      for (final p in _pool) {
        p.dispose();
      }
    } catch (_) {}
  }
}
