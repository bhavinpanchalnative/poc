import CoreML
import Foundation
import simd
import Vision

// AI furniture detection for the camera scanner: an on-device object
// detector (Apple's YOLOv3 Tiny Core ML model, COCO classes; MIT, from
// darknet) finds furniture in the camera image; each box is placed on the
// floor plan through where its bottom meets the floor, and kept once several
// images agree. The twin of FurnitureDetector.kt (keep them in sync; its
// tests cover the shared logic).

struct FurnitureKind {
  let name: String
  /// Usual depth front to back (m): the camera sees only the front.
  let depth: Float
}

enum FurnitureKinds {
  /// Detector labels kept (both the COCO and the darknet spellings), and
  /// what the plan calls them. Things that usually stand on something else
  /// (a TV, a sink) are left out: the bottom of their box is not where they
  /// meet the floor.
  static let byLabel: [String: FurnitureKind] = [
    "bed": FurnitureKind(name: "Bed", depth: 2.0),
    "couch": FurnitureKind(name: "Sofa", depth: 0.9),
    "sofa": FurnitureKind(name: "Sofa", depth: 0.9),
    "chair": FurnitureKind(name: "Chair", depth: 0.55),
    "dining table": FurnitureKind(name: "Table", depth: 0.9),
    "diningtable": FurnitureKind(name: "Table", depth: 0.9),
    "toilet": FurnitureKind(name: "Toilet", depth: 0.7),
    "refrigerator": FurnitureKind(name: "Refrigerator", depth: 0.7),
    "oven": FurnitureKind(name: "Oven", depth: 0.6),
    "potted plant": FurnitureKind(name: "Plant", depth: 0.5),
    "pottedplant": FurnitureKind(name: "Plant", depth: 0.5),
  ]

  static let minScore: Float = 0.5
}

/// A pinhole camera for the captured image: `sensorToWorld` is the camera
/// transform (x right, y up, looking down -z), intrinsics in image pixels.
struct PinholeCamera {
  let sensorToWorld: simd_float4x4
  let fx: Float, fy: Float, cx: Float, cy: Float

  var origin: V3 { V3(sensorToWorld.columns.3.x, sensorToWorld.columns.3.y, sensorToWorld.columns.3.z) }

  func ray(_ u: Float, _ v: Float) -> V3 {
    let d = sensorToWorld * SIMD4<Float>((u - cx) / fx, -(v - cy) / fy, -1, 0)
    return V3(d.x, d.y, d.z)
  }

  /// Where the ray through (u, v) meets the floor; nil when it does not.
  func onFloor(_ u: Float, _ v: Float, floorY: Float, maxDistance: Float = 7) -> V3? {
    let o = origin, d = ray(u, v)
    if d.y > -1e-3 { return nil }
    let t = (floorY - o.y) / d.y
    if t <= 0 { return nil }
    let p = V3(o.x + d.x * t, floorY, o.z + d.z * t)
    if hypot(p.x - o.x, p.z - o.z) > maxDistance { return nil }
    return p
  }
}

/// A detection in the upright image (pixels, y down).
struct Detection2D {
  let label: String
  let score: Float
  let left: Float, top: Float, right: Float, bottom: Float
}

/// A piece of furniture on the floor. `yaw` is the direction of its width
/// (radians, atan2(z, x)).
struct Furniture {
  let kind: String
  let center: V3
  let width: Float, depth: Float, height: Float
  let yaw: Float

  /// Its rectangle on the floor, corner by corner.
  var footprint: [V3] {
    let ux = cos(yaw) * width / 2, uz = sin(yaw) * width / 2
    let vx = -sin(yaw) * depth / 2, vz = cos(yaw) * depth / 2
    let c = center
    return [V3(c.x - ux - vx, c.y, c.z - uz - vz), V3(c.x + ux - vx, c.y, c.z + uz - vz),
            V3(c.x + ux + vx, c.y, c.z + uz + vz), V3(c.x - ux + vx, c.y, c.z - uz + vz)]
  }
}

enum FurniturePlacement {
  /// `d` placed on the floor: its front edge where the bottom of the box
  /// meets the floor, its width from the box at that distance, its usual
  /// depth, square to the view. Nil when it can't be placed.
  static func place(_ d: Detection2D, cam: PinholeCamera, floorY: Float, uprightHeight: Float,
                    toSensor: (Float, Float) -> (Float, Float)) -> Furniture? {
    guard let kind = FurnitureKinds.byLabel[d.label.lowercased()], d.score >= FurnitureKinds.minScore else { return nil }
    if d.bottom > uprightHeight - 4 { return nil }
    let mid = (d.left + d.right) / 2
    let b = toSensor(mid, d.bottom), l = toSensor(d.left, d.bottom), r = toSensor(d.right, d.bottom)
    guard let front = cam.onFloor(b.0, b.1, floorY: floorY),
          let lp = cam.onFloor(l.0, l.1, floorY: floorY),
          let rp = cam.onFloor(r.0, r.1, floorY: floorY) else { return nil }
    let width = hypot(rp.x - lp.x, rp.z - lp.z)
    if width < 0.2 || width > 4 { return nil }
    let o = cam.origin
    let t = toSensor(mid, d.top)
    let top = cam.ray(t.0, t.1)
    let dist = hypot(front.x - o.x, front.z - o.z)
    let horiz = hypot(top.x, top.z)
    let height = horiz > 1e-4 ? min(max(o.y + top.y / horiz * dist - floorY, 0.1), 3) : 0.5
    // Far taller than that kind ever is: the floor (or the box) is wrong.
    if height > (kind.name == "Refrigerator" ? 2.4 : 1.6) { return nil }
    var ax = front.x - o.x, az = front.z - o.z
    let al = max(hypot(ax, az), 1e-4)
    ax /= al
    az /= al
    let depth: Float = kind.name == "Bed" && width > 1.7 ? 1.5 : kind.depth
    let center = V3(front.x + ax * depth / 2, floorY, front.z + az * depth / 2)
    return Furniture(kind: kind.name, center: center, width: width, depth: depth, height: height,
                     yaw: atan2(ax, -az))
  }
}

