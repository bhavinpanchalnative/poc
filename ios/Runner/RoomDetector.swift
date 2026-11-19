import Foundation
import simd

// Room geometry used by the camera scanner. A direct port of the Android
// RoomDetector.kt, kept free of ARKit types so both platforms detect rooms
// the same way. Keep the two files in sync.

typealias V3 = SIMD3<Float>

extension SIMD3 where Scalar == Float {
  func dist2d(_ o: V3) -> Float {
    let dx = x - o.x
    let dz = z - o.z
    return (dx * dx + dz * dz).squareRoot()
  }

  func withY(_ ny: Float) -> V3 { V3(x, ny, z) }
}

/// A wall surface as a line on the floor plan with its extent along the line.
struct WallSegment {
  let cx: Float, cz: Float, dx: Float, dz: Float
  let tMin: Float, tMax: Float
  /// Highest point of the detected surface.
  let top: Float
}

/// Room outline found automatically from the detected walls.
struct AutoRoom {
  /// Corners at floor level, in order around the room.
  let corners: [V3]
  /// Side i (corner i to i+1) was inferred rather than seen as a wall.
  let estimated: [Bool]
  let wallsUsed: Int
  let height: Float?
  let width: Float
  let depth: Float

  var estimatedCount: Int { estimated.filter { $0 }.count }

  func withoutHeight() -> AutoRoom {
    AutoRoom(corners: corners, estimated: estimated, wallsUsed: wallsUsed,
             height: nil, width: width, depth: depth)
  }

  func side(_ i: Int) -> Float { corners[i].dist2d(corners[(i + 1) % corners.count]) }

  var perimeter: Float { corners.indices.reduce(0) { $0 + side($1) } }

  var area: Float {
    var s: Float = 0
    for i in corners.indices {
      let a = corners[i]
      let b = corners[(i + 1) % corners.count]
      s += a.x * b.z - b.x * a.z
    }
    return abs(s) / 2
  }
}

/// A wall aligned to the room's axes, in room-local (u, v) coordinates.
/// `top` is how high above the floor it was seen: walls reach up to the
/// ceiling, furniture (desks, sofas, cabinets) usually stops well below.
final class AxisWall {
  let horizontal: Bool
  var off: Float
  var lo: Float
  var hi: Float
  var top: Float

  init(_ horizontal: Bool, _ off: Float, _ lo: Float, _ hi: Float, _ top: Float = 2.5) {
    self.horizontal = horizontal
    self.off = off
    self.lo = lo
    self.hi = hi
    self.top = top
  }

  var len: Float { hi - lo }
  var midU: Float { horizontal ? (lo + hi) / 2 : off }
  var midV: Float { horizontal ? off : (lo + hi) / 2 }
}

private func clampIndex(_ i: Int, _ n: Int) -> Int { min(max(i, 0), n - 1) }

enum RoomDetector {
  /// Fewest wall points worth analysing.
  static let minCloud = 150

  /// Wall pieces closer than this (across the wall) are the same surface.
  static let sameWallGap: Float = 0.06

  /// Surfaces seen no higher than this above the floor are furniture, not
  /// walls, when choosing the room's sides.
  static let lowTop: Float = 1.3

  /// Surfaces seen at least this high are walls (or as good as): floor seen
  /// beyond them is a doorway, not a sign of furniture.
  static let tallTop: Float = 1.6

  /// Most points a wall is asked for, however large the scan.
  static let maxWallPoints = 30

