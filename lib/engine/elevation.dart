import 'dart:math' as math;

import 'floor_plan_builder.dart';
import 'models.dart';

/// A door or window seen from the front, on its wall: everything needed to
/// draw and dimension it, in metres.
///
/// Horizontal positions are measured from the wall's start corner; heights
/// from the floor. Values the scan did not measure are filled with typical
/// ones and flagged, so the drawing can show them as assumed.
class OpeningElevation {
  const OpeningElevation({
    required this.type,
    required this.wallIndex,
    required this.wallLength,
    required this.wallHeight,
    required this.left,
    required this.width,
    required this.height,
    required this.sill,
    this.heightAssumed = false,
    this.sillAssumed = false,
    this.estimated = false,
    this.standalone = false,
  });

  /// A door or window measured without a room: drawn on a short stretch of
  /// wall, with only its own dimensions.
  factory OpeningElevation.standalone({
    required OpeningType type,
    required double width,
    double? height,
    double? sill,
    bool estimated = false,
  }) {
    final h = height ?? type.typicalHeight;
    final s = type == OpeningType.window ? (sill ?? typicalSill) : 0.0;
    const margin = 0.45;
    return OpeningElevation(
      type: type,
      wallIndex: 0,
      wallLength: width + 2 * margin,
      wallHeight: math.max(s + h + 0.35, type == OpeningType.window ? 2.4 : h + 0.35),
      left: margin,
      width: width,
      height: h,
      sill: s,
      heightAssumed: height == null,
      sillAssumed: type == OpeningType.window && sill == null,
      estimated: estimated,
      standalone: true,
    );
  }

  /// Builds the front view of [o] on its wall of [plan].
  factory OpeningElevation.of(FloorPlan plan, Opening o) {
    final i = o.wallIndex.clamp(0, plan.wallCount - 1);
    final len = plan.wallLength(i);
    final width = math.min(o.width, len);
    final h = o.height ?? o.type.typicalHeight;
    final sill = o.type == OpeningType.window ? (o.sill ?? typicalSill) : 0.0;
    // The wall's real height when the scan measured it (LiDAR); otherwise
    // a backdrop with room above the opening to drag its top edge up.
    final ceiling = plan.ceilingHeight;
    final wallH = ceiling != null
        ? math.max(ceiling, sill + h)
        : math.max(defaultWallHeight, sill + h + 0.4);
    return OpeningElevation(
      type: o.type,
      wallIndex: i,
      wallLength: len,
      wallHeight: wallH,
      left: (o.center * len - width / 2).clamp(0.0, math.max(0.0, len - width)),
      width: width,
      height: h,
      sill: sill,
      heightAssumed: o.height == null,
      sillAssumed: o.type == OpeningType.window && o.sill == null,
      estimated: o.estimated,
    );
  }

  static const defaultWallHeight = 2.5;

  /// Highest an opening's top may go (m).
  static const maxHead = 4.0;
  static const typicalSill = 0.9;

  /// Smallest size an edit may leave.
  static const minSize = 0.1;

  final OpeningType type;
  final int wallIndex;
  final double wallLength, wallHeight;

  /// From the wall's start corner to the opening's left edge.
  final double left;
  final double width, height;

  /// Bottom edge above the floor (0 for doors).
  final double sill;

  final bool heightAssumed, sillAssumed, estimated;

  /// No room around it: the wall is only a backdrop and is not dimensioned.
  final bool standalone;

  double get right => left + width;

  /// From the opening's right edge to the wall's end corner.
  double get rightGap => wallLength - right;

  /// Top edge above the floor.
  double get head => sill + height;

  bool get isWindow => type == OpeningType.window;

  OpeningElevation copyWith({
    double? left,
    double? width,
    double? height,
    double? sill,
  }) =>
      OpeningElevation(
        type: type,
        wallIndex: wallIndex,
        wallLength: wallLength,
        // No ceiling is measured: the wall behind is only a backdrop; it
        // grows to fit a taller opening rather than limiting it.
        wallHeight: math.max(
            wallHeight, (sill ?? this.sill) + (height ?? this.height) + 0.1),
        left: left ?? this.left,
        width: width ?? this.width,
        height: height ?? this.height,
        sill: sill ?? this.sill,
        heightAssumed: height == null && heightAssumed,
        sillAssumed: sill == null && sillAssumed,
        estimated: estimated,
        standalone: standalone,
      );

  /// Moves one edge to [value] (metres in wall coordinates), keeping the
  /// opposite edge where it is and the opening inside the wall.
  OpeningElevation withEdge(OpeningEdge edge, double value) {
    switch (edge) {
      case OpeningEdge.left:
        final l = value.clamp(0.0, right - minSize);
        return copyWith(left: l, width: right - l);
      case OpeningEdge.right:
        final r = value.clamp(left + minSize, wallLength);
        return copyWith(width: r - left);
      case OpeningEdge.top:
        final t = value.clamp(sill + minSize, maxHead);
        return copyWith(height: t - sill);
      case OpeningEdge.bottom:
        // A door stands on the floor.
        if (!isWindow) return this;
        final b = value.clamp(0.0, head - minSize);
        return copyWith(sill: b, height: head - b);
    }
  }

  /// The opening as stored in the scan: position along the wall (0..1),
  /// width, height and sill. The measuring method is kept; edited values
  /// are no longer estimates.
  Opening toOpening(Opening original) => original.copyWith(
        wallIndex: wallIndex,
        center: wallLength <= 0 ? 0.5 : (left + width / 2) / wallLength,
        width: width,
        height: heightAssumed ? null : height,
        sill: isWindow && !sillAssumed ? sill : null,
        clearHeight: heightAssumed,
        clearSill: !isWindow || sillAssumed,
      );
}

enum OpeningEdge { left, right, top, bottom }
