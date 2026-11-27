import 'dart:io';

import 'package:flutter/material.dart';

import '../engine/units.dart';
import '../services/app_settings.dart';
import '../services/laser_meter.dart';

/// Laser meters are only used on phones (Bluetooth LE).
bool get laserAvailable => Platform.isAndroid || Platform.isIOS;

/// Connects (or disconnects) the Bluetooth laser meter. Returns true when
/// one is connected when the sheet closes.
Future<bool> showLaserSheet(BuildContext context) async {
  final laser = LaserMeter.instance;
  if (laser.state == LaserState.off && laser.error == null) laser.connect();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => const _LaserSheet(),
  );
  return laser.connected;
}

class _LaserSheet extends StatelessWidget {
  const _LaserSheet();

  @override
  Widget build(BuildContext context) {
    final laser = LaserMeter.instance;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: laser,
      builder: (context, _) {
        final busy = laser.state == LaserState.searching || laser.state == LaserState.connecting;
        final title = switch (laser.state) {
          LaserState.off => 'Laser meter',
          LaserState.searching => 'Looking for a laser…',
          LaserState.connecting => 'Connecting to ${laser.deviceName}…',
          LaserState.connected => laser.deviceName ?? 'Laser connected',
        };
        final last = laser.last;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(laser.connected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_rounded,
                    color: laser.connected ? cs.primary : cs.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                if (busy) const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
              ]),
              const SizedBox(height: 12),
              Text(
                laser.connected
                    ? 'Select a length box in the app and press the measure button on the laser: '
                        'the distance goes straight in.'
                    : laser.error ??
                        'Switch on your Leica DISTO and turn on its Bluetooth (the Bluetooth key). '
                            'Keep it close to the phone.',
                style: TextStyle(color: laser.error != null && !laser.connected ? cs.error : cs.onSurfaceVariant),
              ),
              if (laser.connected && last != null) ...[
                const SizedBox(height: 12),
                Text('Last: ${formatLength(last, AppSettings.unit.value)}',
                    style: Theme.of(context).textTheme.titleLarge),
              ],
              const SizedBox(height: 20),
              Row(children: [
                if (laser.state != LaserState.off)
                  OutlinedButton(onPressed: laser.disconnect, child: Text(laser.connected ? 'Disconnect' : 'Stop'))
                else
                  FilledButton.icon(
                    onPressed: laser.connect,
                    icon: const Icon(Icons.bluetooth_searching_rounded),
                    label: Text(laser.error == null ? 'Connect' : 'Try again'),
                  ),
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
              ]),
            ]),
          ),
        );
      },
    );
  }
}
