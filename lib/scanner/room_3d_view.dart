import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../engine/measure3d.dart';
import '../engine/units.dart';
import '../ui/app_theme.dart';
import 'room_model_3d.dart';

/// Where the 3D view's camera is. The view eases from what it shows towards
/// the target set here, so presets ([topDown], [perspective]) animate.
class Room3DController extends ChangeNotifier {
  Room3DController({this.yaw = perspectiveYaw, this.pitch = 0.75, this.zoom = 1});

  /// Turn round the room (radians) and look-down angle (0 = level,
  /// pi/2 = straight down).
  double yaw, pitch;

  /// 1 = whole model fits; larger is closer.
  double zoom;

  /// Pan of the looked-at point, in metres, on the floor.
  double panX = 0, panZ = 0;

  static const minPitch = 0.08, maxPitch = math.pi / 2 - 0.001;

  void _set({double? yaw, double? pitch, double? zoom, bool resetPan = false}) {
    if (yaw != null) this.yaw = yaw;
    if (pitch != null) this.pitch = pitch.clamp(minPitch, maxPitch);
    if (zoom != null) this.zoom = zoom.clamp(0.4, 6.0);
    if (resetPan) panX = panZ = 0;
    notifyListeners();
  }

  /// Straight down, turned like the 2D floor plan (its top at the top).
  void topDown() => _set(yaw: _nearestTurn(0), pitch: maxPitch, zoom: 1, resetPan: true);

  /// The default 3D "dollhouse" angle.
  static const perspectiveYaw = -0.6;

  /// [target] plus whole turns, as close as possible to [yaw]: presets turn
  /// the short way round.
  double _nearestTurn(double target) =>
      target + (2 * math.pi) * ((yaw - target) / (2 * math.pi)).round();

  /// The default 3D "dollhouse" angle.
  void perspective() =>
      _set(yaw: _nearestTurn(perspectiveYaw), pitch: 0.75, zoom: 1, resetPan: true);

  /// Turn by a quarter round the room.
  void turn() => _set(yaw: yaw + math.pi / 2);

  void orbit(double dYaw, double dPitch) => _set(yaw: yaw + dYaw, pitch: pitch + dPitch);
  void scaleBy(double f) => _set(zoom: zoom * f);
  void pan(double dx, double dz) {
    panX += dx;
    panZ += dz;
    notifyListeners();
  }
}

/// The scanned room(s) in 3D: drag to turn round, pinch to zoom, two
/// fingers to move, double tap to reset. Walls between the camera and the
/// room fade so the inside can be seen ([seeThrough]).
class Room3DView extends StatefulWidget {
  const Room3DView({
    super.key,
    required this.model,
    required this.controller,
    required this.unit,
    this.showLabels = true,
    this.showFurniture = true,
    this.seeThrough = true,
    this.selectedWall,
    this.onWallTap,
  });

  final RoomModel3D model;
  final Room3DController controller;
  final LengthUnit unit;
  final bool showLabels, showFurniture, seeThrough;

  /// (room, wall) to highlight.
  final (int, int)? selectedWall;
  final void Function(int room, int wall)? onWallTap;

  @override
  State<Room3DView> createState() => _Room3DViewState();
}

