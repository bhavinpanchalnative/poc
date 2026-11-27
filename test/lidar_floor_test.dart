import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/roomplan_mapper.dart';
import 'package:room_measure/engine/elevation.dart';
import 'package:room_measure/engine/floor_map.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/engine/plan_editor.dart';
import 'package:room_measure/engine/units.dart';
import 'package:room_measure/services/plan_exporter.dart';
import 'package:roomplan_flutter/src/performance/optimized_mapper.dart';

/// A RoomPlan wall as the native side sends it: [a] to [b] on the floor
/// (world x, z), [height] high, standing on y = 0.
Map<String, dynamic> wallJson(Vec2 a, Vec2 b, {double height = 2.5}) {
  final d = (b - a).normalized;
  final c = (a + b) / 2;
  return {
    'uuid': 'w${a.x}${a.y}${b.x}${b.y}',
    'category': 'wall',
    'dimensions': {'x': a.distanceTo(b), 'y': height, 'z': 0.0},
    // Column-major: along the wall, up, its normal, centre.
    'transform': [
      d.x, 0.0, d.y, 0.0, //
      0.0, 1.0, 0.0, 0.0, //
      -d.y, 0.0, d.x, 0.0, //
      c.x, height / 2, c.y, 1.0,
    ],
    'confidence': 'high',
  };
}

/// A rectangular room [w] x [d] with its corner at [o], turned [deg].
Map<String, dynamic> roomJson(Vec2 o, double w, double d, {double deg = 0, double height = 2.5}) {
  final r = deg * math.pi / 180;
  Vec2 p(double x, double y) => o + Vec2(x, y).rotate(r);
  final cs = [p(0, 0), p(w, 0), p(w, d), p(0, d)];
  return {
    'walls': [for (var i = 0; i < 4; i++) wallJson(cs[i], cs[(i + 1) % 4], height: height)],
    'objects': <dynamic>[],
    'doors': <dynamic>[],
    'windows': <dynamic>[],
    'openings': <dynamic>[],
  };
}

