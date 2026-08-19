import 'package:flutter/material.dart';
import '../game/audio.dart';
import '../game/campaign.dart';
import '../game/models.dart';
import '../game/raft.dart';
import '../game/save.dart';
import '../theme.dart';
import 'raft_preview.dart';

class CampaignUpgradesScreen extends StatefulWidget {
  const CampaignUpgradesScreen({super.key});

  @override
  State<CampaignUpgradesScreen> createState() => _CampaignUpgradesScreenState();
}

class _CampaignUpgradesScreenState extends State<CampaignUpgradesScreen> {
  static const Map<UpgradeKind, IconData> _icons = {
    UpgradeKind.power: Icons.bolt,
    UpgradeKind.plating: Icons.shield,
    UpgradeKind.aim: Icons.gps_fixed,
  };

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
                    Text("CAPTAIN'S SHOP", style: RT.chunky(size: 22, outline: 3)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: RT.card(color: Colors.white, radius: 12, border: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.monetization_on, color: RT.yellow, size: 18),
                          const SizedBox(width: 4),
                          Text('${save.doubloons}', style: RT.chunky(size: 14, color: RT.ink)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  'Spend doubloons earned in the campaign to permanently upgrade your captain — these bonuses apply in every battle, not just the campaign.',
                  style: RT.chunky(size: 12, color: Colors.white, weight: FontWeight.w600, letterSpacing: 0.3),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    _raftSection(save, totalStars),
                    const SizedBox(height: 14),
                    _ammoSection(save),
                    const SizedBox(height: 14),
                    Text('CAPTAIN UPGRADES',
                        style: RT.body(size: 11, color: Colors.white, weight: FontWeight.w800, letterSpacing: 2)),
                    const SizedBox(height: 8),
                    ...List.generate(Upgrades.all.length, (i) {
                      final def = Upgrades.all[i];
                    final tier = save.upgradeTier(def.kind);
                    final maxed = tier >= def.tiers.length;
                    final next = maxed ? null : def.tiers[tier];
                    final canAfford = next != null && save.doubloons >= next.cost;
                    final hasStars = next != null && totalStars >= next.starsRequired;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: RT.card(color: Colors.white),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: RT.card(color: RT.purple, radius: 12, border: 3),
                                child: Icon(_icons[def.kind], color: Colors.white, size: 22),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(def.name, style: RT.chunky(size: 16, color: RT.ink)),
                                    Text(def.desc,
                                        style: RT.chunky(size: 11, color: RT.ink.withOpacity(0.6), weight: FontWeight.w600, letterSpacing: 0.2)),
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  for (int t = 0; t < def.tiers.length; t++)
                                    Icon(t < tier ? Icons.circle : Icons.circle_outlined, size: 12, color: RT.orange),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (maxed)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: RT.card(color: RT.green, radius: 12, border: 0),
                              child: Text('MAXED OUT', textAlign: TextAlign.center, style: RT.chunky(size: 13, color: Colors.white)),
                            )
                          else
                            GestureDetector(
                              onTap: !canAfford || !hasStars
                                  ? () => AudioService.instance.sfx('bounce')
                                  : () {
                                      final ok = SaveService.instance.purchaseUpgrade(def.kind);
                                      if (ok) {
                                        AudioService.instance.sfx('place');
                                        setState(() {});
                                      }
                                    },
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: RT.card(
                                  color: canAfford && hasStars ? RT.orange : Colors.grey.shade300,
                                  radius: 12,
                                  border: 3,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.monetization_on,
                                        size: 16, color: canAfford && hasStars ? Colors.white : Colors.grey),
                                    const SizedBox(width: 4),
                                    Text(
                                      !hasStars
                                          ? 'NEEDS ${next!.starsRequired} ★ TOTAL'
                                          : 'UPGRADE — ${next.cost}',
                                      style: RT.chunky(size: 13, color: canAfford && hasStars ? Colors.white : Colors.grey.shade600),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Raft upgrade track: crew capacity, hull unlocks and bonus HP, plus the
  /// hull/colour pickers for the raft the player already owns.
  Widget _raftSection(SaveData save, int totalStars) {
    final current = RaftTiers.at(save.raftTier);
    final next = RaftTiers.next(save.raftTier);
    final canAfford = next != null && save.doubloons >= next.cost;
    final hasStars = next != null && totalStars >= next.starsRequired;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: RT.card(color: Colors.white),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('YOUR RAFT', style: RT.chunky(size: 17, color: RT.ink)),
              const Spacer(),
              Text('${current.name} · ${current.crewCapacity} crew',
                  style: RT.body(size: 11, color: RT.ink.withOpacity(0.6), weight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 10),
          RaftPreview(loadout: save.raftLoadout),
          const SizedBox(height: 12),
          Text('HULL', style: RT.body(size: 10, color: RT.ink.withOpacity(0.6), weight: FontWeight.w800, letterSpacing: 1.4)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final h in RaftHull.all)
                _pickChip(
                  label: h.name.toUpperCase(),
                  selected: save.raftHullId == h.id,
                  locked: h.tierRequired > save.raftTier,
                  lockLabel: 'TIER ${h.tierRequired + 1}',
                  onTap: () {
                    save.raftHullId = h.id;
                    SaveService.instance.save();
                    setState(() {});
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('COLOUR', style: RT.body(size: 10, color: RT.ink.withOpacity(0.6), weight: FontWeight.w800, letterSpacing: 1.4)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int c = 0; c < raftColors.length; c++)
                GestureDetector(
                  onTap: () {
                    AudioService.instance.sfx('click');
                    save.raftColorIndex = c;
                    SaveService.instance.save();
                    setState(() {});
                  },
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: raftColorAt(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: save.raftColorIndex == c ? RT.ink : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (next == null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: RT.card(color: RT.green, radius: 12, border: 0),
              child: Text('RAFT FULLY UPGRADED',
                  textAlign: TextAlign.center, style: RT.chunky(size: 13, color: Colors.white)),
            )
          else
            GestureDetector(
              onTap: !canAfford || !hasStars
                  ? () => AudioService.instance.sfx('bounce')
                  : () {
                      if (SaveService.instance.purchaseRaftTier()) {
                        AudioService.instance.sfx('place');
                        setState(() {});
                      }
                    },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: RT.card(
                  color: canAfford && hasStars ? RT.orange : Colors.grey.shade300,
                  radius: 12,
                  border: 0,
                ),
                child: Text(
                  !hasStars
                      ? 'NEEDS ${next.starsRequired} ★ TOTAL'
                      : '${next.name.toUpperCase()} — ${next.cost} ◉  (${next.crewCapacity} CREW, +${next.hpBonus.round()} HP)',
                  textAlign: TextAlign.center,
                  style: RT.chunky(
                      size: 13, color: canAfford && hasStars ? Colors.white : Colors.grey.shade600),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Ammo restocking — the shop side of the design's limited-ammo weapons.
  Widget _ammoSection(SaveData save) {
    final buyable = Weapons.purchasable.where((w) => w.levelLock <= save.level).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: RT.card(color: Colors.white),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AMMO', style: RT.chunky(size: 17, color: RT.ink)),
          const SizedBox(height: 2),
          Text('Heavy ordnance is limited — restock between battles.',
              style: RT.body(size: 11, color: RT.ink.withOpacity(0.6))),
          const SizedBox(height: 10),
          for (final w in buyable) ...[
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(color: w.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${w.name}  ×${save.ammoFor(w.id)}',
                          style: RT.body(size: 13, color: RT.ink, weight: FontWeight.w800)),
                      Text(w.desc, style: RT.body(size: 10, color: RT.ink.withOpacity(0.55))),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: save.doubloons < w.packCost
                      ? () => AudioService.instance.sfx('bounce')
                      : () {
                          if (SaveService.instance.purchaseAmmo(w.id)) {
                            AudioService.instance.sfx('place');
                            setState(() {});
                          }
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: RT.card(
                      color: save.doubloons >= w.packCost ? RT.orange : Colors.grey.shade300,
                      radius: 12,
                      border: 0,
                    ),
                    child: Text('+${w.packSize} · ${w.packCost} ◉',
                        style: RT.body(
                            size: 11,
                            color: save.doubloons >= w.packCost ? Colors.white : Colors.grey.shade600,
                            weight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _pickChip({
    required String label,
    required bool selected,
    required bool locked,
    required String lockLabel,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        AudioService.instance.sfx(locked ? 'bounce' : 'click');
        if (!locked) onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: RT.card(
          color: locked ? Colors.grey.shade300 : (selected ? RT.orange : RT.cream),
          radius: 12,
          border: 0,
        ),
        child: Text(
          locked ? '$label · $lockLabel' : label,
          style: RT.body(
            size: 11,
            color: locked ? Colors.grey.shade600 : (selected ? Colors.white : RT.ink),
            weight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
