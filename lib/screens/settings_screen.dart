import 'package:flutter/material.dart';
import '../game/audio.dart';
import '../game/save.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final d = SaveService.instance.data;
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
                        SaveService.instance.save();
                        Navigator.pop(context);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: RT.card(color: Colors.white, radius: 12, border: 3),
                        child: const Icon(Icons.arrow_back, color: RT.ink),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('SETTINGS', style: RT.chunky(size: 26, outline: 3)),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    _slider('MUSIC VOLUME', d.musicVolume, (v) {
                      setState(() => d.musicVolume = v);
                      AudioService.instance.updateVolumes();
                    }),
                    _slider('SFX VOLUME', d.sfxVolume, (v) {
                      setState(() => d.sfxVolume = v);
                      AudioService.instance.sfx('click');
                    }),
                    _slider('CONTROL SENSITIVITY', d.sensitivity, (v) => setState(() => d.sensitivity = v), min: 0.4, max: 2.0),
                    _toggle('VIBRATION', d.vibration, (v) => setState(() => d.vibration = v)),
                    _toggle('TRAJECTORY PREVIEW', d.showTrajectory, (v) => setState(() => d.showTrajectory = v)),
                    _toggle('AIM ASSIST', d.aimAssist, (v) => setState(() => d.aimAssist = v)),
                    _qualityPicker(d),
                    const SizedBox(height: 10),
                    ChunkyButton(
                      label: 'RESET PROGRESS', icon: Icons.delete_forever, color: RT.red, fontSize: 16,
                      onPressed: () async {
                        AudioService.instance.sfx('explosion');
                        await SaveService.instance.reset();
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slider(String label, double value, ValueChanged<double> onChanged, {double min = 0, double max = 1}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: RT.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: RT.chunky(size: 14, color: RT.ink)),
          Slider(
            value: value.clamp(min, max),
            min: min, max: max,
            activeColor: RT.orange,
            inactiveColor: RT.ink.withOpacity(0.15),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: RT.card(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: RT.chunky(size: 14, color: RT.ink)),
          Switch(
            value: value,
            activeColor: RT.green,
            onChanged: (v) {
              AudioService.instance.sfx('click');
              onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  Widget _qualityPicker(SaveData d) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: RT.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('GRAPHICS QUALITY', style: RT.chunky(size: 14, color: RT.ink)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final (label, v) in [('LOW', 0), ('MED', 1), ('HIGH', 2)])
                GestureDetector(
                  onTap: () {
                    AudioService.instance.sfx('click');
                    setState(() => d.quality = v);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    decoration: RT.card(color: d.quality == v ? RT.orange : Colors.white, radius: 12, border: 3),
                    child: Text(label, style: RT.chunky(size: 12, color: d.quality == v ? Colors.white : RT.ink)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
