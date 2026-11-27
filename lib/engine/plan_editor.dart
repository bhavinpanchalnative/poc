import 'dart:math' as math;

import 'floor_plan_builder.dart';
import 'geometry.dart';
import 'models.dart';

/// Manual edits to a scan's geometry.
///
/// Every edit starts from the built [FloorPlan] (what the user sees), changes
/// its corners, and writes them back as the scan's walls, so later builds
/// reproduce the edited shape exactly. The scale factor is folded in.
class PlanEditor {
  /// Corners closer than this to a cut line count as being on it.
  static const _eps = 0.005;

  /// Replaces the scan's walls with the closed outline through [corners].
  ///
  /// [corners] are in plan coordinates, which become the scan's coordinates;
  /// [plan] (the plan they were taken from) moves the measured surfaces into
  /// the same coordinates.
  static void applyCorners(RoomScan scan, List<Vec2> corners,
      [FloorPlan? plan]) {
    if (plan != null && plan.surfaces.length == scan.surfaces.length) {
      for (var k = 0; k < scan.surfaces.length; k++) {
        scan.surfaces[k] =
            scan.surfaces[k].copyWith(footprint: plan.surfaces[k].footprint);
      }
    }
    if (plan != null && plan.lines.length == scan.lines.length) {
      for (var k = 0; k < scan.lines.length; k++) {
        scan.lines[k] =
            scan.lines[k].copyWith(footprint: plan.lines[k].footprint);
      }
    }
    // Where photos were taken, and furniture, move into the same coordinates.
    if (plan != null) {
      for (var k = 0; k < scan.photoPins.length; k++) {
        final p = scan.photoPins[k];
        scan.photoPins[k] = p.copyWith(
          position: plan.toPlan(p.position),
          direction: p.direction == null ? null : plan.dirToPlan(p.direction!),
        );
      }
      for (var k = 0; k < scan.elements.length; k++) {
        final e = scan.elements[k];
        final pos = e.position;
        if (pos == null) continue;
        scan.elements[k] = e.copyWith(
            position: plan.toPlan(pos), angle: e.angle == null ? null : e.angle! - plan.rotation);
      }
    }
    final n = corners.length;
    scan.walls
      ..clear()
      ..addAll([
        for (var i = 0; i < n; i++) WallLine(corners[i], corners[(i + 1) % n]),
      ]);
    scan.scale = 1.0;
    scan.keepOrientation = true;
  }

  /// Makes wall [i] exactly [length] metres by stretching the room along
  /// that wall: every corner on one side of the wall's end moves, so all
  /// other walls keep their direction. The side with fewer corners moves.
  static void setWallLength(
      RoomScan scan, FloorPlan plan, int i, double length) {
    final a = plan.wallStart(i), b = plan.wallEnd(i);
    final current = a.distanceTo(b);
    if (current <= 0 || length <= 0) return;
    final d = (b - a).normalized;
    final delta = length - current;
    final pa = a.dot(d), pb = b.dot(d);

    final endSide = <int>{}, startSide = <int>{};
    for (var k = 0; k < plan.wallCount; k++) {
      final p = plan.corners[k].dot(d);
      if (p >= pb - _eps) endSide.add(k);
      if (p <= pa + _eps) startSide.add(k);
    }
    final moveEnd = endSide.length <= startSide.length;
    final moving = moveEnd ? endSide : startSide;
    final shift = d * (moveEnd ? delta : -delta);
    applyCorners(scan, [
      for (var k = 0; k < plan.wallCount; k++)
        moving.contains(k) ? plan.corners[k] + shift : plan.corners[k],
    ], plan);
  }

  /// [line] with its end [end] (0 or 1) moved to [to] (plan coordinates):
  /// the length follows the new distance on the floor plan, keeping the
  /// height difference the line was measured with (its rise, or what its
  /// length had beyond its footprint).
  static MeasuredLine movedLineEnd(MeasuredLine line, int end, Vec2 to) {
    if (line.footprint.length < 2) return line;
    final fp = List.of(line.footprint)..[end] = to;
    final oldRun = line.footprint[0].distanceTo(line.footprint[1]);
    final rise = line.rise ??
        math.sqrt(math.max(0.0, line.length * line.length - oldRun * oldRun));
    final run = fp[0].distanceTo(fp[1]);
    return line.copyWith(
      footprint: fp,
      run: run,
      rise: rise,
      length: math.sqrt(run * run + rise * rise),
    );
  }

  /// Moves end [end] of line [k] to [to] (plan coordinates, metres).
  static void moveLineEnd(
      RoomScan scan, FloorPlan plan, int k, int end, Vec2 to) {
    // The scan in plan coordinates first, so the line's ends are too.
    applyCorners(scan, List.of(plan.corners), plan);
    scan.lines[k] = movedLineEnd(plan.lines[k], end, to);
  }

  /// Moves corner [i] to [to] (plan coordinates, metres).
  static void moveCorner(RoomScan scan, FloorPlan plan, int i, Vec2 to) {
    final cs = List.of(plan.corners);
    cs[i] = to;
    applyCorners(scan, cs, plan);
  }

  /// Splits wall [i] in two by adding a corner at its middle.
  static void splitWall(RoomScan scan, FloorPlan plan, int i) {
    final cs = List.of(plan.corners)
      ..insert(i + 1, (plan.wallStart(i) + plan.wallEnd(i)) / 2);
    _applyKeepingOpenings(scan, plan, cs);
  }

  /// Removes corner [i], joining its two walls. Rooms keep at least 3.
  static bool removeCorner(RoomScan scan, FloorPlan plan, int i) {
    if (plan.wallCount <= 3) return false;
    final cs = List.of(plan.corners)..removeAt(i);
    _applyKeepingOpenings(scan, plan, cs);
    return true;
  }

  /// Applies new corners when walls are added or removed, moving each door
  /// and window to the new wall at the same place on the plan.
  static void _applyKeepingOpenings(
      RoomScan scan, FloorPlan plan, List<Vec2> corners) {
    final positions = [
      for (final o in scan.openings)
        () {
          final span = plan.openingSpan(o);
          return span == null ? null : (span.$1 + span.$2) / 2;
        }(),
    ];
    applyCorners(scan, corners, plan);
    final walls = scan.walls;
    for (var k = 0; k < scan.openings.length; k++) {
      final p = positions[k];
      if (p == null) continue;
      final loc = locateOnWalls(walls, p);
      scan.openings[k] =
          scan.openings[k].copyWith(wallIndex: loc.wallIndex, center: loc.t);
    }
  }
}
