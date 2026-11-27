import ARKit
import AVFoundation
import CoreImage
import RoomPlan
import SceneKit
import UIKit

// Room Measure change to the vendored plugin: the scanning screen shows the
// plain camera image with a live 2D floor plan, instead of RoomPlan's 3D view
// (RoomCaptureView). The plan is built from RoomPlan's own room updates, so
// what is detected is unchanged: walls, doors, windows, openings and objects.
// Its look matches the guided scanner's plan (LivePlan.kt / LivePlan.swift in
// the app).
//
// Several rooms can be scanned in one go: "Room done" ends the room (RoomPlan
// builds it), then the user walks into the next room or taps Finish. Photos
// can be taken while scanning (with where they were taken) and the torch
// switched on for dark rooms.

/// The scanning screen: camera + 2D plan + RoomPlan's instructions + controls.
final class PlanScanViewController: UIViewController {
  let session: RoomCaptureSession

  /// "Room done" tapped.
  var onRoomDone: (() -> Void)?
  /// "Scan next room" tapped on the room-done card.
  var onNextRoom: (() -> Void)?
  /// "Finish" tapped on the room-done card.
  var onFinish: (() -> Void)?
  /// A photo was taken (its `room` is set by the controller).
  var onPhoto: ((SerializablePhoto) -> Void)?

  private let cameraView = ARSCNView()
  private let planView = LivePlanView()
  private let wallLines = WallLinesView()
  private let instructionLabel = PaddedLabel()
  private let processing = UIActivityIndicatorView(style: .large)
  private let controls = UIStackView()
  private let photoButton = UIButton(type: .system)
  private let torchButton = UIButton(type: .system)
  private let roomDoneButton = UIButton(type: .system)
  private let flashView = UIView()
  private let card = UIView()
  private let cardTitle = UILabel()
  private let cardDetail = UILabel()
  private let nextButton = UIButton(type: .system)
  private let finishButton = UIButton(type: .system)
  private var link: CADisplayLink?
  private var bigConstraints: [NSLayoutConstraint] = []
  private var smallConstraints: [NSLayoutConstraint] = []
  private var landscapeConstraints: [NSLayoutConstraint] = []
  private var controlsOverPlan: [NSLayoutConstraint] = []
  private var controlsInCorner: [NSLayoutConstraint] = []
  private var photoCount = 0
  private var torchOn = false

  private static let ink = UIColor(red: 11 / 255, green: 20 / 255, blue: 38 / 255, alpha: 1)
  private static let teal = UIColor(red: 18 / 255, green: 194 / 255, blue: 164 / 255, alpha: 1)
  private static let accent = UIColor(red: 47 / 255, green: 91 / 255, blue: 1, alpha: 1)

  init(session: RoomCaptureSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    // Only the camera image: no 3D model is drawn over it.
    cameraView.session = session.arSession
    cameraView.automaticallyUpdatesLighting = false
    cameraView.rendersCameraGrain = false
    cameraView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cameraView)

    // White lines along the walls found, drawn over the camera image.
    wallLines.sceneView = cameraView
    wallLines.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(wallLines)

    planView.translatesAutoresizingMaskIntoConstraints = false
    planView.onTap = { [weak self] in self?.toggleSize() }
    view.addSubview(planView)

    instructionLabel.translatesAutoresizingMaskIntoConstraints = false
    instructionLabel.insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    instructionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    instructionLabel.textColor = .white
    instructionLabel.textAlignment = .center
    instructionLabel.numberOfLines = 2
    instructionLabel.backgroundColor = Self.ink.withAlphaComponent(0.8)
    instructionLabel.layer.cornerRadius = 16
    instructionLabel.clipsToBounds = true
    instructionLabel.text = "Point at a wall and move slowly round the room"
    view.addSubview(instructionLabel)

