import CoreGraphics
import Foundation
import simd

// Geometry of the live 2D floor plan drawn while a room is scanned: the twin
// of LivePlan.kt (keep them in sync; LivePlanTest.kt tests both's logic).

/// World floor plan (x, z) to panel points, heading-up: the way the camera
/// looks is always up on the panel, so the wall in front of the phone is the
/// one at the top of the plan, right under the camera view. (cx, cz), the
/// room's centre, is drawn at the panel's centre (px, py).
struct PlanTransform {
  let cx: Float, cz: Float
  /// Unit horizontal forward of the camera.
  let fx: Float, fz: Float
  /// Points per metre.
  let scale: CGFloat
  let px: CGFloat, py: CGFloat

  func point(_ wx: Float, _ wz: Float) -> CGPoint {
    // Camera right on the floor: forward turned 90° clockwise seen from above.
    let rx = -fz, rz = fx
    let dx = wx - cx, dz = wz - cz
    return CGPoint(x: px + CGFloat(dx * rx + dz * rz) * scale,
                   y: py - CGFloat(dx * fx + dz * fz) * scale)
  }

  func point(_ p: V3) -> CGPoint { point(p.x, p.z) }
}

enum LivePlan {
  /// Smallest area shown (m across), so the first wall found isn't huge.
  static let minSpan: Float = 3

  /// The transform fitting `points` (and the camera at `cam`) in `rect`
  /// with `pad` points to spare. The scale comes from the distance of the
  /// farthest point from the centre, which does not change as the plan turns
  /// with the camera, so the plan doesn't zoom while the user turns round.
  static func fit(_ points: [V3], cam: V3, forward: V3, in rect: CGRect, pad: CGFloat) -> PlanTransform {
    let all = points + [cam]
    let minX = all.map { $0.x }.min()!, maxX = all.map { $0.x }.max()!
    let minZ = all.map { $0.z }.min()!, maxZ = all.map { $0.z }.max()!
    let cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2
    var r = minSpan / 2
    for p in all { r = max(r, ((p.x - cx) * (p.x - cx) + (p.z - cz) * (p.z - cz)).squareRoot()) }
    let half = max(1, min(rect.width, rect.height) / 2 - pad)
    var fx = forward.x, fz = forward.z
    let l = (fx * fx + fz * fz).squareRoot()
    if l < 1e-3 { fx = 0; fz = -1 } else { fx /= l; fz /= l }
    return PlanTransform(cx: cx, cz: cz, fx: fx, fz: fz, scale: half / CGFloat(r),
                         px: rect.midX, py: rect.midY)
  }

  /// A detected wall surface (its outline, world points) as a line on the
  /// floor plan: its two extreme points along its main direction; nil when
  /// it is too small to show.
  static func wallLine(_ points: [V3], minLength: Float = 0.25) -> (V3, V3)? {
    if points.count < 2 { return nil }
    let n = Float(points.count)
    let mx = points.reduce(0) { $0 + $1.x } / n
    let mz = points.reduce(0) { $0 + $1.z } / n
    var sxx: Float = 0, sxz: Float = 0, szz: Float = 0
    for p in points {
      let dx = p.x - mx, dz = p.z - mz
      sxx += dx * dx
      sxz += dx * dz
      szz += dz * dz
    }
    let ang = 0.5 * atan2(2 * sxz, sxx - szz)
    let dx = cos(ang), dz = sin(ang)
    var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
    for p in points {
      let t = (p.x - mx) * dx + (p.z - mz) * dz
      lo = min(lo, t)
      hi = max(hi, t)
    }
    if hi - lo < minLength { return nil }
    return (V3(mx + dx * lo, 0, mz + dz * lo), V3(mx + dx * hi, 0, mz + dz * hi))
  }

  /// A door drawn as on a floor plan: the leaf standing open at 90° from the
  /// hinge `a` into the room (towards `inside`), and its swing, a quarter
  /// circle from the leaf's end to `b`. Returns the leaf's end and the arc's
  /// points (from the leaf's end to `b`), on the floor (y 0).
  static func doorSwing(_ a: V3, _ b: V3, inside: V3, steps: Int = 12) -> (leaf: V3, arc: [V3]) {
    let wx = b.x - a.x, wz = b.z - a.z
    let w = (wx * wx + wz * wz).squareRoot()
    if w < 1e-4 { return (a.withY(0), [a.withY(0)]) }
    var nx = -wz / w, nz = wx / w
    if (inside.x - a.x) * nx + (inside.z - a.z) * nz < 0 {
      nx = -nx
      nz = -nz
    }
    let ux = wx / w, uz = wz / w
    let leaf = V3(a.x + nx * w, 0, a.z + nz * w)
    let arc = (0...steps).map { i -> V3 in
      let t = Float.pi / 2 * Float(i) / Float(steps)
      let c = cos(t), s = sin(t)
      return V3(a.x + (nx * c + ux * s) * w, 0, a.z + (nz * c + uz * s) * w)
    }
    return (leaf, arc)
  }

