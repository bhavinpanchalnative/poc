// Simulated rooms for the iOS RoomDetector (the same scenarios as the
// Android RoomDetectorTest). Rooms are rotated and shifted in world space.
//
// Also checks the iOS OpeningDetector (automatic door / window finding) on
// synthetic camera images of a wall with a door or window.
//
// Run from the project root:
//   swiftc -O -o /tmp/room_check ios/Runner/RoomDetector.swift ios/Runner/OpeningDetector.swift tool/ios_room_detector_check/main.swift && /tmp/room_check
//
// Replay a real scan (file pulled from the phone's Documents/room_measure/diag):
//   /tmp/room_check path/to/scan_1234567890.json

import Foundation
import simd

// Replay mode: `room_check <scan_*.json>` runs the detector on a diagnostic
// file saved by the iPhone scanner (Documents/room_measure/diag) and prints
// what it finds, so detection can be tuned on real scans.
if CommandLine.arguments.count > 1 {
  let path = CommandLine.arguments[1]
  guard let data = FileManager.default.contents(atPath: path),
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    print("cannot read \(path)")
    exit(2)
  }
  func nums(_ k: String) -> [Float] { (j[k] as? [NSNumber] ?? []).map { $0.floatValue } }
  func num(_ k: String) -> Float? { (j[k] as? NSNumber)?.floatValue }
  func v3s(_ a: [Float]) -> [V3] { stride(from: 0, to: a.count - 2, by: 3).map { V3(a[$0], a[$0 + 1], a[$0 + 2]) } }
  let cloud = v3s(nums("cloud"))
  let floorPts = v3s(nums("floorPts"))
  let walls = (j["walls"] as? [[NSNumber]] ?? []).filter { $0.count >= 7 }.map { w -> WallSegment in
    let f = w.map { $0.floatValue }
    return WallSegment(cx: f[0], cz: f[1], dx: f[2], dz: f[3], tMin: f[4], tMax: f[5], top: f[6])
  }
  let cam = nums("cam")
  let floorUsed = num("floorUsed") ?? num("floorY") ?? num("pointFloorY") ?? ((cam.count > 1 ? cam[1] : 0) - 1.35)
  print("device \(j["device"] ?? "?"), frames \(j["frames"] ?? "?"), mode \(j["mode"] ?? "?")")
  print(String(format: "floor plane %@, floor from points %@, ceiling %@, floor used %.2f (guessed: %@)",
               "\(j["floorY"] ?? "-")", "\(j["pointFloorY"] ?? "-")", "\(j["ceilingY"] ?? "-")", floorUsed, "\(j["floorGuessed"] ?? "?")"))
  print("cloud \(cloud.count) points, \(walls.count) wall surfaces, \(floorPts.count) floor outline points, "
        + "\((j["planes"] as? [Any])?.count ?? 0) planes")
  let heights = cloud.map { $0.y - floorUsed }
  func share(_ lo: Float, _ hi: Float) -> Int { heights.filter { $0 >= lo && $0 < hi }.count }
  print("points by height above floor: <0.1 m \(share(-9, 0.1)), 0.1-1.3 m \(share(0.1, 1.3)), "
        + "1.3-2.3 m \(share(1.3, 2.3)), >2.3 m \(share(2.3, 99))")
  print("sectors covered \((j["sectors"] as? [NSNumber] ?? []).map { $0.intValue }), move extent \(j["moveExtent"] ?? "?") m")
  if let r = j["room"] as? [String: Any] {
    print("on the phone: \(r["width"] ?? "?") x \(r["depth"] ?? "?") m, estimated \(r["estimated"] ?? "?"), height \(r["height"] ?? "-")")
  } else {
    print("on the phone: no room found")
  }
  if cam.count >= 3 {
    let room = RoomDetector.computeAutoRoom(walls: walls, floorPts: floorPts, floorY: floorUsed,
                                            cx: cam[0], cz: cam[2], ceilingY: num("ceilingY"), cloud: cloud)
    if let room {
      print(String(format: "replayed here: %.2f x %.2f m, area %.2f, %d corners, estimated sides %@, height %@",
                   room.width, room.depth, room.area, room.corners.count, "\(room.estimated)",
                   room.height.map { String(format: "%.2f", $0) } ?? "-"))
    } else {
      print("replayed here: no room found")
    }
  }
  for line in (j["log"] as? [String] ?? []).suffix(40) { print("  log: \(line)") }
  exit(0)
}

