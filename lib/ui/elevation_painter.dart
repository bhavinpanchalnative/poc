import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/elevation.dart';
import '../engine/units.dart';
import 'plan_painter.dart';

/// Maps wall coordinates (metres: x along the wall from its start corner,
/// y up from the floor) to canvas pixels.
class ElevationLayout {
  ElevationLayout(this.e, Size size, {double top = 0})
      : scale = math.min(
          (size.width - _padL - _padR) / math.max(e.wallLength, 0.5),
          (size.height - _padT - _padB - top) / math.max(e.wallHeight, 0.5),
        ) {
    final w = e.wallLength * scale, h = e.wallHeight * scale;
    origin = Offset(
      _padL + (size.width - _padL - _padR - w) / 2,
      _padT + top + (size.height - _padT - _padB - top - h) / 2 + h,
    );
  }

  // Room for the dimension lines around the wall.
  static const _padL = 64.0, _padR = 72.0, _padT = 36.0, _padB = 76.0;

  final OpeningElevation e;
  final double scale;

  /// Canvas position of the wall's start corner at floor level.
  late final Offset origin;

  Offset toScreen(double x, double y) =>
      Offset(origin.dx + x * scale, origin.dy - y * scale);

  double toWallX(double px) => (px - origin.dx) / scale;
  double toWallY(double py) => (origin.dy - py) / scale;

  /// Canvas position of the drag handle in the middle of [edge].
  Offset handle(OpeningEdge edge) => switch (edge) {
        OpeningEdge.left => toScreen(e.left, e.sill + e.height / 2),
        OpeningEdge.right => toScreen(e.right, e.sill + e.height / 2),
        OpeningEdge.top => toScreen(e.left + e.width / 2, e.head),
        OpeningEdge.bottom => toScreen(e.left + e.width / 2, e.sill),
      };

  /// The edges that can be dragged (a door's bottom is the floor).
  List<OpeningEdge> get edges => [
        OpeningEdge.left,
        OpeningEdge.right,
        OpeningEdge.top,
        if (e.isWindow) OpeningEdge.bottom,
      ];
}

/// A door or window drawn from the front on its wall, with every dimension:
/// width, height, sill height, head height, and the distances to both wall
/// corners. Uses fixed light colours so exports look the same in light and
/// dark mode. Values that were not measured are prefixed with "≈" and drawn
/// in grey.
class ElevationPainter extends CustomPainter {
  ElevationPainter({
    required this.e,
    required this.unit,
    this.title,
    this.editing = false,
    this.activeEdge,
  });

  final OpeningElevation e;
  final LengthUnit unit;
  final String? title;
  final bool editing;
  final OpeningEdge? activeEdge;

  static const ink = PlanPainter.ink;
  static const quiet = PlanPainter.quiet;
  static const wallFill = Color(0xFFEEF1F7);
  static const glass = Color(0xFFD6EFFC);
  static const accent = PlanPainter.accent;

