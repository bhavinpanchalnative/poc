import 'package:flutter/material.dart';

import '../capture/ar_measure.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import '../services/scan_store.dart';
import 'app_theme.dart';
import 'common.dart';
import 'home_screen.dart' show formatDate;
import 'plan_screen.dart' show lineParts;

/// Stand-alone distance measurements: measure the straight line between any
/// two points with the camera, without scanning a room.
class DistancesScreen extends StatefulWidget {
  const DistancesScreen({super.key, this.measureOnOpen = false});

  /// Go straight to the camera when the screen opens.
  final bool measureOnOpen;

  @override
  State<DistancesScreen> createState() => _DistancesScreenState();
}

class _DistancesScreenState extends State<DistancesScreen> {
  List<MeasuredLine> lines = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    LineStore.load().then((l) {
      if (!mounted) return;
      setState(() {
        lines = l;
        loading = false;
      });
      if (widget.measureOnOpen) _measure();
    });
  }

  Future<void> _measure() async {
    ({List<MeasuredLine> lines, List<SavedOpening> openings})? result;
    try {
      result = await RoomScanner.measureLines(first: lines.length + 1);
    } on ScanFailure catch (e) {
      if (mounted) showMessage(context, e.message);
      return;
    }
    if (result == null || !mounted) return;
    var got = result.lines;
    var doors = result.openings;
    if (got.isEmpty && doors.isEmpty) return;
    // The user names each line, door and window measured (mandatory), and
    // says which room the doors / windows are in.
    final unit = AppSettings.unit.value;
    String len(double m) => formatLength(m, unit);
    final askRoom = doors.isNotEmpty;
    final first = askRoom ? 1 : 0;
    final names = await askNames(context,
        title: got.length + doors.length == 1
            ? 'Name this ${got.isEmpty ? doors.first.type.label.toLowerCase() : 'line'}'
            : 'Name your measurements',
        labels: [
          if (askRoom) 'Room',
          for (final o in doors)
            '${o.type.label} · ${len(o.width)}${o.height == null ? '' : ' × ${len(o.height!)}'}',
          for (final l in got) 'Line · ${len(l.length)}',
        ]);
    if (!mounted) return;
    doors = [
      for (var i = 0; i < doors.length; i++)
        doors[i].copyWith(name: names[first + i], room: names[0]),
    ];
    got = [
      for (var i = 0; i < got.length; i++)
        got[i].copyWith(name: names[first + doors.length + i]),
    ];
    if (doors.isNotEmpty) {
      await OpeningStore.save([...doors.reversed, ...await OpeningStore.load()]);
      if (mounted) {
        showMessage(context,
            'Saved to History: ${doors.length} ${doors.length == 1 ? 'door / window' : 'doors / windows'}.');
      }
    }
    if (!mounted || got.isEmpty) return;
    setState(() => lines = [...got.reversed, ...lines]);
    await LineStore.save(lines);
  }

  Future<void> _rename(int k) async {
    final v = await askText(
      context,
      title: 'Name this measurement',
      initial: lines[k].name,
      label: 'Name',
    );
    if (v == null || v.trim().isEmpty) return;
    setState(() => lines[k] = lines[k].copyWith(name: v.trim()));
    await LineStore.save(lines);
  }

  Future<void> _remove(int k) async {
    setState(() => lines.removeAt(k));
    await LineStore.save(lines);
  }

  Widget _empty(ThemeData theme) {
    final cs = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 112),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  gradient: AppTheme.heroGradient,
                  borderRadius: BorderRadius.circular(AppTheme.radiusXL),
                ),
                child: const Icon(Icons.straighten_rounded,
                    size: 40, color: Colors.white),
              ),
              const SizedBox(height: 22),
              Text(
                'Measure between two points',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(
                'Tap Measure. Aim: point the crosshair at each end '
                'and tap. Touch: on plain walls where the crosshair '
                'stays red, hold the phone on each end and tap; no '
                'surface is needed.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(ThemeData theme, LengthUnit unit, int k) {
    final cs = theme.colorScheme;
    final l = lines[k];
    final parts = lineParts(l, unit);
    final meta = [
      l.name,
      if (l.measuredAt != null) formatDate(l.measuredAt!),
    ].join('  ·  ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _rename(k),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.lineMark.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusM),
              ),
              child: const Icon(Icons.straighten_rounded,
                  color: AppTheme.lineMark, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      if (l.estimated)
                        const TextSpan(
                            text: '≈ ',
                            style: TextStyle(color: AppTheme.door)),
                      TextSpan(text: formatLength(l.length, unit)),
                    ]),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontFeatures: AppTheme.tabular,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (parts != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      parts,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontFeatures: AppTheme.tabular,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20, color: cs.onSurfaceVariant),
              onPressed: () => _remove(k),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<LengthUnit>(
      valueListenable: AppSettings.unit,
      builder: (context, unit, _) => Scaffold(
        appBar: AppBar(
          titleSpacing: 20,
          title: const Text('Distances'),
          actions: const [UnitButton(), SizedBox(width: 12)],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _measure,
          elevation: 0,
          highlightElevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusM)),
          icon: const Icon(Icons.straighten_rounded),
          label: const Text('Measure'),
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : lines.isEmpty
            ? _empty(theme)
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 112),
                itemCount: lines.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, k) => _item(theme, unit, k),
              ),
      ),
    );
  }
}
