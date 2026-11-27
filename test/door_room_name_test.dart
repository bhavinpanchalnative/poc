import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/ui/app_theme.dart';
import 'package:room_measure/ui/common.dart';
import 'package:room_measure/ui/opening_drawing_screen.dart';
import 'package:room_measure/ui/opening_editor_screen.dart';
import 'package:room_measure/ui/plan_screen.dart';

/// Selecting or creating a door or window shows the room it is in.
void main() {
  RoomScan kitchen() => scanFromCorners(
        [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
        name: 'Kitchen',
        openings: const [
          MarkedOpening(OpeningType.door, Vec2(0.5, 0), Vec2(1.32, 0),
              height: 2.03, method: OpeningMethod.auto),
        ],
      );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  testWidgets('the door editor shows its room', (tester) async {
    phone(tester);
    final scan = kitchen();
    final plan = const FloorPlanBuilder().build(scan);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: OpeningEditorScreen(
          plan: plan, opening: plan.openings.single, label: 'Door 1', roomName: scan.name),
    ));
    await tester.pumpAndSettle();
    final sub = tester.widget<Text>(find.byKey(const Key('opening-room')));
    expect(sub.data, startsWith('Kitchen'));
    expect(sub.data, contains('Door on wall W1'));
  });

  testWidgets('selecting a door on the plan opens it with the room name', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: PlanScreen(scan: kitchen())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Openings (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Door 1 on W1'));
    await tester.pumpAndSettle();
    expect(find.byType(OpeningEditorScreen), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('opening-room'))).data, startsWith('Kitchen'));
  });

  testWidgets('a door measured without an outline shows the room it was given', (tester) async {
    phone(tester);
    final o = SavedOpening(
      id: '1',
      name: 'Front door',
      room: 'Hall',
      type: OpeningType.door,
      width: 0.86,
      height: 2.04,
      measuredAt: DateTime(2026, 11, 24),
    );
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: OpeningDrawingScreen(opening: o)));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('opening-room'))).data, startsWith('Hall'));
    expect(find.text('Room'), findsOneWidget);
    // The room is kept when saved and loaded.
    final back = SavedOpening.fromJson(jsonDecode(jsonEncode(o.toJson())) as Map<String, dynamic>);
    expect(back.room, 'Hall');
    // Older saves without a room still load.
    final old = o.toJson()..remove('room');
    expect(SavedOpening.fromJson(old).room, '');
  });

  testWidgets('the name dialog can start with the last room filled in', (tester) async {
    List<String>? names;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () async => names = await askNames(c,
              title: 'Name this door', labels: ['Room', 'Door · 0.86 m'], initial: ['Hall']),
          child: const Text('ask'),
        ),
      ),
    ));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, 'Hall');
    await tester.enterText(find.byType(TextField).last, 'Front door');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(names, ['Hall', 'Front door']);
  });
}
