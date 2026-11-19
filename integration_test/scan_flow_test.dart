// End-to-end test of the scan flow on a real device.
//
// The camera scanner itself (ARCore) needs someone to move the phone, so its
// answer is simulated: the 'room_measure/ar' channel returns what the native
// scanner returns after an automatic or manual scan. Everything else runs
// for real: navigation, saving to disk, floor plan, dimensions, editing.
//
// Run: flutter test integration_test -d <device>

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/units.dart';
import 'package:room_measure/main.dart';
import 'package:room_measure/services/app_settings.dart';
import 'package:room_measure/services/scan_store.dart';

const _channel = MethodChannel('room_measure/ar');

/// What the native scanner would return: room corners in ARCore world
/// space (rotated and offset, as real scans are), plus extras.
Map<String, dynamic> scannerResult(
  List<Vec2> roomCorners, {
  bool auto = true,
  int estimated = 0,
  double? height,
  List<(int, Vec2, Vec2)> openings = const [],
}) {
  Vec2 w(Vec2 p) => p.rotate(0.6) + const Vec2(1.3, -0.7);
  final cs = roomCorners.map(w).toList();
  return {
    'xs': [for (final c in cs) c.x],
    'zs': [for (final c in cs) c.y],
    'height': ?height,
    'openings': [
      for (final (t, a, b) in openings) ...[
        t.toDouble(), w(a).x, w(a).y, w(b).x, w(b).y,
      ],
    ],
    'auto': auto,
    'estimated': estimated,
  };
}

Object? nextResult;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LengthUnit savedUnit;
  late bool savedSkipGuide;
  late Set<String> roomsBefore;

  setUpAll(() async {
    await AppSettings.load();
    savedUnit = AppSettings.unit.value;
    savedSkipGuide = AppSettings.skipScanGuide;
    await AppSettings.setUnit(LengthUnit.meters);
    await AppSettings.setSkipScanGuide(false);
    roomsBefore = (await ScanStore.loadAll()).map((s) => s.id).toSet();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'measure');
      final r = nextResult;
      if (r is PlatformException) throw r;
      return r;
    });
  });

  tearDownAll(() async {
    // Leave the user's rooms and settings as they were.
    for (final s in await ScanStore.loadAll()) {
      if (!roomsBefore.contains(s.id)) await ScanStore.delete(s.id);
    }
    await AppSettings.setUnit(savedUnit);
    await AppSettings.setSkipScanGuide(savedSkipGuide);
  });

  Future<void> startScan(WidgetTester tester) async {
    await tester.pumpWidget(const RoomMeasureApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start scan'));
    await tester.pumpAndSettle();
    expect(find.text('How to scan'), findsOneWidget);
    await tester.tap(find.text('Start scanning'));
    await tester.pumpAndSettle();
  }

  Finder text(String s) => find.text(s, skipOffstage: false);

  testWidgets('automatic scan opens the plan with all dimensions',
      (tester) async {
    nextResult = scannerResult(
      const [Vec2(0, 0), Vec2(4.2, 0), Vec2(4.2, 3.6), Vec2(0, 3.6)],
      height: 2.6,
      estimated: 1,
      openings: [(0, const Vec2(1.0, 0.02), const Vec2(1.9, -0.03))],
    );
    await startScan(tester);

    // Straight to the plan, no name prompt; the estimated wall is flagged.
    expect(find.textContaining('1 wall was estimated'), findsOneWidget);
    expect(find.text('Floor area'), findsOneWidget);
    expect(text('15.12 m²'), findsOneWidget);
    expect(text('15.60 m'), findsOneWidget); // perimeter
    expect(text('4.20 m × 3.60 m'), findsOneWidget);
    expect(text('2.60 m'), findsOneWidget); // height
    expect(text('39.31 m³'), findsOneWidget); // volume
    expect(find.text('Walls (4)'), findsOneWidget);
    expect(find.text('Openings (1)'), findsOneWidget);

    // The door was placed on wall 1 with its width.
    await tester.tap(find.text('Openings (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Door on W1'), findsOneWidget);
    expect(find.text('Width 0.90 m'), findsOneWidget);

    // Unit conversion.
    await tester.tap(find.text('Summary'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('m').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Feet & inches'));
    await tester.pumpAndSettle();
    expect(text('162.8 ft²'), findsOneWidget);
    expect(text("13' 9\" × 11' 10\""), findsOneWidget);
    await tester.tap(find.text('ft-in').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metres'));
    await tester.pumpAndSettle();
    expect(text('15.12 m²'), findsOneWidget);

    // Manual adjustment: make wall 1 five metres long.
    await tester.tap(find.text('Walls (4)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change length').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '5');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Summary'));
    await tester.pumpAndSettle();
    expect(text('18.00 m²'), findsOneWidget);
    expect(text('5.00 m × 3.60 m'), findsOneWidget);

    // The edited room is saved and listed on the home screen.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('18.00 m²'), findsOneWidget);
    final saved = (await ScanStore.loadAll())
        .where((s) => !roomsBefore.contains(s.id))
        .toList();
    expect(saved, hasLength(1));
    expect(saved.single.openings, hasLength(1));
  });

  testWidgets('manually marked L-shaped room', (tester) async {
    nextResult = scannerResult(const [
      Vec2(0, 0), Vec2(6, 0), Vec2(6, 2.8),
      Vec2(3.5, 2.8), Vec2(3.5, 5), Vec2(0, 5),
    ], auto: false);
    await startScan(tester);
    expect(find.textContaining('estimated'), findsNothing);
    expect(text('24.50 m²'), findsOneWidget);
    expect(text('6.00 m × 5.00 m'), findsOneWidget);
    expect(find.text('Walls (6)'), findsOneWidget);
    expect(text('Add height'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
  });

  testWidgets('backing out of the scanner changes nothing', (tester) async {
    final before = (await ScanStore.loadAll()).length;
    nextResult = null;
    await startScan(tester);
    expect(find.text('Start scan'), findsOneWidget);
    expect(await ScanStore.loadAll(), hasLength(before));
  });

  testWidgets('scanner errors are explained', (tester) async {
    nextResult = {'error': 'Camera permission is needed to scan a room.'};
    await startScan(tester);
    expect(find.text('Scanning unavailable'), findsOneWidget);
    expect(find.text('Camera permission is needed to scan a room.'),
        findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });
}