  late ElevationLayout _l;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = PlanPainter.paper);
    _l = ElevationLayout(e, size, top: title != null ? 28 : 0);
    if (title != null) {
      _text(canvas, title!, Offset(size.width / 2, 22),
          size: 15, weight: FontWeight.w600);
    }

    // Wall face, floor and ceiling lines.
    final wall = Rect.fromPoints(
        _l.toScreen(0, 0), _l.toScreen(e.wallLength, e.wallHeight));
    canvas.drawRect(wall, Paint()..color = wallFill);
    final edge = Paint()
      ..color = ink
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    // Without a room the wall is only a backdrop: no corners. No ceiling
    // height is measured, so no ceiling line either.
    if (!e.standalone) {
      canvas.drawLine(wall.topLeft, wall.bottomLeft, edge);
      canvas.drawLine(wall.topRight, wall.bottomRight, edge);
    }
    canvas.drawLine(wall.bottomLeft - const Offset(12, 0),
        wall.bottomRight + const Offset(12, 0), edge..strokeWidth = 3);

    _drawOpening(canvas);
    _drawDimensions(canvas, wall);
    if (editing) _drawHandles(canvas);
  }

  void _drawOpening(Canvas canvas) {
    final r = Rect.fromPoints(
        _l.toScreen(e.left, e.sill), _l.toScreen(e.right, e.head));
    final frame = Paint()
      ..color = ink
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final thin = Paint()
      ..color = ink
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    if (e.isWindow) {
      canvas.drawRect(r, Paint()..color = glass);
      canvas.drawRect(r, frame);
      final inset = r.deflate(math.min(6, r.shortestSide / 8));
      canvas.drawRect(inset, thin);
      // Two casements.
      canvas.drawLine(Offset(r.center.dx, inset.top),
          Offset(r.center.dx, inset.bottom), thin);
      // Sill.
      canvas.drawLine(r.bottomLeft + const Offset(-6, 2),
          r.bottomRight + const Offset(6, 2), frame..strokeWidth = 3);
    } else {
      canvas.drawRect(r, Paint()..color = PlanPainter.paper);
      canvas.drawRect(r, frame);
      // Door leaf with its panels and handle.
      final leaf = r.deflate(math.min(5, r.shortestSide / 10));
      canvas.drawRect(leaf, thin);
      final p = leaf.deflate(leaf.width * 0.16);
      canvas.drawRect(
          Rect.fromLTRB(p.left, p.top, p.right, p.top + p.height * 0.42), thin);
      canvas.drawRect(
          Rect.fromLTRB(p.left, p.bottom - p.height * 0.42, p.right, p.bottom),
          thin);
      canvas.drawCircle(
          Offset(leaf.right - leaf.width * 0.12, leaf.center.dy + 4),
          math.max(2.5, leaf.width * 0.03),
          Paint()..color = ink);
    }
  }

  String _len(double m, {bool approx = false}) =>
      '${approx ? '≈ ' : ''}${formatLength(m, unit)}';

  void _drawDimensions(Canvas canvas, Rect wall) {
    final est = e.estimated;
    // Along the floor: corner → opening → corner (only the opening itself
    // when there is no room around it).
    final yRow = wall.bottom + 30;
    if (!e.standalone) _hDim(canvas, 0, e.left, yRow, _len(e.left, approx: est));
    _hDim(canvas, e.left, e.right, yRow, _len(e.width, approx: est),
        strong: true);
    if (!e.standalone) {
      _hDim(canvas, e.right, e.wallLength, yRow, _len(e.rightGap, approx: est));
      // Whole wall below that.
      _hDim(canvas, 0, e.wallLength, yRow + 26, 'Wall ${_len(e.wallLength)}',
          color: quiet);
    }

    // Heights, to the right of the opening.
    final xHeight = _l.toScreen(e.right, 0).dx + 26;
    _vDim(canvas, e.sill, e.head, xHeight,
        _len(e.height, approx: est || e.heightAssumed),
        strong: true, assumed: e.heightAssumed);
    if (e.isWindow) {
      // Sill, and the top of the window above the floor, to the left.
      final xLeft = _l.toScreen(e.left, 0).dx - 26;
      _vDim(canvas, 0, e.sill, xLeft,
          'Sill ${_len(e.sill, approx: est || e.sillAssumed)}',
          assumed: e.sillAssumed);
      final xHead = _l.toScreen(e.right, 0).dx + 58;
      _vDim(canvas, 0, e.head, math.min(xHead, wall.right + 50),
          'Top ${_len(e.head, approx: est || e.sillAssumed || e.heightAssumed)}',
          color: quiet);
    }
  }

  /// Horizontal dimension line between wall x0 and x1 at canvas height y.
  void _hDim(Canvas canvas, double x0, double x1, double y, String label,
      {bool strong = false, Color? color}) {
    if ((x1 - x0) * _l.scale < 2) return;
    final c = color ?? (strong ? ink : quiet);
    final a = Offset(_l.toScreen(x0, 0).dx, y), b = Offset(_l.toScreen(x1, 0).dx, y);
    final p = Paint()
      ..color = c
      ..strokeWidth = strong ? 1.4 : 1;
    canvas.drawLine(a, b, p);
    for (final q in [a, b]) {
      canvas.drawLine(q + const Offset(-4, 4), q + const Offset(4, -4), p);
      canvas.drawLine(q + const Offset(0, -18), q + const Offset(0, 6),
          p..strokeWidth = 0.6);
      p.strokeWidth = strong ? 1.4 : 1;
    }
    _text(canvas, label, Offset((a.dx + b.dx) / 2, y - 9),
        size: strong ? 12 : 10,
        weight: strong ? FontWeight.w700 : FontWeight.w400,
        color: c,
        background: true);
  }

  /// Vertical dimension line between heights y0 and y1 at canvas x.
  void _vDim(Canvas canvas, double y0, double y1, double x, String label,
      {bool strong = false, bool assumed = false, Color? color}) {
    if ((y1 - y0) * _l.scale < 2) return;
    final c = color ?? (assumed ? quiet : (strong ? ink : quiet));
    final a = Offset(x, _l.toScreen(0, y0).dy), b = Offset(x, _l.toScreen(0, y1).dy);
    final p = Paint()
      ..color = c
      ..strokeWidth = strong ? 1.4 : 1;
    canvas.drawLine(a, b, p);
    for (final q in [a, b]) {
      canvas.drawLine(q + const Offset(-4, 4), q + const Offset(4, -4), p);
    }
    canvas.save();
    canvas.translate(x + 9, (a.dy + b.dy) / 2);
    canvas.rotate(-math.pi / 2);
    _text(canvas, label, Offset.zero,
        size: strong ? 12 : 10,
        weight: strong ? FontWeight.w700 : FontWeight.w400,
        color: c,
        background: true);
    canvas.restore();
  }

  void _drawHandles(Canvas canvas) {
    for (final edge in _l.edges) {
      final c = _l.handle(edge);
      final on = edge == activeEdge;
      canvas.drawCircle(c, on ? 13 : 11, Paint()..color = PlanPainter.paper);
      canvas.drawCircle(c, on ? 10 : 8, Paint()..color = on ? accent : ink);
      final arrow = Paint()
        ..color = PlanPainter.paper
        ..strokeWidth = 1.6;
      final horizontal = edge == OpeningEdge.left || edge == OpeningEdge.right;
      final d = horizontal ? const Offset(4, 0) : const Offset(0, 4);
      canvas.drawLine(c - d, c + d, arrow);
    }
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
              (topLeft - const Offset(3, 1)) & Size(tp.width + 6, tp.height + 2),
              const Radius.circular(3)),
          Paint()..color = PlanPainter.paper);
    }
    tp.paint(canvas, topLeft);
  }

  @override
  bool shouldRepaint(ElevationPainter old) =>
      old.e != e ||
      old.unit != unit ||
      old.editing != editing ||
      old.activeEdge != activeEdge ||
      old.title != title;
}
