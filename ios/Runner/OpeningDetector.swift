import Foundation
import simd

// Automatic door / window finding for the scanner's Door and Window modes
// (Auto method). Pure Swift + simd, no ARKit types, so it can be tested
// offline (tool/ios_room_detector_check) with synthetic camera images.
//
// The idea: the wall the user points at is known as a plane (see
// ArMeasureViewController.autoWallFrame). The camera image is resampled onto
// that plane at 1 cm per pixel ("rectified"), so a door or window frame
// becomes an axis-aligned rectangle whose edges are straight rows and
// columns, whatever the viewing angle. The frame's sides are then the
// strongest vertical edges left and right of the crosshair, its top (and a
// window's sill) the strongest horizontal edges above (below) it.

/// The wall plane an opening is searched on.
struct WallFrame {
  /// A point on the wall plane: where the crosshair's ray meets it.
  var origin: V3
  /// Horizontal unit normal, pointing towards the camera.
  var normal: V3
  var floorY: Float?
  /// The plane is assumed (no measured surface), so sizes are approximate.
  var estimated: Bool

  /// Horizontal unit vector along the wall; +u is to the right as seen from
  /// the camera (up × normal).
  var alongU: V3 {
    let u = V3(normal.z, 0, -normal.x)
    let l = simd_length(u)
    return l > 1e-6 ? u / l : V3(1, 0, 0)
  }

  /// World point of wall coordinates (u along the wall from origin, v =
  /// absolute world height).
  func point(_ u: Float, _ v: Float) -> V3 {
    origin + alongU * u + V3(0, v - origin.y, 0)
  }

  /// Height the rectified region is laid out from: the floor, or a typical
  /// floor 1.4 m below the crosshair when the floor is not known.
  var base: Float { floorY ?? (origin.y - 1.4) }
}

/// The camera as needed to find a world point in the captured image. Pixel
/// coordinates are those of the captured image in sensor orientation
/// (ARCamera.imageResolution, which ARCamera.intrinsics refers to).
struct CameraModel {
  /// Inverse of ARCamera.transform. Camera space: x right, y up, looking
  /// along -z (in sensor orientation).
  var worldToCamera: simd_float4x4
  var fx: Float
  var fy: Float
  var cx: Float
  var cy: Float
  var width: Int
  var height: Int

  /// Pixel position of a world point; nil when it is behind (or right at)
  /// the camera.
  func project(_ x: V3) -> (Float, Float)? {
    let p = worldToCamera * SIMD4<Float>(x.x, x.y, x.z, 1)
    if p.z >= -0.1 { return nil }
    let iz = 1 / -p.z
    // Image y runs down, camera y up.
    return (fx * p.x * iz + cx, fy * -p.y * iz + cy)
  }
}

enum OpeningKind {
  case door, window
}

/// The camera image resampled onto the wall plane: 1 cm per pixel, column 0
/// at u = u0 (left), row 0 at the top (v = vTop). NaN where the wall is not
/// in the image.
struct RectifiedImage {
  let width: Int
  let height: Int
  var pixels: [Float]
  let u0: Float
  let vTop: Float
  let frame: WallFrame

  static let cell: Float = 0.01

  /// Wall u of a (fractional) column's centre, and back.
  func u(_ col: Float) -> Float { u0 + (col + 0.5) * Self.cell }
  func col(_ u: Float) -> Float { (u - u0) / Self.cell - 0.5 }
  /// World height of a (fractional) row's centre, and back.
  func v(_ row: Float) -> Float { vTop - (row + 0.5) * Self.cell }
  func row(_ v: Float) -> Float { (vTop - v) / Self.cell - 0.5 }
}

struct OpeningCandidate {
  /// Wall coordinates in metres: u along the wall from the frame's origin,
  /// bottom / top as world heights.
  var left: Float
  var right: Float
  var bottom: Float
  var top: Float
  /// Bottom-left and bottom-right world points.
  var a: V3
  var b: V3
  var topY: Float
  var width: Float
  var height: Float
  /// Window sill above the floor, when the floor is known.
  var sill: Float?
  /// The weakest edge used, as a multiple of its search range's median.
  var strength: Float
  /// The wall plane or the bottom (a door without a known floor) was assumed.
  var estimated: Bool
}

/// Everything a detection looked at, for the diagnostics files.
struct OpeningAnalysis {
  var candidate: OpeningCandidate?
  /// Mean vertical-edge strength per column.
  var columnProfile: [Float]
  /// Mean horizontal-edge strength per row between the sides found (empty
  /// when no sides were found).
  var rowProfile: [Float]
  /// Why nothing was found ("" when a candidate was).
  var failure: String
}

