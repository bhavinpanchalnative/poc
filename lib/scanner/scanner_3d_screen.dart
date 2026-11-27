import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import '../services/plan_exporter.dart';
import '../ui/app_theme.dart';
import '../ui/common.dart';
import 'cad_export.dart';
import 'room_3d_view.dart';
import 'room_model_3d.dart';

/// The scanned room — or every room of a floor map — in 3D, with its
/// measurements, and export to CAD (DXF) and 3D (OBJ) software.
///
/// Opens on the 2D plan seen from above and swings up into 3D. Drag to turn
/// round, pinch to zoom, two fingers to move, double tap to reset; tap a
/// wall for its length.
class Scanner3DScreen extends StatefulWidget {
  const Scanner3DScreen({super.key, required this.rooms, required this.title});

  final List<RoomInput> rooms;
  final String title;

  @override
  State<Scanner3DScreen> createState() => _Scanner3DScreenState();
}

class _Scanner3DScreenState extends State<Scanner3DScreen> {
  late final RoomModel3D model = RoomModel3D.build(widget.rooms);
  final controller = Room3DController();
  bool labels = true, furniture = true, seeThrough = true;
  (int, int)? selected;

  @override
  void initState() {
    super.initState();
    // Swing from the plan up into 3D once the screen is in.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.perspective());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _export(String kind) async {
    final unit = AppSettings.unit.value;
    try {
      switch (kind) {
        case 'dxf':
          final f = await CadExporter.saveDxf(widget.rooms, unit, name: widget.title);
          if (mounted) await deliverFile(context, f, what: 'CAD drawing (DXF)');
        case 'obj':
          final files = await CadExporter.saveObj(model, name: widget.title);
          if (mounted) await deliverFiles(context, files, what: '3D model (OBJ)');
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Export failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<LengthUnit>(
      valueListenable: AppSettings.unit,
      builder: (context, unit, _) => Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title, overflow: TextOverflow.ellipsis),
              Text(widget.rooms.length > 1 ? '3D floor · ${widget.rooms.length} rooms' : '3D room',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
          actions: [
            const UnitButton(compact: true),
            PopupMenuButton<String>(
              tooltip: 'Export',
              icon: const Icon(Icons.ios_share_rounded),
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'dxf',
                    child: ListTile(
                        leading: Icon(Icons.architecture_outlined),
                        title: Text('CAD drawing (DXF)'))),
                PopupMenuItem(
                    value: 'obj',
                    child: ListTile(
                        leading: Icon(Icons.view_in_ar_outlined),
                        title: Text('3D model (OBJ)'))),
              ],
            ),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [scheme.surfaceContainerHighest, scheme.surface],
                    ),
                  ),
                  child: Room3DView(
                    model: model,
                    controller: controller,
                    unit: unit,
                    showLabels: labels,
                    showFurniture: furniture,
                    seeThrough: seeThrough,
                    selectedWall: selected,
                    onWallTap: (r, w) => setState(
                        () => selected = selected == (r, w) ? null : (r, w)),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                top: 12,
                child: _ViewButtons(controller: controller),
              ),
              if (selected != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: _WallCard(
                    room: widget.rooms[selected!.$1],
                    wall: selected!.$2,
                    unit: unit,
                    showRoom: widget.rooms.length > 1,
                    onClose: () => setState(() => selected = null),
                  ),
                ),
            ]),
          ),
          _Toggles(
            labels: labels,
            furniture: furniture,
            seeThrough: seeThrough,
            onLabels: (v) => setState(() => labels = v),
            onFurniture: (v) => setState(() => furniture = v),
            onSeeThrough: (v) => setState(() => seeThrough = v),
          ),
          _Stats(rooms: widget.rooms, unit: unit),
        ]),
      ),
    );
  }
}

class _ViewButtons extends StatelessWidget {
  const _ViewButtons({required this.controller});
  final Room3DController controller;

