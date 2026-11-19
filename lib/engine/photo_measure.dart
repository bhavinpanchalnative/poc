import 'geometry.dart';

/// A perspective mapping between two planes (here: a photo and the floor).
class Homography {
  const Homography(this.m);

  /// Row-major 3x3, with m[8] = 1.
  final List<double> m;

  /// The mapping that sends each of the four [from] points to the matching
  /// [to] point. Null when the points are degenerate (three in a line).
  static Homography? fromPoints(List<Vec2> from, List<Vec2> to) {
    assert(from.length == 4 && to.length == 4);
    // Solve for h0..h7 (h8 = 1): for each pair,
    //   u = (h0 x + h1 y + h2) / (h6 x + h7 y + 1)
    //   v = (h3 x + h4 y + h5) / (h6 x + h7 y + 1)
    final a = List.generate(8, (_) => List.filled(9, 0.0));
    for (var i = 0; i < 4; i++) {
      final x = from[i].x, y = from[i].y, u = to[i].x, v = to[i].y;
      a[2 * i]
        ..[0] = x
        ..[1] = y
        ..[2] = 1
        ..[6] = -u * x
        ..[7] = -u * y
        ..[8] = u;
      a[2 * i + 1]
        ..[3] = x
        ..[4] = y
        ..[5] = 1
        ..[6] = -v * x
        ..[7] = -v * y
        ..[8] = v;
    }
    final h = _solve(a);
    return h == null ? null : Homography([...h, 1.0]);
  }

  /// The projective scale at [p]; its sign tells which side of the
  /// plane's horizon [p] is on.
  double weight(Vec2 p) => m[6] * p.x + m[7] * p.y + m[8];

  Vec2 apply(Vec2 p) {
    final w = weight(p);
    return Vec2((m[0] * p.x + m[1] * p.y + m[2]) / w,
        (m[3] * p.x + m[4] * p.y + m[5]) / w);
  }

  /// Gaussian elimination with partial pivoting on an n x (n+1) system.
  static List<double>? _solve(List<List<double>> a) {
    final n = a.length;
    for (var c = 0; c < n; c++) {
      var p = c;
      for (var r = c + 1; r < n; r++) {
        if (a[r][c].abs() > a[p][c].abs()) p = r;
      }
      if (a[p][c].abs() < 1e-12) return null;
      final t = a[c];
      a[c] = a[p];
      a[p] = t;
      for (var r = 0; r < n; r++) {
        if (r == c) continue;
        final f = a[r][c] / a[c][c];
        if (f == 0) continue;
        for (var k = c; k <= n; k++) {
          a[r][k] -= f * a[c][k];
        }
      }
    }
    return [for (var i = 0; i < n; i++) a[i][n] / a[i][i]];
  }
}

/// A rectangle of known size lying flat on the floor, used as the scale in
/// a photo.
class FloorReference {
  const FloorReference(this.label, this.width, this.depth);

  final String label;
  final double width, depth;

  /// Best first: the larger the reference, the smaller the error when the
  /// room's corners are measured far from it. Paper sheets are only good
  /// for a rough figure.
  static const presets = [
    FloorReference('60 × 60 cm floor tile', 0.60, 0.60),
    FloorReference('30 × 30 cm floor tile', 0.30, 0.30),
    FloorReference('A4 paper (rough)', 0.297, 0.210),
    FloorReference('US Letter paper (rough)', 0.2794, 0.2159),
  ];
}

/// Room corners on the floor, in metres, from a photo.
///
/// [reference] holds the four tapped corners of [ref] in the photo, in order
/// around it, starting at one end of a long side; [corners] are the room's
/// floor corners tapped in the photo, in order around the room. With three
/// corners the room is taken to be a rectangle and the fourth is completed.
/// Returns null when the reference taps are unusable.
List<Vec2>? floorCornersFromPhoto({
  required List<Vec2> reference,
  required FloorReference ref,
  required List<Vec2> corners,
}) {
  if (reference.length != 4) return null;
  final h = Homography.fromPoints(reference, [
    Vec2.zero,
    Vec2(ref.width, 0),
    Vec2(ref.width, ref.depth),
    Vec2(0, ref.depth),
  ]);
  if (h == null) return null;
  // Floor points above the floor's horizon in the photo are not on the
  // floor at all: their scale factor flips sign relative to the reference.
  final refSide = h.weight(reference[0]).sign;
  if (corners.any((c) => h.weight(c).sign != refSide)) return null;
  final pts = [for (final c in corners) h.apply(c)];
  if (pts.any((p) => !p.x.isFinite || !p.y.isFinite)) return null;
  if (pts.length == 3) {
    // a, b, c with the right angle at b: the fourth corner is a + c - b.
    pts.add(pts[0] + pts[2] - pts[1]);
  }
  return pts;
}