struct Rng {
  var s: UInt64
  mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) }
  mutating func gauss(_ sd: Float) -> Float {
    let u1 = max(next(), 1e-7), u2 = next()
    return sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
  }
}

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
  if ok { passed += 1; print("PASS  \(name)  \(detail)") } else { failed += 1; print("FAIL  \(name)  \(detail)") }
}

let angle: Float = 0.6, offX: Float = 1.3, offZ: Float = -0.7
func world(_ x: Float, _ z: Float) -> (Float, Float) {
  (x * cos(angle) - z * sin(angle) + offX, x * sin(angle) + z * cos(angle) + offZ)
}
func wall(_ ax: Float, _ az: Float, _ bx: Float, _ bz: Float, _ f0: Float = 0.2, _ f1: Float = 0.8) -> WallSegment {
  let (wax, waz) = world(ax, az), (wbx, wbz) = world(bx, bz)
  let len = ((wbx - wax) * (wbx - wax) + (wbz - waz) * (wbz - waz)).squareRoot()
  return WallSegment(cx: (wax + wbx) / 2, cz: (waz + wbz) / 2, dx: (wbx - wax) / len, dz: (wbz - waz) / len,
                     tMin: (f0 - 0.5) * len, tMax: (f1 - 0.5) * len, top: 1.9)
}
func floor(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float) -> [V3] {
  [(x0, z0), (x1, z0), (x1, z1), (x0, z1)].map { let (x, z) = world($0.0, $0.1); return V3(x, 0, z) }
}
func size(_ r: AutoRoom?) -> String {
  r.map { String(format: "%.3f x %.3f m, area %.2f, est %d", $0.width, $0.depth, $0.area, $0.estimatedCount) } ?? "none"
}
func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

let rect = [wall(0, 0, 4.2, 0), wall(4.2, 0, 4.2, 3.6), wall(4.2, 3.6, 0, 3.6), wall(0, 3.6, 0, 0)]
func detect(_ walls: [WallSegment], _ fl: [V3], _ cx: Float, _ cz: Float) -> AutoRoom? {
  let (x, z) = world(cx, cz)
  return RoomDetector.computeAutoRoom(walls: walls, floorPts: fl, floorY: 0, cx: x, cz: z, ceilingY: 2.6)
}

// ---- detected wall surfaces
var r = detect(rect, [], 2.1, 1.8)
check("4.20 x 3.60 room, walls partly detected", r != nil && near(r!.width, 4.2, 0.01) && near(r!.depth, 3.6, 0.01)
      && near(r!.area, 15.12, 0.05) && near(r!.height ?? 0, 2.6, 0.001), size(r))
r = detect(rect + [wall(0.6, 1.0, 0.6, 2.2, 0, 1), wall(1.0, 3.1, 2.5, 3.1, 0, 1)], [], 2.1, 1.8)
check("wardrobe and sideboard ignored", r != nil && near(r!.width, 4.2, 0.01) && near(r!.depth, 3.6, 0.01), size(r))
r = detect(rect + [wall(0.8, 0.12, 3.2, 0.12, 0, 1), wall(4.05, 0.6, 4.05, 3.0, 0, 1)], [], 2.1, 1.8)
check("radiator 12 cm / shelves 15 cm from walls", r != nil && near(r!.width, 4.2, 0.01) && near(r!.depth, 3.6, 0.01), size(r))
r = detect(Array(rect.prefix(3)), floor(0.3, 0.2, 4.0, 3.4), 2.1, 1.8)
check("unseen wall estimated from floor", r != nil && r!.estimatedCount == 1 && near(r!.width, 3.9, 0.02), size(r))
r = detect([wall(0, 0, 6, 0, 0.15, 0.85), wall(6, 0, 6, 2.8), wall(6, 2.8, 3.5, 2.8), wall(3.5, 2.8, 3.5, 5),
            wall(3.5, 5, 0, 5), wall(0, 5, 0, 0, 0.15, 0.85)], [], 2, 2)
