import 'dart:io';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../engine/elevation.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import '../services/plan_exporter.dart';
import '../services/scan_store.dart';
import 'app_theme.dart';
import 'common.dart';
import 'elevation_painter.dart';
import 'home_screen.dart' show formatDate;

/// The 2D front-view drawing of a door or window measured without a room,
/// with all its measurements. Shown straight after its ✓ in the scanner.
class OpeningDrawingScreen extends StatefulWidget {
  const OpeningDrawingScreen({super.key, required this.opening, this.justScanned = false});

  final SavedOpening opening;

  /// Opened straight from the scanner: says so at the top.
  final bool justScanned;

  @override
  State<OpeningDrawingScreen> createState() => _OpeningDrawingScreenState();
}

class _OpeningDrawingScreenState extends State<OpeningDrawingScreen> {
  late SavedOpening o = widget.opening;

  LengthUnit get unit => AppSettings.unit.value;

  OpeningElevation get elevation => OpeningElevation.standalone(
        type: o.type,
        width: o.width,
        height: o.height,
        sill: o.sill,
        estimated: o.estimated,
      );

  Future<void> _update(SavedOpening next) async {
    setState(() => o = next);
    final all = await OpeningStore.load();
    await OpeningStore.save([for (final x in all) x.id == next.id ? next : x]);
  }

  Future<void> _rename() async {
    final v = await askText(context, title: 'Rename', initial: o.name, label: 'Name');
    if (v == null || v.trim().isEmpty) return;
    await _update(o.copyWith(name: v.trim()));
  }

  Future<void> _setRoom() async {
    final v = await askText(context,
        title: 'Room', initial: o.room, label: 'Room this ${o.type.label.toLowerCase()} is in');
    if (v == null || v.trim().isEmpty) return;
    await _update(o.copyWith(room: v.trim()));
  }

  Future<void> _edit(String what) async {
    final current = switch (what) {
      'width' => o.width,
      'height' => o.height ?? o.type.typicalHeight,
      _ => o.sill ?? OpeningElevation.typicalSill,
    };
    final v = await askLength(context,
        title: switch (what) {
          'width' => 'Width',
          'height' => 'Height',
          _ => 'Sill height',
        },
        unit: unit,
        initial: current);
    if (v == null || v.isNaN) return;
    await _update(switch (what) {
      // Typed from a tape: no longer the scanner's estimate.
      'width' => o.copyWith(width: v, estimated: false),
      'height' => o.copyWith(height: v, estimated: false),
      _ => o.copyWith(sill: v),
    });
  }

  Future<void> _delete() async {
    final ok = await confirm(context,
        title: 'Delete ${o.name}?', message: 'Its measurements and drawing are removed.');
    if (!ok) return;
    final all = await OpeningStore.load();
    await OpeningStore.save(all.where((x) => x.id != o.id).toList());
    if (mounted) Navigator.pop(context);
  }

  Future<void> _share() async {
    try {
      final png = await PlanExporter.renderElevationPng(elevation, unit,
          title: '${o.name} · ${o.type.label}');
      if (Platform.isAndroid || Platform.isIOS) {
        await Printing.sharePdf(
          bytes: await PlanExporter.imagePdf(png, o.name),
          filename: '${PlanExporter.safeName(o.name)}.pdf',
        );
      } else {
        final dir = await ScanStore.exportsDir();
        final f = File('${dir.path}${Platform.pathSeparator}${PlanExporter.safeName(o.name)}.png');
        await f.writeAsBytes(png);
        if (mounted) showMessage(context, 'Image saved to ${f.path}');
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Export failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final e = elevation;
    final color = o.type == OpeningType.window ? AppTheme.window : AppTheme.door;
    String len(double m) => '${o.estimated ? '≈ ' : ''}${formatLength(m, unit)}';
    final rows = <(String, String, String?)>[
      ('Room', o.room.trim().isEmpty ? 'Add room' : o.room.trim(), 'room'),
      ('Width', len(o.width), 'width'),
      ('Height', o.height == null ? 'not measured' : len(o.height!), 'height'),
      if (o.type == OpeningType.window)
        ('Sill height', o.sill == null ? 'not measured' : formatLength(o.sill!, unit), 'sill'),
      if (o.type == OpeningType.window && o.height != null && o.sill != null)
        ('Top above floor', formatLength(o.sill! + o.height!, unit), null),
      ('Area', o.height == null ? '—' : formatArea(o.width * o.height!, unit), null),
    ];
    return ValueListenableBuilder<LengthUnit>(
      valueListenable: AppSettings.unit,
      builder: (context, _, _) => Scaffold(
        appBar: AppBar(
          title: InkWell(
            onTap: _rename,
            borderRadius: BorderRadius.circular(AppTheme.radiusS),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o.name, overflow: TextOverflow.ellipsis),
              Text(
                  [
                    if (o.room.trim().isNotEmpty) o.room.trim(),
                    o.type.label,
                    formatDate(o.measuredAt),
                  ].join(' · '),
                  key: const Key('opening-room'),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          actions: [
            const UnitButton(compact: true),
            IconButton(
                tooltip: 'Share', onPressed: _share, icon: const Icon(Icons.ios_share_rounded)),
            IconButton(
                tooltip: 'Delete',
                onPressed: _delete,
                icon: Icon(Icons.delete_outline_rounded, color: cs.error)),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            if (widget.justScanned)
              Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: AppTheme.scan.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusL),
                  border: Border.all(color: AppTheme.scan.withValues(alpha: 0.35)),
                ),
                child: Row(children: [
                  const CircleAvatar(
                    radius: 16,
                    backgroundColor: AppTheme.scan,
                    foregroundColor: Colors.white,
                    child: Icon(Icons.check_rounded, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('${o.type.label} measured',
                        style: theme.textTheme.titleSmall),
                  ),
                ]),
              ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: AspectRatio(
                aspectRatio: 1.15,
                child: CustomPaint(painter: ElevationPainter(e: e, unit: unit)),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(children: [
                for (final (k, r) in rows.indexed) ...[
                  if (k > 0) const Divider(indent: 16, endIndent: 16),
                  ListTile(
                    leading: k == 0
                        ? Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(AppTheme.radiusS),
                            ),
                            child: Icon(
                                o.type == OpeningType.window
                                    ? Icons.window_outlined
                                    : Icons.door_front_door_outlined,
                                color: color,
                                size: 20),
                          )
                        : const SizedBox(width: 36),
                    title: Text(r.$1),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(r.$2,
                          style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontFeatures: AppTheme.tabular,
                              color: o.estimated && r.$3 != null ? AppTheme.door : null)),
                      if (r.$3 != null) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.edit_outlined, size: 16, color: cs.onSurfaceVariant),
                      ],
                    ]),
                    onTap: r.$3 == null
                        ? null
                        : () => r.$3 == 'room' ? _setRoom() : _edit(r.$3!),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 10),
            Text(
              [
                o.method.label,
                if (o.estimated) 'size estimated: check it with a tape',
                'measured without a room outline, so it is not on a floor plan',
              ].join('  ·  '),
              style: theme.textTheme.bodySmall?.copyWith(
                  color: o.estimated ? AppTheme.door : cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
