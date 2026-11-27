/// Contains metadata about the scanning session.
class ScanMetadata {
  /// The total duration of the scanning process.
  final Duration scanDuration;

  /// The model of the device used for the scan (e.g., "iPhone14,3").
  final String deviceModel;

  /// Indicates whether the device has a LiDAR sensor, which affects accuracy.
  final bool hasLidar;

  /// Room Measure: in live updates, how many of the 12 directions (30° each)
  /// the camera has looked in so far; null when not reported.
  final int? lookRoundSectors;

  /// Room Measure: in live updates, which room of the session is being
  /// scanned (0 for the first; it goes up after "Room done" → next room).
  final int? roomIndex;

  /// Creates a [ScanMetadata] object.
  const ScanMetadata({
    required this.scanDuration,
    required this.deviceModel,
    required this.hasLidar,
    this.lookRoundSectors,
    this.roomIndex,
  });

  /// Creates a [ScanMetadata] from a JSON map.
  factory ScanMetadata.fromJson(Map<String, dynamic> json) {
    return ScanMetadata(
      scanDuration: Duration(
        microseconds:
            ((json['scanDuration'] as num?)?.toDouble() ?? 0.0 * 1000000)
                .round(),
      ),
      deviceModel: json['deviceModel'] as String? ?? 'Unknown',
      hasLidar: json['hasLidar'] as bool? ?? false,
      // Native metadata values arrive as strings.
      lookRoundSectors: switch (json['lookRoundSectors']) {
        final num n => n.toInt(),
        final String s => int.tryParse(s),
        _ => null,
      },
      roomIndex: switch (json['roomIndex']) {
        final num n => n.toInt(),
        final String s => int.tryParse(s),
        _ => null,
      },
    );
  }

  /// Converts this [ScanMetadata] to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'scanDuration': scanDuration.inMicroseconds / 1000000.0,
      'deviceModel': deviceModel,
      'hasLidar': hasLidar,
      if (lookRoundSectors != null) 'lookRoundSectors': lookRoundSectors,
      if (roomIndex != null) 'roomIndex': roomIndex,
    };
  }

  /// Creates a copy of this metadata with modified values.
  ScanMetadata copyWith({
    Duration? scanDuration,
    String? deviceModel,
    bool? hasLidar,
    int? lookRoundSectors,
    int? roomIndex,
  }) {
    return ScanMetadata(
      scanDuration: scanDuration ?? this.scanDuration,
      deviceModel: deviceModel ?? this.deviceModel,
      hasLidar: hasLidar ?? this.hasLidar,
      lookRoundSectors: lookRoundSectors ?? this.lookRoundSectors,
      roomIndex: roomIndex ?? this.roomIndex,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is ScanMetadata &&
        other.scanDuration == scanDuration &&
        other.deviceModel == deviceModel &&
        other.hasLidar == hasLidar &&
        other.lookRoundSectors == lookRoundSectors &&
        other.roomIndex == roomIndex;
  }

  @override
  int get hashCode {
    return Object.hash(
      scanDuration,
      deviceModel,
      hasLidar,
      lookRoundSectors,
      roomIndex,
    );
  }

  @override
  String toString() {
    return 'ScanMetadata(scanDuration: ${scanDuration.inSeconds}s, '
        'deviceModel: $deviceModel, '
        'hasLidar: $hasLidar)';
  }
}
