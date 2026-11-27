import 'package:flutter/material.dart';

import '../capture/ar_measure.dart';
import '../services/app_settings.dart';
import 'app_theme.dart';
import 'brand.dart';

/// Explains how to scan before the camera opens. Pops `true` to start.
class ScanGuideScreen extends StatefulWidget {
  const ScanGuideScreen({super.key, required this.method});

  final ScanMethod method;

  @override
  State<ScanGuideScreen> createState() => _ScanGuideScreenState();
}

class _ScanGuideScreenState extends State<ScanGuideScreen> {
  bool dontShow = AppSettings.skipScanGuide;

  List<(IconData, String, String)> get _steps => widget.method ==
          ScanMethod.lidar
      ? const [
          (
            Icons.light_mode_outlined,
            'Good lighting',
            'Turn on the lights and open curtains so the camera sees clearly.'
          ),
          (
            Icons.threesixty_rounded,
            'Walk the room',
            'Slowly point the camera at every wall, the floor and the ceiling.'
          ),
          (
            Icons.sensor_door_outlined,
            'Doors and windows',
            'They are detected automatically. Pause briefly in front of each.'
          ),
          (
            Icons.check_circle_outline_rounded,
            'Finish',
            'Tap Done when the outline is complete to see your floor plan.'
          ),
        ]
      : const [
          (
            Icons.grid_on_rounded,
            'Detect the floor',
            'Point the camera at the floor and move slowly until it is '
                'highlighted in teal.'
          ),
          (
            Icons.threesixty_rounded,
            'Walk along every wall',
            'Walk slowly around the room, 1–2 m from the walls, with the '
                'phone facing the wall. Don\'t just turn on the spot: the '
                'camera measures distance from sideways movement.'
          ),
          (
            Icons.auto_awesome_outlined,
            'Watch the progress',
            'The small map shows each wall: teal once measured, dashed '
                'amber while still estimated. The ring around it fills as '
                'you cover the room.'
          ),
          (
            Icons.sensor_door_outlined,
            'Doors and windows',
            'They are found and counted as you go: pause for a moment with '
                'each one in view. One that was missed can be added in the '
                'Door or Window tab, and its frame adjusted side by side.'
          ),
          (
            Icons.check_circle_outline_rounded,
            'It finishes by itself',
            'When every wall is measured a ✓ appears and your floor plan '
                'opens with the doors and windows counted. Tap the ✓ to keep '
                'scanning.'
          ),
        ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final lidar = widget.method == ScanMethod.lidar;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const BrandLogo(size: 28),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.scan.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          lidar
                              ? Icons.sensors_rounded
                              : Icons.photo_camera_outlined,
                          size: 15,
                          color: AppTheme.scan),
                      const SizedBox(width: 6),
                      Text(
                        lidar ? 'LiDAR scan' : 'Camera scan',
                        style: theme.textTheme.labelMedium?.copyWith(
                            color: AppTheme.scan, fontWeight: FontWeight.w700),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                Text('How to scan', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  lidar
                      ? 'Your device has a LiDAR sensor, so the room is '
                          'measured automatically.'
                      : 'Takes about a minute for a typical room.',
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                for (final (i, s) in _steps.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: cs.primaryContainer,
                                borderRadius:
                                    BorderRadius.circular(AppTheme.radiusM),
                              ),
                              child: Icon(s.$1,
                                  size: 22, color: cs.onPrimaryContainer),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'STEP ${i + 1}',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(color: cs.primary),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(s.$2,
                                      style: theme.textTheme.titleMedium),
                                  const SizedBox(height: 4),
                                  Text(s.$3,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                              color: cs.onSurfaceVariant)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Material(
            color: cs.surface,
            shape: Border(top: BorderSide(color: cs.outlineVariant)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
              child: Column(children: [
                SwitchListTile(
                  value: dontShow,
                  onChanged: (v) => setState(() => dontShow = v),
                  contentPadding: EdgeInsets.zero,
                  title: Text("Don't show this again",
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500)),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Start scanning'),
                    onPressed: () async {
                      await AppSettings.setSkipScanGuide(dontShow);
                      if (context.mounted) Navigator.pop(context, true);
                    },
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
