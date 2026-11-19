import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/floor_map.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/measure3d.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/engine/plan_editor.dart';

/// A rectangular room [w] x [d] m with the given surfaces, rotated as AR
/// coordinates usually are.
RoomScan room(double w, double d,
    {String id = 'r', List<MeasuredSurface> surfaces = const []}) {
  final corners = [Vec2.zero, Vec2(w, 0), Vec2(w, d), Vec2(0, d)];
  final s = scanFromCorners(corners, name: id, surfaces: surfaces);
  return RoomScan.fromJson({...s.toJson(), 'id': id});
}

void main() {
  const floorY = -1.4;

  group('surfaces measured with three taps', () {
    test('a wall section: width along the floor, height up the wall', () {
      // 1.20 x 0.80 m panel on the wall z = 2, bottom edge 0.9 m up.
      final m = surfaceFromPoints(
        const Vec3(0.5, floorY + 0.9, 2),
        const Vec3(1.7, floorY + 0.9, 2),
        const Vec3(1.1, floorY + 1.7, 2),
        name: 'Panel',
        floorY: floorY,
      );
      expect(m.kind, SurfaceKind.wall);
      expect(m.width, closeTo(1.2, 1e-9));
      expect(m.height, closeTo(0.8, 1e-9));
      expect(m.area, closeTo(0.96, 1e-9));
      expect(m.elevation, closeTo(0.9, 1e-9));
      expect(m.footprint, hasLength(2));
    });

    test('marking the upright edge first still gives width along the floor',
        () {
      final m = surfaceFromPoints(
        const Vec3(0.5, floorY, 2),
        const Vec3(0.5, floorY + 2.4, 2), // up the wall first
        const Vec3(1.1, floorY + 1.0, 2),
        name: 'Wall',
        floorY: floorY,
      );
      expect(m.kind, SurfaceKind.wall);
      expect(m.width, closeTo(0.6, 1e-9));
      expect(m.height, closeTo(2.4, 1e-9));
      expect(m.elevation, closeTo(0, 1e-9));
    });

    test('a worktop and a floor area', () {
      final top = surfaceFromPoints(
        const Vec3(0, floorY + 0.9, 0),
        const Vec3(2.4, floorY + 0.9, 0),
        const Vec3(1, floorY + 0.9, 0.6),
        name: 'Worktop',
        floorY: floorY,
      );
      expect(top.kind, SurfaceKind.raised);
      expect(top.width, closeTo(2.4, 1e-9));
      expect(top.height, closeTo(0.6, 1e-9));
      expect(top.elevation, closeTo(0.9, 1e-9));
      expect(top.footprint, hasLength(4));

      final rug = surfaceFromPoints(
        const Vec3(1, floorY, 1),
        const Vec3(3, floorY, 1),
        const Vec3(2, floorY + 0.01, 2.5),
        name: 'Rug',
        floorY: floorY,
      );
      expect(rug.kind, SurfaceKind.floor);
      expect(rug.area, closeTo(3.0, 0.01));
    });
  });

  group('doors and windows with heights', () {
    test('door height from the floor, window height and sill', () {
      final door = openingHeights(OpeningType.door,
          const Vec3(0, floorY + 0.02, 0), const Vec3(0.9, floorY, 0),
          topY: floorY + 2.03, floorY: floorY);
      expect(door.height, closeTo(2.03, 1e-9));
      expect(door.sill, isNull);

      final win = openingHeights(OpeningType.window,
          const Vec3(0, floorY + 0.9, 0), const Vec3(1.2, floorY + 0.9, 0),
          topY: floorY + 2.1, floorY: floorY);
      expect(win.height, closeTo(1.2, 1e-9));
      expect(win.sill, closeTo(0.9, 1e-9));
    });

    test('scanner detail list, including a door with no top marked', () {
      final list = parseOpeningDetails([
        0, 1, floorY, 0, 1.9, floorY, 0, floorY + 2.0, // door with top
        1, 2.5, floorY + 1, 0, 3.7, floorY + 1, 0, -999, // window, no top
      ], floorY);
      expect(list, hasLength(2));
      expect(list[0].type, OpeningType.door);
      expect(list[0].height, closeTo(2.0, 1e-9));
      expect(list[1].type, OpeningType.window);
      expect(list[1].height, isNull);
      expect(list[1].sill, closeTo(1.0, 1e-9));
    });

    test('heights reach the plan and survive saving', () {
      final scan = scanFromCorners(
        [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
        name: 'Room',
        openings: [
          const MarkedOpening(OpeningType.window, Vec2(1, 0), Vec2(2.2, 0),
              height: 1.2, sill: 0.9),
        ],
      );
      final back = RoomScan.fromJson(
          jsonDecode(jsonEncode(scan.toJson())) as Map<String, dynamic>);
      final o = const FloorPlanBuilder().build(back).openings.single;
      expect(o.width, closeTo(1.2, 1e-9));
      expect(o.height, 1.2);
      expect(o.sill, 0.9);
    });
  });

  group('surfaces on the floor plan', () {
    test('footprints follow the plan through rotation and editing', () {
      // Room rotated in AR space; a worktop along its first wall.
      const rot = 0.5;
      final corners = [
        Vec2.zero,
        const Vec2(4, 0),
        const Vec2(4, 3),
        const Vec2(0, 3)
      ].map((p) => p.rotate(rot)).toList();
      final worktop = MeasuredSurface(
        name: 'Worktop',
        kind: SurfaceKind.raised,
        width: 2,
        height: 0.6,
        footprint: [
          const Vec2(1, 0),
          const Vec2(3, 0),
          const Vec2(3, 0.6),
          const Vec2(1, 0.6)
        ].map((p) => p.rotate(rot)).toList(),
      );
      final scan =
          scanFromCorners(corners, name: 'Kitchen', surfaces: [worktop]);
      final plan = const FloorPlanBuilder().build(scan);
      final fp = plan.surfaces.single.footprint;
      // In plan coordinates the worktop lies along the wall at y = 0.
      expect(fp[0].distanceTo(fp[1]), closeTo(2, 1e-6));
      final ys = fp.map((p) => p.y).toList()..sort();
      expect(ys.first, closeTo(0, 1e-6));
      expect(ys.last, closeTo(0.6, 1e-6));

      // Editing the shape keeps it in the same place on the plan.
      PlanEditor.moveCorner(scan, plan, 2, const Vec2(4.2, 3));
      final after = const FloorPlanBuilder().build(scan).surfaces.single;
      for (var i = 0; i < 4; i++) {
        expect(after.footprint[i].distanceTo(fp[i]), lessThan(1e-6));
      }
    });

    test('surfaces are saved and loaded', () {
      final s = room(3, 3, surfaces: [
        const MeasuredSurface(
            name: 'Splashback',
            kind: SurfaceKind.wall,
            width: 1.8,
            height: 0.6,
            elevation: 0.9,
            footprint: [Vec2(0, 0), Vec2(1.8, 0)]),
      ]);
      final back = RoomScan.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      final m = back.surfaces.single;
      expect(m.name, 'Splashback');
      expect(m.kind, SurfaceKind.wall);
      expect(m.area, closeTo(1.08, 1e-9));
      expect(m.elevation, 0.9);
      expect(m.footprint, hasLength(2));
    });

    test('older saved rooms without surfaces or photos still load', () {
      final j = room(3, 3).toJson()
        ..remove('surfaces')
        ..remove('photos');
      final s = RoomScan.fromJson(j);
      expect(s.surfaces, isEmpty);
      expect(s.photos, isEmpty);
    });

    test('room photos are saved with the room', () {
      final s = room(3, 3)..photos.addAll(['room_1.jpg', 'photo_2.png']);
      final back = RoomScan.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.photos, ['room_1.jpg', 'photo_2.png']);
    });
  });

  group('floor map', () {
    final kitchen = room(4, 3, id: 'kitchen');
    final hall = room(2, 3, id: 'hall');
    final scans = {kitchen.id: kitchen, hall.id: hall};

    test('rooms placed side by side give the total area', () {
      final map = FloorMap(id: 'm', name: 'Flat', createdAt: DateTime(2026))
        ..rooms.add(MapRoom(scanId: 'kitchen'));
      var placed = placeRooms(map, scans);
      final plan = const FloorPlanBuilder().build(hall);
      map.rooms.add(MapRoom(
          scanId: 'hall', offset: offsetForNewRoom(placed, plan, gap: 0)));
      placed = placeRooms(map, scans);
      expect(placed, hasLength(2));
      expect(totalArea(placed), closeTo(12 + 6, 1e-6));
      final b = mapBounds(placed)!;
      // Plans put the longest wall horizontal: the hall is 3 m wide.
      expect(b.$2.x - b.$1.x, closeTo(4 + 3, 1e-6));
      // Placed right of the kitchen, not overlapping it.
      expect(placed[1].corners.every((c) => c.x >= 4 - 1e-9), isTrue);
    });

    test('a room turned a quarter keeps its size and swaps its sides', () {
      final map = FloorMap(id: 'm', name: 'Flat', createdAt: DateTime(2026))
        ..rooms.add(MapRoom(scanId: 'kitchen', quarterTurns: 1));
      final r = placeRooms(map, scans).single;
      final b = mapBounds([r])!;
      expect(b.$2.x - b.$1.x, closeTo(3, 1e-6));
      expect(b.$2.y - b.$1.y, closeTo(4, 1e-6));
      expect(r.contains(r.toMap(const Vec2(2, 1.5))), isTrue);
    });

    test('a dragged room snaps wall to wall', () {
      final other = [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)];
      // Dropped 8 cm from the kitchen's right wall and 30 cm lower.
      final dragged = [
        const Vec2(4.08, -0.3),
        const Vec2(6.08, -0.3),
        const Vec2(6.08, 2.7),
        const Vec2(4.08, 2.7),
      ];
      final d = snapOffset(dragged, [other], tolerance: 0.15);
      expect(d.x, closeTo(-0.08, 1e-9));
      expect(d.y, 0); // 30 cm is beyond the snap distance
      // Close to a corner: snaps exactly onto it.
      final near = [for (final p in dragged) p + const Vec2(0, 0.25)];
      final c = snapOffset(near, [other], tolerance: 0.15);
      expect((near[0] + c).distanceTo(const Vec2(4, 0)), lessThan(1e-9));
    });

    test('rooms that were deleted drop out of the map', () {
      final map = FloorMap(id: 'm', name: 'Flat', createdAt: DateTime(2026))
        ..rooms.addAll([MapRoom(scanId: 'kitchen'), MapRoom(scanId: 'gone')]);
      expect(placeRooms(map, scans), hasLength(1));
      final back = FloorMap.fromJson(
          jsonDecode(jsonEncode(map.toJson())) as Map<String, dynamic>);
      expect(back.rooms.map((r) => r.scanId), ['kitchen', 'gone']);
    });

    test('quarter turns', () {
      const v = Vec2(1, 0);
      expect(quarterTurn(v, 1).distanceTo(const Vec2(0, 1)), lessThan(1e-12));
      expect(quarterTurn(v, 2).distanceTo(const Vec2(-1, 0)), lessThan(1e-12));
      expect(quarterTurn(v, 7).distanceTo(const Vec2(0, -1)), lessThan(1e-12));
      expect(quarterTurn(v, 4).distanceTo(v), lessThan(1e-12));
    });
  });
}