  @override
  Widget build(BuildContext context) {
    Widget b(String tip, IconData icon, VoidCallback f) => IconButton.filledTonal(
        tooltip: tip, onPressed: f, icon: Icon(icon, size: 20));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      b('Plan (2D)', Icons.crop_square_rounded, controller.topDown),
      const SizedBox(height: 6),
      b('3D view', Icons.view_in_ar_rounded, controller.perspective),
      const SizedBox(height: 6),
      b('Turn 90°', Icons.rotate_90_degrees_ccw_rounded, controller.turn),
      const SizedBox(height: 6),
      b('Zoom in', Icons.add_rounded, () => controller.scaleBy(1.25)),
      const SizedBox(height: 6),
      b('Zoom out', Icons.remove_rounded, () => controller.scaleBy(0.8)),
    ]);
  }
}

class _Toggles extends StatelessWidget {
  const _Toggles({
    required this.labels,
    required this.furniture,
    required this.seeThrough,
    required this.onLabels,
    required this.onFurniture,
    required this.onSeeThrough,
  });

  final bool labels, furniture, seeThrough;
  final ValueChanged<bool> onLabels, onFurniture, onSeeThrough;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Row(children: [
          FilterChip(
              label: const Text('See-through walls'),
              selected: seeThrough,
              onSelected: onSeeThrough),
          const SizedBox(width: 8),
          FilterChip(label: const Text('Lengths'), selected: labels, onSelected: onLabels),
          const SizedBox(width: 8),
          FilterChip(
              label: const Text('Furniture'), selected: furniture, onSelected: onFurniture),
        ]),
      );
}

class _Stats extends StatelessWidget {
  const _Stats({required this.rooms, required this.unit});
  final List<RoomInput> rooms;
  final LengthUnit unit;

  @override
  Widget build(BuildContext context) {
    final area = rooms.fold(0.0, (t, r) => t + r.plan.area);
    final perimeter = rooms.fold(0.0, (t, r) => t + r.plan.perimeter);
    final wallArea = rooms.fold(
        0.0,
        (t, r) =>
            t + (r.heightMeasured ? PlanExporter.wallArea(r.plan) : 0));
    final measured = rooms.where((r) => r.heightMeasured).toList();
    final heights = {for (final r in measured) formatLength(r.height, unit)};
    final scheme = Theme.of(context).colorScheme;

    Widget stat(String k, String v) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(v,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ]),
        );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            stat('Floor area', formatArea(area, unit)),
            stat('Perimeter', formatLength(perimeter, unit)),
            stat('Ceiling', heights.isEmpty ? '—' : heights.join(' / ')),
            if (wallArea > 0) stat('Wall area', formatArea(wallArea, unit)),
          ]),
          if (measured.length < rooms.length) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.info_outline_rounded, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Ceiling height not measured by this scan: walls are shown '
                  '${formatLength(defaultCeilingHeight, unit)} high. LiDAR scans measure it.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _WallCard extends StatelessWidget {
  const _WallCard({
    required this.room,
    required this.wall,
    required this.unit,
    required this.showRoom,
    required this.onClose,
  });

  final RoomInput room;
  final int wall;
  final LengthUnit unit;
  final bool showRoom;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = room.plan;
    final openings = p.openings.where((o) => o.wallIndex == wall).toList();
    final h = room.height;
    var area = p.wallLength(wall) * h;
    for (final o in openings) {
      final (b, t) = openingVerticalSpan(o, h);
      area -= o.width * (t - b);
    }
    final parts = [
      formatLength(p.wallLength(wall), unit),
      if (room.heightMeasured) '${formatLength(h, unit)} high',
      if (room.heightMeasured) formatArea(area < 0 ? 0 : area, unit),
      for (final o in openings) '${o.type.label} ${formatLength(o.width, unit)}',
    ];
    return Card(
      elevation: 3,
      child: ListTile(
        leading: const Icon(Icons.straighten_rounded, color: AppTheme.brand),
        title: Text('${showRoom ? '${room.scan.name} · ' : ''}Wall ${wall + 1}'),
        subtitle: Text(parts.join(' · ')),
        trailing: IconButton(icon: const Icon(Icons.close_rounded), onPressed: onClose),
      ),
    );
  }
}
