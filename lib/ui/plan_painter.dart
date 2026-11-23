import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/floor_map.dart' show pointInPolygon;
import '../engine/floor_plan_builder.dart';
import '../engine/geometry.dart';
import '../engine/models.dart';
import '../engine/units.dart';

/// Maps plan coordinates (metres, y up) to canvas pixels (y down).
class PlanLayout {
  const PlanLayout(this.scale, this.origin, this.maxY);

  /// Fits [plan] into [size], leaving room for dimension labels.
  factory PlanLayout.fit(FloorPlan plan, Size size,
      {double top = 0, double bottom = 0, double pad = 64}) {
    var maxX = 0.0, maxY = 0.0;
    for (final c in plan.corners) {
      maxX = math.max(maxX, c.x);
      maxY = math.max(maxY, c.y);
    }
    final availW = math.max(10.0, size.width - 2 * pad);
    final availH = math.max(10.0, size.height - 2 * pad - top - bottom);
    final s =
        math.min(availW / math.max(maxX, 0.5), availH / math.max(maxY, 0.5));
    return PlanLayout(
      s,
      Offset(pad + (availW - maxX * s) / 2, pad + top + (availH - maxY * s) / 2),
      maxY,
    );
  }

  final double scale;
  final Offset origin;
  final double maxY;

  Offset toScreen(Vec2 v) =>
      Offset(origin.dx + v.x * scale, origin.dy + (maxY - v.y) * scale);

  Vec2 toPlan(Offset p) =>
      Vec2((p.dx - origin.dx) / scale, maxY - (p.dy - origin.dy) / scale);
}

/// Draws a [FloorPlan] as a 2D architectural-style drawing: walls, doors,
/// windows, a dimension line and length on every wall, the area, and a
/// scale bar. Uses fixed light colours so exports look the same in light
/// and dark mode.
class PlanPainter extends CustomPainter {
  PlanPainter({
    required this.plan,
    required this.unit,
    this.highlightWall,
    this.highlightCorner,
    this.title,
    this.layout,
    this.editing = false,
    this.handles = false,
    this.highlightLine,
    this.zoom = 1.0,
  });

  final FloorPlan plan;
  final LengthUnit unit;
  final int? highlightWall;
  final int? highlightCorner;
  final String? title;

  /// Fixed layout (used while dragging a corner); fitted to the size if null.
  final PlanLayout? layout;

  /// Edit-shape mode: no corner angles or scale bar.
  final bool editing;

  /// Draws the draggable circles: every corner and both ends of every
  /// line (on screen only, never in exports).
  final bool handles;

  /// The line whose end is being dragged (highlighted).
  final int? highlightLine;

  /// Current zoom of the surrounding viewer, to keep handles a constant size.
  final double zoom;

  static const paper = Color(0xFFFFFFFF);
  static const ink = Color(0xFF0B1426);
  static const quiet = Color(0xFF66708A);
  static const grid = Color(0xFFEEF1F8);
  static const floorFill = Color(0xFFEDF1FF);
  static const accent = Color(0xFF2F5BFF);
  static const windowColor = Color(0xFF0EA5E9);
  static const doorColor = Color(0xFFD97706);
  static const surfaceColor = Color(0xFF8B5CF6);
  static const lineColor = Color(0xFFCA8A04);

  late PlanLayout _l;

  Offset _p(Vec2 v) => _l.toScreen(v);

  /// Plan-space direction to screen-space direction (y flips).
  Offset _d(Vec2 v) => Offset(v.x, -v.y);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    final pts = plan.corners;
    _l = layout ??
        PlanLayout.fit(plan, size, top: title != null ? 36.0 : 0.0);
    final s = _l.scale;

    if (title != null) {
      _text(canvas, title!, Offset(size.width / 2, 28),
          size: 16, weight: FontWeight.w600);
    }
    _drawGrid(canvas, size);

    // Floor
    final floor = Path()..addPolygon([for (final c in pts) _p(c)], true);
    canvas.drawPath(floor, Paint()..color = floorFill);
    for (final m in plan.surfaces) {
      if (m.kind != SurfaceKind.wall) _drawAreaSurface(canvas, m);
    }

    // Walls
    final wallPx = math.max(5.0, 0.12 * s);
    final wallPaint = Paint()
      ..color = ink
      ..strokeWidth = wallPx
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter;
    canvas.drawPath(floor, wallPaint);
    if (highlightWall != null && highlightWall! < plan.wallCount) {
      canvas.drawLine(
          _p(plan.wallStart(highlightWall!)),
          _p(plan.wallEnd(highlightWall!)),
          Paint()
            ..color = accent
            ..strokeWidth = wallPx + 2
            ..strokeCap = StrokeCap.square);
    }

