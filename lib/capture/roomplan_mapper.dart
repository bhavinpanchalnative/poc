import 'package:roomplan_flutter/roomplan_flutter.dart' as rp;

import '../engine/floor_plan_builder.dart';
import '../engine/geometry.dart';
import '../engine/models.dart';

/// Converts an Apple RoomPlan result into the app's shared [RoomScan] model,
/// so RoomPlan and tap-to-measure use the same engine and drawing.
class RoomPlanMapper {
  static RoomScan toScan(rp.ScanResult result, {required String name}) {
    final room = result.room;

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

    // Room height: median of the wall heights.
    final heights = [for (final w in room.walls) w.height]
      ..removeWhere((h) => h <= 0)
      ..sort();
    final height = heights.isEmpty
        ? room.dimensions?.height
        : heights[heights.length ~/ 2];

    return RoomScan(
      id: RoomScan.newId(),
      name: name,
      createdAt: DateTime.now(),
      source: CaptureSource.roomPlan,
      walls: walls,
      openings: openings,
      height: (height ?? 0) > 0 ? height : null,
    );
  }
}
