import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// Player level -> XP thresholds (cumulative)
const List<int> xpLevels = [0, 100, 250, 450, 700, 1000, 1400, 1900, 2500, 3200, 4000];

class SaveData {
  int xp = 0;
  int wins = 0;
  int losses = 0;
  int shotsFired = 0;
  int totalDamage = 0;
  int blocksPlaced = 0;
  String character = 'captain';
  int hatIndex = 0;
  int colorIndex = 0;
  double musicVolume = 0.6;
  double sfxVolume = 0.9;
  bool vibration = true;
  int quality = 1; // 0 low, 1 med, 2 high
  double sensitivity = 1.0;
  bool aimAssist = true;
  bool showTrajectory = true;
  List<String> achievements = [];
  List<Map<String, dynamic>> matchHistory = [];

  int get level {
    int lvl = 1;
    for (int i = 0; i < xpLevels.length; i++) {
      if (xp >= xpLevels[i]) lvl = i + 1;
    }
    return lvl.clamp(1, 10);
  }

  int get xpForNext => level >= 10 ? xpLevels.last : xpLevels[level];
  int get xpForCurrent => level >= 10 ? xpLevels.last : xpLevels[level - 1];

  List<WeaponDef> get unlockedWeapons => Weapons.unlockedAt(level);

  Map<String, dynamic> toJson() => {
        'xp': xp, 'wins': wins, 'losses': losses, 'shotsFired': shotsFired,
        'totalDamage': totalDamage, 'blocksPlaced': blocksPlaced,
        'character': character, 'hatIndex': hatIndex, 'colorIndex': colorIndex,
        'musicVolume': musicVolume, 'sfxVolume': sfxVolume, 'vibration': vibration,
        'quality': quality, 'sensitivity': sensitivity, 'aimAssist': aimAssist,
        'showTrajectory': showTrajectory, 'achievements': achievements,
        'matchHistory': matchHistory,
      };

  void fromJson(Map<String, dynamic> j) {
    xp = j['xp'] ?? 0;
    wins = j['wins'] ?? 0;
    losses = j['losses'] ?? 0;
    shotsFired = j['shotsFired'] ?? 0;
    totalDamage = j['totalDamage'] ?? 0;
    blocksPlaced = j['blocksPlaced'] ?? 0;
    character = j['character'] ?? 'captain';
    hatIndex = j['hatIndex'] ?? 0;
    colorIndex = j['colorIndex'] ?? 0;
    musicVolume = (j['musicVolume'] ?? 0.6).toDouble();
    sfxVolume = (j['sfxVolume'] ?? 0.9).toDouble();
    vibration = j['vibration'] ?? true;
    quality = j['quality'] ?? 1;
    sensitivity = (j['sensitivity'] ?? 1.0).toDouble();
    aimAssist = j['aimAssist'] ?? true;
    showTrajectory = j['showTrajectory'] ?? true;
    achievements = List<String>.from(j['achievements'] ?? []);
    matchHistory = List<Map<String, dynamic>>.from(j['matchHistory'] ?? []);
  }
}

class SaveService {
  SaveService._();
  static final SaveService instance = SaveService._();

  static const _key = 'raft_rumble_save_v1';
  SaveData data = SaveData();
  bool _loaded = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        data.fromJson(jsonDecode(raw));
      } catch (_) {}
    }
    _loaded = true;
  }

  Future<void> save() async {
    if (!_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(data.toJson()));
  }

  Future<void> reset() async {
    data = SaveData();
    await save();
  }

  /// Award XP & record a match result. Returns newly unlocked achievements.
  List<String> recordMatch({required bool won, required int damageDealt, String mode = 'AI', String map = 'Ocean'}) {
    data.shotsFired += 0; // shots tracked separately
    if (won) {
      data.wins++;
      data.xp += 60;
    } else {
      data.losses++;
      data.xp += 20;
    }
    data.xp += (damageDealt / 10).round();
    data.totalDamage += damageDealt;
    data.matchHistory.insert(0, {
      'won': won,
      'mode': mode,
      'map': map,
      'damage': damageDealt,
      'date': DateTime.now().toIso8601String().substring(0, 16),
    });
    if (data.matchHistory.length > 20) data.matchHistory.removeLast();

    final newAch = <String>[];
    void ach(String id) {
      if (!data.achievements.contains(id)) {
        data.achievements.add(id);
        newAch.add(id);
      }
    }

    if (won && data.wins == 1) ach('first_win');
    if (data.wins >= 10) ach('veteran');
    if (data.wins >= 50) ach('legend');
    if (data.totalDamage >= 1000) ach('demolisher');
    if (data.totalDamage >= 10000) ach('wrecker');
    if (data.shotsFired >= 100) ach('trigger_happy');
    if (data.blocksPlaced >= 50) ach('architect');

    save();
    return newAch;
  }

  static const Map<String, Map<String, String>> achievementInfo = {
    'first_win': {'name': 'First Splash', 'desc': 'Win your first battle'},
    'veteran': {'name': 'Sea Dog', 'desc': 'Win 10 battles'},
    'legend': {'name': 'Raft Legend', 'desc': 'Win 50 battles'},
    'demolisher': {'name': 'Demolisher', 'desc': 'Deal 1,000 total damage'},
    'wrecker': {'name': 'Wrecking Crew', 'desc': 'Deal 10,000 total damage'},
    'trigger_happy': {'name': 'Trigger Happy', 'desc': 'Fire 100 shots'},
    'architect': {'name': 'Raft Architect', 'desc': 'Place 50 building blocks'},
  };
}
