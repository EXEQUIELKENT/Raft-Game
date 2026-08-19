import 'package:flutter/material.dart';
import '../game/ai.dart';
import '../game/audio.dart';
import '../game/campaign.dart';
import '../game/controller.dart';
import '../game/save.dart';
import '../theme.dart';
import 'game_screen.dart';

class CampaignWorldScreen extends StatefulWidget {
  final CampaignWorld world;
  const CampaignWorldScreen({super.key, required this.world});

  @override
  State<CampaignWorldScreen> createState() => _CampaignWorldScreenState();
}

class _CampaignWorldScreenState extends State<CampaignWorldScreen> {
  @override
  Widget build(BuildContext context) {
    final map = widget.world.map;
    final save = SaveService.instance.data;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: map.sky)),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        AudioService.instance.sfx('click');
                        Navigator.pop(context);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: RT.card(color: Colors.white, radius: 12, border: 3),
                        child: const Icon(Icons.arrow_back, color: RT.ink),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(map.name.toUpperCase(), style: RT.chunky(size: 22, outline: 3), overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(map.tagline, style: RT.chunky(size: 13, color: Colors.white, outline: 1.5)),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: widget.world.levels.length,
                  itemBuilder: (_, i) {
                    final level = widget.world.levels[i];
                    final unlocked = Campaign.isUnlocked(level.id, save);
                    final stars = Campaign.starsFor(level, save);
                    // Cycle a small ocean palette per battle slot, boss always orange —
                    // mirrors the mockup's per-level colored cards.
                    const palette = [RT.sea1, RT.blue, RT.purple];
                    final bg = !unlocked ? Colors.grey.shade300 : (level.isBoss ? RT.orange : palette[i % palette.length]);
                    final onColor = unlocked ? Colors.white : Colors.grey.shade600;
                    return GestureDetector(
                      onTap: !unlocked
                          ? () => AudioService.instance.sfx('bounce')
                          : () => _startLevel(level),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: RT.card(color: bg, border: 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: unlocked ? Colors.white.withOpacity(0.3) : Colors.white.withOpacity(0.5),
                                  ),
                                  child: Center(
                                    child: !unlocked
                                        ? const Icon(Icons.lock, color: Colors.white, size: 20)
                                        : level.isBoss
                                            ? const Icon(Icons.emoji_events, color: Colors.white, size: 22)
                                            : Text('${i + 1}', style: RT.chunky(size: 18, color: Colors.white)),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        level.isBoss ? 'BOSS · ${level.captainName}' : level.captainName,
                                        style: RT.chunky(size: 16, color: onColor),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        !unlocked
                                            ? 'Locked'
                                            : level.isBoss
                                                ? 'Sea boss · toughest fight yet'
                                                : 'Battle ${i + 1}',
                                        style: RT.body(size: 11, color: onColor.withOpacity(0.85)),
                                      ),
                                    ],
                                  ),
                                ),
                                if (unlocked)
                                  Row(
                                    children: [
                                      for (int s = 0; s < 3; s++)
                                        Icon(s < stars ? Icons.star : Icons.star_border, color: Colors.white, size: 18),
                                    ],
                                  ),
                              ],
                            ),
                            if (unlocked) ...[
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  _infoChip(Icons.smart_toy, _difficultyLabel(level.aiDifficulty)),
                                  const SizedBox(width: 8),
                                  _infoChip(Icons.sailing, '${level.fleet.length} rafts'),
                                  const SizedBox(width: 8),
                                  _infoChip(Icons.groups, '${level.fleet.fold<int>(0, (s, e) => s + e.crew)} crew'),
                                  const Spacer(),
                                  const Icon(Icons.play_circle_fill, color: Colors.white, size: 30),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.24), borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Text(label, style: RT.body(size: 10, color: Colors.white, weight: FontWeight.w800)),
        ],
      ),
    );
  }

  String _difficultyLabel(AiDifficulty d) => switch (d) {
        AiDifficulty.easy => 'Easy',
        AiDifficulty.normal => 'Normal',
        AiDifficulty.hard => 'Hard',
        AiDifficulty.expert => 'Expert',
      };

  void _startLevel(CampaignLevel level) {
    AudioService.instance.sfx('fire');
    final (settings, players) = Campaign.matchFor(level);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GameScreen(settings: settings, players: players, mode: GameMode.vsAi, campaignLevel: level),
      ),
    ).then((_) => setState(() {})); // refresh stars/locks on return
  }
}
