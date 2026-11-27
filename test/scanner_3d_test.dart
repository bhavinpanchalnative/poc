import 'package:flutter_test/flutter_test.dart';
import 'package:room_measure/engine/floor_map.dart';
import 'package:room_measure/engine/floor_plan_builder.dart';
import 'package:room_measure/engine/geometry.dart';
import 'package:room_measure/engine/measure3d.dart';
import 'package:room_measure/engine/models.dart';
import 'package:room_measure/engine/units.dart';
import 'package:room_measure/scanner/cad_export.dart';
import 'package:room_measure/scanner/room_model_3d.dart';

/// A 4 x 3 m room, 2.5 m high, with a 0.9 x 2.0 m door, a 1.2 x 1.0 m
/// window (sill 1.0 m) and a bed.
RoomScan kitchen({double? ceiling = 2.5}) {
  const c = [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3), Vec2(0, 3)];
  return RoomScan(
    id: 'k',
    name: 'Kitchen',
    createdAt: DateTime(2026),
    source: CaptureSource.roomPlan,
    walls: [for (var i = 0; i < 4; i++) WallLine(c[i], c[(i + 1) % 4])],
    openings: const [
      Opening(type: OpeningType.door, wallIndex: 0, center: 0.5, width: 0.9, height: 2.0),
      Opening(
          type: OpeningType.window, wallIndex: 1, center: 0.5, width: 1.2, height: 1.0, sill: 1.0),
    ],
    elements: const [
      RoomElement(kind: 'Bed', width: 1.6, depth: 2.0, height: 0.5, position: Vec2(2, 1.5), angle: 0),
    ],
    ceilingHeight: ceiling,
  );
}

/// Area of a planar polygon: half the length of the summed cross products.
double faceArea(Face3D f) {
  var s = const Vec3(0, 0, 0);
  final p = f.points;
  for (var i = 0; i < p.length; i++) {
    s = s + p[i].cross(p[(i + 1) % p.length]);
  }
  return s.length / 2;
}

void main() {
  final scan = kitchen();
  final plan = const FloorPlanBuilder().build(scan);

  group('3D model', () {
    final m = RoomModel3D.single(scan, plan);

    test('walls are the perimeter times the height, less doors and windows', () {
      final wall = m.faces.where((f) => f.part == Part3D.wall).fold(0.0, (t, f) => t + faceArea(f));
      expect(wall, closeTo(14 * 2.5 - 0.9 * 2.0 - 1.2 * 1.0, 1e-6));
    });

    test('doors and windows fill their gaps at the right height', () {
      final door = m.faces.singleWhere((f) => f.part == Part3D.door);
      final window = m.faces.singleWhere((f) => f.part == Part3D.window);
      expect(faceArea(door), closeTo(1.8, 1e-6));
      expect(faceArea(window), closeTo(1.2, 1e-6));
      final ys = [for (final p in window.points) p.y];
      expect(ys.reduce((a, b) => a < b ? a : b), closeTo(1.0, 1e-9));
      expect(ys.reduce((a, b) => a > b ? a : b), closeTo(2.0, 1e-9));
    });

    test('the floor matches the plan and furniture is a box', () {
      expect(faceArea(m.faces.singleWhere((f) => f.part == Part3D.floor)), closeTo(12, 1e-6));
      expect(m.faces.where((f) => f.part == Part3D.furniture), hasLength(5));
      expect(m.max.y, closeTo(2.5, 1e-9));
      expect(m.labels, hasLength(4));
    });

    test('wall normals point out of the room, also when a floor map turns it', () {
      for (final turns in [0, 1, 2, 3]) {
        final placed = PlacedRoom(scan, plan,
            MapRoom(scanId: 'k', offset: const Vec2(5, -2), quarterTurns: turns));
        final mm = RoomModel3D.build([RoomInput.placed(placed)]);
        final c = mm.center;
        for (final f in mm.faces.where((f) => f.outward != null)) {
          final out = f.centroid - c;
          expect(f.outward!.x * out.x + f.outward!.z * out.z, greaterThan(0),
              reason: 'turns $turns');
        }
      }
    });

    test('an unmeasured ceiling uses the default height', () {
      final s = kitchen(ceiling: null);
      final mm = RoomModel3D.single(s, const FloorPlanBuilder().build(s));
      expect(mm.max.y, closeTo(defaultCeilingHeight, 1e-9));
      expect(mm.heightsMeasured, isFalse);
    });
  });

  group('DXF', () {
    final dxf = CadExporter.dxf([RoomInput(scan, plan)], unit: LengthUnit.meters);
    final lines = dxf.split('\r\n');
    int count(String entity) {
      var n = 0;
      for (var i = 0; i + 1 < lines.length; i += 2) {
        if (lines[i] == '0' && lines[i + 1] == entity) n++;
      }
      return n;
    }

    test('is a complete R12 drawing in group code / value pairs', () {
      expect(lines.take(4), ['0', 'SECTION', '2', 'HEADER']);
      expect(dxf.trimRight().endsWith('0\r\nEOF'), isTrue);
      expect(dxf, contains('AC1009'));
      for (final l in ['WALLS', 'DOORS', 'WINDOWS', 'FURNITURE', 'DIMENSIONS', 'ROOMS']) {
        expect(dxf, contains('2\r\n$l\r\n'));
      }
      // Only ASCII, which every reader takes.
      expect(dxf.codeUnits.every((c) => c < 128), isTrue);
    });

    test('draws walls, the door swing, window lines and labels', () {
      // 4 walls x (inner + outer) + one more of each for every opening,
      // + 2 jambs per opening + door leaf + 3 window lines + 3 dim lines per wall.
      expect(count('LINE'), 4 * 2 + 2 * 2 + 2 * 2 + 1 + 3 + 4 * 3);
      expect(count('ARC'), 1);
      expect(count('POLYLINE'), 1); // the bed
      expect(dxf, contains('Kitchen'));
      expect(dxf, contains('Bed'));
      expect(count('TEXT'), 4 + 2 + 1);
    });
  });

  group('OBJ', () {
    final m = RoomModel3D.single(scan, plan);
    final (obj, mtl) = CadExporter.obj(m, mtlName: 'kitchen.mtl');

    test('has a vertex for every face corner and materials per part', () {
      final verts = '\n$obj'.split('\nv ').length - 1;
      expect(verts, m.faces.fold(0, (t, f) => t + f.points.length));
      expect(obj, contains('mtllib kitchen.mtl'));
      for (final p in ['floor', 'wall', 'door', 'window', 'furniture']) {
        expect(obj, contains('usemtl $p'));
        expect(mtl, contains('newmtl $p'));
      }
    });
  });
}
