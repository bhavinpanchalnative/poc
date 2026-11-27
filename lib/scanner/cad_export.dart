import 'dart:io';
import 'dart:math' as math;

import '../engine/geometry.dart';
import '../engine/models.dart';
import '../engine/units.dart';
import '../services/plan_exporter.dart';
import '../services/scan_store.dart';
import 'room_model_3d.dart';

/// Exports scanned rooms for CAD and 3D tools:
///
/// - [dxf]: the floor plan as an AutoCAD DXF drawing (R12 ASCII, opens in
///   AutoCAD, DraftSight, LibreCAD, SketchUp, Revit, MeasureSquare and
///   most other CAD software). Walls are drawn as double lines with the
///   doors, windows and gaps cut out; doors get a leaf and swing arc,
///   windows the usual three lines; every wall gets its length; each room
///   its name and area. Layers: WALLS, DOORS, WINDOWS, OPENINGS, FURNITURE,
///   DIMENSIONS, ROOMS. Units are metres.
/// - [obj]: the 3D model (floors, walls, doors, windows, furniture) as
///   Wavefront OBJ with an MTL file of colours, for Blender, SketchUp,
///   3ds Max, AR viewers, etc. One group per room and part.
class CadExporter {
  /// Thickness drawn for walls in the DXF (the scanner measures the inside
  /// faces of walls, so walls grow outwards).
  static const wallThickness = 0.10;

  // ------------------------------------------------------------------ DXF

  static String dxf(List<RoomInput> rooms, {LengthUnit unit = LengthUnit.meters}) {
    final e = _DxfWriter();
    for (final room in rooms) {
      _dxfRoom(e, room, unit);
    }
    return e.document();
  }

  static void _dxfRoom(_DxfWriter e, RoomInput room, LengthUnit unit) {
    final plan = room.plan;
    final n = plan.wallCount;
    if (n < 3) return;
    final w = room.toWorld;
    final inner = [for (final c in plan.corners) w(c)];
    final ccw = signedArea(inner) > 0;

    Vec2 outN(int i) {
      final d = (inner[(i + 1) % n] - inner[i]).normalized;
      return ccw ? d.perp * -1 : d.perp;
    }

    // Outer corners: where the walls' outer faces meet (mitred).
    final outer = <Vec2>[];
    for (var i = 0; i < n; i++) {
      final prev = (i - 1 + n) % n;
      final lp = Line2(inner[prev] + outN(prev) * wallThickness,
          inner[i] - inner[prev]);
      final lc = Line2(inner[i] + outN(i) * wallThickness,
          inner[(i + 1) % n] - inner[i]);
      outer.add(lp.intersect(lc) ?? inner[i] + outN(i) * wallThickness);
    }

    for (var i = 0; i < n; i++) {
      final a = inner[i], b = inner[(i + 1) % n];
      final oa = outer[i], ob = outer[(i + 1) % n];
      final len = a.distanceTo(b);
      if (len < 1e-6) continue;
      final dir = (b - a) / len;
      final on = outN(i);
      // Position along the inner face of a point, and the inner / outer
      // face points at that position.
      Vec2 inAt(double t) => a + dir * t;
      Vec2 outAt(double t) => inAt(t) + on * wallThickness;

      final spans = <(double, double, Opening)>[];
      for (final o in plan.openings.where((o) => o.wallIndex == i)) {
        final s = plan.openingSpan(o);
        if (s == null) continue;
        final t0 = (w(s.$1) - a).dot(dir), t1 = (w(s.$2) - a).dot(dir);
        spans.add((math.min(t0, t1), math.max(t0, t1), o));
      }
      spans.sort((x, y) => x.$1.compareTo(y.$1));

      // Wall faces, broken at the openings. The ends use the mitred outer
      // corners so neighbouring walls join cleanly.
      var t = 0.0;
      var outStart = oa;
      for (final (s0, s1, o) in spans) {
        final start = math.max(s0, t);
        if (s1 <= start) continue;
        e.line('WALLS', inAt(t), inAt(start));
        e.line('WALLS', outStart, outAt(start));
        // Jambs.
        e.line('WALLS', inAt(start), outAt(start));
        e.line('WALLS', inAt(s1), outAt(s1));
        _dxfOpening(e, o, inAt(start), inAt(s1), on);
        t = s1;
        outStart = outAt(s1);
      }
      e.line('WALLS', inAt(t), b);
      e.line('WALLS', outStart, ob);

      // Dimension: the inside length, written outside the wall, along it.
      final mid = inAt(len / 2) + on * (wallThickness + 0.18);
      var ang = radToDeg(dir.angle);
      if (ang > 90 || ang <= -90) ang += 180; // keep text upright
      e.text('DIMENSIONS', mid, formatLength(plan.wallLength(i), unit),
          height: 0.12, rotation: ang);
      // Dimension line with ticks, just outside the wall.
      final d0 = outAt(0) + on * 0.08, d1 = outAt(len) + on * 0.08;
      e.line('DIMENSIONS', d0, d1);
      e.line('DIMENSIONS', d0 - on * 0.05, d0 + on * 0.05);
      e.line('DIMENSIONS', d1 - on * 0.05, d1 + on * 0.05);
    }

    // Furniture outlines.
    for (final f in RoomModel3D.single(room.scan, room.plan).faces) {
      if (f.part != Part3D.furniture || f.normal.y.abs() < 0.9) continue;
      // Top face of a box: its outline on the plan.
      final pts = [for (final p in f.points) w(Vec2(p.x, -p.z))];
      e.polyline('FURNITURE', pts, closed: true);
    }
    for (final el in room.scan.elements) {
      if (el.position == null) continue;
      e.text('FURNITURE', w(plan.toPlan(el.position!)), el.kind,
          height: 0.08, center: true);
    }

    // Room name and floor area at its centre.
    final c = polygonCentroid(inner);
    e.text('ROOMS', c + const Vec2(0, 0.12),
        room.scan.name.isEmpty ? 'Room' : room.scan.name,
        height: 0.2, center: true);
    e.text('ROOMS', c - const Vec2(0, 0.18), formatArea(plan.area, unit),
        height: 0.14, center: true);
  }

