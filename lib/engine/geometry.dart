import 'dart:math' as math;

/// A 2D point or vector on the floor plane, in metres.
///
/// AR frameworks are Y-up, so a 3D world point (x, y, z) maps to
/// `Vec2(x, z)` on the floor.
class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  static const zero = Vec2(0, 0);

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);
  Vec2 operator /(double s) => Vec2(x / s, y / s);

  double dot(Vec2 o) => x * o.x + y * o.y;
  double cross(Vec2 o) => x * o.y - y * o.x;
  double get length => math.sqrt(x * x + y * y);
  double get angle => math.atan2(y, x);
  double distanceTo(Vec2 o) => (this - o).length;

  Vec2 get normalized {
    final l = length;
    return l == 0 ? Vec2.zero : this / l;
  }

  /// Rotated 90 degrees counter-clockwise.
  Vec2 get perp => Vec2(-y, x);

  Vec2 rotate(double radians) {
    final c = math.cos(radians), s = math.sin(radians);
    return Vec2(x * c - y * s, x * s + y * c);
  }

  static Vec2 fromAngle(double radians) =>
      Vec2(math.cos(radians), math.sin(radians));

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory Vec2.fromJson(Map<String, dynamic> j) =>
      Vec2((j['x'] as num).toDouble(), (j['y'] as num).toDouble());

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}

/// An infinite line through [point] with unit direction [dir].
class Line2 {
  Line2(this.point, Vec2 dir) : dir = dir.normalized;

  final Vec2 point;
  final Vec2 dir;

  /// Intersection with [other], or null when the lines are close to parallel
  /// (the angle between them is below [minAngleRadians]).
  Vec2? intersect(Line2 other, {double minAngleRadians = 10 * math.pi / 180}) {
    final denom = dir.cross(other.dir);
    if (denom.abs() < math.sin(minAngleRadians)) return null;
    final t = (other.point - point).cross(other.dir) / denom;
    return point + dir * t;
  }

  /// Signed position of [p] along the line, measured from [point].
  double project(Vec2 p) => (p - point).dot(dir);

  double distanceTo(Vec2 p) => (p - point).cross(dir).abs();
}

double degToRad(double d) => d * math.pi / 180;
double radToDeg(double r) => r * 180 / math.pi;

/// Wraps an angle to (-pi, pi].
double wrapAngle(double a) {
  var r = a % (2 * math.pi);
  if (r > math.pi) r -= 2 * math.pi;
  if (r <= -math.pi) r += 2 * math.pi;
  return r;
}

/// Signed area of a polygon (shoelace). Positive when counter-clockwise.
double signedArea(List<Vec2> pts) {
  var s = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    s += a.cross(b);
  }
  return s / 2;
}

Vec2 polygonCentroid(List<Vec2> pts) {
  final a = signedArea(pts);
  if (a.abs() < 1e-9) {
    var sx = 0.0, sy = 0.0;
    for (final p in pts) {
      sx += p.x;
      sy += p.y;
    }
    return Vec2(sx / pts.length, sy / pts.length);
  }
  var cx = 0.0, cy = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i], q = pts[(i + 1) % pts.length];
    final f = p.cross(q);
    cx += (p.x + q.x) * f;
    cy += (p.y + q.y) * f;
  }
  return Vec2(cx / (6 * a), cy / (6 * a));
}