  /// Builds the room outline from the detected walls, without any taps.
  ///
  /// Rooms are assumed to have square corners: the dominant wall direction
  /// defines the room's axes, walls are snapped to them and pieces of the
  /// same wall are merged. The outermost wall on each side of the room gives
  /// a rectangle; with more walls an L-shaped or stepped outline is traced.
  /// Sides with no detected wall yet are estimated from the floor's extent.
  ///
  /// `cx`, `cz` is a point inside the room (the mean camera position).
  /// `cloud` holds tracked feature points; walls are also found as dense
  /// lines of points, since plain walls are often never detected as planes.
  static func computeAutoRoom(
    walls: [WallSegment], floorPts: [V3], floorY: Float,
    cx: Float, cz: Float, ceilingY: Float?, cloud: [V3] = []
  ) -> AutoRoom? {
    // Points on walls and furniture: off the floor, below the ceiling.
    // The upper part of the walls matters: it is what tells a wall from
    // furniture standing in front of it.
    var upper = floorY + 2.3
    if let c = ceilingY, c - 0.15 > floorY + 1.8 { upper = c - 0.15 }
    let wallPts = cloud.filter { $0.y > floorY + 0.1 && $0.y < upper }
    let useCloud = wallPts.count >= minCloud
    if walls.isEmpty && floorPts.count < 3 && !useCloud { return nil }

    // 1. Room axes.
    let planeLen = walls.reduce(0.0) { $0 + Double($1.tMax - $1.tMin) }
    let theta: Float
    if planeLen >= 2.0 || (!walls.isEmpty && !useCloud) {
      var sx = 0.0
      var sy = 0.0
      for w in walls {
        let a = 4.0 * atan2(Double(w.dz), Double(w.dx))
        let l = Double(w.tMax - w.tMin)
        sx += l * cos(a)
        sy += l * sin(a)
      }
      theta = Float(atan2(sy, sx) / 4.0)
    } else if useCloud {
      theta = cloudAngle(wallPts)
    } else {
      theta = floorAngle(floorPts)
    }
    let ct = cos(theta)
    let st = sin(theta)
    func lu(_ x: Float, _ z: Float) -> Float { x * ct + z * st }
    func lv(_ x: Float, _ z: Float) -> Float { -x * st + z * ct }
    func world(_ u: Float, _ v: Float) -> V3 { V3(u * ct - v * st, floorY, u * st + v * ct) }

    // 2. Snap walls to the axes; drop walls at odd angles.
    let tol: Float = 0.2618 // 15 degrees
    let pi = Float.pi
    var hs = [AxisWall]()
    var vs = [AxisWall]()
    for w in walls {
      var a = atan2(w.dz, w.dx) - theta
      while a < 0 { a += pi }
      while a >= pi { a -= pi }
      let horizontal: Bool
      if a < tol || a > pi - tol {
        horizontal = true
      } else if abs(a - pi / 2) < tol {
        horizontal = false
      } else {
        continue
      }
      let ax = w.cx + w.dx * w.tMin
      let az = w.cz + w.dz * w.tMin
      let bx = w.cx + w.dx * w.tMax
      let bz = w.cz + w.dz * w.tMax
      let ua = lu(ax, az), va = lv(ax, az)
      let ub = lu(bx, bz), vb = lv(bx, bz)
      let top = w.top - floorY
      if horizontal {
        hs.append(AxisWall(true, (va + vb) / 2, min(ua, ub), max(ua, ub), top))
      } else {
        vs.append(AxisWall(false, (ua + ub) / 2, min(va, vb), max(va, vb), top))
      }
    }
    let cu = lu(cx, cz)
    let cv = lv(cx, cz)
    // Walls found as lines of feature points.
    if useCloud {
      let us = wallPts.map { lu($0.x, $0.z) }
      let vArr = wallPts.map { lv($0.x, $0.z) }
      let ys = wallPts.map { $0.y - floorY }
      hs += pointWalls(us, vArr, ys, horizontal: true, c: cv)
      vs += pointWalls(us, vArr, ys, horizontal: false, c: cu)
    }
    let all = dropShadowed((mergeWalls(hs, cv) + mergeWalls(vs, cu)).filter { $0.len >= 0.5 }, cu, cv)

    var height: Float? = nil
    if let c = ceilingY, c - floorY >= 1.8, c - floorY <= 5 {
      height = c - floorY
    } else if let top = walls.map({ $0.top - floorY }).max(), top >= 2.2, top <= 4 {
      height = top
    } else {
      height = cloudHeight(cloud, floorY)
    }

    // 3. L-shaped / stepped rooms: trace the walls around the room (only
    //    surfaces tall enough to be walls).
    if let traced = traceOutline(all.filter { $0.top >= lowTop }, cu, cv) {
      let pts = traced.0
      return finishRoom(pts.map { world($0.x, $0.y) }, traced.1, all.count, height, pts)
    }

    // 4. Rectangle: the most wall-like candidate on each side, or the
    //    floor's edge.
    var fMinU = Float.greatestFiniteMagnitude
    var fMaxU = -Float.greatestFiniteMagnitude
    var fMinV = Float.greatestFiniteMagnitude
    var fMaxV = -Float.greatestFiniteMagnitude
    for p in floorPts {
      let u = lu(p.x, p.z)
      let v = lv(p.x, p.z)
      fMinU = min(fMinU, u)
      fMaxU = max(fMaxU, u)
      fMinV = min(fMinV, v)
      fMaxV = max(fMaxV, v)
    }
    let hasFloor = !floorPts.isEmpty
    // The floor ends at the walls, so a "wall" with floor well beyond it is
    // furniture standing in the room.
    let slack: Float = 0.3
    // On each side the tallest-looking surface is the wall. When only low
    // surfaces were seen there (a desk or sofa in front of a wall that was
    // never scanned) the side is still drawn there, but flagged as
    // estimated instead of shown as measured.
    var lowOnly = [false, false, false, false]
    func best(_ ws: [AxisWall], _ c: Float, _ side: Int) -> AxisWall? {
      let tall = ws.filter { $0.top >= lowTop }
      lowOnly[side] = tall.isEmpty && !ws.isEmpty
      return (tall.isEmpty ? ws : tall).max {
        ($0.len + 0.1 * abs($0.off - c)) < ($1.len + 0.1 * abs($1.off - c))
      }
    }
    // Floor beyond a low surface means furniture. Beyond a surface that
    // reaches wall height it means an open door: the floor continues into
    // the next room, and the wall is still the wall.
    func tall(_ w: AxisWall) -> Bool { w.top >= tallTop }
    let bottom = best(all.filter {
      $0.horizontal && $0.off < cv - 0.3 && (!hasFloor || tall($0) || $0.off <= fMinV + slack)
    }, cv, 0)
    let top = best(all.filter {
      $0.horizontal && $0.off > cv + 0.3 && (!hasFloor || tall($0) || $0.off >= fMaxV - slack)
    }, cv, 2)
    let left = best(all.filter {
      !$0.horizontal && $0.off < cu - 0.3 && (!hasFloor || tall($0) || $0.off <= fMinU + slack)
    }, cu, 3)
    let right = best(all.filter {
      !$0.horizontal && $0.off > cu + 0.3 && (!hasFloor || tall($0) || $0.off >= fMaxU - slack)
    }, cu, 1)
    if !hasFloor && (bottom == nil || top == nil || left == nil || right == nil) { return nil }

    let b = bottom?.off ?? fMinV
    let t = top?.off ?? fMaxV
    let l = left?.off ?? fMinU
    let r = right?.off ?? fMaxU
    if t - b < 0.8 || r - l < 0.8 { return nil }
    let local = [SIMD2<Float>(l, b), SIMD2(r, b), SIMD2(r, t), SIMD2(l, t)]
    let used = [bottom, top, left, right].compactMap { $0 }.count
    return finishRoom(
      local.map { world($0.x, $0.y) },
      [bottom == nil || lowOnly[0], right == nil || lowOnly[1],
       top == nil || lowOnly[2], left == nil || lowOnly[3]],
      used, height, local)
  }

