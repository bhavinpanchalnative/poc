import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/engine/plan_editor.dart';
import 'package:room_measure/engine/sample_rooms.dart';
import 'package:room_measure/engine/units.dart';

RoomScan rect(double w, double d) => RoomScan(
      id: 't',
      name: 'Test',
      createdAt: DateTime(2026),
      source: CaptureSource.manual,
      walls: wallsFromLengths([w, d, w, d], [90, 90, 90, 90]),
    );

FloorPlan build(RoomScan s) => const FloorPlanBuilder().build(s);

void main() {
  group('units', () {
    test('formats in every unit', () {
      expect(formatLength(3.0, LengthUnit.meters), '3.00 m');
      expect(formatLength(3.0, LengthUnit.centimeters), '300 cm');
      expect(formatLength(3.048, LengthUnit.feetInches), "10' 0\"");
      expect(formatLength(0.254, LengthUnit.inches), '10.0 in');
      expect(formatArea(1, LengthUnit.feetInches), '10.8 ft²');
      expect(formatVolume(1, LengthUnit.meters), '1.00 m³');
    });

    test('parses typed lengths', () {
      expect(parseLength('3,5', LengthUnit.meters), 3.5);
      expect(parseLength('350', LengthUnit.centimeters), closeTo(3.5, 1e-9));
      expect(parseLength("10' 6\"", LengthUnit.feetInches),
          closeTo(3.2004, 1e-4));
      expect(parseLength('120 cm', LengthUnit.feetInches), closeTo(1.2, 1e-9));
      expect(parseLength('abc', LengthUnit.meters), isNull);
      expect(parseLength('0', LengthUnit.meters), isNull);
    });

    test('editable text round-trips', () {
      for (final u in LengthUnit.values) {
        final back = parseLength(editableLength(2.5, u), u)!;
        expect(back, closeTo(2.5, 0.02), reason: u.name);
      }
    });
  });

  group('dimensions', () {
    test('rectangle area, size and element counts', () {
      final s = rect(4, 3)
        ..openings.add(const Opening(
            type: OpeningType.door,
            wallIndex: 0,
            center: 0.5,
            width: 1,
            height: 2));
      final p = build(s);
      expect(p.area, closeTo(12, 1e-6));
      expect(p.perimeter, closeTo(14, 1e-6));
      expect(p.overallSize.width, closeTo(4, 1e-6));
      expect(p.overallSize.depth, closeTo(3, 1e-6));
      // Ceiling height is no longer part of a room.
      expect(s.toJson().containsKey('height'), isFalse);
      s.elements.addAll(const [
        RoomElement(kind: 'Bed'),
        RoomElement(kind: 'Chair'),
        RoomElement(kind: 'Chair'),
      ]);
      expect(roomElementCounts(s), [('Door', 1), ('Bed', 1), ('Chair', 2)]);
      final back = RoomScan.fromJson(s.toJson());
      expect(back.elements.map((e) => e.kind), ['Bed', 'Chair', 'Chair']);
    });

    test('old saves with a ceiling height still load', () {
      final j = rect(4, 3).toJson()..['height'] = 2.6;
      final back = RoomScan.fromJson(j);
      expect(build(back).area, closeTo(12, 1e-6));
      expect(back.elements, isEmpty);
    });

    test('sample scans close with the right size', () {
      final p = build(SampleRooms.rectangle());
      expect(p.area, closeTo(4.2 * 3.6, 0.15));
    });
  });

  group('editing', () {
    test('changing a wall length stretches the room', () {
      final s = rect(4, 3);
      PlanEditor.setWallLength(s, build(s), 0, 5);
      final p = build(s);
      expect(p.wallLength(0), closeTo(5, 1e-6));
      expect(p.wallLength(1), closeTo(3, 1e-6));
      expect(p.wallLength(2), closeTo(5, 1e-6));
      expect(p.area, closeTo(15, 1e-6));
      expect(s.keepOrientation, isTrue);
    });

    test('editing keeps the orientation when another wall gets longest', () {
      final s = rect(4, 3);
      PlanEditor.setWallLength(s, build(s), 1, 6);
      final p = build(s);
      expect(p.wallLength(0), closeTo(4, 1e-6));
      expect(p.wallLength(1), closeTo(6, 1e-6));
      // Wall 0 still runs horizontally.
      expect((p.wallEnd(0) - p.wallStart(0)).y.abs(), lessThan(1e-6));
    });

    test('L-shape stretch keeps right angles', () {
      final s = RoomScan(
        id: 'l',
        name: 'L',
        createdAt: DateTime(2026),
        source: CaptureSource.manual,
        walls: wallsFromLengths(
            [6, 2.8, 2.5, 2.2, 3.5, 5], [90, 90, -90, 90, 90, 90]),
      );
      final before = build(s);
      expect(before.area, closeTo(6 * 5 - 2.5 * 2.2, 1e-6));
      PlanEditor.setWallLength(s, before, 2, 3.0);
      final p = build(s);
      expect(p.wallLength(2), closeTo(3.0, 1e-6));
      for (var i = 0; i < p.wallCount; i++) {
        final a = p.interiorAngleDeg(i);
        expect((a - 90).abs() < 0.01 || (a - 270).abs() < 0.01, isTrue,
            reason: 'corner $i is $a°');
      }
    });

    test('split and remove corners keep openings on the right walls', () {
      final s = rect(4, 3)
        ..openings.add(const Opening(
            type: OpeningType.window, wallIndex: 2, center: 0.5, width: 1));
      PlanEditor.splitWall(s, build(s), 0);
      var p = build(s);
      expect(p.wallCount, 5);
      expect(p.warnings, isEmpty);
      expect(p.area, closeTo(12, 1e-6));
      expect(s.openings.single.wallIndex, 3);

      PlanEditor.removeCorner(s, p, 1);
      p = build(s);
      expect(p.wallCount, 4);
      expect(p.wallLength(0), closeTo(4, 1e-6));
      expect(s.openings.single.wallIndex, 2);
      expect(s.openings.single.center, closeTo(0.5, 1e-6));
    });

    test('moving a corner changes the shape', () {
      final s = rect(4, 3);
      final p0 = build(s);
      PlanEditor.moveCorner(s, p0, 2, p0.corners[2] + const Vec2(1, 0));
      final p = build(s);
      expect(p.area, closeTo(12 + 1.5, 1e-6));
    });
  });

  group('AR openings', () {
    test('door marks are placed on the nearest wall', () {
      final scan = scanFromCorners(
        const [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)],
        name: 'AR',
        openings: const [
          MarkedOpening(OpeningType.door, Vec2(1.0, 0.05), Vec2(1.9, -0.03)),
          MarkedOpening(OpeningType.window, Vec2(3.95, 1), Vec2(4.02, 2.2)),
        ],
      );
      final door = scan.openings[0], window = scan.openings[1];
      expect(door.wallIndex, 0);
      expect(door.width, closeTo(0.9, 1e-6));
      expect(door.center, closeTo(1.45 / 4, 0.01));
      expect(window.type, OpeningType.window);
      expect(window.wallIndex, 1);
      expect(window.width, closeTo(1.2, 1e-6));
    });
  });
}
