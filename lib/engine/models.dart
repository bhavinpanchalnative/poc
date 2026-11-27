import 'geometry.dart';

/// Nothing gets an automatic name ("Room 3", "Door 1"): the user must type a
/// name for every measurement (see `askNames` in ui/common.dart).
/// Whether [name] still has to be typed.
bool isUnnamed(String name) => name.trim().isEmpty;

/// What a name box says while it is empty: a name is mandatory.
const nameNeeded = 'Enter a name';

/// Where a scan came from.
enum CaptureSource { arTap, roomPlan, manual, sample, photo }

extension CaptureSourceLabel on CaptureSource {
  String get label => switch (this) {
        CaptureSource.arTap => 'Camera scan',
        CaptureSource.roomPlan => 'LiDAR auto-scan',
        CaptureSource.manual => 'Manual entry',
        CaptureSource.sample => 'Sample room',
        CaptureSource.photo => 'Measured from a photo',
      };
}

/// One measured wall: a segment on the floor plane, in metres.
///
/// Only the line through [a] and [b] matters to the engine. Its length is
/// set later by the neighbouring walls, so the user can tap anywhere along
/// a wall and hidden corners are not a problem.
class WallLine {
  const WallLine(this.a, this.b);

  final Vec2 a;
  final Vec2 b;

  Vec2 get mid => (a + b) / 2;
  Vec2 get dir => (b - a).normalized;
  double get length => a.distanceTo(b);
  Line2 get line => Line2(a, b - a);

  WallLine reversed() => WallLine(b, a);

  Map<String, dynamic> toJson() => {'a': a.toJson(), 'b': b.toJson()};

  factory WallLine.fromJson(Map<String, dynamic> j) => WallLine(
        Vec2.fromJson(j['a'] as Map<String, dynamic>),
        Vec2.fromJson(j['b'] as Map<String, dynamic>),
      );
}

enum OpeningType { door, window, opening }

extension OpeningTypeLabel on OpeningType {
  String get label => switch (this) {
        OpeningType.door => 'Door',
        OpeningType.window => 'Window',
        OpeningType.opening => 'Opening',
      };

  /// Typical height, used when none was measured.
  double get typicalHeight => switch (this) {
        OpeningType.door => 2.03,
        OpeningType.window => 1.2,
        OpeningType.opening => 2.03,
      };
}

/// How a door or window was measured.
enum OpeningMethod { manual, auto, touch, typed }

extension OpeningMethodLabel on OpeningMethod {
  String get label => switch (this) {
        OpeningMethod.manual => 'Marked in the scanner',
        OpeningMethod.auto => 'Detected automatically',
        OpeningMethod.touch => 'Measured by touch',
        OpeningMethod.typed => 'Entered by hand',
      };
}

/// A door, window or open gap on a wall of the finished plan.
class Opening {
  const Opening({
    required this.type,
    required this.wallIndex,
    required this.center,
    required this.width,
    this.height,
    this.sill,
    this.method = OpeningMethod.typed,
    this.estimated = false,
  });

  final OpeningType type;

  /// How it was measured.
  final OpeningMethod method;

  /// Its size rests on a surface the phone could only estimate.
  final bool estimated;

  /// Index into the scan's ordered walls.
  final int wallIndex;

  /// Centre position along the wall, 0 = start corner, 1 = end corner.
  final double center;

  /// Width in metres (not affected by the plan's scale factor).
  final double width;

  /// Height in metres, if known.
  final double? height;

  /// Height of the bottom edge above the floor (a window's sill), if known.
  final double? sill;

  Opening copyWith({
    OpeningType? type,
    int? wallIndex,
    double? center,
    double? width,
    double? height,
    double? sill,
    OpeningMethod? method,
    bool? estimated,
    bool clearHeight = false,
    bool clearSill = false,
  }) =>
      Opening(
        type: type ?? this.type,
        wallIndex: wallIndex ?? this.wallIndex,
        center: center ?? this.center,
        width: width ?? this.width,
        height: clearHeight ? null : (height ?? this.height),
        sill: clearSill ? null : (sill ?? this.sill),
        method: method ?? this.method,
        estimated: estimated ?? this.estimated,
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'wallIndex': wallIndex,
        'center': center,
        'width': width,
        if (height != null) 'height': height,
        if (sill != null) 'sill': sill,
        'method': method.name,
        if (estimated) 'estimated': true,
      };

