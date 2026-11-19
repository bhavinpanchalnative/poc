import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The Planora mark: a room seen from above (walls with a door and its
/// swing), a teal measuring line with end ticks across the top, and a teal
/// scan point on a corner. Drawn in a unit square so the same drawing makes
/// the in-app logo and every app-icon size.
class PlanoraMarkPainter extends CustomPainter {
  const PlanoraMarkPainter({
    this.background = true,
    this.rounded = true,
    this.inset = 0.0,
    this.lineColor = Colors.white,
  });

  /// Paint the blue-to-navy tile behind the mark.
  final bool background;

  /// Round the tile's corners (app icons that the system masks itself are
  /// drawn square).
  final bool rounded;

  /// Extra margin around the mark, as a fraction of the size (Android
  /// adaptive icons keep the mark inside the middle two thirds).
  final double inset;

  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final r = Offset.zero & Size(s, s);
    if (background) {
      final tile = Paint()..shader = AppTheme.heroGradient.createShader(r);
      if (rounded) {
        canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(s * 0.225)), tile);
      } else {
        canvas.drawRect(r, tile);
      }
      // A soft light from the top-left corner.
      canvas.drawCircle(
        Offset(s * 0.15, s * 0.1),
        s * 0.7,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: 0.16),
            Colors.white.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: Offset(s * 0.15, s * 0.1), radius: s * 0.7)),
      );
    }

    canvas.save();
    // Fit the mark's unit square into the area left by the inset.
    final m = s * inset;
    canvas.translate(m, m);
    final u = s - 2 * m;
    Offset p(double x, double y) => Offset(x * u, y * u + 0.055 * u);

    final wall = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.058 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Walls, with a doorway in the bottom wall.
    final room = Path()
      ..moveTo(p(0.38, 0.76).dx, p(0.38, 0.76).dy)
      ..lineTo(p(0.24, 0.76).dx, p(0.24, 0.76).dy)
      ..lineTo(p(0.24, 0.27).dx, p(0.24, 0.27).dy)
      ..lineTo(p(0.76, 0.27).dx, p(0.76, 0.27).dy)
      ..lineTo(p(0.76, 0.76).dx, p(0.76, 0.76).dy)
      ..lineTo(p(0.56, 0.76).dx, p(0.56, 0.76).dy);
    canvas.drawPath(room, wall);

    // The door leaf and its swing.
    final thin = Paint()
      ..color = lineColor.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.032 * u
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(p(0.38, 0.76), p(0.38, 0.58), thin);
    canvas.drawArc(
      Rect.fromCircle(center: p(0.38, 0.76), radius: 0.18 * u),
      -math.pi / 2,
      math.pi / 2,
      false,
      thin,
    );

    // The measuring line across the top, with end ticks.
    final tape = Paint()
      ..color = AppTheme.scan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.04 * u
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(p(0.24, 0.13), p(0.76, 0.13), tape);
    canvas.drawLine(p(0.24, 0.09), p(0.24, 0.17), tape);
    canvas.drawLine(p(0.76, 0.09), p(0.76, 0.17), tape);

    // The scan point on the far corner.
    canvas.drawCircle(p(0.76, 0.27), 0.056 * u, Paint()..color = AppTheme.scan);
    canvas.drawCircle(p(0.76, 0.27), 0.024 * u, Paint()..color = lineColor);
    canvas.restore();
  }

  @override
  bool shouldRepaint(PlanoraMarkPainter old) =>
      old.background != background ||
      old.rounded != rounded ||
      old.inset != inset ||
      old.lineColor != lineColor;
}

/// The logo: the mark on its tile, optionally with the wordmark.
class PlanoraLogo extends StatelessWidget {
  const PlanoraLogo({super.key, this.size = 36, this.wordmark = true, this.color});

  final double size;
  final bool wordmark;

  /// Wordmark colour (defaults to the text colour).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox.square(
      dimension: size,
      child: const CustomPaint(painter: PlanoraMarkPainter()),
    );
    if (!wordmark) return mark;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      mark,
      SizedBox(width: size * 0.3),
      Text(
        AppTheme.appName,
        style: TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: size * 0.62,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
          color: color ?? Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ]);
  }
}