  /// Walls as dense lines of points along one axis: a histogram of the
  /// points' offsets (5 cm bins) peaks where a wall is; the peak's points
  /// must spread at least 0.8 m along the wall.
  private static func pointWalls(_ us: [Float], _ vs: [Float], _ ys: [Float],
                                 horizontal: Bool, c: Float) -> [AxisWall] {
    let offAll = horizontal ? vs : us
    let alongAll = horizontal ? us : vs
    if offAll.isEmpty { return [] }
    // A share of all points keeps clutter from forming walls, but capped: a
    // plain wall has only so many features, and must not get harder to find
    // the longer the rest of the room is scanned.
    let minCount = max(12, min(maxWallPoints, Int(Float(offAll.count) * 0.015)))

    // Points on strong walls of the other direction would otherwise add up
    // to fake walls crossing them; leave them out.
    // (This threshold stays a share of all points: with many points spread
    // along one wall, a capped one would take random bumps in that spread
    // for crossing walls and delete points everywhere.)
    let other = histogramPeaks(alongAll, max(3 * minCount, Int(Float(offAll.count) * 0.045)))
    var off = [Float]()
    var along = [Float]()
    var height = [Float]()
    for k in offAll.indices where !other.contains(where: { abs(alongAll[k] - $0) < 0.1 }) {
      off.append(offAll[k])
      along.append(alongAll[k])
      height.append(ys[k])
    }

    /// The wall made of the points within `half` of `centre`, if they are
    /// enough and spread along the wall.
    func wallAt(_ centre: Float, _ half: Float) -> AxisWall? {
      var sum: Float = 0
      var alongPts = [Float]()
      var heights = [Float]()
      for k in off.indices where abs(off[k] - centre) < half {
        sum += off[k]
        alongPts.append(along[k])
        heights.append(height[k])
      }
      if alongPts.count < minCount { return nil }
      alongPts.sort()
      let lo = alongPts[Int(Float(alongPts.count) * 0.05)]
      let hi = alongPts[Int(Float(alongPts.count - 1) * 0.95)]
      if hi - lo < 0.8 { return nil }
      // A wall has points along most of its length, not just at its ends.
      let cells = Int((hi - lo) / 0.2) + 1
      var filled = [Bool](repeating: false, count: cells)
      for a in alongPts where a >= lo && a <= hi {
        filled[clampIndex(Int((a - lo) / 0.2), cells)] = true
      }
      if Float(filled.filter { $0 }.count) < Float(cells) * 0.5 { return nil }
      heights.sort()
      let top = heights[Int(Float(heights.count - 1) * 0.9)]
      return AxisWall(horizontal, sum / Float(alongPts.count), lo, hi, top)
    }

    var out = [AxisWall]()
    for centre in histogramPeaks(off, minCount) {
      // The 5 cm histogram blurs a wall and a surface 10-20 cm in front of
      // it (radiator, shelves, skirting) into one peak between the two,
      // which put the wall inside the room. Split the peak finely and take
      // the outermost surface: the wall.
      let nearby = off.filter { abs($0 - centre) < 0.25 }
      let fine = histogramPeaks(nearby, minCount, bin: 0.02, sep: 3)
        .sorted { abs($0 - c) > abs($1 - c) }
      if let w = fine.lazy.compactMap({ wallAt($0, 0.05) }).first ?? wallAt(centre, 0.08) {
        out.append(w)
      }
    }
    return out
  }

