import 'dart:math' as math;

import 'floor_plan_builder.dart';
import 'geometry.dart';
import 'models.dart';

/// Simulated tap-to-measure scans of known rooms, for demos and tests on
/// devices without AR (Windows, emulators).
class SampleRooms {
  /// Simulates a user tapping two points on each wall of [trueCorners]
  /// (somewhere in the middle of the wall, as furniture often hides the
  /// ends), with [noise] metres of random error per tap.
  static List<WallLine> simulateTaps(
    List<Vec2> trueCorners, {
    double noise = 0.015,
    int seed = 7,
    double rotationDeg = 23,
    Vec2 offset = const Vec2(1.7, -0.4),
  }) {
    final rnd = math.Random(seed);
    double gauss() {
      // Box-Muller
      final u = 1 - rnd.nextDouble(), v = rnd.nextDouble();
      return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
    }

    Vec2 jitter(Vec2 p) => Vec2(p.x + gauss() * noise, p.y + gauss() * noise);
    final rot = degToRad(rotationDeg);
    final n = trueCorners.length;
    return [
      for (var i = 0; i < n; i++)
        () {
          final a = trueCorners[i], b = trueCorners[(i + 1) % n];
          final t1 = 0.15 + rnd.nextDouble() * 0.2;
          final t2 = 0.65 + rnd.nextDouble() * 0.2;
          final p1 = jitter(a + (b - a) * t1).rotate(rot) + offset;
          final p2 = jitter(a + (b - a) * t2).rotate(rot) + offset;
          return WallLine(p1, p2);
        }(),
    ];
  }

  static const rectangleCorners = [
    Vec2(0, 0),
    Vec2(4.20, 0),
    Vec2(4.20, 3.60),
    Vec2(0, 3.60),
  ];

  static const lShapeCorners = [
    Vec2(0, 0),
    Vec2(6.00, 0),
    Vec2(6.00, 2.80),
    Vec2(3.50, 2.80),
    Vec2(3.50, 5.00),
    Vec2(0, 5.00),
  ];

  static RoomScan rectangle() => RoomScan(
        id: 'sample-rect',
        name: 'Example bedroom',
        createdAt: DateTime(2026, 11, 16),
        source: CaptureSource.sample,
        walls: simulateTaps(rectangleCorners),
        openings: const [
          Opening(
              type: OpeningType.door, wallIndex: 0, center: 0.2, width: 0.9),
          Opening(
              type: OpeningType.window, wallIndex: 2, center: 0.5, width: 1.5),
        ],
      );

  static RoomScan lShape() => RoomScan(
        id: 'sample-l',
        name: 'Example L-shaped living room',
        createdAt: DateTime(2026, 11, 16),
        source: CaptureSource.sample,
        walls: simulateTaps(lShapeCorners, seed: 11, rotationDeg: -41),
        openings: const [
          Opening(
              type: OpeningType.door, wallIndex: 5, center: 0.3, width: 0.9),
          Opening(
              type: OpeningType.window, wallIndex: 1, center: 0.5, width: 1.2),
          Opening(
              type: OpeningType.window, wallIndex: 4, center: 0.5, width: 1.8),
        ],
      );

  static RoomScan rectangleFromLengths() => RoomScan(
        id: 'sample-manual',
        name: 'Example typed lengths',
        createdAt: DateTime(2026, 11, 16),
        source: CaptureSource.manual,
        walls: wallsFromLengths([3.0, 2.5, 3.0, 2.5], [90, 90, 90, 90]),
      );

  static List<RoomScan> all() => [rectangle(), lShape()];
}
