import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/engine/units.dart';
import 'package:room_measure/services/app_settings.dart';
import 'package:room_measure/ui/app_theme.dart';
import 'package:room_measure/ui/manual_entry_screen.dart';
import 'package:room_measure/ui/plan_painter.dart';

/// Typing a room's dimensions draws its floor plan straight away.
void main() {
  testWidgets('the floor plan appears as soon as the dimensions are typed', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    AppSettings.unit.value = LengthUnit.meters;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(), home: const ManualEntryScreen(defaultName: '')));
    await tester.pumpAndSettle();

    final preview = find.byKey(const ValueKey('manual-plan-preview'));
    expect(preview, findsNothing);
    expect(find.text('Enter the length and width to see the floor plan.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Length'), '4.2');
    await tester.pump();
    expect(preview, findsNothing); // width still missing
    await tester.enterText(find.widgetWithText(TextField, 'Width'), '3.6');
    await tester.pump();
    expect(preview, findsOneWidget);
    PlanPainter painter() => tester.widget<CustomPaint>(preview).painter! as PlanPainter;
    expect(painter().plan.area, closeTo(4.2 * 3.6, 0.01));

    // It follows every change.
    await tester.enterText(find.widgetWithText(TextField, 'Width'), '3');
    await tester.pump();
    expect(painter().plan.area, closeTo(4.2 * 3, 0.01));
    expect(tester.takeException(), isNull);
  });
}