  /// Offsets where a `bin`-wide histogram of `values` peaks with at least
  /// `minCount` points; of peaks within `sep` bins the stronger is kept.
  private static func histogramPeaks(_ values: [Float], _ minCount: Int,
                                     bin: Float = 0.05, sep: Int = 5) -> [Float] {
    guard let mn = values.min(), let mx = values.max() else { return [] }
    let nb = Int((mx - mn) / bin) + 1
    if nb > 2000 { return [] }
    var counts = [Int](repeating: 0, count: nb)
    for o in values { counts[clampIndex(Int((o - mn) / bin), nb)] += 1 }
    let smooth = (0..<nb).map { i in
      counts[i] + (i > 0 ? counts[i - 1] : 0) + (i < nb - 1 ? counts[i + 1] : 0)
    }
    // Local maxima, keeping the stronger of peaks closer than `sep` bins.
    var peaks = [Int]()
    for i in 0..<nb {
      let s = smooth[i]
      if s < minCount { continue }
      if i > 0 && smooth[i - 1] > s { continue }
      if i < nb - 1 && smooth[i + 1] >= s { continue }
      if let near = peaks.firstIndex(where: { abs($0 - i) <= sep }) {
        if smooth[peaks[near]] < s { peaks[near] = i }
      } else {
        peaks.append(i)
      }
    }
    return peaks.map { mn + (Float($0) + 0.5) * bin }
  }

  /// Rotation (radians, 0..90 degrees) at which the points line up best with
  /// the axes: the one giving the sharpest histograms.
  private static func cloudAngle(_ pts: [V3]) -> Float {
    let step = max(1, pts.count / 3000)
    let n = (pts.count + step - 1) / step
    let xs = (0..<n).map { pts[$0 * step].x }
    let zs = (0..<n).map { pts[$0 * step].z }
    func score(_ a: Float) -> Int {
      let c = cos(a)
      let s = sin(a)
      let bin: Float = 0.05
      var total = 0
      for axis in 0...1 {
        let vals = (0..<n).map { axis == 0 ? xs[$0] * c + zs[$0] * s : -xs[$0] * s + zs[$0] * c }
        guard let mn = vals.min(), let mx = vals.max() else { continue }
        let nb = min(Int((mx - mn) / bin) + 1, 4000)
        var counts = [Int](repeating: 0, count: nb)
        for v in vals { counts[clampIndex(Int((v - mn) / bin), nb)] += 1 }
        for k in counts { total += k * k }
      }
      return total
    }
    var best: Float = 0
    var bestScore = -1
    for deg in 0..<90 {
      let a = Float(deg) * .pi / 180
      let sc = score(a)
      if sc > bestScore {
        bestScore = sc
        best = a
      }
    }
    // Refine to a quarter degree.
    let coarse = best
    for k in -4...4 {
      let a = coarse + Float(k) * 0.25 * .pi / 180
      let sc = score(a)
      if sc > bestScore {
        bestScore = sc
        best = a
      }
    }
    return best
  }