  factory Opening.fromJson(Map<String, dynamic> j) => Opening(
        type: OpeningType.values.byName(j['type'] as String),
        wallIndex: j['wallIndex'] as int,
        center: (j['center'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num?)?.toDouble(),
        sill: (j['sill'] as num?)?.toDouble(),
        method: OpeningMethod.values.asNameMap()[j['method']] ?? OpeningMethod.typed,
        estimated: j['estimated'] as bool? ?? false,
      );
}

/// What a measured surface is, from how it lies in the room.
enum SurfaceKind { floor, raised, wall, sloped }

extension SurfaceKindLabel on SurfaceKind {
  String get label => switch (this) {
        SurfaceKind.floor => 'Floor area',
        SurfaceKind.raised => 'Worktop / shelf',
        SurfaceKind.wall => 'Wall surface',
        SurfaceKind.sloped => 'Sloped surface',
      };
}

/// A rectangular surface measured on its own: a wall section, a worktop, a
/// cabinet front, part of the floor.
class MeasuredSurface {
  const MeasuredSurface({
    required this.name,
    required this.kind,
    required this.width,
    required this.height,
    this.elevation,
    this.footprint = const [],
  });

  final String name;
  final SurfaceKind kind;

  /// Size in metres. For a horizontal surface "height" is its depth.
  final double width;
  final double height;

  /// Height above the floor of its lowest edge (wall surfaces) or of the
  /// surface itself (worktops), if the floor was known.
  final double? elevation;

  /// Where it is on the floor plan, in the scan's coordinates: the four
  /// corners seen from above, or for a wall surface its bottom edge (two
  /// points). Empty for surfaces typed in by hand.
  final List<Vec2> footprint;

  double get area => width * height;

  MeasuredSurface copyWith({
    String? name,
    SurfaceKind? kind,
    double? width,
    double? height,
    double? elevation,
    List<Vec2>? footprint,
  }) =>
      MeasuredSurface(
        name: name ?? this.name,
        kind: kind ?? this.kind,
        width: width ?? this.width,
        height: height ?? this.height,
        elevation: elevation ?? this.elevation,
        footprint: footprint ?? this.footprint,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'kind': kind.name,
        'width': width,
        'height': height,
        if (elevation != null) 'elevation': elevation,
        'footprint': footprint.map((p) => p.toJson()).toList(),
      };

  factory MeasuredSurface.fromJson(Map<String, dynamic> j) => MeasuredSurface(
        name: j['name'] as String,
        kind: SurfaceKind.values.byName(j['kind'] as String),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
        elevation: (j['elevation'] as num?)?.toDouble(),
        footprint: (j['footprint'] as List? ?? [])
            .map((p) => Vec2.fromJson(p as Map<String, dynamic>))
            .toList(),
      );
}

/// The raw output of any capture mode, plus the user's corrections.
/// This is what gets saved to disk.
class RoomScan {
  RoomScan({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.source,
    required List<WallLine> walls,
    List<Opening>? openings,
    List<MeasuredSurface>? surfaces,
    List<String>? photos,
    List<MeasuredLine>? lines,
    List<RoomElement>? elements,
    List<PhotoPin>? photoPins,
    this.scale = 1.0,
    this.keepOrientation = false,
    this.ceilingHeight,
  })  // Copied: a caller's list (a const one in the examples) must not be
      // what edits change, or adding a door to an example threw.
      : walls = List.of(walls),
        openings = List.of(openings ?? const []),
        surfaces = List.of(surfaces ?? const []),
        photos = List.of(photos ?? const []),
        lines = List.of(lines ?? const []),
        elements = List.of(elements ?? const []),
        photoPins = List.of(photoPins ?? const []);

  final String id;
  String name;
  final DateTime createdAt;
  final CaptureSource source;

  /// Walls in order around the room (either direction).
  final List<WallLine> walls;
  final List<Opening> openings;

