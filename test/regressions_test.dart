import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/elevation.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/engine/sample_rooms.dart';
import 'package:room_measure/engine/units.dart';
import 'package:room_measure/ui/app_theme.dart';
import 'package:room_measure/services/app_settings.dart';
import 'package:room_measure/ui/manual_entry_screen.dart';
import 'package:room_measure/ui/opening_editor_screen.dart';
import 'package:room_measure/ui/plan_painter.dart';
import 'package:room_measure/ui/plan_screen.dart';

/// Bugs found while testing the whole app.
void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  test('example rooms can be edited (their lists were const)', () {
    final s = SampleRooms.rectangle();
    s.openings.add(const Opening(type: OpeningType.door, wallIndex: 1, center: 0.5, width: 0.8));
    s.openings.removeAt(0);
    s.walls.add(s.walls.first);
    expect(s.openings, hasLength(2));
    // The next example is unaffected.
    expect(SampleRooms.rectangle().openings, hasLength(2));
  });

  testWidgets('an edit that breaks the plan is undone, not saved', (tester) async {
    phone(tester);
    final scan = scanFromCorners(
        [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
        name: 'Den');
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: PlanScreen(scan: scan)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Walls (4)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change length').first);
    await tester.pumpAndSettle();
    // 1 mm: too short to give the wall a direction.
    await tester.enterText(find.byType(TextField), '0.001');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't build a floor plan"), findsNothing);
    expect(find.textContaining('That change was undone'), findsOneWidget);
    expect(find.text('Walls (4)'), findsOneWidget);
  });

  test('feet and inches typed with curly quotes (iOS) are understood', () {
    final straight = parseLength('11\' 4"', LengthUnit.feetInches)!;
    expect(parseLength('11’ 4”', LengthUnit.feetInches), closeTo(straight, 1e-9));
    expect(parseLength('11′4″', LengthUnit.feetInches), closeTo(straight, 1e-9));
  });

  test('a door can be made taller than the drawing\'s backdrop wall', () {
    final scan = scanFromCorners(
      [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
      name: 'Hall',
      openings: const [MarkedOpening(OpeningType.door, Vec2(1, 0), Vec2(1.9, 0), height: 2.1)],
    );
    final p = const FloorPlanBuilder().build(scan);
    final e = OpeningElevation.of(p, p.openings.single);
    final tall = e.withEdge(OpeningEdge.top, 2.9);
    expect(tall.height, closeTo(2.9, 1e-9));
    expect(tall.wallHeight, greaterThanOrEqualTo(2.9));
  });

  testWidgets('leaving a field unchanged keeps an unmeasured height unmeasured', (tester) async {
    phone(tester);
    final scan = scanFromCorners(
      [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
      name: 'Hall',
      openings: const [MarkedOpening(OpeningType.door, Vec2(1, 0), Vec2(1.9, 0))],
    );
    final p = const FloorPlanBuilder().build(scan);
    OpeningEdit? result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () async => result = await Navigator.push<OpeningEdit>(
              c,
              MaterialPageRoute(
                  builder: (_) =>
                      OpeningEditorScreen(plan: p, opening: p.openings.single, label: 'Door 1'))),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Into the Height field and out again without typing.
    await tester.tap(find.widgetWithText(TextField, 'Height'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.opening?.height, isNull);
  });

  test('door labels keep clear of the room\'s area in a small room', () {
    // Just check painting a small room with a door and window throws nothing.
    final scan = scanFromCorners(
      [Vec2.zero, const Vec2(3, 0), const Vec2(3, 2.6), const Vec2(0, 2.6)],
      name: 'Box',
      openings: const [
        MarkedOpening(OpeningType.door, Vec2(1, 0), Vec2(1.9, 0), height: 2.03),
        MarkedOpening(OpeningType.window, Vec2(1, 2.6), Vec2(2, 2.6), height: 1.1, sill: 0.9),
      ],
    );
    final p = const FloorPlanBuilder().build(scan);
    final recorder = PictureRecorder();
    PlanPainter(plan: p, unit: LengthUnit.meters).paint(Canvas(recorder), const Size(380, 320));
    recorder.endRecording();
  });
  testWidgets('custom walls that don\x27t close are reported, not changed', (tester) async {
    phone(tester);
    AppSettings.unit.value = LengthUnit.meters;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(), home: const ManualEntryScreen(defaultName: '')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom shape'));
    await tester.pumpAndSettle();
    for (final (i, v) in ['3', '2', '4', '2'].indexed) {
      await tester.enterText(find.widgetWithText(TextField, 'Wall ${i + 1}'), v);
      await tester.pump();
    }
    await tester.scrollUntilVisible(find.textContaining("The walls don't meet"), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining("The walls don't meet"), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-plan-preview')), findsNothing);
  });

  testWidgets('leaving manual entry with typed values asks first', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () => Navigator.push(c,
              MaterialPageRoute(builder: (_) => const ManualEntryScreen(defaultName: ''))),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Length'), '4');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard these measurements?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });
}
