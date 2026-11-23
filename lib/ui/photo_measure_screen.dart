import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../capture/ar_measure.dart';
import '../engine/geometry.dart';
import '../engine/models.dart';
import '../engine/photo_measure.dart';
import '../engine/units.dart';
import '../services/app_settings.dart';
import '../services/scan_store.dart';
import 'app_theme.dart';
import 'common.dart';

/// Measures a room from an ordinary photo.
///
/// A photo alone has no scale, so a rectangle of known size lying on the
/// floor (an A4 sheet, a floor tile) is tapped first; its four corners fix
/// how the floor appears in the photo. The room's floor corners tapped next
/// are then converted to metres. Works without AR, on any photo, but is less
/// accurate than scanning: precision drops for corners far from the
/// reference, and corners hidden behind furniture have to be placed by eye.
class PhotoMeasureScreen extends StatefulWidget {
  const PhotoMeasureScreen({super.key, required this.defaultName});

  final String defaultName;

  @override
  State<PhotoMeasureScreen> createState() => _PhotoMeasureScreenState();
}

class _PhotoMeasureScreenState extends State<PhotoMeasureScreen> {
  File? _file;
  ui.Image? _image;
  FloorReference _ref = FloorReference.presets.first;
  final _refPts = <Vec2>[]; // image pixels
  final _cornerPts = <Vec2>[]; // image pixels
  final _viewer = TransformationController();
  bool _saving = false;

  // A point being dragged: in _dragList (_refPts or _cornerPts) at
  // _dragIndex, by pointer _dragPointer; where it was, to put it back.
  List<Vec2>? _dragList;
  int _dragIndex = 0;
  int? _dragPointer;
  Vec2? _dragOriginal;
  Offset _dragFrom = Offset.zero;
  bool _dragMoved = false;

  /// The finger that just lifted was on a point: its tap adds no new one.
  bool _suppressTap = false;

  LengthUnit get unit => AppSettings.unit.value;
  bool get _refDone => _refPts.length == 4;

  List<Vec2>? get _floor => _refDone && _cornerPts.length >= 2
      ? floorCornersFromPhoto(reference: _refPts, ref: _ref, corners: _cornerPts)
      : null;