class _Room3DViewState extends State<Room3DView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);

  // What is shown now; eases towards the controller.
  late double _yaw, _pitch, _zoom, _panX, _panZ;
  _Camera? _lastCamera;
  Size _lastSize = Size.zero;

  // Gesture state.
  double _startZoom = 1;
  Offset _lastFocal = Offset.zero;
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    // Opens looking straight down (the 2D plan) and swings into 3D: the
    // same room as the plan, now with its walls standing up.
    _yaw = 0;
    _pitch = Room3DController.maxPitch;
    _zoom = c.zoom;
    _panX = c.panX;
    _panZ = c.panZ;
    c.addListener(_wake);
    _ticker.start();
  }

  @override
  void didUpdateWidget(Room3DView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_wake);
      widget.controller.addListener(_wake);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_wake);
    _ticker.dispose();
    super.dispose();
  }

  void _wake() {
    if (!_ticker.isActive) _ticker.start();
  }

  void _tick(Duration _) {
    final c = widget.controller;
    double ease(double from, double to) => from + (to - from) * 0.18;
    final ny = ease(_yaw, c.yaw), np = ease(_pitch, c.pitch);
    final nz = ease(_zoom, c.zoom);
    final nx = ease(_panX, c.panX), nzz = ease(_panZ, c.panZ);
    final done = (ny - c.yaw).abs() < 1e-4 &&
        (np - c.pitch).abs() < 1e-4 &&
        (nz - c.zoom).abs() < 1e-4 &&
        (nx - c.panX).abs() < 1e-4 &&
        (nzz - c.panZ).abs() < 1e-4;
    setState(() {
      _yaw = done ? c.yaw : ny;
      _pitch = done ? c.pitch : np;
      _zoom = done ? c.zoom : nz;
      _panX = done ? c.panX : nx;
      _panZ = done ? c.panZ : nzz;
    });
    if (done) _ticker.stop();
  }

  _Camera _camera(Size size) {
    final m = widget.model;
    final target = m.center + Vec3(_panX, -m.center.y * 0.5, _panZ);
    // Far enough for the whole model to fit at zoom 1. The lens narrows
    // (and the camera backs off) as it looks straight down, so the plan
    // view is nearly flat, like the 2D plan, instead of walls splaying out.
    final down = ((_pitch - 1.0) / (Room3DController.maxPitch - 1.0)).clamp(0.0, 1.0);
    final fov = 0.9 + (0.18 - 0.9) * down; // radians
    final dist = (m.radius / math.sin(fov / 2)) / _zoom;
    final eye = target +
        Vec3(math.cos(_pitch) * math.sin(_yaw), math.sin(_pitch),
                math.cos(_pitch) * math.cos(_yaw)) *
            dist;
    final focal = size.shortestSide / (2 * math.tan(fov / 2));
    return _Camera(eye, target, _yaw, focal, size.center(Offset.zero));
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startZoom = widget.controller.zoom;
    _lastFocal = d.localFocalPoint;
    _pointers = d.pointerCount;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final c = widget.controller;
    final delta = d.localFocalPoint - _lastFocal;
    _lastFocal = d.localFocalPoint;
    if (d.pointerCount != _pointers) {
      // A finger was added or lifted: restart from here, no jump.
      _pointers = d.pointerCount;
      _startZoom = c.zoom / d.scale;
      return;
    }
    if (d.pointerCount >= 2) {
      c.zoom = (_startZoom * d.scale).clamp(0.4, 6.0);
      // Move the looked-at point across the floor, in the camera's frame.
      final cam = _lastCamera;
      if (cam != null) {
        final perPx = (cam.eye - cam.target).length / cam.focal;
        final right = Vec3(math.cos(_yaw), 0, -math.sin(_yaw));
        final fwd = Vec3(-math.sin(_yaw), 0, -math.cos(_yaw));
        final move = right * (-delta.dx * perPx) + fwd * (delta.dy * perPx);
        c.pan(move.x, move.z);
      }
    } else {
      c.orbit(-delta.dx * 0.008, delta.dy * 0.006);
    }
  }

  void _onTapUp(TapUpDetails d) {
    final cb = widget.onWallTap;
    final cam = _lastCamera;
    if (cb == null || cam == null) return;
    // The nearest wall face under the finger.
    Face3D? hit;
    var best = double.infinity;
    for (final f in widget.model.faces) {
      if (f.wall == null) continue;
      final pts = cam.projectAll(f.points);
      if (pts == null) continue;
      final path = Path()..addPolygon(pts, true);
      if (!path.contains(d.localPosition)) continue;
      final depth = cam.depth(f.centroid);
      if (_isFaded(f, cam)) continue;
      if (depth < best) {
        best = depth;
        hit = f;
      }
    }
    if (hit != null) cb(hit.room, hit.wall!);
  }

  bool _isFaded(Face3D f, _Camera cam) =>
      widget.seeThrough &&
      f.outward != null &&
      _pitch < 1.35 &&
      f.outward!.dot(cam.eye - f.centroid) > 0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      _lastSize = size;
      final cam = _camera(size);
      _lastCamera = cam;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onDoubleTap: widget.controller.perspective,
        onTapUp: _onTapUp,
        child: CustomPaint(
          size: _lastSize,
          painter: _Room3DPainter(
            model: widget.model,
            camera: cam,
            unit: widget.unit,
            dark: dark,
            showLabels: widget.showLabels,
            showFurniture: widget.showFurniture,
            faded: (f) => _isFaded(f, cam),
            selectedWall: widget.selectedWall,
          ),
        ),
      );
    });
  }
}

