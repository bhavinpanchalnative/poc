import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/ui/plan_painter.dart';

RoomScan room({List<RoomElement> elements = const [], List<PhotoPin> pins = const []}) => RoomScan(
      id: 'r',
      name: 'R',
      createdAt: DateTime(2026),
      source: CaptureSource.arTap,
      // A 4 × 3 room, turned and away from the origin as a scan is.
      walls: [
        for (final (a, b) in [
          (const Vec2(0, 0), const Vec2(4, 0)),
          (const Vec2(4, 0), const Vec2(4, 3)),
          (const Vec2(4, 3), const Vec2(0, 3)),
          (const Vec2(0, 3), const Vec2(0, 0)),
        ])
          WallLine(a.rotate(0.4) + const Vec2(5, -2), b.rotate(0.4) + const Vec2(5, -2)),
      ],
      elements: elements,
      photoPins: pins,
    );

void main() {
  test('furniture from the camera scanner is read with its size and direction', () {
    final e = parseElements([1, 2, 2.0, 0.9, 0.8, 0.5, 3, 4, 0.5, 0.5, 0.9, 0], ['Sofa', 'Chair']);
    expect(e.length, 2);
    expect(e[0].kind, 'Sofa');
    expect(e[0].position!.x, 1);
    expect(e[0].width, 2.0);
    expect(e[0].depth, 0.9);
    expect(e[0].angle, 0.5);
    expect(e[1].kind, 'Chair');
    // Kinds missing, or values cut short: only whole entries.
    expect(parseElements([1, 2, 3], ['Bed']), isEmpty);
    expect(parseElements([1, 2, 2, 1, 1, 0], const []), isEmpty);
  });

  test('furniture direction is saved and loaded', () {
    const e = RoomElement(kind: 'Bed', width: 1.6, depth: 2, position: Vec2(1, 1), angle: 0.3);
    final back = RoomElement.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
    expect(back.angle, 0.3);
    expect(back.width, 1.6);
  });

  test('a tap on the plan maps back to the scan, so a 360° photo lands there', () {
    final scan = room();
    final plan = const FloorPlanBuilder().build(scan);
    for (final p in [const Vec2(5.5, -1), const Vec2(7, 0.5)]) {
      final back = plan.fromPlan(plan.toPlan(p));
      expect(back.x, closeTo(p.x, 1e-9));
      expect(back.y, closeTo(p.y, 1e-9));
    }
  });

  test('a 360° pin is saved as one', () {
    const pin = PhotoPin(file: 'pano_1.jpg', position: Vec2(1, 2), panorama: true);
    final back = PhotoPin.fromJson(jsonDecode(jsonEncode(pin.toJson())) as Map<String, dynamic>);
    expect(back.panorama, isTrue);
    expect(back.copyWith(position: Vec2.zero).panorama, isTrue);
    expect(PhotoPin.fromJson(const {'file': 'a', 'position': {'x': 0, 'y': 0}}).panorama, isFalse);
  });

  test('furniture is drawn inside the room, turned with the plan', () {
    // A sofa in the middle of the room, along its first wall.
    final mid = const Vec2(2, 1.5).rotate(0.4) + const Vec2(5, -2);
    final scan = room(elements: [RoomElement(kind: 'Sofa', width: 2, depth: 0.9, position: mid, angle: 0.4)]);
    final plan = const FloorPlanBuilder().build(scan);
    final f = furnitureOnPlan(scan, plan).single;
    expect(f.$5, 'Sofa');
    // Along the room's first wall, whichever way the plan turned it.
    final wall = plan.corners[1] - plan.corners[0];
    final along = (math.cos(f.$2) * wall.x + math.sin(f.$2) * wall.y).abs() / wall.length;
    expect(along, closeTo(1, 1e-6));
    // Its centre is inside the room on the plan.
    expect(pointInPolygonForTest(f.$1, plan.corners), isTrue);
  });
}

bool pointInPolygonForTest(Vec2 p, List<Vec2> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}
