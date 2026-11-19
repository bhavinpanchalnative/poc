import '../engine/geometry.dart';
import '../engine/models.dart';

/// A 3D world point from ARCore / ARKit (Y is up), in metres.
class WorldPoint {
  const WorldPoint(this.x, this.y, this.z);
  final double x, y, z;
  Vec2 get floor => Vec2(x, z);
}

enum TapMode { walls, ceiling }

/// What happened after a tap, for the UI to show.
class TapOutcome {
  const TapOutcome(this.message, {this.accepted = true, this.markerId});
  final String message;
  final bool accepted;

  /// Id of the marker to draw at the tapped point, if any.
  final String? markerId;
}

/// Platform-independent logic of tap-to-measure.
///
/// For each wall the user taps two points along it, going around the room in
/// order: at the bottom edge (wall meets floor), the top edge (wall meets
/// ceiling) or on the wall itself. Only the points' floor-plan position is
/// used, and [WorldPoint.y] must be the floor height. Each pair becomes one
/// [WallLine].
/// Optionally the user taps the ceiling once to get the room height.
class TapSession {
  /// Taps closer than this on one wall give an unreliable direction.
  static const minTapSpacing = 0.30;

  final List<WallLine> walls = [];
  final List<double> _floorHeights = [];
  final List<String> _wallMarkers = [];
  WorldPoint? _pending;
  String? _pendingMarker;
  String? _ceilingMarker;
  double? height;
  TapMode mode = TapMode.walls;
  int _markerCount = 0;

  bool get hasPendingPoint => _pending != null;
  int get wallCount => walls.length;
  bool get canFinish => walls.length >= 3 && _pending == null;

  /// Floor level estimated from all floor taps (median, robust to one bad tap).
  double? get floorY {
    if (_floorHeights.isEmpty) return null;
    final s = List.of(_floorHeights)..sort();
    return s[s.length ~/ 2];
  }

  String get instruction {
    if (mode == TapMode.ceiling) {
      return 'Tap the ceiling once to measure the room height.';
    }
    final next = walls.length + 1;
    return _pending == null
        ? 'Wall $next: tap where the wall meets the floor or the ceiling.'
        : 'Wall $next: tap a second point further along the same wall.';
  }

  TapOutcome onTap(WorldPoint p) {
    if (mode == TapMode.ceiling) return _onCeilingTap(p);

    final marker = 'm${_markerCount++}';
    if (_pending == null) {
      _pending = p;
      _pendingMarker = marker;
      _floorHeights.add(p.y);
      return TapOutcome('First point of wall ${walls.length + 1} placed.',
          markerId: marker);
    }
    final a = _pending!.floor, b = p.floor;
    if (a.distanceTo(b) < minTapSpacing) {
      _markerCount--;
      return TapOutcome(
          'Too close to the first point. Tap at least '
          '${(minTapSpacing * 100).round()} cm further along the wall.',
          accepted: false);
    }
    walls.add(WallLine(a, b));
    _wallMarkers
      ..add(_pendingMarker!)
      ..add(marker);
    _floorHeights.add(p.y);
    _pending = null;
    _pendingMarker = null;
    return TapOutcome('Wall ${walls.length} added.', markerId: marker);
  }

  TapOutcome _onCeilingTap(WorldPoint p) {
    final floor = floorY;
    if (floor == null) {
      return const TapOutcome('Measure at least one wall first.',
          accepted: false);
    }
    final h = p.y - floor;
    if (h < 1.8 || h > 6) {
      return TapOutcome(
          'That point is ${h.toStringAsFixed(2)} m above the floor, which '
          'does not look like a ceiling. Try again.',
          accepted: false);
    }
    height = h;
    mode = TapMode.walls;
    _ceilingMarker = 'ceiling';
    return TapOutcome('Height ${h.toStringAsFixed(2)} m.',
        markerId: _ceilingMarker);
  }

  /// Removes the last point or wall. Returns the marker ids to delete.
  List<String> undo() {
    if (_pending != null) {
      _pending = null;
      _floorHeights.removeLast();
      final m = _pendingMarker!;
      _pendingMarker = null;
      return [m];
    }
    if (walls.isNotEmpty) {
      walls.removeLast();
      _floorHeights
        ..removeLast()
        ..removeLast();
      final b = _wallMarkers.removeLast();
      final a = _wallMarkers.removeLast();
      return [a, b];
    }
    return [];
  }

  RoomScan toScan(String name) => RoomScan(
        id: RoomScan.newId(),
        name: name,
        createdAt: DateTime.now(),
        source: CaptureSource.arTap,
        walls: List.of(walls),
        height: height,
      );
}
