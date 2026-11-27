import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/engine/sample_rooms.dart';
import 'package:room_measure/main.dart';
import 'package:room_measure/ui/plan_screen.dart';
import 'package:room_measure/ui/app_theme.dart';

void main() {
  testWidgets('home screen shows the main actions', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const RoomMeasureApp());
    // Saved rooms load from disk (real I/O), so don't wait for it to settle.
    await tester.pump(const Duration(milliseconds: 300));
    // The ECM-AI logo image in the app bar.
    expect(find.bySemanticsLabel('ECM-AI'), findsOneWidget);
    // Measure and History pages.
    expect(find.text('Measure'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Example bedroom'), findsOneWidget);
    // No camera scanning in the test environment: manual entry is offered.
    expect(find.text('Enter dimensions'), findsOneWidget);
  });

  testWidgets('plan screen shows measurements and tabs', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: PlanScreen(scan: SampleRooms.rectangle()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Floor area'), findsOneWidget);
    // Room height is no longer measured or shown anywhere.
    expect(find.textContaining('Ceiling'), findsNothing);
    expect(find.text('Volume'), findsNothing);
    // Doors and windows are counted.
    expect(find.text('Doors'), findsOneWidget);
    expect(find.text('Windows'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('1 × Window'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Found in this room'), findsOneWidget);
    expect(find.text('1 × Door'), findsOneWidget);
    expect(find.text('1 × Window'), findsOneWidget);
    expect(find.text('Walls (4)'), findsOneWidget);
    expect(find.text('Save room'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a completed scan opens with the "Room scanned" check',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: PlanScreen(scan: SampleRooms.rectangle(), justScanned: true),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Room scanned'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Room scanned'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