  /// Ceiling height from points high up on the walls and ceiling.
  private static func cloudHeight(_ cloud: [V3], _ floorY: Float) -> Float? {
    let high = cloud.map { $0.y - floorY }.filter { $0 >= 2.1 && $0 <= 4.0 }.sorted()
    if high.count < 40 { return nil }
    return high[min(Int(Float(high.count) * 0.9), high.count - 1)]
  }

  private static func finishRoom(
    _ corners: [V3], _ estimated: [Bool], _ wallsUsed: Int,
    _ height: Float?, _ local: [SIMD2<Float>]
  ) -> AutoRoom {
    let us = local.map { $0.x }
    let vs = local.map { $0.y }
    let w = us.max()! - us.min()!
    let d = vs.max()! - vs.min()!
    return AutoRoom(corners: corners, estimated: estimated, wallsUsed: wallsUsed,
                    height: height, width: max(w, d), depth: min(w, d))
  }

  /// Removes surfaces standing in front of a wall (wardrobes, fridges): a wall
  /// with a parallel wall behind it, on the same side of the room, that
  /// overlaps it along its length.
  private static func dropShadowed(_ ws: [AxisWall], _ cu: Float, _ cv: Float) -> [AxisWall] {
    ws.filter { w in
      let c = w.horizontal ? cv : cu
      return !ws.contains { o in
        o !== w && o.horizontal == w.horizontal &&
          (o.off - c) * (w.off - c) > 0 &&
          abs(o.off - c) > abs(w.off - c) &&
          min(o.hi, w.hi) - max(o.lo, w.lo) > 0.3
      }
    }
  }

  /// Joins wall pieces lying on the same line (within 20 cm). `c` is the
  /// room centre's offset across these walls.
  ///
  /// Pieces a few centimetres apart are the same wall seen twice and are
  /// averaged. Further apart, the inner one is something standing against
  /// the wall (skirting, radiator, shelves, curtains): the outer one is the
  /// wall. Averaging those pulled every wall into the room, so rooms came
  /// out too small.
  private static func mergeWalls(_ ws: [AxisWall], _ c: Float) -> [AxisWall] {
    var out = [AxisWall]()
    for w in ws.sorted(by: { $0.off < $1.off }) {
      if let m = out.first(where: {
        abs($0.off - w.off) < 0.2 && w.lo < $0.hi + 1.0 && w.hi > $0.lo - 1.0
      }) {
        let lm = m.len
        let lw = w.len
        if abs(m.off - w.off) <= sameWallGap {
          m.off = (m.off * lm + w.off * lw) / (lm + lw)
        } else if abs(w.off - c) > abs(m.off - c) {
          m.off = w.off
        }
        m.lo = min(m.lo, w.lo)
        m.hi = max(m.hi, w.hi)
        m.top = max(m.top, w.top)
      } else {
        out.append(AxisWall(w.horizontal, w.off, w.lo, w.hi, w.top))
      }
    }
    return out
  }