    for (final o in plan.openings) {
      _drawOpening(canvas, o, wallPx);
    }
    for (final m in plan.surfaces) {
      if (m.kind == SurfaceKind.wall) _drawWallSurface(canvas, m, wallPx);
    }
    for (var i = 0; i < plan.wallCount; i++) {
      _drawDimension(canvas, i, wallPx);
    }
    for (var k = 0; k < plan.lines.length; k++) {
      _drawLine(canvas, plan.lines[k], on: k == highlightLine);
    }
    if (!editing) _drawCornerAngles(canvas, wallPx);

    // Area and height in the middle of the room
    final c = _p(polygonCentroid(pts));
    _text(canvas, formatArea(plan.area, unit), c,
        size: 15, weight: FontWeight.w700);
    if (plan.height != null) {
      _text(canvas, 'Ceiling ${formatLength(plan.height!, unit)}',
          c + const Offset(0, 20),
          size: 11, color: quiet);
    }
    if (handles || editing) _drawHandles(canvas);
    if (!editing) _drawScaleBar(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final step = unit.isMetric ? 0.5 : 0.6096; // 0.5 m or 2 ft
    final s = _l.scale, o = _l.origin;
    final p = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final x0 = -(o.dx / s), x1 = (size.width - o.dx) / s;
    for (var x = (x0 / step).floor() * step; x <= x1; x += step) {
      final sx = o.dx + x * s;
      canvas.drawLine(Offset(sx, 0), Offset(sx, size.height), p);
    }
    final yTop = _l.maxY + o.dy / s;
    final yBottom = _l.maxY - (size.height - o.dy) / s;
    for (var y = (yBottom / step).floor() * step; y <= yTop; y += step) {
      final sy = o.dy + (_l.maxY - y) * s;
      canvas.drawLine(Offset(0, sy), Offset(size.width, sy), p);
    }
  }

  void _drawOpening(Canvas canvas, Opening o, double wallPx) {
    final span = plan.openingSpan(o);
    if (span == null) return;
    final (s, e) = span;
    final width = s.distanceTo(e);
    final dir = (e - s).normalized;

    // Cut the gap out of the wall
    canvas.drawLine(
        _p(s),
        _p(e),
        Paint()
          ..color = paper
          ..strokeWidth = wallPx + 2);
    // Jambs
    final jamb = Paint()
      ..color = ink
      ..strokeWidth = 2;
    final n = _d(plan.outwardNormal(o.wallIndex)) * (wallPx / 2);
    canvas.drawLine(_p(s) - n, _p(s) + n, jamb);
    canvas.drawLine(_p(e) - n, _p(e) + n, jamb);

    final inward = plan.outwardNormal(o.wallIndex) * -1;
    final thin = Paint()
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    switch (o.type) {
      case OpeningType.door:
        // Leaf drawn open at 90 degrees into the room, plus its swing arc.
        final leafEnd = s + inward * width;
        canvas.drawLine(_p(s), _p(leafEnd), thin..color = doorColor);
        final r = width * _l.scale;
        final startAng = math.atan2(_d(inward).dy, _d(inward).dx);
        final endAng = math.atan2(_d(dir).dy, _d(dir).dx);
        var sweep = endAng - startAng;
        if (sweep > math.pi) sweep -= 2 * math.pi;
        if (sweep < -math.pi) sweep += 2 * math.pi;
        canvas.drawArc(Rect.fromCircle(center: _p(s), radius: r), startAng,
            sweep, false, thin..color = doorColor.withValues(alpha: 0.6));
      case OpeningType.window:
        final off = _d(inward) * (wallPx / 2);
        canvas.drawLine(_p(s) + off, _p(e) + off, thin..color = windowColor);
        canvas.drawLine(_p(s) - off, _p(e) - off, thin..color = windowColor);
        canvas.drawLine(_p(s), _p(e), thin..color = windowColor);
      case OpeningType.opening:
        break;
    }

    // Its measured size, just inside the room.
    final label = [
      o.height != null
          ? '${_short(o.width)} × ${_short(o.height!)}'
          : _short(o.width),
      if (o.sill != null) 'sill ${_short(o.sill!)}',
    ].join('  ·  ');
    final color = o.type == OpeningType.window ? windowColor : doorColor;
    // Further in than the wall's number tag (W1, W2…), which sits at the
    // middle of the wall too.
    var at = _p((s + e) / 2) + _d(inward) * (wallPx / 2 + 28);
    // Doors: beyond the swing arc rather than on top of it.
    if (o.type == OpeningType.door) at += _d(inward) * (width * _l.scale);
    _textAlong(canvas, label, at, _d(dir), color: color);
  }

