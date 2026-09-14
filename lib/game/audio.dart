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

  /// Clips that exist in all three pitch registers, so [voiced] can select
  /// one. Any voice line NOT listed here falls back to the mid clip for
  /// every character — fine for the handful that are effectively noises
  /// (a whistle has no register), wrong for anything a person says.
  static const List<String> voiceBases = [
    'voice_grunt', 'voice_ouch1', 'voice_ouch2', 'voice_ouch3', 'voice_ouch4',
    'voice_laugh', 'voice_yawn', 'voice_chatter', 'voice_hmm', 'voice_look',
    'voice_cheer', 'voice_gasp', 'voice_hup',
    // The wider activity set.
    'voice_tsk', 'voice_hum', 'voice_sneeze', 'voice_count', 'voice_blow',
    'voice_taunt', 'voice_brr', 'voice_whistle',
  ];

  /// Every clip the game plays, so [init] can preload them all.
  static final List<String> _knownSounds = [
    'click', 'bounce', 'hit', 'explosion', 'shockwave', 'splash',
    'eliminate', 'whoosh', 'swap', 'turn', 'place', 'fire',
    'voice_swap',
    for (final v in voiceBases) ...[v, '${v}_low', '${v}_high'],
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

  /// The track most recently asked for, whether or not there is a sound
  /// device to play it on.
  ///
  /// Separate from [_currentMusic], which only moves when audio is actually
  /// up: the question a test needs to answer is which track a screen ASKED
  /// for and in what order, and that is exactly what goes wrong when two
  /// screens hand the music back and forth during a route change.
  @visibleForTesting
  String? lastMusicRequest;

  Future<void> playMusic(String name) async {
    lastMusicRequest = name;
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

  /// When each clip was last started, and at what volume.
  ///
  /// A single explosive kill asks for six to ten sounds inside one frame —
  /// the blast, the shockwave, a yelp and a thud per crew member caught, an
  /// elimination sting, the shooter's laugh. Each of those was three platform
  /// channel round-trips (stop, setVolume, resume), so one impact could fire
  /// two dozen messages across the channel in a single frame. That is a
  /// well-known way to drop frames on a real device, and it happens at
  /// exactly the moment the player is watching a body fly.
  final Map<String, DateTime> _lastAt = {};
  final Map<String, double> _lastVol = {};

  /// Two requests for the SAME clip closer together than this are one sound.
  /// Restarting a clip a few milliseconds in is inaudible anyway — the ear
  /// hears one hit either way — so the second request buys nothing but
  /// channel traffic.
  static const Duration _retrigger = Duration(milliseconds: 55);

  /// How many *different* voice clips may start in one burst. Three crew
  /// caught by one blast used to yelp over each other into mush; capping it
  /// keeps the reaction legible and cuts the burst down.
  static const int _voiceBurstCap = 2;
  static const Duration _voiceBurstWindow = Duration(milliseconds: 110);
  DateTime _voiceBurstStart = DateTime.fromMillisecondsSinceEpoch(0);
  int _voiceBurstCount = 0;

  /// True if [name] should be skipped this instant.
  ///
  /// Exposed for tests: without a platform implementation the audio stack is
  /// a no-op, so the throttle is the only part of this that can be checked at
  /// all — and it is the part that changes what the player hears.
  @visibleForTesting
  bool throttled(String name, {bool voice = false}) {
    final now = DateTime.now();
    final last = _lastAt[name];
    if (last != null && now.difference(last) < _retrigger) return true;
    if (voice) {
      if (now.difference(_voiceBurstStart) > _voiceBurstWindow) {
        _voiceBurstStart = now;
        _voiceBurstCount = 0;
      }
      if (_voiceBurstCount >= _voiceBurstCap) return true;
      _voiceBurstCount++;
    }
    _lastAt[name] = now;
    return false;
  }

  void sfx(String name, {double volume = 1.0, bool voice = false}) {
    if (!_ready || !_available || _sfxVol <= 0.01) return;
    if (throttled(name, voice: voice)) return;
    final vol = (volume * _sfxVol).clamp(0.0, 1.0);
    final locked = _locked[name];
    if (locked != null) {
      // Preloaded: a stop + resume restarts the clip with no re-decode.
      // setVolume is skipped when it has not changed, which removes a third
      // of the channel traffic — the volume only ever moves when the player
      // changes it in settings.
      final needVol = (_lastVol[name] ?? -1) != vol;
      if (needVol) _lastVol[name] = vol;
      () async {
        try {
          await locked.stop();
          if (needVol) await locked.setVolume(vol);
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

  /// Clears the throttle bookkeeping, so one test's burst cannot leak into
  /// the next through the singleton.
  @visibleForTesting
  void resetThrottle() {
    _lastAt.clear();
    _lastVol.clear();
    _voiceBurstCount = 0;
    _voiceBurstStart = DateTime.fromMillisecondsSinceEpoch(0);
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
