import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/measure3d.dart';
import 'package:room_measure/engine/models.dart';

void main() {
  test('distance between two points, with its across and up parts', () {
    // 3 m across the floor and 4 m up: a 5 m straight line.
    final l = lineFromPoints(const Vec3(1, 0, 2), const Vec3(1, 4, 5), name: 'L');
    expect(l.length, closeTo(5, 1e-9));
    expect(l.run, closeTo(3, 1e-9));
    expect(l.rise, closeTo(4, 1e-9));
    expect(l.footprint, [const Vec2(1, 2), const Vec2(1, 5)]);
  });

  test('scanner lines are parsed and numbered', () {
    final lines = parseLines([0, 0, 0, 1.24, 0, 0, 0, 1, 0, 0, 1.56, 0], first: 3);
    expect(lines, hasLength(2));
    // No automatic names ("Line 3"): the user names each line.
    expect(lines[0].name, '');
    expect(lines[0].length, closeTo(1.24, 1e-9));
    expect(lines[1].name, '');
    expect(lines[1].length, closeTo(0.56, 1e-9));
    // A horizontal line has no "up" part worth showing.
    expect(lines[0].rise, closeTo(0, 1e-9));
  });

  test('lines are saved with the room and follow it onto the plan', () {
    const rot = 0.7;
    final corners = [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)]
        .map((p) => p.rotate(rot))
        .toList();
    final a = const Vec2(1, 1).rotate(rot), b = const Vec2(3, 1).rotate(rot);
    final scan = scanFromCorners(corners, name: 'Room', lines: [
      MeasuredLine(name: 'Sofa', length: 2.0, footprint: [a, b]),
    ]);
    final back = RoomScan.fromJson(
        jsonDecode(jsonEncode(scan.toJson())) as Map<String, dynamic>);
    final l = const FloorPlanBuilder().build(back).lines.single;
    expect(l.name, 'Sofa');
    expect(l.length, 2.0);
    // On the plan (longest wall horizontal) the line is horizontal, 1 m in.
    expect(l.footprint[0].distanceTo(l.footprint[1]), closeTo(2.0, 1e-6));
    expect(l.footprint[0].y, closeTo(l.footprint[1].y, 1e-6));
  });

  test('older saved rooms without lines still load', () {
    final j = scanFromCorners(
            [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
            name: 'Room')
        .toJson()
      ..remove('lines');
    expect(RoomScan.fromJson(j).lines, isEmpty);
  });

  test('a scan with lines but no room keeps just the lines', () {
    // Line mode under Start scan, finished before any room outline: no
    // corners, one line, and a door marked along the way.
    final scan = scanFromCorners(
      const [],
      name: 'Room',
      lines: parseLines([0, 0, 0, 2, 0, 0]),
      openings: const [MarkedOpening(OpeningType.door, Vec2(0, 0), Vec2(0.9, 0))],
    );
    final captured = CapturedScan(scan);
    expect(captured.hasRoom, isFalse);
    expect(scan.lines.single.length, closeTo(2, 1e-9));
    expect(scan.openings, isEmpty);

    final room = CapturedScan(scanFromCorners(
        [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
        name: 'Room'));
    expect(room.hasRoom, isTrue);
  });

  test('lines with an estimated end are flagged and stay flagged when saved',
      () {
    final lines = parseLines([0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 0],
        estimated: [0, 1]);
    expect(lines[0].estimated, isFalse);
    expect(lines[1].estimated, isTrue);
    final back = MeasuredLine.fromJson(
        jsonDecode(jsonEncode(lines[1].toJson())) as Map<String, dynamic>);
    expect(back.estimated, isTrue);
    // Scanner builds without the flags: nothing is marked estimated.
    expect(parseLines([0, 0, 0, 1, 0, 0]).single.estimated, isFalse);
  });
}