    // Photo, torch, room done.
    func style(_ b: UIButton, _ symbol: String, _ title: String, filled: Bool = false) {
      var c = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
      c.image = UIImage(systemName: symbol)
      c.title = title
      c.imagePadding = 6
      c.cornerStyle = .capsule
      c.baseForegroundColor = .white
      c.baseBackgroundColor = filled ? Self.teal : Self.ink.withAlphaComponent(0.8)
      c.buttonSize = .medium
      b.configuration = c
    }
    style(photoButton, "camera.fill", "Photo")
    style(torchButton, "flashlight.off.fill", "Torch")
    style(roomDoneButton, "checkmark", "Room done", filled: true)
    photoButton.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)
    torchButton.addTarget(self, action: #selector(toggleTorch), for: .touchUpInside)
    roomDoneButton.addTarget(self, action: #selector(roomDone), for: .touchUpInside)
    controls.axis = .horizontal
    controls.spacing = 10
    for b in [photoButton, torchButton, roomDoneButton] { controls.addArrangedSubview(b) }
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)

    // The room-done card: next room or finish.
    card.backgroundColor = Self.ink.withAlphaComponent(0.94)
    card.layer.cornerRadius = 20
    card.isHidden = true
    card.translatesAutoresizingMaskIntoConstraints = false
    cardTitle.font = .systemFont(ofSize: 18, weight: .semibold)
    cardTitle.textColor = .white
    cardTitle.numberOfLines = 0
    cardDetail.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    cardDetail.textColor = UIColor(white: 1, alpha: 0.75)
    cardDetail.numberOfLines = 0
    style(nextButton, "arrow.right", "Scan next room")
    style(finishButton, "checkmark", "Finish", filled: true)
    nextButton.addTarget(self, action: #selector(nextRoom), for: .touchUpInside)
    finishButton.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
    let buttons = UIStackView(arrangedSubviews: [nextButton, finishButton])
    buttons.spacing = 10
    buttons.distribution = .fillEqually
    let stack = UIStackView(arrangedSubviews: [cardTitle, cardDetail, buttons])
    stack.axis = .vertical
    stack.spacing = 10
    stack.setCustomSpacing(18, after: cardDetail)
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)
    view.addSubview(card)

    flashView.backgroundColor = .white
    flashView.alpha = 0
    flashView.isUserInteractionEnabled = false
    flashView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(flashView)

    processing.color = .white
    processing.hidesWhenStopped = true
    processing.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(processing)

    let g = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      cameraView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      cameraView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      cameraView.topAnchor.constraint(equalTo: view.topAnchor),
      cameraView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      wallLines.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      wallLines.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      wallLines.topAnchor.constraint(equalTo: view.topAnchor),
      wallLines.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      flashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      flashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      flashView.topAnchor.constraint(equalTo: view.topAnchor),
      flashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      instructionLabel.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
      instructionLabel.centerXAnchor.constraint(equalTo: g.centerXAnchor),
      instructionLabel.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -32),
      processing.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      processing.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 20),
      card.centerXAnchor.constraint(equalTo: g.centerXAnchor),
      card.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -32),
      { let c = card.widthAnchor.constraint(equalToConstant: 340); c.priority = .defaultHigh; return c }(),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
    ])
    // Portrait: the lower part of the screen; landscape: the right half;
    // small: a square map top right (the camera view as before).
    bigConstraints = [
      planView.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
      planView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
      planView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
      planView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),
    ]
    landscapeConstraints = [
      planView.leadingAnchor.constraint(equalTo: view.centerXAnchor),
      planView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
      planView.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
      planView.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
    ]
    smallConstraints = [
      planView.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
      planView.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 12),
      planView.widthAnchor.constraint(equalToConstant: 150),
      planView.heightAnchor.constraint(equalToConstant: 150),
    ]
    // The buttons: just above the plan when it fills the lower part,
    // otherwise in the bottom left corner.
    controlsOverPlan = [
      controls.bottomAnchor.constraint(equalTo: planView.topAnchor, constant: -12),
      controls.centerXAnchor.constraint(equalTo: g.centerXAnchor),
    ]
    controlsInCorner = [
      controls.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
      controls.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
    ]
    applyLayout()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // The phone moves all the time, the room only now and then: the plan is
    // redrawn with the camera's pose about 30 times a second.
    let l = CADisplayLink(target: self, selector: #selector(tick))
    l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30)
    l.add(to: .main, forMode: .common)
    link = l
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    link?.invalidate()
    link = nil
    if torchOn { setTorch(false) }
  }

  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { _ in self.applyLayout() })
  }

  private func applyLayout() {
    NSLayoutConstraint.deactivate(bigConstraints + landscapeConstraints + smallConstraints
                                  + controlsOverPlan + controlsInCorner)
    let landscape = view.bounds.width > view.bounds.height
    if !planView.big {
      NSLayoutConstraint.activate(smallConstraints + controlsInCorner)
    } else if landscape {
      NSLayoutConstraint.activate(landscapeConstraints + controlsInCorner)
    } else {
      NSLayoutConstraint.activate(bigConstraints + controlsOverPlan)
    }
    view.layoutIfNeeded()
  }

  private func toggleSize() {
    planView.big.toggle()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    UIView.animate(withDuration: 0.2) { self.applyLayout() }
  }

  @objc private func tick() {
    guard let frame = session.arSession.currentFrame else { return }
    let t = frame.camera.transform
    let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    // The camera looks along its -z axis.
    let fwd = SIMD3<Float>(-t.columns.2.x, -t.columns.2.y, -t.columns.2.z)
    planView.setCamera(pos, forward: fwd, tracking: frame.camera.trackingState == .normal)
    wallLines.setCamera(pos, forward: fwd)
  }

  /// A room update from RoomPlan (main thread).
  func update(_ room: CapturedRoom) {
    planView.setRoom(room)
    wallLines.setRoom(room)
  }

  /// How many of the 12 directions (30° each) the camera has looked in, in
  /// the room being scanned; sent to Dart with each update so a room only
  /// ends by itself once the user has turned round to every wall.
  var sectorsSeen: Int { planView.sectorsSeen }

  /// RoomPlan's coaching instruction (main thread).
  func show(_ instruction: RoomCaptureSession.Instruction) {
    if processing.isAnimating || !card.isHidden { return }
    let text: String
    switch instruction {
    case .moveCloseToWall: text = "Move closer to the wall"
    case .moveAwayFromWall: text = "Move further from the wall"
    case .slowDown: text = "Slow down"
    case .turnOnLight: text = "Too dark: turn on a light or the torch"
    case .lowTexture: text = "Not enough detail here: point at something else"
    case .normal: text = "Move slowly round the room; turn to every wall"
    @unknown default: text = "Move slowly round the room"
    }
    instructionLabel.text = text
  }

  // MARK: Rooms

  @objc private func roomDone() { onRoomDone?() }
  @objc private func nextRoom() { onNextRoom?() }
  @objc private func finishTapped() {
    card.isHidden = true
    onFinish?()
  }

  /// A room is being built, or the whole scan (main thread).
  func showBusy(_ text: String) {
    instructionLabel.text = text
    processing.startAnimating()
    card.isHidden = true
    controls.isHidden = true
  }

  /// Room `index` has been built (`room`), or failed (`failure`): offers
  /// the next room or Finish.
  func showRoomDone(index: Int, room: CapturedRoom?, failure: String?) {
    processing.stopAnimating()
    controls.isHidden = true
    if let room {
      cardTitle.text = "Room \(index + 1) saved"
      func n(_ c: Int, _ w: String) -> String { "\(c) \(w)\(c == 1 ? "" : "s")" }
      var parts = [n(room.walls.count, "wall"), n(room.doors.count, "door"), n(room.windows.count, "window")]
      if !room.objects.isEmpty { parts.append(n(room.objects.count, "object")) }
      var text = parts.joined(separator: " · ")
      let heights = room.walls.map { $0.dimensions.y }.filter { $0 > 0.5 }.sorted()
      if !heights.isEmpty { text += String(format: "\nCeiling %.2f m", heights[heights.count / 2]) }
      text += "\n\nWalk into the next room to scan it too, or finish."
      cardDetail.text = text
      instructionLabel.text = "Room \(index + 1) done"
    } else {
      cardTitle.text = "Room \(index + 1) could not be saved"
      cardDetail.text = (failure ?? "") + "\n\nScan it again, or finish with the rooms already saved."
      instructionLabel.text = "Room \(index + 1) not saved"
    }
    card.isHidden = false
    UINotificationFeedbackGenerator().notificationOccurred(room == nil ? .error : .success)
  }

  /// Capturing room `index` starts; `done` are the rooms already finished
  /// (drawn faintly on the plan).
  func startRoom(index: Int, done: [CapturedRoom]) {
    card.isHidden = true
    processing.stopAnimating()
    controls.isHidden = false
    navigationItem.title = "Room \(index + 1)"
    navigationItem.rightBarButtonItem?.isEnabled = true
    instructionLabel.text = "Walk into the next room and point at its walls"
    planView.startRoom(done: done)
    wallLines.clear()
  }

  // MARK: Photo and torch

  @objc private func takePhoto() {
    guard let frame = session.arSession.currentFrame else { return }
    let t = frame.camera.transform
    let buffer = frame.capturedImage
    // The camera image is landscape (home button right); turned upright as
    // the phone is held.
    let orientation: CGImagePropertyOrientation
    switch view.window?.windowScene?.interfaceOrientation ?? .portrait {
    case .landscapeRight: orientation = .up
    case .landscapeLeft: orientation = .down
    case .portraitUpsideDown: orientation = .left
    default: orientation = .right
    }
    var dx = -t.columns.2.x, dz = -t.columns.2.z
    let l = (dx * dx + dz * dz).squareRoot()
    let hasDir = l > 0.2
    if hasDir { dx /= l; dz /= l }
    let x = t.columns.3.x, z = t.columns.3.z
    // Shutter feedback.
    flashView.alpha = 0.8
    UIView.animate(withDuration: 0.3) { self.flashView.alpha = 0 }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
      guard let cg = CIContext().createCGImage(image, from: image.extent),
            let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { return }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scan_photo_\(UUID().uuidString).jpg")
      guard (try? data.write(to: url)) != nil else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.onPhoto?(SerializablePhoto(path: url.path, x: x, z: z,
                                        dirX: hasDir ? dx : nil, dirZ: hasDir ? dz : nil, room: 0))
        self.photoCount += 1
        self.photoButton.configuration?.title = "Photo (\(self.photoCount))"
      }
    }
  }

  @objc private func toggleTorch() { setTorch(!torchOn) }

  private func setTorch(_ on: Bool) {
    // The camera ARKit is using (it can be configured while it runs).
    guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
            ?? AVCaptureDevice.default(for: .video),
          device.hasTorch else {
      instructionLabel.text = "This device has no torch"
      return
    }
    do {
      try device.lockForConfiguration()
      if on { try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) } else { device.torchMode = .off }
      device.unlockForConfiguration()
      torchOn = on
    } catch {
      instructionLabel.text = "The torch can't be switched on now"
    }
    torchButton.configuration?.image = UIImage(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
    torchButton.configuration?.baseBackgroundColor = torchOn ? Self.accent : Self.ink.withAlphaComponent(0.8)
  }
}