check("L-shaped room", r != nil && r!.corners.count == 6 && near(r!.area, 30 - 2.5 * 2.2, 0.1), size(r))

// ---- feature points only
var rng = Rng(s: 42)
func wallPoints(_ ax: Float, _ az: Float, _ bx: Float, _ bz: Float, _ n: Int, _ f0: Float = 0.1, _ f1: Float = 0.9) -> [V3] {
  (0..<n).map { _ in
    let t = f0 + rng.next() * (f1 - f0)
    let (x, z) = world(ax + (bx - ax) * t + rng.gauss(0.02), az + (bz - az) * t + rng.gauss(0.02))
    return V3(x, 0.15 + rng.next() * 1.7, z)
  }
}
func clutter(_ n: Int, _ w: Float, _ d: Float) -> [V3] {
  (0..<n).map { _ in
    let (x, z) = world(0.3 + rng.next() * (w - 0.6), 0.3 + rng.next() * (d - 0.6))
    return V3(x, 0.2 + rng.next() * 0.8, z)
  }
}
func detectCloud(_ cloud: [V3], _ fl: [V3], _ cx: Float, _ cz: Float, ceiling: Float? = nil) -> AutoRoom? {
  let (x, z) = world(cx, cz)
  return RoomDetector.computeAutoRoom(walls: [], floorPts: fl, floorY: 0, cx: x, cz: z, ceilingY: ceiling, cloud: cloud)
}
var cloud = wallPoints(0, 0, 4.2, 0, 120) + wallPoints(4.2, 0, 4.2, 3.6, 60, 0.3, 0.7) + wallPoints(4.2, 3.6, 0, 3.6, 150)
  + wallPoints(0, 3.6, 0, 0, 90) + wallPoints(1.0, 0.7, 2.4, 0.7, 80) + clutter(200, 4.2, 3.6)
r = detectCloud(cloud, floor(1, 1, 3, 2.5), 2.1, 1.8)
check("plain walls, feature points only", r != nil && r!.estimatedCount == 0 && near(r!.width, 4.2, 0.05) && near(r!.depth, 3.6, 0.05), size(r))
cloud = wallPoints(0, 0, 4.2, 0, 120) + wallPoints(4.2, 0, 4.2, 3.6, 100) + wallPoints(4.2, 3.6, 0, 3.6, 120)
  + wallPoints(0, 3.6, 0, 0, 100) + wallPoints(0.8, 0.12, 3.4, 0.12, 150, 0, 1) + clutter(150, 4.2, 3.6)
r = detectCloud(cloud, floor(1, 1, 3, 2.5), 2.1, 1.8)
check("radiator points 12 cm from a wall", r != nil && near(r!.width, 4.2, 0.05) && near(r!.depth, 3.6, 0.05), size(r))