  /// Surfaces measured on their own (wall sections, worktops, floor areas).
  final List<MeasuredSurface> surfaces;

  /// Photos of the room with its measurements drawn on them: file names in
  /// the app's photo folder (see ScanStore.photoFile).
  final List<String> photos;

  /// Point-to-point distances measured in the room.
  final List<MeasuredLine> lines;

  /// Other things found in the room by the scanner (furniture and fixtures
  /// such as a bed, sofa or sink). Doors and windows are in [openings].
  final List<RoomElement> elements;

  /// Where photos taken during the scan were taken, in the same coordinates
  /// as [walls] (LiDAR scans). Each names its file in [photos].
  final List<PhotoPin> photoPins;

  /// Floor-to-ceiling height (m), when the scanner measured it (LiDAR: from
  /// the walls' heights). The camera scanner can't, so it stays null.
  double? ceilingHeight;

  /// Correction factor for horizontal sizes, set when the user types the
  /// true length of one wall (fixes AR drift).
  double scale;

  /// True once the user has edited the shape: the walls are then already
  /// aligned, so the plan is not re-rotated to its longest wall.
  bool keepOrientation;

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'source': source.name,
        'walls': walls.map((w) => w.toJson()).toList(),
        'openings': openings.map((o) => o.toJson()).toList(),
        'surfaces': surfaces.map((s) => s.toJson()).toList(),
        'photos': photos,
        'lines': lines.map((l) => l.toJson()).toList(),
        if (elements.isNotEmpty)
          'elements': elements.map((e) => e.toJson()).toList(),
        if (photoPins.isNotEmpty)
          'photoPins': photoPins.map((p) => p.toJson()).toList(),
        'scale': scale,
        'keepOrientation': keepOrientation,
        if (ceilingHeight != null) 'ceilingHeight': ceilingHeight,
      };

  factory RoomScan.fromJson(Map<String, dynamic> j) => RoomScan(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        source: CaptureSource.values.byName(j['source'] as String),
        walls: (j['walls'] as List)
            .map((w) => WallLine.fromJson(w as Map<String, dynamic>))
            .toList(),
        openings: (j['openings'] as List? ?? [])
            .map((o) => Opening.fromJson(o as Map<String, dynamic>))
            .toList(),
        surfaces: (j['surfaces'] as List? ?? [])
            .map((s) => MeasuredSurface.fromJson(s as Map<String, dynamic>))
            .toList(),
        photos: (j['photos'] as List? ?? []).cast<String>(),
        lines: (j['lines'] as List? ?? [])
            .map((l) => MeasuredLine.fromJson(l as Map<String, dynamic>))
            .toList(),
        // Older saves also hold a ceiling 'height'; it is no longer used.
        elements: (j['elements'] as List? ?? [])
            .map((e) => RoomElement.fromJson(e as Map<String, dynamic>))
            .toList(),
        photoPins: (j['photoPins'] as List? ?? [])
            .map((p) => PhotoPin.fromJson(p as Map<String, dynamic>))
            .toList(),
        scale: (j['scale'] as num?)?.toDouble() ?? 1.0,
        keepOrientation: j['keepOrientation'] as bool? ?? false,
        // Older saves' 'height' was a typed guess, not a measurement: only
        // 'ceilingHeight' (LiDAR) is read.
        ceilingHeight: (j['ceilingHeight'] as num?)?.toDouble(),
      );
}

/// Where a photo was taken during a scan: [position] on the floor plan (in
/// the room's scan coordinates) and the way the camera looked
/// ([direction], unit length, null when unknown).
class PhotoPin {
  const PhotoPin({required this.file, required this.position, this.direction, this.panorama = false});

  /// The photo's file name (one of RoomScan.photos).
  final String file;
  final Vec2 position;
  final Vec2? direction;

  /// A 360° photo (equirectangular, from a 360° camera): shown in the 360°
  /// viewer and marked "360" on the plan.
  final bool panorama;

  PhotoPin copyWith({Vec2? position, Vec2? direction}) => PhotoPin(
      file: file,
      position: position ?? this.position,
      direction: direction ?? this.direction,
      panorama: panorama);