// MARK: - Lines on the camera image

/// The room as RoomPlan finds it, outlined in white on the camera image like
/// a room scanner's live view: each wall's four edges (floor, ceiling and the
/// corners floor to ceiling), each door, window and opening as a frame in its
/// wall, and each piece of furniture as a box. It grows as the user turns
/// round the room; walls RoomPlan is unsure of are dashed.
final class WallLinesView: UIView {
  weak var sceneView: ARSCNView?
  private struct Edge { let a: SIMD3<Float>; let b: SIMD3<Float>; let dashed: Bool; let thin: Bool }
  private var edges: [Edge] = []
  private var cam = SIMD3<Float>(0, 0, 0)
  private var forward = SIMD3<Float>(0, 0, -1)

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
    contentMode = .redraw
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// The four corners of a RoomPlan surface (a rectangle in its local x, y).
  private static func corners(_ s: CapturedRoom.Surface) -> [SIMD3<Float>] {
    let t = s.transform, hw = s.dimensions.x / 2, hh = s.dimensions.y / 2
    let local: [(Float, Float)] = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
    return local.map { xy in
      let p = t * SIMD4<Float>(xy.0, xy.1, 0, 1)
      return SIMD3<Float>(p.x, p.y, p.z)
    }
  }

  func setRoom(_ room: CapturedRoom) {
    var out: [Edge] = []
    func rect(_ c: [SIMD3<Float>], dashed: Bool = false, thin: Bool = false) {
      for k in 0..<4 { out.append(Edge(a: c[k], b: c[(k + 1) % 4], dashed: dashed, thin: thin)) }
    }
    for w in room.walls { rect(Self.corners(w), dashed: w.confidence == .low) }
    for s in room.doors + room.windows + room.openings { rect(Self.corners(s)) }
    // Furniture: a box (its local x, y, z extents).
    for o in room.objects {
      let t = o.transform, d = o.dimensions / 2
      func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        let v = t * SIMD4<Float>(x * d.x, y * d.y, z * d.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
      }
      let bottom = [p(-1, -1, -1), p(1, -1, -1), p(1, -1, 1), p(-1, -1, 1)]
      let top = [p(-1, 1, -1), p(1, 1, -1), p(1, 1, 1), p(-1, 1, 1)]
      rect(bottom, thin: true)
      rect(top, thin: true)
      for k in 0..<4 { out.append(Edge(a: bottom[k], b: top[k], dashed: false, thin: true)) }
    }
    edges = out
    setNeedsDisplay()
  }

