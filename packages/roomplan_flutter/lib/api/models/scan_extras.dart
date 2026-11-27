import 'package:roomplan_flutter/roomplan_flutter.dart';

// Room Measure additions to the final scan result: several rooms scanned in
// one session, their room types, and photos taken while scanning with where
// they were taken.

/// One room of a finished scan. Rooms scanned in the same session share
/// one coordinate system (RoomPlan merges them into one structure).
class ScannedRoom {
  const ScannedRoom({required this.room, this.type});

  final RoomData room;

  /// What RoomPlan recognised the room as: "kitchen", "bathroom",
  /// "bedroom", "livingRoom", "diningRoom", or null when it could not tell.
  final String? type;
}

/// A photo taken while scanning.
class ScanPhoto {
  const ScanPhoto({
    required this.path,
    required this.x,
    required this.z,
    this.dirX,
    this.dirZ,
    this.room = 0,
  });

  /// JPEG in a temporary folder: copy it to keep it.
  final String path;

  /// Where the phone was (world x, z: the rooms' coordinates), and the way
  /// it looked on the floor (unit x, z), when known.
  final double x, z;
  final double? dirX, dirZ;

  /// Index (in [ScanResult.rooms]) of the room being scanned when it was taken.
  final int room;

  factory ScanPhoto.fromJson(Map<String, dynamic> j) => ScanPhoto(
        path: j['path'] as String,
        x: (j['x'] as num).toDouble(),
        z: (j['z'] as num).toDouble(),
        dirX: (j['dirX'] as num?)?.toDouble(),
        dirZ: (j['dirZ'] as num?)?.toDouble(),
        room: (j['room'] as num?)?.toInt() ?? 0,
      );
}