// ---- furniture
do {
  var desk = [V3]()
  for _ in 0..<120 {
    let t = 0.25 + rng.next() * 0.5
    let (x, z) = world(4.2 * t, 0.6 + rng.gauss(0.015))
    desk.append(V3(x, 0.3 + rng.next() * 0.5, z))
  }
  let c1 = wallPoints(4.2, 0, 4.2, 3.6, 100) + wallPoints(4.2, 3.6, 0, 3.6, 120) + wallPoints(0, 3.6, 0, 0, 100)
    + desk + clutter(150, 4.2, 3.6)
  let r1 = detectCloud(c1, floor(0.4, 0.4, 3.8, 3.2), 2.1, 2.0)
  check("desk in front of an unscanned wall is flagged, not measured", r1 != nil && r1!.estimatedCount >= 1, size(r1))

  var high = [V3](), sofa = [V3]()
  for _ in 0..<90 {
    let t = 0.1 + rng.next() * 0.8
    let (x, z) = world(4.2 * t, rng.gauss(0.02))
    high.append(V3(x, 1.0 + rng.next() * 1.2, z))
  }
  for _ in 0..<200 {
    let t = 0.2 + rng.next() * 0.6
    let (x, z) = world(4.2 * t, 0.35 + rng.gauss(0.015))
    sofa.append(V3(x, 0.2 + rng.next() * 0.6, z))
  }
  let c2 = high + sofa + wallPoints(4.2, 0, 4.2, 3.6, 100) + wallPoints(4.2, 3.6, 0, 3.6, 120)
    + wallPoints(0, 3.6, 0, 0, 100) + clutter(150, 4.2, 3.6)
  let r2 = detectCloud(c2, floor(1, 1, 3, 2.5), 2.1, 1.8, ceiling: 2.5)
  check("tall wall behind a sofa wins over the sofa",
        r2 != nil && r2!.estimatedCount == 0 && near(r2!.width, 4.2, 0.05) && near(r2!.depth, 3.6, 0.05), size(r2))
}

// ---- long scans and open doors
do {
  let c = wallPoints(0, 0, 4.2, 0, 2500) + wallPoints(4.2, 0, 4.2, 3.6, 2500) + wallPoints(4.2, 3.6, 0, 3.6, 2500)
    + wallPoints(0, 3.6, 0, 0, 45) + clutter(300, 4.2, 3.6)
  let r1 = detectCloud(c, floor(1, 1, 3, 2.5), 2.1, 1.8)
  check("plain wall still found after scanning lots of texture",
        r1 != nil && r1!.estimatedCount == 0 && near(r1!.width, 4.2, 0.05) && near(r1!.depth, 3.6, 0.05), size(r1))

  let c2 = wallPoints(0, 0, 4.2, 0, 120) + wallPoints(4.2, 0, 4.2, 3.6, 100) + wallPoints(4.2, 3.6, 0, 3.6, 120)
    + wallPoints(0, 3.6, 0, 0, 100) + clutter(150, 4.2, 3.6)
  let corridor: [(Float, Float)] = [(0.3, 0.3), (1.5, 0.3), (1.4, -1.5), (2.6, -1.5), (2.4, 0.3), (3.9, 0.3), (3.9, 3.3), (0.3, 3.3)]
  let fl = corridor.map { p -> V3 in let (x, z) = world(p.0, p.1); return V3(x, 0, z) }
  let r2 = detectCloud(c2, fl, 2.1, 1.8)
  check("floor seen through an open door does not cancel the wall",
        r2 != nil && r2!.estimatedCount == 0 && near(r2!.width, 4.2, 0.05) && near(r2!.depth, 3.6, 0.05), size(r2))
}

