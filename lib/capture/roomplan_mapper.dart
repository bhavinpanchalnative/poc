import 'dart:math' as math;

import 'package:roomplan_flutter/roomplan_flutter.dart' as rp;

import '../engine/floor_plan_builder.dart';
import '../engine/geometry.dart';
import '../engine/models.dart';

/// Converts an Apple RoomPlan result into the app's shared [RoomScan] model,
/// so RoomPlan and tap-to-measure use the same engine and drawing.
class RoomPlanMapper {
  /// The scan's (first) room. Used for live updates while scanning.
  static RoomScan toScan(rp.ScanResult result, {required String name}) =>
      roomToScan(result.room, name: name);

  /// One RoomPlan room as a [RoomScan], in RoomPlan's world coordinates
  /// (x, z): walls, doors, windows, openings, furniture and the ceiling
  /// height.
  static RoomScan roomToScan(rp.RoomData room, {required String name}) {
    // Each RoomPlan wall is a rectangle: its transform's translation is the
    // wall centre and its local X axis runs along the wall; width = length.
    final raw = <WallLine>[];
    for (final w in room.walls) {
      final t = w.transform;
      if (t == null || w.width <= 0.05) continue;
      final c = t.getTranslation();
      final axis = t.getColumn(0);
      final dir = Vec2(axis.x, axis.z).normalized;
      final centre = Vec2(c.x, c.z);
      final half = dir * (w.width / 2);
      raw.add(WallLine(centre - half, centre + half));
    }
    final walls = orderWalls(raw);

    // Doors, windows and openings can come at room level or nested in a
    // wall; collect each once.
    final seen = <String>{};
    final all = <rp.OpeningData>[
      ...room.doors,
      ...room.windows,
      ...room.openings,
      for (final w in room.walls) ...w.openings,
    ].where((o) => seen.add(o.uuid.isEmpty ? '${o.hashCode}' : o.uuid));

    // Floor level: the bottom of the walls (each is centred on its height).
    double? floorY;
    for (final w in room.walls) {
      final c = w.transform?.getTranslation();
      if (c == null || w.height <= 0) continue;
      final bottom = c.y - w.height / 2;
      if (floorY == null || bottom < floorY) floorY = bottom;
    }

    final openings = <Opening>[];
    if (walls.length >= 3) {
      for (final o in all) {
        final p = o.transform?.getTranslation() ?? o.position.vector;
        final loc = locateOnWalls(walls, Vec2(p.x, p.z));
        final isWindow = o.type == rp.OpeningType.window;
        final sill = isWindow && floorY != null && o.height > 0
            ? p.y - o.height / 2 - floorY
            : null;
        openings.add(Opening(
          type: switch (o.type) {
            rp.OpeningType.door => OpeningType.door,
            rp.OpeningType.window => OpeningType.window,
            rp.OpeningType.opening => OpeningType.opening,
          },
          wallIndex: loc.wallIndex,
          center: loc.t,
          width: o.width,
          height: o.height > 0 ? o.height : null,
          sill: sill != null && sill >= 0 ? sill : null,
          method: OpeningMethod.auto,
        ));
      }
    }

    // Furniture and fixtures RoomPlan recognised (bed, sofa, sink...).
    final elements = <RoomElement>[
      for (final o in room.objects)
        if (o.category != rp.ObjectCategory.unknown)
          RoomElement(
            kind: elementLabel(o.category),
            width: o.width > 0 ? o.width : null,
            depth: o.length > 0 ? o.length : null,
            height: o.height > 0 ? o.height : null,
            position: () {
              final p = o.transform?.getTranslation() ?? o.position.vector;
              return Vec2(p.x, p.z);
            }(),
            // Which way its width (its local x axis) runs on the floor.
            angle: o.transform == null
                ? null
                : math.atan2(o.transform!.entry(2, 0), o.transform!.entry(0, 0)),
          ),
    ];

    return RoomScan(
      id: RoomScan.newId(),
      name: name,
      createdAt: DateTime.now(),
      source: CaptureSource.roomPlan,
      walls: walls,
      openings: openings,
      elements: elements,
      ceilingHeight: ceilingHeightOf([for (final w in room.walls) w.height]),
    );
  }