  func clear() {
    edges = []
    setNeedsDisplay()
  }

  func setCamera(_ p: SIMD3<Float>, forward f: SIMD3<Float>) {
    cam = p
    forward = f
    if !edges.isEmpty { setNeedsDisplay() }
  }

  /// The part of a..b in front of the camera, on screen.
  private func onScreen(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ v: ARSCNView) -> (CGPoint, CGPoint)? {
    let near: Float = 0.1
    let da = simd_dot(a - cam, forward), db = simd_dot(b - cam, forward)
    if da < near && db < near { return nil }
    var a = a, b = b
    if da < near { a = a + (b - a) * ((near - da) / (db - da)) }
    if db < near { b = b + (a - b) * ((near - db) / (da - db)) }
    func p(_ q: SIMD3<Float>) -> CGPoint {
      let s = v.projectPoint(SCNVector3(q.x, q.y, q.z))
      return CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
    }
    return (p(a), p(b))
  }

  override func draw(_ rect: CGRect) {
    guard let v = sceneView, let ctx = UIGraphicsGetCurrentContext(), !edges.isEmpty else { return }
    ctx.setLineCap(.round)
    for e in edges {
      guard let (a, b) = onScreen(e.a, e.b, v) else { continue }
      ctx.saveGState()
      // A soft dark edge so the white lines show on light walls too.
      ctx.setStrokeColor(UIColor(white: 0, alpha: 0.25).cgColor)
      ctx.setLineWidth(e.thin ? 4 : 6)
      ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
      ctx.setStrokeColor(UIColor(white: 1, alpha: e.thin ? 0.85 : 1).cgColor)
      ctx.setLineWidth(e.thin ? 2 : 3.5)
      if e.dashed { ctx.setLineDash(phase: 0, lengths: [10, 8]) }
      ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
      ctx.restoreGState()
    }
  }
}

