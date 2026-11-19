import 'dart:math' as math;

import 'floor_plan_builder.dart';
import 'geometry.dart';
import 'models.dart';

/// A room of a [FloorMap] with its plan, placed in map coordinates.
class PlacedRoom {
  PlacedRoom(this.scan, this.plan, this.place);

  final RoomScan scan;
  final FloorPlan plan;
  final MapRoom place;

  /// Centre of the plan's bounding box: rooms turn about it.
  Vec2 get pivot {
    var maxX = 0.0, maxY = 0.0;
    for (final c in plan.corners) {
      maxX = math.max(maxX, c.x);
      maxY = math.max(maxY, c.y);
    }
    return Vec2(maxX / 2, maxY / 2);
  }

  /// A point of the room's plan in map coordinates.
  Vec2 toMap(Vec2 p) {
    final c = pivot;
    return quarterTurn(p - c, place.quarterTurns) + c + place.offset;
  }

  /// A direction of the room's plan in map coordinates.
  Vec2 dirToMap(Vec2 d) => quarterTurn(d, place.quarterTurns);

  List<Vec2> get corners => [for (final c in plan.corners) toMap(c)];

  bool contains(Vec2 p) => pointInPolygon(p, corners);
}

/// [v] turned [turns] times by 90 degrees counter-clockwise.
Vec2 quarterTurn(Vec2 v, int turns) => switch (turns % 4) {
      0 => v,
      1 => Vec2(-v.y, v.x),
      2 => Vec2(-v.x, -v.y),
      _ => Vec2(v.y, -v.x),
    };

bool pointInPolygon(Vec2 p, List<Vec2> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.y > p.y) != (b.y > p.y) &&
        p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

/// The rooms of [map] that still exist, with their plans. Rooms whose scan
/// was deleted or no longer builds are left out.
List<PlacedRoom> placeRooms(FloorMap map, Map<String, RoomScan> scans,
    {FloorPlanBuilder builder = const FloorPlanBuilder()}) {
  final out = <PlacedRoom>[];
  for (final r in map.rooms) {
    final s = scans[r.scanId];
    if (s == null) continue;
    try {
      out.add(PlacedRoom(s, builder.build(s), r));
    } on PlanException {
      continue;
    }
  }
  return out;
}

/// Bounding box of all placed rooms: (min, max), or null for none.
(Vec2, Vec2)? mapBounds(Iterable<PlacedRoom> rooms) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final r in rooms) {
    for (final c in r.corners) {
      minX = math.min(minX, c.x);
      minY = math.min(minY, c.y);
      maxX = math.max(maxX, c.x);
      maxY = math.max(maxY, c.y);
    }
  }
  if (minX == double.infinity) return null;
  return (Vec2(minX, minY), Vec2(maxX, maxY));
}

double totalArea(Iterable<PlacedRoom> rooms) =>
    rooms.fold(0.0, (s, r) => s + r.plan.area);

/// Offset for a new room so it sits [gap] metres to the right of the
/// existing rooms, aligned with their top.
Vec2 offsetForNewRoom(List<PlacedRoom> existing, FloorPlan plan,
    {double gap = 1.0}) {
  final b = mapBounds(existing);
  if (b == null) return Vec2.zero;
  var maxY = 0.0;
  for (final c in plan.corners) {
    maxY = math.max(maxY, c.y);
  }
  return Vec2(b.$2.x + gap, b.$2.y - maxY);
}

/// How far to move a dragged room so it lines up with the others.
///
/// [corners] are the dragged room's corners where the finger put them.
/// A corner within [tolerance] of another room's corner snaps onto it;
/// otherwise each axis snaps separately when a corner is that close to
/// another room's wall line (rooms are drawn with straight walls, so this
/// puts neighbouring rooms wall to wall).
Vec2 snapOffset(List<Vec2> corners, List<List<Vec2>> others,
    {double tolerance = 0.25}) {
  Vec2? best;
  var bestD = tolerance;
  for (final c in corners) {
    for (final room in others) {
      for (final o in room) {
        final d = c.distanceTo(o);
        if (d < bestD) {
          bestD = d;
          best = o - c;
        }
      }
    }
  }
  if (best != null) return best;

  double? dx, dy;
  var bestX = tolerance, bestY = tolerance;
  for (final c in corners) {
    for (final room in others) {
      for (final o in room) {
        final ex = (o.x - c.x).abs(), ey = (o.y - c.y).abs();
        if (ex < bestX) {
          bestX = ex;
          dx = o.x - c.x;
        }
        if (ey < bestY) {
          bestY = ey;
          dy = o.y - c.y;
        }
      }
    }
  }
  return Vec2(dx ?? 0, dy ?? 0);
}
