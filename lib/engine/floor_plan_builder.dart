import 'dart:math' as math;

import 'geometry.dart';
import 'models.dart';

class PlanException implements Exception {
  PlanException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A closed floor plan built from a [RoomScan].
class FloorPlan {
  FloorPlan({
    required this.corners,
    required this.openings,
    required this.height,
    required this.warnings,
    required this.snappedWalls,
    this.surfaces = const [],
    this.lines = const [],
  });

  /// Corner i is where wall i starts; wall i runs to corner i+1.
  final List<Vec2> corners;
  final List<Opening> openings;

  /// The scan's measured surfaces, with footprints in plan coordinates.
  final List<MeasuredSurface> surfaces;

  /// The scan's point-to-point distances, with ends in plan coordinates.
  final List<MeasuredLine> lines;
  final double? height;
  final List<String> warnings;

  /// How many walls were snapped to a right angle.
  final int snappedWalls;

  int get wallCount => corners.length;

  Vec2 wallStart(int i) => corners[i];
  Vec2 wallEnd(int i) => corners[(i + 1) % corners.length];
  double wallLength(int i) => wallStart(i).distanceTo(wallEnd(i));
  List<double> get wallLengths =>
      [for (var i = 0; i < wallCount; i++) wallLength(i)];

  double get area => signedArea(corners).abs();
  double get perimeter => wallLengths.fold(0.0, (a, b) => a + b);

  /// Overall size along the longest wall (width) and across it (depth).
  /// The plan is built with the longest wall horizontal and starting at
  /// (0, 0), so this is the bounding box.
  ({double width, double depth}) get overallSize {
    var maxX = 0.0, maxY = 0.0;
    for (final c in corners) {
      maxX = math.max(maxX, c.x);
      maxY = math.max(maxY, c.y);
    }
    return maxX >= maxY
        ? (width: maxX, depth: maxY)
        : (width: maxY, depth: maxX);
  }

  /// Floor area times ceiling height, when the height is known.
  double? get volume => height == null ? null : area * height!;

  /// Total wall surface without subtracting doors and windows.
  double? get grossWallArea => height == null ? null : perimeter * height!;

  /// Surface of all doors and windows (typical heights where not measured).
  double get openingsArea => openings
      .where((o) => o.wallIndex < wallCount)
      .fold(0.0, (s, o) => s + o.width * (o.height ?? o.type.typicalHeight));

  /// Paintable wall surface: gross wall area minus doors and windows.
  double? get netWallArea {
    final g = grossWallArea;
    return g == null ? null : math.max(0.0, g - openingsArea);
  }

  /// Start and end of opening [o] in plan coordinates, clamped to its wall.
  (Vec2, Vec2)? openingSpan(Opening o) {
    if (o.wallIndex >= wallCount) return null;
    final a = wallStart(o.wallIndex), b = wallEnd(o.wallIndex);
    final len = a.distanceTo(b);
    if (len <= 0) return null;
    final dir = (b - a).normalized;
    final half = math.min(o.width, len) / 2;
    final mid = (o.center * len).clamp(half, len - half);
    return (a + dir * (mid - half), a + dir * (mid + half));
  }

  /// True when corners run counter-clockwise (y up). Used to find the
  /// outside of each wall.
  bool get isCounterClockwise => signedArea(corners) > 0;

  /// Unit normal pointing out of the room for wall i.
  Vec2 outwardNormal(int i) {
    final d = (wallEnd(i) - wallStart(i)).normalized;
    // For a CCW polygon the interior is on the left (perp), so outward is
    // the right side.
    return isCounterClockwise ? d.perp * -1 : d.perp;
  }

  /// Interior angle at corner i, in degrees.
  double interiorAngleDeg(int i) {
    final n = wallCount;
    final prev = corners[(i - 1 + n) % n], cur = corners[i];
    final next = corners[(i + 1) % n];
    final a = (prev - cur).angle, b = (next - cur).angle;
    var deg = radToDeg(wrapAngle(b - a)).abs();
    // Reflex corners (L-shaped rooms): the turn direction disagrees with the
    // polygon's orientation.
    final turn = (cur - prev).cross(next - cur);
    final convex = isCounterClockwise ? turn > 0 : turn < 0;
    if (!convex) deg = 360 - deg;
    return deg;
  }
}

/// Turns ordered wall lines into a closed floor plan.
///
/// Steps: snap near-right angles to square (optional), intersect each pair
/// of neighbouring walls to get the corners, apply the user's scale
/// correction, then compute lengths and area.
class FloorPlanBuilder {
  const FloorPlanBuilder({
    this.squareCorners = true,
    this.snapToleranceDeg = 3,
  });