  @override
  void dispose() {
    _viewer.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(source: source, maxWidth: 4000);
      if (x == null) return;
      final bytes = await File(x.path).readAsBytes();
      final img = await decodeImageFromList(bytes);
      setState(() {
        _file = File(x.path);
        _image = img;
        _refPts.clear();
        _cornerPts.clear();
        _viewer.value = Matrix4.identity();
      });
    } catch (e) {
      if (mounted) showMessage(context, 'Could not open the photo: $e');
    }
  }

  Future<void> _chooseReference() async {
    final picked = await showModalBottomSheet<FloorReference>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text('What is lying on the floor?',
                  style: Theme.of(ctx).textTheme.titleLarge),
              subtitle: const Text('Something rectangular whose size you know. '
                  'Larger references give better results.')),
          const SizedBox(height: 4),
          for (final r in FloorReference.presets)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(Icons.crop_square_rounded),
              title: Text(r.label),
              subtitle: Text(
                  '${formatLength(r.width, unit)} × ${formatLength(r.depth, unit)}',
                  style: const TextStyle(fontFeatures: AppTheme.tabular)),
              selected: r.label == _ref.label,
              onTap: () => Navigator.pop(ctx, r),
            ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Other size…'),
            onTap: () async {
              final w = await askLength(ctx,
                  title: 'Reference length', unit: unit, label: 'Long side');
              if (w == null || w.isNaN || !ctx.mounted) return;
              final d = await askLength(ctx,
                  title: 'Reference width', unit: unit, label: 'Short side');
              if (d == null || d.isNaN || !ctx.mounted) return;
              Navigator.pop(ctx, FloorReference('Custom', w, d));
            },
          ),
        ]),
      ),
    );
    if (picked != null) setState(() => _ref = picked);
  }

  /// A finger down on a point grabs it (s: image to view pixels): the photo
  /// stops panning and zooming until it is let go.
  void _pointerDown(PointerDownEvent e, double s) {
    if (_dragPointer != null) {
      // A second finger: a pinch, not a drag. Put the point back.
      _endDrag(restore: true);
      return;
    }
    _suppressTap = false;
    final zoom = _viewer.value.getMaxScaleOnAxis();
    final reach = 26 / zoom; // view pixels inside the viewer
    List<Vec2>? list;
    var index = 0;
    var best = reach;
    for (final l in [_cornerPts, _refPts]) {
      for (var i = 0; i < l.length; i++) {
        final d = (Offset(l[i].x * s, l[i].y * s) - e.localPosition).distance;
        if (d < best) {
          best = d;
          list = l;
          index = i;
        }
      }
    }
    if (list == null) return;
    _suppressTap = true;
    setState(() {
      _dragPointer = e.pointer;
      _dragList = list;
      _dragIndex = index;
      _dragOriginal = list![index];
      _dragFrom = e.localPosition;
      _dragMoved = false;
    });
  }

  void _pointerMove(PointerMoveEvent e, double s) {
    final list = _dragList, img = _image;
    if (e.pointer != _dragPointer || list == null || img == null) return;
    if (!_dragMoved && (e.localPosition - _dragFrom).distance < 4) return;
    _dragMoved = true;
    setState(() => list[_dragIndex] = Vec2(
          (e.localPosition.dx / s).clamp(0.0, img.width.toDouble()),
          (e.localPosition.dy / s).clamp(0.0, img.height.toDouble()),
        ));
  }

  void _pointerUp(PointerEvent e) {
    if (e.pointer != _dragPointer) return;
    // A room corner must stay where the photo shows floor.
    final bad = _dragMoved && _refDone && _cornerPts.length >= 2 && _floor == null;
    _endDrag(restore: bad);
    if (bad) {
      showMessage(
          context,
          "That point isn't on the floor as seen in the photo. Drag it to "
          'where the wall meets the floor.');
    }
  }

  void _endDrag({required bool restore}) {
    final list = _dragList, original = _dragOriginal;
    setState(() {
      if (restore && list != null && original != null) list[_dragIndex] = original;
      _dragPointer = null;
      _dragList = null;
      _dragOriginal = null;
      _dragMoved = false;
    });
  }

  void _tap(Vec2 p) {
    if (_suppressTap) {
      // The tap was on an existing point (or ended a drag of one).
      _suppressTap = false;
      return;
    }
    setState(() {
      if (!_refDone) {
        _refPts.add(p);
      } else {
        _cornerPts.add(p);
      }
    });
    if (_refDone && _cornerPts.length >= 2 && _floor == null) {
      setState(() => _cornerPts.removeLast());
      showMessage(
          context,
          "That point isn't on the floor as seen in the photo. Tap where "
          'the wall meets the floor.');
    }
  }

  void _undo() {
    setState(() {
      if (_cornerPts.isNotEmpty) {
        _cornerPts.removeLast();
      } else if (_refPts.isNotEmpty) {
        _refPts.removeLast();
      }
    });
  }

  Future<void> _create() async {
    final floor = _floor;
    final img = _image, file = _file;
    if (floor == null || floor.length < 3 || img == null || file == null) return;
    setState(() => _saving = true);
    try {
      final scan = scanFromCorners(floor,
          name: widget.defaultName, source: CaptureSource.photo);
      // Keep the photo with the taps and lengths drawn on it.
      final png = await _annotated(img);
      final tmp = File('${Directory.systemTemp.path}/photo_measure_'
          '${DateTime.now().millisecondsSinceEpoch}.png');
      await tmp.writeAsBytes(png);
      scan.photos.add(await ScanStore.keepPhoto(tmp.path, prefix: 'photo'));
      await tmp.delete();
      if (mounted) Navigator.pop(context, scan);
    } catch (e) {
      if (mounted) showMessage(context, 'Could not create the room: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<List<int>> _annotated(ui.Image img) async {
    const maxSide = 2000.0;
    final s = math.min(1.0, maxSide / math.max(img.width, img.height));
    final size = Size(img.width * s, img.height * s);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.high);
    canvas.scale(s);
    _MarksPainter(
      refPts: _refPts,
      cornerPts: _cornerPts,
      floor: _floor,
      unit: unit,
      dotScale: 1 / s * (size.width / 1000),
    ).paint(canvas, Size(img.width.toDouble(), img.height.toDouble()));
    final out = await recorder
        .endRecording()
        .toImage(size.width.round(), size.height.round());
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  // ---------------------------------------------------------------- build

  String get _instruction {
    if (!_refDone) {
      final n = _refPts.length;
      return 'Step 1 of 2 · Zoom in and tap the ${n == 0 ? 'first' : 'next'} '
          'corner of the ${_ref.label.toLowerCase()} on the floor (${n + 1} of '
          '4), going around it, starting at one end of a long side.';
    }
    if (_cornerPts.length < 3) {
      return 'Step 2 of 2 · Tap the room corners where the walls meet the '
          'floor, in order around the room (${_cornerPts.length} so far). '
          'With 3 corners the room is completed as a rectangle.';
    }
    return 'Tap more corners for an L-shaped room, or create the room. '
        'Drag any point to adjust it.';
  }

  Widget _photoView() {
    final img = _image!;
    return LayoutBuilder(builder: (context, c) {
      final s = math.min(c.maxWidth / img.width, c.maxHeight / img.height);
      final w = img.width * s, h = img.height * s;
      return Center(
        child: InteractiveViewer(
          transformationController: _viewer,
          maxScale: 8,
          // Off while a point is held, so the drag moves the point.
          panEnabled: _dragPointer == null,
          scaleEnabled: _dragPointer == null,
          child: SizedBox(
            width: w,
            height: h,
            child: Listener(
              onPointerDown: (e) => _pointerDown(e, s),
              onPointerMove: (e) => _pointerMove(e, s),
              onPointerUp: _pointerUp,
              onPointerCancel: (e) {
                if (e.pointer == _dragPointer) _endDrag(restore: true);
              },
              child: GestureDetector(
                onTapUp: (d) => _tap(Vec2(
                    d.localPosition.dx / s, d.localPosition.dy / s)),
                child: Stack(fit: StackFit.expand, children: [
                  RawImage(image: img, fit: BoxFit.fill),
                  CustomPaint(
                    painter: _MarksPainter(
                      refPts: _refPts,
                      cornerPts: _cornerPts,
                      floor: _floor,
                      unit: unit,
                      viewScale: s,
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _picker() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const steps = [
      'Have something large, flat and of known size on the floor in the '
          'middle of the room: a 60 × 60 cm floor tile is ideal. Paper sheets '
          'are too small for more than a rough figure.',
      'Stand in a corner and take the photo with the 0.5× wide lens, so '
          'the other three corners and the reference are all in view.',
      'Zoom in and tap the reference\'s corners, then the room\'s '
          'corners where the walls meet the floor.',
    ];
    final mobile = Platform.isAndroid || Platform.isIOS;
    return SafeArea(
      child: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: AppTheme.heroGradient,
                    borderRadius: BorderRadius.circular(AppTheme.radiusL),
                  ),
                  child: const Icon(Icons.photo_camera_back_outlined,
                      size: 30, color: Colors.white),
                ),
              ),
              const SizedBox(height: 18),
              Text('Measure a room from a photo',
                  style: theme.textTheme.headlineSmall),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
                  child: Column(children: [
                    for (final (i, t) in steps.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: cs.primaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Text('${i + 1}',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                      color: cs.onPrimaryContainer,
                                      fontFeatures: AppTheme.tabular)),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(t,
                                    style: theme.textTheme.bodyMedium),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: AppTheme.door.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppTheme.radiusM),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 18, color: AppTheme.door),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'An estimate, less accurate than a camera scan: with a '
                        '60 cm tile and careful taps expect about 2–6 % on '
                        'each wall; with an A4 sheet, 10 % or worse. Check one '
                        'wall with a tape and use Calibrate on the plan.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mobile) ...[
                FilledButton.icon(
                  onPressed: () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Take photo'),
                ),
                const SizedBox(height: 10),
              ],
              OutlinedButton.icon(
                onPressed: () => _pick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose a photo'),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _panel() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final floor = _floor;
    String? headline, detail;
    if (floor != null && floor.length >= 3) {
      final area = signedArea(floor).abs();
      var per = 0.0;
      for (var i = 0; i < floor.length; i++) {
        per += floor[i].distanceTo(floor[(i + 1) % floor.length]);
      }
      headline = formatArea(area, unit);
      detail = 'perimeter ${formatLength(per, unit)}';
    } else if (floor != null && floor.length == 2) {
      headline = formatLength(floor[0].distanceTo(floor[1]), unit);
      detail = 'wall length';
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppTheme.radiusXL)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: ActionChip(
                    avatar: const Icon(Icons.crop_square_rounded,
                        size: 18, color: AppTheme.scan),
                    label: Text('Reference: ${_ref.label} '
                        '(${formatLength(_ref.width, unit)} × ${formatLength(_ref.depth, unit)})',
                        overflow: TextOverflow.ellipsis),
                    onPressed: _chooseReference,
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Text(_instruction, style: theme.textTheme.bodyMedium),
              if (headline != null) ...[
                const SizedBox(height: 8),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: headline,
                        style: theme.textTheme.headlineSmall?.copyWith(
                            fontFeatures: AppTheme.tabular,
                            color: cs.onSurface)),
                    TextSpan(
                        text: '   $detail',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontFeatures: AppTheme.tabular,
                            color: cs.onSurfaceVariant)),
                  ]),
                ),
              ],
              const SizedBox(height: 10),
              Row(children: [
                TextButton.icon(
                  onPressed: _refPts.isEmpty && _cornerPts.isEmpty ? null : _undo,
                  icon: const Icon(Icons.undo_rounded),
                  label: const Text('Undo'),
                ),
                TextButton.icon(
                  onPressed: () => setState(() {
                    _file = null;
                    _image = null;
                  }),
                  icon: const Icon(Icons.photo_outlined),
                  label: const Text('Other photo'),
                ),
                const Spacer(),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  onPressed: _saving || floor == null || floor.length < 3
                      ? null
                      : _create,
                  child: const Text('Create room'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('Measure from a photo'),
      ),
      body: _image == null
          ? _picker()
          : Container(
              color: Colors.black,
              child: Column(children: [
                Expanded(child: _photoView()),
                _panel(),
              ]),
            ),
    );
  }
}

/// The reference's corners, the room's corners and the measured lengths,
/// drawn over the photo (in image pixel coordinates).
class _MarksPainter extends CustomPainter {
  _MarksPainter({
    required this.refPts,
    required this.cornerPts,
    required this.floor,
    required this.unit,
    this.viewScale = 1,
    this.dotScale,
  });

  final List<Vec2> refPts, cornerPts;
  final List<Vec2>? floor;
  final LengthUnit unit;

  /// Image pixels to canvas pixels (on screen).
  final double viewScale;

  /// Size of dots and text relative to on-screen size (for the saved image).
  final double? dotScale;

  static const refColor = Color(0xFF22C55E);
  static const roomColor = Color(0xFF3B82F6);

  @override
  void paint(Canvas canvas, Size size) {
    final k = dotScale ?? 1.0;
    Offset o(Vec2 p) => Offset(p.x * viewScale, p.y * viewScale);
    void poly(List<Vec2> pts, Color c, {bool close = true}) {
      if (pts.length < 2) return;
      final path = Path()..moveTo(o(pts[0]).dx, o(pts[0]).dy);
      for (final p in pts.skip(1)) {
        path.lineTo(o(p).dx, o(p).dy);
      }
      if (close && pts.length > 2) path.close();
      canvas.drawPath(
          path,
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5 * k);
    }

    void dot(Vec2 p, Color c) {
      canvas.drawCircle(o(p), 7 * k, Paint()..color = Colors.white);
      canvas.drawCircle(o(p), 4.5 * k, Paint()..color = c);
    }

    void label(String s, Offset at, Color bg) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                color: Colors.white,
                fontSize: 13 * k,
                fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      final r = Rect.fromCenter(
          center: at, width: tp.width + 12 * k, height: tp.height + 6 * k);
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(8 * k)),
          Paint()..color = bg.withValues(alpha: 0.9));
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }

    poly(refPts, refColor, close: refPts.length == 4);
    for (final p in refPts) {
      dot(p, refColor);
    }
    // With 3 corners only the two walls between them are in the photo (the
    // room is completed as a rectangle on the plan).
    poly(cornerPts, roomColor, close: cornerPts.length >= 4);
    for (final p in cornerPts) {
      dot(p, roomColor);
    }
    final f = floor;
    if (f != null) {
      final n = cornerPts.length;
      final sides = n >= 4 ? n : n - 1;
      for (var i = 0; i < sides; i++) {
        final a = cornerPts[i], b = cornerPts[(i + 1) % n];
        final len = f[i].distanceTo(f[(i + 1) % f.length]);
        label(formatLength(len, unit), (o(a) + o(b)) / 2, roomColor);
      }
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => true;
}
