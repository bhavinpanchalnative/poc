import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/engine/plan_editor.dart';
import 'package:room_measure/ui/app_theme.dart';
import 'package:room_measure/ui/plan_painter.dart';
import 'package:room_measure/ui/plan_screen.dart';

/// The circles on the plan (room corners, the ends of measured lines) can be
/// dragged to adjust a measurement, without switching to Edit shape.
void main() {
  test('moving a line end changes its length and keeps its height part', () {
    // 3 m across the floor and 4 m up: 5 m.
    const l = MeasuredLine(
        name: 'L', length: 5, run: 3, rise: 4, footprint: [Vec2(0, 0), Vec2(3, 0)]);
    final m = PlanEditor.movedLineEnd(l, 1, const Vec2(6, 0));
    expect(m.run, closeTo(6, 1e-9));
    expect(m.rise, closeTo(4, 1e-9));
    expect(m.length, closeTo(7.2111, 1e-4));
    expect(m.footprint, [const Vec2(0, 0), const Vec2(6, 0)]);

    // A flat line saved without its parts: just the new distance.
    const flat = MeasuredLine(name: 'F', length: 2, footprint: [Vec2(1, 1), Vec2(3, 1)]);
    final f = PlanEditor.movedLineEnd(flat, 0, const Vec2(0, 1));
    expect(f.length, closeTo(3, 1e-9));
  });

  test('a moved line end is saved with the room', () {
    final scan = scanFromCorners(
        [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
        name: 'Room',
        lines: [const MeasuredLine(name: 'L', length: 2, footprint: [Vec2(1, 1), Vec2(3, 1)])]);
    final plan = const FloorPlanBuilder().build(scan);
    final a = plan.lines.single.footprint[0];
    PlanEditor.moveLineEnd(scan, plan, 0, 1, a + const Vec2(2.5, 0));
    final again = const FloorPlanBuilder().build(scan);
    expect(again.lines.single.length, closeTo(2.5, 1e-6));
    expect(again.overallSize.width, closeTo(plan.overallSize.width, 1e-6));
  });

  group('on the plan screen', () {
    late RoomScan scan;

    Finder canvas() => find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PlanPainter);

    PlanPainter painter(WidgetTester tester) =>
        tester.widget<CustomPaint>(canvas()).painter! as PlanPainter;

    Future<PlanPainter> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      scan = scanFromCorners(
          [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
          name: 'Room',
          lines: [const MeasuredLine(name: 'L', length: 2, footprint: [Vec2(1, 1.5), Vec2(3, 1.5)])]);
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: PlanScreen(scan: scan)));
      await tester.pumpAndSettle();
      return painter(tester);
    }

    /// Screen position of plan point [p].
    Offset at(WidgetTester tester, PlanPainter pp, Vec2 p) =>
        tester.getTopLeft(canvas()) + pp.layout!.toScreen(p);

    Future<void> drag(WidgetTester tester, Offset from, Offset by) async {
      final g = await tester.startGesture(from);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(from + by * (i / 10));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    testWidgets('a corner circle drags without Edit shape', (tester) async {
      final pp = await open(tester);
      expect(pp.handles, isTrue);
      final before = const FloorPlanBuilder().build(scan).area;
      final corner = pp.plan.corners[2];
      await drag(tester, at(tester, pp, corner), const Offset(45, 0));
      final after = const FloorPlanBuilder().build(scan).area;
      expect(after, isNot(closeTo(before, 0.05)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a line end circle drags and the length follows', (tester) async {
      final pp = await open(tester);
      final end = pp.plan.lines.single.footprint[1];
      final px = pp.layout!.scale; // pixels per metre
      await drag(tester, at(tester, pp, end), Offset(0.5 * px, 0));
      expect(scan.lines.single.length, closeTo(2.5, 0.03));
      expect(tester.takeException(), isNull);
    });

    testWidgets('dragging away from the circles changes nothing', (tester) async {
      final pp = await open(tester);
      final before = const FloorPlanBuilder().build(scan);
      // The middle of the room, between the line and the walls.
      await drag(tester, at(tester, pp, const Vec2(2, 0.6)), const Offset(40, 30));
      final after = const FloorPlanBuilder().build(scan);
      expect(after.area, closeTo(before.area, 1e-9));
      expect(scan.lines.single.length, 2);
    });
  });
}
