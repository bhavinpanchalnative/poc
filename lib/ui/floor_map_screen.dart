import 'dart:io';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../engine/floor_map.dart';
import '../engine/floor_plan_builder.dart';
import '../engine/geometry.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import '../services/plan_exporter.dart';
import '../services/scan_store.dart';
import '../scanner/cad_export.dart';
import '../scanner/room_model_3d.dart';
import '../scanner/scanner_3d_screen.dart';
import 'app_theme.dart';
import 'common.dart';
import 'floor_map_painter.dart';
import 'plan_painter.dart';
import 'plan_screen.dart';

/// A whole flat or floor: saved rooms placed together, each with its
/// measurements, doors and windows, and the total area.
class FloorMapScreen extends StatefulWidget {
  const FloorMapScreen({super.key, required this.map});

  final FloorMap map;

  @override
  State<FloorMapScreen> createState() => _FloorMapScreenState();
}

class _FloorMapScreenState extends State<FloorMapScreen> {
  late final FloorMap map = widget.map;
  Map<String, RoomScan> scans = {};
  List<PlacedRoom> rooms = [];
  bool loading = true;
  bool dimensions = true;
  int? selected;

  // Room drag in progress.
  MapLayout? _dragLayout;
  Vec2? _grab; // where the finger took hold, in map coordinates
  Vec2? _startOffset;