  /// The room's floor-to-ceiling height from its walls' heights: their
  /// median (one wall cut short by a cupboard or a sloped ceiling doesn't
  /// change it). Null when no wall is tall enough to be a full wall.
  static double? ceilingHeightOf(List<double> wallHeights) {
    final h = wallHeights.where((v) => v >= 1.5 && v <= 6).toList()..sort();
    if (h.isEmpty) return null;
    final m = h.length ~/ 2;
    return h.length.isOdd ? h[m] : (h[m - 1] + h[m]) / 2;
  }

  /// A readable name for a RoomPlan object category.
  static String elementLabel(rp.ObjectCategory c) => switch (c) {
        rp.ObjectCategory.storage => 'Storage',
        rp.ObjectCategory.table => 'Table',
        rp.ObjectCategory.sofa => 'Sofa',
        rp.ObjectCategory.chair => 'Chair',
        rp.ObjectCategory.bed => 'Bed',
        rp.ObjectCategory.sink => 'Sink',
        rp.ObjectCategory.toilet => 'Toilet',
        rp.ObjectCategory.oven => 'Oven',
        rp.ObjectCategory.refrigerator => 'Refrigerator',
        rp.ObjectCategory.stove => 'Stove',
        rp.ObjectCategory.washerDryer => 'Washer / dryer',
        rp.ObjectCategory.television => 'Television',
        rp.ObjectCategory.fireplace => 'Fireplace',
        rp.ObjectCategory.stairs => 'Stairs',
        rp.ObjectCategory.bathtub => 'Bathtub',
        rp.ObjectCategory.dishwasher => 'Dishwasher',
        rp.ObjectCategory.unknown => 'Object',
      };

  // ------------------------------------------------------------ room types

  /// A name for the room from what RoomPlan recognised it as ([type]:
  /// "kitchen", "bathroom", ...) or, failing that, from what is in it (a
  /// toilet or bath: bathroom; a stove, oven or fridge: kitchen; a bed:
  /// bedroom; a sofa or TV: living room). Null when nothing tells.
  static String? roomTypeName(String? type, List<RoomElement> elements) {
    final named = switch (type) {
      'kitchen' => 'Kitchen',
      'bathroom' => 'Bathroom',
      'bedroom' => 'Bedroom',
      'livingRoom' => 'Living room',
      'diningRoom' => 'Dining room',
      _ => null,
    };
    if (named != null) return named;
    final kinds = {for (final e in elements) e.kind};
    if (kinds.contains('Toilet') || kinds.contains('Bathtub')) return 'Bathroom';
    if (kinds.contains('Stove') ||
        kinds.contains('Oven') ||
        kinds.contains('Refrigerator') ||
        kinds.contains('Dishwasher')) {
      return 'Kitchen';
    }
    if (kinds.contains('Bed')) return 'Bedroom';
    if (kinds.contains('Washer / dryer')) return 'Utility room';
    if (kinds.contains('Sofa') || kinds.contains('Television') || kinds.contains('Fireplace')) {
      return 'Living room';
    }
    if (kinds.contains('Table') && kinds.contains('Chair')) return 'Dining room';
    return null;
  }

  /// [names] with repeats numbered ("Bedroom", "Bedroom 2"); a null name
  /// becomes "Room n" (its position).
  static List<String> uniqueNames(List<String?> names) {
    final total = <String, int>{};
    for (final n in names) {
      if (n != null) total[n] = (total[n] ?? 0) + 1;
    }
    final used = <String, int>{};
    return [
      for (var i = 0; i < names.length; i++)
        if (names[i] == null)
          'Room ${i + 1}'
        else if (total[names[i]]! == 1)
          names[i]!
        else
          () {
            final k = (used[names[i]!] ?? 0) + 1;
            used[names[i]!] = k;
            return k == 1 ? names[i]! : '${names[i]} $k';
          }(),
    ];
  }