  /// A small label running parallel to [dir] (kept upright), so labels by
  /// a wall stay on the inside of it whatever the wall's direction.
  void _textAlong(Canvas canvas, String label, Offset at, Offset dir,
      {required Color color}) {
    var ang = math.atan2(dir.dy, dir.dx);
    if (ang > math.pi / 2) ang -= math.pi;
    if (ang < -math.pi / 2) ang += math.pi;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(ang);
    _text(canvas, label, Offset.zero, size: 10, color: color, background: true);
    canvas.restore();
  }

  /// A length without its unit, for compact labels on the drawing.
  String _short(double m) {
    final f = formatLength(m, unit);
    return unit.isMetric ? f.replaceAll(RegExp(r' ?c?m$'), '') : f;
  }

  /// A floor area, worktop or other flat surface: its outline seen from
  /// above with its size.
  void _drawAreaSurface(Canvas canvas, MeasuredSurface m) {
    if (m.footprint.length < 3) return;
    final path = Path()..addPolygon([for (final p in m.footprint) _p(p)], true);
    canvas.drawPath(path, Paint()..color = surfaceColor.withValues(alpha: 0.10));
    canvas.drawPath(
        path,
        Paint()
          ..color = surfaceColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    _text(canvas, '${m.name}  ${_short(m.width)} × ${_short(m.height)}',
        _p(polygonCentroid(m.footprint)),
        size: 10, color: surfaceColor, background: true);
  }

  /// A measured stretch of wall (a wall section, a cabinet front): a band
  /// along the inside of the nearest wall.
  void _drawWallSurface(Canvas canvas, MeasuredSurface m, double wallPx) {
    if (m.footprint.length < 2 || plan.wallCount < 3) return;
    final walls = [
      for (var i = 0; i < plan.wallCount; i++)
        WallLine(plan.wallStart(i), plan.wallEnd(i)),
    ];
    final mid = (m.footprint[0] + m.footprint[1]) / 2;
    final i = locateOnWalls(walls, mid).wallIndex;
    final w = walls[i];
    final len = w.length;
    if (len <= 0) return;
    double along(Vec2 p) => ((p - w.a).dot(w.dir)).clamp(0.0, len);
    final t0 = along(m.footprint[0]), t1 = along(m.footprint[1]);
    final a = w.a + w.dir * math.min(t0, t1), b = w.a + w.dir * math.max(t0, t1);
    final inward = _d(plan.outwardNormal(i) * -1);
    final off = inward * (wallPx / 2 + 3);
    canvas.drawLine(
        _p(a) + off,
        _p(b) + off,
        Paint()
          ..color = surfaceColor
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.butt);
    _textAlong(canvas, '${m.name}  ${_short(m.width)} × ${_short(m.height)}',
        _p((a + b) / 2) + inward * (wallPx / 2 + 14), _d(w.dir),
        color: surfaceColor);
  }

  /// A point-to-point distance: a dashed line between its two ends as seen
  /// from above, with the measured length (which may include height).
  void _drawLine(Canvas canvas, MeasuredLine l, {bool on = false}) {
    if (l.footprint.length < 2) return;
    final a = _p(l.footprint[0]), b = _p(l.footprint[1]);
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2;
    final d = b - a;
    final len = d.distance;
    if (len > 1) {
      final step = d / len;
      for (var t = 0.0; t < len; t += 10) {
        canvas.drawLine(a + step * t, a + step * math.min(t + 6, len), paint);
      }
    }
    if (handles) {
      // Draggable ends: a ring like the corners', in the line's colour.
      final r = (on ? 8 : 7) / zoom;
      for (final e in [a, b]) {
        canvas.drawCircle(e, r + 2 / zoom, Paint()..color = paper);
        canvas.drawCircle(e, r, Paint()..color = on ? accent : lineColor);
        canvas.drawCircle(e, r * 0.4, Paint()..color = paper);
      }
    } else {
      canvas.drawCircle(a, 3.5, paint);
      canvas.drawCircle(b, 3.5, paint);
    }
    _text(canvas,
        '${l.name}  ${l.estimated ? '≈ ' : ''}${formatLength(l.length, unit)}',
        (a + b) / 2,
        size: 10, color: lineColor, background: true);
  }

  /// The angle inside the room at every corner.
  void _drawCornerAngles(Canvas canvas, double wallPx) {
    final n = plan.wallCount;
    for (var i = 0; i < n; i++) {
      final cur = plan.corners[i];
      final u1 = (plan.corners[(i - 1 + n) % n] - cur).normalized;
      final u2 = (plan.corners[(i + 1) % n] - cur).normalized;
      var bis = (u1 + u2).normalized;
      if (bis == Vec2.zero) bis = u1.perp;
      // Point the label into the room (reflex corners bisect outwards).
      final probe = cur + bis * (0.05 / _l.scale * 20);
      if (!pointInPolygon(probe, plan.corners)) bis = bis * -1;
      final at = _p(cur) + _d(bis) * (wallPx / 2 + 16);
      _text(canvas, '${plan.interiorAngleDeg(i).toStringAsFixed(0)}°', at,
          size: 9, color: quiet);
    }
  }

  void _drawDimension(Canvas canvas, int i, double wallPx) {
    final a = _p(plan.wallStart(i)), b = _p(plan.wallEnd(i));
    final n = _d(plan.outwardNormal(i));
    final off = n * (wallPx / 2 + 14);
    final da = a + off, db = b + off;
    final highlighted = i == highlightWall;
    final p = Paint()
      ..color = highlighted ? accent : quiet
      ..strokeWidth = 1;
    canvas.drawLine(da, db, p);
    final tick = n * 5;
    canvas.drawLine(da - tick, da + tick, p);
    canvas.drawLine(db - tick, db + tick, p);

    // Length label, rotated along the wall and kept upright
    var ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
    if (ang > math.pi / 2) ang -= math.pi;
    if (ang < -math.pi / 2) ang += math.pi;
    final mid = (da + db) / 2 + n * 11;
    canvas.save();
    canvas.translate(mid.dx, mid.dy);
    canvas.rotate(ang);
    _text(canvas, formatLength(plan.wallLength(i), unit), Offset.zero,
        size: 12,
        weight: FontWeight.w600,
        color: highlighted ? accent : ink,
        background: true);
    canvas.restore();

    // Wall number just inside the room
    final inside = (a + b) / 2 - n * (wallPx / 2 + 12);
    _text(canvas, 'W${i + 1}', inside,
        size: 10, color: highlighted ? accent : quiet);
  }

  void _drawHandles(Canvas canvas) {
    final r = 9 / zoom;
    for (var i = 0; i < plan.wallCount; i++) {
      final c = _p(plan.corners[i]);
      final on = i == highlightCorner;
      canvas.drawCircle(c, r + 2 / zoom, Paint()..color = paper);
      canvas.drawCircle(c, r, Paint()..color = on ? accent : ink);
      canvas.drawCircle(c, r * 0.4, Paint()..color = paper);
    }
  }

  void _drawScaleBar(Canvas canvas, Size size) {
    final metres = unit.isMetric ? 1.0 : 0.9144; // 1 m or 3 ft
    final label = unit.isMetric ? '1 m' : '3 ft';
    final len = metres * _l.scale;
    final y = size.height - 20, x = 20.0;
    final p = Paint()
      ..color = ink
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, y), Offset(x + len, y), p);
    canvas.drawLine(Offset(x, y - 5), Offset(x, y + 5), p);
    canvas.drawLine(Offset(x + len, y - 5), Offset(x + len, y + 5), p);
    _text(canvas, label, Offset(x + len + 18, y), size: 11, color: quiet);
  }

  void _text(Canvas canvas, String s, Offset centre,
      {double size = 12,
      FontWeight weight = FontWeight.w400,
      Color color = ink,
      bool background = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              fontFamily: 'Inter',
              fontSize: size,
              fontWeight: weight,
              color: color,
              // Measurements line up with figures of equal width.
              fontFeatures: const [FontFeature.tabularFigures()])),
      textDirection: TextDirection.ltr,
    )..layout();
    final topLeft = centre - Offset(tp.width / 2, tp.height / 2);
    if (background) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              (topLeft - const Offset(3, 1)) &
                  Size(tp.width + 6, tp.height + 2),
              const Radius.circular(3)),
          Paint()..color = paper);
    }
    tp.paint(canvas, topLeft);
  }

  @override
  bool shouldRepaint(PlanPainter old) =>
      old.plan != plan ||
      old.unit != unit ||
      old.highlightWall != highlightWall ||
      old.highlightCorner != highlightCorner ||
      old.title != title ||
      old.layout != layout ||
      old.editing != editing ||
      old.handles != handles ||
      old.highlightLine != highlightLine ||
      old.zoom != zoom;
}

/// A small outline of a room for lists.
class PlanThumbnailPainter extends CustomPainter {
  PlanThumbnailPainter(this.plan, {required this.fill, required this.stroke});

  final FloorPlan? plan;
  final Color fill, stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final p = plan;
    if (p == null) return;
    final l = PlanLayout.fit(p, size, pad: 8);
    final path = Path()
      ..addPolygon([for (final c in p.corners) l.toScreen(c)], true);
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
        path,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(PlanThumbnailPainter old) =>
      old.plan != plan || old.fill != fill || old.stroke != stroke;
}
