import 'package:flutter/material.dart';
import '../game/audio.dart';
import '../game/campaign.dart';
import '../game/save.dart';
import '../theme.dart';
import 'campaign_upgrades_screen.dart';
import 'campaign_world_screen.dart';

/// Campaign world select: a path of six seas, each unlocked by beating the
/// previous one's boss captain. The premise (deliberately light — this is
/// a casual arcade game, not a story-heavy one): you're a raft captain
/// making a name for yourself, one rival crew at a time.
class CampaignScreen extends StatelessWidget {
  const CampaignScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final save = SaveService.instance.data;
    final totalStars = Campaign.totalStars(save);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: RT.sunset),
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
                    Text('CAMPAIGN', style: RT.chunky(size: 24, outline: 3)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: RT.card(color: Colors.white, radius: 12, border: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star, color: RT.yellow, size: 18),
                          const SizedBox(width: 4),
                          Text('$totalStars/${Campaign.maxStars}', style: RT.chunky(size: 13, color: RT.ink)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: RT.card(color: RT.ink.withOpacity(0.75), radius: 16, border: 0),
                        child: Text(
                          'Prove you\'re the toughest captain on the water — take down every rival crew, sea by sea.',
                          style: RT.chunky(size: 12, color: Colors.white, weight: FontWeight.w600, letterSpacing: 0.3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          AudioService.instance.sfx('click');
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const CampaignUpgradesScreen()));
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: RT.card(color: RT.purple, radius: 14, border: 3),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.storefront, color: Colors.white, size: 20),
                              const SizedBox(width: 8),
                              Text('CAPTAIN\'S SHOP', style: RT.chunky(size: 14, color: Colors.white)),
                              const SizedBox(width: 10),
                              const Icon(Icons.monetization_on, color: RT.yellow, size: 18),
                              const SizedBox(width: 3),
                              Text('${save.doubloons}', style: RT.chunky(size: 14, color: Colors.white)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: Campaign.worlds.length,
                  itemBuilder: (_, i) {
                    final world = Campaign.worlds[i];
                    final map = world.map;
                    final unlocked = Campaign.isWorldUnlocked(world, save);
                    final worldStars = world.levels.fold<int>(0, (s, l) => s + Campaign.starsFor(l, save));
                    final worldMax = world.levels.length * 3;
                    final boss = world.levels.last;
                    return GestureDetector(
                      onTap: !unlocked
                          ? () => AudioService.instance.sfx('bounce')
                          : () {
                              AudioService.instance.sfx('click');
                              Navigator.push(context, MaterialPageRoute(builder: (_) => CampaignWorldScreen(world: world)));
                            },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: RT.card(color: unlocked ? Colors.white : Colors.grey.shade300),
                        child: Row(
                          children: [
                            Container(
                              width: 78,
                              height: 78,
                              margin: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(colors: unlocked ? map.sky : [Colors.grey, Colors.grey.shade400]),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: RT.ink, width: 3),
                              ),
                              child: Center(
                                child: Icon(unlocked ? map.icon : Icons.lock, size: 34, color: Colors.white),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('WORLD ${i + 1}: ${map.name.toUpperCase()}',
                                        style: RT.chunky(size: 14, color: unlocked ? RT.ink : Colors.grey)),
                                    const SizedBox(height: 2),
                                    Text(
                                      unlocked ? 'Boss: ${boss.captainName}' : 'Beat the previous world to unlock',
                                      style: RT.chunky(size: 11, color: (unlocked ? RT.ink : Colors.grey).withOpacity(0.65),
                                          weight: FontWeight.w600, letterSpacing: 0.3),
                                    ),
                                    if (unlocked) ...[
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          const Icon(Icons.star, color: RT.yellow, size: 15),
                                          const SizedBox(width: 3),
                                          Text('$worldStars/$worldMax', style: RT.chunky(size: 12, color: RT.ink)),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (unlocked) const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: Icon(Icons.chevron_right, color: RT.ink, size: 26),
                            ),
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
}