  /// Traces a room with more than four walls (L-shapes, alcoves) by going
  /// round the room centre. Returns local corners and, per side, whether it
  /// was inferred; nil when the walls don't form a clean outline.
  private static func traceOutline(
    _ walls: [AxisWall], _ cu: Float, _ cv: Float
  ) -> ([SIMD2<Float>], [Bool])? {
    if walls.count < 5 { return nil }
    // Keep walls seen directly from the centre (not hidden behind another).
    func crosses(_ w: AxisWall, _ o: AxisWall) -> Bool {
      let mu = w.midU
      let mv = w.midV
      if o.horizontal {
        if (cv - o.off) * (mv - o.off) >= 0 { return false }
        let t = (o.off - cv) / (mv - cv)
        let u = cu + (mu - cu) * t
        return u > o.lo && u < o.hi
      } else {
        if (cu - o.off) * (mu - o.off) >= 0 { return false }
        let t = (o.off - cu) / (mu - cu)
        let v = cv + (mv - cv) * t
        return v > o.lo && v < o.hi
      }
    }
    let visible = walls.filter { w in !walls.contains { o in o !== w && crosses(w, o) } }
    if visible.count < 5 { return nil }
    let ring = visible.sorted {
      atan2($0.midV - cv, $0.midU - cu) < atan2($1.midV - cv, $1.midU - cu)
    }

    var pts = [SIMD2<Float>]()
    var est = [Bool]()
    // Walls are often only partly detected, so corners may lie this far
    // beyond a wall's detected extent.
    let reach: Float = 2.0
    for i in ring.indices {
      let a = ring[i]
      let b = ring[(i + 1) % ring.count]
      if a.horizontal != b.horizontal {
        let h = a.horizontal ? a : b
        let v = a.horizontal ? b : a
        if v.off < h.lo - reach || v.off > h.hi + reach { return nil }
        if h.off < v.lo - reach || h.off > v.hi + reach { return nil }
        pts.append(SIMD2(v.off, h.off))
        est.append(false)
      } else {
        // Two parallel walls in a row: join them with a step.
        let sideA = a.horizontal ? a.off < cv : a.off > cu
        let sideB = b.horizontal ? b.off < cv : b.off > cu
        if sideA != sideB { return nil }
        // Shallow steps are more likely furniture than an alcove.
        if abs(a.off - b.off) < 0.5 { return nil }
        let forward = a.horizontal ? a.off < cv : a.off > cu
        let endA = forward ? a.hi : a.lo
        let startB = forward ? b.lo : b.hi
        if (startB - endA) * (forward ? 1 : -1) < -0.5 { return nil }
        let s = (endA + startB) / 2
        if a.horizontal {
          pts.append(SIMD2(s, a.off)); est.append(true)
          pts.append(SIMD2(s, b.off)); est.append(false)
        } else {
          pts.append(SIMD2(a.off, s)); est.append(true)
          pts.append(SIMD2(b.off, s)); est.append(false)
        }
      }
    }
    if pts.count < 4 || !isSimple(pts) { return nil }
    var area: Float = 0
    for i in pts.indices {
      let p = pts[i]
      let q = pts[(i + 1) % pts.count]
      area += p.x * q.y - q.x * p.y
    }
    if abs(area) / 2 < 1 { return nil }
    for i in pts.indices {
      let p = pts[i]
      let q = pts[(i + 1) % pts.count]
      if abs(p.x - q.x) + abs(p.y - q.y) < 0.15 { return nil }
    }
    return (pts, est)
  }

  private static func isSimple(_ pts: [SIMD2<Float>]) -> Bool {
    let n = pts.count
    func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    for i in 0..<n {
      for j in stride(from: i + 2, to: n, by: 1) {
        if i == 0 && j == n - 1 { continue }
        let a = pts[i], b = pts[(i + 1) % n]
        let c = pts[j], d = pts[(j + 1) % n]
        let d1 = cross(a, b, c)
        let d2 = cross(a, b, d)
        let d3 = cross(c, d, a)
        let d4 = cross(c, d, b)
        if d1 * d2 < 0 && d3 * d4 < 0 { return false }
      }
    }
    return true
  }

  /// Rotation (radians) giving the floor's smallest bounding box.
  private static func floorAngle(_ pts: [V3]) -> Float {
    var best: Float = 0
    var bestArea = Float.greatestFiniteMagnitude
    for deg in stride(from: 0, to: 90, by: 2) {
      let a = Float(deg) * .pi / 180
      let c = cos(a)
      let s = sin(a)
      var minU = Float.greatestFiniteMagnitude
      var maxU = -Float.greatestFiniteMagnitude
      var minV = Float.greatestFiniteMagnitude
      var maxV = -Float.greatestFiniteMagnitude
      for p in pts {
        let u = p.x * c + p.z * s
        let v = -p.x * s + p.z * c
        minU = min(minU, u); maxU = max(maxU, u)
        minV = min(minV, v); maxV = max(maxV, v)
      }
      let area = (maxU - minU) * (maxV - minV)
      if area < bestArea {
        bestArea = area
        best = a
      }
    }
    return best
  }
}