  /// Wall lines found so far (`wallLine` of each wall surface) joined where
  /// they are parts of the same wall: about parallel, on the same line and
  /// overlapping or close end to end. A wall seen as several surfaces is
  /// then drawn, and measured, as one line as soon as it is found.
  static func mergeWalls(_ lines: [(V3, V3)], maxAngleDeg: Float = 12, maxOffset: Float = 0.15,
                         maxGap: Float = 0.3) -> [(V3, V3)] {
    var out = lines.map { ($0.0.withY(0), $0.1.withY(0)) }
    let cosMax = cos(maxAngleDeg * .pi / 180)
    var merged = true
    while merged {
      merged = false
      search: for i in out.indices {
        for j in (i + 1)..<out.count {
          if let m = join(out[i], out[j], cosMax: cosMax, maxOffset: maxOffset, maxGap: maxGap) {
            out[i] = m
            out.remove(at: j)
            merged = true
            break search
          }
        }
      }
    }
    return out
  }

  /// Walls found so far (`mergeWalls`) joined at the corners: where two walls
  /// meet at an angle (at least `minAngleDeg`) and an end of each is within
  /// `reach` m of where their lines cross, both ends are moved to that point,
  /// which becomes a corner. So the lines drawn run along the walls and turn
  /// at the corners, growing as more walls are found.
  static func connectWalls(_ walls: [(V3, V3)], reach: Float = 0.6,
                           minAngleDeg: Float = 30) -> (walls: [(V3, V3)], corners: [V3]) {
    var ends = walls.map { [$0.0.withY(0), $0.1.withY(0)] }
    var used = walls.map { _ in [false, false] }
    var corners: [V3] = []
    let sinMin = sin(minAngleDeg * .pi / 180)
    for i in walls.indices {
      for j in walls.indices where j > i {
        let a = [walls[i].0, walls[i].1], b = [walls[j].0, walls[j].1]
        let la = a[0].dist2d(a[1]), lb = b[0].dist2d(b[1])
        if la < 1e-4 || lb < 1e-4 { continue }
        let ux = (a[1].x - a[0].x) / la, uz = (a[1].z - a[0].z) / la
        let vx = (b[1].x - b[0].x) / lb, vz = (b[1].z - b[0].z) / lb
        let cross = ux * vz - uz * vx
        if abs(cross) < sinMin { continue }
        let t = ((b[0].x - a[0].x) * vz - (b[0].z - a[0].z) * vx) / cross
        let p = V3(a[0].x + ux * t, 0, a[0].z + uz * t)
        let ei = a[0].dist2d(p) <= a[1].dist2d(p) ? 0 : 1
        let ej = b[0].dist2d(p) <= b[1].dist2d(p) ? 0 : 1
        if used[i][ei] || used[j][ej] { continue }
        if a[ei].dist2d(p) > reach || b[ej].dist2d(p) > reach { continue }
        ends[i][ei] = p
        ends[j][ej] = p
        used[i][ei] = true
        used[j][ej] = true
        corners.append(p)
      }
    }
    return (ends.map { ($0[0], $0[1]) }, corners)
  }

  /// `a` and `b` as one line, or nil when they are different walls.
  private static func join(_ a: (V3, V3), _ b: (V3, V3), cosMax: Float, maxOffset: Float,
                           maxGap: Float) -> (V3, V3)? {
    func len(_ s: (V3, V3)) -> Float {
      let dx = s.1.x - s.0.x, dz = s.1.z - s.0.z
      return (dx * dx + dz * dz).squareRoot()
    }
    let la = len(a), lb = len(b)
    if la < 1e-4 || lb < 1e-4 { return nil }
    // The longer line's direction is the wall's.
    let (long, short) = la >= lb ? (a, b) : (b, a)
    let l = max(la, lb), ls = min(la, lb)
    let o = long.0
    let ux = (long.1.x - o.x) / l, uz = (long.1.z - o.z) / l
    let vx = (short.1.x - short.0.x) / ls, vz = (short.1.z - short.0.z) / ls
    if abs(ux * vx + uz * vz) < cosMax { return nil }
    let pts = [a.0, a.1, b.0, b.1]
    func off(_ p: V3) -> Float { -(p.x - o.x) * uz + (p.z - o.z) * ux }
    for p in pts where abs(off(p)) > maxOffset { return nil }
    func t(_ p: V3) -> Float { (p.x - o.x) * ux + (p.z - o.z) * uz }
    let alo = min(t(a.0), t(a.1)), ahi = max(t(a.0), t(a.1))
    let blo = min(t(b.0), t(b.1)), bhi = max(t(b.0), t(b.1))
    if max(alo, blo) - min(ahi, bhi) > maxGap { return nil }
    let lo = min(alo, blo), hi = max(ahi, bhi)
    // Along the line through the middle of both.
    let mid = pts.reduce(0) { $0 + off($1) } / Float(pts.count)
    let bx = o.x - uz * mid, bz = o.z + ux * mid
    return (V3(bx + ux * lo, 0, bz + uz * lo), V3(bx + ux * hi, 0, bz + uz * hi))
  }

  /// Area of a polygon on the floor plan (m², shoelace).
  static func area(_ corners: [V3]) -> Float {
    var s: Float = 0
    for i in corners.indices {
      let p = corners[i], q = corners[(i + 1) % corners.count]
      s += p.x * q.z - q.x * p.z
    }
    return abs(s) / 2
  }
}
