import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:roomplan_flutter/roomplan_flutter.dart' as rp;

import '../engine/floor_plan_builder.dart';
import '../engine/geometry.dart';
import '../engine/measure3d.dart';
import '../engine/models.dart';
import '../services/scan_store.dart';
import 'roomplan_mapper.dart';

const _channel = MethodChannel('room_measure/ar');

/// How this device can scan a room with its camera.
enum ScanMethod {
  /// Guided camera scan with floor, wall and corner detection: ARCore on
  /// Android, ARKit on iPhones and iPads without LiDAR.
  guided,

  /// iPhone/iPad with LiDAR: Apple RoomPlan, fully automatic.
  lidar,

  /// No camera scanning; manual entry only.
  none,
}

/// A scan that could not be completed, with a message for the user.
class ScanFailure implements Exception {
  ScanFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An opening marked in AR by its two edges on the floor plan, with its
/// height and sill when they were measured.
class MarkedOpening {
  const MarkedOpening(this.type, this.a, this.b,
      {this.height,
      this.sill,
      this.method = OpeningMethod.manual,
      this.estimated = false});
  final OpeningType type;
  final Vec2 a, b;
  final double? height, sill;
  final OpeningMethod method;
  final bool estimated;
}

/// Turns corners marked in order around a room into its walls, and places
/// each marked door or window on the wall nearest to it.
RoomScan scanFromCorners(
  List<Vec2> corners, {
  required String name,
  double? height,
  List<MarkedOpening> openings = const [],
  List<MeasuredSurface> surfaces = const [],
  List<MeasuredLine> lines = const [],
  CaptureSource source = CaptureSource.arTap,
}) {
  final n = corners.length;
  final walls = [
    for (var i = 0; i < n; i++) WallLine(corners[i], corners[(i + 1) % n]),
  ];
  return RoomScan(
    id: RoomScan.newId(),
    name: name,
    createdAt: DateTime.now(),
    source: source,
    walls: walls,
    // Without a room outline (only distances were measured) there is no
    // wall to put a door or window on.
    openings: n < 3 ? [] : [for (final o in openings) placeOpening(walls, o)],
    surfaces: List.of(surfaces),
    lines: List.of(lines),
    height: height,
  );
}

/// Snaps a marked opening onto its wall: the wall nearest to its middle,
/// with the width measured along that wall.
Opening placeOpening(List<WallLine> walls, MarkedOpening o) {
  final loc = locateOnWalls(walls, (o.a + o.b) / 2);
  final wall = walls[loc.wallIndex];
  final along = (o.b - o.a).dot(wall.dir).abs();
  final width = along > 0.2 ? along : o.a.distanceTo(o.b);
  return Opening(
    type: o.type,
    wallIndex: loc.wallIndex,
    center: loc.t,
    width: width,
    height: o.height,
    sill: o.sill,
    method: o.method,
    estimated: o.estimated,
  );
}

/// Scanner codes for how each door/window was measured.
OpeningMethod openingMethodFromCode(int code) => switch (code) {
      1 => OpeningMethod.auto,
      2 => OpeningMethod.touch,
      _ => OpeningMethod.manual,
    };

/// Doors and windows from the scanner's detailed list: 8 values each (type,
/// both bottom corners in 3D, and the top's height or -999 when no top was
/// marked).
List<MarkedOpening> parseOpeningDetails(List<double> raw, double? floorY,
        {List<int> methods = const [], List<int> estimated = const []}) =>
    [
      for (var i = 0; i + 7 < raw.length; i += 8)
        () {
          final k = i ~/ 8;
          final type = raw[i] == 1 ? OpeningType.window : OpeningType.door;
          final a = Vec3(raw[i + 1], raw[i + 2], raw[i + 3]);
          final b = Vec3(raw[i + 4], raw[i + 5], raw[i + 6]);
          final top = raw[i + 7] <= -900 ? null : raw[i + 7];
          final method =
              openingMethodFromCode(k < methods.length ? methods[k] : 0);
          // A door measured by touch has its height from its own
          // floor-level taps (the phone's offset cancels out), not from the
          // detected floor.
          final h = openingHeights(type, a, b,
              topY: top,
              floorY: floorY,
              baseFromPoints:
                  type == OpeningType.door && method == OpeningMethod.touch);
          return MarkedOpening(type, a.plan, b.plan,
              height: h.height,
              sill: h.sill,
              method: method,
              estimated: k < estimated.length && estimated[k] != 0);
        }(),
    ];

/// Point-to-point distances from the scanner: 6 values each, the two marked
/// points in 3D. [estimated] flags (0/1 per line) mark lines with an end on
/// a surface the phone could only estimate.
List<MeasuredLine> parseLines(List<double> raw,
        {DateTime? at, int first = 1, List<int> estimated = const []}) =>
    [
      for (var i = 0; i + 5 < raw.length; i += 6)
        lineFromPoints(
          Vec3(raw[i], raw[i + 1], raw[i + 2]),
          Vec3(raw[i + 3], raw[i + 4], raw[i + 5]),
          // No automatic name: the user names it.
          name: '',
          at: at,
          estimated: i ~/ 6 < estimated.length && estimated[i ~/ 6] != 0,
        ),
    ];

List<int> _flags(Object? raw) =>
    [for (final v in (raw as List?) ?? const []) (v as num).toInt()];

/// Surfaces from the scanner: 9 values each, three marked points in 3D.
List<MeasuredSurface> parseSurfaces(List<double> raw, double? floorY) => [
      for (var i = 0; i + 8 < raw.length; i += 9)
        surfaceFromPoints(
          Vec3(raw[i], raw[i + 1], raw[i + 2]),
          Vec3(raw[i + 3], raw[i + 4], raw[i + 5]),
          Vec3(raw[i + 6], raw[i + 7], raw[i + 8]),
          name: '',
          floorY: floorY,
        ),
    ];

/// The result of a camera scan.
class CapturedScan {
  const CapturedScan(this.scan,
      {this.automatic = false,
      this.estimatedWalls = 0,
      this.complete = false,
      this.focusOpening,
      this.looseOpenings = const []});