  Map<String, dynamic> toJson() => {
        'file': file,
        'position': position.toJson(),
        if (direction != null) 'direction': direction!.toJson(),
        if (panorama) 'panorama': true,
      };

  factory PhotoPin.fromJson(Map<String, dynamic> j) => PhotoPin(
        file: j['file'] as String,
        position: Vec2.fromJson(j['position'] as Map<String, dynamic>),
        direction: j['direction'] == null
            ? null
            : Vec2.fromJson(j['direction'] as Map<String, dynamic>),
        panorama: j['panorama'] as bool? ?? false,
      );
}

/// A straight-line distance measured between two points.
class MeasuredLine {
  const MeasuredLine({
    required this.name,
    required this.length,
    this.run,
    this.rise,
    this.footprint = const [],
    this.measuredAt,
    this.estimated = false,
  });

  final String name;

  /// At least one end was placed on a surface the phone could not measure
  /// directly (a plain wall): the distance is approximate.
  final bool estimated;

  /// Distance between the two points, in metres.
  final double length;

  /// Its horizontal and vertical parts, when measured in 3D.
  final double? run, rise;

  /// Where it is on the floor plan, in the scan's coordinates: its two ends
  /// seen from above. Empty for stand-alone measurements.
  final List<Vec2> footprint;

  final DateTime? measuredAt;

  MeasuredLine copyWith(
          {String? name,
          List<Vec2>? footprint,
          double? length,
          double? run,
          double? rise}) =>
      MeasuredLine(
        name: name ?? this.name,
        length: length ?? this.length,
        run: run ?? this.run,
        rise: rise ?? this.rise,
        footprint: footprint ?? this.footprint,
        measuredAt: measuredAt,
        estimated: estimated,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'length': length,
        if (estimated) 'estimated': true,
        if (run != null) 'run': run,
        if (rise != null) 'rise': rise,
        'footprint': footprint.map((p) => p.toJson()).toList(),
        if (measuredAt != null) 'measuredAt': measuredAt!.toIso8601String(),
      };

  factory MeasuredLine.fromJson(Map<String, dynamic> j) => MeasuredLine(
        name: j['name'] as String,
        length: (j['length'] as num).toDouble(),
        run: (j['run'] as num?)?.toDouble(),
        rise: (j['rise'] as num?)?.toDouble(),
        footprint: (j['footprint'] as List? ?? [])
            .map((p) => Vec2.fromJson(p as Map<String, dynamic>))
            .toList(),
        measuredAt: j['measuredAt'] == null
            ? null
            : DateTime.parse(j['measuredAt'] as String),
        estimated: j['estimated'] as bool? ?? false,
      );
}

/// Something other than a wall, door or window found in a scanned room:
/// furniture or a fixture (Apple RoomPlan on LiDAR devices finds these).
class RoomElement {
  const RoomElement({
    required this.kind,
    this.width,
    this.depth,
    this.height,
    this.position,
    this.angle,
  });

  /// What it is, e.g. "Bed", "Sofa", "Sink".
  final String kind;

  /// Its size in metres, when known.
  final double? width, depth, height;

  /// Its centre on the floor plan, in the scan's coordinates.
  final Vec2? position;

  /// Which way its width runs, in the scan's coordinates (radians from +x
  /// towards +y); null when not known.
  final double? angle;

  RoomElement copyWith({Vec2? position, double? angle}) => RoomElement(
      kind: kind,
      width: width,
      depth: depth,
      height: height,
      position: position ?? this.position,
      angle: angle ?? this.angle);

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (width != null) 'width': width,
        if (depth != null) 'depth': depth,
        if (height != null) 'height': height,
        if (position != null) 'position': position!.toJson(),
        if (angle != null) 'angle': angle,
      };

  factory RoomElement.fromJson(Map<String, dynamic> j) => RoomElement(
        kind: j['kind'] as String,
        width: (j['width'] as num?)?.toDouble(),
        depth: (j['depth'] as num?)?.toDouble(),
        height: (j['height'] as num?)?.toDouble(),
        position: j['position'] == null
            ? null
            : Vec2.fromJson(j['position'] as Map<String, dynamic>),
        angle: (j['angle'] as num?)?.toDouble(),
      );
}