  /// A door's leaf and swing, a window's three lines, or a gap's dashed
  /// edge, between inner-face points [s] and [t] of a wall whose outside
  /// is [on].
  static void _dxfOpening(_DxfWriter e, Opening o, Vec2 s, Vec2 t, Vec2 on) {
    final width = s.distanceTo(t);
    switch (o.type) {
      case OpeningType.door:
        // Hinged at s, opening into the room by 90°.
        final inward = on * -1;
        final leafEnd = s + inward * width;
        e.line('DOORS', s, leafEnd);
        final a0 = radToDeg((t - s).angle), a1 = radToDeg(inward.angle);
        // ARC runs counter-clockwise from start to end angle.
        final ccwTurn = (t - s).cross(inward) > 0;
        e.arc('DOORS', s, width, ccwTurn ? a0 : a1, ccwTurn ? a1 : a0);
      case OpeningType.window:
        for (final f in [0.0, 0.5, 1.0]) {
          e.line('WINDOWS', s + on * (wallThickness * f), t + on * (wallThickness * f));
        }
      case OpeningType.opening:
        e.line('OPENINGS', s, t);
        e.line('OPENINGS', s + on * wallThickness, t + on * wallThickness);
    }
  }

  // ------------------------------------------------------------------ OBJ

  /// The model as OBJ text, its materials in `<mtlName>`. Faces are written
  /// as they are (n-gons; OBJ allows them), once per side so walls show from
  /// inside and out in every viewer.
  static (String obj, String mtl) obj(RoomModel3D model, {required String mtlName}) {
    final o = StringBuffer()
      ..writeln('# Room scan 3D model, metres, Y up')
      ..writeln('mtllib $mtlName');
    var v = 0;
    String? group;
    String? material;
    for (final f in model.faces) {
      final name = model.rooms.length > 1
          ? '${_objName(model.rooms[f.room].scan.name, f.room)}_${f.part.name}'
          : f.part.name;
      if (name != group) {
        o.writeln('g $name');
        group = name;
      }
      if (f.part.name != material) {
        o.writeln('usemtl ${f.part.name}');
        material = f.part.name;
      }
      for (final p in f.points) {
        o.writeln('v ${_f(p.x)} ${_f(p.y)} ${_f(p.z)}');
      }
      final idx = [for (var k = 0; k < f.points.length; k++) v + k + 1];
      o.writeln('f ${idx.join(' ')}');
      if (f.part != Part3D.floor) o.writeln('f ${idx.reversed.join(' ')}');
      v += f.points.length;
    }

    final m = StringBuffer();
    for (final part in Part3D.values) {
      final (r, g, b, d) = _colour(part);
      m
        ..writeln('newmtl ${part.name}')
        ..writeln('Kd ${_f(r)} ${_f(g)} ${_f(b)}')
        ..writeln('Ka 0.1 0.1 0.1')
        ..writeln('d ${_f(d)}')
        ..writeln('illum 1')
        ..writeln();
    }
    return (o.toString(), m.toString());
  }