  // ------------------------------------------------------------ multi-room

  /// The angle (radians) that turns every room of one scan square to the
  /// plan's axes: that of the longest wall of all, so the rooms stay put
  /// relative to each other and the floor plan isn't drawn askew.
  static double alignmentAngle(List<List<WallLine>> rooms) {
    WallLine? longest;
    for (final r in rooms) {
      for (final w in r) {
        if (longest == null || w.length > longest.length) longest = w;
      }
    }
    return longest?.dir.angle ?? 0;
  }

  /// [scan] turned by -[angle] about the origin (walls, furniture, photo
  /// positions); doors and windows are along their walls, so unchanged.
  /// It keeps that orientation on the plan ([RoomScan.keepOrientation]),
  /// so rooms scanned together keep lining up.
  static RoomScan rotated(RoomScan scan, double angle) {
    Vec2 r(Vec2 p) => p.rotate(-angle);
    return RoomScan(
      id: scan.id,
      name: scan.name,
      createdAt: scan.createdAt,
      source: scan.source,
      walls: [for (final w in scan.walls) WallLine(r(w.a), r(w.b))],
      openings: scan.openings,
      surfaces: scan.surfaces,
      photos: scan.photos,
      lines: scan.lines,
      elements: [
        for (final e in scan.elements)
          RoomElement(
            kind: e.kind,
            width: e.width,
            depth: e.depth,
            height: e.height,
            position: e.position == null ? null : r(e.position!),
            angle: e.angle == null ? null : e.angle! - angle,
          ),
      ],
      photoPins: [
        for (final p in scan.photoPins)
          p.copyWith(position: r(p.position), direction: p.direction == null ? null : r(p.direction!)),
      ],
      scale: scan.scale,
      keepOrientation: true,
      ceilingHeight: scan.ceilingHeight,
    );
  }

  /// Where each room of a floor scanned in one go sits on its floor map:
  /// the offset that puts its plan back where it was scanned (rooms must
  /// already be turned together, see [rotated]). Null for a room whose plan
  /// can't be built.
  static List<Vec2?> mapOffsets(List<RoomScan> rooms,
      {FloorPlanBuilder builder = const FloorPlanBuilder()}) => [
        for (final s in rooms)
          () {
            try {
              // keepOrientation: plan = scan coordinates - origin, so the
              // origin is where the plan's (0, 0) goes on the map.
              return builder.build(s).origin;
            } on PlanException {
              return null;
            }
          }(),
      ];

  /// The room a photo taken at [p] belongs to: the one whose outline it is
  /// in, else the one with the nearest wall, else [fallback] (the room
  /// being scanned when it was taken).
  static int roomForPoint(Vec2 p, List<List<WallLine>> rooms, int fallback) {
    for (var i = 0; i < rooms.length; i++) {
      final poly = [for (final w in rooms[i]) w.a];
      if (poly.length >= 3 && _inside(p, poly)) return i;
    }
    var best = math.min(math.max(fallback, 0), math.max(0, rooms.length - 1));
    var bestD = double.infinity;
    for (var i = 0; i < rooms.length; i++) {
      for (final w in rooms[i]) {
        final d = _distToSegment(p, w.a, w.b);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
    }
    return best;
  }

  static bool _inside(Vec2 p, List<Vec2> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i], b = poly[j];
      if ((a.y > p.y) != (b.y > p.y) &&
          p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
        inside = !inside;
      }
    }
    return inside;
  }

  static double _distToSegment(Vec2 p, Vec2 a, Vec2 b) {
    final ab = b - a;
    final l2 = ab.dot(ab);
    final t = l2 <= 0 ? 0.0 : ((p - a).dot(ab) / l2).clamp(0.0, 1.0);
    return p.distanceTo(a + ab * t);
  }
}
