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

  /// One dedicated player per sound, with its asset preloaded at init.
  /// `play(AssetSource(...))` decodes the clip from the bundle on *every*
  /// call — an explosive blast fires 4–7 concurrent sfx in a single frame
  /// (boom + shockwave + eliminate + a voice per hit crew), and re-decoding
  /// all of them at once stuttered the frame. Preloading turns a replay
  /// into a cheap resume.
  final Map<String, AudioPlayer> _locked = {};
  String? _currentMusic;
  bool _ready = false;
  bool _available = true;

  /// Every clip the game plays, so [init] can preload them all.
  static const List<String> _knownSounds = [
    'click', 'bounce', 'hit', 'explosion', 'shockwave', 'splash',
    'eliminate', 'whoosh', 'swap', 'turn', 'place', 'fire',
    'voice_grunt', 'voice_laugh', 'voice_ouch1', 'voice_ouch2',
    'voice_ouch3', 'voice_ouch4', 'voice_swap',
  ];

  AudioService._();

  Future<void> init() async {
    if (_ready || !_available) return;
    try {
      final music = AudioPlayer(playerId: 'music');
      await music.setReleaseMode(ReleaseMode.loop);
      await music.setVolume(_musicVol);
      _music = music;
      // Preload one dedicated player per known sound.
      for (final name in _knownSounds) {
        final p = AudioPlayer(playerId: 'sfx_$name');
        await p.setReleaseMode(ReleaseMode.stop);
        await p.setSourceAsset('sfx/$name.wav');
        _locked[name] = p;
      }
      // Fallback pool for any sound not in the known list.
      for (int i = 0; i < 4; i++) {
        final p = AudioPlayer(playerId: 'sfx_pool$i');
        await p.setReleaseMode(ReleaseMode.stop);
        _pool.add(p);
      }
      _ready = true;
    } catch (e) {
      debugPrint('audio unavailable: $e');
      _available = false;
      _music = null;
      _locked.clear();
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
    if (!_ready || !_available || _sfxVol <= 0.01) return;
    final vol = (volume * _sfxVol).clamp(0.0, 1.0);
    final locked = _locked[name];
    if (locked != null) {
      // Preloaded: a stop + resume restarts the clip with no re-decode.
      () async {
        try {
          await locked.stop();
          await locked.setVolume(vol);
          await locked.resume();
        } catch (_) {}
      }();
      return;
    }
    // Fallback for unknown names: pooled lazy-load (one decode, then the
    // platform caches it for that player).
    final p = _pool.isEmpty ? null : _pool[_poolIndex];
    if (p == null) return;
    _poolIndex = (_poolIndex + 1) % _pool.length;
    () async {
      try {
        await p.stop();
        await p.setVolume(vol);
        await p.play(AssetSource('sfx/$name.wav'));
      } catch (_) {}
    }();
  }

  void dispose() {
    if (!_available) return;
    try {
      _music?.dispose();
      for (final p in _locked.values) {
        p.dispose();
      }
      for (final p in _pool) {
        p.dispose();
      }
    } catch (_) {}
  }
}
