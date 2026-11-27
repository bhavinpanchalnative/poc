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
  /// The rectified region: ±1.6 m along the wall, from 35 cm below the base
  /// height to 2.80 m above it (below the floor too: when the wall is
  /// assumed too far away, the line where it meets the floor shows up below
  /// the floor's height).
  static let halfWidth: Float = 1.6
  static let below: Float = 0.35
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
  static let casingShare: Float = 0.45
  /// A farther edge replacing a window bar (mullion, transom) is at least
  /// this share of the bar's strength.
  static let barStepShare: Float = 0.5

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

  /// Horizontal aims tried by `search`, nearest the crosshair first (m).
  private static let searchU: [Float] = [0, -0.5, 0.5, -1.0, 1.0]
  /// Window aim heights tried by `search` above a known floor (m).
  private static let searchWindowV: [Float] = [1.3, 1.0, 1.6]

  /// Room scan: the door / window nearest the crosshair, not only one
  /// around it. While a room is scanned the camera sweeps along the walls,
  /// often aimed at the corners or where the walls meet the floor, so a door
  /// or window is seldom right under the crosshair, and a window hardly
  /// ever at its height. `analyze` is tried with the aim moved along the
  /// wall (`searchU`) and, for windows over a known floor, to the heights
  /// windows are at (`searchWindowV`); the first detection (nearest the
  /// crosshair) wins. Same as `OpeningDetector.search` on Android.
  static func search(kind: OpeningKind, frame: WallFrame, image img: RectifiedImage) -> OpeningAnalysis {
    let grad = gradients(img)
    var heights: [Float] = [frame.origin.y]
    if kind == .window, let fy = frame.floorY {
      for dv in searchWindowV {
        let y = fy + dv
        if !heights.contains(where: { abs($0 - y) < 0.2 }) { heights.append(y) }
      }
    }
    var first: OpeningAnalysis?
    for y in heights {
      var f = frame
      f.origin.y = y
      for du in searchU {
        let a = analyze(kind: kind, frame: f, image: img, uRef: du, gradients: grad)
        if first == nil { first = a }
        if a.candidate != nil { return a }
      }
    }
    return first!
  }

  /// Sobel gradients of a rectified image (grey levels per cell); NaN next
  /// to a cell the camera did not see.
  struct Gradients {
    var gx: [Float]
    var gy: [Float]
  }

  static func gradients(_ img: RectifiedImage) -> Gradients {
    let w = img.width, h = img.height
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
    return Gradients(gx: gx, gy: gy)
  }

  /// Looks for the door / window around the aim: the crosshair's foot
  /// (`frame.origin`) moved `uRef` m along the wall; its sides are looked
  /// for left and right of that point. `grad`: the image's gradients when
  /// already computed (`gradients`).
  static func analyze(kind: OpeningKind, frame: WallFrame, image img: RectifiedImage,
                      uRef: Float = 0, gradients grad: Gradients? = nil) -> OpeningAnalysis {
    let w = img.width, h = img.height
    let door = kind == .door
    let px = img.pixels
    let grads = grad ?? gradients(img)
    let gx = grads.gx, gy = grads.gy

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
      var vals = [Float]()
      vals.reserveCapacity(r1 - r0 + 1)
      for c in 0..<w {
        vals.removeAll(keepingCapacity: true)
        for r in r0...r1 {
          let x = gx[r * w + c]
          if x.isNaN { continue }
          // Only edges that run up and down: a slanted line (perspective of
          // something off the wall, a shadow) is not a frame's side.
          let ax = abs(x)
          vals.append(ax > 2 * abs(gy[r * w + c]) ? ax : 0)
        }
        if vals.count >= need { colProf[c] = cappedMean(&vals) }
      }
    }
    var out = OpeningAnalysis(candidate: nil, columnProfile: colProf, rowProfile: [], failure: "")

    let crossCol = img.col(uRef)
    let left = peaks(colProf, colIndex(uRef - halfWidth), colIndex(uRef - 0.12))
    let right = peaks(colProf, colIndex(uRef + 0.12), colIndex(uRef + halfWidth))
    // Each strong edge proposes the inside edge of its casing as a side
    // (positions in cells, 1 cm); `outer` is the casing's farthest edge.
    func groups(_ ps: [Peak], towards: Float) -> [Side] {
      var best = [Int: Side]()
      for anchor in ps {
        let inner = innermost(ps, around: anchor, towards: towards)
        let outer = outermost(ps, around: anchor, from: towards)
        if (best[inner.index]?.score ?? -1) < anchor.value {
          best[inner.index] = Side(pos: inner.pos, outer: outer.pos, score: anchor.value, prominence: inner.prominence)
        }
      }
      return Array(best.values)
    }

    // Mean brightness of the cells in columns [ca, cb] and rows [ra, rb]
    // (cell positions, either order); NaN when none.
    func band(_ ca: Float, _ cb: Float, _ ra: Float, _ rb: Float) -> Float {
      let c0 = max(0, Int(min(ca, cb).rounded(.up))), c1 = min(w - 1, Int(max(ca, cb).rounded(.down)))
      let q0 = max(0, Int(min(ra, rb).rounded(.up))), q1 = min(h - 1, Int(max(ra, rb).rounded(.down)))
      if c1 < c0 || q1 < q0 { return .nan }
      var s: Float = 0
      var n = 0
      for r in q0...q1 {
        for c in c0...c1 {
          let x = px[r * w + c]
          if !x.isNaN { s += x; n += 1 }
        }
      }
      return n > 0 ? s / Float(n) : .nan
    }
    // Whether the edge group from `inner` to `outer` (cells along one axis)
    // is a bar inside a window, a mullion or transom with glass on both
    // sides, rather than the frame with the wall beyond it. `at` is the
    // mean brightness of an interval of that axis.
    func isBar(_ inner: Float, _ outer: Float, _ at: (Float, Float) -> Float) -> Bool {
      let span = outer - inner
      if abs(span) < 2 { return false }
      let d: Float = span > 0 ? 1 : -1
      let inside = at(inner - d * 10, inner - d * 3)
      let bar = at(inner + d, outer - d)
      let beyond = at(outer + d * 3, outer + d * 10)
      if inside.isNaN || bar.isNaN || beyond.isNaN { return false }
      let contrast = abs(bar - inside)
      return contrast >= 8 && abs(beyond - inside) < 0.35 * contrast
    }
    // Windows: the nearest strong edge beyond a bar, else `e`.
    func pastBars(_ e: Side, _ cands: [Side], _ at: (Float, Float) -> Float, _ ok: (Side) -> Bool) -> Side {
      var cur = e
      for _ in 0..<3 {
        if !isBar(cur.pos, cur.outer, at) { return cur }
        let d: Float = cur.outer > cur.pos ? 1 : -1
        let farther = cands.filter { ($0.pos - cur.outer) * d > 2 && $0.score >= barStepShare * cur.score && ok($0) }
        guard let next = farther.min(by: { abs($0.pos - cur.outer) < abs($1.pos - cur.outer) }) else { return cur }
        cur = next
      }
      return cur
    }

    let minW: Float = door ? 0.55 : 0.3
    let maxW: Float = door ? 2.0 : 3.0
    let lefts = groups(left, towards: crossCol), rights = groups(right, towards: crossCol)
    var pair: (l: Side, r: Side, score: Float)?
    for l in lefts {
      for r in rights {
        let width = img.u(r.pos) - img.u(l.pos)
        if width < minW || width > maxW { continue }
        let score = l.score + r.score
        if score > (pair?.score ?? -1) { pair = (l, r, score) }
      }
    }
    guard var pair else {
      out.failure = left.isEmpty || right.isEmpty
        ? "no \(left.isEmpty ? "left" : "right") side" : "no side pair of a plausible width"
      return out
    }
    if !door {
      let colBand = { (a: Float, b: Float) in band(a, b, Float(r0), Float(r1)) }
      let r = pair.r
      pair.l = pastBars(pair.l, lefts, colBand) { img.u(r.pos) - img.u($0.pos) <= maxW }
      let l = pair.l
      pair.r = pastBars(pair.r, rights, colBand) { img.u($0.pos) - img.u(l.pos) <= maxW }
    }
    let uL = img.u(pair.l.pos), uR = img.u(pair.r.pos)

    // ---- top and bottom: horizontal edges between the sides
    let c0 = max(1, Int((pair.l.pos + 3).rounded(.up))), c1 = min(w - 2, Int((pair.r.pos - 3).rounded(.down)))
    var rowProf = [Float](repeating: .nan, count: h)
    if c1 > c0 {
      let need = max(5, (c1 - c0 + 1) / 2)
      var vals = [Float]()
      vals.reserveCapacity(c1 - c0 + 1)
      for r in 0..<h {
        vals.removeAll(keepingCapacity: true)
        for c in c0...c1 {
          let y = gy[r * w + c]
          if y.isNaN { continue }
          let ay = abs(y)
          vals.append(ay > 2 * abs(gx[r * w + c]) ? ay : 0)
        }
        if vals.count >= need { rowProf[r] = cappedMean(&vals) }
      }
    }
    out.rowProfile = rowProf
    let crossRow = img.row(oy)

    // Rows of a height range [lo, hi] (row numbers run downwards).
    func rows(_ lo: Float, _ hi: Float) -> (Int, Int) { (rowIndex(hi), rowIndex(lo)) }

    let (t0, t1) = door
      ? (frame.floorY.map { rows($0 + 1.8, $0 + 2.6) } ?? rows(oy + 0.6, oy + 1.5))
      : rows(oy + 0.15, oy + 1.8)
    let rowBand = { (a: Float, b: Float) in band(Float(c0), Float(c1), a, b) }
    let tops = groups(peaks(rowProf, t0, t1), towards: crossRow)
    guard let strongestTop = tops.max(by: { $0.score < $1.score }) else {
      out.failure = "no top edge"
      return out
    }
    let topEdge = door ? strongestTop : pastBars(strongestTop, tops, rowBand) { _ in true }
    let top = img.v(topEdge.pos)
    var prom = min(pair.l.prominence, pair.r.prominence, topEdge.prominence)

    var bottom: Float
    var bottomEstimated = false
    if door {
      if let f = frame.floorY {
        bottom = f
      } else {
        // The floor line: the strongest horizontal edge low in the region.
        let (b0, b1) = rows(frame.base - 0.10, frame.base + 0.30)
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
      let sills = groups(b1 > b0 ? peaks(rowProf, b0, b1) : [], towards: crossRow)
      guard let strongest = sills.max(by: { $0.score < $1.score }) else {
        out.failure = "no sill edge"
        return out
      }
      let sillEdge = pastBars(strongest, sills, rowBand) { _ in true }
      bottom = img.v(sillEdge.pos)
      prom = min(prom, sillEdge.prominence)
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

  // ------------------------------------------------------- floor line

  /// A wall placed by `wallFromFloorLine`: `moved` is how far the
  /// crosshair's point moved (m, negative: towards the camera), `turned` how
  /// much the wall turned (degrees), `strips` how many 10 cm strips showed
  /// the floor line.
  struct FloorLineWall {
    var frame: WallFrame
    var moved: Float
    var turned: Float
    var strips: Int
  }

  /// The result of `measure`: the wall used (corrected by the floor line
  /// when `floorLine` is set), the image rectified on it and the analysis.
  struct Measured {
    var frame: WallFrame
    var image: RectifiedImage
    var analysis: OpeningAnalysis
    var floorLine: FloorLineWall?
  }

  /// One automatic attempt: rectifies the camera image on `frame` and looks
  /// for the door / window; then places the wall by the line where it meets
  /// the floor (`wallFromFloorLine`) and, if that moved it, looks again on
  /// the corrected wall. A wall that was only guessed (`estimated`) may move
  /// up to 1.5 m and turn up to 30 degrees, and is then measured; a detected
  /// wall surface only up to 8 cm and 8 degrees, so that a misread line can
  /// never make it worse by more than its own error.
  /// `wide` (room scan): looked for with `search`, not only around the crosshair.
  static func measure(kind: OpeningKind, frame: WallFrame, camera: CameraModel, wide: Bool = false,
                      luminance: (Float, Float) -> Float?) -> Measured {
    func find(_ f: WallFrame, _ i: RectifiedImage) -> OpeningAnalysis {
      wide ? search(kind: kind, frame: f, image: i) : analyze(kind: kind, frame: f, image: i)
    }
    let image = rectify(frame: frame, camera: camera, luminance: luminance)
    let analysis = find(frame, image)
    let c = analysis.candidate
    guard let fl = wallFromFloorLine(frame: frame, camera: camera, image: image,
                                     skipLo: c?.left ?? .nan, skipHi: c?.right ?? .nan)
    else { return Measured(frame: frame, image: image, analysis: analysis, floorLine: nil) }
    let ok = frame.estimated ? abs(fl.moved) <= 1.5 && fl.turned <= 30 : abs(fl.moved) <= 0.08 && fl.turned <= 8
    if !ok || (abs(fl.moved) < 0.003 && fl.turned < 0.3 && !frame.estimated) {
      return Measured(frame: frame, image: image, analysis: analysis, floorLine: nil)
    }
    let image2 = rectify(frame: fl.frame, camera: camera, luminance: luminance)
    return Measured(frame: fl.frame, image: image2, analysis: find(fl.frame, image2), floorLine: fl)
  }

  /// The wall where it really is, from the line along which it meets the
  /// floor (its base or skirting); nil when that line is not seen clearly.
  ///
  /// Door and window sizes are measured on the wall plane, so a wall assumed
  /// d cm too near or too far makes them d / distance too small or too
  /// large, and a guessed wall can be off by tens of cm. The floor, though,
  /// is known accurately. Each 10 cm strip of the image is searched for
  /// horizontal edges near the floor's height; the camera ray through each
  /// meets the floor where that edge really is. Those floor points line up
  /// along the wall's base: a line through them gives the wall's true
  /// position and direction. Strips over the opening (skipLo...skipHi, wall
  /// u) are left out: an open door shows the next room's floor.
  ///
  /// Of the lines found the best supported is used, unless one about as well
  /// supported lies 4-30 cm nearer the camera: a skirting's top edge seen as
  /// a floor line lands behind the wall, and the line in front of it is the
  /// wall's base.
  static func wallFromFloorLine(frame: WallFrame, camera: CameraModel, image img: RectifiedImage,
                                skipLo: Float = .nan, skipHi: Float = .nan) -> FloorLineWall? {
    guard let fy = frame.floorY else { return nil }
    let c4 = camera.worldToCamera.inverse.columns.3
    let cam = V3(c4.x, c4.y, c4.z)
    if cam.y - fy < 0.4 { return nil }
    let w = img.width, h = img.height
    let px = img.pixels
    let r0 = max(1, min(h - 2, Int(img.row(fy + 0.45).rounded(.up))))
    let r1 = max(1, min(h - 2, Int(img.row(fy - 0.30).rounded(.down))))
    if r1 - r0 < 6 { return nil }

    struct Sample { var x: Float; var z: Float; var weight: Float; var strip: Int; var u: Float }
    var samples = [Sample]()
    let strip = 10
    var profile = [Float](repeating: .nan, count: h)
    var s = 0
    var c0 = 1
    while c0 + strip < w - 1 {
      let uMid = img.u(Float(c0) + Float(strip) / 2)
      let skip = !skipLo.isNaN && uMid > skipLo - 0.10 && uMid < skipHi + 0.10
      if !skip {
        for i in profile.indices { profile[i] = .nan }
        for r in r0...r1 {
          var sum: Float = 0
          var n = 0
          for c in c0..<(c0 + strip) {
            let i = r * w + c
            let a = px[i - w - 1], b = px[i - w], cc = px[i - w + 1]
            let d = px[i - 1], f = px[i + 1]
            let g = px[i + w - 1], hh = px[i + w], k = px[i + w + 1]
            let gx = ((cc + 2 * f + k) - (a + 2 * d + g)) / 8
            let gy = ((g + 2 * hh + k) - (a + 2 * b + cc)) / 8
            if gx.isNaN || gy.isNaN { continue }
            n += 1
            if abs(gy) > 2 * abs(gx) { sum += abs(gy) }
          }
          profile[r] = n >= strip / 2 ? sum / Float(n) : 0
        }
        let found = peaks(profile, r0, r1).sorted { $0.value > $1.value }.prefix(3)
        for pk in found {
          let q = frame.point(uMid, img.v(pk.pos))
          let dir = q - cam
          if dir.y > -1e-3 { continue }
          let t = (fy - cam.y) / dir.y
          let x = cam.x + dir.x * t, z = cam.z + dir.z * t
          let dist = ((x - cam.x) * (x - cam.x) + (z - cam.z) * (z - cam.z)).squareRoot()
          if dist < 0.3 || dist > 10 { continue }
          samples.append(Sample(x: x, z: z, weight: pk.value, strip: s, u: uMid))
        }
      }
      c0 += strip
      s += 1
    }
    if samples.count < 4 { return nil }

    struct Line { var px: Float; var pz: Float; var nx: Float; var nz: Float; var support: Float; var inliers: [Sample] }
    // Every pair of samples from strips at least 30 cm apart proposes a
    // line; its support is the summed strength of the strips with a sample
    // within 3 cm of it (each strip's strongest one).
    var lines = [Line]()
    let maxTilt: Float = 0.42 // sin(25 degrees): roughly along the assumed wall
    let wn = frame.normal
    for i in samples.indices {
      for j in (i + 1)..<samples.count {
        let a = samples[i], b = samples[j]
        if abs(a.u - b.u) < 0.3 { continue }
        let l = ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).squareRoot()
        if l < 0.2 { continue }
        let dx = (b.x - a.x) / l, dz = (b.z - a.z) / l
        if abs(dx * wn.x + dz * wn.z) > maxTilt { continue }
        let nx = -dz, nz = dx
        var best = [Int: Sample]()
        for q in samples where abs((q.x - a.x) * nx + (q.z - a.z) * nz) <= 0.03 {
          if (best[q.strip]?.weight ?? -1) < q.weight { best[q.strip] = q }
        }
        if best.count < 4 { continue }
        let inl = Array(best.values)
        let us = inl.map { $0.u }
        if (us.max() ?? 0) - (us.min() ?? 0) < 0.5 { continue }
        lines.append(Line(px: a.x, pz: a.z, nx: nx, nz: nz, support: inl.reduce(0) { $0 + $1.weight }, inliers: inl))
      }
    }
    guard let top = lines.max(by: { $0.support < $1.support }) else { return nil }
    // Distance of a line from the camera.
    func depth(_ l: Line) -> Float { abs((l.px - cam.x) * l.nx + (l.pz - cam.z) * l.nz) }
    let nearer = lines.filter {
      $0.support >= 0.6 * top.support && abs($0.nx * top.nx + $0.nz * top.nz) > 0.996 &&
        (0.04...0.30).contains(depth(top) - depth($0))
    }
    let chosen = nearer.max(by: { $0.support < $1.support }) ?? top

    // Least-squares line through the chosen inliers.
    let inl = chosen.inliers
    let mx = inl.reduce(0) { $0 + $1.x } / Float(inl.count)
    let mz = inl.reduce(0) { $0 + $1.z } / Float(inl.count)
    var sxx: Float = 0, sxz: Float = 0, szz: Float = 0
    for q in inl {
      let dx = q.x - mx, dz = q.z - mz
      sxx += dx * dx
      sxz += dx * dz
      szz += dz * dz
    }
    let ang = 0.5 * atan2(2 * sxz, sxx - szz)
    var nx = -sin(ang), nz = cos(ang)
    // Facing the camera.
    if (cam.x - mx) * nx + (cam.z - mz) * nz < 0 {
      nx = -nx
      nz = -nz
    }
    // The crosshair's point: where its ray (camera to the old origin) meets
    // the new wall.
    let o = frame.origin
    let ray = o - cam
    let den = ray.x * nx + ray.z * nz
    if abs(den) < 1e-3 { return nil }
    let k = ((mx - cam.x) * nx + (mz - cam.z) * nz) / den
    if k <= 0 { return nil }
    let origin = cam + ray * k
    let dOrigin = origin - o
    let moved = (dOrigin.x * dOrigin.x + dOrigin.z * dOrigin.z).squareRoot() * (k < 1 ? -1 : 1)
    let cosTurn = min(max(nx * wn.x + nz * wn.z, -1), 1)
    let turned = acos(cosTurn) * 180 / .pi
    let wall = WallFrame(origin: origin, normal: V3(nx, 0, nz), floorY: fy, estimated: false)
    return FloorLineWall(frame: wall, moved: moved, turned: turned, strips: inl.count)
  }

  /// A side, top or bottom edge group: `pos` its inside edge, `outer` its
  /// outside edge (cells), `score` its strongest edge's strength.
  private struct Side {
    var pos: Float
    var outer: Float
    var score: Float
    var prominence: Float
  }

  /// Mean of `v` (reordered) with each value capped at the 75th
  /// percentile: an edge counts by how strong it is along most of its
  /// length, so a short bright feature (a door handle, a light switch) next
  /// to a frame does not outweigh the frame's own edge.
  private static func cappedMean(_ v: inout [Float]) -> Float {
    if v.isEmpty { return 0 }
    v.sort()
    let cap = v[min(v.count - 1, v.count * 3 / 4)]
    var s: Float = 0
    for x in v { s += min(x, cap) }
    return s / Float(v.count)
  }

  /// Of the strong edges within casingReach of `anchor`, the one farthest
  /// from `from` (the crosshair): the outside edge of a casing or frame.
  private static func outermost(_ ps: [Peak], around anchor: Peak, from: Float) -> Peak {
    var best = anchor
    for p in ps where abs(p.pos - anchor.pos) <= casingReach && p.value >= casingShare * anchor.value {
      if abs(p.pos - from) > abs(best.pos - from) { best = p }
    }
    return best
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

// MARK: - Room scan counting, frame adjustment, aim smoothing
// (twins of RoomOpeningCounter / OpeningFrameAdjust in OpeningDetector.kt
// and AimSmoother.kt; keep them in sync).

/// Doors and windows counted automatically while a room is scanned (Auto
/// mode): which steady detections are real doors / windows, and which repeat
/// one already counted.
enum RoomOpeningCounter {
  /// Detections whose centres are closer than this (m) are one opening.
  static let duplicate: Float = 0.5

  /// Whether a steady detection has a door's or a window's proportions
  /// (and, when the floor is known, sits where one would). Anything else (a
  /// picture frame, a wardrobe front, a radiator) is not counted.
  static func plausible(_ kind: OpeningKind, width: Float, height: Float, bottom: Float,
                        floorY: Float?) -> Bool {
    switch kind {
    case .door:
      return width >= 0.6 && width <= 1.4 && height >= 1.75 && height <= 2.5
        && (floorY.map { abs(bottom - $0) <= 0.12 } ?? true)
    case .window:
      return width >= 0.35 && width <= 3.2 && height >= 0.35 && height <= 2.3
        && (floorY.map { bottom - $0 >= 0.15 && bottom - $0 <= 1.9 } ?? true)
    }
  }

  /// Whether door detection `door` is really the window `window` found in
  /// the same image: the door's bottom is taken at the floor, so a window's
  /// sides and top can read as a door. A window clearly above the floor
  /// (sill over 30 cm) spanning most of the door's width means it is not one.
  static func doorIsWindow(_ door: OpeningCandidate, _ window: OpeningCandidate?, floorY: Float?) -> Bool {
    guard let window else { return false }
    guard let sill = window.sill ?? floorY.map({ window.bottom - $0 }) else { return false }
    if sill < 0.30 { return false }
    let overlap = min(door.right, window.right) - max(door.left, window.left)
    return overlap >= 0.5 * min(door.width, window.width)
  }

  /// Centre of an opening from its bottom corners and heights.
  static func centre(_ a: V3, _ b: V3, bottom: Float, top: Float) -> V3 {
    V3((a.x + b.x) / 2, (bottom + top) / 2, (a.z + b.z) / 2)
  }

  /// Index in `existing` (opening centres) of the one at `centre`, or nil.
  static func duplicateOf(_ centre: V3, _ existing: [V3]) -> Int? {
    var best: Int?
    var bestD = duplicate
    for (i, e) in existing.enumerated() {
      let d = simd_length(e - centre)
      if d < bestD {
        bestD = d
        best = i
      }
    }
    return best
  }
}

/// Adjusting the door / window frame found by hand, on the camera view. The
/// frame is a rectangle on its wall: left / right (m along the wall), bottom
/// / top (heights). Each side has its own handle, a circle at its middle,
/// and moving one side never moves another (corner handles moved two).
enum OpeningFrameAdjust {
  static let bottom = 0
  static let right = 1
  static let top = 2
  static let left = 3

  /// Smallest width / height a side may leave (m).
  static let minSize: Float = 0.10

  /// The side under a finger at `p`: `s` are the frame's corners on screen
  /// (bottom-left, bottom-right, top-right, top-left; nil behind the
  /// camera), side i running from corner i to i + 1. A handle (side middle)
  /// within `handleRadius` wins; otherwise the nearest line within
  /// `lineRadius`. nil when none.
  static func pickSide(_ s: [SIMD2<Float>?], _ p: SIMD2<Float>, handleRadius: Float,
                       lineRadius: Float) -> Int? {
    guard s.count == 4 else { return nil }
    var best: Int?
    var bestD = handleRadius
    for i in 0..<4 {
      guard let a = s[i], let b = s[(i + 1) % 4] else { continue }
      let d = simd_length((a + b) / 2 - p)
      if d < bestD {
        bestD = d
        best = i
      }
    }
    if best != nil { return best }
    bestD = lineRadius
    for i in 0..<4 {
      guard let a = s[i], let b = s[(i + 1) % 4] else { continue }
      let ab = b - a
      let len2 = simd_length_squared(ab)
      let t: Float = len2 > 0 ? min(max(simd_dot(p - a, ab) / len2, 0), 1) : 0
      let d = simd_length(a + ab * t - p)
      if d < bestD {
        bestD = d
        best = i
      }
    }
    return best
  }

  /// Whether `side` runs up the wall (its position is along the wall).
  static func isVertical(_ side: Int) -> Bool { side == Self.left || side == Self.right }

  /// The current position of `side`.
  static func sideValue(_ side: Int, left l: Float, right r: Float, bottom b: Float, top t: Float) -> Float {
    switch side {
    case Self.left: return l
    case Self.right: return r
    case Self.bottom: return b
    default: return t
    }
  }

  /// `side` moved to `value`; every other side stays exactly where it is.
  /// The side stops `minSize` short of the opposite one.
  static func moveSide(_ side: Int, to value: Float, left l: Float, right r: Float, bottom b: Float,
                       top t: Float) -> (left: Float, right: Float, bottom: Float, top: Float) {
    switch side {
    case Self.left: return (min(value, r - minSize), r, b, t)
    case Self.right: return (l, max(value, l + minSize), b, t)
    case Self.bottom: return (l, r, min(value, t - minSize), t)
    case Self.top: return (l, r, b, max(value, b + minSize))
    default: return (l, r, b, t)
    }
  }
}

/// Steadies the point under the crosshair. A single frame's hit jitters by
/// a centimetre or more (depth noise, tracking noise, the hand). When the
/// phone is held still, the per-axis median of the last `window` seconds of
/// hits is used instead, so one frame's noise no longer goes into a mark.
struct AimSmoother {
  var window: TimeInterval = 0.35
  /// Hits further than this from the median (m) mean the aim moved.
  var steady: Float = 0.03
  /// Fewest hits worth a median.
  var minHits = 4

  private var times = [TimeInterval]()
  private var points = [V3]()

  init() {}

  /// Records the hit of the frame at `now` (seconds); nil when nothing is
  /// under the crosshair, which starts over.
  mutating func add(_ now: TimeInterval, _ hit: V3?) {
    guard let hit else {
      clear()
      return
    }
    times.append(now)
    points.append(hit)
    while let first = times.first, now - first > window {
      times.removeFirst()
      points.removeFirst()
    }
  }

  mutating func clear() {
    times.removeAll()
    points.removeAll()
  }

  /// The median of the recent hits when there are enough and they all
  /// agree (the aim was held still), else `latest` (the aim is moving).
  func point(_ latest: V3) -> V3 {
    if points.count < minHits { return latest }
    func median(_ v: [Float]) -> Float {
      let s = v.sorted()
      return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    let m = V3(median(points.map { $0.x }), median(points.map { $0.y }), median(points.map { $0.z }))
    for p in points where simd_length(p - m) > steady { return latest }
    return simd_length(latest - m) > steady ? latest : m
  }
}
