import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/elevation.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/ui/opening_drawing_screen.dart';

void main() {
  final at = DateTime(2026, 11, 19, 10);
  final marked = [
    const MarkedOpening(OpeningType.door, Vec2(0, 0), Vec2(0.82, 0),
        height: 2.03, method: OpeningMethod.auto),
    const MarkedOpening(OpeningType.window, Vec2(2, 0), Vec2(3.2, 0),
        height: 1.1, sill: 0.9, method: OpeningMethod.auto, estimated: true),
    const MarkedOpening(OpeningType.door, Vec2(4, 0), Vec2(4.9, 0)),
  ];

  test('doors and windows without a room are kept with their size', () {
    final loose = looseOpeningsFrom(marked, at);
    expect(loose.map((o) => o.name), ['Door 1', 'Window 1', 'Door 2']);
    expect(loose[0].width, closeTo(0.82, 1e-9));
    expect(loose[0].height, 2.03);
    expect(loose[1].sill, 0.9);
    expect(loose[1].estimated, isTrue);
    expect(loose[2].height, isNull);
    // Unique ids, and they survive saving.
    expect(loose.map((o) => o.id).toSet(), hasLength(3));
    final back = SavedOpening.fromJson(
        jsonDecode(jsonEncode(loose[1].toJson())) as Map<String, dynamic>);
    expect(back.name, 'Window 1');
    expect(back.sill, 0.9);
    expect(back.estimated, isTrue);
    expect(back.measuredAt, at);
  });

  test('the ✓ that finished the scan picks its door or window', () {
    final c = CapturedScan(
      scanFromCorners(const [], name: 'R', openings: marked),
      focusOpening: 1,
      looseOpenings: looseOpeningsFrom(marked, at),
    );
    expect(c.hasRoom, isFalse);
    expect(c.looseOpenings[c.focusOpening!].type, OpeningType.window);
  });

  test('a stand-alone front view has only the opening\'s own dimensions', () {
    final e = OpeningElevation.standalone(
        type: OpeningType.window, width: 1.2, height: 1.1, sill: 0.9);
    expect(e.standalone, isTrue);
    expect(e.width, 1.2);
    expect(e.sill, 0.9);
    expect(e.head, closeTo(2.0, 1e-9));
    expect(e.left, greaterThan(0));
    expect(e.wallHeight, greaterThan(e.head));
    // Edits keep it stand-alone.
    expect(e.withEdge(OpeningEdge.right, e.right + 0.1).standalone, isTrue);
    final d = OpeningElevation.standalone(type: OpeningType.door, width: 0.9);
    expect(d.sill, 0);
    expect(d.heightAssumed, isTrue);
  });

  testWidgets('the drawing screen shows the measurements', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final w = looseOpeningsFrom(marked, at)[1];
    await tester.pumpWidget(MaterialApp(
        home: OpeningDrawingScreen(opening: w, justScanned: true)));
    await tester.pumpAndSettle();
    expect(find.text('Window measured'), findsOneWidget);
    expect(find.text('Width'), findsOneWidget);
    expect(find.text('Sill height'), findsOneWidget);
    expect(find.text('≈ 1.20 m'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