  LengthUnit get unit => AppSettings.unit.value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await ScanStore.loadAll();
    if (!mounted) return;
    setState(() {
      scans = {for (final s in all) s.id: s};
      // Rooms deleted since they were added are dropped from the map.
      map.rooms.removeWhere((r) => !scans.containsKey(r.scanId));
      rooms = placeRooms(map, scans);
      if (selected != null && selected! >= rooms.length) selected = null;
      loading = false;
    });
  }

  Future<void> _save() async {
    rooms = placeRooms(map, scans);
    setState(() {});
    await MapStore.save(map);
  }

  Future<void> _rename() async {
    final v = await askText(context,
        title: 'Rename floor map', initial: map.name, label: 'Name');
    if (v == null || v.trim().isEmpty) return;
    map.name = v.trim();
    await _save();
  }

  Future<void> _delete() async {
    final ok = await confirm(context,
        title: 'Delete "${map.name}"?',
        message: 'The map is removed. Its rooms stay saved.');
    if (!ok) return;
    await MapStore.delete(map.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addRoom() async {
    final onMap = map.rooms.map((r) => r.scanId).toSet();
    final free = scans.values.where((s) => !onMap.contains(s.id)).toList();
    if (free.isEmpty) {
      showMessage(
          context,
          scans.isEmpty
              ? 'Scan or enter a room first, then add it here.'
              : 'All your rooms are already on this map.');
      return;
    }
    final picked = await showModalBottomSheet<RoomScan>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text('Add a room',
                    style: Theme.of(ctx).textTheme.titleLarge),
                subtitle: const Text('Choose one of your saved rooms.')),
            for (final s in free)
              () {
                FloorPlan? p;
                try {
                  p = const FloorPlanBuilder().build(s);
                } on PlanException {
                  p = null;
                }
                return ListTile(
                  enabled: p != null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  leading: Container(
                    width: 48,
                    height: 48,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surface,
                      borderRadius: BorderRadius.circular(AppTheme.radiusS),
                      border: Border.all(
                          color: Theme.of(ctx).colorScheme.outlineVariant),
                    ),
                    child: CustomPaint(
                      painter: PlanThumbnailPainter(p,
                          fill: Theme.of(ctx)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                          stroke: Theme.of(ctx).colorScheme.primary),
                    ),
                  ),
                  title: Text(s.name),
                  subtitle: Text(
                      p == null
                          ? 'Plan needs fixing first'
                          : formatArea(p.area, unit),
                      style: const TextStyle(fontFeatures: AppTheme.tabular)),
                  onTap: () => Navigator.pop(ctx, s),
                );
              }(),
          ]),
        ),
      ),
    );
    if (picked == null) return;
    final plan = const FloorPlanBuilder().build(picked);
    map.rooms.add(MapRoom(
        scanId: picked.id, offset: offsetForNewRoom(rooms, plan)));
    await _save();
    if (!mounted) return;
    setState(() => selected = rooms.length - 1);
    if (mounted && rooms.length > 1) {
      showMessage(context, 'Drag the room into place. It snaps to the others.');
    }
  }

  Future<void> _rotate(int k) async {
    rooms[k].place.quarterTurns = (rooms[k].place.quarterTurns + 1) % 4;
    await _save();
  }

  Future<void> _remove(int k) async {
    map.rooms.remove(rooms[k].place);
    selected = null;
    await _save();
  }

  Future<void> _openRoom(int k) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => PlanScreen(scan: rooms[k].scan, saved: true)),
    );
    await _load();
  }

  Future<void> _export(String kind) async {
    if (rooms.isEmpty) return;
    try {
      switch (kind) {
        case 'png':
          final f = await PlanExporter.saveMapPng(map, rooms, unit);
          if (mounted) await deliverFile(context, f, what: 'Image');
        case 'pdf':
          final f = await PlanExporter.saveMapPdf(map, rooms, unit);
          if (mounted) await deliverFile(context, f, what: 'PDF');
        case 'share':
          final bytes = await PlanExporter.buildMapPdf(map, rooms, unit);
          await Printing.sharePdf(
              bytes: bytes, filename: '${PlanExporter.safeName(map.name)}.pdf');
        case 'csv':
          final f = await PlanExporter.saveCsv(
              [for (final r in rooms) (r.scan, r.plan)], unit,
              name: map.name);
          if (mounted) await deliverFile(context, f, what: 'Spreadsheet (CSV)');
        case 'dxf':
          final f = await CadExporter.saveDxf(
              [for (final r in rooms) RoomInput.placed(r)], unit,
              name: map.name);
          if (mounted) await deliverFile(context, f, what: 'CAD drawing (DXF)');
        case 'obj':
          final files = await CadExporter.saveObj(
              RoomModel3D.build([for (final r in rooms) RoomInput.placed(r)]),
              name: map.name);
          if (mounted) await deliverFiles(context, files, what: '3D model (OBJ)');
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Export failed: $e');
    }
  }

  // ---------------------------------------------------------------- canvas

  int? _hitRoom(MapLayout l, Offset pos) {
    final p = l.toMap(pos);
    // Topmost (last drawn) first.
    for (var k = rooms.length - 1; k >= 0; k--) {
      if (rooms[k].contains(p)) return k;
    }
    return null;
  }

  void _dragStart(MapLayout l, Offset pos) {
    final k = _hitRoom(l, pos);
    if (k == null) return;
    setState(() {
      selected = k;
      _dragLayout = l;
      _grab = l.toMap(pos);
      _startOffset = rooms[k].place.offset;
    });
  }

  void _dragUpdate(Offset pos) {
    final l = _dragLayout, grab = _grab, start = _startOffset, k = selected;
    if (l == null || grab == null || start == null || k == null) return;
    final r = rooms[k];
    r.place.offset = start + (l.toMap(pos) - grab);
    final others = [
      for (var i = 0; i < rooms.length; i++)
        if (i != k) rooms[i].corners,
    ];
    // Snap distance: about 14 px on screen.
    r.place.offset =
        r.place.offset + snapOffset(r.corners, others, tolerance: 14 / l.scale);
    setState(() {});
  }

  Future<void> _dragEnd() async {
    if (_dragLayout == null) return;
    setState(() {
      _dragLayout = null;
      _grab = null;
      _startOffset = null;
    });
    await _save();
  }

  Widget _canvas() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final layout = _dragLayout ?? MapLayout.fit(rooms, size);
        return GestureDetector(
          onTapUp: (d) => setState(() {
            final k = _hitRoom(layout, d.localPosition);
            selected = k == selected ? null : k;
          }),
          onPanStart: (d) => _dragStart(layout, d.localPosition),
          onPanUpdate: (d) => _dragUpdate(d.localPosition),
          onPanEnd: (_) => _dragEnd(),
          child: CustomPaint(
            size: size,
            painter: FloorMapPainter(
              rooms: rooms,
              unit: unit,
              selected: selected,
              layout: layout,
              dimensions: dimensions,
            ),
          ),
        );
      }),
    );
  }

  /// A labelled headline number in the panel.
  Widget _stat(String label, String value, {bool big = true}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style:
                theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: (big
                    ? theme.textTheme.headlineMedium
                    : theme.textTheme.titleLarge)
                ?.copyWith(
                    fontFeatures: AppTheme.tabular, color: cs.onSurface),
          ),
        ),
      ],
    );
  }

  ButtonStyle get _tonal => FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      );

  Widget _panel() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final k = selected;
    final Widget content;
    if (k != null && k < rooms.length) {
      final r = rooms[k];
      final size = r.plan.overallSize;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(r.scan.name,
              overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
                flex: 4, child: _stat('Floor area', formatArea(r.plan.area, unit))),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: _stat(
                  'Overall size',
                  '${formatLength(size.width, unit)} × ${formatLength(size.depth, unit)}',
                  big: false),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            [
              for (final t in [OpeningType.door, OpeningType.window])
                () {
                  final k = r.plan.openings.where((o) => o.type == t).length;
                  return '$k ${t.label.toLowerCase()}${k == 1 ? '' : 's'}';
                }(),
            ].join('  ·  '),
            style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant, fontFeatures: AppTheme.tabular),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
                style: _tonal,
                onPressed: () => _rotate(k),
                icon: const Icon(Icons.rotate_90_degrees_ccw_rounded, size: 18),
                label: const Text('Rotate')),
            FilledButton.tonalIcon(
                style: _tonal,
                onPressed: () => _openRoom(k),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open plan')),
            FilledButton.tonalIcon(
                style: _tonal.copyWith(
                  backgroundColor: WidgetStatePropertyAll(
                      AppTheme.danger.withValues(alpha: 0.12)),
                  foregroundColor:
                      const WidgetStatePropertyAll(AppTheme.danger),
                ),
                onPressed: () => _remove(k),
                icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                label: const Text('Remove from map')),
          ]),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rooms.isEmpty)
            Text('No rooms yet', style: theme.textTheme.titleLarge)
          else
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                  flex: 3,
                  child:
                      _stat('Total area', formatArea(totalArea(rooms), unit))),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: _stat(rooms.length == 1 ? 'Room' : 'Rooms',
                    '${rooms.length}'),
              ),
            ]),
          const SizedBox(height: 6),
          Text(
            rooms.isEmpty
                ? 'Add your saved rooms to build the floor map.'
                : 'Drag rooms to arrange them; they snap wall to wall. '
                    'Tap a room for more.',
            style:
                theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _addRoom,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add room'),
          ),
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppTheme.radiusXL)),
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: SizedBox(width: double.infinity, child: content),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LengthUnit>(
      valueListenable: AppSettings.unit,
      builder: (context, _, _) => Scaffold(
        appBar: AppBar(
          titleSpacing: 20,
          title: InkWell(
            onTap: _rename,
            borderRadius: BorderRadius.circular(AppTheme.radiusS),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(map.name, overflow: TextOverflow.ellipsis),
                  Text('Floor map',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          actions: [
            const UnitButton(compact: true),
            IconButton(
              tooltip: '3D view',
              icon: const Icon(Icons.view_in_ar_rounded),
              onPressed: rooms.isEmpty
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                          builder: (_) => Scanner3DScreen(
                              rooms: [for (final r in rooms) RoomInput.placed(r)],
                              title: map.name))),
            ),
            PopupMenuButton<String>(
              tooltip: 'Export',
              icon: const Icon(Icons.ios_share_rounded),
              enabled: rooms.isNotEmpty,
              onSelected: _export,
              itemBuilder: (_) => [
                if (Platform.isAndroid || Platform.isIOS)
                  const PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                          leading: Icon(Icons.share_outlined),
                          title: Text('Share PDF'))),
                const PopupMenuItem(
                    value: 'pdf',
                    child: ListTile(
                        leading: Icon(Icons.picture_as_pdf_outlined),
                        title: Text('Save PDF'))),
                const PopupMenuItem(
                    value: 'png',
                    child: ListTile(
                        leading: Icon(Icons.image_outlined),
                        title: Text('Save image'))),
                const PopupMenuItem(
                    value: 'csv',
                    child: ListTile(
                        leading: Icon(Icons.table_chart_outlined),
                        title: Text('Spreadsheet (CSV)'))),
                const PopupMenuItem(
                    value: 'dxf',
                    child: ListTile(
                        leading: Icon(Icons.architecture_outlined),
                        title: Text('CAD drawing (DXF)'))),
                const PopupMenuItem(
                    value: 'obj',
                    child: ListTile(
                        leading: Icon(Icons.view_in_ar_outlined),
                        title: Text('3D model (OBJ)'))),
              ],
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    _rename();
                  case 'dims':
                    setState(() => dimensions = !dimensions);
                  case 'delete':
                    _delete();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                        leading: Icon(Icons.drive_file_rename_outline),
                        title: Text('Rename'))),
                CheckedPopupMenuItem(
                    value: 'dims',
                    checked: dimensions,
                    child: const Text('Show wall lengths')),
                const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                        leading: Icon(Icons.delete_outline_rounded,
                            color: AppTheme.danger),
                        title: Text('Delete map',
                            style: TextStyle(color: AppTheme.danger)))),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                Expanded(
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: _canvas(),
                    ),
                  ),
                ),
                _panel(),
              ]),
      ),
    );
  }
}
