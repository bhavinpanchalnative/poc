import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/floor_map.dart';
import '../engine/geometry.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import 'plan_painter.dart';

/// Maps floor-map coordinates (metres, y up) to canvas pixels (y down).
class MapLayout {
  const MapLayout(this.scale, this.origin, this.min, this.maxY);

  /// Fits [rooms] into [size].
  factory MapLayout.fit(List<PlacedRoom> rooms, Size size,
      {double pad = 56, double top = 0}) {
    final b = mapBounds(rooms) ?? (Vec2.zero, const Vec2(4, 3));
    final w = math.max(b.$2.x - b.$1.x, 1.0), h = math.max(b.$2.y - b.$1.y, 1.0);
    final availW = math.max(10.0, size.width - 2 * pad);
    final availH = math.max(10.0, size.height - 2 * pad - top);
    final s = math.min(availW / w, availH / h);
    return MapLayout(
      s,
      Offset(pad + (availW - w * s) / 2, pad + top + (availH - h * s) / 2),
      b.$1,
      b.$2.y,
    );
  }

  final double scale;
  final Offset origin;
  final Vec2 min;
  final double maxY;

  Offset toScreen(Vec2 v) =>
      Offset(origin.dx + (v.x - min.x) * scale, origin.dy + (maxY - v.y) * scale);

  Vec2 toMap(Offset p) =>
      Vec2((p.dx - origin.dx) / scale + min.x, maxY - (p.dy - origin.dy) / scale);
}

/// Draws the rooms of a floor map: each room's walls, doors and windows,
/// its name and area, and optionally every wall's length.
class FloorMapPainter extends CustomPainter {
  FloorMapPainter({
    required this.rooms,
    required this.unit,
    this.selected,
    this.layout,
    this.dimensions = true,
    this.title,
  });

  final List<PlacedRoom> rooms;
  final LengthUnit unit;
  final int? selected;

  /// Fixed layout (used while dragging); fitted to the size if null.
  final MapLayout? layout;
  final bool dimensions;
  final String? title;

  static const roomFills = [
    Color(0xFFEFF4FD),
    Color(0xFFF0FDF4),
    Color(0xFFFFF7ED),
    Color(0xFFFDF2F8),
    Color(0xFFF5F3FF),
    Color(0xFFECFEFF),
  ];

  late MapLayout _l;