// MARK: - The plan

/// The live 2D floor plan, heading-up (the way the camera looks is up).
final class LivePlanView: UIView {
  /// Starts small: the camera view, with the room outlined in it, fills the
  /// screen; a tap on the map shows the big plan.
  var big = false { didSet { setNeedsDisplay() } }
  var onTap: (() -> Void)?

  private struct Seg { let a: SIMD3<Float>; let b: SIMD3<Float> }
  private struct Box { let corners: [SIMD3<Float>]; let label: String }

  private var walls: [(seg: Seg, sure: Bool)] = []
  private var doors: [Seg] = []
  private var windows: [Seg] = []
  private var openings: [Seg] = []
  private var objects: [Box] = []
  private var floor: [SIMD3<Float>] = []
  private var cam: SIMD3<Float>?
  private var forward = SIMD3<Float>(0, 0, -1)
  private var tracking = false
  private var sectors = [Bool](repeating: false, count: 12)
  var sectorsSeen: Int { sectors.filter { $0 }.count }
  /// Walls of the rooms finished earlier in this session (drawn faintly).
  private var doneWalls: [Seg] = []

  /// The next room starts: what was scanned so far becomes the faint
  /// background, and the directions looked in start again.
  func startRoom(done: [CapturedRoom]) {
    doneWalls = done.flatMap { $0.walls.map(Self.seg) }
    walls = []
    doors = []
    windows = []
    openings = []
    objects = []
    floor = []
    sectors = [Bool](repeating: false, count: 12)
    setNeedsDisplay()
  }

  private static let ink = UIColor(red: 11 / 255, green: 20 / 255, blue: 38 / 255, alpha: 1)
  private static let teal = UIColor(red: 18 / 255, green: 194 / 255, blue: 164 / 255, alpha: 1)
  private static let amber = UIColor(red: 224 / 255, green: 138 / 255, blue: 11 / 255, alpha: 1)
  private static let blue = UIColor(red: 14 / 255, green: 165 / 255, blue: 233 / 255, alpha: 1)
  private static let accent = UIColor(red: 47 / 255, green: 91 / 255, blue: 1, alpha: 1)

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  @objc private func tapped() { onTap?() }

  func setCamera(_ p: SIMD3<Float>, forward f: SIMD3<Float>, tracking t: Bool) {
    cam = p
    forward = f
    tracking = t
    // Which way the phone has looked (12 sectors of atan2(z, x)), so the
    // gaps show where to turn next.
    if t && abs(f.y) < 0.85 {
      let a = atan2(f.z, f.x) + Float.pi
      let i = min(max(Int(a / (2 * Float.pi) * 12), 0), 11)
      sectors[i] = true
    }
    setNeedsDisplay()
  }

  private static func seg(_ s: CapturedRoom.Surface) -> Seg {
    let t = s.transform
    let c = SIMD3<Float>(t.columns.3.x, 0, t.columns.3.z)
    var ax = SIMD3<Float>(t.columns.0.x, 0, t.columns.0.z)
    let l = simd_length(ax)
    ax = l > 1e-4 ? ax / l : SIMD3<Float>(1, 0, 0)
    let h = s.dimensions.x / 2
    return Seg(a: c - ax * h, b: c + ax * h)
  }

  func setRoom(_ room: CapturedRoom) {
    walls = room.walls.map { (seg: Self.seg($0), sure: $0.confidence != .low) }
    doors = room.doors.map(Self.seg)
    windows = room.windows.map(Self.seg)
    openings = room.openings.map(Self.seg)
    objects = room.objects.map { o in
      let t = o.transform
      let c = SIMD3<Float>(t.columns.3.x, 0, t.columns.3.z)
      let ux = SIMD3<Float>(t.columns.0.x, 0, t.columns.0.z) * (o.dimensions.x / 2)
      let uz = SIMD3<Float>(t.columns.2.x, 0, t.columns.2.z) * (o.dimensions.z / 2)
      return Box(corners: [c - ux - uz, c + ux - uz, c + ux + uz, c - ux + uz], label: Self.name(o.category))
    }
    if let f = room.floors.first {
      floor = f.polygonCorners.map { p in
        let w = f.transform * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(w.x, 0, w.z)
      }
    }
    setNeedsDisplay()
  }