enum OpeningDetector {
  /// The rectified region: ±1.6 m along the wall, from 10 cm below the base
  /// height to 2.80 m above it.
  static let halfWidth: Float = 1.6
  static let below: Float = 0.10
  static let above: Float = 2.80
  /// A peak counts when it is this many times the median of its search
  /// range (edges stand out from the wall's own texture) ...
  static let minProminence: Float = 2.5
  /// ... and at least this strong in grey levels per pixel, so the noise
  /// of a perfectly plain wall (median near zero) is never an edge.
  static let minEdge: Float = 1.0
  /// Casings and frames give two or three parallel edges a few cm apart:
  /// among strong edges this close (in pixels = cm) the one nearest the
  /// crosshair (the opening's inside edge) is used.
  static let casingReach: Float = 15
  /// A casing edge must be at least this share of the strongest one, so a
  /// faint mark next to the frame is not taken for its inner edge.
  static let casingShare: Float = 0.3

  // ------------------------------------------------------------ rectify

  /// Resamples the camera image onto the wall plane. `luminance` samples
  /// the image (bilinear) at a pixel position, nil outside. Each cell is the
  /// mean of 2 x 2 samples, so an edge between cells keeps its sub-cm
  /// position as a partial value.
  static func rectify(frame: WallFrame, camera: CameraModel,
                      luminance: (Float, Float) -> Float?) -> RectifiedImage {
    let cell = RectifiedImage.cell
    let w = Int((2 * halfWidth / cell).rounded())
    let h = Int(((below + above) / cell).rounded())
    let u0 = -halfWidth
    let vTop = frame.base + above
    var px = [Float](repeating: .nan, count: w * h)
    let m = camera.worldToCamera
    let uDir = frame.alongU
    // Camera-space position is linear in u and v: p = p0 + du * u + dv * v.
    let o = frame.origin
    let p0 = m * SIMD4<Float>(o.x, 0, o.z, 1)
    let du = m * SIMD4<Float>(uDir.x, 0, uDir.z, 0)
    let dv = m * SIMD4<Float>(0, 1, 0, 0)
    // Plain scalars in the loop: the app is often run as a debug build,
    // where SIMD arithmetic is not inlined and would take seconds here.
    let (p0x, p0y, p0z) = (p0.x, p0.y, p0.z)
    let (dux, duy, duz) = (du.x, du.y, du.z)
    let (dvx, dvy, dvz) = (dv.x, dv.y, dv.z)
    let (fx, fy, cx, cy) = (camera.fx, camera.fy, camera.cx, camera.cy)
    px.withUnsafeMutableBufferPointer { out in
      for r in 0..<h {
        for c in 0..<w {
          var sum: Float = 0
          var n = 0
          for sy in 0..<2 {
            let v = vTop - (Float(r) + (sy == 0 ? 0.25 : 0.75)) * cell
            for sx in 0..<2 {
              let u = u0 + (Float(c) + (sx == 0 ? 0.25 : 0.75)) * cell
              let pz = p0z + duz * u + dvz * v
              if pz >= -0.1 { continue }
              let iz = 1 / -pz
              let x = fx * (p0x + dux * u + dvx * v) * iz + cx
              let y = fy * -(p0y + duy * u + dvy * v) * iz + cy
              if let l = luminance(x, y) {
                sum += l
                n += 1
              }
            }
          }
          // A cell only partly in the image would show a false edge.
          if n == 4 { out[r * w + c] = sum / 4 }
        }
      }
    }
    return RectifiedImage(width: w, height: h, pixels: px, u0: u0, vTop: vTop, frame: frame)
  }

  // ------------------------------------------------------------ detect

  static func detect(kind: OpeningKind, frame: WallFrame, image: RectifiedImage) -> OpeningCandidate? {
    analyze(kind: kind, frame: frame, image: image).candidate
  }

  private struct Peak {
    var index: Int
    /// Sub-pixel position (parabola through the peak and its neighbours).
    var pos: Float
    var value: Float
    /// value / median of the search range.
    var prominence: Float
  }