  final RoomScan scan;

  /// The outline was found automatically (no corners tapped).
  final bool automatic;

  /// Sides of the room that were inferred because no wall was seen there.
  final int estimatedWalls;

  /// Every wall of the room was measured: the scan finished on its own (or
  /// could have), with nothing estimated.
  final bool complete;

  /// False when only distances or doors / windows were measured, with no
  /// room outline: [scan] then just carries its lines, and the doors and
  /// windows are in [looseOpenings].
  bool get hasRoom => scan.walls.length >= 3;

  /// The door / window whose ✓ finished the scan (its index in
  /// scan.openings, or in [looseOpenings] when there is no room): its
  /// front-view drawing is shown first.
  final int? focusOpening;

  /// Doors and windows measured without a room around them.
  final List<SavedOpening> looseOpenings;
}

/// Doors and windows measured when no room outline was found, kept on their
/// own with their measured size.
List<SavedOpening> looseOpeningsFrom(List<MarkedOpening> marked, DateTime at) {
  return [
    for (final (k, o) in marked.indexed)
      SavedOpening(
        id: '${at.microsecondsSinceEpoch}_$k',
        // No automatic name (such as Door 1): the user names it.
        name: '',
        type: o.type,
        width: o.a.distanceTo(o.b),
        height: o.height,
        sill: o.sill,
        method: o.method,
        estimated: o.estimated,
        measuredAt: at,
      ),
  ];
}

class RoomScanner {
  static Future<ScanMethod> availableMethod() async {
    if (kIsWeb) return ScanMethod.none;
    if (Platform.isAndroid) return ScanMethod.guided;
    if (Platform.isIOS) {
      // LiDAR devices use Apple RoomPlan (fully automatic); other iPhones
      // and iPads use the guided ARKit scanner.
      try {
        if (await rp.RoomPlanScanner.isSupported()) return ScanMethod.lidar;
      } catch (_) {}
      try {
        final ok = await _channel.invokeMethod<bool>('isSupported');
        return ok == true ? ScanMethod.guided : ScanMethod.none;
      } catch (_) {
        return ScanMethod.none;
      }
    }
    return ScanMethod.none;
  }

  /// Runs a camera scan. Returns null when the user backs out, throws
  /// [ScanFailure] when scanning is not possible.
  static Future<CapturedScan?> scan(ScanMethod method,
          {required String name}) =>
      switch (method) {
        ScanMethod.guided => _guided(name),
        ScanMethod.lidar => _lidar(name),
        ScanMethod.none => throw ScanFailure(
            'Camera scanning is not available on this device. '
            'Enter the wall lengths manually instead.'),
      };

  /// Opens the camera scanner in Line mode to measure straight-line
  /// distances only (no room). Returns the lines measured, null when the
  /// user backs out; throws [ScanFailure] when scanning is not possible.
  static Future<List<MeasuredLine>?> measureLines({int first = 1}) async {
    Map<String, dynamic>? result;
    try {
      result = await _channel.invokeMapMethod<String, dynamic>(
          'measure', {'startMode': 'line'});
    } on PlatformException catch (e) {
      throw ScanFailure(e.message ?? e.code);
    }
    if (result == null) return null;
    final error = result['error'] as String?;
    if (error != null) throw ScanFailure(error);
    // Photos are only kept with rooms.
    for (final p in (result['photos'] as List?)?.cast<String>() ?? const []) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    // Doors / windows measured here too are kept on their own.
    final details = (result['openingDetails'] as List?)?.cast<double>();
    if (details != null && details.isNotEmpty) {
      final loose = looseOpeningsFrom(
          parseOpeningDetails(details, (result['floorY'] as num?)?.toDouble(),
              methods: _flags(result['openingMethods']),
              estimated: _flags(result['openingEstimated'])),
          DateTime.now());
      await OpeningStore.save([...loose.reversed, ...await OpeningStore.load()]);
    }
    return parseLines((result['lines'] as List?)?.cast<double>() ?? const [],
        at: DateTime.now(),
        first: first,
        estimated: _flags(result['linesEstimated']));
  }