  private static func name(_ c: CapturedRoom.Object.Category) -> String {
    switch c {
    case .storage: return "Storage"
    case .refrigerator: return "Fridge"
    case .stove: return "Stove"
    case .bed: return "Bed"
    case .sink: return "Sink"
    case .washerDryer: return "Washer"
    case .toilet: return "Toilet"
    case .bathtub: return "Bath"
    case .oven: return "Oven"
    case .dishwasher: return "Dishwasher"
    case .table: return "Table"
    case .sofa: return "Sofa"
    case .chair: return "Chair"
    case .fireplace: return "Fireplace"
    case .television: return "TV"
    case .stairs: return "Stairs"
    @unknown default: return "Object"
    }
  }

  // Heading-up transform (as LivePlan.fit in the app).
  private struct Fit {
    let cx: Float, cz: Float, fx: Float, fz: Float, scale: CGFloat, px: CGFloat, py: CGFloat
    func p(_ x: Float, _ z: Float) -> CGPoint {
      let dx = x - cx, dz = z - cz
      return CGPoint(x: px + CGFloat(dx * -fz + dz * fx) * scale, y: py - CGFloat(dx * fx + dz * fz) * scale)
    }
    func p(_ v: SIMD3<Float>) -> CGPoint { p(v.x, v.z) }
  }