  static func analyze(kind: OpeningKind, frame: WallFrame, image img: RectifiedImage) -> OpeningAnalysis {
    let w = img.width, h = img.height
    let door = kind == .door
    let px = img.pixels

    // Sobel gradients (scaled to grey levels per pixel). A cell next to a
    // missing one has none: the image border is not an edge.
    var gx = [Float](repeating: .nan, count: w * h)
    var gy = [Float](repeating: .nan, count: w * h)
    if w >= 3 && h >= 3 {
      for r in 1..<(h - 1) {
        let up = (r - 1) * w, mid = r * w, dn = (r + 1) * w
        for c in 1..<(w - 1) {
          let a = px[up + c - 1], b = px[up + c], cc = px[up + c + 1]
          let d = px[mid + c - 1], e = px[mid + c], f = px[mid + c + 1]
          let g = px[dn + c - 1], hh = px[dn + c], i = px[dn + c + 1]
          let sx = (cc + 2 * f + i) - (a + 2 * d + g)
          let sy = (g + 2 * hh + i) - (a + 2 * b + cc)
          if sx.isNaN || sy.isNaN || e.isNaN { continue }
          gx[mid + c] = sx / 8
          gy[mid + c] = sy / 8
        }
      }
    }

    func rowIndex(_ v: Float) -> Int { Int(img.row(v).rounded()) }
    func colIndex(_ u: Float) -> Int { Int(img.col(u).rounded()) }
    let oy = frame.origin.y

    // ---- sides: vertical edges over the body of the opening
    let bodyLo: Float = door ? frame.base + 0.3 : oy - 0.3
    let bodyHi: Float = door ? frame.base + 1.8 : oy + 0.5
    let r0 = max(1, rowIndex(bodyHi)), r1 = min(h - 2, rowIndex(bodyLo))
    var colProf = [Float](repeating: .nan, count: w)
    if r1 > r0 {
      let need = max(5, (r1 - r0 + 1) / 2)
      for c in 0..<w {
        var s: Float = 0
        var n = 0
        for r in r0...r1 {
          let x = gx[r * w + c]
          if x.isNaN { continue }
          n += 1
          // Only edges that run up and down: a slanted line (perspective of
          // something off the wall, a shadow) is not a frame's side.
          let ax = abs(x)
          if ax > 2 * abs(gy[r * w + c]) { s += ax }
        }
        if n >= need { colProf[c] = s / Float(n) }
      }
    }
    var out = OpeningAnalysis(candidate: nil, columnProfile: colProf, rowProfile: [], failure: "")

    let crossCol = img.col(0)
    let left = peaks(colProf, colIndex(-halfWidth), colIndex(-0.12))
    let right = peaks(colProf, colIndex(0.12), colIndex(halfWidth))
    // Each strong edge proposes the inside edge of its casing as a side.
    func sides(_ ps: [Peak]) -> [(pos: Float, score: Float, prominence: Float)] {
      var best = [Int: (pos: Float, score: Float, prominence: Float)]()
      for anchor in ps {
        let inner = innermost(ps, around: anchor, towards: crossCol)
        if (best[inner.index]?.score ?? -1) < anchor.value {
          best[inner.index] = (inner.pos, anchor.value, inner.prominence)
        }
      }
      return Array(best.values)
    }
    let minW: Float = door ? 0.55 : 0.3
    let maxW: Float = door ? 2.0 : 3.0
    var pair: (l: Float, r: Float, score: Float, prom: Float)?
    for l in sides(left) {
      for r in sides(right) {
        let width = img.u(r.pos) - img.u(l.pos)
        if width < minW || width > maxW { continue }
        let score = l.score + r.score
        if score > (pair?.score ?? -1) { pair = (l.pos, r.pos, score, min(l.prominence, r.prominence)) }
      }
    }
    guard let pair else {
      out.failure = left.isEmpty || right.isEmpty
        ? "no \(left.isEmpty ? "left" : "right") side" : "no side pair of a plausible width"
      return out
    }
    let uL = img.u(pair.l), uR = img.u(pair.r)

    // ---- top and bottom: horizontal edges between the sides
    let c0 = max(1, Int((pair.l + 3).rounded(.up))), c1 = min(w - 2, Int((pair.r - 3).rounded(.down)))
    var rowProf = [Float](repeating: .nan, count: h)
    if c1 > c0 {
      let need = max(5, (c1 - c0 + 1) / 2)
      for r in 0..<h {
        var s: Float = 0
        var n = 0
        for c in c0...c1 {
          let y = gy[r * w + c]
          if y.isNaN { continue }
          n += 1
          let ay = abs(y)
          if ay > 2 * abs(gx[r * w + c]) { s += ay }
        }
        if n >= need { rowProf[r] = s / Float(n) }
      }
    }
    out.rowProfile = rowProf
    let crossRow = img.row(oy)

    // Rows of a height range [lo, hi] (row numbers run downwards).
    func rows(_ lo: Float, _ hi: Float) -> (Int, Int) { (rowIndex(hi), rowIndex(lo)) }

    let (t0, t1) = door
      ? (frame.floorY.map { rows($0 + 1.8, $0 + 2.6) } ?? rows(oy + 0.6, oy + 1.5))
      : rows(oy + 0.15, oy + 1.8)
    let tops = peaks(rowProf, t0, t1)
    guard let strongestTop = tops.max(by: { $0.value < $1.value }) else {
      out.failure = "no top edge"
      return out
    }
    let topPeak = innermost(tops, around: strongestTop, towards: crossRow)
    let top = img.v(topPeak.pos)
    var prom = min(pair.prom, topPeak.prominence)

    var bottom: Float
    var bottomEstimated = false
    if door {
      if let f = frame.floorY {
        bottom = f
      } else {
        // The floor line: the strongest horizontal edge low in the region.
        let (b0, b1) = rows(frame.base - below, frame.base + 0.30)
        if let floorLine = peaks(rowProf, b0, b1).max(by: { $0.value < $1.value }) {
          bottom = img.v(floorLine.pos)
          prom = min(prom, floorLine.prominence)
        } else {
          bottom = frame.base
          bottomEstimated = true
        }
      }
    } else {
      let lowest = max(oy - 1.6, (frame.floorY ?? -Float.greatestFiniteMagnitude) + 0.05)
      let (b0, b1) = rows(lowest, oy - 0.1)
      let sills = b1 > b0 ? peaks(rowProf, b0, b1) : []
      guard let strongest = sills.max(by: { $0.value < $1.value }) else {
        out.failure = "no sill edge"
        return out
      }
      let sillPeak = innermost(sills, around: strongest, towards: crossRow)
      bottom = img.v(sillPeak.pos)
      prom = min(prom, sillPeak.prominence)
    }

    let height = top - bottom
    let sill = door ? nil : frame.floorY.map { bottom - $0 }
    if door ? (height < 1.7 || height > 2.7) : (height < 0.25 || height > 2.6) {
      out.failure = String(format: "implausible height %.2f m", height)
      return out
    }
    if let sill, sill < 0 || sill > 1.8 {
      out.failure = String(format: "implausible sill %.2f m", sill)
      return out
    }
    out.candidate = OpeningCandidate(
      left: uL, right: uR, bottom: bottom, top: top,
      a: frame.point(uL, bottom), b: frame.point(uR, bottom), topY: top,
      width: uR - uL, height: height, sill: sill, strength: prom,
      estimated: frame.estimated || bottomEstimated)
    return out
  }