  Offset _p(Vec2 v) => _l.toScreen(v);
  Offset _d(Vec2 v) => Offset(v.x, -v.y);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = PlanPainter.paper);
    _l = layout ?? MapLayout.fit(rooms, size, top: title != null ? 36 : 0);
    if (title != null) {
      _text(canvas, title!, Offset(size.width / 2, 28),
          size: 16, weight: FontWeight.w600);
    }
    final wallPx = math.max(3.0, 0.12 * _l.scale);

    for (var k = 0; k < rooms.length; k++) {
      final r = rooms[k];
      final path = Path()..addPolygon([for (final c in r.corners) _p(c)], true);
      canvas.drawPath(path, Paint()..color = roomFills[k % roomFills.length]);
    }
    for (var k = 0; k < rooms.length; k++) {
      final r = rooms[k];
      final path = Path()..addPolygon([for (final c in r.corners) _p(c)], true);
      canvas.drawPath(
          path,
          Paint()
            ..color = k == selected ? PlanPainter.accent : PlanPainter.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = k == selected ? wallPx + 2 : wallPx
            ..strokeJoin = StrokeJoin.miter);
      for (final o in r.plan.openings) {
        _drawOpening(canvas, r, o, wallPx);
      }
      if (dimensions) {
        for (var i = 0; i < r.plan.wallCount; i++) {
          _drawLength(canvas, r, i, wallPx);
        }
      }
    }
    // Names last, so walls of neighbouring rooms don't cover them.
    for (var k = 0; k < rooms.length; k++) {
      final r = rooms[k];
      final c = _p(polygonCentroid(r.corners));
      _text(canvas, r.scan.name, c - const Offset(0, 9),
          size: 13, weight: FontWeight.w700, background: true);
      _text(canvas, formatArea(r.plan.area, unit), c + const Offset(0, 9),
          size: 11, color: PlanPainter.quiet, background: true);
    }
    _drawScaleBar(canvas, size);
  }

  void _drawOpening(Canvas canvas, PlacedRoom r, Opening o, double wallPx) {
    final span = r.plan.openingSpan(o);
    if (span == null) return;
    final s = r.toMap(span.$1), e = r.toMap(span.$2);
    canvas.drawLine(
        _p(s),
        _p(e),
        Paint()
          ..color = PlanPainter.paper
          ..strokeWidth = wallPx + 1);
    final inward = r.dirToMap(r.plan.outwardNormal(o.wallIndex) * -1);
    final thin = Paint()
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    switch (o.type) {
      case OpeningType.door:
        final width = s.distanceTo(e);
        final leaf = s + inward * width;
        canvas.drawLine(_p(s), _p(leaf), thin..color = PlanPainter.doorColor);
        final a0 = math.atan2(_d(inward).dy, _d(inward).dx);
        final dir = (e - s).normalized;
        var sweep = math.atan2(_d(dir).dy, _d(dir).dx) - a0;
        if (sweep > math.pi) sweep -= 2 * math.pi;
        if (sweep < -math.pi) sweep += 2 * math.pi;
        canvas.drawArc(Rect.fromCircle(center: _p(s), radius: width * _l.scale),
            a0, sweep, false, thin..color = PlanPainter.doorColor.withValues(alpha: 0.6));
      case OpeningType.window:
        canvas.drawLine(_p(s), _p(e), thin..color = PlanPainter.windowColor);
        final off = _d(inward) * (wallPx / 2);
        canvas.drawLine(_p(s) + off, _p(e) + off, thin);
        canvas.drawLine(_p(s) - off, _p(e) - off, thin);
      case OpeningType.opening:
        break;
    }
  }

  void _drawLength(Canvas canvas, PlacedRoom r, int i, double wallPx) {
    final a = r.toMap(r.plan.wallStart(i)), b = r.toMap(r.plan.wallEnd(i));
    final pa = _p(a), pb = _p(b);
    if ((pb - pa).distance < 36) return; // too short to label legibly
    final inward = _d(r.dirToMap(r.plan.outwardNormal(i) * -1));
    var ang = math.atan2(pb.dy - pa.dy, pb.dx - pa.dx);
    if (ang > math.pi / 2) ang -= math.pi;
    if (ang < -math.pi / 2) ang += math.pi;
    // Inside the room, so shared walls show each room's own length.
    final mid = (pa + pb) / 2 + inward * (wallPx / 2 + 9);
    canvas.save();
    canvas.translate(mid.dx, mid.dy);
    canvas.rotate(ang);
    _text(canvas, formatLength(r.plan.wallLength(i), unit), Offset.zero,
        size: 10, color: PlanPainter.quiet);
    canvas.restore();
  }

  void _drawScaleBar(Canvas canvas, Size size) {
    final metres = unit.isMetric ? 1.0 : 0.9144;
    final label = unit.isMetric ? '1 m' : '3 ft';
    final len = metres * _l.scale;
    final y = size.height - 20, x = 20.0;
    final p = Paint()
      ..color = PlanPainter.ink
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, y), Offset(x + len, y), p);
    canvas.drawLine(Offset(x, y - 5), Offset(x, y + 5), p);
    canvas.drawLine(Offset(x + len, y - 5), Offset(x + len, y + 5), p);
    _text(canvas, label, Offset(x + len + 18, y),
        size: 11, color: PlanPainter.quiet);
  }

  void _text(Canvas canvas, String s, Offset centre,
      {double size = 12,
      FontWeight weight = FontWeight.w400,
      Color color = PlanPainter.ink,
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
              (topLeft - const Offset(3, 1)) & Size(tp.width + 6, tp.height + 2),
              const Radius.circular(3)),
          Paint()..color = PlanPainter.paper.withValues(alpha: 0.85));
    }
    tp.paint(canvas, topLeft);
  }

  @override
  bool shouldRepaint(FloorMapPainter old) => true;
}

/// A small outline of a floor map for lists.
class MapThumbnailPainter extends CustomPainter {
  MapThumbnailPainter(this.rooms, {required this.fill, required this.stroke});

  final List<PlacedRoom> rooms;
  final Color fill, stroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (rooms.isEmpty) return;
    final l = MapLayout.fit(rooms, size, pad: 8);
    for (final r in rooms) {
      final path = Path()
        ..addPolygon([for (final c in r.corners) l.toScreen(c)], true);
      canvas.drawPath(path, Paint()..color = fill);
      canvas.drawPath(
          path,
          Paint()
            ..color = stroke
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(MapThumbnailPainter old) => true;
}