// ---- random rooms: a wrong size must never be shown as fully measured
func randomRooms(_ seeds: ClosedRange<Int>, radiator: Bool) -> (wrong: Int, flagged: Int, worst: Float) {
  var wrong = 0, flagged = 0
  var worst: Float = 0
  for seed in seeds {
    var g = Rng(s: UInt64(seed) &* 0x9E3779B97F4A7C15)
    let w = 2.5 + g.next() * 3.5, d = 2.0 + g.next() * 3.0, rot = g.next() * 6.28
    let ox = g.next() * 4 - 2, oz = g.next() * 4 - 2
    func wp(_ x: Float, _ z: Float, _ y: Float) -> V3 { V3(x * cos(rot) - z * sin(rot) + ox, y, x * sin(rot) + z * cos(rot) + oz) }
    var pts = [V3]()
    let cs: [(Float, Float)] = [(0, 0), (w, 0), (w, d), (0, d)]
    for i in 0..<4 {
      let (ax, az) = cs[i], (bx, bz) = cs[(i + 1) % 4]
      let f0 = radiator ? 0.1 : g.next() * 0.3, f1 = radiator ? 0.9 : 0.6 + g.next() * 0.4
      for _ in 0..<(radiator ? 60 + Int(g.next() * 90) : 40 + Int(g.next() * 110)) {
        let t = f0 + g.next() * (f1 - f0)
        pts.append(wp(ax + (bx - ax) * t + g.gauss(0.025), az + (bz - az) * t + g.gauss(0.025), 0.15 + g.next() * 1.7))
      }
    }
    for _ in 0..<(100 + Int(g.next() * 200)) {
      pts.append(wp(0.4 + g.next() * (w - 0.8), 0.4 + g.next() * (d - 0.8), 0.2 + g.next() * 0.8))
    }
    if radiator {
      let gap = 0.08 + g.next() * 0.10
      for _ in 0..<(120 + Int(g.next() * 80)) { pts.append(wp(w * (0.2 + g.next() * 0.6), gap + g.gauss(0.015), 0.2 + g.next() * 0.7)) }
    } else {
      let inset = 0.5 + g.next() * 0.4
      for _ in 0..<70 { pts.append(wp(w * (0.25 + g.next() * 0.4), inset + g.gauss(0.02), 0.3 + g.next() * 0.5)) }
    }
    let fl = [(0.3, 0.3), (w - 0.3, 0.3), (w - 0.3, d - 0.3), (0.3, d - 0.3)].map { wp($0.0, $0.1, 0) }
    let c = wp(w / 2, d / 2, 0)
    let room = RoomDetector.computeAutoRoom(walls: [], floorPts: fl, floorY: 0, cx: c.x, cz: c.z, ceilingY: nil, cloud: pts)
    guard let room, room.estimatedCount == 0 else { flagged += 1; continue }
    let err = max(abs(room.width - max(w, d)), abs(room.depth - min(w, d)))
    worst = max(worst, err)
    if err > 0.06 {
      wrong += 1
      print(String(format: "   seed %d: true %.2f x %.2f, got %.2f x %.2f", seed, max(w, d), min(w, d), room.width, room.depth))
    }
  }
  return (wrong, flagged, worst)
}
let a = randomRooms(1...50, radiator: false)
check("50 random rooms with furniture", a.wrong == 0 && a.flagged <= 5,
      String(format: "wrong %d, flagged as estimated %d, worst error %.1f cm", a.wrong, a.flagged, a.worst * 100))
let b = randomRooms(101...150, radiator: true)
check("50 random rooms with a radiator/shelf 8-18 cm from a wall", b.wrong <= 1 && b.flagged <= 5,
      String(format: "wrong %d, flagged as estimated %d, worst error %.1f cm", b.wrong, b.flagged, b.worst * 100))