  static (double, double, double, double) _colour(Part3D p) => switch (p) {
        Part3D.floor => (0.80, 0.74, 0.64, 1.0),
        Part3D.wall => (0.93, 0.93, 0.95, 1.0),
        Part3D.door => (0.88, 0.54, 0.04, 1.0),
        Part3D.window => (0.05, 0.65, 0.91, 0.5),
        Part3D.opening => (0.6, 0.6, 0.6, 0.15),
        Part3D.furniture => (0.47, 0.55, 0.70, 1.0),
      };

  static String _objName(String s, int i) {
    final n = s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    return n.isEmpty ? 'room${i + 1}' : n;
  }

  static String _f(double x) => x.toStringAsFixed(4);

  // ---------------------------------------------------------------- files

  static Future<File> saveDxf(List<RoomInput> rooms, LengthUnit unit,
      {required String name}) async {
    final f = await _file(name, 'dxf');
    await f.writeAsString(dxf(rooms, unit: unit));
    return f;
  }

  /// Writes the OBJ and its MTL side by side; returns both (OBJ first).
  static Future<List<File>> saveObj(RoomModel3D model, {required String name}) async {
    final objFile = await _file(name, 'obj');
    final base = objFile.uri.pathSegments.last.replaceAll('.obj', '');
    final mtlFile = File(objFile.path.replaceAll(RegExp(r'\.obj$'), '.mtl'));
    final (obj, mtl) = CadExporter.obj(model, mtlName: '$base.mtl');
    await objFile.writeAsString(obj);
    await mtlFile.writeAsString(mtl);
    return [objFile, mtlFile];
  }

  static Future<File> _file(String name, String ext) async {
    final dir = await ScanStore.exportsDir();
    return File('${dir.path}${Platform.pathSeparator}'
        '${PlanExporter.safeName(name)}_${DateTime.now().millisecondsSinceEpoch}.$ext');
  }
}

/// Minimal DXF R12 (AC1009) writer: the layer table and LINE, (old-style)
/// POLYLINE, ARC and TEXT entities, which every DXF reader understands.
class _DxfWriter {
  final _entities = StringBuffer();

  static const _layers = {
    'WALLS': 7, // white / black
    'DOORS': 30, // orange
    'WINDOWS': 4, // cyan
    'OPENINGS': 8, // grey
    'FURNITURE': 5, // blue
    'DIMENSIONS': 1, // red
    'ROOMS': 3, // green
  };

  void _pair(StringBuffer b, int code, Object value) {
    b
      ..write(code)
      ..write('\r\n')
      ..write(value is double ? value.toStringAsFixed(4) : value)
      ..write('\r\n');
  }