void main() {
  group('scan results from the LiDAR scanner', () {
    test('live updates carry how far round the user looked, and the room number', () {
      // Regression: these were dropped by the parser, so the scan never
      // waited for the user to turn round.
      final r = OptimizedMapper.parseScanResult(jsonEncode({
        'room': roomJson(Vec2.zero, 4, 3),
        'metadata': {'lookRoundSectors': '7', 'roomIndex': '1'},
      }))!;
      expect(r.metadata.lookRoundSectors, 7);
      expect(r.metadata.roomIndex, 1);
      expect(r.rooms, isEmpty);
    });

    test('a finished scan carries every room, its type, and the photos', () {
      final r = OptimizedMapper.parseScanResult(jsonEncode({
        'room': roomJson(Vec2.zero, 4, 3),
        'metadata': <String, String>{},
        'rooms': [
          {'room': roomJson(Vec2.zero, 4, 3), 'type': 'kitchen'},
          {'room': roomJson(const Vec2(4, 0), 3, 3, height: 2.4), 'type': null},
        ],
        'photos': [
          {'path': '/tmp/p.jpg', 'x': 5.0, 'z': 1.0, 'dirX': 1.0, 'dirZ': 0.0, 'room': 1},
        ],
      }))!;
      expect(r.rooms.length, 2);
      expect(r.rooms[0].type, 'kitchen');
      expect(r.rooms[1].type, isNull);
      expect(r.photos.single.x, 5.0);
      expect(r.photos.single.room, 1);

      final second = RoomPlanMapper.roomToScan(r.rooms[1].room, name: '');
      expect(second.walls.length, 4);
      expect(second.ceilingHeight, closeTo(2.4, 1e-6));
      final plan = const FloorPlanBuilder().build(second);
      expect(plan.area, closeTo(9, 0.01));
    });
  });

  group('ceiling height and room names', () {
    test('ceiling height is the median full wall height', () {
      expect(RoomPlanMapper.ceilingHeightOf([2.5, 2.52, 2.48, 0.9]), closeTo(2.5, 1e-9));
      expect(RoomPlanMapper.ceilingHeightOf([2.4, 2.6]), closeTo(2.5, 1e-9));
      // Only short pieces (a half wall): unknown.
      expect(RoomPlanMapper.ceilingHeightOf([1.0, 0.8]), isNull);
    });

    test('rooms are named from RoomPlan or from what is in them', () {
      RoomElement e(String k) => RoomElement(kind: k);
      expect(RoomPlanMapper.roomTypeName('livingRoom', const []), 'Living room');
      expect(RoomPlanMapper.roomTypeName(null, [e('Toilet')]), 'Bathroom');
      expect(RoomPlanMapper.roomTypeName(null, [e('Refrigerator'), e('Table')]), 'Kitchen');
      expect(RoomPlanMapper.roomTypeName(null, [e('Bed'), e('Storage')]), 'Bedroom');
      expect(RoomPlanMapper.roomTypeName(null, [e('Sofa')]), 'Living room');
      expect(RoomPlanMapper.roomTypeName(null, [e('Storage')]), isNull);
      expect(RoomPlanMapper.uniqueNames(['Bedroom', 'Kitchen', null, 'Bedroom']),
          ['Bedroom', 'Kitchen', 'Room 3', 'Bedroom 2']);
    });
  });

  group('several rooms scanned in one go', () {
    // Two rooms side by side, sharing a wall, the house turned 30 degrees.
    final a = RoomPlanMapper.roomToScan(
        OptimizedMapper.parseScanResult(jsonEncode({'room': roomJson(const Vec2(1, 2), 4, 3, deg: 30)}))!.room,
        name: 'A');
    final bOrigin = const Vec2(1, 2) + const Vec2(4, 0).rotate(30 * math.pi / 180);
    final b = RoomPlanMapper.roomToScan(
        OptimizedMapper.parseScanResult(jsonEncode({'room': roomJson(bOrigin, 2.5, 3, deg: 30)}))!.room,
        name: 'B');

    test('they are squared to the page and placed on the map where they were scanned', () {
      final angle = RoomPlanMapper.alignmentAngle([a.walls, b.walls]);
      final rooms = [RoomPlanMapper.rotated(a, angle), RoomPlanMapper.rotated(b, angle)];
      final offsets = RoomPlanMapper.mapOffsets(rooms);
      final map = FloorMap(id: 'm', name: 'Floor', createdAt: DateTime(2026), rooms: [
        MapRoom(scanId: rooms[0].id, offset: offsets[0]!),
        MapRoom(scanId: rooms[1].id, offset: offsets[1]!),
      ]);
      // Distinct ids (both scans were made in the same microsecond).
      final scans = {rooms[0].id: rooms[0]};
      final placedA = placeRooms(map, scans).first;
      final mapB = FloorMap(id: 'm2', name: 'F', createdAt: DateTime(2026),
          rooms: [MapRoom(scanId: rooms[1].id, offset: offsets[1]!)]);
      final placedB = placeRooms(mapB, {rooms[1].id: rooms[1]}).first;

      // Square to the page: every wall horizontal or vertical.
      for (final p in [placedA, placedB]) {
        final cs = p.corners;
        for (var i = 0; i < cs.length; i++) {
          final d = cs[(i + 1) % cs.length] - cs[i];
          expect(math.min(d.x.abs(), d.y.abs()), lessThan(1e-6));
        }
      }
      // A's right wall is B's left wall: same x, same span.
      double maxX(List<Vec2> cs) => cs.map((c) => c.x).reduce(math.max);
      double minX(List<Vec2> cs) => cs.map((c) => c.x).reduce(math.min);
      expect(minX(placedB.corners), closeTo(maxX(placedA.corners), 1e-6));
      double minY(List<Vec2> cs) => cs.map((c) => c.y).reduce(math.min);
      expect(minY(placedB.corners), closeTo(minY(placedA.corners), 1e-6));
      expect(placedA.plan.area, closeTo(12, 1e-6));
      expect(placedB.plan.area, closeTo(7.5, 1e-6));
    });

    test('a photo goes to the room it was taken in', () {
      Vec2 inA = const Vec2(1, 2) + const Vec2(2, 1.5).rotate(30 * math.pi / 180);
      Vec2 inB = bOrigin + const Vec2(1.2, 1.5).rotate(30 * math.pi / 180);
      expect(RoomPlanMapper.roomForPoint(inA, [a.walls, b.walls], 1), 0);
      expect(RoomPlanMapper.roomForPoint(inB, [a.walls, b.walls], 0), 1);
      // Outside both (in a doorway): the nearest wall's room.
      final out = bOrigin + const Vec2(3.0, 1.5).rotate(30 * math.pi / 180);
      expect(RoomPlanMapper.roomForPoint(out, [a.walls, b.walls], 0), 1);
    });
  });

  group('photo pins', () {
    test('a pin stays on the same spot of the plan when the shape is edited', () {
      final scan = RoomScan(
        id: 'r',
        name: 'R',
        createdAt: DateTime(2026),
        source: CaptureSource.roomPlan,
        walls: [
          for (final (p, q) in [
            (const Vec2(1, 1), const Vec2(5, 2)),
            (const Vec2(5, 2), const Vec2(4.25, 5)),
            (const Vec2(4.25, 5), const Vec2(0.25, 4)),
            (const Vec2(0.25, 4), const Vec2(1, 1)),
          ])
            WallLine(p, q),
        ],
        photos: ['p.jpg'],
        photoPins: [const PhotoPin(file: 'p.jpg', position: Vec2(2.5, 3), direction: Vec2(1, 0))],
      );
      final before = const FloorPlanBuilder().build(scan);
      final at = before.toPlan(scan.photoPins.single.position);
      final dir = before.dirToPlan(scan.photoPins.single.direction!);
      PlanEditor.applyCorners(scan, List.of(before.corners), before);
      final after = const FloorPlanBuilder().build(scan);
      final at2 = after.toPlan(scan.photoPins.single.position);
      expect(at2.distanceTo(at), lessThan(1e-6));
      expect(after.dirToPlan(scan.photoPins.single.direction!).distanceTo(dir), lessThan(1e-6));
      // Inside the room on the plan.
      expect(pointInPolygon(at, before.corners), isTrue);
    });

    test('new fields are saved and loaded', () {
      final scan = RoomScan(
        id: 'r',
        name: 'R',
        createdAt: DateTime(2026),
        source: CaptureSource.roomPlan,
        walls: [WallLine(Vec2.zero, const Vec2(1, 0))],
        photoPins: [const PhotoPin(file: 'p.jpg', position: Vec2(1, 2))],
        ceilingHeight: 2.45,
      );
      final back = RoomScan.fromJson(jsonDecode(jsonEncode(scan.toJson())) as Map<String, dynamic>);
      expect(back.ceilingHeight, 2.45);
      expect(back.photoPins.single.position.y, 2);
      expect(back.photoPins.single.direction, isNull);
    });
  });

  group('ceiling height in drawings and exports', () {
    RoomScan room({double? ceiling}) => RoomScan(
          id: 'r',
          name: 'Living, "big"',
          createdAt: DateTime(2026),
          source: CaptureSource.roomPlan,
          walls: [
            WallLine(Vec2.zero, const Vec2(4, 0)),
            WallLine(const Vec2(4, 0), const Vec2(4, 3)),
            WallLine(const Vec2(4, 3), const Vec2(0, 3)),
            WallLine(const Vec2(0, 3), Vec2.zero),
          ],
          openings: [
            Opening(type: OpeningType.door, wallIndex: 0, center: 0.5, width: 0.9, height: 2.0),
            Opening(type: OpeningType.window, wallIndex: 2, center: 0.5, width: 1.2, height: 1.0, sill: 0.9),
          ],
          ceilingHeight: ceiling,
        );

    test('a door drawn on its wall uses the measured wall height', () {
      final p = const FloorPlanBuilder().build(room(ceiling: 2.7));
      expect(OpeningElevation.of(p, p.openings.first).wallHeight, closeTo(2.7, 1e-9));
      final unknown = const FloorPlanBuilder().build(room());
      expect(OpeningElevation.of(unknown, unknown.openings.first).wallHeight,
          OpeningElevation.defaultWallHeight);
    });

    test('wall area is the walls less doors and windows', () {
      final p = const FloorPlanBuilder().build(room(ceiling: 2.5));
      // 14 m perimeter x 2.5 m, less 0.9 x 2.0 and 1.2 x 1.0.
      expect(PlanExporter.wallArea(p), closeTo(35 - 1.8 - 1.2, 1e-9));
      expect(PlanExporter.wallArea(const FloorPlanBuilder().build(room())), 0);
    });

    test('the CSV has rooms, walls and openings, as numbers', () {
      final s = room(ceiling: 2.5);
      final p = const FloorPlanBuilder().build(s);
      final csv = PlanExporter.csv([(s, p)], LengthUnit.meters);
      expect(csv.startsWith('﻿'), isTrue);
      final lines = csv.substring(1).split('\r\n');
      expect(lines[0], startsWith('Room,Floor area (m²),Perimeter (m)'));
      // Quotes in the name are doubled; the comma stays inside the quotes.
      expect(lines[1], startsWith('"Living, ""big""",12.00,14.00,4.00,3.00,2.50,32.00,4,1,1,0,0'));
      expect(csv, contains('"Living, ""big""",1,4.00'));
      expect(csv, contains('"Living, ""big""",Window,3,1.20,1.00,0.90'));
      final feet = PlanExporter.csv([(s, p)], LengthUnit.feetInches);
      expect(feet, contains('Perimeter (ft)'));
      expect(feet, contains(',45.93,')); // 14 m
    });
  });
}
