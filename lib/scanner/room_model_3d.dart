import 'dart:math' as math;

import '../engine/floor_map.dart';
import '../engine/floor_plan_builder.dart';
import '../engine/geometry.dart';
import '../engine/measure3d.dart';
import '../engine/models.dart';

/// What a face of the 3D room model is part of (its colour, its layer in
/// exports, and whether the viewer may hide it).
enum Part3D { floor, wall, door, window, opening, furniture }

/// Ceiling height used when the scanner did not measure one (camera scans,
/// manual entry): 8 ft, the most common.
const defaultCeilingHeight = 2.44;

/// Typical sill of a window whose sill was not measured.
const defaultWindowSill = 0.9;

/// Height of furniture whose height is not known.
const defaultFurnitureHeight = 0.75;

/// One flat, convex-or-not polygon of the model. World coordinates, metres,
/// Y up: a floor-plan point (x, y) is (x, 0, -y), so the model looks the
/// same as the 2D plan from above.
class Face3D {
  Face3D(this.points, this.part, {this.room = 0, this.wall, this.outward})
      : normal = _normal(points);

  final List<Vec3> points;
  final Part3D part;

  /// Index of the room in [RoomModel3D.rooms].
  final int room;

  /// Index of the wall (in its room's plan) that this face belongs to.
  final int? wall;

  /// For wall faces: the horizontal direction out of the room. The viewer
  /// fades walls whose outside faces the camera so the room can be seen
  /// into ("dollhouse" view).
  final Vec3? outward;
  final Vec3 normal;

  Vec3 get centroid {
    var s = const Vec3(0, 0, 0);
    for (final p in points) {
      s = s + p;
    }
    return s * (1 / points.length);
  }

  static Vec3 _normal(List<Vec3> p) {
    // Newell's method: works for any planar polygon, concave included.
    var x = 0.0, y = 0.0, z = 0.0;
    for (var i = 0; i < p.length; i++) {
      final a = p[i], b = p[(i + 1) % p.length];
      x += (a.y - b.y) * (a.z + b.z);
      y += (a.z - b.z) * (a.x + b.x);
      z += (a.x - b.x) * (a.y + b.y);
    }
    return Vec3(x, y, z).normalized;
  }
}

/// A length label in the model: the wall [length] drawn at [at].
class Label3D {
  const Label3D(this.at, this.length, {this.room = 0, this.wall});
  final Vec3 at;
  final double length;
  final int room;
  final int? wall;
}

/// One room going into a model: its scan, its plan, and where the plan sits
/// in the model ([toWorld]: plan point to model floor point; identity for a
/// single room, [PlacedRoom.toMap] on a floor map).
class RoomInput {
  RoomInput(this.scan, this.plan, {Vec2 Function(Vec2)? toWorld})
      : toWorld = toWorld ?? ((p) => p);

  factory RoomInput.placed(PlacedRoom r) =>
      RoomInput(r.scan, r.plan, toWorld: r.toMap);

  final RoomScan scan;
  final FloorPlan plan;
  final Vec2 Function(Vec2) toWorld;

  /// The room's height: measured, or [defaultCeilingHeight].
  double get height => plan.ceilingHeight ?? defaultCeilingHeight;
  bool get heightMeasured => plan.ceilingHeight != null;
}

/// Bottom and top (m above the floor) of opening [o] in a room [h] high.
(double, double) openingVerticalSpan(Opening o, double h) {
  final bottom = o.type == OpeningType.window
      ? (o.sill ?? defaultWindowSill)
      : 0.0;
  final top = bottom + (o.height ?? o.type.typicalHeight);
  final b = bottom.clamp(0.0, h);
  return (b, top.clamp(b, h));
}

/// The scanned rooms as a 3D model: floors, walls with the doors, windows
/// and open gaps cut out of them, the doors and windows as panels, and
/// furniture as boxes. Used by the 3D viewer and the OBJ export.
class RoomModel3D {
  RoomModel3D._(this.rooms, this.faces, this.labels, this.min, this.max);

  final List<RoomInput> rooms;
  final List<Face3D> faces;
  final List<Label3D> labels;

  /// Bounding box of the model.
  final Vec3 min, max;

  Vec3 get center => (min + max) * 0.5;
  double get radius => (max - min).length / 2;

  /// Whether every room's ceiling height was measured.
  bool get heightsMeasured => rooms.every((r) => r.heightMeasured);

  factory RoomModel3D.single(RoomScan scan, FloorPlan plan) =>
      RoomModel3D.build([RoomInput(scan, plan)]);

