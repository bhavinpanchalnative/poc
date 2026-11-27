import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:panorama_viewer/panorama_viewer.dart';
import 'package:printing/printing.dart';

import '../engine/floor_plan_builder.dart';
import '../engine/geometry.dart';
import '../engine/models.dart';
import '../engine/plan_editor.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import '../services/plan_exporter.dart';
import '../services/scan_store.dart';
import '../scanner/cad_export.dart';
import '../scanner/room_model_3d.dart';
import '../scanner/scanner_3d_screen.dart';
import 'app_theme.dart';
import 'common.dart';
import 'opening_editor_screen.dart';
import 'plan_painter.dart';

/// Shows the 2D plan of one room with its measurements, and lets the user
/// adjust the shape, walls, doors and windows, and export the plan.
class PlanScreen extends StatefulWidget {
  const PlanScreen(
      {super.key,
      required this.scan,
      this.saved = false,
      this.justScanned = false,
      this.openOpening,
      this.initialTab = 0});

  final RoomScan scan;

  /// Opened straight after a scan that measured every wall: shows a
  /// "Room scanned" confirmation with the dimensions.
  final bool justScanned;

  /// Opened straight after a door / window's ✓ in the scanner: its front-view
  /// drawing (index in scan.openings) is shown on top of the plan at once.
  final int? openOpening;

  /// The tab shown first (0 Summary, 1 Walls, 2 Openings, 3 Surfaces).
  final int initialTab;