  void line(String layer, Vec2 a, Vec2 b) {
    if (a.distanceTo(b) < 1e-5) return;
    final e = _entities;
    _pair(e, 0, 'LINE');
    _pair(e, 8, layer);
    _pair(e, 10, a.x);
    _pair(e, 20, a.y);
    _pair(e, 30, 0.0);
    _pair(e, 11, b.x);
    _pair(e, 21, b.y);
    _pair(e, 31, 0.0);
  }

  void polyline(String layer, List<Vec2> pts, {bool closed = false}) {
    final e = _entities;
    _pair(e, 0, 'POLYLINE');
    _pair(e, 8, layer);
    _pair(e, 66, 1);
    _pair(e, 10, 0.0);
    _pair(e, 20, 0.0);
    _pair(e, 30, 0.0);
    _pair(e, 70, closed ? 1 : 0);
    for (final p in pts) {
      _pair(e, 0, 'VERTEX');
      _pair(e, 8, layer);
      _pair(e, 10, p.x);
      _pair(e, 20, p.y);
      _pair(e, 30, 0.0);
    }
    _pair(e, 0, 'SEQEND');
    _pair(e, 8, layer);
  }

  void arc(String layer, Vec2 c, double r, double startDeg, double endDeg) {
    final e = _entities;
    _pair(e, 0, 'ARC');
    _pair(e, 8, layer);
    _pair(e, 10, c.x);
    _pair(e, 20, c.y);
    _pair(e, 30, 0.0);
    _pair(e, 40, r);
    _pair(e, 50, startDeg);
    _pair(e, 51, endDeg);
  }

  void text(String layer, Vec2 at, String s,
      {required double height, double rotation = 0, bool center = false}) {
    final e = _entities;
    // DXF text is plain ASCII in R12 readers: spell out the symbols the app
    // uses in its lengths and areas.
    final ascii = s
        .replaceAll('²', '2')
        .replaceAll('×', 'x')
        .replaceAll('′', "'")
        .replaceAll('″', '"')
        .replaceAll(RegExp(r'[^\x20-\x7E]'), '');
    _pair(e, 0, 'TEXT');
    _pair(e, 8, layer);
    _pair(e, 10, at.x);
    _pair(e, 20, at.y);
    _pair(e, 30, 0.0);
    _pair(e, 40, height);
    _pair(e, 1, ascii);
    if (rotation != 0) _pair(e, 50, rotation);
    // Centred both ways (72 = 1 centre, 73 = 2 middle) on the point.
    _pair(e, 72, 1);
    _pair(e, 73, 2);
    _pair(e, 11, at.x);
    _pair(e, 21, at.y);
    _pair(e, 31, 0.0);
  }

  String document() {
    final b = StringBuffer();
    _pair(b, 0, 'SECTION');
    _pair(b, 2, 'HEADER');
    _pair(b, 9, r'$ACADVER');
    _pair(b, 1, 'AC1009');
    _pair(b, 9, r'$INSUNITS');
    _pair(b, 70, 6); // metres
    _pair(b, 0, 'ENDSEC');

    _pair(b, 0, 'SECTION');
    _pair(b, 2, 'TABLES');
    _pair(b, 0, 'TABLE');
    _pair(b, 2, 'LAYER');
    _pair(b, 70, _layers.length);
    for (final MapEntry(key: name, value: colour) in _layers.entries) {
      _pair(b, 0, 'LAYER');
      _pair(b, 2, name);
      _pair(b, 70, 0);
      _pair(b, 62, colour);
      _pair(b, 6, 'CONTINUOUS');
    }
    _pair(b, 0, 'ENDTAB');
    _pair(b, 0, 'ENDSEC');

    _pair(b, 0, 'SECTION');
    _pair(b, 2, 'ENTITIES');
    b.write(_entities);
    _pair(b, 0, 'ENDSEC');
    _pair(b, 0, 'EOF');
    return b.toString();
  }
}