  static Future<CapturedScan?> _guided(String name) async {
    Map<String, dynamic>? result;
    try {
      result = await _channel.invokeMapMethod<String, dynamic>('measure');
    } on PlatformException catch (e) {
      throw ScanFailure(e.message ?? e.code);
    }
    if (result == null) return null; // user backed out
    final error = result['error'] as String?;
    if (error != null) throw ScanFailure(error);

    final xs = (result['xs'] as List).cast<double>();
    final zs = (result['zs'] as List).cast<double>();
    final corners = [for (var i = 0; i < xs.length; i++) Vec2(xs[i], zs[i])];
    final floorY = (result['floorY'] as num?)?.toDouble();
    final details = (result['openingDetails'] as List?)?.cast<double>();
    final List<MarkedOpening> openings;
    if (details != null) {
      openings = parseOpeningDetails(details, floorY,
          methods: _flags(result['openingMethods']),
          estimated: _flags(result['openingEstimated']));
    } else {
      // Older scanner builds: widths only.
      final raw = (result['openings'] as List?)?.cast<double>() ?? const [];
      openings = [
        for (var i = 0; i + 4 < raw.length; i += 5)
          MarkedOpening(
            raw[i] == 1 ? OpeningType.window : OpeningType.door,
            Vec2(raw[i + 1], raw[i + 2]),
            Vec2(raw[i + 3], raw[i + 4]),
          ),
      ];
    }
    final surfaces = parseSurfaces(
        (result['surfaces'] as List?)?.cast<double>() ?? const [], floorY);
    final scan = scanFromCorners(corners,
        name: name,
        height: (result['height'] as num?)?.toDouble(),
        openings: openings,
        surfaces: surfaces,
        lines: parseLines(
            (result['lines'] as List?)?.cast<double>() ?? const [],
            estimated: _flags(result['linesEstimated'])));
    // Photos taken in the scanner are in a temporary folder: keep them.
    for (final p in (result['photos'] as List?)?.cast<String>() ?? const []) {
      try {
        scan.photos.add(await ScanStore.keepPhoto(p));
        await File(p).delete();
      } catch (_) {}
    }
    final automatic = result['auto'] as bool? ?? false;
    final estimated = (result['estimated'] as num?)?.toInt() ?? 0;
    final focus = (result['focusOpening'] as num?)?.toInt();
    final roomless = scan.walls.length < 3;
    return CapturedScan(
      scan,
      automatic: automatic,
      estimatedWalls: estimated,
      complete: automatic && estimated == 0,
      focusOpening:
          focus != null && focus >= 0 && focus < openings.length ? focus : null,
      looseOpenings:
          roomless ? looseOpeningsFrom(openings, DateTime.now()) : const [],
    );
  }

  static Future<CapturedScan?> _lidar(String name) async {
    final scanner = rp.RoomPlanScanner();
    // RoomPlan only ends when Done is tapped. Watch its live updates and
    // finish on our own once the walls close around the room and the
    // outline has stopped changing for a few seconds.
    final watcher = LidarCompletion();
    final updates = scanner.onScanResult.listen((r) {
      if (r == null) return;
      try {
        if (watcher.update(RoomPlanMapper.toScan(r, name: name).walls,
            DateTime.now())) {
          scanner.stopScanning();
        }
      } catch (_) {}
    });
    try {
      final result = await scanner.startScanning();
      if (result == null) return null;
      final scan = RoomPlanMapper.toScan(result, name: name);
      if (scan.walls.length < 3) {
        throw ScanFailure('Not enough walls were found. Scan the room again, '
            'pointing the camera at every wall.');
      }
      return CapturedScan(scan,
          automatic: true, complete: isClosedOutline(scan.walls));
    } on rp.ScanCancelledException {
      return null;
    } on rp.RoomPlanPermissionsException {
      throw ScanFailure('Camera permission is needed to scan a room. '
          'Allow it in Settings.');
    } on rp.RoomPlanException catch (e) {
      throw ScanFailure('The scan failed: $e');
    } finally {
      await updates.cancel();
      scanner.dispose();
    }
  }
}

/// Decides when a live LiDAR scan is complete: the walls form a closed
/// outline whose wall count and floor area have held steady for [hold].
class LidarCompletion {
  LidarCompletion({this.hold = const Duration(seconds: 3)});

  final Duration hold;
  DateTime? _stableSince;
  int _walls = 0;
  double _area = 0;
  bool _fired = false;

  /// Feeds the latest walls; true once (the moment to stop scanning).
  bool update(List<WallLine> raw, DateTime now) {
    if (_fired) return false;
    final walls = orderWalls(raw);
    if (!isClosedOutline(walls)) {
      _stableSince = null;
      return false;
    }
    final area = signedArea([for (final w in walls) w.a]).abs();
    if (_stableSince == null ||
        walls.length != _walls ||
        (area - _area).abs() > 0.15) {
      _stableSince = now;
      _walls = walls.length;
      _area = area;
      return false;
    }
    if (now.difference(_stableSince!) < hold) return false;
    _fired = true;
    return true;
  }
}
