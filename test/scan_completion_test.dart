import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';

List<WallLine> rect(double w, double d, {double gap = 0.05}) => [
      WallLine(const Vec2(0, 0), Vec2(w - gap, 0)),
      WallLine(Vec2(w, gap), Vec2(w, d - gap)),
      WallLine(Vec2(w - gap, d), Vec2(gap, d)),
      WallLine(Vec2(0, d - gap), Vec2(0, gap)),
    ];

void main() {
  test('a room is complete when its walls close around it', () {
    expect(isClosedOutline(rect(4.2, 3.6)), isTrue);
    // One wall not scanned yet: the outline is open.
    expect(isClosedOutline(rect(4.2, 3.6).take(3).toList()), isFalse);
    // Walls that stop well short of each other: not finished.
    expect(isClosedOutline(rect(4.2, 3.6, gap: 0.6)), isFalse);
    // Too small to be a room (e.g. a cupboard).
    expect(isClosedOutline(rect(1.0, 1.0)), isFalse);
  });

  test('a LiDAR scan finishes once the closed outline holds steady', () {
    final w = LidarCompletion(hold: const Duration(seconds: 3));
    final t0 = DateTime(2026, 1, 1, 12);
    // Still scanning: three walls.
    expect(w.update(rect(4.2, 3.6).take(3).toList(), t0), isFalse);
    // Closed, but has to hold steady first.
    expect(w.update(rect(4.2, 3.6), t0.add(const Duration(seconds: 1))), isFalse);
    expect(w.update(rect(4.2, 3.6), t0.add(const Duration(seconds: 3))), isFalse);
    // The room grows as a wall is refined: the wait starts again.
    expect(w.update(rect(4.5, 3.6), t0.add(const Duration(seconds: 4))), isFalse);
    expect(w.update(rect(4.5, 3.6), t0.add(const Duration(seconds: 6))), isFalse);
    expect(w.update(rect(4.5, 3.6), t0.add(const Duration(seconds: 7, milliseconds: 100))),
        isTrue);
    // Only once.
    expect(w.update(rect(4.5, 3.6), t0.add(const Duration(seconds: 9))), isFalse);
  });

  test('a LiDAR scan waits until the user has looked all the way round', () {
    final w = LidarCompletion(hold: const Duration(seconds: 3));
    final t0 = DateTime(2026, 1, 1, 12);
    Duration s(int n) => Duration(seconds: n);
    // Closed and steady, but only half the room looked at: doors and windows
    // on the other walls would be missed.
    expect(w.update(rect(4.2, 3.6), t0, sectorsSeen: 6), isFalse);
    expect(w.update(rect(4.2, 3.6), t0.add(s(4)), sectorsSeen: 6), isFalse);
    expect(w.update(rect(4.2, 3.6), t0.add(s(8)), sectorsSeen: 9), isFalse);
    // Turned round to every wall: finishes (it has held steady long since).
    expect(
        w.update(rect(4.2, 3.6), t0.add(s(9)),
            sectorsSeen: LidarCompletion.lookRoundSectors),
        isTrue);
  });

  test('walls arriving in any order are recognised as a closed room', () {
    final shuffled = rect(4.2, 3.6);
    final mixed = [shuffled[2], shuffled[0].reversed(), shuffled[3], shuffled[1]];
    final w = LidarCompletion(hold: Duration.zero);
    final t0 = DateTime(2026);
    expect(w.update(mixed, t0), isFalse); // first sight starts the clock
    expect(w.update(mixed, t0.add(const Duration(milliseconds: 1))), isTrue);
  });
}
