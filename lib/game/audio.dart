import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'save.dart';

/// Central audio service: music loops + pooled one-shot SFX.
class AudioService {
  AudioService._();
  static final AudioService instance = AudioService._();

  late final AudioPlayer _music;
  final List<AudioPlayer> _pool = [];
  int _poolIndex = 0;
  String? _currentMusic;
  bool _ready = false;
  bool _available = true;

  AudioService._() {
    try {
      _music = AudioPlayer(playerId: 'music');
    } catch (_) {
      _available = false;
    }
  }

  Future<void> init() async {
    if (_ready || !_available) return;
    try {
      for (int i = 0; i < 6; i++) {
        _pool.add(AudioPlayer(playerId: 'sfx$i'));
      }
      await _music.setReleaseMode(ReleaseMode.loop);
      for (final p in _pool) {
        await p.setReleaseMode(ReleaseMode.stop);
      }
      _ready = true;
    } catch (e) {
      debugPrint('audio unavailable: $e');
      _available = false;
    }
  }

  double get _sfxVol => SaveService.instance.data.sfxVolume;
  double get _musicVol => SaveService.instance.data.musicVolume;

  Future<void> playMusic(String name) async {
    if (!_ready || !_available) return;
    if (_currentMusic == name) return;
    _currentMusic = name;
    try {
      await _music.stop();
      await _music.setVolume(_musicVol);
      await _music.play(AssetSource('sfx/$name.wav'));
    } catch (e) {
      debugPrint('music error: $e');
    }
  }

  Future<void> stopMusic() async {
    _currentMusic = null;
    if (!_available) return;
    try {
      await _music.stop();
    } catch (_) {}
  }

  Future<void> updateVolumes() async {
    if (!_ready || !_available) return;
    try {
      await _music.setVolume(_musicVol);
    } catch (_) {}
  }

  void sfx(String name, {double volume = 1.0}) {
    if (!_ready || !_available || _sfxVol <= 0.01) return;
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
      _music.dispose();
      for (final p in _pool) {
        p.dispose();
      }
    } catch (_) {}
  }
}