  factory RoomModel3D.build(List<RoomInput> rooms) {
    final faces = <Face3D>[];
    final labels = <Label3D>[];
    for (var r = 0; r < rooms.length; r++) {
      _addRoom(rooms[r], r, faces, labels);
    }
    var mn = const Vec3(double.infinity, double.infinity, double.infinity);
    var mx = const Vec3(-double.infinity, -double.infinity, -double.infinity);
    for (final f in faces) {
      for (final p in f.points) {
        mn = Vec3(math.min(mn.x, p.x), math.min(mn.y, p.y), math.min(mn.z, p.z));
        mx = Vec3(math.max(mx.x, p.x), math.max(mx.y, p.y), math.max(mx.z, p.z));
      }
    }
    if (faces.isEmpty) {
      mn = const Vec3(0, 0, 0);
      mx = const Vec3(1, 1, 1);
    }
    return RoomModel3D._(rooms, faces, labels, mn, mx);
  }

  /// A model floor point at height [h].
  static Vec3 at(Vec2 p, double h) => Vec3(p.x, h, -p.y);

  static void _addRoom(
      RoomInput room, int r, List<Face3D> faces, List<Label3D> labels) {
    final plan = room.plan;
    final h = room.height;
    final n = plan.wallCount;
    if (n < 3) return;
    final w = room.toWorld;
    // A floor map may turn a room: work out whether it is still
    // counter-clockwise in the model, for the outward normals.
    final worldCorners = [for (final c in plan.corners) w(c)];
    final ccw = signedArea(worldCorners) > 0;

    // Floor, facing up. In the model (x, -y) a counter-clockwise plan polygon
    // seen from above is counter-clockwise too, so its normal points up when
    // listed as is.
    final floor = [for (final c in worldCorners) at(c, 0)];
    faces.add(Face3D(ccw ? floor : floor.reversed.toList(), Part3D.floor, room: r));

    for (var i = 0; i < n; i++) {
      final a = w(plan.wallStart(i)), b = w(plan.wallEnd(i));
      final len = a.distanceTo(b);
      if (len < 1e-6) continue;
      final dir = (b - a) / len;
      final out2 = ccw ? dir.perp * -1 : dir.perp;
      final outward = Vec3(out2.x, 0, -out2.y);
      Vec3 p(double t, double y) => at(a + dir * t, y);
      void quad(double t0, double t1, double y0, double y1, Part3D part) {
        if (t1 - t0 < 1e-4 || y1 - y0 < 1e-4) return;
        faces.add(Face3D([p(t0, y0), p(t1, y0), p(t1, y1), p(t0, y1)], part,
            room: r, wall: i, outward: outward));
      }

      // Openings on this wall, as (start, end) along it, sorted; overlaps
      // are trimmed so the wall pieces never cross.
      final spans = <(double, double, Opening)>[];
      for (final o in plan.openings.where((o) => o.wallIndex == i)) {
        final s = plan.openingSpan(o);
        if (s == null) continue;
        final t0 = (w(s.$1) - a).dot(dir), t1 = (w(s.$2) - a).dot(dir);
        spans.add((math.min(t0, t1).clamp(0, len), math.max(t0, t1).clamp(0, len), o));
      }
      spans.sort((x, y) => x.$1.compareTo(y.$1));

      var t = 0.0;
      for (final (s0, s1, o) in spans) {
        final start = math.max(s0, t);
        if (s1 <= start) continue;
        quad(t, start, 0, h, Part3D.wall);
        final (bottom, top) = openingVerticalSpan(o, h);
        quad(start, s1, 0, bottom, Part3D.wall);
        quad(start, s1, top, h, Part3D.wall);
        final part = switch (o.type) {
          OpeningType.door => Part3D.door,
          OpeningType.window => Part3D.window,
          OpeningType.opening => Part3D.opening,
        };
        quad(start, s1, bottom, top, part);
        t = s1;
      }
      quad(t, len, 0, h, Part3D.wall);
      labels.add(Label3D(p(len / 2, h), plan.wallLength(i), room: r, wall: i));
    }

    // Furniture: boxes on the floor.
    for (final e in room.scan.elements) {
      if (e.position == null || e.width == null || e.depth == null) continue;
      final c = w(plan.toPlan(e.position!));
      final angle = (e.angle ?? 0) - plan.rotation;
      // The direction of its width, through the same placement as the room.
      final ux = (w(plan.toPlan(e.position!) + Vec2.fromAngle(angle)) - c).normalized;
      final uy = ux.perp;
      final hw = e.width! * plan.scale / 2, hd = e.depth! * plan.scale / 2;
      final fh = math.min(e.height ?? defaultFurnitureHeight, h);
      final base = [
        c - ux * hw - uy * hd,
        c + ux * hw - uy * hd,
        c + ux * hw + uy * hd,
        c - ux * hw + uy * hd,
      ];
      faces.add(Face3D([for (final q in base) at(q, fh)], Part3D.furniture, room: r));
      for (var k = 0; k < 4; k++) {
        final q0 = base[k], q1 = base[(k + 1) % 4];
        faces.add(Face3D(
            [at(q0, 0), at(q1, 0), at(q1, fh), at(q0, fh)], Part3D.furniture,
            room: r));
      }
    }
  }
}