/// A pinhole camera at [eye] looking at [target].
class _Camera {
  _Camera(this.eye, this.target, double yaw, this.focal, this.centre) {
    final f = (target - eye).normalized;
    fwd = f;
    var r = f.cross(const Vec3(0, 1, 0));
    if (r.length < 1e-6) {
      // Straight down: right is set by the turn round the room.
      r = Vec3(math.cos(yaw), 0, -math.sin(yaw));
    }
    right = r.normalized;
    up = right.cross(fwd).normalized;
  }

  final Vec3 eye, target;
  final double focal;
  final Offset centre;
  late final Vec3 fwd, right, up;

  static const near = 0.05;

  double depth(Vec3 p) => (p - eye).dot(fwd);

  Offset? project(Vec3 p) {
    final d = p - eye;
    final z = d.dot(fwd);
    if (z < near) return null;
    return centre + Offset(d.dot(right) * focal / z, -d.dot(up) * focal / z);
  }

  List<Offset>? projectAll(List<Vec3> pts) {
    final out = <Offset>[];
    for (final p in pts) {
      final s = project(p);
      if (s == null) return null;
      out.add(s);
    }
    return out;
  }
}

class _Room3DPainter extends CustomPainter {
  _Room3DPainter({
    required this.model,
    required this.camera,
    required this.unit,
    required this.dark,
    required this.showLabels,
    required this.showFurniture,
    required this.faded,
    required this.selectedWall,
  });

  final RoomModel3D model;
  final _Camera camera;
  final LengthUnit unit;
  final bool dark, showLabels, showFurniture;
  final bool Function(Face3D) faded;
  final (int, int)? selectedWall;

  static const _light = Vec3(0.35, 0.85, 0.4);

  Color _base(Part3D p) => switch (p) {
        Part3D.floor => dark ? const Color(0xFF3A3F4E) : const Color(0xFFE9E1D3),
        Part3D.wall => dark ? const Color(0xFFC9CED9) : const Color(0xFFF4F5F8),
        Part3D.door => AppTheme.door,
        Part3D.window => AppTheme.window,
        Part3D.opening => Colors.transparent,
        Part3D.furniture => dark ? const Color(0xFF7487AD) : const Color(0xFF9AA8C4),
      };

  Color _shade(Color c, Vec3 n) {
    final l = _light.normalized;
    final k = 0.74 + 0.26 * n.dot(l).abs();
    return Color.from(
        alpha: c.a, red: c.r * k, green: c.g * k, blue: c.b * k);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Floors under everything else; the rest far to near.
    final floors = <Face3D>[], rest = <Face3D>[];
    for (final f in model.faces) {
      if (f.part == Part3D.furniture && !showFurniture) continue;
      (f.part == Part3D.floor ? floors : rest).add(f);
    }
    double d(Face3D f) => camera.depth(f.centroid);
    floors.sort((a, b) => d(b).compareTo(d(a)));
    rest.sort((a, b) => d(b).compareTo(d(a)));

    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeJoin = StrokeJoin.round
      ..color = dark ? const Color(0xFF0B1426) : const Color(0xFF4A5468);

    for (final f in [...floors, ...rest]) {
      final pts = camera.projectAll(f.points);
      if (pts == null) continue;
      final path = Path()..addPolygon(pts, true);
      final fade = faded(f);
      final selected = selectedWall != null &&
          f.wall == selectedWall!.$2 &&
          f.room == selectedWall!.$1 &&
          f.part == Part3D.wall;
      var fill = _shade(selected ? AppTheme.brand : _base(f.part), f.normal);
      if (f.part == Part3D.window) fill = fill.withValues(alpha: 0.45);
      if (fade) fill = fill.withValues(alpha: fill.a * 0.12);
      if (f.part != Part3D.opening) {
        canvas.drawPath(path, Paint()..color = fill);
      }
      canvas.drawPath(
          path,
          edge
            ..color = (f.part == Part3D.door
                    ? AppTheme.door
                    : f.part == Part3D.window
                        ? AppTheme.window
                        : (dark ? const Color(0xFF0B1426) : const Color(0xFF4A5468)))
                .withValues(alpha: fade ? 0.25 : (f.part == Part3D.opening ? 0.6 : 0.9)));
    }

    if (showLabels) {
      for (final l in model.labels) {
        final s = camera.project(l.at);
        if (s == null) continue;
        _pill(canvas, s, formatLength(l.length, unit));
      }
    }
  }

  void _pill(Canvas canvas, Offset at, String text) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(
              color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: at, width: tp.width + 12, height: tp.height + 6),
        const Radius.circular(10));
    canvas.drawRRect(r, Paint()..color = AppTheme.ink.withValues(alpha: 0.82));
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_Room3DPainter old) => true;
}