  /// Strong local maxima of a profile within [lo, hi] (indices, clamped).
  private static func peaks(_ p: [Float], _ lo: Int, _ hi: Int) -> [Peak] {
    let lo = max(lo, 0), hi = min(hi, p.count - 1)
    if hi - lo < 4 { return [] }
    let vals = p[lo...hi].filter { !$0.isNaN }.sorted()
    if vals.count < 5 { return [] }
    let median = vals[vals.count / 2]
    let threshold = max(minProminence * median, minEdge)
    var out = [Peak]()
    for i in lo...hi {
      let v = p[i]
      if v.isNaN || v < threshold { continue }
      // A maximum within ±2 px (ties go to the first), so one blurred edge
      // is one peak while casing edges 4 cm apart stay separate.
      var isMax = true
      for j in max(0, i - 2)...min(p.count - 1, i + 2) where j != i {
        let q = p[j]
        if !q.isNaN && (q > v || (q == v && j < i)) {
          isMax = false
          break
        }
      }
      if !isMax { continue }
      var off: Float = 0
      if i > 0 && i < p.count - 1 {
        let a = p[i - 1], c = p[i + 1]
        let den = a - 2 * v + c
        if !a.isNaN && !c.isNaN && den < 0 { off = min(max(0.5 * (a - c) / den, -1), 1) }
      }
      out.append(Peak(index: i, pos: Float(i) + off, value: v,
                      prominence: v / max(median, 0.05)))
    }
    return out
  }

  /// Of the strong edges within casingReach of `anchor`, the one nearest to
  /// `towards` (the crosshair): the inside edge of a casing or frame.
  private static func innermost(_ ps: [Peak], around anchor: Peak, towards: Float) -> Peak {
    var best = anchor
    for p in ps where abs(p.pos - anchor.pos) <= casingReach && p.value >= casingShare * anchor.value {
      if abs(p.pos - towards) < abs(best.pos - towards) { best = p }
    }
    return best
  }
}
