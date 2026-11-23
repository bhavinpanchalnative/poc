import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/ui/app_theme.dart';
import 'package:room_measure/ui/common.dart';
import 'package:room_measure/ui/plan_screen.dart';

/// Nothing gets a name by default ("Room 3", "Door 1", "Required"): the user
/// must type one, and cannot go on without it.
void main() {
  Widget host(Future<void> Function(BuildContext) onAsk) => MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () => onAsk(context), child: const Text('ask')),
        ),
      );

  testWidgets('a name box starts empty and Save stays off until a name is typed', (tester) async {
    String? result = 'not asked';
    await tester.pumpWidget(host((c) async => result = await askText(c, title: 'Name', label: 'Name')));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    expect(find.text('Required'), findsNothing);
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Hall door');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(result, 'Hall door');
  });

  testWidgets('new measurements must all be named before going on', (tester) async {
    List<String>? names;
    await tester.pumpWidget(host((c) async => names = await askNames(c,
        title: 'Name your measurements', labels: ['Window · 1.20 × 1.10 m', 'Line · 2.35 m'])));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(find.text('Window · 1.20 × 1.10 m'), findsOneWidget);
    expect(find.text('Line · 2.35 m'), findsOneWidget);
    // No way out without names: no Cancel, Back and taps outside do nothing.
    expect(find.text('Cancel'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Name your measurements'), findsOneWidget);
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField).first, 'Bedroom window');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull); // one still empty
    await tester.enterText(find.byType(TextField).last, 'Sofa');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(names, ['Bedroom window', 'Sofa']);
  });

  testWidgets('an unnamed room is named before it is saved', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final scan = scanFromCorners(
        [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
        name: '');
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: PlanScreen(scan: scan)));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsNothing);
    await tester.tap(find.text('Save room'));
    await tester.pumpAndSettle();
    expect(find.text('Name this room'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Bedroom');
    await tester.pump();
    // Saving to disk is not available in tests; the name is what matters.
    await tester.tap(find.widgetWithText(FilledButton, 'Save room').last);
    await tester.pump();
    expect(scan.name, 'Bedroom');
    await tester.pumpAndSettle();
    tester.takeException();
  });
}
