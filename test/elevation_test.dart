import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/capture/ar_measure.dart';
import 'package:room_measure/engine/elevation.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/engine/units.dart';
import 'package:room_measure/services/plan_exporter.dart';
import 'package:room_measure/ui/opening_editor_screen.dart';

/// A 4.0 x 3.0 m room, 2.5 m high, with a door and a window on wall W1.
FloorPlan plan() {
  final scan = scanFromCorners(
    [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
    name: 'Room',
    height: 2.5,
    openings: const [
      MarkedOpening(OpeningType.door, Vec2(0.5, 0), Vec2(1.32, 0),
          height: 2.03, method: OpeningMethod.auto),
      MarkedOpening(OpeningType.window, Vec2(2.2, 0), Vec2(3.4, 0),
          height: 1.1, sill: 0.9, method: OpeningMethod.touch, estimated: true),
    ],
  );
  return const FloorPlanBuilder().build(scan);
}

void main() {
  test('front view of a door: position along the wall and every dimension', () {
    final p = plan();
    final door = p.openings.firstWhere((o) => o.type == OpeningType.door);
    final e = OpeningElevation.of(p, door);
    expect(e.wallLength, closeTo(4.0, 1e-6));
    expect(e.wallHeight, 2.5);
    expect(e.width, closeTo(0.82, 1e-6));
    expect(e.height, 2.03);
    expect(e.sill, 0);
    // 0.5 m from one corner, 2.68 m from the other (which one depends on
    // the wall's direction in the plan).
    expect({e.left.toStringAsFixed(2), e.rightGap.toStringAsFixed(2)},
        {'0.50', '2.68'});
    expect(door.method, OpeningMethod.auto);
  });

  test('front view of a window keeps its sill and estimate flag', () {
    final p = plan();
    final w = p.openings.firstWhere((o) => o.type == OpeningType.window);
    final e = OpeningElevation.of(p, w);
    expect(e.sill, 0.9);
    expect(e.head, closeTo(2.0, 1e-9));
    expect(e.estimated, isTrue);
    expect(w.method, OpeningMethod.touch);
  });

  test('dragging edges edits the measurements, within the wall', () {
    final p = plan();
    final w = p.openings.firstWhere((o) => o.type == OpeningType.window);
    var e = OpeningElevation.of(p, w);
    final left = e.left;
    e = e.withEdge(OpeningEdge.right, e.right + 0.10); // 10 cm wider
    expect(e.width, closeTo(1.30, 1e-9));
    expect(e.left, left);
    e = e.withEdge(OpeningEdge.bottom, 0.80); // sill down 10 cm, top stays
    expect(e.sill, closeTo(0.80, 1e-9));
    expect(e.head, closeTo(2.0, 1e-9));
    e = e.withEdge(OpeningEdge.top, 9); // can't go above the ceiling
    expect(e.head, closeTo(2.5, 1e-9));
    e = e.withEdge(OpeningEdge.left, e.right + 1); // can't cross the other edge
    expect(e.width, closeTo(OpeningElevation.minSize, 1e-9));

    final saved = e.toOpening(w);
    expect(saved.sill, closeTo(0.80, 1e-9));
    expect(saved.method, OpeningMethod.touch);
    // Stored back as a position along the wall and survives a rebuild.
    final again = OpeningElevation.of(p, saved);
    expect(again.left, closeTo(e.left, 1e-9));
    expect(again.width, closeTo(e.width, 1e-9));
  });

  test("a door's bottom stays on the floor", () {
    final p = plan();
    final door = p.openings.firstWhere((o) => o.type == OpeningType.door);
    final e = OpeningElevation.of(p, door).withEdge(OpeningEdge.bottom, 0.5);
    expect(e.sill, 0);
  });

  test('unmeasured heights are shown as typical and flagged', () {
    final scan = scanFromCorners(
      [Vec2.zero, const Vec2(4, 0), const Vec2(4, 3), const Vec2(0, 3)],
      name: 'Room',
      openings: const [MarkedOpening(OpeningType.window, Vec2(1, 0), Vec2(2, 0))],
    );
    final p = const FloorPlanBuilder().build(scan);
    final e = OpeningElevation.of(p, p.openings.single);
    expect(e.heightAssumed, isTrue);
    expect(e.sillAssumed, isTrue);
    expect(e.wallHeightAssumed, isTrue);
    // Saving without editing keeps them unmeasured.
    final o = e.toOpening(p.openings.single);
    expect(o.height, isNull);
    expect(o.sill, isNull);
  });

  test('how an opening was measured is saved with it', () {
    final o = plan().openings.last;
    final back = Opening.fromJson(
        jsonDecode(jsonEncode(o.toJson())) as Map<String, dynamic>);
    expect(back.method, o.method);
    expect(back.estimated, o.estimated);
    // Older files without the fields.
    final old = o.toJson()
      ..remove('method')
      ..remove('estimated');
    expect(Opening.fromJson(old).method, OpeningMethod.typed);
  });

  test('scanner codes: auto, touch and estimate flags', () {
    final list = parseOpeningDetails(
      [
        0, 0, -1.4, 0, 0.9, -1.4, 0, 0.63, // door with top
        1, 2, -0.5, 0, 3.2, -0.5, 0, 0.6, // window
      ],
      -1.4,
      methods: [1, 2],
      estimated: [0, 1],
    );
    expect(list[0].method, OpeningMethod.auto);
    expect(list[0].height, closeTo(2.03, 1e-9));
    expect(list[1].method, OpeningMethod.touch);
    expect(list[1].estimated, isTrue);
    expect(list[1].sill, closeTo(0.9, 1e-9));
  });

  test('front views render for the PDF, in every unit', () async {
    final p = plan();
    for (final o in p.openings) {
      for (final u in LengthUnit.values) {
        final png = await PlanExporter.renderElevationPng(
            OpeningElevation.of(p, o), u,
            title: 'Test', size: const Size(500, 360));
        expect(png.length, greaterThan(1000));
        expect(png.sublist(1, 4), Uint8List.fromList([0x50, 0x4E, 0x47]));
      }
    }
    final pdf = await PlanExporter.buildPdf(
        RoomScan(id: 'x', name: 'R', createdAt: DateTime(2026),
            source: CaptureSource.arTap,
            walls: [for (var i = 0; i < 4; i++)
                WallLine(p.wallStart(i), p.wallEnd(i))],
            openings: List.of(p.openings), height: 2.5),
        p,
        LengthUnit.meters);
    expect(pdf.length, greaterThan(10000));
  });

  testWidgets('the editor shows the front view and saves edits', (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final p = plan();
    final w = p.openings.firstWhere((o) => o.type == OpeningType.window);
    OpeningEdit? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await Navigator.push<OpeningEdit>(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      OpeningEditorScreen(plan: p, opening: w, label: 'Window 1')),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Window 1'), findsOneWidget);
    expect(find.text('Sill height'), findsOneWidget);

    // Type a new width and save.
    await tester.enterText(find.widgetWithText(TextFormField, 'Width'), '1.50');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.delete, isFalse);
    expect(result!.opening!.width, closeTo(1.50, 1e-9));
    expect(tester.takeException(), isNull);
  });

  test('a door measured by touch takes its height from its own floor taps',
      () {
    // The camera is 4 cm above the phone's corner at every tap: the taps at
    // the floor are at floor + 0.04, the top tap at 2.03 + 0.04. Measured
    // from the taps the offset cancels; from the detected floor it would
    // not.
    final touched = parseOpeningDetails(
      [0, 0, -1.36, 0, 0.82, -1.36, 0, -1.4 + 2.07],
      -1.4,
      methods: [2],
    ).single;
    expect(touched.height, closeTo(2.03, 1e-9));
    final marked = parseOpeningDetails(
      [0, 0, -1.4, 0, 0.82, -1.4, 0, -1.4 + 2.03],
      -1.4,
      methods: [0],
    ).single;
    expect(marked.height, closeTo(2.03, 1e-9));
  });
}