/// How many of each kind of thing a room has: "2 Doors", "1 Bed".
/// Doors, windows and open gaps come first, then other elements by kind.
List<(String, int)> roomElementCounts(RoomScan scan) {
  final counts = <String, int>{};
  void add(String k) => counts[k] = (counts[k] ?? 0) + 1;
  for (final t in OpeningType.values) {
    final n = scan.openings.where((o) => o.type == t).length;
    if (n > 0) counts[t.label] = n;
  }
  for (final e in scan.elements) {
    add(e.kind);
  }
  return [for (final e in counts.entries) (e.key, e.value)];
}

/// A door or window measured on its own, without a room outline around it.
/// [room] says which room it belongs to, when the user gave one.
class SavedOpening {
  const SavedOpening({
    required this.id,
    required this.name,
    required this.type,
    required this.width,
    this.room = '',
    this.height,
    this.sill,
    this.method = OpeningMethod.auto,
    this.estimated = false,
    required this.measuredAt,
  });

  final String id;
  final String name;

  /// The room it is in (typed by the user); empty when not given.
  final String room;
  final OpeningType type;
  final double width;
  final double? height;

  /// Bottom edge above the floor (windows), when the floor was known.
  final double? sill;
  final OpeningMethod method;
  final bool estimated;
  final DateTime measuredAt;

  SavedOpening copyWith(
          {String? name,
          String? room,
          double? width,
          double? height,
          double? sill,
          bool? estimated}) =>
      SavedOpening(
        id: id,
        name: name ?? this.name,
        room: room ?? this.room,
        type: type,
        width: width ?? this.width,
        height: height ?? this.height,
        sill: sill ?? this.sill,
        method: method,
        estimated: estimated ?? this.estimated,
        measuredAt: measuredAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (room.isNotEmpty) 'room': room,
        'type': type.name,
        'width': width,
        if (height != null) 'height': height,
        if (sill != null) 'sill': sill,
        'method': method.name,
        if (estimated) 'estimated': true,
        'measuredAt': measuredAt.toIso8601String(),
      };

  factory SavedOpening.fromJson(Map<String, dynamic> j) => SavedOpening(
        id: j['id'] as String,
        name: j['name'] as String,
        room: j['room'] as String? ?? '',
        type: OpeningType.values.byName(j['type'] as String),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num?)?.toDouble(),
        sill: (j['sill'] as num?)?.toDouble(),
        method: OpeningMethod.values.asNameMap()[j['method']] ?? OpeningMethod.auto,
        estimated: j['estimated'] as bool? ?? false,
        measuredAt: DateTime.parse(j['measuredAt'] as String),
      );
}

/// One room placed on a [FloorMap].
class MapRoom {
  MapRoom({required this.scanId, this.offset = Vec2.zero, this.quarterTurns = 0});

  final String scanId;

  /// Where the room's plan sits on the map, in metres.
  Vec2 offset;

  /// Rotation in 90 degree steps (counter-clockwise), about the room's
  /// centre.
  int quarterTurns;

  Map<String, dynamic> toJson() => {
        'scanId': scanId,
        'offset': offset.toJson(),
        'quarterTurns': quarterTurns,
      };

  factory MapRoom.fromJson(Map<String, dynamic> j) => MapRoom(
        scanId: j['scanId'] as String,
        offset: Vec2.fromJson(j['offset'] as Map<String, dynamic>),
        quarterTurns: j['quarterTurns'] as int? ?? 0,
      );
}

/// Several rooms arranged together: the plan of a whole flat or floor.
class FloorMap {
  FloorMap({
    required this.id,
    required this.name,
    required this.createdAt,
    List<MapRoom>? rooms,
  }) : rooms = rooms ?? [];

  final String id;
  String name;
  final DateTime createdAt;
  final List<MapRoom> rooms;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'rooms': rooms.map((r) => r.toJson()).toList(),
      };

  factory FloorMap.fromJson(Map<String, dynamic> j) => FloorMap(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        rooms: (j['rooms'] as List? ?? [])
            .map((r) => MapRoom.fromJson(r as Map<String, dynamic>))
            .toList(),
      );
}