  final bool squareCorners;
  final double snapToleranceDeg;

  FloorPlan build(RoomScan scan) {
    final walls = scan.walls;
    final n = walls.length;
    if (n < 3) {
      throw PlanException('A room needs at least 3 walls (got $n).');
    }
    for (var i = 0; i < n; i++) {
      if (walls[i].length < 0.05) {
        throw PlanException(
            'Wall ${i + 1} is too short to give a direction. Measure it again.');
      }
    }
    final warnings = <String>[];

    // 1. Reference direction = the longest wall (the most reliable one).
    var ref = 0;
    for (var i = 1; i < n; i++) {
      if (walls[i].length > walls[ref].length) ref = i;
    }
    final refAngle = walls[ref].dir.angle;

    // 2. Wall directions, optionally snapped to multiples of 90 degrees
    //    relative to the reference wall.
    final tol = degToRad(snapToleranceDeg);
    var snapped = 0;
    final angles = <double>[];
    for (final w in walls) {
      var a = w.dir.angle;
      if (squareCorners) {
        final diff = wrapAngle(a - refAngle);
        final k = (diff / (math.pi / 2)).round();
        final off = diff - k * math.pi / 2;
        if (off.abs() <= tol) {
          if (off.abs() > 1e-9) snapped++;
          a = refAngle + k * math.pi / 2;
        }
      }
      angles.add(a);
    }

    // 3. Rotate so the reference wall is horizontal (unless the user has
    //    edited the plan, which is then already aligned), then build each
    //    wall's infinite line through its measured midpoint.
    final rot = scan.keepOrientation ? 0.0 : refAngle;
    final lines = <Line2>[
      for (var i = 0; i < n; i++)
        Line2(walls[i].mid.rotate(-rot), Vec2.fromAngle(angles[i] - rot)),
    ];

    // 4. Corner i = intersection of wall i-1 and wall i.
    final corners = <Vec2>[];
    for (var i = 0; i < n; i++) {
      final prev = lines[(i - 1 + n) % n], cur = lines[i];
      final p = prev.intersect(cur);
      if (p != null) {
        corners.add(p);
      } else {
        final prevEnd = walls[(i - 1 + n) % n].b.rotate(-rot);
        final curStart = walls[i].a.rotate(-rot);
        corners.add((prevEnd + curStart) / 2);
        // Walls that already share their corner (e.g. a split wall) are
        // exact; only warn when the corner had to be guessed.
        if (prevEnd.distanceTo(curStart) > 0.02) {
          warnings.add('Walls $i and ${i + 1} are almost parallel, so their '
              'corner is estimated. Add the short wall between them.');
        }
      }
    }

    // 5. Scale correction, then move the plan so it starts at (0, 0).
    final scaled = [for (final c in corners) c * scan.scale];
    var minX = double.infinity, minY = double.infinity;
    for (final c in scaled) {
      minX = math.min(minX, c.x);
      minY = math.min(minY, c.y);
    }
    final shifted = [for (final c in scaled) c - Vec2(minX, minY)];

    // Measured surfaces go through the same rotation, scale and shift.
    final shift = Vec2(minX, minY);
    Vec2 toPlan(Vec2 p) => p.rotate(-rot) * scan.scale - shift;
    final plan = FloorPlan(
      corners: shifted,
      openings: List.of(scan.openings),
      height: scan.height,
      warnings: warnings,
      snappedWalls: snapped,
      surfaces: [
        for (final s in scan.surfaces)
          s.copyWith(footprint: [for (final p in s.footprint) toPlan(p)]),
      ],
      lines: [
        for (final l in scan.lines)
          l.copyWith(footprint: [for (final p in l.footprint) toPlan(p)]),
      ],
    );

    // 6. Sanity checks that point at a wrong wall order or a mis-tap.
    for (var i = 0; i < n; i++) {
      final built = plan.wallLength(i);
      final measured = walls[i].length * scan.scale;
      if (built < 0.05) {
        warnings.add('Wall ${i + 1} ends up with no length. Check the order '
            'the walls were measured in.');
      } else if (built + 0.25 < measured * 0.8) {
        warnings.add('Wall ${i + 1} came out shorter than the stretch you '
            'tapped on it. Check its neighbours.');
      }
    }
    if (_selfIntersects(shifted)) {
      warnings.add('The outline crosses itself. The walls were probably not '
          'measured in order around the room.');
    }
    return plan;
  }