/// Furniture found while scanning: detections of the same kind close
/// together are one piece, averaged; a piece counts once seen `minHits` times.
final class FurnitureTracker {
  private struct Track { var f: Furniture; var hits: Int }
  private var tracks: [Track] = []
  private let minHits: Int
  private let sameDistance: Float

  init(minHits: Int = 3, sameDistance: Float = 0.8) {
    self.minHits = minHits
    self.sameDistance = sameDistance
  }

  func add(_ f: Furniture) {
    func dist(_ t: Track) -> Float { hypot(t.f.center.x - f.center.x, t.f.center.z - f.center.z) }
    if let i = tracks.indices.filter({ tracks[$0].f.kind == f.kind }).min(by: { dist(tracks[$0]) < dist(tracks[$1]) }),
       dist(tracks[i]) < sameDistance {
      let a = tracks[i].f, n = Float(tracks[i].hits), k = 1 / (n + 1)
      let c = cos(2 * a.yaw) * n + cos(2 * f.yaw), s = sin(2 * a.yaw) * n + sin(2 * f.yaw)
      tracks[i].f = Furniture(
        kind: a.kind,
        center: V3(a.center.x + (f.center.x - a.center.x) * k, a.center.y, a.center.z + (f.center.z - a.center.z) * k),
        width: a.width + (f.width - a.width) * k, depth: a.depth + (f.depth - a.depth) * k,
        height: a.height + (f.height - a.height) * k, yaw: atan2(s, c) / 2)
      tracks[i].hits += 1
    } else {
      tracks.append(Track(f: f, hits: 1))
    }
  }

  var confirmed: [Furniture] { tracks.filter { $0.hits >= minHits }.map { $0.f } }

  func clear() { tracks.removeAll() }
}

/// Maps a pixel of the image turned upright by `degrees` (clockwise) back to
/// the sensor image (`w` × `h`).
func uprightToSensor(_ degrees: Int, _ w: Int, _ h: Int) -> (Float, Float) -> (Float, Float) {
  let fw = Float(w), fh = Float(h)
  switch ((degrees % 360) + 360) % 360 {
  case 90: return { x, y in (y, fh - 1 - x) }
  case 180: return { x, y in (fw - 1 - x, fh - 1 - y) }
  case 270: return { x, y in (fw - 1 - y, x) }
  default: return { x, y in (x, y) }
  }
}

/// The Core ML furniture detector (bundled YOLOv3TinyInt8LUT, compiled by
/// Xcode). Use from one queue.
final class FurnitureModel {
  private let request: VNCoreMLRequest

  init?() {
    guard let url = Bundle.main.url(forResource: "YOLOv3TinyInt8LUT", withExtension: "mlmodelc"),
          let ml = try? MLModel(contentsOf: url),
          let vn = try? VNCoreMLModel(for: ml) else { return nil }
    request = VNCoreMLRequest(model: vn)
    request.imageCropAndScaleOption = .scaleFill
  }

  /// Furniture in `buffer` (the sensor image) turned upright by `degrees`;
  /// boxes in upright pixels (y down).
  func detect(_ buffer: CVPixelBuffer, degrees: Int) -> [Detection2D] {
    let orientation: CGImagePropertyOrientation
    switch degrees {
    case 90: orientation = .right
    case 180: orientation = .down
    case 270: orientation = .left
    default: orientation = .up
    }
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
    guard (try? handler.perform([request])) != nil,
          let results = request.results as? [VNRecognizedObjectObservation] else { return [] }
    let sw = Float(CVPixelBufferGetWidth(buffer)), sh = Float(CVPixelBufferGetHeight(buffer))
    let (w, h) = degrees % 180 == 0 ? (sw, sh) : (sh, sw)
    return results.compactMap { o in
      guard let top = o.labels.first else { return nil }
      // Vision's boxes are normalised, origin bottom left.
      let b = o.boundingBox
      return Detection2D(label: top.identifier, score: top.confidence,
                         left: Float(b.minX) * w, top: Float(1 - b.maxY) * h,
                         right: Float(b.maxX) * w, bottom: Float(1 - b.minY) * h)
    }
  }
}
