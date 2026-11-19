import 'dart:math' as math;

import 'geometry.dart';
import 'models.dart';

/// A point in the camera scanner's world space, in metres (y up).
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x, y, z;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(dot(this));
  Vec3 get normalized {
    final l = length;
    return l == 0 ? this : this * (1 / l);
  }

  /// Seen from above: the point on the floor plan.
  Vec2 get plan => Vec2(x, z);
}

/// Height and sill of a door or window marked in the scanner from its two
/// bottom corners [a], [b] and a point on its top edge at height [topY].
/// Doors stand on the floor; a window's sill is where its bottom corners are.
({double? height, double? sill}) openingHeights(
  OpeningType type,
  Vec3 a,
  Vec3 b, {
  double? topY,
  double? floorY,
  bool baseFromPoints = false,
}) {
  final base = (a.y + b.y) / 2;
  if (type == OpeningType.window) {
    return (
      height: topY == null ? null : topY - base,
      sill: floorY == null ? null : math.max(0.0, base - floorY),
    );
  }
  final bottom = baseFromPoints ? base : (floorY ?? base);
  return (height: topY == null ? null : topY - bottom, sill: null);
}

/// The rectangle through corner [a], the next corner [b] along one edge, and
/// any point [c] on the opposite edge, as a [MeasuredSurface].
///
/// Its kind comes from how it lies: flat surfaces at floor level are floor
/// areas, higher ones worktops or shelves; upright ones are wall surfaces.
MeasuredSurface surfaceFromPoints(
  Vec3 a,
  Vec3 b,
  Vec3 c, {
  required String name,
  double? floorY,
}) {
  final ab = b - a;
  final width = ab.length;
  final u = ab.normalized;
  final ac = c - a;
  // The part of a→c across the edge a→b: the rectangle's other side.
  final h = ac - u * ac.dot(u);
  final height = h.length;
  final n = u.cross(h.normalized);
  final corners = [a, b, b + h, a + h];

  final ny = n.y.abs();
  if (ny > 0.9) {
    final y = corners.map((p) => p.y).reduce((s, v) => s + v) / 4;
    final above = floorY == null ? null : y - floorY;
    final onFloor = above != null && above < 0.1;
    return MeasuredSurface(
      name: name,
      kind: onFloor ? SurfaceKind.floor : SurfaceKind.raised,
      width: width,
      height: height,
      elevation: above == null ? null : math.max(0.0, above),
      footprint: [for (final p in corners) p.plan],
    );
  }
  if (ny < 0.25) {
    // Upright: on the plan it is a stretch of wall, its bottom edge. The
    // edges may have been marked in any order, so width is that bottom
    // edge's length and height the other side.
    // Edges 0 and 2 run along a→b (length width), edges 1 and 3 along h.
    var lowest = 0;
    double edgeY(int i) => corners[i].y + corners[(i + 1) % 4].y;
    for (var i = 1; i < 4; i++) {
      if (edgeY(i) < edgeY(lowest) - 1e-6) lowest = i;
    }
    final e0 = corners[lowest], e1 = corners[(lowest + 1) % 4];
    final along = lowest.isEven;
    final bottom = math.min(e0.y, e1.y);
    return MeasuredSurface(
      name: name,
      kind: SurfaceKind.wall,
      width: along ? width : height,
      height: along ? height : width,
      elevation: floorY == null ? null : math.max(0.0, bottom - floorY),
      footprint: [e0.plan, e1.plan],
    );
  }
  return MeasuredSurface(
    name: name,
    kind: SurfaceKind.sloped,
    width: width,
    height: height,
    footprint: [for (final p in corners) p.plan],
  );
}

/// The straight-line distance between two marked points, with its
/// horizontal and vertical parts.
MeasuredLine lineFromPoints(Vec3 a, Vec3 b,
    {required String name, DateTime? at, bool estimated = false}) {
  final d = b - a;
  return MeasuredLine(
    name: name,
    length: d.length,
    run: math.sqrt(d.x * d.x + d.z * d.z),
    rise: d.y.abs(),
    footprint: [a.plan, b.plan],
    measuredAt: at,
    estimated: estimated,
  );
}