// ---- doors and windows (OpeningDetector) on synthetic camera images
//
// A painted wall (plane z = 0, facing +z) 2.0-2.8 m in front of a phone held
// upright at 1.4 m, yawed and pitched; ARKit-style intrinsics of a 1920 x
// 1440 sensor image. Each image pixel is ray-cast into the scene (wall,
// floor, and for an open doorway a farther wall behind the opening), then
// the detector runs on it with the true wall frame, as the scanner does.
do {
  let imgW = 1920, imgH = 1440
  let fx: Float = 1450, fy: Float = 1450, icx: Float = 960, icy: Float = 720
  let doorX: Float = 0.3, winX: Float = -0.2
  // Opening sizes (changed for the off-grid series below).
  var doorW: Float = 0.82, doorH: Float = 2.03
  var winW: Float = 1.20, winH: Float = 1.10, winSill: Float = 0.90

  enum Scene { case door, openDoor, window, plain }

  /// Luminance seen along a ray (without noise).
  func shade(_ scene: Scene, _ o: V3, _ d: V3) -> Float {
    // The floor in front of the wall, or the wall itself.
    let tWall = d.z < -1e-6 ? -o.z / d.z : Float.infinity
    let tFloor = d.y < -1e-6 ? -o.y / d.y : Float.infinity
    if tFloor < tWall { return 100 }
    if !tWall.isFinite { return 0 }
    let p = o + d * tWall
    switch scene {
    case .plain:
      return 180
    case .door, .openDoor:
      let dx = abs(p.x - doorX)
      if dx <= doorW / 2 && p.y <= doorH {
        if scene == .door { return 90 }
        // Through the opening: a wall 2 m farther, or the floor before it.
        let tFar = (-2.0 - o.z) / d.z
        return tFloor < tFar ? 100 : 120
      }
      if dx <= doorW / 2 + 0.07 && p.y <= doorH + 0.07 { return 140 }
      return 180
    case .window:
      let dx = abs(p.x - winX)
      if dx <= winW / 2 && p.y >= winSill && p.y <= winSill + winH { return 60 }
      if dx <= winW / 2 + 0.08 && p.y >= winSill - 0.08 && p.y <= winSill + winH + 0.08 { return 220 }
      return 180
    }
  }

  var noise = Rng(s: 7)
  /// Renders the scene and runs the detector. The crosshair aims at
  /// (aimX, height given by the pitch) on the wall.
  func run(_ scene: Scene, _ kind: OpeningKind, dist: Float, yaw yawDeg: Float, pitch pitchDeg: Float,
           aimX: Float, floorKnown: Bool = true) -> (OpeningCandidate?, OpeningAnalysis) {
    let yaw = yawDeg * .pi / 180, pitch = pitchDeg * .pi / 180
    let f = V3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    let cam = V3(aimX + dist * tan(yaw), 1.4, dist)
    let aim = cam + f * (dist / (cos(yaw) * cos(pitch)))
    // ARKit camera axes; held upright, the sensor's long side (x) points
    // down the wall.
    let z = -f
    let down = V3(0, -1, 0)
    let x = simd_normalize(down - z * simd_dot(down, z))
    let y = simd_cross(z, x)
    let camToWorld = simd_float4x4(SIMD4<Float>(x, 0), SIMD4<Float>(y, 0), SIMD4<Float>(z, 0),
                                   SIMD4<Float>(cam, 1))
    var img = [Float](repeating: 0, count: imgW * imgH)
    for py in 0..<imgH {
      for px in 0..<imgW {
        let dc = x * ((Float(px) - icx) / fx) + y * (-(Float(py) - icy) / fy) - z
        img[py * imgW + px] = shade(scene, cam, simd_normalize(dc)) + noise.gauss(3)
      }
    }
    let model = CameraModel(worldToCamera: camToWorld.inverse, fx: fx, fy: fy, cx: icx, cy: icy,
                            width: imgW, height: imgH)
    let frame = WallFrame(origin: aim, normal: V3(0, 0, 1), floorY: floorKnown ? 0 : nil, estimated: false)
    let rect = OpeningDetector.rectify(frame: frame, camera: model) { sx, sy in
      if sx < 0 || sy < 0 || sx > Float(imgW - 1) || sy > Float(imgH - 1) { return nil }
      let x0 = min(Int(sx), imgW - 2), y0 = min(Int(sy), imgH - 2)
      let ax = sx - Float(x0), ay = sy - Float(y0)
      let i = y0 * imgW + x0
      return (img[i] * (1 - ax) + img[i + 1] * ax) * (1 - ay) + (img[i + imgW] * (1 - ax) + img[i + imgW + 1] * ax) * ay
    }
    let res = OpeningDetector.analyze(kind: kind, frame: frame, image: rect)
    return (res.candidate, res)
  }

  /// Runs a set of views; returns the number of misses and the worst error.
  func series(_ name: String, _ scene: Scene, _ kind: OpeningKind, aimX: Float,
              views: [(Float, Float, Float)], width: Float, height: Float, sill: Float?,
              floorKnown: Bool = true) {
    var misses = 0
    var worst: Float = 0
    for (dist, yaw, pitch) in views {
      let (c, res) = run(scene, kind, dist: dist, yaw: yaw, pitch: pitch, aimX: aimX, floorKnown: floorKnown)
      guard let c else {
        misses += 1
        print(String(format: "   %@ at %.1f m, yaw %.0f, pitch %.0f: nothing found (%@)",
                     name, dist, yaw, pitch, res.failure))
        continue
      }
      var err = max(abs(c.width - width), abs(c.height - height))
      if let sill { err = max(err, abs((c.sill ?? -9) - sill)) }
      if c.estimated { err = max(err, 9) }
      worst = max(worst, err)
      if err > 0.015 {
        print(String(format: "   %@ at %.1f m, yaw %.0f, pitch %.0f: %.3f x %.3f m, sill %@",
                     name, dist, yaw, pitch, c.width, c.height, c.sill.map { String(format: "%.3f", $0) } ?? "-"))
      }
    }
    check(name, misses == 0 && worst <= 0.015,
          String(format: "%d views, missed %d, worst error %.1f cm", views.count, misses, worst * 100))
  }

  var views = [(Float, Float, Float)]()
  for d: Float in [2.0, 2.4, 2.8] {
    for yaw: Float in [0, 12, -25] {
      for pitch: Float in [-10, 0, 10] { views.append((d, yaw, pitch)) }
    }
  }
  series("door 0.82 x 2.03 m with casing", .door, .door, aimX: doorX + 0.0537, views: views,
         width: 0.82, height: 2.03, sill: nil)
  series("open doorway (farther wall seen through it)", .openDoor, .door, aimX: doorX - 0.0614,
         views: [(2.0, 0, 0), (2.0, 20, -8), (2.4, -15, 5), (2.8, 25, 0), (2.8, -8, 10), (2.4, 0, -10)],
         width: 0.82, height: 2.03, sill: nil)
  series("door, floor not known (floor line used)", .door, .door, aimX: doorX + 0.0128,
         views: [(2.4, 12, 0), (2.8, -20, 0)], width: 0.82, height: 2.03, sill: nil, floorKnown: false)
  var winViews = [(Float, Float, Float)]()
  for d: Float in [2.0, 2.4, 2.8] {
    for yaw: Float in [0, 12, -25] {
      for pitch: Float in [-5, 0, 5] { winViews.append((d, yaw, pitch)) }
    }
  }
  winViews += [(2.0, 0, -10), (2.0, 15, 10)]
  series("window 1.20 x 1.10 m, sill 0.90 m", .window, .window, aimX: winX + 0.0813, views: winViews,
         width: 1.20, height: 1.10, sill: 0.90)

  // Sizes off the 1 cm grid of the rectified image (the edges then fall
  // inside cells): the sub-pixel fit must keep the error well under 1.5 cm.
  doorW = 0.817; doorH = 2.034
  series("door 0.817 x 2.034 m (off the 1 cm grid)", .door, .door, aimX: doorX - 0.0233,
         views: [(2.0, 0, 0), (2.4, 12, -10), (2.8, -25, 10), (2.2, 18, 4), (2.6, -7, -6)],
         width: 0.817, height: 2.034, sill: nil)
  winW = 1.203; winH = 1.096; winSill = 0.904
  series("window 1.203 x 1.096 m, sill 0.904 m (off the grid)", .window, .window, aimX: winX + 0.0371,
         views: [(2.0, 0, 0), (2.4, 12, -5), (2.8, -25, 5), (2.2, 18, 3), (2.6, -7, -4)],
         width: 1.203, height: 1.096, sill: 0.904)

  var falseHits = 0
  for (kind, dist, yaw, pitch) in [(OpeningKind.door, Float(2.0), Float(0), Float(0)), (.door, 2.8, 20, -10),
                                    (.window, 2.4, -12, 5), (.window, 2.0, 25, 0)] {
    if let c = run(.plain, kind, dist: dist, yaw: yaw, pitch: pitch, aimX: 0).0 {
      falseHits += 1
      print(String(format: "   plain wall: found %.2f x %.2f m", c.width, c.height))
    }
  }
  check("plain wall: nothing found", falseHits == 0, "\(falseHits) of 4 views found something")
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
