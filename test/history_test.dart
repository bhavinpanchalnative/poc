import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/ui/app_theme.dart';
import 'package:room_measure/ui/history_view.dart';

void main() {
  testWidgets('History tabs show each category with its count', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final opened = <String>[];
    HistoryItem item(HistoryKind k, String title, {int daysAgo = 0}) => HistoryItem(
          kind: k,
          title: title,
          subtitle: 'sub',
          value: '1.00 m',
          date: DateTime.now().subtract(Duration(days: daysAgo)),
          onTap: () => opened.add(title),
        );
    var newMap = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: HistoryView(
          loading: false,
          items: [
            item(HistoryKind.room, 'Kitchen'),
            item(HistoryKind.door, 'Door 1', daysAgo: 1),
            item(HistoryKind.door, 'Door 2', daysAgo: 9),
            item(HistoryKind.window, 'Window 1'),
            item(HistoryKind.line, 'Line 1'),
          ],
          emptyActions: {
            HistoryKind.map: HistoryEmptyAction('New map', Icons.add, () => newMap++),
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // All tab: everything, grouped by when it was measured.
    for (final t in ['All', 'Rooms', 'Doors', 'Windows', 'Lines', 'Surfaces', 'Floor maps']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Kitchen'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('EARLIER'), findsOneWidget);

    // Doors tab: only doors; tapping opens one.
    await tester.tap(find.text('Doors'));
    await tester.pumpAndSettle();
    expect(find.text('Door 1'), findsOneWidget);
    expect(find.text('Door 2'), findsOneWidget);
    expect(find.text('Kitchen'), findsNothing);
    await tester.tap(find.text('Door 2'));
    expect(opened, ['Door 2']);

    // An empty tab offers its action.
    // The last tab is off screen at first: the tab row scrolls.
    await tester.ensureVisible(find.text('Floor maps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Floor maps'));
    await tester.pumpAndSettle();
    expect(find.text('No floor maps yet'), findsOneWidget);
    await tester.tap(find.text('New map'));
    expect(newMap, 1);
    expect(tester.takeException(), isNull);
  });
}