  /// The scale that makes wall [wallIndex] exactly [trueLength] metres.
  static double scaleForTrueLength(
      RoomScan scan, FloorPlan plan, int wallIndex, double trueLength) {
    final current = plan.wallLength(wallIndex);
    if (current <= 0) return scan.scale;
    return scan.scale * trueLength / current;
  }

  static bool _selfIntersects(List<Vec2> pts) {
    final n = pts.length;
    if (n < 4) return false;
    bool cross(Vec2 a, Vec2 b, Vec2 c, Vec2 d) {
      final d1 = (b - a).cross(c - a), d2 = (b - a).cross(d - a);
      final d3 = (d - c).cross(a - c), d4 = (d - c).cross(b - c);
      return (d1 * d2 < 0) && (d3 * d4 < 0);
    }

    for (var i = 0; i < n; i++) {
      for (var j = i + 2; j < n; j++) {
        if (i == 0 && j == n - 1) continue; // neighbours share a corner
        if (cross(pts[i], pts[(i + 1) % n], pts[j], pts[(j + 1) % n])) {
          return true;
        }
      }
    }
    return false;
  }
}

/// Puts unordered wall segments (as RoomPlan returns them) in order around
/// the room by chaining nearest endpoints.
List<WallLine> orderWalls(List<WallLine> walls) {
  if (walls.length < 3) return List.of(walls);
  final remaining = List.of(walls);
  final ordered = <WallLine>[remaining.removeAt(0)];
  while (remaining.isNotEmpty) {
    final end = ordered.last.b;
    var best = 0;
    var bestDist = double.infinity;
    var flip = false;
    for (var i = 0; i < remaining.length; i++) {
      final da = remaining[i].a.distanceTo(end);
      final db = remaining[i].b.distanceTo(end);
      if (da < bestDist) {
        bestDist = da;
        best = i;
        flip = false;
      }
      if (db < bestDist) {
        bestDist = db;
        best = i;
        flip = true;
      }
    }
    final w = remaining.removeAt(best);
    ordered.add(flip ? w.reversed() : w);
  }
  return ordered;
}

/// Finds the wall nearest to [point] and where along it the point sits
/// (0 = wall start, 1 = wall end).
({int wallIndex, double t}) locateOnWalls(List<WallLine> walls, Vec2 point) {
  var best = 0;
  var bestDist = double.infinity;
  var bestT = 0.5;
  for (var i = 0; i < walls.length; i++) {
    final w = walls[i];
    final len = w.length;
    if (len == 0) continue;
    final t = ((point - w.a).dot(w.b - w.a) / (len * len)).clamp(0.0, 1.0);
    final d = point.distanceTo(w.a + (w.b - w.a) * t);
    if (d < bestDist) {
      bestDist = d;
      best = i;
      bestT = t;
    }
  }
  return (wallIndex: best, t: bestT);
}

/// Builds walls from lengths and turn angles, walking around the room.
/// A turn of 90 means a left turn of 90 degrees at the end of that wall.
List<WallLine> wallsFromLengths(List<double> lengths, List<double> turnsDeg) {
  var p = Vec2.zero;
  var heading = 0.0;
  final walls = <WallLine>[];
  for (var i = 0; i < lengths.length; i++) {
    final q = p + Vec2.fromAngle(heading) * lengths[i];
    walls.add(WallLine(p, q));
    p = q;
    heading += degToRad(i < turnsDeg.length ? turnsDeg[i] : 90);
  }
  return walls;
}

/// True when [walls], in order around the room, close into a full outline:
/// each wall ends where the next one starts (within [gap] metres, the
/// accuracy of a scan), there are at least 3 walls and the room has a
/// usable floor area. Used to tell when a room has been scanned completely.
bool isClosedOutline(List<WallLine> walls,
    {double gap = 0.35, double minArea = 2.0}) {
  final n = walls.length;
  if (n < 3) return false;
  for (var i = 0; i < n; i++) {
    if (walls[i].b.distanceTo(walls[(i + 1) % n].a) > gap) return false;
  }
  return signedArea([for (final w in walls) w.a]).abs() >= minArea;
}
