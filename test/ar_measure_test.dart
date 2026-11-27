import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';

void main() {
  test('corners marked around a room give its wall lengths', () {
    // A 4.00 x 3.00 m room, slightly rotated as AR coordinates usually are,
    // with a centimetre or so of marking error.
    final corners = [
      const Vec2(0, 0),
      const Vec2(4.0, 0.01),
      const Vec2(4.01, 3.0),
      const Vec2(-0.01, 2.99),
    ].map((p) => p.rotate(0.4)).toList();

    final scan = scanFromCorners(corners, name: 'Test');
    expect(scan.walls, hasLength(4));

    final plan = FloorPlanBuilder(squareCorners: true).build(scan);
    final lengths = plan.wallLengths;
    expect(lengths, hasLength(4));
    for (final (i, expected) in [4.0, 3.0, 4.0, 3.0].indexed) {
      expect(lengths[i], closeTo(expected, 0.03), reason: 'wall ${i + 1}');
    }
  });

  test('three corners make a closed triangle', () {
    final scan = scanFromCorners(
        const [Vec2(0, 0), Vec2(3, 0), Vec2(0, 2)],
        name: 'Section');
    final plan = FloorPlanBuilder(squareCorners: false).build(scan);
    expect(plan.wallLengths, hasLength(3));
    expect(plan.wallLengths[0], closeTo(3.0, 0.001));
  });
}
