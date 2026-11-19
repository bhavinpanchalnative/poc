import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/photo_measure.dart';

/// A phone camera held at 1.4 m in one corner of the room (0.3, 0.3),
/// turned towards the opposite corner and tilted 25 degrees down, with a
/// 4000 x 3000 photo from the 0.5x ultra-wide lens (about 115 degrees
/// wide): from a corner, only that lens shows the other three corners.
Vec2 photoOf(Vec2 floor, {math.Random? jitter, double px = 2}) {
  const camX = 0.3, camY = 1.4, camZ = 0.3;
  const f = 1300.0, w = 4000.0, h = 3000.0;
  const tilt = 25 * math.pi / 180;
  final yaw = math.atan2(4.2 - camX, 3.6 - camZ); // towards the far corner
  // Camera axes: right, forward (tilted down), up.
  final rx = math.cos(yaw), rz = -math.sin(yaw);
  final hx = math.sin(yaw), hz = math.cos(yaw); // horizontal forward
  final dx = floor.x - camX, dy = 0 - camY, dz = floor.y - camZ;
  final horiz = dx * hx + dz * hz;
  final depth = horiz * math.cos(tilt) - dy * math.sin(tilt);
  final up = dy * math.cos(tilt) + horiz * math.sin(tilt);
  var x = w / 2 + f * (dx * rx + dz * rz) / depth;
  var y = h / 2 - f * up / depth;
  if (jitter != null) {
    x += (jitter.nextDouble() * 2 - 1) * px;
    y += (jitter.nextDouble() * 2 - 1) * px;
  }
  return Vec2(x, y);
}

bool inPhoto(Vec2 p) => p.x >= 0 && p.x <= 4000 && p.y >= 0 && p.y <= 3000;

void main() {
  // A4 sheet lying on the floor in the middle of the room.
  const a4 = FloorReference('A4 paper', 0.297, 0.210);
  final sheet = [
    const Vec2(2.0, 1.8),
    const Vec2(2.297, 1.8),
    const Vec2(2.297, 2.01),
    const Vec2(2.0, 2.01),
  ];
  // A 4.20 x 3.60 m room.
  final room = [
    Vec2.zero,
    const Vec2(4.2, 0),
    const Vec2(4.2, 3.6),
    const Vec2(0, 3.6),
  ];

  double side(List<Vec2> p, int i) => p[i].distanceTo(p[(i + 1) % p.length]);

  final visible = [room[1], room[2], room[3]];

  test('the simulated photo shows the reference and three corners', () {
    for (final p in [...sheet, ...visible]) {
      expect(inPhoto(photoOf(p)), isTrue, reason: '$p');
    }
  });

  test('room size from a photo with an A4 sheet on the floor', () {
    final got = floorCornersFromPhoto(
      reference: [for (final p in sheet) photoOf(p)],
      ref: a4,
      corners: [for (final p in room) photoOf(p)],
    )!;
    expect(got, hasLength(4));
    for (var i = 0; i < 4; i++) {
      expect(side(got, i), closeTo(side(room, i), 1e-6));
    }
    expect(signedArea(got).abs(), closeTo(15.12, 1e-5));
  });

  test('three visible corners complete a rectangular room', () {
    // Far corners and one near corner seen from the doorway.
    final got = floorCornersFromPhoto(
      reference: [for (final p in sheet) photoOf(p)],
      ref: a4,
      corners: [for (final p in visible) photoOf(p)],
    )!;
    expect(got, hasLength(4));
    expect(side(got, 0), closeTo(3.6, 1e-6));
    expect(side(got, 1), closeTo(4.2, 1e-6));
    expect(signedArea(got).abs(), closeTo(15.12, 1e-5));
  });

  /// Worst and typical (median) wall error over 200 photos with tapping
  /// error of up to [px] pixels.
  (double worst, double median) tappingError(
      List<Vec2> refPts, FloorReference ref, double px) {
    final rnd = math.Random(7);
    final errs = <double>[];
    for (var trial = 0; trial < 200; trial++) {
      final got = floorCornersFromPhoto(
        reference: [for (final p in refPts) photoOf(p, jitter: rnd, px: px)],
        ref: ref,
        corners: [for (final p in visible) photoOf(p, jitter: rnd, px: px)],
      );
      // Rejected taps count as a complete failure.
      errs.add(got == null
          ? 1.0
          : math.max((side(got, 0) / 3.6 - 1).abs(),
              (side(got, 1) / 4.2 - 1).abs()));
    }
    errs.sort();
    return (errs.last, errs[errs.length ~/ 2]);
  }

  test('accuracy limits with tapping error (shown to the user)', () {
    final tile = [
      const Vec2(1.8, 1.5),
      const Vec2(2.4, 1.5),
      const Vec2(2.4, 2.1),
      const Vec2(1.8, 2.1),
    ];
    const tileRef = FloorReference('tile', 0.6, 0.6);
    String pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
    for (final px in [1.0, 3.0]) {
      final a = tappingError(sheet, a4, px), t = tappingError(tile, tileRef, px);
      // ignore: avoid_print
      print('taps ±${px.toStringAsFixed(0)} px:  A4 median ${pct(a.$2)}, '
          'worst ${pct(a.$1)};  60 cm tile median ${pct(t.$2)}, worst ${pct(t.$1)}');
    }
    // Zoomed-in taps (about ±1 px) on a 60 cm tile: a few percent.
    final zoomed = tappingError(tile, tileRef, 1);
    expect(zoomed.$2, lessThan(0.03));
    expect(zoomed.$2, lessThan(tappingError(sheet, a4, 1).$2));
  });

  test('a tap above the floor horizon is rejected', () {
    // A point high up in the photo (sky / upper wall), not on the floor.
    final got = floorCornersFromPhoto(
      reference: [for (final p in sheet) photoOf(p)],
      ref: a4,
      corners: [photoOf(room[2]), photoOf(room[3]), const Vec2(2000, -2500)],
    );
    expect(got, isNull);
  });

  test('a degenerate reference (three corners in a line) is rejected', () {
    expect(
      floorCornersFromPhoto(
        reference: const [Vec2(0, 0), Vec2(1, 0), Vec2(2, 0), Vec2(3, 0)],
        ref: a4,
        corners: [photoOf(room[0])],
      ),
      isNull,
    );
  });
}