  private func fit(_ pts: [SIMD3<Float>], in rect: CGRect, pad: CGFloat) -> Fit {
    let all = pts + (cam.map { [$0] } ?? [])
    guard !all.isEmpty else {
      return Fit(cx: 0, cz: 0, fx: 0, fz: -1, scale: 40, px: rect.midX, py: rect.midY)
    }
    let minX = all.map { $0.x }.min()!, maxX = all.map { $0.x }.max()!
    let minZ = all.map { $0.z }.min()!, maxZ = all.map { $0.z }.max()!
    let cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2
    var r: Float = 1.5
    for p in all { r = max(r, ((p.x - cx) * (p.x - cx) + (p.z - cz) * (p.z - cz)).squareRoot()) }
    let half = max(1, min(rect.width, rect.height) / 2 - pad)
    var fx = forward.x, fz = forward.z
    let l = (fx * fx + fz * fz).squareRoot()
    if l < 1e-3 { fx = 0; fz = -1 } else { fx /= l; fz /= l }
    return Fit(cx: cx, cz: cz, fx: fx, fz: fz, scale: half / CGFloat(r), px: rect.midX, py: rect.midY)
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    let card = UIBezierPath(roundedRect: bounds, cornerRadius: big ? 20 : 16)
    Self.ink.withAlphaComponent(big ? 0.94 : 0.8).setFill()
    card.fill()
    UIColor(white: 1, alpha: 0.14).setStroke()
    card.lineWidth = 1
    card.stroke()
    ctx.saveGState()
    ctx.addPath(card.cgPath)
    ctx.clip()

    let header: CGFloat = big ? 52 : 0
    let body = CGRect(x: 0, y: header, width: bounds.width, height: bounds.height - header)
    var pts = [SIMD3<Float>]()
    for w in walls { pts += [w.seg.a, w.seg.b] }
    for w in doneWalls { pts += [w.a, w.b] }
    for o in objects { pts += o.corners }
    let t = fit(pts, in: body, pad: big ? 26 : 12)
    let lineScale: CGFloat = big ? 1 : 0.5

    if big {
      // 1 m grid, turning with the plan.
      let reach = Int(max(bounds.width, bounds.height) / t.scale) + 2
      let gx0 = Int(t.cx.rounded(.down)), gz0 = Int(t.cz.rounded(.down))
      ctx.setStrokeColor(UIColor(white: 1, alpha: 0.09).cgColor)
      ctx.setLineWidth(1)
      for k in -reach...reach {
        let gx = Float(gx0 + k), gz = Float(gz0 + k)
        ctx.move(to: t.p(gx, Float(gz0 - reach))); ctx.addLine(to: t.p(gx, Float(gz0 + reach)))
        ctx.move(to: t.p(Float(gx0 - reach), gz)); ctx.addLine(to: t.p(Float(gx0 + reach), gz))
      }
      ctx.strokePath()
    }

    // Rooms finished earlier in this session.
    if !doneWalls.isEmpty {
      ctx.saveGState()
      ctx.setStrokeColor(UIColor(white: 1, alpha: 0.35).cgColor)
      ctx.setLineWidth(4 * lineScale)
      ctx.setLineCap(.square)
      for w in doneWalls {
        ctx.move(to: t.p(w.a))
        ctx.addLine(to: t.p(w.b))
      }
      ctx.strokePath()
      ctx.restoreGState()
    }

    // Floor.
    if floor.count >= 3 {
      ctx.addLines(between: floor.map { t.p($0) })
      ctx.closePath()
      ctx.setFillColor(UIColor(white: 1, alpha: 0.1).cgColor)
      ctx.fillPath()
    }

    // Furniture and fixtures: their footprint, with a name when big.
    for o in objects {
      ctx.addLines(between: o.corners.map { t.p($0) })
      ctx.closePath()
      ctx.setFillColor(UIColor(white: 1, alpha: 0.12).cgColor)
      ctx.setStrokeColor(UIColor(white: 1, alpha: 0.45).cgColor)
      ctx.setLineWidth(1)
      ctx.drawPath(using: .fillStroke)
    }

    // Walls: solid white; still uncertain ones amber and dashed.
    for w in walls {
      ctx.saveGState()
      ctx.move(to: t.p(w.seg.a))
      ctx.addLine(to: t.p(w.seg.b))
      if w.sure {
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(6 * lineScale)
        ctx.setLineCap(.square)
      } else {
        ctx.setStrokeColor(Self.amber.cgColor)
        ctx.setLineWidth(3 * lineScale)
        ctx.setLineDash(phase: 0, lengths: [7, 5])
      }
      ctx.strokePath()
      ctx.restoreGState()
    }

    // Doors, windows and openings: the wall cut open, then their symbol.
    var mx: Float = 0, mz: Float = 0
    for w in walls { mx += w.seg.a.x + w.seg.b.x; mz += w.seg.a.z + w.seg.b.z }
    let inside = walls.isEmpty ? (cam ?? .zero) : SIMD3<Float>(mx / Float(2 * walls.count), 0, mz / Float(2 * walls.count))
    func cut(_ s: Seg) {
      ctx.saveGState()
      ctx.setStrokeColor(Self.ink.cgColor)
      ctx.setLineWidth(8 * lineScale)
      ctx.move(to: t.p(s.a))
      ctx.addLine(to: t.p(s.b))
      ctx.strokePath()
      ctx.restoreGState()
    }
    for s in openings { cut(s) }
    for s in doors {
      cut(s)
      let swing = Self.doorSwing(s.a, s.b, inside: inside)
      ctx.saveGState()
      ctx.setStrokeColor(Self.amber.cgColor)
      ctx.setLineWidth(2 * lineScale)
      ctx.move(to: t.p(s.a))
      ctx.addLine(to: t.p(swing.leaf))
      ctx.strokePath()
      ctx.setLineDash(phase: 0, lengths: [3, 3])
      ctx.addLines(between: swing.arc.map { t.p($0) })
      ctx.strokePath()
      ctx.restoreGState()
    }
    for s in windows {
      cut(s)
      let a = t.p(s.a), b = t.p(s.b)
      let l = hypot(b.x - a.x, b.y - a.y)
      if l < 1 { continue }
      let off = 3.5 * lineScale
      let nx = -(b.y - a.y) / l * off, ny = (b.x - a.x) / l * off
      ctx.saveGState()
      ctx.setStrokeColor(Self.blue.cgColor)
      ctx.setLineWidth(2 * lineScale)
      ctx.addLines(between: [CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny),
                             CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)])
      ctx.closePath()
      ctx.move(to: a)
      ctx.addLine(to: b)
      ctx.strokePath()
      ctx.restoreGState()
    }

    if big {
      // Wall lengths, outside the room; object names.
      let ic = t.p(inside)
      let small: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.white,
      ]
      for w in walls {
        let a = t.p(w.seg.a), b = t.p(w.seg.b)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = mid.x - ic.x, dy = mid.y - ic.y
        let d = max(1, hypot(dx, dy))
        let text = String(format: "%.2f m", simd_distance(w.seg.a, w.seg.b)) as NSString
        let sz = text.size(withAttributes: small)
        let c = CGPoint(x: mid.x + dx / d * 16, y: mid.y + dy / d * 16)
        let pill = UIBezierPath(roundedRect: CGRect(x: c.x - sz.width / 2 - 7, y: c.y - 10,
                                                    width: sz.width + 14, height: 20), cornerRadius: 10)
        (w.sure ? UIColor(red: 30 / 255, green: 41 / 255, blue: 59 / 255, alpha: 0.9)
          : UIColor(red: 176 / 255, green: 104 / 255, blue: 6 / 255, alpha: 0.92)).setFill()
        pill.fill()
        text.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: small)
      }
      let objFont: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor(white: 1, alpha: 0.75),
      ]
      for o in objects {
        let ps = o.corners.map { t.p($0) }
        let c = CGPoint(x: ps.map { $0.x }.reduce(0, +) / 4, y: ps.map { $0.y }.reduce(0, +) / 4)
        let s = o.label as NSString
        let sz = s.size(withAttributes: objFont)
        s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: objFont)
      }
    }

    // The phone: field of view (always up), directions looked at, a dot.
    if let cam, tracking {
      let c = t.p(cam)
      if big {
        let reach: CGFloat = 70, half = reach * 0.58
        ctx.saveGState()
        ctx.addLines(between: [c, CGPoint(x: c.x - half, y: c.y - reach), CGPoint(x: c.x + half, y: c.y - reach)])
        ctx.closePath()
        ctx.clip()
        let colors = [Self.accent.withAlphaComponent(0.45).cgColor, Self.accent.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
          ctx.drawLinearGradient(g, start: c, end: CGPoint(x: c.x, y: c.y - reach), options: [])
        }
        ctx.restoreGState()
        let step = 2 * CGFloat.pi / 12
        ctx.saveGState()
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        for i in 0..<12 {
          let a = Float(-Double.pi + (Double(i) + 0.5) * Double(step))
          let w = t.p(cam.x + cos(a), cam.z + sin(a))
          let ang = atan2(w.y - c.y, w.x - c.x)
          ctx.addArc(center: c, radius: 22, startAngle: ang - step / 2 + 0.05, endAngle: ang + step / 2 - 0.05,
                     clockwise: false)
          ctx.setStrokeColor((sectors[i] ? Self.teal : UIColor(white: 1, alpha: 0.24)).cgColor)
          ctx.strokePath()
        }
        ctx.restoreGState()
      }
      let r: CGFloat = big ? 8 : 5
      ctx.setFillColor(UIColor.white.cgColor)
      ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
      ctx.setFillColor(Self.accent.cgColor)
      ctx.fillEllipse(in: CGRect(x: c.x - r * 0.7, y: c.y - r * 0.7, width: 1.4 * r, height: 1.4 * r))
    }
    ctx.restoreGState()

    if big {
      var title = walls.isEmpty ? "Point at the walls to start the plan"
        : "\(walls.count) wall\(walls.count == 1 ? "" : "s")"
      if floor.count >= 3 { title += String(format: "  ·  %.2f m²", Self.area(floor)) }
      (title as NSString).draw(at: CGPoint(x: 16, y: 10), withAttributes: [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.white,
      ])
      func n(_ c: Int, _ w: String) -> String { "\(c) \(w)\(c == 1 ? "" : "s")" }
      var parts = [n(doors.count, "door"), n(windows.count, "window")]
      if !openings.isEmpty { parts.append(n(openings.count, "opening")) }
      if !objects.isEmpty { parts.append(n(objects.count, "object")) }
      // The scan only finishes by itself once the user has turned to every
      // wall (10 of 12 directions, as LidarCompletion.lookRoundSectors).
      let around = sectorsSeen >= 10 ? "tap for camera"
        : "turn round: \(Int((Double(sectorsSeen) / 12 * 20).rounded()) * 5)%"
      let sub = parts.joined(separator: " · ") + "  ·  " + around
      (sub as NSString).draw(at: CGPoint(x: 16, y: 30), withAttributes: [
        .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor(white: 1, alpha: 0.67),
      ])
    }
  }

  /// As LivePlan.doorSwing in the app.
  private static func doorSwing(_ a: SIMD3<Float>, _ b: SIMD3<Float>, inside: SIMD3<Float>)
    -> (leaf: SIMD3<Float>, arc: [SIMD3<Float>]) {
    let wx = b.x - a.x, wz = b.z - a.z
    let w = (wx * wx + wz * wz).squareRoot()
    if w < 1e-4 { return (a, [a]) }
    var nx = -wz / w, nz = wx / w
    if (inside.x - a.x) * nx + (inside.z - a.z) * nz < 0 { nx = -nx; nz = -nz }
    let ux = wx / w, uz = wz / w
    let arc = (0...12).map { i -> SIMD3<Float> in
      let t = Float.pi / 2 * Float(i) / 12
      return SIMD3<Float>(a.x + (nx * cos(t) + ux * sin(t)) * w, 0, a.z + (nz * cos(t) + uz * sin(t)) * w)
    }
    return (SIMD3<Float>(a.x + nx * w, 0, a.z + nz * w), arc)
  }

  private static func area(_ c: [SIMD3<Float>]) -> Float {
    var s: Float = 0
    for i in c.indices {
      let p = c[i], q = c[(i + 1) % c.count]
      s += p.x * q.z - q.x * p.z
    }
    return abs(s) / 2
  }
}

/// A label with padding around its text.
final class PaddedLabel: UILabel {
  var insets = UIEdgeInsets.zero

  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

  override var intrinsicContentSize: CGSize {
    let s = super.intrinsicContentSize
    return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
  }
}