  /// True when the scan is already stored; edits are then saved right away.
  final bool saved;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen>
    with SingleTickerProviderStateMixin {
  late RoomScan scan = widget.scan;
  late bool _saved = widget.saved;
  late bool _showScanned = widget.justScanned;
  bool squareCorners = true;
  bool editing = false;
  int? selectedWall;
  int? selectedCorner;
  FloorPlan? plan;
  String? error;

  late final TabController _tabs =
      TabController(length: 4, vsync: this, initialIndex: widget.initialTab.clamp(0, 3));
  final _viewer = TransformationController();
  double _zoom = 1;

  // Drag of a circle in progress: a corner (_dragIndex) or a line's end
  // (_dragLine, _dragLineEnd), by pointer _dragPointer.
  int? _dragIndex;
  PlanLayout? _dragLayout;
  List<Vec2>? _dragCorners;
  int? _dragLine;
  int _dragLineEnd = 0;
  MeasuredLine? _draggedLine;
  int? _dragPointer;
  Offset _dragFrom = Offset.zero;
  bool _dragMoved = false;

  /// The finger that just lifted moved a circle: its tap is ignored.
  bool _suppressTap = false;

  /// A 360° photo just added (its file name), waiting for a tap on the plan
  /// where it was taken.
  String? _placingPano;

  LengthUnit get unit => AppSettings.unit.value;

  @override
  void initState() {
    super.initState();
    _rebuild();
    if (plan != null) _lastGood = scan.toJson();
    final k = widget.openOpening;
    if (k != null && k >= 0 && k < scan.openings.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && plan != null) _openOpening(k);
      });
    }
    _viewer.addListener(() {
      final z = _viewer.value.getMaxScaleOnAxis();
      if ((z - _zoom).abs() > 0.01) setState(() => _zoom = z);
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _viewer.dispose();
    super.dispose();
  }

  void _rebuild() {
    try {
      plan = FloorPlanBuilder(squareCorners: squareCorners).build(scan);
      error = null;
      if (selectedWall != null && selectedWall! >= plan!.wallCount) {
        selectedWall = null;
      }
      if (selectedCorner != null && selectedCorner! >= plan!.wallCount) {
        selectedCorner = null;
      }
    } on PlanException catch (e) {
      plan = null;
      error = e.message;
    }
  }

  /// The scan as it last built into a plan: an edit that breaks the plan
  /// (a corner dragged onto its neighbour, a wall typed 0 long) goes back
  /// to it instead of being saved, which left a room that never opened
  /// again.
  Map<String, dynamic>? _lastGood;

  Future<void> _changed() async {
    setState(_rebuild);
    if (plan == null && _lastGood != null) {
      final why = error;
      setState(() {
        scan = RoomScan.fromJson(_lastGood!);
        _rebuild();
      });
      if (mounted) {
        showMessage(context, 'That change was undone: ${why ?? 'the room could not be drawn.'}');
      }
      return;
    }
    if (plan != null) _lastGood = scan.toJson();
    if (_saved) await ScanStore.save(scan);
  }

  /// A saved room whose plan can't be built: drops the walls too short to
  /// have a direction (corners on top of each other), when that fixes it.
  Future<void> _repair() async {
    final kept = [for (final w in scan.walls) if (w.length >= 0.05) w];
    if (kept.length < 3 || kept.length == scan.walls.length) return;
    final trial = RoomScan.fromJson(scan.toJson());
    trial.walls
      ..clear()
      ..addAll(kept);
    trial.openings.removeWhere((o) => o.wallIndex >= kept.length);
    try {
      FloorPlanBuilder(squareCorners: squareCorners).build(trial);
    } on PlanException {
      if (mounted) showMessage(context, 'The room could not be repaired. Measure it again.');
      return;
    }
    scan = trial;
    await _changed();
    if (mounted) showMessage(context, 'Repaired: the wall too short to draw was removed.');
  }

  bool get _repairable {
    final kept = scan.walls.where((w) => w.length >= 0.05).length;
    return kept >= 3 && kept < scan.walls.length;
  }

  Future<void> _save() async {
    // A room has no automatic name: it is named before it is saved.
    if (isUnnamed(scan.name)) {
      final v = await askText(context,
          title: 'Name this room', label: 'Room name', confirm: 'Save room');
      if (v == null || v.trim().isEmpty || !mounted) return;
      scan.name = v.trim();
    }
    if (scan.source == CaptureSource.sample) {
      // Save examples as a copy, so the example itself stays unchanged.
      scan = RoomScan.fromJson({
        ...scan.toJson(),
        'id': RoomScan.newId(),
        'createdAt': DateTime.now().toIso8601String(),
        'source': CaptureSource.manual.name,
      });
    }
    await ScanStore.save(scan);
    if (!mounted) return;
    setState(() => _saved = true);
    if (mounted) showMessage(context, 'Room saved');
  }

  // ---------------------------------------------------------------- edits

  Future<void> _rename() async {
    final v = await askText(context,
        title: 'Rename room', initial: scan.name, label: 'Room name');
    if (v == null || v.trim().isEmpty) return;
    scan.name = v.trim();
    await _changed();
  }

  Future<void> _delete() async {
    final ok = await confirm(context,
        title: 'Delete "${scan.name}"?',
        message: 'This room and its floor plan will be removed.');
    if (!ok) return;
    await ScanStore.delete(scan.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _setWallLength(int i) async {
    final p = plan!;
    final len = await askLength(context,
        title: 'Length of wall W${i + 1}',
        unit: unit,
        initial: p.wallLength(i),
        helper: 'The room is stretched along this wall. Other walls keep '
            'their direction.');
    if (len == null || len.isNaN) return;
    PlanEditor.setWallLength(scan, p, i, len);
    await _changed();
  }

  /// Compares wall [i] with a tape measurement: shows how far off the scan
  /// is, and offers to rescale the whole plan to match.
  Future<void> _calibrate(int i) async {
    final p = plan!;
    final scanned = p.wallLength(i);
    final len = await askLength(context,
        title: 'Check wall W${i + 1} with a tape',
        unit: unit,
        label: 'Tape-measured length',
        helper: 'Measure this wall with a tape or laser and type the result. '
            'The scan says ${formatLength(scanned, unit)}.');
    if (len == null || len.isNaN || len <= 0 || !mounted) return;
    final diff = scanned - len;
    final pct = diff / len * 100;
    final close = pct.abs() < 1.0;
    final rescale = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(close ? Icons.verified_outlined : Icons.straighten,
            color: close ? AppTheme.success : null),
        title: Text(close ? 'Accurate' : 'Off by ${pct.abs().toStringAsFixed(1)} %'),
        content: Text(
          'Scan: ${formatLength(scanned, unit)}\n'
          'Tape: ${formatLength(len, unit)}\n'
          'Difference: ${diff >= 0 ? '+' : '−'}${formatLength(diff.abs(), unit)} '
          '(${pct >= 0 ? '+' : '−'}${pct.abs().toStringAsFixed(1)} %)\n\n'
          '${close ? 'This wall matches the tape to within 1 %.' : 'Rescaling makes this wall exactly match the tape and corrects every other length in the plan by the same factor.'}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep as is')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Rescale plan')),
        ],
      ),
    );
    if (rescale != true) return;
    scan.scale = FloorPlanBuilder.scaleForTrueLength(scan, p, i, len);
    await _changed();
  }

  Future<void> _removeLine(int index) async {
    scan.lines.removeAt(index);
    await _changed();
  }

  Future<void> _split(int i) async {
    PlanEditor.splitWall(scan, plan!, i);
    selectedWall = null;
    await _changed();
    if (mounted) {
      showMessage(context, 'Corner added. Turn on Edit and drag it into place.');
    }
  }

  Future<void> _removeCorner(int i) async {
    if (!PlanEditor.removeCorner(scan, plan!, i)) {
      showMessage(context, 'A room needs at least 3 corners.');
      return;
    }
    selectedCorner = null;
    selectedWall = null;
    await _changed();
  }

  Future<void> _editOpening({int? index, int? wall}) async {
    final p = plan!;
    final existing = index != null ? scan.openings[index] : null;
    final result = await showDialog<Opening>(
      context: context,
      builder: (_) => _OpeningDialog(
        plan: p,
        unit: unit,
        existing: existing,
        wall: wall ?? existing?.wallIndex ?? selectedWall ?? 0,
      ),
    );
    if (result == null) return;
    if (index != null) {
      scan.openings[index] = result;
    } else {
      scan.openings.add(result);
    }
    await _changed();
  }

  /// "Door 1", "Window 2": numbered per type, in the order they are listed.
  String _openingLabel(int index) {
    final t = scan.openings[index].type;
    final n = scan.openings.take(index + 1).where((o) => o.type == t).length;
    return '${t.label} $n';
  }

  /// Opens the front view of a door or window, where its edges and
  /// measurements can be edited.
  Future<void> _openOpening(int index) async {
    final p = plan;
    if (p == null) return;
    final edit = await Navigator.push<OpeningEdit>(
      context,
      MaterialPageRoute(
        builder: (_) => OpeningEditorScreen(
          plan: p,
          opening: scan.openings[index],
          label: _openingLabel(index),
          roomName: scan.name,
        ),
      ),
    );
    if (edit == null) return;
    if (edit.delete) {
      scan.openings.removeAt(index);
    } else {
      scan.openings[index] = edit.opening!;
    }
    await _changed();
  }

  Future<void> _removeOpening(int index) async {
    scan.openings.removeAt(index);
    await _changed();
  }

  Future<void> _editSurface({int? index}) async {
    final existing = index != null ? scan.surfaces[index] : null;
    final result = await showDialog<MeasuredSurface>(
      context: context,
      builder: (_) => _SurfaceDialog(
        unit: unit,
        existing: existing,
        defaultName: '',
      ),
    );
    if (result == null) return;
    if (index != null) {
      scan.surfaces[index] = result;
    } else {
      scan.surfaces.add(result);
    }
    await _changed();
  }

  /// Adds a 360° photo from the phone's gallery (any 360° camera's app
  /// saves them there as 2:1 equirectangular images), then the user taps the
  /// plan where it was taken.
  Future<void> _addPanorama() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 8000);
    if (x == null || !mounted) return;
    // Its size without decoding the whole (often very large) image.
    final buffer = await ui.ImmutableBuffer.fromUint8List(await File(x.path).readAsBytes());
    final desc = await ui.ImageDescriptor.encoded(buffer);
    final ratio = desc.width / desc.height;
    desc.dispose();
    buffer.dispose();
    if (!mounted) return;
    if ((ratio - 2).abs() > 0.15) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Not a 360° photo?'),
          content: const Text('360° photos are twice as wide as they are high. '
              'This one is not, so it may not look right in the 360° view.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add anyway')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    final name = await ScanStore.keepPhoto(x.path, prefix: 'pano');
    if (!mounted) return;
    setState(() {
      scan.photos.add(name);
      _placingPano = name;
      editing = false;
    });
    await _changed();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(minutes: 1),
      content: const Text('Tap the plan where the 360° photo was taken'),
      action: SnackBarAction(label: 'Later', onPressed: () => setState(() => _placingPano = null)),
    ));
  }

  Future<void> _showPhoto(int k) async {
    final f = await ScanStore.photoFile(scan.photos[k]);
    if (!mounted) return;
    final pano = scan.photoPins.any((p) => p.file == scan.photos[k] && p.panorama) ||
        scan.photos[k].startsWith('pano_');
    final remove = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(scan.name),
            actions: [
              IconButton(
                tooltip: 'Delete photo',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
          // 360° photos: look round by dragging or by turning the phone.
          body: pano
              ? PanoramaViewer(sensorControl: SensorControl.orientation, child: Image.file(f))
              : InteractiveViewer(
                  maxScale: 6,
                  child: Center(child: Image.file(f)),
                ),
        ),
      ),
    );
    if (remove != true) return;
    final removed = scan.photos.removeAt(k);
    scan.photoPins.removeWhere((p) => p.file == removed);
    if (await f.exists()) await f.delete();
    await _changed();
  }

  Future<void> _removeSurface(int index) async {
    scan.surfaces.removeAt(index);
    await _changed();
  }

  Future<void> _export(String kind) async {
    final p = plan;
    if (p == null) return;
    try {
      switch (kind) {
        case 'png':
          final f = await PlanExporter.savePng(scan, p, unit);
          if (mounted) await deliverFile(context, f, what: 'Image');
        case 'pdf':
          final f = await PlanExporter.savePdf(scan, p, unit);
          if (mounted) await deliverFile(context, f, what: 'PDF');
        case 'share':
          final bytes = await PlanExporter.buildPdf(scan, p, unit);
          await Printing.sharePdf(
              bytes: bytes,
              filename: '${PlanExporter.safeName(scan.name)}.pdf');
        case 'csv':
          final f = await PlanExporter.saveCsv([(scan, p)], unit,
              name: scan.name);
          if (mounted) await deliverFile(context, f, what: 'Spreadsheet (CSV)');
        case 'dxf':
          final f = await CadExporter.saveDxf([RoomInput(scan, p)], unit,
              name: scan.name);
          if (mounted) await deliverFile(context, f, what: 'CAD drawing (DXF)');
        case 'obj':
          final files = await CadExporter.saveObj(RoomModel3D.single(scan, p),
              name: scan.name);
          if (mounted) await deliverFiles(context, files, what: '3D model (OBJ)');
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Export failed: $e');
    }
  }

  // ---------------------------------------------------------------- sheets

  Future<void> _wallSheet(int i) async {
    setState(() => selectedWall = i);
    final p = plan!;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget item(IconData icon, String title, String? sub, VoidCallback f,
                {bool enabled = true}) =>
            ListTile(
              enabled: enabled,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: _Badge(
                color: enabled
                    ? Theme.of(ctx).colorScheme.primary
                    : Theme.of(ctx).colorScheme.onSurfaceVariant,
                size: 38,
                child: Icon(icon, size: 20),
              ),
              title: Text(title),
              subtitle: sub == null ? null : Text(sub),
              onTap: () {
                Navigator.pop(ctx);
                f();
              },
            );
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text('Wall W${i + 1}',
                  style: Theme.of(ctx).textTheme.titleLarge),
              subtitle: Text(
                  '${formatLength(p.wallLength(i), unit)}  ·  '
                  'corner ${p.interiorAngleDeg(i).toStringAsFixed(0)}°',
                  style: const TextStyle(fontFeatures: AppTheme.tabular)),
            ),
            const SizedBox(height: 4),
            const Divider(indent: 20, endIndent: 20),
            const SizedBox(height: 4),
            item(Icons.straighten_rounded, 'Change wall length',
                'Stretch the room along this wall', () => _setWallLength(i)),
            item(Icons.fact_check_outlined, 'Check with a tape measure',
                'See how accurate the scan is, and correct it',
                () => _calibrate(i)),
            item(Icons.sensor_door_outlined, 'Add door or window', null,
                () => _editOpening(wall: i)),
            item(Icons.call_split_rounded, 'Add corner', 'Split this wall in two',
                () => _split(i)),
            item(Icons.remove_circle_outline_rounded, 'Remove start corner',
                'Join this wall with the previous one', () => _removeCorner(i),
                enabled: p.wallCount > 3),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
  }

  // ---------------------------------------------------------------- canvas

  int? _hitCorner(FloorPlan p, PlanLayout l, Offset pos) {
    final r = 28 / _zoom;
    int? best;
    var bestD = r;
    for (var i = 0; i < p.wallCount; i++) {
      final d = (l.toScreen(p.corners[i]) - pos).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  int? _hitWall(FloorPlan p, PlanLayout l, Offset pos) {
    final r = 22 / _zoom;
    int? best;
    var bestD = r;
    for (var i = 0; i < p.wallCount; i++) {
      final a = l.toScreen(p.wallStart(i)), b = l.toScreen(p.wallEnd(i));
      final ab = b - a;
      final len2 = ab.distanceSquared;
      if (len2 == 0) continue;
      final t = (((pos - a).dx * ab.dx + (pos - a).dy * ab.dy) / len2)
          .clamp(0.0, 1.0);
      final d = (a + ab * t - pos).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _onTap(FloorPlan p, PlanLayout l, Offset pos) {
    // Placing a 360° photo: it goes where the plan was tapped.
    final placing = _placingPano;
    if (placing != null) {
      setState(() {
        scan.photoPins.removeWhere((x) => x.file == placing);
        scan.photoPins.add(PhotoPin(file: placing, position: p.fromPlan(l.toPlan(pos)), panorama: true));
        _placingPano = null;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      _changed();
      return;
    }
    // A photo marker: open the photo.
    if (!editing) {
      final r = 20 / _zoom;
      for (final pin in scan.photoPins) {
        final k = scan.photos.indexOf(pin.file);
        if (k < 0) continue;
        if ((l.toScreen(p.toPlan(pin.position)) - pos).distance <= r) {
          _showPhoto(k);
          return;
        }
      }
    }
    if (editing) {
      final c = _hitCorner(p, l, pos);
      if (c != null) {
        setState(() => selectedCorner = c);
        return;
      }
    }
    final w = _hitWall(p, l, pos);
    if (w == null) {
      setState(() {
        selectedWall = null;
        selectedCorner = null;
      });
    } else if (editing) {
      _wallSheet(w);
    } else {
      setState(() => selectedWall = selectedWall == w ? null : w);
      if (selectedWall != null) _tabs.animateTo(1);
    }
  }

  /// The line end nearest [pos] within reach: (line, end).
  (int, int)? _hitLineEnd(FloorPlan p, PlanLayout l, Offset pos) {
    final r = 26 / _zoom;
    (int, int)? best;
    var bestD = r;
    for (var k = 0; k < p.lines.length; k++) {
      final fp = p.lines[k].footprint;
      if (fp.length < 2) continue;
      for (var e = 0; e < 2; e++) {
        final d = (l.toScreen(fp[e]) - pos).distance;
        if (d < bestD) {
          bestD = d;
          best = (k, e);
        }
      }
    }
    return best;
  }

  /// A finger down on a circle (a corner or a line's end) grabs it: the
  /// plan stops panning and zooming until it is let go. Anywhere else the
  /// plan pans and zooms as usual.
  void _pointerDown(FloorPlan p, PlanLayout l, PointerDownEvent e) {
    if (_dragPointer != null) {
      // A second finger: a pinch, not a drag. Put the circle back.
      _cancelDrag();
      return;
    }
    _suppressTap = false;
    final pos = e.localPosition;
    final c = _hitCorner(p, l, pos);
    final le = c == null ? _hitLineEnd(p, l, pos) : null;
    if (c == null && le == null) return;
    setState(() {
      _dragPointer = e.pointer;
      _dragFrom = pos;
      _dragMoved = false;
      _dragLayout = l;
      if (c != null) {
        _dragIndex = c;
        _dragCorners = List.of(p.corners);
      } else {
        _dragLine = le!.$1;
        _dragLineEnd = le.$2;
        _draggedLine = p.lines[le.$1];
      }
    });
  }

  void _pointerMove(FloorPlan p, PointerMoveEvent e) {
    if (e.pointer != _dragPointer) return;
    final l = _dragLayout;
    if (l == null) return;
    final pos = e.localPosition;
    if (!_dragMoved && (pos - _dragFrom).distance < 4) return;
    _dragMoved = true;
    final to = l.toPlan(pos);
    final tol = 12 / (l.scale * _zoom);
    final i = _dragIndex, cs = _dragCorners;
    if (i != null && cs != null) {
      // Snap into line with the neighbouring corners to keep walls square.
      final n = cs.length;
      var x = to.x, y = to.y;
      for (final q in [cs[(i - 1 + n) % n], cs[(i + 1) % n]]) {
        if ((x - q.x).abs() < tol) x = q.x;
        if ((y - q.y).abs() < tol) y = q.y;
      }
      setState(() {
        cs[i] = Vec2(x, y);
        selectedCorner = editing ? i : selectedCorner;
      });
      return;
    }
    final k = _dragLine;
    if (k == null) return;
    // Snap a line's end onto a room corner.
    var v = to;
    for (final q in p.corners) {
      if (q.distanceTo(to) < tol) v = q;
    }
    setState(() =>
        _draggedLine = PlanEditor.movedLineEnd(p.lines[k], _dragLineEnd, v));
  }

  Future<void> _pointerUp(FloorPlan p, PointerEvent e) async {
    if (e.pointer != _dragPointer) return;
    final moved = _dragMoved;
    final i = _dragIndex, cs = _dragCorners;
    final k = _dragLine, line = _draggedLine, end = _dragLineEnd;
    _cancelDrag();
    // Pointer events reach this listener before the tap is decided, so a
    // short drag that still counts as a tap is not also taken as one.
    _suppressTap = moved;
    if (!moved) return; // A tap: handled by onTapUp.
    if (i != null && cs != null) {
      PlanEditor.moveCorner(scan, p, i, cs[i]);
    } else if (k != null && line != null) {
      PlanEditor.moveLineEnd(scan, p, k, end, line.footprint[end]);
    } else {
      return;
    }
    await _changed();
  }

  void _cancelDrag() => setState(() {
        _dragPointer = null;
        _dragIndex = null;
        _dragLayout = null;
        _dragCorners = null;
        _dragLine = null;
        _draggedLine = null;
        _dragMoved = false;
      });

  Widget _canvas(FloorPlan p) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: editing ? cs.primary : AppTheme.scan,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                editing ? 'Editing shape' : 'Floor plan',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            if (_zoom > 1.01) ...[
              IconButton.filledTonal(
                tooltip: 'Fit to screen',
                visualDensity: VisualDensity.compact,
                onPressed: () => _viewer.value = Matrix4.identity(),
                icon: const Icon(Icons.fit_screen_rounded, size: 20),
              ),
              const SizedBox(width: 6),
            ],
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 38),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: const StadiumBorder(),
                textStyle: theme.textTheme.labelLarge,
                backgroundColor: editing ? cs.primary : cs.primaryContainer,
                foregroundColor:
                    editing ? cs.onPrimary : cs.onPrimaryContainer,
              ),
              onPressed: () => setState(() {
                editing = !editing;
                selectedCorner = null;
              }),
              icon: Icon(editing ? Icons.check_rounded : Icons.edit_outlined,
                  size: 18),
              label: Text(editing ? 'Done' : 'Edit shape'),
            ),
          ]),
        ),
        Divider(height: 1, color: cs.outlineVariant),
        Expanded(
          child: Stack(children: [
            Positioned.fill(
              child: LayoutBuilder(builder: (context, c) {
                final size = Size(c.maxWidth, c.maxHeight);
                final layout = _dragLayout ??
                    PlanLayout.fit(p, size, bottom: editing ? 56 : 0);
                final k = _dragLine, moved = _draggedLine;
                final shown = _dragCorners == null && moved == null
                    ? p
                    : FloorPlan(
                        corners: _dragCorners ?? p.corners,
                        openings: p.openings,
                        warnings: const [],
                        snappedWalls: 0,
                        surfaces: p.surfaces,
                        ceilingHeight: p.ceilingHeight,
                        rotation: p.rotation,
                        scale: p.scale,
                        origin: p.origin,
                        lines: [
                          for (var j = 0; j < p.lines.length; j++)
                            j == k && moved != null ? moved : p.lines[j],
                        ]);
                final grabbing = _dragPointer != null;
                return InteractiveViewer(
                  transformationController: _viewer,
                  minScale: 1,
                  maxScale: 8,
                  // Off while a circle is held, so the drag moves the circle
                  // and not the plan.
                  panEnabled: !grabbing,
                  scaleEnabled: !grabbing,
                  child: Listener(
                    onPointerDown: (e) => _pointerDown(p, layout, e),
                    onPointerMove: (e) => _pointerMove(p, e),
                    onPointerUp: (e) => _pointerUp(p, e),
                    onPointerCancel: (e) {
                      if (e.pointer == _dragPointer) _cancelDrag();
                    },
                    child: GestureDetector(
                      onTapUp: (d) {
                        if (_suppressTap) {
                          _suppressTap = false;
                          return;
                        }
                        _onTap(p, layout, d.localPosition);
                      },
                      child: CustomPaint(
                        size: size,
                        painter: PlanPainter(
                          plan: shown,
                          unit: unit,
                          highlightWall: selectedWall,
                          highlightCorner: _dragIndex ?? selectedCorner,
                          highlightLine: k,
                          layout: layout,
                          editing: editing,
                          handles: true,
                          zoom: _zoom,
                          furniture: furnitureOnPlan(scan, p),
                          photoPins: [
                            for (final pin in scan.photoPins)
                              if (scan.photos.contains(pin.file))
                                (
                                  p.toPlan(pin.position),
                                  pin.direction == null ? null : p.dirToPlan(pin.direction!),
                                  scan.photos.indexOf(pin.file) + 1,
                                  pin.panorama,
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            if (editing)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: _EditBar(
                  selectedCorner: selectedCorner,
                  canRemove: p.wallCount > 3,
                  onRemoveCorner: selectedCorner == null
                      ? null
                      : () => _removeCorner(selectedCorner!),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- tabs

  Widget _summaryTab(FloorPlan p) {
    final size = p.overallSize;
    final doors = p.openings.where((o) => o.type == OpeningType.door).length;
    final windows =
        p.openings.where((o) => o.type == OpeningType.window).length;
    final gaps = p.openings.where((o) => o.type == OpeningType.opening).length;
    final tiles = [
      MetricTile(
          icon: Icons.crop_free_rounded,
          label: 'Perimeter',
          value: formatLength(p.perimeter, unit)),
      MetricTile(
          icon: Icons.polyline_outlined,
          label: 'Walls · Corners',
          value: '${p.wallCount} · ${p.wallCount}'),
      MetricTile(
        icon: Icons.door_front_door_outlined,
        label: 'Doors',
        value: '$doors',
        onTap: () => _tabs.animateTo(2),
      ),
      MetricTile(
        icon: Icons.window_outlined,
        label: 'Windows',
        value: '$windows',
        onTap: () => _tabs.animateTo(2),
      ),
      if (gaps > 0)
        MetricTile(
          icon: Icons.crop_free_rounded,
          label: 'Open gaps',
          value: '$gaps',
          onTap: () => _tabs.animateTo(2),
        ),
      if (scan.elements.isNotEmpty)
        MetricTile(
          icon: Icons.chair_outlined,
          label: 'Other elements',
          value: '${scan.elements.length}',
        ),
      // Measured by the LiDAR scanner; the camera scanner can't.
      if (p.ceilingHeight != null) ...[
        MetricTile(
          icon: Icons.height_rounded,
          label: 'Ceiling height',
          value: formatLength(p.ceilingHeight!, unit),
        ),
        MetricTile(
          icon: Icons.view_in_ar_outlined,
          label: 'Wall area',
          value: formatArea(PlanExporter.wallArea(p), unit),
        ),
      ],
      MetricTile(
        icon: Icons.texture_rounded,
        label: 'Measured surfaces',
        value: p.surfaces.isEmpty
            ? 'None'
            : '${p.surfaces.length}  ·  ${formatArea(p.surfaces.fold(0.0, (a, m) => a + m.area), unit)}',
        placeholder: p.surfaces.isEmpty,
        onTap: () => _tabs.animateTo(3),
      ),
    ];
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 560 ? 3 : 2;
      const pad = 16.0, gap = 10.0;
      return ListView(
        padding: const EdgeInsets.fromLTRB(pad, 16, pad, 24),
        children: [
          if (_showScanned)
            _Banner(
              color: AppTheme.scan,
              leading: const CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.scan,
                foregroundColor: Colors.white,
                child: Icon(Icons.check, size: 22),
              ),
              title: 'Room scanned',
              message: [
                '${formatLength(size.width, unit)} × ${formatLength(size.depth, unit)}',
                formatArea(p.area, unit),
                '$doors door${doors == 1 ? '' : 's'}',
                '$windows window${windows == 1 ? '' : 's'}',
              ].join('  ·  '),
              trailing: IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                onPressed: () => setState(() => _showScanned = false),
              ),
            ),
          for (final w in p.warnings)
            _Banner(
              color: AppTheme.door,
              leading: const Icon(Icons.warning_amber_rounded,
                  color: AppTheme.door),
              message: w,
            ),
          // The two numbers people come for, large.
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: IntrinsicHeight(
                child: Row(children: [
                  Expanded(
                    flex: 5,
                    child: _HeroMetric(
                      icon: Icons.square_foot_rounded,
                      label: 'Floor area',
                      value: formatArea(p.area, unit),
                    ),
                  ),
                  VerticalDivider(
                      width: 32, thickness: 1, color: cs.outlineVariant),
                  Expanded(
                    flex: 6,
                    child: _HeroMetric(
                      icon: Icons.aspect_ratio_rounded,
                      label: 'Overall size',
                      value:
                          '${formatLength(size.width, unit)} × ${formatLength(size.depth, unit)}',
                    ),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(height: gap),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final t in tiles)
                SizedBox(
                    width: (c.maxWidth - 2 * pad - gap * (cols - 1)) / cols,
                    child: t),
            ],
          ),
          // Everything counted in the room: doors, windows, gaps and the
          // furniture / fixtures the scanner found.
          if (scan.openings.isNotEmpty || scan.elements.isNotEmpty) ...[
            const SectionLabel('Found in this room'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (kind, n) in roomElementCounts(scan))
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('$n × $kind',
                            style: const TextStyle(
                                fontFeatures: AppTheme.tabular)),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (scan.photos.isNotEmpty) ...[
            const SectionLabel('Photos'),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: scan.photos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, k) => _PhotoThumb(
                  name: scan.photos[k],
                  onTap: () => _showPhoto(k),
                  number: scan.photoPins.any((p) => p.file == scan.photos[k]) ? k + 1 : null,
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              [
                scan.source.label,
                if (p.snappedWalls > 0) '${p.snappedWalls} walls squared',
                if (scan.scale != 1.0)
                  'calibrated ×${scan.scale.toStringAsFixed(3)}',
              ].join('  ·  '),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      );
    });
  }

  /// List-row title for a measurement: tabular figures.
  static const _valueStyle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    fontFeatures: AppTheme.tabular,
  );

  Widget _wallsTab(FloorPlan p) {
    final cs = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
      itemCount: p.wallCount,
      itemBuilder: (_, i) {
        final sel = selectedWall == i;
        final openings =
            p.openings.where((o) => o.wallIndex == i).map((o) => o.type.label);
        return ListTile(
          selected: sel,
          selectedTileColor: cs.primary.withValues(alpha: 0.07),
          onTap: () => _wallSheet(i),
          leading: _Badge(
            color: cs.primary,
            filled: sel,
            child: Text('W${i + 1}',
                style:
                    const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
          title: Text(formatLength(p.wallLength(i), unit),
              style: _valueStyle.copyWith(color: cs.onSurface)),
          subtitle: Text([
            'Corner ${p.interiorAngleDeg(i).toStringAsFixed(0)}°',
            ...openings,
          ].join('  ·  ')),
          trailing: IconButton(
            tooltip: 'Change length',
            icon: Icon(Icons.edit_outlined,
                size: 20, color: cs.onSurfaceVariant),
            onPressed: () => _setWallLength(i),
          ),
        );
      },
    );
  }

  Widget _emptyNote(IconData icon, Color color, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      child: Column(children: [
        _Badge(color: color, size: 48, child: Icon(icon, size: 24)),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }

  Widget _addButton(String label, VoidCallback onPressed) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.add_rounded),
          label: Text(label),
        ),
      );

  Widget _removeButton(VoidCallback onPressed) => IconButton(
        tooltip: 'Remove',
        icon: Icon(Icons.delete_outline_rounded,
            size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        onPressed: onPressed,
      );

  Widget _openingsTab(FloorPlan p) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
      children: [
        if (scan.openings.isEmpty)
          _emptyNote(
              Icons.sensor_door_outlined,
              AppTheme.door,
              'No doors or windows yet. Mark them during the scan, or add '
              'them here.'),
        for (var k = 0; k < scan.openings.length; k++)
          () {
            final o = scan.openings[k];
            final color = switch (o.type) {
              OpeningType.door => AppTheme.door,
              OpeningType.window => AppTheme.window,
              OpeningType.opening => theme.colorScheme.onSurfaceVariant,
            };
            return ListTile(
              onTap: () => _openOpening(k),
              leading: _Badge(
                color: color,
                child: Icon(
                    switch (o.type) {
                      OpeningType.door => Icons.door_front_door_outlined,
                      OpeningType.window => Icons.window_outlined,
                      OpeningType.opening => Icons.crop_free_rounded,
                    },
                    size: 21),
              ),
              title: Text('${_openingLabel(k)} on W${o.wallIndex + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text.rich(TextSpan(children: [
                TextSpan(
                  text: [
                    '${o.estimated ? '≈ ' : ''}${formatLength(o.width, unit)}',
                    if (o.height != null) formatLength(o.height!, unit),
                  ].join(' × '),
                  style: TextStyle(
                    fontFeatures: AppTheme.tabular,
                    fontWeight: FontWeight.w600,
                    color: o.estimated
                        ? AppTheme.door
                        : theme.colorScheme.onSurface,
                  ),
                ),
                TextSpan(
                  text: [
                    '',
                    if (o.sill != null) 'sill ${formatLength(o.sill!, unit)}',
                    if (o.method == OpeningMethod.auto) 'detected',
                    if (o.method == OpeningMethod.touch) 'by touch',
                  ].join('  ·  '),
                  style: const TextStyle(fontFeatures: AppTheme.tabular),
                ),
              ])),
              trailing: _removeButton(() => _removeOpening(k)),
            );
          }(),
        _addButton('Add door or window', () => _editOpening()),
      ],
    );
  }

  Widget _surfacesTab(FloorPlan p) {
    final theme = Theme.of(context);
    const color = AppTheme.surfaceMark;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
      children: [
        if (scan.surfaces.isEmpty)
          _emptyNote(
              Icons.texture_rounded,
              color,
              'No surfaces yet. Measure wall sections, worktops or floor areas '
              'in the scanner\'s Surface mode, or add them here.'),
        for (var k = 0; k < scan.surfaces.length; k++)
          () {
            final m = scan.surfaces[k];
            return ListTile(
              onTap: () => _editSurface(index: k),
              leading: _Badge(
                color: color,
                child: Icon(
                    switch (m.kind) {
                      SurfaceKind.floor => Icons.grid_on_rounded,
                      SurfaceKind.raised => Icons.table_restaurant_outlined,
                      SurfaceKind.wall => Icons.wallpaper_rounded,
                      SurfaceKind.sloped => Icons.roofing_rounded,
                    },
                    size: 21),
              ),
              title: Row(children: [
                Expanded(
                  child: Text(m.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                Text(formatArea(m.area, unit), style: _valueStyle),
              ]),
              subtitle: Text(
                [
                  m.kind.label,
                  '${formatLength(m.width, unit)} × ${formatLength(m.height, unit)}',
                  if (m.elevation != null && m.elevation! >= 0.05)
                    '${formatLength(m.elevation!, unit)} above floor',
                ].join('  ·  '),
                style: const TextStyle(fontFeatures: AppTheme.tabular),
              ),
              trailing: _removeButton(() => _removeSurface(k)),
            );
          }(),
        _addButton('Add surface', () => _editSurface()),
        if (scan.lines.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: SectionLabel('Distances'),
          ),
          for (var k = 0; k < scan.lines.length; k++)
            ListTile(
              leading: const _Badge(
                color: AppTheme.lineMark,
                child: Icon(Icons.straighten_rounded, size: 21),
              ),
              title: Row(children: [
                Expanded(
                  child: Text(scan.lines[k].name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                Text(
                  '${scan.lines[k].estimated ? '≈ ' : ''}${formatLength(scan.lines[k].length, unit)}',
                  style: _valueStyle.copyWith(
                      color: scan.lines[k].estimated
                          ? AppTheme.door
                          : theme.colorScheme.onSurface),
                ),
              ]),
              subtitle: lineParts(scan.lines[k], unit) == null
                  ? null
                  : Text(lineParts(scan.lines[k], unit)!,
                      style: const TextStyle(fontFeatures: AppTheme.tabular)),
              trailing: _removeButton(() => _removeLine(k)),
            ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LengthUnit>(
      valueListenable: AppSettings.unit,
      builder: (context, _, _) => Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: InkWell(
            onTap: _rename,
            borderRadius: BorderRadius.circular(AppTheme.radiusS),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(scan.name, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 1),
                  Text(scan.source.label,
                      overflow: TextOverflow.ellipsis,
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
              onPressed: plan == null
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                          builder: (_) => Scanner3DScreen(
                              rooms: [RoomInput(scan, plan!)], title: scan.name))),
            ),
            PopupMenuButton<String>(
              tooltip: 'Export',
              icon: const Icon(Icons.ios_share_rounded),
              enabled: plan != null,
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
                  case 'pano':
                    _addPanorama();
                  case 'square':
                    squareCorners = !squareCorners;
                    _changed();
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
                const PopupMenuItem(
                    value: 'pano',
                    child: ListTile(
                        leading: Icon(Icons.panorama_photosphere_outlined),
                        title: Text('Add 360° photo'))),
                CheckedPopupMenuItem(
                    value: 'square',
                    checked: squareCorners,
                    child: const Text('Square near-right corners')),
                if (_saved)
                  const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                          leading: Icon(Icons.delete_outline_rounded,
                              color: AppTheme.danger),
                          title: Text('Delete room',
                              style: TextStyle(color: AppTheme.danger)))),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: error != null
            ? _ErrorView(
                message: error!,
                onRepair: _repairable ? _repair : null,
                onDelete: _saved ? _delete : null)
            : LayoutBuilder(builder: (context, c) {
                final p = plan!;
                final tabs = Column(children: [
                  TabBar(
                      controller: _tabs,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                      tabs: [
                        const Tab(text: 'Summary'),
                        Tab(text: 'Walls (${p.wallCount})'),
                        Tab(text: 'Openings (${p.openings.length})'),
                        Tab(
                            text: 'Surfaces (${p.surfaces.length + p.lines.length})'),
                      ]),
                  Expanded(
                    child: TabBarView(controller: _tabs, children: [
                      _summaryTab(p),
                      _wallsTab(p),
                      _openingsTab(p),
                      _surfacesTab(p),
                    ]),
                  ),
                ]);
                final wide = c.maxWidth > 900;
                final canvas = Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, wide ? 8 : 16, wide ? 16 : 10),
                  child: _canvas(p),
                );
                return wide
                    ? Row(children: [
                        Expanded(child: canvas),
                        SizedBox(width: 420, child: tabs),
                      ])
                    : Column(children: [
                        Expanded(flex: 11, child: canvas),
                        Expanded(flex: 10, child: tabs),
                      ]);
              }),
        bottomNavigationBar: _saved
            ? null
            : Material(
                color: Theme.of(context).colorScheme.surface,
                shape: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('Save room'),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _EditBar extends StatelessWidget {
  const _EditBar({
    required this.selectedCorner,
    required this.canRemove,
    required this.onRemoveCorner,
  });

  final int? selectedCorner;
  final bool canRemove;
  final VoidCallback? onRemoveCorner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppTheme.ink.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(AppTheme.radiusM),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(children: [
          const Icon(Icons.open_with_rounded, size: 18, color: Colors.white70),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              selectedCorner == null
                  ? 'Drag a corner to move it. Tap a wall for more options.'
                  : 'Corner ${selectedCorner! + 1} selected',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
            ),
          ),
          if (selectedCorner != null)
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: canRemove ? onRemoveCorner : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Remove'),
            ),
        ]),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, this.onRepair, this.onDelete});
  final String message;

  /// Fixes the room (drops a wall too short to draw), when that can work.
  final VoidCallback? onRepair;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _Badge(
            color: AppTheme.danger,
            size: 64,
            radius: AppTheme.radiusL,
            child: Icon(Icons.error_outline_rounded, size: 30),
          ),
          const SizedBox(height: 18),
          Text("Couldn't build a floor plan",
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 22),
          if (onRepair != null)
            FilledButton.icon(
              onPressed: onRepair,
              icon: const Icon(Icons.build_outlined),
              label: const Text('Repair the room'),
            ),
          if (onDelete != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Delete room'),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Adds or edits a door, window or opening.
class _OpeningDialog extends StatefulWidget {
  const _OpeningDialog({
    required this.plan,
    required this.unit,
    required this.wall,
    this.existing,
  });

  final FloorPlan plan;
  final LengthUnit unit;
  final int wall;
  final Opening? existing;

  @override
  State<_OpeningDialog> createState() => _OpeningDialogState();
}

class _OpeningDialogState extends State<_OpeningDialog> {
  final _form = GlobalKey<FormState>();
  late OpeningType type = widget.existing?.type ?? OpeningType.door;
  late int wall = widget.wall.clamp(0, widget.plan.wallCount - 1);
  late final _width = TextEditingController(
      text: editableLength(widget.existing?.width ?? 0.9, widget.unit));
  late final _height = TextEditingController(
      text: widget.existing?.height == null
          ? ''
          : editableLength(widget.existing!.height!, widget.unit));
  late final _sill = TextEditingController(
      text: widget.existing?.sill == null
          ? ''
          : editableLength(widget.existing!.sill!, widget.unit));
  late final _offset = TextEditingController(text: () {
    final o = widget.existing;
    final len = widget.plan.wallLength(wall);
    final width = o?.width ?? 0.9;
    final start = o == null ? (len - width) / 2 : o.center * len - width / 2;
    return editableLength(start.clamp(0.0, len), widget.unit);
  }());

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final u = widget.unit;
    final len = widget.plan.wallLength(wall);
    final w = parseLength(_width.text, u)!;
    final start = parseLength(_offset.text, u) ?? 0;
    final h = _height.text.trim().isEmpty ? null : parseLength(_height.text, u);
    final sill = type != OpeningType.window || _sill.text.trim().isEmpty
        ? null
        : (LengthField.isZero(_sill.text) ? 0.0 : parseLength(_sill.text, u));
    Navigator.pop(
      context,
      Opening(
        type: type,
        wallIndex: wall,
        center: ((start + w / 2) / len).clamp(0.0, 1.0),
        width: w,
        height: h,
        sill: sill,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final len = widget.plan.wallLength(wall);
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add opening' : 'Edit opening'),
      scrollable: true,
      content: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<OpeningType>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: OpeningType.door, label: Text('Door')),
              ButtonSegment(value: OpeningType.window, label: Text('Window')),
              ButtonSegment(value: OpeningType.opening, label: Text('Gap')),
            ],
            selected: {type},
            onSelectionChanged: (s) => setState(() => type = s.first),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: wall,
            decoration: const InputDecoration(labelText: 'Wall'),
            items: [
              for (var i = 0; i < widget.plan.wallCount; i++)
                DropdownMenuItem(
                    value: i,
                    child: Text(
                        'W${i + 1}  (${formatLength(widget.plan.wallLength(i), u)})')),
            ],
            onChanged: (v) => setState(() => wall = v ?? wall),
          ),
          const SizedBox(height: 14),
          LengthField(controller: _width, unit: u, label: 'Width'),
          const SizedBox(height: 14),
          LengthField(
              controller: _height,
              unit: u,
              label: 'Height (optional)',
              optional: true),
          if (type == OpeningType.window) ...[
            const SizedBox(height: 14),
            LengthField(
                controller: _sill,
                unit: u,
                label: 'Sill height (optional)',
                helper: 'From the floor to the bottom of the window.',
                optional: true,
                allowZero: true),
          ],
          const SizedBox(height: 14),
          LengthField(
            controller: _offset,
            unit: u,
            label: 'Distance from wall start',
            allowZero: true,
            helper: 'From corner ${wall + 1} to the near edge. '
                'Wall is ${formatLength(len, u)} long.',
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _submit,
            child: Text(widget.existing == null ? 'Add' : 'Save')),
      ],
    );
  }
}

/// Adds or edits a measured surface (its name and size).
class _SurfaceDialog extends StatefulWidget {
  const _SurfaceDialog({
    required this.unit,
    required this.defaultName,
    this.existing,
  });

  final LengthUnit unit;
  final String defaultName;
  final MeasuredSurface? existing;

  @override
  State<_SurfaceDialog> createState() => _SurfaceDialogState();
}

class _SurfaceDialogState extends State<_SurfaceDialog> {
  final _form = GlobalKey<FormState>();
  late SurfaceKind kind = widget.existing?.kind ?? SurfaceKind.wall;
  late final _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final _width = TextEditingController(
      text: widget.existing == null
          ? ''
          : editableLength(widget.existing!.width, widget.unit));
  late final _height = TextEditingController(
      text: widget.existing == null
          ? ''
          : editableLength(widget.existing!.height, widget.unit));

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final u = widget.unit;
    final name = _name.text.trim();
    final w = parseLength(_width.text, u)!;
    final h = parseLength(_height.text, u)!;
    final e = widget.existing;
    Navigator.pop(
      context,
      e == null
          ? MeasuredSurface(name: name, kind: kind, width: w, height: h)
          : e.copyWith(name: name, kind: kind, width: w, height: h),
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final flat = kind == SurfaceKind.floor || kind == SurfaceKind.raised;
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add surface' : 'Edit surface'),
      scrollable: true,
      content: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
            textCapitalization: TextCapitalization.sentences,
            // Mandatory: the surface is not added without a name.
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (v) => isUnnamed(v ?? '') ? nameNeeded : null,
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<SurfaceKind>(
            initialValue: kind,
            decoration: const InputDecoration(labelText: 'Type'),
            items: [
              for (final k in SurfaceKind.values)
                DropdownMenuItem(value: k, child: Text(k.label)),
            ],
            onChanged: (v) => setState(() => kind = v ?? kind),
          ),
          const SizedBox(height: 14),
          LengthField(controller: _width, unit: u, label: 'Width'),
          const SizedBox(height: 14),
          LengthField(
              controller: _height, unit: u, label: flat ? 'Depth' : 'Height'),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _submit,
            child: Text(widget.existing == null ? 'Add' : 'Save')),
      ],
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.name, required this.onTap, this.number});

  final String name;
  final VoidCallback onTap;

  /// Shown when the photo is pinned on the plan (the pin's number).
  final int? number;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: ScanStore.photoFile(name),
      builder: (context, snap) => ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.radiusM),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 128,
            height: 96,
            child: Stack(fit: StackFit.expand, children: [
              snap.hasData
                  ? Image.file(snap.data!, fit: BoxFit.cover, cacheWidth: 384)
                  : ColoredBox(
                      color: Theme.of(context).colorScheme.outlineVariant),
              if (number != null)
                Positioned(
                  left: 6,
                  top: 6,
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: PlanPainter.accent,
                    child: Text('$number',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A soft tinted notice: the "Room scanned" confirmation, plan warnings.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.leading,
    required this.message,
    this.title,
    this.trailing,
  });

  final Color color;
  final Widget leading;
  final String? title;
  final String message;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: EdgeInsets.fromLTRB(14, 12, trailing == null ? 16 : 6, 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppTheme.radiusL),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null) ...[
                  Text(title!,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                ],
                Text(
                  message,
                  style: (title == null
                          ? theme.textTheme.bodyMedium
                          : theme.textTheme.bodySmall)
                      ?.copyWith(
                          color: title == null ? cs.onSurface : cs.onSurfaceVariant,
                          fontFeatures: AppTheme.tabular),
                ),
              ],
            ),
          ),
          ?trailing,
        ]),
      ),
    );
  }
}

/// A rounded-square tile tinted with [color], leading list rows.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.color,
    required this.child,
    this.filled = false,
    this.size = 40,
    this.radius = 12,
  });

  final Color color;
  final Widget child;
  final bool filled;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : color;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: fg),
        child: DefaultTextStyle.merge(style: TextStyle(color: fg), child: child),
      ),
    );
  }
}

/// One of the summary's headline numbers.
class _HeroMetric extends StatelessWidget {
  const _HeroMetric(
      {required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(children: [
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ),
        ]),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: AppTheme.tabular,
              color: cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

/// "↔ 1.10 m  ↕ 0.57 m" for a line that runs both along and up, else null.
String? lineParts(MeasuredLine l, LengthUnit unit) {
  final run = l.run, rise = l.rise;
  if (run == null || rise == null || run < 0.05 || rise < 0.05) {
    return l.estimated ? 'Approximate: an end is on a plain surface' : null;
  }
  return '↔ ${formatLength(run, unit)} across   ↕ ${formatLength(rise, unit)} up';
}
