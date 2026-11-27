import ARKit
import AVFoundation
import CoreText
import Flutter
import UIKit
import os

private let scanLog = Logger(subsystem: "com.nativesoftware.roomMeasure", category: "RoomMeasureAR")

/// Flutter side of the guided camera scanner, on the same channel as Android
/// ('room_measure/ar'):
///  - isSupported: whether ARKit world tracking works on this device.
///  - measure: opens the scanner. With arguments {"startMode": "line"} it
///    opens as a plain distance measurer (Line mode, no room outline needed).
///    Returns nil when the user backs out, {error} on failure, or {xs, zs,
///    openings, auto, estimated, floorY?, openingDetails, surfaces,
///    lines, lineOnly, focusOpening?}.
///    xs and zs are empty (auto false, estimated 0) when the scan finished
///    with doors / windows but no room outline.
///    focusOpening: index (in "openings" / "openingDetails" order) of the
///    door / window whose ✓ finished the scan; absent otherwise.
///    openingDetails: 8 values per door/window: type (0 door, 1 window),
///    ax, ay, az, bx, by, bz, topY (-999 when no top was marked).
///    surfaces: 9 values per surface: Ax, Ay, Az, Bx, By, Bz, Cx, Cy, Cz.
///    lines: 6 values per measured line: ax, ay, az, bx, by, bz.
///    lineOnly: the scanner was opened with startMode "line"; xs and zs are
///    then empty.
///    openingMethods: per door/window (in "openings" order) how it was
///    measured: 0 aimed at by hand (Manual), 1 found automatically (Auto),
///    2 touched with the phone (Touch).
///    openingEstimated: 0/1 per door/window: its wall plane or its bottom
///    was assumed, so its size is approximate.
///    diagFile: name of the scan's diagnostics file in
///    Documents/room_measure/diag (see writeDiag).
final class ArMeasurePlugin: NSObject, FlutterPlugin {
  private var pending: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "room_measure/ar", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ArMeasurePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(ARWorldTrackingConfiguration.isSupported)
    case "measure":
      if pending != nil {
        result(FlutterError(code: "busy", message: "Measuring is already open", details: nil))
        return
      }
      guard let top = Self.topViewController() else {
        result(FlutterError(code: "no_view", message: "Could not open the camera scanner", details: nil))
        return
      }
      pending = result
      let args = call.arguments as? [String: Any]
      let lineOnly = (args?["startMode"] as? String) == "line"
      let vc = ArMeasureViewController(lineOnly: lineOnly) { [weak self] out in
        self?.pending?(out)
        self?.pending = nil
      }
      top.present(vc, animated: true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var vc = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}

/// Camera room scanner (ARKit), the iOS twin of ArMeasureActivity.kt.
///
/// ARKit's detected planes are classified into floor, walls and ceiling and
/// drawn over the camera image. In Auto mode the room outline is found from
/// the walls and tracked feature points (RoomDetector); doors and windows
/// in view are counted along the way. Corners / Door / Window / Surface /
/// Line modes let the user mark points with the crosshair. No room height is
/// measured or returned (the ceiling only helps tell walls from furniture).
final class ArMeasureViewController: UIViewController, ARSessionDelegate {

  private enum Mode: Int, CaseIterable {
    case auto, corner, door, window, surface, line
    var label: String { ["Auto", "Corners", "Door", "Window", "Surface", "Line"][rawValue] }
  }

  private enum SurfaceKind { case floor, wall, ceiling, other }

  private struct PlaneOutline {
    let kind: SurfaceKind
    let points: [V3]
  }

  private struct OpeningMark {
    let type: Int
    /// The two base points as tapped (full 3D; doors are only drawn on the
    /// floor, the points themselves are kept as measured).
    let a: V3
    let b: V3
    /// Height of the tapped top of the frame; nil when the opening was
    /// committed before its top was marked.
    let topY: Float?
    /// How it was measured, as in the result's "openingMethods": 0 Manual,
    /// 1 Auto, 2 Touch.
    var method = 0
    /// The wall plane (Auto) or the floor (a touched door) was assumed.
    var estimated = false
  }

  /// A flat rectangle from three taps: corner A, the next corner B along one
  /// edge, and any point C on the opposite edge.
  private struct SurfaceMark {
    let a: V3
    let b: V3
    let c: V3

    var width: Float { simd_length(b - a) }
    /// Offset from edge AB to the opposite edge: the part of C - A
    /// perpendicular to AB.
    var offset: V3 { SurfaceMark.perpendicular(a, b, c) }
    var height: Float { simd_length(offset) }

    static func perpendicular(_ a: V3, _ b: V3, _ c: V3) -> V3 {
      let ab = b - a
      let len2 = simd_length_squared(ab)
      let ac = c - a
      if len2 < 1e-8 { return ac }
      return ac - ab * (simd_dot(ac, ab) / len2)
    }
  }

  /// A straight line between two tapped points (any surfaces).
  private struct LineMark {
    let a: V3
    let b: V3
    /// The end was placed on an estimated surface (see pick), not on
    /// something measured. Never set for the Touch method.
    var aEstimated = false
    var bEstimated = false

    var length: Float { simd_length(b - a) }
    /// Either end is estimated, so the length is approximate.
    var estimated: Bool { aEstimated || bEstimated }
  }

  /// The marker under a finger held on the camera view (Line mode, Aim).
  private struct TapPreview {
    let at: CGPoint
    /// What the finger points at; nil when no depth can be told there.
    let pick: (point: V3, estimated: Bool)?
  }

  /// Latest camera state, used for drawing and marking.
  private struct Snapshot {
    let tracking: Bool
    let trackingHint: String
    let viewProj: simd_float4x4
    let hit: V3?
    /// The hit is on a detected wall's plane extended beyond its detected
    /// area (the last resort on a plain wall), not on something measured.
    let hitEstimated: Bool
    /// Where the phone (its camera) is.
    let camPos: V3
    /// Which way the phone is turned (the camera's forward and up axes).
    let camForward: V3
    let camUp: V3
    let planes: [PlaneOutline]
    let floorY: Float?
    let ceilingY: Float?
    let wallCount: Int
    let cornerCandidates: [V3]
    let autoRoom: AutoRoom?
    /// Feature points tracked in this frame, drawn as scan feedback.
    let framePoints: [V3]
  }

  /// What a tap on the mark button would do right now.
  private struct Aim {
    let p: V3
    let snappedCorner: Bool
    let closesRoom: Bool
    /// On an extended wall plane (see Snapshot.hitEstimated).
    var estimated = false
  }

  /// How the two ends of a line are given: by aiming the crosshair at them,
  /// or by holding the phone itself on them (its own position is always
  /// known, so no surface has to be found: works on a plain wall).
  private enum LineMethod: Int {
    case aim, touch
  }

  /// How a door or window is measured. New ones are always found in the
  /// camera image (Auto); Manual and Touch remain only as result codes.
  private enum OpeningMethod: Int {
    case auto, manual, touch
    /// The value in the result's "openingMethods".
    var code: Int { [1, 0, 2][rawValue] }
  }

  /// One automatic detection kept for the consensus, in world terms (the
  /// wall coordinates move with the crosshair).
  private struct AutoSample {
    let a: V3
    let b: V3
    let bottom: Float
    let top: Float
    /// The wall plane it was found on.
    let origin: V3
    let normal: V3
    let estimated: Bool
    let time: Date
    var centre: V3 { ((a + b) / 2).withY((bottom + top) / 2) }
  }

  /// What the recent detections agree on (per-edge medians).
  private struct AutoOpening {
    let a: V3
    let b: V3
    let bottom: Float
    let top: Float
    let estimated: Bool
    /// Enough recent detections agree: it can be added.
    let stable: Bool
  }

  /// The last detection attempt's input and output, for the diagnostics
  /// files (opening_<ms>.png / .json).
  private struct OpeningShot {
    let image: RectifiedImage
    let analysis: OpeningAnalysis
    let wall: WallFrame
    let source: String
    let kind: OpeningKind
  }

  /// A detected surface as written to the diagnostics file.
  private struct DiagPlane {
    let vertical: Bool
    let classification: String
    let y: Float
    let width: Float
    let height: Float
    let points: [V3]
  }

  /// Everything a diagnostics file holds, captured on the main queue so the
  /// encoding can run in the background.
  private struct DiagCapture {
    let device: String
    let started: Date
    let frames: Int
    let mode: String
    let tracking: Bool
    let floorY: Float?
    let pointFloorY: Float?
    let ceilingY: Float?
    let floorUsed: Float?
    let floorGuessed: Bool
    let camMean: V3?
    let camNow: V3?
    let camPath: [Float]
    let sectors: [Bool]
    let moveExtent: Float
    let walls: [WallSegment]
    let floorPts: [V3]
    let planes: [DiagPlane]
    let cloud: [V3]
    let room: AutoRoom?
    let stableFor: TimeInterval?
    let completion: String
    /// Both ends of every measured line: a0, b0, a1, b1, ...
    let lines: [V3]
    /// Per line: an end was placed on an estimated surface.
    let linesEstimated: [Bool]
    let log: [String]
  }

  private let completion: ([String: Any]?) -> Void
  private var completed = false

  /// Opened only to measure distances: starts in Line mode, never finishes
  /// on its own and needs no room outline.
  private let lineOnly: Bool

  init(lineOnly: Bool = false, completion: @escaping ([String: Any]?) -> Void) {
    self.lineOnly = lineOnly
    self.mode = lineOnly ? .line : .auto
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // ------------------------------------------------------------ AR state

  private let sceneView = ARSCNView()
  private let overlay = OverlayView()
  /// Takes the taps on the camera view in Line mode (Aim); sits above the
  /// overlay and below the panels.
  private let tapView = TapView()
  /// The cards over the camera view; a touch on them is not a tap on the
  /// scene.
  private var topStack: UIView?
  private var bottomPanel: UIView?
  private var sessionStarted = false
  private var planeFloorY: Float?
  /// Floor height found from feature points when ARKit finds no floor plane.
  private var pointFloorY: Float?
  private var ceilingY: Float?
  private var autoRoom: AutoRoom?
  private var frameCount = 0
  /// Feature points seen so far, by ARKit point id.
  private var cloud = [UInt64: V3]()
  // Mean camera position on the floor plan: a point inside the room.
  private var camSumX = 0.0
  private var camSumY = 0.0
  private var camSumZ = 0.0
  private var camSamples = 0
  private let detector = DispatchQueue(label: "room_measure.detector", qos: .userInitiated)
  private var detecting = false
  /// Bumped by "Start over", so a room still being computed for the old scan
  /// is thrown away.
  private var scanGeneration = 0
  private var snapshot: Snapshot?
  private var lastTracking: Bool?
  private var lastScanLog = ""

  // ------------------------------------------------------------ how the user scanned

  /// Directions the camera has looked in while tracking, as 12 sectors of
  /// 30 degrees around the vertical axis. A phone without a depth sensor
  /// only measures what it has looked at, so this is the scan's progress.
  private var sectors = [Bool](repeating: false, count: ArMeasureViewController.sectorCount)
  /// Box around every camera position so far. Distance is measured from
  /// sideways movement (parallax): turning on the spot leaves this box tiny
  /// and yields almost no usable points.
  private var camMinX = Float.greatestFiniteMagnitude
  private var camMaxX = -Float.greatestFiniteMagnitude
  private var camMinZ = Float.greatestFiniteMagnitude
  private var camMaxZ = -Float.greatestFiniteMagnitude
  /// The camera's path on the floor plan (x0, z0, x1, z1, ...), sampled twice
  /// a second, for the diagnostics file.
  private var camPath = [Float]()
  private var lastPathSample: TimeInterval = -1
  /// Camera position and viewing direction of the last tracked frame.
  private var camNow: V3?
  private var camDir = V3(0, 0, -1)
  /// Room scan (Auto mode): the live 2D floor plan fills the lower part of
  /// the screen and the walls, doors and windows found are drawn on it
  /// instead of over the camera image. Tapping the plan switches to the
  /// camera overlay with the small mini-map, and back.
  // The camera view, with the walls outlined in it, fills the screen, and
  // the plan is a small map; tap the map for the big plan.
  private var planBig = false
  private var livePlanShown: Bool { (mode == .auto || mode == .corner) && !lineOnly && planBig }
  /// Where the plan / the small map was last drawn (overlay coordinates).
  private var planRect = CGRect.null
  private var miniRect = CGRect.null

  private var sectorsCovered: Int { sectors.filter { $0 }.count }
  /// Diagonal of the box the camera has moved in, in metres.
  private var moveExtent: Float {
    if camMaxX < camMinX { return 0 }
    let dx = camMaxX - camMinX
    let dz = camMaxZ - camMinZ
    return (dx * dx + dz * dz).squareRoot()
  }
  /// Share of the full turn looked at, in percent rounded to 5.
  private var coveragePercent: Int {
    Int((Double(sectorsCovered) / Double(Self.sectorCount) * 20).rounded()) * 5
  }

  // ------------------------------------------------------------ diagnostics

  /// One JSON file per scan (Documents/room_measure/diag/scan_<start>.json)
  /// with everything the detector was given, so a scan that went wrong on a
  /// real phone can be replayed offline.
  private var scanStarted = Date()
  private var diagLines = [String]()
  private var lastDiagWrite = Date.distantPast
  /// A diagnostics file is being encoded; the next one waits for it.
  private var diagWriting = false
  private var diagWriteFailed = false
  private let diagQueue = DispatchQueue(label: "room_measure.diag", qos: .utility)
  /// What the last detection was handed.
  private var lastWalls = [WallSegment]()
  private var lastFloorPts = [V3]()
  private var lastCloud = [V3]()
  private var lastPlanes = [DiagPlane]()
  private var lastFloorUsed: Float?
  private var lastFloorGuessed = false
  /// How the scan ended: "none", the auto-completion rule "a" / "b" / "c",
  /// "cancelled" (a mode switch, Undo, Start over, Close or lost tracking
  /// stopped it) or "manual" (Finish tapped, or ✓ added a door / window).
  private var completionKind = "none"

  // ------------------------------------------------------------ marking state

  private var mode = Mode.auto
  /// The room outline comes from corners marked by hand (Corners mode was
  /// chosen) instead of the automatic outline.
  private var manualOutline = false
  private var corners = [V3]()
  private var openings = [OpeningMark]()
  private var surfaces = [SurfaceMark]()
  private var lines = [LineMark]()
  private var lineMethod = LineMethod.aim
  /// Doors and windows are always found automatically (there is no
  /// Manual / Touch choice any more).
  private let openingMethod = OpeningMethod.auto
  private var openingMode: Bool { mode == .door || mode == .window }
  /// Door / Window mode: the frame is found in the camera image.
  private var openingAuto: Bool { openingMode && openingMethod == .auto }
  /// Line mode with the Touch method: the phone's position is marked.
  private var touching: Bool { mode == .line && lineMethod == .touch }

  // ------------------------------------------------------------ automatic doors and windows

  /// Detection runs here, at most one attempt at a time (see
  /// maybeDetectOpening).
  private let openingQueue = DispatchQueue(label: "room_measure.opening", qos: .userInitiated)

  /// AI furniture detection runs here (its model is made, and used, only on
  /// this queue); what it finds goes into `furniture` on the main thread.
  private let furnitureQueue = DispatchQueue(label: "room_measure.furniture", qos: .utility)
  private var furnitureModel: FurnitureModel?
  private var furnitureModelFailed = false
  private var furnitureBusy = false
  private var lastFurnitureAttempt: CFTimeInterval = 0
  private let furniture = FurnitureTracker()
  private var openingBusy = false
  private var lastOpeningAttempt: CFTimeInterval = 0
  /// Bumped whenever an attempt in flight must be thrown away (mode or
  /// method switch, Start over, an opening just added).
  private var openingGen = 0
  /// Recent detections on the wall pointed at (newest last, at most 8).
  private var autoSamples = [AutoSample]()
  private var autoOpening: AutoOpening?
  /// No wall plane could be found for the last attempt.
  private var autoWallMissing = false
  /// When the floor-line wall correction was last logged.
  private var lastFloorLineDiag: CFTimeInterval = 0
  /// Since when nothing has been found (searching started, or the last
  /// detection), for the "can't find the frame" advice.
  private var autoNothingSince = Date()
  /// Just added: detections around it are ignored for a moment, so the same
  /// door is not offered again straight away.
  private var autoSuppress: (centre: V3, until: Date)?
  /// The last stable result and when it was stable. The estimated wall can
  /// drop out for a frame, and a tap a moment after the frame turned green
  /// must still add it.
  private var lastStableOpening: (opening: AutoOpening, at: Date)?

  /// The door / window found, adjusted by hand on the camera view. Its
  /// wall is the vertical plane through the bottom corners it was found
  /// with; left / right run along it (m from `origin`). Once the user drags
  /// one of its circles or lines it no longer follows new detections; ✓
  /// adds it as adjusted, Undo goes back to automatic.
  private struct AdjustedOpening {
    let origin: V3
    /// Horizontal unit vector along the wall (bottom-left to bottom-right).
    let along: V3
    var left: Float
    var right: Float
    var bottom: Float
    var top: Float
    let estimated: Bool

    var opening: AutoOpening {
      let a = (origin + along * left).withY(bottom)
      let b = (origin + along * right).withY(bottom)
      return AutoOpening(a: a, b: b, bottom: bottom, top: top, estimated: estimated, stable: true)
    }
  }

  private var adjusted: AdjustedOpening?
  /// The side the finger holds (OpeningFrameAdjust: 0 bottom, 1 right,
  /// 2 top, 3 left); -1 none. Only that side moves.
  private var adjustGrab = -1
  /// Where the held side was relative to the finger when grabbed (m along
  /// the wall, or height), so it follows the finger without jumping.
  private var adjustOffset: Float = 0

  /// Room scan (Auto mode): doors and windows are looked for on whatever
  /// wall is in view while the room is measured (both kinds in each image),
  /// and counted once a detection holds steady.
  private var roomOpeningScan: Bool { mode == .auto && !lineOnly && !completing && !completed }
  /// Room scan: recent detections per kind (typeDoor / typeWindow), kept
  /// apart from the Door / Window mode's own search.
  private var roomSamples = [Int: [AutoSample]]()

  /// Steadies the crosshair's point over the last few frames.
  private var aimSmoother = AimSmoother()

  /// The frame drawn on the camera view: the hand-adjusted one, else the
  /// detection.
  private var shownOpening: AutoOpening? { adjusted?.opening ?? autoOpening }
  private var lastOpeningShot: OpeningShot?
  private var lastOpeningDiagWrite = Date.distantPast
  /// Tracking has been normal since the last Start over.
  private var everTracked = false
  /// Points of the door, window, surface or line being marked in the current
  /// mode (at most 2, for a line 1; the next tap completes it). Each has its
  /// own history entry on top of `history`, hEdge then hBase.
  private var pending = [V3]()
  /// The pending first point of a line was placed on an estimated surface.
  /// Only meaningful in Line mode while `pending` holds that point.
  private var lineStartEstimated = false
  /// A finger is down on the camera view in Line mode (Aim): where, and
  /// what it points at.
  private var tapPreview: TapPreview?
  /// When the finger's pick was last computed, to limit it to ~30 a second.
  private var lastTapPick: CFTimeInterval = 0
  /// A tap where no depth could be told: a red ring stays there briefly.
  private var failedTap: (at: CGPoint, until: Date)?
  private var history = [Int]()
  private var flashMessage: String?
  private var flashUntil = Date.distantPast
  /// Annotated room photos (absolute JPEG paths in the temporary directory).
  /// Not part of Undo.
  private var photos = [String]()

  // ------------------------------------------------------------ auto-completion state

  /// Auto mode finishes on its own once the outline has stopped changing
  /// (see autoCompleteKind), so the user does not have to notice the scan is
  /// done. Since when the outline has stayed the same (nil until a room
  /// arrives).
  private var stableSince: Date?
  /// Size of the outline when the clock last restarted. Later outlines are
  /// compared with these, not with the previous one, so a slow drift still
  /// restarts the clock.
  private var stableWidth: Float = 0
  private var stableDepth: Float = 0
  private var stableArea: Float = 0
  private var stableCorners = 0
  /// The current autoRoom was computed from an assumed phone height, not a
  /// detected floor; it has no height.
  private var autoRoomGuessedFloor = false
  /// The completion card is showing (feedback only, not tappable) and the
  /// scan finishes shortly.
  private var completing = false
  /// Corners mode was chosen since the last Start over; only the pure Auto
  /// flow finishes on its own.
  private var usedCorners = false
  private var completionCard: UIView?
  private var completionWork: DispatchWorkItem?
  /// Index (in `openings` order) of the door / window just added with ✓,
  /// which finishes the scan; reported as "focusOpening".
  private var focusOpening: Int?

  // ------------------------------------------------------------ views

  private let statusLabel = PaddedLabel()
  private let hintLabel = PaddedLabel()
  private let statsLabel = UILabel()
  private var tabButtons = [Mode: UIButton]()
  private let tabScroll = TabScrollView()
  private let methodControl = UISegmentedControl(items: ["Aim", "Touch"])
  /// The mark button's glyph: "+" to mark a point, "✓" to add a door or
  /// window found automatically.
  private let markGlyph = UILabel()
  private var undoColumn: UIView!
  private var undoButton: UIButton!
  private var doneColumn: UIView!
  private var doneButton: UIButton!
  private let markButton = UIButton(type: .custom)
  private let haptics = UIImpactFeedbackGenerator(style: .medium)
  private let notifyHaptics = UINotificationFeedbackGenerator()
  private let lightHaptics = UIImpactFeedbackGenerator(style: .light)
  private var tabsMode: Mode?

  // Measuring works in any orientation: the aim ray is the camera's optical
  // axis and the overlay is projected for the current interface orientation.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

  /// Constraints swapped between the portrait layout (cards across the top
  /// and bottom) and the landscape one (cards in the corners, so the centre
  /// of the camera view stays clear).
  private var portraitConstraints = [NSLayoutConstraint]()
  private var landscapeConstraints = [NSLayoutConstraint]()
  private var landscapeLayout: Bool?

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    let landscape = view.bounds.width > view.bounds.height
    if landscape == landscapeLayout { return }
    landscapeLayout = landscape
    NSLayoutConstraint.deactivate(landscape ? portraitConstraints : landscapeConstraints)
    NSLayoutConstraint.activate(landscape ? landscapeConstraints : portraitConstraints)
  }
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  // ------------------------------------------------------------ lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    buildUi()
    refreshUi()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    UIApplication.shared.isIdleTimerDisabled = true
    startIfAllowed()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    UIApplication.shared.isIdleTimerDisabled = false
    sceneView.session.pause()
  }

  /// Always called on the main queue.
  private func diag(_ msg: String) {
    scanLog.info("\(msg, privacy: .public)")
    // Also to stderr, so the lines show in the Xcode / flutter run console.
    NSLog("[scan] %@", msg)
    diagLines.append(String(format: "%.1f ", Date().timeIntervalSince(scanStarted)) + msg)
    if diagLines.count > Self.diagLogLines {
      diagLines.removeFirst(diagLines.count - Self.diagLogLines)
    }
  }

  // ------------------------------------------------------------ diagnostics file

  private var diagFileName: String { "scan_\(Int(scanStarted.timeIntervalSince1970)).json" }

  private static func diagFolder() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("room_measure", isDirectory: true)
      .appendingPathComponent("diag", isDirectory: true)
  }

  /// A new scan (session start, Start over) gets its own file. Older files
  /// are deleted so that, with this one, the 5 newest remain.
  private func beginDiagScan() {
    let now = Date()
    // Start over within the same second must not overwrite the file just
    // written for the previous scan.
    let previous = Int(scanStarted.timeIntervalSince1970)
    scanStarted = sessionStarted && Int(now.timeIntervalSince1970) <= previous
      ? Date(timeIntervalSince1970: Double(previous + 1)) : now
    diagLines.removeAll()
    lastDiagWrite = now
    let keep = Self.diagKeepFiles - 1
    diagQueue.async {
      guard let dir = Self.diagFolder(),
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
      let scans = names
        .filter { $0.hasPrefix("scan_") && $0.hasSuffix(".json") }
        .sorted { (Int($0.dropFirst(5).dropLast(5)) ?? 0) > (Int($1.dropFirst(5).dropLast(5)) ?? 0) }
      for name in scans.dropFirst(keep) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
      }
    }
  }

  /// Writes the diagnostics file for this scan: at most every few seconds
  /// while scanning, or right now with `force` (finish, close, Start over).
  /// The values are captured here; encoding and writing happen on a
  /// background queue so the camera view never stutters.
  private func writeDiag(force: Bool = false) {
    if !sessionStarted { return }
    let now = Date()
    if !force && (diagWriting || now.timeIntervalSince(lastDiagWrite) < Self.diagInterval) { return }
    lastDiagWrite = now
    diagWriting = true
    let cap = DiagCapture(
      device: deviceModel(), started: scanStarted, frames: frameCount,
      mode: mode.label.lowercased(), tracking: snapshot?.tracking == true,
      floorY: planeFloorY, pointFloorY: pointFloorY, ceilingY: ceilingY,
      floorUsed: lastFloorUsed, floorGuessed: lastFloorGuessed,
      camMean: camSamples > 0
        ? V3(Float(camSumX / Double(camSamples)), Float(camSumY / Double(camSamples)),
             Float(camSumZ / Double(camSamples)))
        : nil,
      camNow: camNow, camPath: camPath, sectors: sectors, moveExtent: moveExtent,
      walls: lastWalls, floorPts: lastFloorPts, planes: lastPlanes, cloud: lastCloud,
      room: autoRoom, stableFor: stableSince.map { now.timeIntervalSince($0) },
      completion: completionKind, lines: lines.flatMap { [$0.a, $0.b] },
      linesEstimated: lines.map { $0.estimated }, log: diagLines)
    let name = diagFileName
    diagQueue.async { [weak self] in
      let failure = Self.writeDiagFile(cap, name: name, written: now)
      DispatchQueue.main.async {
        guard let self else { return }
        self.diagWriting = false
        // Diagnostics must never get in the way of a scan: say so once and
        // carry on.
        if let failure, !self.diagWriteFailed {
          self.diagWriteFailed = true
          self.diag("diagnostics not written: \(failure)")
        }
      }
    }
  }

  /// Encodes and writes one diagnostics file; returns what went wrong, if
  /// anything. Runs off the main queue.
  private static func writeDiagFile(_ c: DiagCapture, name: String, written: Date) -> String? {
    // Millimetres are plenty and keep the file small. A decimal number, as
    // JSONSerialization writes a rounded Double as 1.2350000000000001.
    func num(_ v: Float) -> Any {
      if !v.isFinite { return NSNull() }
      let mm = (Double(v) * 1000).rounded()
      return NSDecimalNumber(mantissa: UInt64(abs(mm)), exponent: -3, isNegative: mm < 0)
    }
    func opt(_ v: Float?) -> Any { v.map(num) ?? NSNull() }
    func xyz(_ pts: [V3]) -> [Any] {
      var out = [Any]()
      out.reserveCapacity(pts.count * 3)
      for p in pts {
        out.append(num(p.x))
        out.append(num(p.y))
        out.append(num(p.z))
      }
      return out
    }
    var room: Any = NSNull()
    if let r = c.room {
      room = [
        "corners": r.corners.flatMap { [num($0.x), num($0.z)] },
        "estimated": r.estimated.map { $0 ? 1 : 0 },
        "width": num(r.width),
        "depth": num(r.depth),
        "area": num(r.area),
        "height": opt(r.height),
      ] as [String: Any]
    }
    let json: [String: Any] = [
      "version": 1,
      "device": c.device,
      "started": Int(c.started.timeIntervalSince1970),
      "written": Int(written.timeIntervalSince1970),
      "frames": c.frames,
      "mode": c.mode,
      "tracking": c.tracking,
      "floorY": opt(c.floorY),
      "pointFloorY": opt(c.pointFloorY),
      "ceilingY": opt(c.ceilingY),
      "floorUsed": opt(c.floorUsed),
      "floorGuessed": c.floorGuessed,
      "cam": c.camMean.map { xyz([$0]) } ?? [],
      "camNow": c.camNow.map { xyz([$0]) } ?? [],
      "camPath": c.camPath.map(num),
      "sectors": c.sectors.map { $0 ? 1 : 0 },
      "moveExtent": num(c.moveExtent),
      "walls": c.walls.map { [num($0.cx), num($0.cz), num($0.dx), num($0.dz),
                              num($0.tMin), num($0.tMax), num($0.top)] },
      "floorPts": xyz(c.floorPts),
      "planes": c.planes.map {
        ["alignment": $0.vertical ? "v" : "h",
         "class": $0.classification,
         "y": num($0.y),
         "extent": [num($0.width), num($0.height)],
         "pts": xyz($0.points)] as [String: Any]
      },
      "cloud": xyz(c.cloud),
      "room": room,
      "stableFor": c.stableFor.map { num(Float($0)) } ?? NSNull(),
      "completion": c.completion,
      // 6 values per line, as in the result.
      "lines": xyz(c.lines),
      // 0/1 per line, as in the result.
      "linesEstimated": c.linesEstimated.map { $0 ? 1 : 0 },
      "log": c.log,
    ]
    guard let dir = diagFolder() else { return "no documents folder" }
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: json)
      try data.write(to: dir.appendingPathComponent(name), options: .atomic)
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private func planeClass(_ p: ARPlaneAnchor) -> String {
    switch p.classification {
    case .floor: return "floor"
    case .wall: return "wall"
    case .ceiling: return "ceiling"
    case .table: return "table"
    case .seat: return "seat"
    case .window: return "window"
    case .door: return "door"
    case .none: return "none"
    @unknown default: return "other"
    }
  }

  private func startIfAllowed() {
    if sessionStarted { return }
    guard ARWorldTrackingConfiguration.isSupported else {
      finishWithError("Camera scanning is not available on this device.")
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      startSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted {
            self.startSession()
          } else {
            self.finishWithError("Camera permission is needed to scan a room.")
          }
        }
      }
    default:
      finishWithError("Camera permission is needed to scan a room. Allow it in Settings > ECM-AI.")
    }
  }

  private func startSession() {
    if sessionStarted { return }
    beginDiagScan()
    sessionStarted = true
    sceneView.session.delegate = self
    sceneView.session.run(makeConfig(), options: [.resetTracking, .removeExistingAnchors])
    diag("session started on \(deviceModel()), plane classification: \(ARPlaneAnchor.isClassificationSupported)")
  }

  private func makeConfig() -> ARWorldTrackingConfiguration {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    config.isLightEstimationEnabled = false
    config.worldAlignment = .gravity
    return config
  }

  private func deviceModel() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { buf in
      String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  private func finishWithError(_ msg: String) {
    diag("error: \(msg)")
    deletePhotos()
    finish(with: ["error": msg])
  }

  private func finish(with result: [String: Any]?) {
    if completed { return }
    // The last state of the scan, however it ends (Finish, close, error).
    writeDiag(force: true)
    completed = true
    sceneView.session.pause()
    UIApplication.shared.isIdleTimerDisabled = false
    let done = completion
    if presentingViewController == nil {
      done(result)
    } else {
      dismiss(animated: true) { done(result) }
    }
  }

  @objc private func onClose() {
    if completing { cancelAutoComplete("close tapped") }
    if corners.isEmpty && openings.isEmpty && surfaces.isEmpty && lines.isEmpty && pending.isEmpty
        && photos.isEmpty {
      deletePhotos()
      finish(with: nil)
      return
    }
    let alert = UIAlertController(
      title: "Discard this scan?",
      message: photos.isEmpty
        ? "Everything you have marked will be lost."
        : "Everything you have marked and the photos you took will be lost.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Keep scanning", style: .cancel))
    alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { _ in
      self.deletePhotos()
      self.finish(with: nil)
    })
    present(alert, animated: true)
  }

  // ------------------------------------------------------------ ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    if completed { return }
    process(frame)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    if let e = error as? ARError, e.code == .cameraUnauthorized {
      finishWithError("Camera permission is needed to scan a room. Allow it in Settings > ECM-AI.")
    } else {
      finishWithError("The camera scanner stopped: \(error.localizedDescription)")
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
    diag("session interrupted")
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    diag("session interruption ended")
  }

  // ------------------------------------------------------------ frame processing

  private func process(_ frame: ARFrame) {
    let camera = frame.camera
    var tracking = false
    var hint = "Move the phone slowly to start tracking."
    switch camera.trackingState {
    case .normal:
      tracking = true
    case .limited(let reason):
      switch reason {
      case .excessiveMotion: hint = "Moving too fast. Slow down."
      case .insufficientFeatures: hint = "Point the camera at an area with more detail, or turn on more lights."
      case .relocalizing: hint = "Hold still for a moment, finding your position again..."
      case .initializing: hint = "Move the phone slowly from side to side to start measuring."
      default: break
      }
    default:
      hint = "Camera tracking is not available."
    }

    let t = camera.transform
    let origin = V3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    let dir = -V3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
    let size = sceneView.bounds.size
    let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
    let viewProj = camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.05, zFar: 50)
      * camera.viewMatrix(for: orientation)

    var outlines = [PlaneOutline]()
    var cornerCandidates = [V3]()
    var wallCount = 0
    var hit: V3? = nil
    var hitEstimated = false
    var framePoints = [V3]()
    frameCount += 1

    if tracking { everTracked = true }
    if tracking && size.width > 0 {
      camSumX += Double(origin.x)
      camSumY += Double(origin.y)
      camSumZ += Double(origin.z)
      camSamples += 1
      noteCamera(origin, dir, at: frame.timestamp)
      framePoints = collectPoints(frame, origin)

      let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
      detectFloorAndCeiling(planes, camY: origin.y)
      if frameCount % 60 == 0 {
        diag(String(format: "frame: camY=%.2f points=%d floorY=%@ pointFloorY=%@ planes=%d",
                    origin.y, cloud.count, fmt(planeFloorY), fmt(pointFloorY), planes.count))
      }
      let floorY = planeFloorY ?? pointFloorY

      // Classify surfaces and collect their outlines in world space.
      var walls = [WallSegment]()
      var polys = [(anchor: ARPlaneAnchor, local: [V3])]()
      for p in planes {
        let local = p.geometry.boundaryVertices
        if local.count < 3 { continue }
        let m = p.transform
        let pts = local.map { v -> V3 in
          let w = m * SIMD4<Float>(v.x, v.y, v.z, 1)
          return V3(w.x, w.y, w.z)
        }
        let py = m.columns.3.y
        let kind: SurfaceKind
        if p.alignment == .vertical {
          kind = .wall
        } else if isCeiling(p) || py > origin.y + 0.2 {
          kind = .ceiling
        } else if let f = floorY, abs(py - f) < 0.12 {
          kind = .floor
        } else {
          kind = .other
        }
        outlines.append(PlaneOutline(kind: kind, points: pts))
        polys.append((p, local))
        if kind == .wall,
           let seg = wallSegment(normal: V3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                 cx: m.columns.3.x, cz: m.columns.3.z, pts: pts) {
          walls.append(seg)
        }
      }
      wallCount = walls.count
      cornerCandidates = findCorners(walls, y: floorY ?? (origin.y - 1.3))

      // Automatic room outline, refreshed a few times per second on the
      // detector queue (the last good outline is kept meanwhile).
      if frameCount % 10 == 0 && camSamples > 0 && !detecting {
        let cloudNow = Array(cloud.values)
        let camY = Float(camSumY / Double(camSamples))
        if planeFloorY == nil && frameCount % 30 == 0, let f = estimateFloor(cloudNow, camY: camY) {
          pointFloorY = f
        }
        // Without a floor plane or a floor from points, assume the phone is
        // held at a typical height; the room height is then left out.
        let guessed = floorY == nil
        let useFloor = floorY ?? (camY - 1.35)
        if !guessed || cloudNow.count >= RoomDetector.minCloud {
          detecting = true
          let floorPts = outlines.filter { $0.kind == .floor }.flatMap { $0.points }
          let wallsNow = walls
          let cx = Float(camSumX / Double(camSamples))
          let cz = Float(camSumZ / Double(camSamples))
          let ceiling = ceilingY
          let surfaces = planes.count
          let source = planeFloorY != nil ? "plane" : (guessed ? "guess" : "points")
          let gen = scanGeneration
          // Kept for the diagnostics file, so the detection can be replayed.
          lastWalls = wallsNow
          lastFloorPts = floorPts
          lastCloud = cloudNow
          lastFloorUsed = useFloor
          lastFloorGuessed = guessed
          // polys and outlines hold the same surfaces, in the same order.
          lastPlanes = zip(polys, outlines).map { poly, o in
            let p = poly.anchor
            return DiagPlane(vertical: p.alignment == .vertical, classification: planeClass(p),
                             y: p.transform.columns.3.y, width: p.planeExtent.width,
                             height: p.planeExtent.height, points: o.points)
          }
          detector.async { [weak self] in
            let room = RoomDetector.computeAutoRoom(
              walls: wallsNow, floorPts: floorPts, floorY: useFloor,
              cx: cx, cz: cz, ceilingY: ceiling, cloud: cloudNow)
            DispatchQueue.main.async {
              guard let self else { return }
              if gen != self.scanGeneration {
                self.detecting = false
                return
              }
              if let room {
                self.autoRoom = guessed ? room.withoutHeight() : room
                self.autoRoomGuessedFloor = guessed
                self.noteRoomStability(room)
              }
              self.logScanState(surfaces, wallsNow.count, cloudNow.count, useFloor, source, self.autoRoom)
              self.detecting = false
              self.checkAutoComplete()
              self.writeDiag()
            }
          }
        }
      }

      // What the crosshair, i.e. the screen centre, points at.
      let centre = CGPoint(x: size.width / 2, y: size.height / 2)
      if let r = pick(at: centre, frame: frame, polys: polys) {
        hit = r.point
        hitEstimated = r.estimated
      }
      if openingAuto && !completed {
        maybeDetectOpening(frame, polys: polys, kind: mode == .door ? .door : .window, room: false)
      } else if roomOpeningScan {
        // Room scan: doors and windows are found along the way, both looked
        // for in each image (a little less often, so the room detection
        // keeps its share of the phone). They used to alternate, which
        // halved how often each was seen while the camera swept past.
        maybeDetectOpening(frame, polys: polys, kind: .door, room: true)
        // AI furniture detection, once the floor is known (furniture is
        // placed where it stands on it).
        if let fy = planeFloorY ?? pointFloorY { maybeDetectFurniture(frame, floorY: fy, orientation: orientation) }
      }
    }
    // A finger held still still points at something else as the phone moves.
    if let tp = tapPreview, CACurrentMediaTime() - lastTapPick >= 1.0 / 30 {
      lastTapPick = CACurrentMediaTime()
      tapPreview = TapPreview(at: tp.at, pick: pick(at: tp.at, frame: frame, lineTap: true))
    }

    snapshot = Snapshot(
      tracking: tracking, trackingHint: hint, viewProj: viewProj, hit: hit,
      hitEstimated: hitEstimated, camPos: origin, camForward: dir,
      camUp: V3(t.columns.1.x, t.columns.1.y, t.columns.1.z), planes: outlines, floorY: planeFloorY ?? pointFloorY, ceilingY: ceilingY,
      wallCount: wallCount, cornerCandidates: cornerCandidates, autoRoom: autoRoom,
      framePoints: framePoints)
    aimSmoother.add(CACurrentMediaTime(), tracking ? hit : nil)

    if tracking != lastTracking {
      lastTracking = tracking
      diag(tracking ? "tracking" : "tracking limited: \(hint)")
    }
    // The room can no longer be trusted to be what the card shows.
    if !tracking && completing { cancelAutoComplete("tracking lost") }
    refreshUi()
    overlay.setNeedsDisplay()
  }

  /// A frame's detected surfaces with their outline in the surface's own
  /// space, as pick needs them.
  private func planePolys(_ frame: ARFrame) -> [(anchor: ARPlaneAnchor, local: [V3])] {
    frame.anchors.compactMap { a -> (anchor: ARPlaneAnchor, local: [V3])? in
      guard let p = a as? ARPlaneAnchor else { return nil }
      let local = p.geometry.boundaryVertices
      return local.count < 3 ? nil : (p, local)
    }
  }

  /// The point in the scene under a point of the screen: the crosshair at
  /// the screen centre, or a finger. `estimated` when it is not on anything
  /// measured but on a surface assumed to be there. `polys` are the frame's
  /// surfaces when the caller has them already. `lineTap` (a tap in Line
  /// mode) adds two rougher estimates, so a tap on a plain wall still gives
  /// a distance.
  private func pick(at point: CGPoint, frame: ARFrame,
                    polys given: [(anchor: ARPlaneAnchor, local: [V3])]? = nil,
                    lineTap: Bool = false) -> (point: V3, estimated: Bool)? {
    let camera = frame.camera
    guard case .normal = camera.trackingState else { return nil }
    let size = sceneView.bounds.size
    if size.width <= 0 || size.height <= 0 { return nil }
    let polys = given ?? planePolys(frame)
    let floorY = planeFloorY ?? pointFloorY
    let t = camera.transform
    let origin = V3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    let forward = -V3(t.columns.2.x, t.columns.2.y, t.columns.2.z)

    // The line of sight through that point of the screen. For the crosshair
    // the camera's optical axis is not exactly that line (lens centre
    // offset, the camera image is cropped to fill the screen), so the point
    // measured was not the point under the crosshair.
    let query = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
    let rayO: V3
    let rayD: V3
    if let query {
      rayO = query.origin
      rayD = simd_normalize(query.direction)
    } else {
      // No query: the same line from the camera's projection.
      let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
      let inv = (camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.05, zFar: 50)
        * camera.viewMatrix(for: orientation)).inverse
      let nx = Float(point.x / size.width) * 2 - 1
      let ny = 1 - Float(point.y / size.height) * 2
      let n4 = inv * SIMD4<Float>(nx, ny, 0, 1)
      let f4 = inv * SIMD4<Float>(nx, ny, 1, 1)
      if abs(n4.w) < 1e-6 || abs(f4.w) < 1e-6 { return nil }
      let d = V3(f4.x, f4.y, f4.z) / f4.w - V3(n4.x, n4.y, n4.z) / n4.w
      let len = simd_length(d)
      if !len.isFinite || len < 1e-6 { return nil }
      rayO = origin
      rayD = d / len
    }

    var hit: V3? = nil
    // Nearest surface along the line of sight.
    var bestT = Float.greatestFiniteMagnitude
    // Height of the floor / ceiling when the best hit is on it beyond its
    // detected area (it is treated as an infinite plane).
    var bestExtendedY: Float? = nil
    func consider(_ t: Float, extendedY: Float? = nil) {
      if t > 0.15 && t < 12 && t < bestT {
        bestT = t
        hit = rayO + rayD * t
        bestExtendedY = extendedY
      }
    }
    for (anchor, local) in polys {
      let m = anchor.transform
      let normal = V3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
      let denom = simd_dot(normal, rayD)
      if abs(denom) < 1e-3 { continue }
      let c = V3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
      let tt = simd_dot(c - rayO, normal) / denom
      if tt <= 0.15 || tt >= 12 { continue }
      let w = rayO + rayD * tt
      let l = m.inverse * SIMD4<Float>(w.x, w.y, w.z, 1)
      let vertical = anchor.alignment == .vertical
      if !inPolygon(local, l.x, l.z, margin: vertical ? 0.3 : 0) { continue }
      consider(tt)
    }
    // The floor and ceiling are extended beyond their detected area, but
    // not at a shallow angle or far away: there a degree of tilt moves the
    // point by metres (a "9 m" line across a small room).
    if let f = floorY, rayD.y < -Self.minExtendSlope {
      let t = (f - rayO.y) / rayD.y
      if t < Self.maxExtendDistance { consider(t, extendedY: f) }
    }
    if let cy = ceilingY, rayD.y > Self.minExtendSlope {
      let t = (cy - rayO.y) / rayD.y
      if t < Self.maxExtendDistance { consider(t, extendedY: cy) }
    }

    // Walls of the room outline already found: vertical planes from its
    // floor up to the ceiling, so an already scanned plain wall can still
    // be measured once its surface is no longer tracked.
    if let room = autoRoom, room.corners.count >= 3 {
      let n = room.corners.count
      let roomFloor = room.corners[0].y
      let roomTop = ceilingY ?? (roomFloor + 3.0)
      for i in 0..<n {
        let a = room.corners[i]
        let b = room.corners[(i + 1) % n]
        let ex = b.x - a.x
        let ez = b.z - a.z
        let len = (ex * ex + ez * ez).squareRoot()
        if len < 0.05 { continue }
        let ux = ex / len, uz = ez / len
        // Horizontal wall normal.
        let nx = -uz, nz = ux
        let denom = nx * rayD.x + nz * rayD.z
        if abs(denom) < 1e-3 { continue }
        let tt = ((a.x - rayO.x) * nx + (a.z - rayO.z) * nz) / denom
        if tt <= 0.15 || tt >= 12 { continue }
        let w = rayO + rayD * tt
        let along = (w.x - a.x) * ux + (w.z - a.z) * uz
        if along < -0.15 || along > len + 0.15 { continue }
        if w.y < roomFloor - 0.05 || w.y > roomTop { continue }
        consider(tt)
      }
    }

    // Points tracked earlier along the line of sight (the accumulated
    // cloud), so aiming back at a scanned area measures without having to
    // pick up fresh detail first. Same rule as ARKit's estimate below.
    if !cloud.isEmpty {
      var along = [Float]()
      for p in cloud.values {
        let v = p - rayO
        let s = simd_dot(v, rayD)
        if s <= 0.2 || s >= 12 { continue }
        let perp = v - rayD * s
        let tol = max(Float(0.03), 0.012 * s)
        if simd_length_squared(perp) <= tol * tol { along.append(s) }
      }
      if along.count >= 6 {
        along.sort()
        let s = along[along.count / 4]
        let p = rayO + rayD * s
        let inFront: Bool
        if let py = bestExtendedY {
          inFront = s < bestT - 0.03 && abs(p.y - py) > 0.05
        } else {
          inFront = s < bestT - 0.35
        }
        if hit == nil || inFront {
          hit = p
          bestT = s
          bestExtendedY = nil
        }
      }
    }

    // ARKit's estimate from feature points under that point of the screen:
    // used when nothing else is there, or when it is in front of the
    // surface found above (a wall that was not detected as a surface).
    if let q = query, let r = sceneView.session.raycast(q).first {
      let c = r.worldTransform.columns.3
      let p = V3(c.x, c.y, c.z)
      let d = simd_length(p - rayO)
      let inFront: Bool
      if let py = bestExtendedY {
        // Aiming at the foot of an undetected wall, the extended floor is
        // hit *behind* the wall (often 10-40 cm). Any point off the floor
        // in front of it is the wall itself.
        inFront = d < bestT - 0.03 && abs(p.y - py) > 0.05
      } else {
        inFront = d < bestT - 0.35
      }
      if d < 12 && (hit == nil || inFront) { hit = p }
    }
    if let hit { return (hit, false) }

    // Last resort, for a plain wall: nothing can be measured at the spot
    // itself, but a wall detected nearby most likely continues there. Its
    // plane is extended up to 2 m beyond its detected area, between the
    // floor and a ceiling's height. Shown as estimated.
    var nearest = Float.greatestFiniteMagnitude
    for (anchor, local) in polys where anchor.alignment == .vertical {
      let m = anchor.transform
      let normal = V3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
      let denom = simd_dot(normal, rayD)
      if abs(denom) < 1e-3 { continue }
      let c = V3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
      let tt = simd_dot(c - rayO, normal) / denom
      if tt <= 0.15 || tt >= 8 || tt >= nearest { continue }
      let w = rayO + rayD * tt
      if let f = floorY, w.y < f - 0.05 || w.y > f + 3.5 { continue }
      let l = m.inverse * SIMD4<Float>(w.x, w.y, w.z, 1)
      if !inPolygon(local, l.x, l.z, margin: 2.0) { continue }
      nearest = tt
      hit = w
    }
    if let hit { return (hit, true) }
    if !lineTap { return nil }

    if mode == .line, let a = pending.first {
      // The second end of a line with no wall detected at all: the user is
      // assumed to face the wall the first point is on, so the tap is put
      // on the upright plane through that point, square to the view.
      let flat = V3(forward.x, 0, forward.z)
      let len = simd_length(flat)
      // Looking straight down or up there is no such wall.
      if len < 0.1 { return nil }
      let normal = flat / len
      let denom = simd_dot(normal, rayD)
      if abs(denom) < 1e-3 { return nil }
      let tt = simd_dot(a - rayO, normal) / denom
      return tt > 0.15 && tt < 8 ? (rayO + rayD * tt, true) : nil
    }

    // No first point yet: the depth of what was scanned around the spot.
    // Of the points within 15 degrees of the line of sight, the 9 nearest
    // to it in angle; their median distance along it.
    let minCos = cos(Float(15) * .pi / 180)
    var near = [(cos: Float, s: Float)]()
    for p in cloud.values {
      let v = p - rayO
      let s = simd_dot(v, rayD)
      if s <= 0.2 || s >= 8 { continue }
      let c = s / simd_length(v)
      if c >= minCos { near.append((c, s)) }
    }
    if near.count < 5 { return nil }
    near.sort { $0.cos > $1.cos }
    let depths = near.prefix(9).map { $0.s }.sorted()
    return (rayO + rayD * depths[depths.count / 2], true)
  }

  // ------------------------------------------------------------ automatic doors and windows

  /// The line of sight through a point of the screen (as in pick).
  private func screenRay(_ point: CGPoint, _ frame: ARFrame) -> (o: V3, d: V3)? {
    let size = sceneView.bounds.size
    if size.width <= 0 || size.height <= 0 { return nil }
    if let q = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any) {
      return (q.origin, simd_normalize(q.direction))
    }
    let camera = frame.camera
    let t = camera.transform
    let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
    let inv = (camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.05, zFar: 50)
      * camera.viewMatrix(for: orientation)).inverse
    let nx = Float(point.x / size.width) * 2 - 1
    let ny = 1 - Float(point.y / size.height) * 2
    let n4 = inv * SIMD4<Float>(nx, ny, 0, 1)
    let f4 = inv * SIMD4<Float>(nx, ny, 1, 1)
    if abs(n4.w) < 1e-6 || abs(f4.w) < 1e-6 { return nil }
    let d = V3(f4.x, f4.y, f4.z) / f4.w - V3(n4.x, n4.y, n4.z) / n4.w
    let len = simd_length(d)
    if !len.isFinite || len < 1e-6 { return nil }
    return (V3(t.columns.3.x, t.columns.3.y, t.columns.3.z), d / len)
  }

  /// The wall plane a door or window is searched on, and where the
  /// crosshair meets it. Detected surfaces are not required: the first of
  /// these that is available is used.
  ///  plane:    the crosshair is on a detected wall surface.
  ///  fit:      a plane through measured points around the crosshair (an
  ///            open doorway: the crosshair looks through the opening, the
  ///            wall is found around it).
  ///  room:     the side of the room outline the crosshair crosses.
  ///  extended: a wall surface detected nearby, extended (estimated).
  ///  cloud:    the depth of tracked points around the crosshair, facing
  ///            the camera (estimated).
  ///  floor:    (doors) where the floor meets the bottom of the view,
  ///            facing the camera (estimated).
  private func autoWallFrame(_ frame: ARFrame, polys: [(anchor: ARPlaneAnchor, local: [V3])])
    -> (wall: WallFrame, source: String)? {
    let size = sceneView.bounds.size
    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
    guard let (rayO, rayD) = screenRay(centre, frame) else { return nil }
    let floorY = planeFloorY ?? pointFloorY
    let camPos = rayO
    let flatFwd = V3(rayD.x, 0, rayD.z)
    let flatLen = simd_length(flatFwd)
    // Looking straight down or up there is no wall to search.
    if flatLen < 0.3 { return nil }

    /// The frame for the plane through `p` with horizontal normal `n`
    /// (turned to face the camera); nil when the crosshair meets it at a
    /// grazing angle or out of range.
    func make(_ p: V3, _ n: V3, _ source: String, estimated: Bool) -> (wall: WallFrame, source: String)? {
      var nh = V3(n.x, 0, n.z)
      let l = simd_length(nh)
      if l < 0.5 { return nil }
      nh /= l
      if simd_dot(nh, camPos - p) < 0 { nh = -nh }
      let denom = simd_dot(rayD, nh)
      if denom > -0.3 { return nil }
      let t = simd_dot(p - rayO, nh) / denom
      if t < 0.3 || t > 8 { return nil }
      return (WallFrame(origin: rayO + rayD * t, normal: nh, floorY: floorY, estimated: estimated), source)
    }

    // a. A detected wall surface under the crosshair.
    var bestT = Float.greatestFiniteMagnitude
    var best: (wall: WallFrame, source: String)?
    for (anchor, local) in polys where anchor.alignment == .vertical {
      let m = anchor.transform
      let normal = V3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
      let denom = simd_dot(normal, rayD)
      if abs(denom) < 1e-3 { continue }
      let c = V3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
      let tt = simd_dot(c - rayO, normal) / denom
      if tt <= 0.3 || tt >= 8 || tt >= bestT { continue }
      let w = rayO + rayD * tt
      let l = m.inverse * SIMD4<Float>(w.x, w.y, w.z, 1)
      if !inPolygon(local, l.x, l.z, margin: 0.3) { continue }
      if let f = make(c, normal, "plane", estimated: false) {
        bestT = tt
        best = f
      }
    }
    if let best { return best }

    // b. Measured points on the crosshair's row and 20 % lower, at 15, 30,
    // 70 and 85 % of the width, and the crosshair itself. Points on the
    // floor or ceiling are left out; a vertical plane is fitted through
    // the rest.
    var pts = [V3]()
    for fy in [CGFloat(0.5), 0.7] {
      for fx in [CGFloat(0.15), 0.3, 0.7, 0.85] {
        if let r = pick(at: CGPoint(x: size.width * fx, y: size.height * fy), frame: frame, polys: polys),
           !r.estimated { pts.append(r.point) }
      }
    }
    if let r = pick(at: centre, frame: frame, polys: polys), !r.estimated { pts.append(r.point) }
    pts.removeAll { p in
      (floorY.map { p.y < $0 + 0.08 } ?? false) || (ceilingY.map { p.y > $0 - 0.08 } ?? false)
    }
    if let (p, n) = Self.fitVerticalPlane(pts), let f = make(p, n, "fit", estimated: false) { return f }

    // c. The room outline's side the crosshair crosses.
    if let room = autoRoom, room.corners.count >= 3 {
      let n = room.corners.count
      var nearest = Float.greatestFiniteMagnitude
      var found: (wall: WallFrame, source: String)?
      for i in 0..<n {
        let a = room.corners[i]
        let b = room.corners[(i + 1) % n]
        let e = V3(b.x - a.x, 0, b.z - a.z)
        let len = simd_length(e)
        if len < 0.05 { continue }
        let normal = V3(-e.z / len, 0, e.x / len)
        let denom = simd_dot(normal, rayD)
        if abs(denom) < 1e-3 { continue }
        let tt = simd_dot(V3(a.x, rayO.y, a.z) - rayO, normal) / denom
        if tt <= 0.3 || tt >= 8 || tt >= nearest { continue }
        let w = rayO + rayD * tt
        let along = simd_dot(V3(w.x - a.x, 0, w.z - a.z), e / len)
        if along < -0.15 || along > len + 0.15 { continue }
        if let f = make(V3(a.x, rayO.y, a.z), normal, "room", estimated: false) {
          nearest = tt
          found = f
        }
      }
      if let found { return found }
    }

    // d. A wall surface detected nearby, extended up to 2 m (as pick).
    var nearest = Float.greatestFiniteMagnitude
    var extended: (wall: WallFrame, source: String)?
    for (anchor, local) in polys where anchor.alignment == .vertical {
      let m = anchor.transform
      let normal = V3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
      let denom = simd_dot(normal, rayD)
      if abs(denom) < 1e-3 { continue }
      let c = V3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
      let tt = simd_dot(c - rayO, normal) / denom
      if tt <= 0.3 || tt >= 8 || tt >= nearest { continue }
      let w = rayO + rayD * tt
      if let f = floorY, w.y < f - 0.05 || w.y > f + 3.5 { continue }
      let l = m.inverse * SIMD4<Float>(w.x, w.y, w.z, 1)
      if !inPolygon(local, l.x, l.z, margin: 2.0) { continue }
      if let f = make(c, normal, "extended", estimated: true) {
        nearest = tt
        extended = f
      }
    }
    if let extended { return extended }

    let facing = flatFwd / flatLen
    // e. Tracked points within 10 degrees of the crosshair: their median
    // distance, on a plane facing the camera.
    let minCos = cos(Float(10) * .pi / 180)
    var depths = [Float]()
    for p in cloud.values {
      let v = p - rayO
      let s = simd_dot(v, rayD)
      if s <= 0.3 || s >= 8 { continue }
      if s / simd_length(v) >= minCos { depths.append(s) }
    }
    if depths.count >= 5 {
      depths.sort()
      if let f = make(rayO + rayD * depths[depths.count / 2], facing, "cloud", estimated: true) { return f }
    }

    // f. A door stands on the floor: the floor at the bottom of the view is
    // taken as its foot, on a plane facing the camera. (Windows too: the
    // floor line then has to place the wall; see maybeDetectOpening.)
    if let fy = floorY,
       let (bo, bd) = screenRay(CGPoint(x: size.width / 2, y: size.height), frame), bd.y < -0.05 {
      let t = (fy - bo.y) / bd.y
      if t > 0.3 && t < 8, let f = make(bo + bd * t, facing, "floor", estimated: true) { return f }
    }
    return nil
  }

  /// A vertical plane (a point on it and its horizontal normal) through
  /// points around the crosshair: a least-squares line in x/z, dropping
  /// points more than 8 cm off it. Needs two points at least 0.4 m apart.
  private static func fitVerticalPlane(_ input: [V3]) -> (V3, V3)? {
    var pts = input
    while pts.count >= 2 {
      var mx: Float = 0, mz: Float = 0
      for p in pts { mx += p.x; mz += p.z }
      mx /= Float(pts.count)
      mz /= Float(pts.count)
      var sxx: Float = 0, sxz: Float = 0, szz: Float = 0
      for p in pts {
        let dx = p.x - mx, dz = p.z - mz
        sxx += dx * dx
        sxz += dx * dz
        szz += dz * dz
      }
      // Direction of the line: the main axis of the points.
      let angle = 0.5 * atan2(2 * sxz, sxx - szz)
      let dir = V3(cos(angle), 0, sin(angle))
      let normal = V3(-dir.z, 0, dir.x)
      let centre = V3(mx, 0, mz)
      var worst = 0
      var worstD: Float = 0
      var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
      for (i, p) in pts.enumerated() {
        let d = abs(simd_dot(V3(p.x, 0, p.z) - centre, normal))
        if d > worstD {
          worstD = d
          worst = i
        }
        let t = simd_dot(V3(p.x, 0, p.z) - centre, dir)
        lo = min(lo, t)
        hi = max(hi, t)
      }
      if worstD > 0.08 {
        pts.remove(at: worst)
        continue
      }
      if hi - lo < 0.4 { return nil }
      return (V3(mx, pts.map { $0.y }.reduce(0, +) / Float(pts.count), mz), normal)
    }
    return nil
  }

  /// Starts a detection attempt on this frame (about 5 a second, one at a
  /// time). The wall plane is found here, on the main queue; reading the
  /// camera image and the detection itself run on openingQueue.
  /// `room`: a room-scan attempt (Auto mode, counting doors and windows),
  /// whose result goes to noteRoomOpening instead of the Door / Window
  /// search. Returns whether an attempt slot was used (started, or no wall).
  @discardableResult
  private func maybeDetectOpening(_ frame: ARFrame, polys: [(anchor: ARPlaneAnchor, local: [V3])],
                                  kind: OpeningKind, room: Bool) -> Bool {
    let now = CACurrentMediaTime()
    if openingBusy || now - lastOpeningAttempt < (room ? 0.25 : 0.2) { return false }
    lastOpeningAttempt = now
    guard let (wall, source) = autoWallFrame(frame, polys: polys) else {
      if room { return true }
      if !autoWallMissing { diag("auto \(mode.label.lowercased()): no wall plane") }
      autoWallMissing = true
      // The detections so far are kept: an estimated wall often drops out
      // for a frame or two, and clearing them then meant the result never
      // stayed stable long enough to be added. They expire after 2 s.
      return true
    }
    if !room {
      if autoWallMissing { diag("auto \(mode.label.lowercased()): wall from \(source)") }
      autoWallMissing = false
    }
    let camera = frame.camera
    let k = camera.intrinsics
    let model = CameraModel(
      worldToCamera: camera.transform.inverse,
      fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y,
      width: Int(camera.imageResolution.width), height: Int(camera.imageResolution.height))
    // Only the image is kept, not the frame: ARKit stops delivering frames
    // when too many are held.
    let buffer = frame.capturedImage
    let gen = openingGen
    openingBusy = true
    openingQueue.async { [weak self] in
      let result = Self.detectOpening(buffer, model, wall, kind, wide: room)
      // Room scan: the same image and wall searched for a window too. A
      // window's wall guessed through the floor is of no use unless the floor
      // line confirmed it (as below).
      var roomDoor: OpeningCandidate?
      var roomWindow: OpeningCandidate?
      if room, let result {
        if result.floorLine != nil || source != "floor" {
          roomWindow = OpeningDetector.search(kind: .window, frame: result.frame, image: result.image).candidate
        }
        roomDoor = result.analysis.candidate
        if let d = roomDoor, RoomOpeningCounter.doorIsWindow(d, roomWindow, floorY: result.frame.floorY) {
          roomDoor = nil
        }
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.openingBusy = false
        guard gen == self.openingGen, !self.completed, let result else { return }
        if room {
          if self.roomOpeningScan {
            self.noteRoomOpening(roomDoor, kind: .door, wall: result.frame)
            self.noteRoomOpening(roomWindow, kind: .window, wall: result.frame)
          }
          return
        }
        guard self.openingAuto else { return }
        // The wall is placed by where it meets the floor when that line is in
        // view (OpeningDetector.measure): a detected wall a few cm out, or a
        // guessed one, made the door / window that much too small or large.
        if let fl = result.floorLine, CACurrentMediaTime() - self.lastFloorLineDiag > 2 {
          self.lastFloorLineDiag = CACurrentMediaTime()
          self.diag(String(format: "opening wall %@ corrected by the floor line: %+.1f cm, %.1f°, %d strips",
                           source, fl.moved * 100, fl.turned, fl.strips))
        }
        // A window's wall taken through the floor at the bottom of the view
        // is only a guess, of no use unless the floor line confirmed it.
        if result.floorLine == nil && source == "floor" && kind == .window {
          if !self.autoWallMissing { self.diag("auto window: floor-guessed wall not confirmed by a floor line") }
          self.autoWallMissing = true
          return
        }
        self.noteOpeningAttempt(OpeningShot(image: result.image, analysis: result.analysis, wall: result.frame,
                                            source: result.floorLine == nil ? source : source + "+floor line",
                                            kind: kind))
      }
    }
    return true
  }

  /// Resamples the camera image's luminance (the Y plane) onto the wall and
  /// looks for the frame. Runs on openingQueue.
  private static func detectOpening(_ buf: CVPixelBuffer, _ model: CameraModel, _ wall: WallFrame,
                                    _ kind: OpeningKind, wide: Bool = false) -> OpeningDetector.Measured? {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let planar = CVPixelBufferIsPlanar(buf)
    guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buf, 0) : CVPixelBufferGetBaseAddress(buf)
    else { return nil }
    let pw = planar ? CVPixelBufferGetWidthOfPlane(buf, 0) : CVPixelBufferGetWidth(buf)
    let ph = planar ? CVPixelBufferGetHeightOfPlane(buf, 0) : CVPixelBufferGetHeight(buf)
    let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buf, 0) : CVPixelBufferGetBytesPerRow(buf)
    if pw < 2 || ph < 2 || model.width <= 0 || model.height <= 0 { return nil }
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    // The intrinsics are for imageResolution; the Y plane has the same size
    // on current devices, scaled in case it ever differs.
    let sx = Float(pw) / Float(model.width), sy = Float(ph) / Float(model.height)
    let maxX = Float(pw - 1), maxY = Float(ph - 1)
    return OpeningDetector.measure(kind: kind, frame: wall, camera: model, wide: wide) { x, y in
      let fx = x * sx, fy = y * sy
      if !(fx >= 0 && fy >= 0 && fx <= maxX && fy <= maxY) { return nil }
      let x0 = min(Int(fx), pw - 2), y0 = min(Int(fy), ph - 2)
      let ax = fx - Float(x0), ay = fy - Float(y0)
      let r0 = bytes + y0 * stride + x0
      let r1 = r0 + stride
      let top = Float(r0[0]) * (1 - ax) + Float(r0[1]) * ax
      let bottom = Float(r1[0]) * (1 - ax) + Float(r1[1]) * ax
      return top * (1 - ay) + bottom * ay
    }
  }

  private func clearAutoSamples() {
    autoSamples.removeAll()
    autoOpening = nil
    lastStableOpening = nil
    adjusted = nil
    adjustGrab = -1
  }

  /// Starts the automatic search afresh (mode or method switch, an opening
  /// just added, Start over).
  private func resetAutoSearch() {
    openingGen += 1
    clearAutoSamples()
    roomSamples.removeAll()
    autoWallMissing = false
    autoNothingSince = Date()
  }

  /// Adds an attempt's result to the consensus. A detection counts only
  /// together with the others on the same wall (within 10 cm / 10 degrees)
  /// around the same spot (centre within 20 cm); pointing elsewhere starts
  /// over. Stable when at least 4 of the last 8 agree within 2 cm with the
  /// per-edge median.
  private func noteOpeningAttempt(_ shot: OpeningShot) {
    lastOpeningShot = shot
    let now = Date()
    // Detections expire after 2 s. They are not dropped when the wall
    // estimate shifts a little between frames (an estimated wall jitters):
    // whether they are the same opening is decided by where it is (below).
    autoSamples.removeAll { s in now.timeIntervalSince(s.time) > 2 }
    if let c = shot.analysis.candidate {
      let sample = AutoSample(a: c.a, b: c.b, bottom: c.bottom, top: c.top, origin: shot.wall.origin,
                              normal: shot.wall.normal, estimated: c.estimated, time: now)
      if let sup = autoSuppress, now < sup.until, simd_length(sample.centre - sup.centre) < 0.2 {
        // The opening just added.
      } else {
        autoSamples.removeAll { simd_length($0.centre - sample.centre) > Self.sameOpening }
        autoSamples.append(sample)
        if autoSamples.count > 8 { autoSamples.removeFirst(autoSamples.count - 8) }
        autoNothingSince = now
      }
    }
    let wasStable = autoOpening?.stable == true
    autoOpening = Self.consensus(autoSamples)
    if let o = autoOpening, o.stable { lastStableOpening = (o, now) }
    if let o = autoOpening, o.stable && !wasStable {
      diag(String(format: "auto %@ stable: %.3f x %.3f m (wall %@%@)", mode.label.lowercased(),
                  o.a.dist2d(o.b), o.top - o.bottom, shot.source, o.estimated ? ", estimated" : ""))
    }
    // While searching without a result, an image now and then for tuning.
    if autoOpening?.stable != true && now.timeIntervalSince(lastOpeningDiagWrite) >= 3 {
      writeOpeningDiag(shot, accepted: false)
    }
  }

  /// Room scan: there the camera sweeps past a door or window instead of
  /// being held on it, so 4 detections within 2 cm (about 2 s held still)
  /// were seldom reached and nothing was counted. 3 within 4 cm still
  /// rejects one-off misreads (as OpeningConsensus.forRoomScan on Android).
  private static func consensus(_ samples: [AutoSample], tol: Float = 0.02, need: Int = 4) -> AutoOpening? {
    if samples.isEmpty { return nil }
    func median(_ v: [Float]) -> Float {
      let s = v.sorted()
      return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    let bottom = median(samples.map { $0.bottom })
    let top = median(samples.map { $0.top })
    let a = V3(median(samples.map { $0.a.x }), bottom, median(samples.map { $0.a.z }))
    let b = V3(median(samples.map { $0.b.x }), bottom, median(samples.map { $0.b.z }))
    let agree = samples.filter {
      $0.a.dist2d(a) <= tol && $0.b.dist2d(b) <= tol && abs($0.bottom - bottom) <= tol && abs($0.top - top) <= tol
    }
    let estimated = samples.filter { $0.estimated }.count * 2 > samples.count
    return AutoOpening(a: a, b: b, bottom: bottom, top: top, estimated: estimated, stable: agree.count >= need)
  }

  /// Centres of the doors / windows of `type` counted so far (others are
  /// put far away so their indices still match `openings`).
  private func openingCentres(_ type: Int) -> [V3] {
    openings.map { o in
      o.type != type
        ? V3(Float.greatestFiniteMagnitude, 0, Float.greatestFiniteMagnitude)
        : RoomOpeningCounter.centre(o.a, o.b, bottom: (o.a.y + o.b.y) / 2,
                                    top: o.topY ?? ((o.a.y + o.b.y) / 2 + 1))
    }
  }

  /// Room scan (Auto mode): a door / window attempt is back. Once the
  /// detections of one kind hold steady, have a door's or window's
  /// proportions and are not one already counted, it is added: the room's
  /// doors and windows are counted as it is walked round, with no tap.
  private func noteRoomOpening(_ c: OpeningCandidate?, kind: OpeningKind, wall: WallFrame) {
    guard let c else { return }
    let type = kind == .door ? Self.typeDoor : Self.typeWindow
    let now = Date()
    var samples = roomSamples[type] ?? []
    samples.removeAll { now.timeIntervalSince($0.time) > 2 }
    let sample = AutoSample(a: c.a, b: c.b, bottom: c.bottom, top: c.top, origin: wall.origin,
                            normal: wall.normal, estimated: c.estimated, time: now)
    samples.removeAll { simd_length($0.centre - sample.centre) > Self.sameOpening }
    samples.append(sample)
    if samples.count > 6 { samples.removeFirst(samples.count - 6) }
    roomSamples[type] = samples
    guard let found = Self.consensus(samples, tol: 0.04, need: 3), found.stable else { return }
    roomSamples[type] = []
    let width = found.a.dist2d(found.b)
    // Counted without a tap, so only on firm ground: the floor known (a
    // window's sill and a door's foot are checked against it) and a size a
    // real one has. Small "windows" counted on a guessed floor were posters.
    guard let fy = snapshot?.floorY, width >= 0.5, found.top - found.bottom >= 0.5 else { return }
    if !RoomOpeningCounter.plausible(kind, width: width, height: found.top - found.bottom,
                                     bottom: found.bottom, floorY: fy) { return }
    let centre = RoomOpeningCounter.centre(found.a, found.b, bottom: found.bottom, top: found.top)
    // Already counted (as either kind: a glazed door must not count twice).
    if RoomOpeningCounter.duplicateOf(centre, openingCentres(Self.typeDoor)) != nil
      || RoomOpeningCounter.duplicateOf(centre, openingCentres(Self.typeWindow)) != nil { return }
    // A door stands on the floor when it is known.
    let base = kind == .door ? fy : found.bottom
    let o = OpeningMark(type: type, a: found.a.withY(base), b: found.b.withY(base), topY: found.top,
                        method: OpeningMethod.auto.code, estimated: found.estimated)
    openings.append(o)
    history.append(Self.hOpening)
    let name = kind == .door ? "Door" : "Window"
    diag("room scan: \(name.lowercased()) counted automatically \(openingText(o, fy)), \(elementsSummary() ?? "")")
    flash("\(name) found: \(openingText(o, fy))  ·  \(elementsSummary() ?? "")")
    lightHaptics.impactOccurred()
    overlay.setNeedsDisplay()
  }

  /// The ✓ button in Door / Window mode: adds the door or window found: the
  /// stable result (or one that was stable a moment ago), else the
  /// detection so far, flagged as approximate. With nothing detected it
  /// says what to do instead. The scan goes on, so every door and window of
  /// the room can be added (and counted); one already counted at the same
  /// spot is replaced rather than counted twice. Finish ends the scan.
  private func acceptAutoOpening(_ snap: Snapshot) {
    let now = Date()
    var settled = true
    var picked: AutoOpening?
    let byHand = adjusted != nil
    if let adj = adjusted {
      // Adjusted by hand: exactly as the user left it.
      picked = adj.opening
    } else if let o = autoOpening, o.stable {
      picked = o
    } else if let last = lastStableOpening, now.timeIntervalSince(last.at) <= Self.stableGrace {
      picked = last.opening
    } else if let o = autoOpening, !autoSamples.isEmpty {
      picked = o
      settled = false
    }
    guard let found = picked else {
      diag("auto \(mode.label.lowercased()): ✓ tapped, nothing detected")
      lightHaptics.impactOccurred()
      flash(mode == .door
            ? "No door found yet. Point at the middle of the door with the whole frame and the floor below it in view."
            : "No window found yet. Point at the middle of the window with the whole frame in view.")
      return
    }
    let isDoor = mode == .door
    let fy = snap.floorY
    // A door stands on the floor when it is known.
    let base = isDoor ? (fy ?? found.bottom) : found.bottom
    let o = OpeningMark(type: isDoor ? Self.typeDoor : Self.typeWindow,
                        a: found.a.withY(base), b: found.b.withY(base), topY: found.top,
                        method: OpeningMethod.auto.code, estimated: found.estimated || !settled)
    let centre = ((o.a + o.b) / 2).withY((base + found.top) / 2)
    // The same door / window counted already (e.g. found during the room
    // scan): this one, as accepted or adjusted, replaces it.
    let dup = RoomOpeningCounter.duplicateOf(
      RoomOpeningCounter.centre(found.a, found.b, bottom: found.bottom, top: found.top),
      openingCentres(o.type))
    if let dup {
      openings[dup] = o
    } else {
      openings.append(o)
      // One entry: Undo removes the whole opening.
      history.append(Self.hOpening)
    }
    if let shot = lastOpeningShot { writeOpeningDiag(shot, accepted: true) }
    resetAutoSearch()
    autoSuppress = (centre, Date().addingTimeInterval(2))
    diag("\(mode.label.lowercased()) \(openings.count) (auto, wall \(lastOpeningShot?.source ?? "-")"
      + "\(o.estimated ? ", estimated" : "")\(byHand ? ", adjusted by hand" : "")): \(openingSize(o, fy))")
    notifyHaptics.notificationOccurred(.success)
    // The scan goes on: point at the next door / window, or tap Finish.
    flash("\(mode.label) \(dup != nil ? "updated" : "added"): \(openingText(o, fy))  ·  \(elementsSummary() ?? "")"
      + (settled ? "" : ". The frame had not settled: check its size on the plan."))
    overlay.setNeedsDisplay()
  }

  /// Writes the rectified image of an attempt (opening_<ms>.png, 8-bit
  /// grey) and what the detector made of it (opening_<ms>.json) to the
  /// diagnostics folder, keeping the newest 30 pairs. Failures are ignored:
  /// these files are only for tuning.
  private func writeOpeningDiag(_ shot: OpeningShot, accepted: Bool) {
    lastOpeningDiagWrite = Date()
    let ms = Int64(Date().timeIntervalSince1970 * 1000)
    diagQueue.async { Self.writeOpeningFiles(shot, accepted: accepted, ms: ms) }
  }

  private static func writeOpeningFiles(_ s: OpeningShot, accepted: Bool, ms: Int64) {
    guard let dir = diagFolder() else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let img = s.image
    var grey = [UInt8](repeating: 0, count: img.width * img.height)
    for i in grey.indices {
      let v = img.pixels[i]
      grey[i] = v.isNaN ? 0 : UInt8(max(0, min(255, v.rounded())))
    }
    if let provider = CGDataProvider(data: Data(grey) as CFData),
       let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 8,
                        bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
       let png = UIImage(cgImage: cg).pngData() {
      try? png.write(to: dir.appendingPathComponent("opening_\(ms).png"), options: .atomic)
    }
    func num(_ v: Float, _ digits: Int16 = 3) -> Any {
      if !v.isFinite { return NSNull() }
      let scaled = (Double(v) * pow(10, Double(digits))).rounded()
      return NSDecimalNumber(mantissa: UInt64(abs(scaled)), exponent: -digits, isNegative: scaled < 0)
    }
    func xyz(_ p: V3) -> [Any] { [num(p.x), num(p.y), num(p.z)] }
    let w = s.wall
    var candidate: Any = NSNull()
    if let c = s.analysis.candidate {
      candidate = ["left": num(c.left), "right": num(c.right), "bottom": num(c.bottom),
                   "top": num(c.top), "strength": num(c.strength, 2)] as [String: Any]
    }
    let json: [String: Any] = [
      "kind": s.kind == .door ? "door" : "window",
      "accepted": accepted,
      "wallSource": s.source,
      "estimated": w.estimated,
      "floorY": w.floorY.map { num($0) } ?? NSNull(),
      "origin": xyz(w.origin),
      "normal": xyz(w.normal),
      "region": ["u0": num(img.u0), "u1": num(img.u0 + Float(img.width) * RectifiedImage.cell),
                 "v0": num(img.vTop - Float(img.height) * RectifiedImage.cell), "v1": num(img.vTop)],
      "candidate": candidate,
      "failure": s.analysis.failure,
      "columnProfile": s.analysis.columnProfile.map { num($0, 2) },
      "rowProfile": s.analysis.rowProfile.map { num($0, 2) },
    ]
    if let data = try? JSONSerialization.data(withJSONObject: json) {
      try? data.write(to: dir.appendingPathComponent("opening_\(ms).json"), options: .atomic)
    }
    // Keep the newest 30 pairs.
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
    func stamp(_ name: String) -> Int64? {
      guard name.hasPrefix("opening_"), let dot = name.lastIndex(of: ".") else { return nil }
      return Int64(name[name.index(name.startIndex, offsetBy: 8)..<dot])
    }
    let stamps = Set(names.compactMap(stamp)).sorted(by: >)
    let old = Set(stamps.dropFirst(30))
    for name in names {
      if let t = stamp(name), old.contains(t) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
      }
    }
  }

  /// openingSize, marked "≈ " when the opening's size is approximate.
  private func openingText(_ o: OpeningMark, _ floorY: Float?) -> String {
    (o.estimated ? "≈ " : "") + openingSize(o, floorY)
  }

  private func fmt(_ v: Float?) -> String {
    v.map { String(format: "%.2f", $0) } ?? "-"
  }

  /// Records where the camera is and which way it looks, for the guidance,
  /// the completion rules and the mini-map.
  private func noteCamera(_ origin: V3, _ dir: V3, at time: TimeInterval) {
    camNow = origin
    camDir = dir
    // Looking straight down or up says nothing about which wall was seen.
    if abs(dir.y) < 0.85 {
      let a = atan2(dir.z, dir.x) + Float.pi
      let n = Self.sectorCount
      sectors[min(max(Int(a / (2 * Float.pi) * Float(n)), 0), n - 1)] = true
    }
    camMinX = min(camMinX, origin.x)
    camMaxX = max(camMaxX, origin.x)
    camMinZ = min(camMinZ, origin.z)
    camMaxZ = max(camMaxZ, origin.z)
    if (lastPathSample < 0 || time - lastPathSample >= 0.5) && camPath.count < 2 * Self.maxPathSamples {
      lastPathSample = time
      camPath.append(origin.x)
      camPath.append(origin.z)
    }
  }

  private func isCeiling(_ p: ARPlaneAnchor) -> Bool {
    if case .ceiling = p.classification { return true }
    return false
  }

  private func isFurniture(_ p: ARPlaneAnchor) -> Bool {
    switch p.classification {
    case .table, .seat: return true
    default: return false
    }
  }

  /// Adds this frame's feature points (within 6 m) to `cloud` and returns them.
  private func collectPoints(_ frame: ARFrame, _ cam: V3) -> [V3] {
    guard let pc = frame.rawFeaturePoints else { return [] }
    let pts = pc.points
    let ids = pc.identifiers
    var seen = [V3]()
    seen.reserveCapacity(pts.count)
    for i in 0..<min(pts.count, ids.count) {
      let p = pts[i]
      if !(p.x.isFinite && p.y.isFinite && p.z.isFinite) { continue }
      if p.dist2d(cam) > 6 { continue }
      seen.append(p)
      let id = ids[i]
      if cloud.count >= Self.maxCloud && cloud[id] == nil { continue }
      cloud[id] = p
    }
    return seen
  }

  /// Floor height from points: the lowest well-filled 5 cm layer between
  /// 0.6 m and 2.2 m below the phone.
  private func estimateFloor(_ pts: [V3], camY: Float) -> Float? {
    // No lower than 1.85 m under the phone: nobody holds it higher. Depth
    // noise under desks made a "floor" 2.2 m down, so every line drawn and
    // the room height were wrong.
    let lo = camY - 1.85
    var bins = [Int](repeating: 0, count: 32)
    var n = 0
    for p in pts {
      let dy = p.y - lo
      if dy < 0 || p.y > camY - 0.6 { continue }
      bins[min(max(Int(dy / 0.05), 0), 31)] += 1
      n += 1
    }
    if n < 80 { return nil }
    var smooth = [Int](repeating: 0, count: 32)
    for i in 0..<32 {
      var s: Int = bins[i]
      if i > 0 { s += bins[i - 1] }
      if i < 31 { s += bins[i + 1] }
      smooth[i] = s
    }
    let best = smooth.max() ?? 0
    if best < 40 { return nil }
    let threshold = max(40, Int(Float(best) * 0.4))
    guard let i = smooth.indices.first(where: { smooth[$0] >= threshold }) else { return nil }
    // At the bottom of the range: the points go on below it, so this is the
    // edge of depth noise, not a floor (a floor has little under it).
    if i <= 1 { return nil }
    var sum: Float = 0
    var cnt = 0
    for j in max(0, i - 1)...min(31, i + 1) {
      sum += Float(bins[j]) * (lo + (Float(j) + 0.5) * 0.05)
      cnt += bins[j]
    }
    return cnt > 0 ? sum / Float(cnt) : nil
  }

  private func logScanState(_ planes: Int, _ walls: Int, _ points: Int, _ floorY: Float,
                            _ floorSource: String, _ room: AutoRoom?) {
    let r = room.map {
      String(format: "%d corners %.2f x %.2f m, area %.2f m², estimated sides %d, height %@",
             $0.corners.count, $0.width, $0.depth, $0.area, $0.estimatedCount, fmt($0.height))
    } ?? "none"
    let pointsRounded: Int = points / 500 * 500
    let floorText: String = String(format: "floorY=%.2f", floorY)
    let msg: String = "surfaces=\(planes) walls=\(walls) points~\(pointsRounded) \(floorText) (\(floorSource)) room: \(r)"
    if msg != lastScanLog {
      lastScanLog = msg
      diag("scan: \(msg)")
    }
  }

  /// Floor = lowest large horizontal surface well below the phone; ceiling =
  /// largest horizontal surface above it.
  private func detectFloorAndCeiling(_ planes: [ARPlaneAnchor], camY: Float) {
    var floor: Float?
    var floorArea: Float = 0
    var ceiling: Float?
    var ceilingArea: Float = 0
    for p in planes where p.alignment == .horizontal {
      let y = p.transform.columns.3.y
      let area = p.planeExtent.width * p.planeExtent.height
      if area < 0.2 { continue }
      if isCeiling(p) || y > camY + 0.2 {
        if y >= camY + 0.2 && area > ceilingArea {
          ceiling = y
          ceilingArea = area
        }
      } else if y <= camY - 0.5 && !isFurniture(p) {
        if let f = floor {
          if y < f - 0.08 || (abs(y - f) <= 0.08 && area > floorArea) {
            floor = y
            floorArea = area
          }
        } else {
          floor = y
          floorArea = area
        }
      }
    }
    if let floor { planeFloorY = floor }
    if let ceiling { ceilingY = ceiling }
  }

  private func wallSegment(normal: V3, cx: Float, cz: Float, pts: [V3]) -> WallSegment? {
    let nl = (normal.x * normal.x + normal.z * normal.z).squareRoot()
    if nl < 0.5 || pts.isEmpty { return nil }
    let dx = -normal.z / nl
    let dz = normal.x / nl
    var tMin = Float.greatestFiniteMagnitude
    var tMax = -Float.greatestFiniteMagnitude
    for p in pts {
      let t = (p.x - cx) * dx + (p.z - cz) * dz
      tMin = min(tMin, t)
      tMax = max(tMax, t)
    }
    if tMax - tMin < 0.25 { return nil }
    return WallSegment(cx: cx, cz: cz, dx: dx, dz: dz, tMin: tMin, tMax: tMax,
                       top: pts.map { $0.y }.max()!)
  }

  /// Corners where two detected walls (at least 50 degrees apart) meet.
  private func findCorners(_ walls: [WallSegment], y: Float) -> [V3] {
    var out = [V3]()
    let reach: Float = 0.6
    for i in walls.indices {
      for j in walls.indices where j > i {
        let a = walls[i]
        let b = walls[j]
        let denom = a.dx * b.dz - a.dz * b.dx
        if abs(denom) < 0.766 { continue } // sin(50 deg)
        let wx = b.cx - a.cx
        let wz = b.cz - a.cz
        let ta = (wx * b.dz - wz * b.dx) / denom
        let tb = (wx * a.dz - wz * a.dx) / denom
        if ta < a.tMin - reach || ta > a.tMax + reach { continue }
        if tb < b.tMin - reach || tb > b.tMax + reach { continue }
        let c = V3(a.cx + a.dx * ta, y, a.cz + a.dz * ta)
        if !out.contains(where: { $0.dist2d(c) < 0.15 }) { out.append(c) }
      }
    }
    return out
  }

  /// Point in polygon (local x, z), or within `margin` metres of its edge.
  private func inPolygon(_ poly: [V3], _ x: Float, _ z: Float, margin: Float) -> Bool {
    let n = poly.count
    var inside = false
    var j = n - 1
    for i in 0..<n {
      let xi = poly[i].x, zi = poly[i].z
      let xj = poly[j].x, zj = poly[j].z
      if (zi > z) != (zj > z) && x < (xj - xi) * (z - zi) / (zj - zi) + xi { inside.toggle() }
      j = i
    }
    if inside || margin <= 0 { return inside }
    j = n - 1
    for i in 0..<n {
      let ax = poly[j].x, az = poly[j].z
      let ex = poly[i].x - ax, ez = poly[i].z - az
      let len2 = ex * ex + ez * ez
      let t = len2 > 0 ? min(max(((x - ax) * ex + (z - az) * ez) / len2, 0), 1) : 0
      let px = ax + ex * t - x
      let pz = az + ez * t - z
      if px * px + pz * pz <= margin * margin { return true }
      j = i
    }
    return false
  }

  // ------------------------------------------------------------ measuring logic

  /// The automatic outline is used unless Corners mode was chosen.
  private func useAutoRoom() -> Bool { !manualOutline }

  private func resolveAim(_ snap: Snapshot) -> Aim? {
    // Held still, the median of the last few frames' hits: one frame's
    // depth / tracking noise no longer goes into the measurement.
    guard let latest = snap.hit else { return nil }
    let hit = aimSmoother.point(latest)
    if mode == .corner {
      if corners.count >= 3 && hit.dist2d(corners[0]) < 0.25 {
        return Aim(p: corners[0], snappedCorner: true, closesRoom: true)
      }
      if let c = snap.cornerCandidates.min(by: { $0.dist2d(hit) < $1.dist2d(hit) }),
         c.dist2d(hit) < 0.3 {
        return Aim(p: V3(c.x, hit.y, c.z), snappedCorner: true, closesRoom: false,
                   estimated: snap.hitEstimated)
      }
    }
    return Aim(p: hit, snappedCorner: false, closesRoom: false, estimated: snap.hitEstimated)
  }

  private func perimeter() -> Float {
    var s: Float = 0
    if corners.count >= 2 {
      for i in 1..<corners.count { s += corners[i - 1].dist2d(corners[i]) }
    }
    if corners.count >= 3 { s += corners.last!.dist2d(corners[0]) }
    return s
  }

  private func area() -> Float {
    if corners.count < 3 { return 0 }
    var s: Float = 0
    for i in corners.indices {
      let a = corners[i]
      let b = corners[(i + 1) % corners.count]
      s += a.x * b.z - b.x * a.z
    }
    return abs(s) / 2
  }

  private func m(_ v: Float) -> String { String(format: "%.2f m", v) }

  /// Height a door or window is measured from: doors stand on the floor
  /// (when it is known), windows on their sill as tapped.
  private func openingBaseY(_ type: Int, _ a: V3, _ b: V3, _ floorY: Float?) -> Float {
    if type == Self.typeDoor, let floorY { return floorY }
    return (a.y + b.y) / 2
  }

  private func openingHeight(_ o: OpeningMark, _ floorY: Float?) -> Float? {
    // A touched door's base is its own floor-level taps (see
    // placeOpeningTouch), not the detected floor.
    let touched = o.method == OpeningMethod.touch.code
    return o.topY.map { $0 - openingBaseY(touched ? Self.typeWindow : o.type, o.a, o.b, floorY) }
  }

  /// Window sill above the floor, when the floor is known.
  private func openingSill(_ o: OpeningMark, _ floorY: Float?) -> Float? {
    guard o.type == Self.typeWindow, let floorY else { return nil }
    return (o.a.y + o.b.y) / 2 - floorY
  }

  /// "0.82 × 2.03 m", or just the width when the top was not marked.
  private func openingSize(_ o: OpeningMark, _ floorY: Float?) -> String {
    let w = o.a.dist2d(o.b)
    guard let h = openingHeight(o, floorY) else { return m(w) }
    return String(format: "%.2f × %.2f m", w, h)
  }

  /// "1.24 m", or with its horizontal and vertical parts when the two points
  /// differ clearly in both: "1.24 m  (↔ 1.10 m  ↕ 0.57 m)".
  private func lineText(_ a: V3, _ b: V3) -> String {
    let d = simd_length(b - a)
    let across = a.dist2d(b)
    let rise = abs(b.y - a.y)
    if rise > 0.05 && across > 0.05 { return "\(m(d))  (↔ \(m(across))  ↕ \(m(rise)))" }
    return m(d)
  }

  private func flash(_ msg: String) {
    flashMessage = msg
    flashUntil = Date().addingTimeInterval(2.6)
    refreshUi()
  }

  private func instruction(_ snap: Snapshot?) -> String {
    guard let snap else { return "Starting camera..." }
    if !snap.tracking {
      // The camera pressed against a wall sees nothing to track.
      if touching && everTracked {
        return "Tracking lost. Keep the camera's view clear and move slowly."
      }
      return snap.trackingHint
    }
    // A line runs between any two points; it does not need the floor. Nor
    // do doors and windows found automatically or touched (a door's bottom
    // is then estimated).
    if snap.floorY == nil && mode != .auto && mode != .line && !(openingMode && openingMethod != .manual) {
      return "Point the camera at the floor and move the phone slowly from side to side until the floor is highlighted."
    }
    switch mode {
    case .auto:
      // The most common reason for a scan that never completes: without a
      // depth sensor, distance comes from sideways movement only.
      if sectorsCovered >= Self.spotSectors && moveExtent < Self.spotMove
          && (snap.autoRoom?.estimatedCount ?? 1) > 0 {
        return "Walls aren't measured by turning on the spot: walk slowly along them with the phone facing them. "
          + "Or tap Corners to mark each corner from where you stand."
      }
      guard let room = snap.autoRoom else {
        return snap.wallCount == 0
          ? "Walk slowly around the room, about 1–2 m from the walls, with the phone facing the wall. Keep the floor's edge in view. Doors and windows in view are counted automatically."
          : "Keep walking along the walls. The outline appears once enough of them are measured."
      }
      let n = room.estimatedCount
      if n > 0 {
        return "Room found. \(n) dashed side\(n == 1 ? " is" : "s are") estimated. Point the camera at \(n == 1 ? "that wall" : "those walls") to measure \(n == 1 ? "it" : "them"), or tap Finish."
      }
      let counted = elementsSummary().map { " (\($0))" } ?? ""
      return "All walls found\(counted). Tap Finish, or point at any door or window not counted yet."
    case .corner:
      switch corners.count {
      case 0: return "Aim the crosshair where two walls meet the floor, then tap the button to mark the first corner."
      case 1, 2: return "Aim at the next corner, going round the room in order, and mark it. You can stay where you are."
      default: return "Mark the next corner. To close the room, aim at the first corner or tap Finish."
      }
    case .door, .window:
      return autoInstruction()
    case .surface:
      switch pending.count {
      case 0: return "Step 1 of 3: aim at one corner of the surface (wall section, worktop, cabinet front or floor area) and tap the button."
      case 1: return "Step 2 of 3: aim at the next corner along one edge and tap the button."
      default: return "Step 3 of 3: aim at any point on the opposite edge and tap the button."
      }
    case .line:
      if lineMethod == .touch {
        return pending.isEmpty
          ? "Put one corner of the phone on the first point and tap the button. Don't cover the camera."
          : (touchTurned(snap)
              ? "The phone has been turned. Turn it back the way it was at the first point, then put the SAME corner on the second point."
              : "Slide the phone to the second point WITHOUT turning it, with the SAME corner on the point (not the other side of the phone), and tap.")
      }
      return pending.isEmpty
        ? "Tap the first point on the screen, or aim the crosshair at it and press the button."
        : "Tap the second point. The distance updates as you move."
    }
  }

  /// Door / Window mode, Auto: what the search is doing.
  private func autoInstruction() -> String {
    let isDoor = mode == .door
    if adjusted != nil {
      return "Drag a side's circle (or its line) onto the \(isDoor ? "door" : "window")'s frame: "
        + "only that side moves. Then tap ✓. Undo goes back to automatic."
    }
    if autoWallMissing {
      return "Point at the wall around the \(isDoor ? "door" : "window") so it can be found."
    }
    if let found = autoOpening {
      return found.stable
        ? "\(isDoor ? "Door" : "Window") found. Tap ✓ to add it."
        : "Hold still…"
    }
    if Date().timeIntervalSince(autoNothingSince) > 3 {
      return "Can't find the frame edges. Step back so the whole frame is in view."
    }
    return isDoor
      ? "Point at the middle of the door. Keep the whole frame and the floor below it in view."
      : "Point at the middle of the window. Keep the whole window frame, and the bottom of the wall below it if you can, in view."
  }

  @objc private func onMark() {
    guard let snap = snapshot, snap.tracking, !completed else { return }
    if touching {
      // The phone itself is the measuring tip: its position, not what the
      // crosshair points at.
      // The phone's position is tracked, never estimated.
      if pending.isEmpty {
        touchForward = snap.camForward
        touchUp = snap.camUp
      } else if touchTurned(snap) {
        // A turned phone moves its corner without moving the camera the
        // same way: the result would be off by up to the phone's size.
        flash("Turn the phone back the way it was at the first point, then tap.")
        return
      }
      if !placeLinePoint(snap.camPos, estimated: false, via: "touch") { return }
      haptics.impactOccurred()
      overlay.setNeedsDisplay()
      return
    }
    if openingAuto {
      acceptAutoOpening(snap)
      refreshUi()
      overlay.setNeedsDisplay()
      return
    }
    guard let aim = resolveAim(snap) else {
      flash(mode == .line
            ? "Can't measure that spot. Move the phone a little, or aim at a spot with more detail."
            : "Can't measure that spot. Aim at the floor or a highlighted wall.")
      return
    }
    switch mode {
    case .auto:
      return
    case .corner:
      if aim.closesRoom {
        onDone()
        return
      }
      let last = corners.last
      if let last, last.dist2d(aim.p) < 0.1 {
        flash("That is the same corner. Aim at the next one.")
        return
      }
      corners.append(aim.p)
      history.append(Self.hCorner)
      flash(last.map { "Wall \(corners.count - 1): \(m($0.dist2d(aim.p)))" } ?? "First corner marked")
    case .door, .window:
      // Always automatic (acceptAutoOpening above).
      return
    case .surface:
      switch pending.count {
      case 0:
        pending = [aim.p]
        history.append(Self.hEdge)
        flash("First corner marked")
      case 1:
        let w = simd_length(aim.p - pending[0])
        if w < 0.1 {
          flash("That is the same corner. Aim at the next corner along the edge.")
          return
        }
        pending.append(aim.p)
        history.append(Self.hBase)
        flash("Edge \(m(w)). Now aim at the opposite edge.")
      default:
        let s = SurfaceMark(a: pending[0], b: pending[1], c: aim.p)
        if s.height < 0.1 {
          flash("That point is on the first edge. Aim at the opposite edge of the surface.")
          return
        }
        surfaces.append(s)
        pending.removeAll()
        history.removeLast(2)
        history.append(Self.hSurface)
        flash(String(format: "Surface added: %.2f × %.2f m", s.width, s.height))
      }
    case .line:
      if !placeLinePoint(aim.p, estimated: aim.estimated, via: "aim") { return }
    }
    haptics.impactOccurred()
    overlay.setNeedsDisplay()
  }

  /// Adds a point of a line: its first end, or the second one completing
  /// it. `via` is how it was given: "aim" (crosshair and button), "tap" (a
  /// tap on the screen) or "touch" (the phone's own position). False when
  /// the point was refused.
  /// Touch method: how the phone was turned when the first point was set.
  private var touchForward = V3(0, 0, -1)
  private var touchUp = V3(0, 1, 0)

  /// Touch method (Line, Door or Window) with the first point set: the
  /// phone has since been turned by more than about 12 degrees. The method measures how far the phone
  /// moved, which is only the distance between the two points when the same
  /// corner touches both and the phone is not turned in between.
  private func touchTurned(_ snap: Snapshot?) -> Bool {
    guard let snap, touching, !pending.isEmpty else { return false }
    let limit: Float = 0.978 // cos(12 degrees)
    return simd_dot(snap.camForward, touchForward) < limit || simd_dot(snap.camUp, touchUp) < limit
  }

  private func placeLinePoint(_ p: V3, estimated: Bool, via: String) -> Bool {
    if let a = pending.first {
      let l = LineMark(a: a, b: p, aEstimated: lineStartEstimated, bEstimated: estimated)
      if l.length < 0.01 {
        switch via {
        case "touch": flash("Move the phone to the second point first.")
        case "tap": flash("Tap a different point for the other end.")
        default: flash("Aim at a different point for the other end.")
        }
        return false
      }
      lines.append(l)
      pending.removeAll()
      // The two taps become one entry; undoing it re-opens the line.
      history.removeLast()
      history.append(Self.hLine)
      diag("line \(lines.count) (\(via)\(l.estimated ? ", estimated" : "")): \(m(l.length))")
      flash("Line added: \(l.estimated ? "≈ " : "")\(lineText(l.a, l.b))")
    } else {
      pending = [p]
      lineStartEstimated = estimated
      history.append(Self.hEdge)
      flash("First point marked")
    }
    return true
  }

  // ------------------------------------------------------------ taps on the camera view

  /// Taps on the scene place line points only in Line mode with the Aim
  /// method (Touch marks the phone's own position; other modes use the
  /// crosshair).
  private var tapEnabled: Bool { mode == .line && lineMethod == .aim && !completing && !completed }

  /// A touch on one of the cards is not a tap on the scene. Some of them
  /// (labels, the gaps of a stack) would otherwise let it through.
  /// The camera view takes touches: line points (Line, Aim), or dragging
  /// the door / window frame found (Door / Window, Auto).
  private var touchEnabled: Bool { tapEnabled || (openingAuto && !completing && !completed) }

  fileprivate func tapAllowed(at p: CGPoint) -> Bool {
    for v in [topStack, bottomPanel, completionCard] {
      if let v, !v.isHidden, v.convert(v.bounds, to: tapView).contains(p) { return false }
    }
    // Room scan: a tap on the 2D plan or on the small map switches them.
    if planToggleHit(p) { return true }
    if !touchEnabled { return false }
    // Door / Window: only on the frame's circles and lines; elsewhere the
    // touch goes on to the controls below as before.
    if !tapEnabled { return openingHit(at: p) != nil }
    return true
  }

  /// The side (OpeningFrameAdjust: 0 bottom, 1 right, 2 top, 3 left) of the
  /// door / window frame shown under a finger at `p`: by its handle (the
  /// circle in the middle of each side) or anywhere along its line.
  private func openingHit(at p: CGPoint) -> Int? {
    guard openingAuto, let vp = snapshot?.viewProj, let o = shownOpening else { return nil }
    let size = tapView.bounds.size
    let corners = [o.a, o.b, o.b.withY(o.top), o.a.withY(o.top)]
    let s: [SIMD2<Float>?] = corners.map { c in
      project(vp, c, size).map { SIMD2<Float>(Float($0.x), Float($0.y)) }
    }
    return OpeningFrameAdjust.pickSide(s, SIMD2<Float>(Float(p.x), Float(p.y)),
                                       handleRadius: 36, lineRadius: 24)
  }

  /// Where a finger at `p` meets the wall of `adj`: (u along the wall,
  /// height), or nil when the line of sight runs along the wall or the hit
  /// is behind / too far.
  private func wallHit(_ adj: AdjustedOpening, _ p: CGPoint) -> (u: Float, v: Float)? {
    guard let frame = sceneView.session.currentFrame, let (o, d) = screenRay(p, frame) else { return nil }
    // The wall: vertical, through the bottom corners, normal across `along`.
    let n = V3(-adj.along.z, 0, adj.along.x)
    let den = d.x * n.x + d.z * n.z
    if abs(den) < 0.05 { return nil }
    let t = ((adj.origin.x - o.x) * n.x + (adj.origin.z - o.z) * n.z) / den
    if t <= 0.1 || t > 15 { return nil }
    let q = o + d * t
    return ((q.x - adj.origin.x) * adj.along.x + (q.z - adj.origin.z) * adj.along.z, q.y)
  }

  /// A finger down on the frame found grabs that side; the frame then
  /// stays as the user leaves it.
  private func grabOpening(at p: CGPoint) {
    guard let side = openingHit(at: p), let o = shownOpening else { return }
    if adjusted == nil {
      let d = o.b - o.a
      let len = (d.x * d.x + d.z * d.z).squareRoot()
      if len < 0.05 { return }
      adjusted = AdjustedOpening(origin: o.a.withY(0), along: V3(d.x / len, 0, d.z / len),
                                 left: 0, right: len, bottom: o.bottom, top: o.top, estimated: o.estimated)
      diag("auto \(mode.label.lowercased()): adjusting by hand")
    }
    guard let adj = adjusted else { return }
    // Keep where the side is relative to the finger: it follows the
    // finger's movement from here instead of jumping onto it.
    if let hit = wallHit(adj, p) {
      let value = OpeningFrameAdjust.sideValue(side, left: adj.left, right: adj.right,
                                               bottom: adj.bottom, top: adj.top)
      adjustOffset = value - (OpeningFrameAdjust.isVertical(side) ? hit.u : hit.v)
    } else {
      adjustOffset = 0
    }
    adjustGrab = side
    lightHaptics.impactOccurred()
  }

  /// The held side follows the finger, on the frame's wall. Only that side
  /// moves: the opposite and adjacent sides stay where they are.
  private func dragOpening(to p: CGPoint) {
    guard var adj = adjusted, adjustGrab >= 0, let hit = wallHit(adj, p) else { return }
    let side = adjustGrab
    let value = (OpeningFrameAdjust.isVertical(side) ? hit.u : hit.v) + adjustOffset
    let e = OpeningFrameAdjust.moveSide(side, to: value, left: adj.left, right: adj.right,
                                        bottom: adj.bottom, top: adj.top)
    adj.left = e.left
    adj.right = e.right
    adj.bottom = e.bottom
    adj.top = e.top
    adjusted = adj
  }

  private func linePick(at p: CGPoint) -> (point: V3, estimated: Bool)? {
    guard let frame = sceneView.session.currentFrame else { return nil }
    return pick(at: p, frame: frame, lineTap: true)
  }

  /// A finger went down on the camera view (`began`) or moved on it.
  /// Room scan: `p` (tap view) is on the 2D plan or the small map.
  private func planToggleHit(_ p: CGPoint) -> Bool {
    guard mode == .auto || mode == .corner, !lineOnly else { return false }
    let q = tapView.convert(p, to: overlay)
    return planRect.contains(q) || miniRect.contains(q)
  }

  fileprivate func tapMoved(to p: CGPoint, began: Bool) {
    if planToggleHit(p) {
      if began {
        planBig.toggle()
        lightHaptics.impactOccurred()
        overlay.setNeedsDisplay()
      }
      return
    }
    if !tapEnabled {
      // Door / Window: dragging the frame found.
      if began { grabOpening(at: p) } else { dragOpening(to: p) }
      overlay.setNeedsDisplay()
      return
    }
    if !began && tapPreview == nil { return }
    let now = CACurrentMediaTime()
    if began || now - lastTapPick >= 1.0 / 30 {
      lastTapPick = now
      tapPreview = TapPreview(at: p, pick: linePick(at: p))
    } else {
      // Between picks the ring still follows the finger exactly.
      tapPreview = TapPreview(at: p, pick: tapPreview?.pick)
    }
    failedTap = nil
    overlay.setNeedsDisplay()
  }

  /// The finger was lifted: the point under it is placed.
  fileprivate func tapEnded(at p: CGPoint) {
    if adjustGrab >= 0 {
      adjustGrab = -1
      overlay.setNeedsDisplay()
      return
    }
    if tapPreview == nil { return }
    tapPreview = nil
    defer { overlay.setNeedsDisplay() }
    if !tapEnabled { return }
    // Where the finger is now, not where it last was picked.
    if let r = linePick(at: p) {
      if placeLinePoint(r.point, estimated: r.estimated, via: "tap") { haptics.impactOccurred() }
    } else {
      failedTap = (p, Date().addingTimeInterval(1.5))
      flash("Can't tell how far that spot is. Move the phone a little sideways and tap again, or use Touch.")
    }
  }

  fileprivate func tapCancelled() {
    adjustGrab = -1
    tapPreview = nil
    overlay.setNeedsDisplay()
  }

  @objc private func onUndo() {
    if completing { cancelAutoComplete("undo tapped") }
    if adjusted != nil {
      // First undo drops the hand adjustment: the frame follows the
      // detections again.
      adjusted = nil
      adjustGrab = -1
      flash("Back to automatic")
      overlay.setNeedsDisplay()
      return
    }
    guard let last = history.popLast() else { return }
    switch last {
    case Self.hCorner: corners.removeLast()
    case Self.hEdge, Self.hBase: _ = pending.popLast()
    case Self.hOpening: openings.removeLast()
    case Self.hOpeningTop:
      // Back to the base marked, waiting for the top. The user may be in
      // another mode by now; the base belongs to the door / window mode.
      let o = openings.removeLast()
      mode = o.type == Self.typeDoor ? .door : .window
      resetAutoSearch()
      pending = [o.a, o.b]
      history.append(contentsOf: [Self.hEdge, Self.hBase])
    case Self.hSurface:
      let s = surfaces.removeLast()
      mode = .surface
      pending = [s.a, s.b]
      history.append(contentsOf: [Self.hEdge, Self.hBase])
    case Self.hLine:
      let l = lines.removeLast()
      mode = .line
      pending = [l.a]
      lineStartEstimated = l.aEstimated
      history.append(Self.hEdge)
    default: return
    }
    flash("Undone")
    refreshUi()
    overlay.setNeedsDisplay()
  }

  /// Ends the door, window, surface or line being marked when leaving it
  /// (mode switch, Finish). A door or window with both base points is kept
  /// without a height, so its width is not lost; anything less is dropped.
  private func commitPending() {
    if pending.isEmpty { return }
    let n = pending.count
    if n == 2 && (mode == .door || mode == .window) {
      let touched = openingMethod == .touch
      openings.append(OpeningMark(type: mode == .door ? Self.typeDoor : Self.typeWindow,
                                  a: pending[0], b: pending[1], topY: nil,
                                  method: touched ? OpeningMethod.touch.code : OpeningMethod.manual.code,
                                  estimated: touched && mode == .door && (planeFloorY ?? pointFloorY) == nil))
      history.removeLast(2)
      history.append(Self.hOpening)
    } else {
      history.removeLast(n)
    }
    pending.removeAll()
  }

  @objc private func onTab(_ sender: UIButton) {
    guard let md = Mode(rawValue: sender.tag), md != mode else { return }
    if completing { cancelAutoComplete("mode switched to \(md.label)") }
    if md == .corner { usedCorners = true }
    commitPending()
    mode = md
    resetAutoSearch()
    diag("mode \(md.label)")
    flashMessage = nil
    // Auto and Corners each measure the outline from scratch: switching
    // between them drops the other one's result.
    if md == .corner && !manualOutline {
      manualOutline = true
      flash("Mark the room's corners. The automatic outline is no longer used.")
    } else if md == .auto && manualOutline {
      manualOutline = false
      let had = !corners.isEmpty
      corners.removeAll()
      history.removeAll { $0 == Self.hCorner }
      flash(had ? "Marked corners cleared. Measuring the room automatically."
                : "Measuring the room automatically.")
    }
    refreshUi()
    overlay.setNeedsDisplay()
  }

  @objc private func onLineMethod() {
    guard let method = LineMethod(rawValue: methodControl.selectedSegmentIndex),
          method != lineMethod else { return }
    // A first point given the other way is dropped: the two ends of a line
    // are both aimed at or both touched.
    if mode == .line && !pending.isEmpty {
      history.removeLast(min(pending.count, history.count))
      pending.removeAll()
    }
    lineMethod = method
    diag("line method \(method == .touch ? "touch" : "aim")")
    flashMessage = nil
    refreshUi()
    overlay.setNeedsDisplay()
  }

  @objc private func onReset() {
    if completing { cancelAutoComplete("start over tapped") }
    let hasData = !corners.isEmpty || !openings.isEmpty || !surfaces.isEmpty || !lines.isEmpty
      || !pending.isEmpty || (autoRoom != nil && !lineOnly) || !photos.isEmpty
    if !hasData {
      resetScan()
      return
    }
    let alert = UIAlertController(
      title: "Start over?",
      message: lineOnly
        ? "This clears everything measured and starts again."
        : "This clears the room outline and every door, window, surface and line measured, and scans the room again.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Start over", style: .destructive) { _ in self.resetScan() })
    present(alert, animated: true)
  }

  // ------------------------------------------------------------ AR photo

  /// Takes a photo of the camera view with the room outline, doors,
  /// windows and surfaces drawn on it and the room size as a caption.
  @objc private func onPhoto() {
    guard let snap = snapshot, snap.tracking else {
      flash("Wait for tracking, then take the photo.")
      return
    }
    if lineOnly {
      if lines.isEmpty {
        flash("Measure a line first, then take the photo.")
        return
      }
    } else if useAutoRoom() && autoRoom == nil {
      flash("Keep panning across the walls until the room outline appears, then take the photo.")
      return
    } else if !useAutoRoom() && corners.count < 3 {
      flash("Mark at least 3 corners first.")
      return
    }
    let camera = sceneView.snapshot()
    let size = view.bounds.size
    if size.width <= 0 || size.height <= 0 { return }
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: size, format: format).image { rc in
      camera.draw(in: CGRect(origin: .zero, size: size))
      drawOverlay(rc.cgContext, size, forPhoto: true)
      drawPhotoCaption(photoCaption(), size)
    }
    guard let data = image.jpegData(compressionQuality: 0.88) else {
      flash("Could not save the photo.")
      return
    }
    let ms = Int64(Date().timeIntervalSince1970 * 1000)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("room_photo_\(ms).jpg")
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      diag("photo save failed: \(error.localizedDescription)")
      flash("Could not save the photo.")
      return
    }
    photos.append(url.path)
    diag("photo saved: \(url.lastPathComponent) (\(data.count / 1024) KB), \(photos.count) total")
    haptics.impactOccurred()
    flash("Photo saved with measurements (\(photos.count))")
  }

  /// "W × D m  ·  Area A m²" for the outline in use.
  private func photoCaption() -> String {
    let sep = "  ·  "
    var parts = [String]()
    if lineOnly { return lines.map { m($0.length) }.joined(separator: sep) }
    if useAutoRoom(), let room = autoRoom {
      parts.append(String(format: "%.2f × %.2f m", room.width, room.depth))
      parts.append(String(format: "Area %.2f m²", room.area))
    } else {
      parts.append(String(format: "Area %.2f m²", area()))
      parts.append("Perimeter \(m(perimeter()))")
    }
    return parts.joined(separator: sep)
  }

  private func drawPhotoCaption(_ text: String, _ size: CGSize) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
      .font: PlanoraFont.inter(16, .semibold, tabular: true),
      .foregroundColor: UIColor.white,
      .paragraphStyle: para,
    ]
    let margin: CGFloat = 16
    let padX: CGFloat = 16
    let padY: CGFloat = 10
    let maxW = size.width - 2 * margin - 2 * padX
    let s = text as NSString
    let tr = s.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            attributes: attrs, context: nil)
    let textH = ceil(tr.height)
    let barW = min(size.width - 2 * margin, ceil(tr.width) + 2 * padX)
    let barH = textH + 2 * padY
    let bottomInset = max(view.safeAreaInsets.bottom, 0) + margin
    let bar = CGRect(x: (size.width - barW) / 2, y: size.height - bottomInset - barH,
                     width: barW, height: barH)
    Self.ink.withAlphaComponent(0.78).setFill()
    UIBezierPath(roundedRect: bar, cornerRadius: min(18, barH / 2)).fill()
    s.draw(with: CGRect(x: bar.minX + padX, y: bar.minY + padY, width: bar.width - 2 * padX, height: textH),
           options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
  }

  private func deletePhotos() {
    for p in photos { try? FileManager.default.removeItem(atPath: p) }
    photos.removeAll()
  }

  /// Clears every measurement and restarts tracking, so the room is scanned
  /// again from scratch.
  private func resetScan() {
    // The scan being thrown away keeps its diagnostics file; the new one
    // starts its own.
    writeDiag(force: true)
    beginDiagScan()
    scanGeneration += 1
    furniture.clear()
    planeFloorY = nil
    pointFloorY = nil
    ceilingY = nil
    autoRoom = nil
    cloud.removeAll()
    camSumX = 0
    camSumY = 0
    camSumZ = 0
    camSamples = 0
    lastScanLog = ""
    sectors = [Bool](repeating: false, count: Self.sectorCount)
    camMinX = .greatestFiniteMagnitude
    camMaxX = -.greatestFiniteMagnitude
    camMinZ = .greatestFiniteMagnitude
    camMaxZ = -.greatestFiniteMagnitude
    camPath.removeAll()
    lastPathSample = -1
    camNow = nil
    lastWalls.removeAll()
    lastFloorPts.removeAll()
    lastCloud.removeAll()
    lastPlanes.removeAll()
    lastFloorUsed = nil
    lastFloorGuessed = false
    completionKind = "none"
    corners.removeAll()
    openings.removeAll()
    surfaces.removeAll()
    lines.removeAll()
    pending.removeAll()
    lineStartEstimated = false
    tapPreview = nil
    failedTap = nil
    history.removeAll()
    resetAutoSearch()
    autoSuppress = nil
    lastOpeningShot = nil
    everTracked = false
    deletePhotos()
    manualOutline = false
    mode = lineOnly ? .line : .auto
    snapshot = nil
    hideCompletionCard()
    completing = false
    focusOpening = nil
    usedCorners = false
    stableSince = nil
    stableCorners = 0
    autoRoomGuessedFloor = false
    if sessionStarted {
      sceneView.session.run(makeConfig(), options: [.resetTracking, .removeExistingAnchors])
    }
    diag("scan reset")
    flash(lineOnly ? "Starting over." : "Starting over. Walk slowly along the walls.")
    overlay.setNeedsDisplay()
  }

  @objc private func onDone() { finish(confirmed: false) }

  private func finish(confirmed: Bool) {
    let auto = snapshot?.autoRoom
    // An automatic outline that is mostly guesswork (half its sides or more
    // estimated) is not saved without asking: plain walls the camera can't
    // measure gave rooms like 4.6 × 0.9 m. Marking the corners works there.
    let mostlyGuessed = auto.map { $0.estimatedCount * 2 >= $0.corners.count } ?? false
    let noWalls = (snapshot?.wallCount ?? 0) == 0
    if !confirmed, !lineOnly, useAutoRoom(), let auto, mostlyGuessed || noWalls {
      if presentedViewController != nil { return }
      if completing { cancelAutoComplete("outline unreliable") }
      let measured = max(auto.corners.count - auto.estimatedCount, 0)
      diag("finish: outline unreliable (estimated \(auto.estimatedCount) of \(auto.corners.count), walls \(snapshot?.wallCount ?? 0)), asking")
      let why = mostlyGuessed
        ? "Only \(measured) of \(auto.corners.count) walls were measured; the rest of this outline is a guess"
        : "No wall was measured directly; this outline only comes from the edges of the floor and ceiling"
      let alert = UIAlertController(
        title: "Room not measured yet",
        message: why + ", so its size is probably wrong.\n\nPlain walls are hard for the camera. Mark the corners "
          + "instead: stand in the room, aim at each corner where the walls meet the floor and tap +.",
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Mark corners", style: .default) { _ in
        let b = UIButton()
        b.tag = Mode.corner.rawValue
        self.onTab(b)
      })
      alert.addAction(UIAlertAction(title: "Save anyway", style: .default) { _ in self.finish(confirmed: true) })
      alert.addAction(UIAlertAction(title: "Keep scanning", style: .cancel))
      present(alert, animated: true)
      return
    }
    let outline: [V3]
    // The result holds distances only, no room: asked for at the start, or
    // lines were measured in a normal scan before any room outline existed.
    var linesOnly = lineOnly
    // No room outline, but a door / window was measured (✓ finishes the
    // scan): it is returned on its own, without an outline.
    var openingsOnly = false
    if lineOnly {
      // Only distances were asked for: no room outline is needed.
      if lines.isEmpty && openings.isEmpty {
        flash("Measure a line first: mark its two points.")
        return
      }
      outline = []
    } else if !useAutoRoom() && corners.count >= 3 {
      outline = corners
    } else if useAutoRoom(), let auto {
      outline = auto.corners
    } else if !lines.isEmpty {
      outline = []
      linesOnly = true
    } else if !openings.isEmpty {
      outline = []
      openingsOnly = true
    } else if !useAutoRoom() {
      flash("Mark at least 3 corners, or switch to Auto.")
      return
    } else {
      diag("finish tapped, but no room found yet")
      flash("No room found yet. Keep walking along the walls, or mark the corners by hand.")
      return
    }
    commitPending()
    // Finish tapped, rather than the completion card running out.
    if !completing { completionKind = "manual" }
    let isAuto = !linesOnly && !openingsOnly && useAutoRoom()
    let floorY = snapshot?.floorY
    diag("finish: \(linesOnly ? "line-only, no" : (openingsOnly ? "openings-only, no" : (isAuto ? "auto" : "manual"))) outline "
      + outline.map { String(format: "(%.2f,%.2f)", $0.x, $0.z) }.joined(separator: " ")
      + ", openings \(openings.count) (\(openings.filter { $0.topY != nil }.count) with height, "
      + "\(openings.filter { $0.method == OpeningMethod.auto.code }.count) auto, "
      + "\(openings.filter { $0.method == OpeningMethod.touch.code }.count) touch)"
      + ", surfaces \(surfaces.count), lines \(lines.count), floorY \(fmt(floorY))")
    var out: [String: Any] = [
      "xs": outline.map { Double($0.x) },
      "zs": outline.map { Double($0.z) },
      "auto": isAuto,
      "estimated": isAuto ? (auto?.estimatedCount ?? 0) : 0,
      "openings": openings.flatMap {
        [Double($0.type), Double($0.a.x), Double($0.a.z), Double($0.b.x), Double($0.b.z)]
      },
      // Raw 3D points; Flutter computes the sizes. topY is -999 when the
      // top of the frame was not marked.
      "openingDetails": openings.flatMap { o -> [Double] in
        [Double(o.type), Double(o.a.x), Double(o.a.y), Double(o.a.z),
         Double(o.b.x), Double(o.b.y), Double(o.b.z), Double(o.topY ?? -999)]
      },
      // Per opening, in the same order: how it was measured (0 Manual,
      // 1 Auto, 2 Touch) and whether its size is approximate (0/1).
      "openingMethods": openings.map { $0.method },
      "openingEstimated": openings.map { $0.estimated ? 1 : 0 },
      "surfaces": surfaces.flatMap { s -> [Double] in
        [s.a, s.b, s.c].flatMap { [Double($0.x), Double($0.y), Double($0.z)] }
      },
      // Raw tapped points, 6 values per line: ax, ay, az, bx, by, bz.
      "lines": lines.flatMap { l -> [Double] in
        [l.a, l.b].flatMap { [Double($0.x), Double($0.y), Double($0.z)] }
      },
      // 0/1 per line, in the same order: an end was placed on an estimated
      // surface, so the length is approximate.
      "linesEstimated": lines.map { $0.estimated ? 1 : 0 },
      "lineOnly": linesOnly,
      // Annotated room photos (absolute JPEG paths); may be empty.
      "photos": photos,
      // Furniture found by the AI detector: 6 values each (centre x, z,
      // width, depth, height, direction of its width), kinds alongside.
      "elements": linesOnly ? [] : furniture.confirmed.flatMap { f -> [Double] in
        [Double(f.center.x), Double(f.center.z), Double(f.width), Double(f.depth), Double(f.height), Double(f.yaw)]
      },
      "elementKinds": linesOnly ? [] : furniture.confirmed.map { $0.kind },
      // Name of this scan's diagnostics file in Documents/room_measure/diag.
      "diagFile": diagFileName,
    ]
    if let floorY { out["floorY"] = Double(floorY) }
    // The door / window just added with ✓, which finished the scan: the app
    // shows its 2D front view first.
    if let f = focusOpening, f >= 0, f < openings.count {
      out["focusOpening"] = f
      diag("finish: focus opening \(f)")
    }
    finish(with: out)
  }

  private func refreshUi() {
    let snap = snapshot
    let tracking = snap?.tracking == true

    let status: String
    let room = snap?.autoRoom
    let measured = room.map { $0.corners.count - $0.estimatedCount } ?? 0
    if !tracking {
      status = "Initializing"
    } else if mode == .line {
      // Walls, floor and corners play no part in a distance.
      status = "Tracking ✓"
    } else if mode == .auto && completing {
      // First: the scan can complete with a side still estimated.
      status = "Room scanned ✓"
    } else if mode == .auto, let room, measured < room.corners.count {
      // Progress towards auto-completion: sides seen as real walls, and how
      // much of the full turn the camera has looked at.
      status = "Scanning  ·  \(measured) of \(room.corners.count) walls  ·  \(coveragePercent)% around"
    } else if mode == .auto && room == nil {
      status = "Scanning  ·  \(coveragePercent)% around"
    } else if mode == .auto && room != nil && !usedCorners && !lookedRound {
      status = "All walls found  ·  turn round for doors & windows  ·  \(coveragePercent)%"
    } else if mode == .auto && room != nil && snap?.floorY != nil {
      status = usedCorners
        ? "All walls found  ·  tap Finish"
        : "All walls found  ·  hold steady…"
    } else if snap?.floorY == nil && snap?.autoRoom != nil {
      status = "Room found  ·  tilt down to the floor"
    } else if snap?.floorY == nil {
      status = "Scanning  ·  include some floor"
    } else {
      let w = snap?.wallCount ?? 0
      let c = snap?.cornerCandidates.count ?? 0
      status = "Floor ✓  ·  \(w) wall\(w == 1 ? "" : "s")  ·  \(c) corner\(c == 1 ? "" : "s") found"
    }
    setIfChanged(statusLabel, status)

    let msg = (Date() < flashUntil ? flashMessage : nil) ?? instruction(snap)
    setIfChanged(hintLabel, msg)

    let auto = snap?.autoRoom
    setIfChanged(statsLabel, statsText(auto))

    // Touching marks the phone's own position: no surface is needed.
    // Door / Window: the button always responds while tracking (onMark says
    // why when it can't use the tap), so a tap is never silently ignored.
    setEnabled(markButton, markButton, mode != .auto && tracking
               && (openingMode || touching || snap?.hit != nil))
    let glyph = openingAuto ? "✓" : "+"
    if markGlyph.text != glyph {
      markGlyph.text = glyph
      markGlyph.font = openingAuto ? .systemFont(ofSize: 28, weight: .semibold) : .systemFont(ofSize: 34, weight: .light)
      markButton.accessibilityLabel = openingAuto ? "Add \(mode == .door ? "door" : "window")" : "Mark point"
    }
    // Door / Window found automatically and stable: the disc turns teal.
    let detected = openingAuto && (autoOpening?.stable == true || adjusted != nil)
    let disc = detected ? Self.snap : UIColor.white
    if markGlyph.backgroundColor != disc {
      markGlyph.backgroundColor = disc
      markGlyph.textColor = detected ? .white : Self.ink
    }
    if tapView.isUserInteractionEnabled != touchEnabled {
      tapView.isUserInteractionEnabled = touchEnabled
      // A finger still down when the mode or method changes places nothing.
      if !tapEnabled {
        tapPreview = nil
        failedTap = nil
      }
    }
    if methodControl.isHidden != (mode != .line) { methodControl.isHidden = mode != .line }
    if methodControl.selectedSegmentIndex != lineMethod.rawValue {
      methodControl.selectedSegmentIndex = lineMethod.rawValue
    }
    setEnabled(undoColumn, undoButton, !history.isEmpty || adjusted != nil)
    setEnabled(doneColumn, doneButton,
               // A measured line or door / window can be finished with on
               // its own, without a room outline.
               !lines.isEmpty || !openings.isEmpty || (!lineOnly && (useAutoRoom() ? auto != nil : corners.count >= 3)))
    // Finish is the primary action once it can be used.
    let doneBg = doneButton.isEnabled ? Self.accent : Self.sideFill
    if doneButton.backgroundColor != doneBg { doneButton.backgroundColor = doneBg }
    if tabsMode != mode {
      let first = tabsMode == nil
      tabsMode = mode
      scrollSelectedTabIntoView(animated: !first)
      for (md, b) in tabButtons {
        let on = md == mode
        b.backgroundColor = on ? .white : .clear
        b.setTitleColor(on ? Self.ink : UIColor(white: 1, alpha: 0.8), for: .normal)
      }
    }
  }

  /// Scrolls the tab row so the selected mode's tab is fully visible, with a
  /// little of its neighbours.
  private func scrollSelectedTabIntoView(animated: Bool) {
    guard let b = tabButtons[mode], tabScroll.bounds.width > 0 else { return }
    tabScroll.layoutIfNeeded()
    let frame = b.convert(b.bounds, to: tabScroll)
    if frame.width <= 0 { return }
    tabScroll.scrollRectToVisible(frame.insetBy(dx: -28, dy: 0), animated: animated)
  }

  // ------------------------------------------------------------ auto-completion

  /// Tracks how long the automatic outline has stayed the same size. A room
  /// that differs from the one the clock started with by more than the
  /// tolerance (or has a different corner count) restarts the clock. Whether
  /// the floor was found plays no part: the horizontal sizes do not depend
  /// on the floor height.
  private func noteRoomStability(_ room: AutoRoom) {
    func sideChanged(_ now: Float, _ then: Float) -> Bool {
      abs(now - then) > max(Self.stableSideMin, Self.stableSideShare * then)
    }
    let changed = room.corners.count != stableCorners
      || sideChanged(room.width, stableWidth)
      || sideChanged(room.depth, stableDepth)
      || abs(room.area - stableArea) > Self.stableArea
    if changed || stableSince == nil {
      stableSince = Date()
      stableWidth = room.width
      stableDepth = room.depth
      stableArea = room.area
      stableCorners = room.corners.count
    }
  }

  /// Which rule, if any, says the Auto scan is complete:
  ///  "a": every side measured as a real wall, on a detected floor, and the
  ///       outline steady for a moment.
  ///  "b": every side measured but no floor found, steady for longer: the
  ///       scan finishes without a height rather than never.
  ///  "c": the user has been all the way round, has really moved, and
  ///       nothing has changed for a long while. One side (two in a room
  ///       with more than 4 corners) may still be estimated; the result
  ///       says so.
  private func autoCompleteKind() -> String? {
    guard !lineOnly, mode == .auto, !manualOutline, !usedCorners, !completed, !completing,
          pending.isEmpty,
          snapshot?.tracking == true,
          // Not while a Start over / Discard question is open.
          presentedViewController == nil,
          let room = autoRoom, room.corners.count >= 4,
          let since = stableSince else { return nil }
    let steady = Date().timeIntervalSince(since)
    let estimated = room.estimatedCount
    // Doors and windows are only counted on walls the camera has looked at:
    // finishing as soon as the walls were found (often from a few corners)
    // ended the scan before most of them had been in view.
    if estimated == 0 && lookedRound {
      let floorKnown = !autoRoomGuessedFloor && (planeFloorY ?? pointFloorY) != nil
      if steady >= (floorKnown ? Self.stableFor : Self.stableForNoFloor) {
        return floorKnown ? "a" : "b"
      }
    }
    // Some walls measured as walls, not only outlined from the floor and
    // ceiling edges: turning on the spot gave a different size every time.
    if sectorsCovered >= Self.walkedSectors && moveExtent >= Self.walkedMove
        && (snapshot?.wallCount ?? 0) >= 2
        && steady >= Self.stableForWalked
        && estimated <= (room.corners.count == 4 ? 1 : 2) {
      return "c"
    }
    return nil
  }

  private func checkAutoComplete() {
    if let kind = autoCompleteKind() { startAutoComplete(kind) }
  }

  /// The camera has looked nearly all the way round the room (every wall in
  /// view at some point), so its doors and windows had their chance.
  private var lookedRound: Bool { sectorsCovered >= Self.lookRoundSectors }

  /// Shows the completion card briefly as feedback, then finishes exactly
  /// as the Finish button does (unless a mode switch, Undo, Start over,
  /// Close or lost tracking cancels it first). No confirmation is asked.
  private func startAutoComplete(_ kind: String) {
    // Never on an outline that is mostly guesswork: Finish asks about that.
    guard let room = autoRoom, room.estimatedCount * 2 < room.corners.count else { return }
    completing = true
    completionKind = kind
    diag(String(format: "auto-complete (%@): %d corners %.2f x %.2f m, area %.2f m², estimated sides %d, "
                  + "stable %.1f s, sectors %d/%d, moved %.2f m",
                kind, room.corners.count, room.width, room.depth, room.area, room.estimatedCount,
                Date().timeIntervalSince(stableSince ?? Date()),
                sectorsCovered, Self.sectorCount, moveExtent))
    notifyHaptics.notificationOccurred(.success)
    showCompletionCard(room)
    refreshUi()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.completing, !self.completed else { return }
      self.completionWork = nil
      self.onDone()
      // onDone only returns without finishing when there is no room; then
      // the user is back to scanning.
      if !self.completed {
        self.completing = false
        self.hideCompletionCard()
        self.refreshUi()
      }
    }
    completionWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.completeDelay, execute: work)
  }

  /// Stops a pending auto-finish (mode switch, Undo, Start over, Close,
  /// tracking lost). The outline must then be steady again for the full
  /// time before the scan finishes on its own.
  private func cancelAutoComplete(_ reason: String) {
    if !completing { return }
    completing = false
    completionKind = "cancelled"
    stableSince = nil
    hideCompletionCard()
    diag("auto-complete cancelled: \(reason)")
    refreshUi()
  }

  private func showCompletionCard(_ room: AutoRoom) {
    hideCompletionCard()
    // Teal check badge with a soft glow.
    let badge = UIView()
    badge.backgroundColor = Self.snap
    badge.layer.cornerRadius = Self.badgeSize / 2
    badge.layer.shadowColor = Self.snap.cgColor
    badge.layer.shadowOpacity = 0.55
    badge.layer.shadowRadius = 18
    badge.layer.shadowOffset = .zero
    let check = UIImageView(image: UIImage(systemName: "checkmark",
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)))
    check.tintColor = .white
    check.contentMode = .center
    check.translatesAutoresizingMaskIntoConstraints = false
    badge.addSubview(check)
    NSLayoutConstraint.activate([
      check.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
      check.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
      badge.widthAnchor.constraint(equalToConstant: Self.badgeSize),
      badge.heightAnchor.constraint(equalToConstant: Self.badgeSize),
    ])

    let title = UILabel()
    title.text = "Room scanned"
    title.font = PlanoraFont.inter(20, .bold)
    title.textColor = .white
    title.textAlignment = .center

    let sizeText = String(format: "%.2f × %.2f m · Area %.2f m²", room.width, room.depth, room.area)
    let size = UILabel()
    size.text = sizeText
    size.font = PlanoraFont.inter(15, .semibold, tabular: true)
    size.textColor = .white
    size.textAlignment = .center
    size.numberOfLines = 0

    // What the result lacks, so a scan that completed with less than
    // everything measured does not look like a perfect one.
    var caveats = [String]()
    let est = room.estimatedCount
    if est > 0 {
      caveats.append("\(est) wall\(est == 1 ? "" : "s") estimated — check \(est == 1 ? "it" : "them") on the plan")
    }
    // What was counted along the way (doors and windows).
    if let counts = elementsSummary() { caveats.append(counts) }
    let note = UILabel()
    note.text = caveats.joined(separator: "\n")
    note.font = PlanoraFont.inter(13, .medium)
    note.textColor = Self.door
    note.textAlignment = .center
    note.numberOfLines = 0
    note.isHidden = caveats.isEmpty

    let hint = UILabel()
    hint.text = "Opening your floor plan…"
    hint.font = PlanoraFont.inter(13, .regular)
    hint.textColor = UIColor(white: 1, alpha: 0.7)
    hint.textAlignment = .center

    let stack = UIStackView(arrangedSubviews: [badge, title, size, note, hint])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 8
    stack.setCustomSpacing(20, after: badge)
    stack.setCustomSpacing(12, after: note)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let card = UIView()
    styleCard(card)
    card.translatesAutoresizingMaskIntoConstraints = false
    card.accessibilityLabel = (["Room scanned", sizeText] + caveats + ["Opening your floor plan."])
      .joined(separator: ". ")
    card.isAccessibilityElement = true
    card.addSubview(stack)
    // Feedback only: the card is not tappable.
    card.isUserInteractionEnabled = false
    view.addSubview(card)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 32),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
      card.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
    ])
    completionCard = card

    card.alpha = 0
    card.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
    UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
      card.alpha = 1
      card.transform = .identity
    }
  }

  private func hideCompletionCard() {
    completionWork?.cancel()
    completionWork = nil
    guard let card = completionCard else { return }
    completionCard = nil
    card.isUserInteractionEnabled = false
    UIView.animate(withDuration: 0.2, animations: { card.alpha = 0 }) { _ in card.removeFromSuperview() }
  }

  /// The measurements line under the camera view, for the selected mode:
  /// the room in Auto and Corners (with the doors and windows counted so
  /// far), the marked openings in Door and Window.
  private func statsText(_ auto: AutoRoom?) -> String {
    let sep = "   ·   "
    switch mode {
    case .auto:
      let counts = elementsSummary()
      guard let auto else { return "Measuring the room..." + (counts.map { sep + $0 } ?? "") }
      var parts = ["\(m(auto.width)) × \(m(auto.depth))",
                   String(format: "Area %.2f m²", auto.area),
                   "Perimeter \(m(auto.perimeter))",
                   "\(auto.corners.count) walls"]
      if let counts { parts.append(counts) }
      return parts.joined(separator: sep)
    case .corner:
      var parts = ["\(corners.count) corner\(corners.count == 1 ? "" : "s")"]
      if corners.count >= 2 { parts.append("Perimeter \(m(perimeter()))") }
      if corners.count >= 3 { parts.append(String(format: "Area %.2f m²", area())) }
      if let counts = elementsSummary() { parts.append(counts) }
      return parts.joined(separator: sep)
    case .door, .window:
      let type = mode == .door ? Self.typeDoor : Self.typeWindow
      let name = mode == .door ? "door" : "window"
      let fy = snapshot?.floorY
      let sizes = openings.filter { $0.type == type }.map { o -> String in
        var s = openingText(o, fy)
        if let sill = openingSill(o, fy) { s += " (sill \(m(sill)))" }
        return s
      }
      if sizes.isEmpty { return "No \(name)s marked yet" }
      return "\(sizes.count) \(name)\(sizes.count == 1 ? "" : "s"):  " + sizes.joined(separator: ",  ")
    case .surface:
      if surfaces.isEmpty { return "No surfaces marked yet" }
      let sizes = surfaces.map { String(format: "%.2f × %.2f m", $0.width, $0.height) }
      let total = surfaces.reduce(Float(0)) { $0 + $1.width * $1.height }
      return "\(surfaces.count) surface\(surfaces.count == 1 ? "" : "s"):  " + sizes.joined(separator: ",  ")
        + String(format: "  ·  %.2f m²", total)
    case .line:
      if lines.isEmpty { return "No lines measured yet" }
      return "\(lines.count) line\(lines.count == 1 ? "" : "s"):  "
        + lines.map { ($0.estimated ? "≈ " : "") + m($0.length) }.joined(separator: ",  ")
    }
  }

  /// "2 doors · 3 windows" for what this scan has found so far (marked,
  /// accepted or counted automatically); nil when there are none.
  private func elementsSummary() -> String? {
    let doors = openings.filter { $0.type == Self.typeDoor }.count
    let windows = openings.filter { $0.type == Self.typeWindow }.count
    let things = mode == .auto ? furniture.confirmed.count : 0
    if doors == 0 && windows == 0 && things == 0 { return nil }
    return "\(doors) door\(doors == 1 ? "" : "s") · \(windows) window\(windows == 1 ? "" : "s")"
      + (things > 0 ? " · \(things) object\(things == 1 ? "" : "s")" : "")
  }

  /// AI furniture detection (main thread), a little over once a second: the
  /// camera image goes to the detector on its own queue; what it finds is
  /// placed on the floor and added to `furniture`.
  private func maybeDetectFurniture(_ frame: ARFrame, floorY: Float, orientation: UIInterfaceOrientation) {
    let now = CACurrentMediaTime()
    if furnitureBusy || furnitureModelFailed || now - lastFurnitureAttempt < 0.7 { return }
    lastFurnitureAttempt = now
    let camera = frame.camera
    let k = camera.intrinsics
    let cam = PinholeCamera(sensorToWorld: camera.transform,
                            fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y)
    // The captured image is landscape (home button right): turned upright
    // as the phone is held.
    let degrees: Int
    switch orientation {
    case .portraitUpsideDown: degrees = 270
    case .landscapeLeft: degrees = 180
    case .landscapeRight: degrees = 0
    default: degrees = 90
    }
    // Only the image is kept, not the frame (ARKit stops when too many are held).
    let buffer = frame.capturedImage
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let gen = scanGeneration
    furnitureBusy = true
    furnitureQueue.async { [weak self] in
      guard let self else { return }
      if self.furnitureModel == nil { self.furnitureModel = FurnitureModel() }
      guard let model = self.furnitureModel else {
        DispatchQueue.main.async {
          self.furnitureModelFailed = true
          self.furnitureBusy = false
        }
        return
      }
      let toSensor = uprightToSensor(degrees, w, h)
      let uprightH = Float(degrees % 180 == 0 ? h : w)
      let found = model.detect(buffer, degrees: degrees).compactMap {
        FurniturePlacement.place($0, cam: cam, floorY: floorY, uprightHeight: uprightH, toSensor: toSensor)
      }
      DispatchQueue.main.async {
        self.furnitureBusy = false
        if gen == self.scanGeneration { found.forEach(self.furniture.add) }
      }
    }
  }

  private func setIfChanged(_ label: UILabel, _ text: String) {
    if label.text == text { return }
    if label === hintLabel {
      // The instruction card: Inter with a little more line height.
      let para = NSMutableParagraphStyle()
      para.lineHeightMultiple = 1.3 * 15 / max(PlanoraFont.inter(15, .regular).lineHeight, 1)
      label.attributedText = NSAttributedString(string: text, attributes: [
        .font: PlanoraFont.inter(15, .regular),
        .foregroundColor: UIColor.white,
        .paragraphStyle: para,
      ])
    } else {
      label.text = text
    }
  }

  private func setEnabled(_ view: UIView, _ control: UIControl, _ on: Bool) {
    control.isEnabled = on
    view.alpha = on ? 1 : 0.4
  }

  // ------------------------------------------------------------ layout

  private func buildUi() {
    view.backgroundColor = .black
    for v in [sceneView, overlay, tapView] as [UIView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
      NSLayoutConstraint.activate([
        v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        v.topAnchor.constraint(equalTo: view.topAnchor),
        v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }
    sceneView.automaticallyUpdatesLighting = false
    sceneView.rendersCameraGrain = false
    overlay.owner = self
    overlay.isUserInteractionEnabled = false
    overlay.backgroundColor = .clear
    overlay.isOpaque = false
    overlay.contentMode = .redraw
    // Added before the panels, so their buttons stay on top of it. Switched
    // on in refreshUi, in Line mode with the Aim method only.
    tapView.owner = self
    tapView.backgroundColor = .clear
    tapView.isUserInteractionEnabled = false

    // ---- top: close button, status pill, instruction card
    let close = UIButton(type: .system)
    setSymbol(close, "xmark", fallback: "✕")
    frost(close, radius: 22)
    close.addTarget(self, action: #selector(onClose), for: .touchUpInside)
    close.accessibilityLabel = "Close"
    NSLayoutConstraint.activate([
      close.widthAnchor.constraint(equalToConstant: 44),
      close.heightAnchor.constraint(equalToConstant: 44),
    ])

    statusLabel.font = PlanoraFont.inter(13, .semibold, tabular: true)
    statusLabel.textColor = .white
    statusLabel.textAlignment = .center
    statusLabel.backgroundColor = .clear
    statusLabel.insets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    statusLabel.adjustsFontSizeToFitWidth = true
    statusLabel.minimumScaleFactor = 0.8
    statusLabel.heightAnchor.constraint(equalToConstant: 44).isActive = true

    let reset = UIButton(type: .system)
    setSymbol(reset, "arrow.counterclockwise", fallback: "↻")
    frost(reset, radius: 22)
    reset.addTarget(self, action: #selector(onReset), for: .touchUpInside)
    reset.accessibilityLabel = "Start over"
    NSLayoutConstraint.activate([
      reset.widthAnchor.constraint(equalToConstant: 44),
      reset.heightAnchor.constraint(equalToConstant: 44),
    ])

    let photo = UIButton(type: .system)
    setSymbol(photo, "camera", fallback: "📷")
    frost(photo, radius: 22)
    photo.addTarget(self, action: #selector(onPhoto), for: .touchUpInside)
    photo.accessibilityLabel = "Take photo"
    NSLayoutConstraint.activate([
      photo.widthAnchor.constraint(equalToConstant: 44),
      photo.heightAnchor.constraint(equalToConstant: 44),
    ])

    let statusPill = wrapFrosted(statusLabel, radius: 22)
    let bar = UIStackView(arrangedSubviews: [close, statusPill, photo, reset])
    bar.axis = .horizontal
    bar.spacing = 10
    bar.alignment = .center

    hintLabel.font = PlanoraFont.inter(15, .regular)
    hintLabel.textColor = .white
    hintLabel.numberOfLines = 0
    hintLabel.backgroundColor = .clear
    hintLabel.insets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    let hintCard = wrapFrosted(hintLabel, radius: 18)

    let top = UIStackView(arrangedSubviews: [bar, hintCard])
    top.axis = .vertical
    top.spacing = 10
    top.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(top)
    topStack = top
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      top.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
      top.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
    ])
    portraitConstraints.append(top.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16))
    landscapeConstraints.append(top.widthAnchor.constraint(equalToConstant: Self.landscapeTopWidth))

    // ---- bottom: stats, mode tabs, actions
    statsLabel.font = PlanoraFont.inter(13, .medium, tabular: true)
    statsLabel.textColor = UIColor(white: 1, alpha: 0.82)
    statsLabel.textAlignment = .center
    statsLabel.numberOfLines = 2

    // The mode tabs: equally wide and filling the row when they all fit,
    // otherwise the row scrolls sideways.
    let tabs = UIStackView()
    tabs.axis = .horizontal
    tabs.distribution = .fillEqually
    tabs.isLayoutMarginsRelativeArrangement = true
    tabs.layoutMargins = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
    tabs.translatesAutoresizingMaskIntoConstraints = false
    let tabFont = PlanoraFont.inter(13, .semibold)
    // Surface measuring is hidden from the camera.
    // Measuring distances only: no room outline is returned, so the room
    // modes (whose result would be thrown away) are not offered.
    for md in Mode.allCases where md != .surface && !(lineOnly && (md == .auto || md == .corner)) {
      let b = UIButton(type: .custom)
      b.setTitle(md.label, for: .normal)
      b.titleLabel?.font = tabFont
      b.titleLabel?.lineBreakMode = .byClipping
      b.layer.cornerRadius = 18
      b.layer.cornerCurve = .continuous
      b.setTitleColor(UIColor(white: 1, alpha: 0.8), for: .normal)
      b.tag = md.rawValue
      b.addTarget(self, action: #selector(onTab(_:)), for: .touchUpInside)
      b.heightAnchor.constraint(equalToConstant: 36).isActive = true
      // Never narrower than its label needs.
      let labelWidth = ceil((md.label as NSString).size(withAttributes: [.font: tabFont]).width) + 20
      b.widthAnchor.constraint(greaterThanOrEqualToConstant: max(Self.tabMinWidth, labelWidth)).isActive = true
      tabButtons[md] = b
      tabs.addArrangedSubview(b)
    }
    tabScroll.backgroundColor = UIColor(white: 1, alpha: 0.1)
    tabScroll.layer.cornerRadius = 21
    tabScroll.layer.cornerCurve = .continuous
    tabScroll.clipsToBounds = true
    tabScroll.showsHorizontalScrollIndicator = false
    tabScroll.showsVerticalScrollIndicator = false
    tabScroll.alwaysBounceVertical = false
    tabScroll.contentInsetAdjustmentBehavior = .never
    tabScroll.addSubview(tabs)
    let fillRow = tabs.widthAnchor.constraint(equalTo: tabScroll.frameLayoutGuide.widthAnchor)
    fillRow.priority = .defaultLow
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.leadingAnchor),
      tabs.trailingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.trailingAnchor),
      tabs.topAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.topAnchor),
      tabs.bottomAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.bottomAnchor),
      tabs.heightAnchor.constraint(equalTo: tabScroll.frameLayoutGuide.heightAnchor),
      tabs.widthAnchor.constraint(greaterThanOrEqualTo: tabScroll.frameLayoutGuide.widthAnchor),
      fillRow,
    ])
    // The row's width is only known after layout (and changes on rotation):
    // bring the selected tab back into view then.
    tabScroll.onWidthChange = { [weak self] in
      DispatchQueue.main.async { self?.scrollSelectedTabIntoView(animated: false) }
    }

    let (uCol, uBtn) = sideButton("Undo", "arrow.uturn.backward", "↺", #selector(onUndo))
    undoColumn = uCol
    undoButton = uBtn
    let (dCol, dBtn) = sideButton("Finish", "checkmark", "✓", #selector(onDone))
    doneColumn = dCol
    doneButton = dBtn

    markButton.layer.cornerRadius = 38
    markButton.layer.borderWidth = 3
    markButton.layer.borderColor = UIColor.white.cgColor
    markButton.layer.shadowColor = UIColor.black.cgColor
    markButton.layer.shadowOpacity = 0.25
    markButton.layer.shadowRadius = 10
    markButton.layer.shadowOffset = CGSize(width: 0, height: 3)
    markButton.addTarget(self, action: #selector(onMark), for: .touchUpInside)
    markButton.accessibilityLabel = "Mark point"
    let inner = markGlyph
    inner.text = "+"
    inner.font = .systemFont(ofSize: 34, weight: .light)
    inner.textColor = Self.ink
    inner.textAlignment = .center
    inner.backgroundColor = .white
    inner.layer.cornerRadius = 30
    inner.clipsToBounds = true
    inner.isUserInteractionEnabled = false
    inner.translatesAutoresizingMaskIntoConstraints = false
    markButton.addSubview(inner)
    markButton.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      markButton.widthAnchor.constraint(equalToConstant: 76),
      markButton.heightAnchor.constraint(equalToConstant: 76),
      inner.widthAnchor.constraint(equalToConstant: 60),
      inner.heightAnchor.constraint(equalToConstant: 60),
      inner.centerXAnchor.constraint(equalTo: markButton.centerXAnchor),
      inner.centerYAnchor.constraint(equalTo: markButton.centerYAnchor),
    ])
    let markHolder = UIView()
    markHolder.addSubview(markButton)
    NSLayoutConstraint.activate([
      markButton.centerXAnchor.constraint(equalTo: markHolder.centerXAnchor),
      markButton.topAnchor.constraint(equalTo: markHolder.topAnchor),
      markButton.bottomAnchor.constraint(equalTo: markHolder.bottomAnchor),
    ])

    let actions = UIStackView(arrangedSubviews: [uCol, markHolder, dCol])
    actions.axis = .horizontal
    actions.distribution = .fillEqually
    actions.alignment = .center

    // Line mode only: how the two ends of a line are given.
    methodControl.selectedSegmentIndex = lineMethod.rawValue
    methodControl.overrideUserInterfaceStyle = .dark
    methodControl.backgroundColor = UIColor(white: 1, alpha: 0.1)
    methodControl.selectedSegmentTintColor = .white
    let methodFont = PlanoraFont.inter(13, .semibold)
    methodControl.setTitleTextAttributes([.foregroundColor: UIColor(white: 1, alpha: 0.8), .font: methodFont],
                                         for: .normal)
    methodControl.setTitleTextAttributes([.foregroundColor: Self.ink, .font: methodFont], for: .selected)
    methodControl.addTarget(self, action: #selector(onLineMethod), for: .valueChanged)
    methodControl.heightAnchor.constraint(equalToConstant: 32).isActive = true
    methodControl.isHidden = mode != .line

    let content = UIStackView(arrangedSubviews: [statsLabel, methodControl, tabScroll, actions])
    content.axis = .vertical
    content.spacing = 12
    content.setCustomSpacing(16, after: tabScroll)
    content.translatesAutoresizingMaskIntoConstraints = false

    let panel = UIView()
    frost(panel, radius: 28)
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(content)
    view.addSubview(panel)
    bottomPanel = panel
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
      content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
      content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
      panel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
      panel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
    ])
    portraitConstraints.append(panel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12))
    landscapeConstraints.append(panel.widthAnchor.constraint(equalToConstant: Self.landscapePanelWidth))
  }

  private func sideButton(_ label: String, _ symbol: String, _ glyph: String,
                          _ action: Selector) -> (UIView, UIButton) {
    let b = UIButton(type: .custom)
    setSymbol(b, symbol, fallback: glyph)
    b.setTitleColor(.white, for: .normal)
    b.backgroundColor = Self.sideFill
    b.layer.cornerRadius = 26
    b.layer.borderWidth = 1 / UIScreen.main.scale
    b.layer.borderColor = Self.hairline.cgColor
    b.accessibilityLabel = label
    b.addTarget(self, action: action, for: .touchUpInside)
    NSLayoutConstraint.activate([
      b.widthAnchor.constraint(equalToConstant: 52),
      b.heightAnchor.constraint(equalToConstant: 52),
    ])
    let l = UILabel()
    l.text = label
    l.font = PlanoraFont.inter(11, .medium)
    l.textColor = UIColor(white: 1, alpha: 0.8)
    l.textAlignment = .center
    let col = UIStackView(arrangedSubviews: [b, l])
    col.axis = .vertical
    col.alignment = .center
    col.spacing = 6
    return (col, b)
  }

  /// An SF Symbol (17 pt, medium) as the button's icon, white.
  private func setSymbol(_ b: UIButton, _ name: String, fallback: String) {
    let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    if let img = UIImage(systemName: name, withConfiguration: config) {
      b.setImage(img.withRenderingMode(.alwaysTemplate), for: .normal)
    } else {
      b.setTitle(fallback, for: .normal)
      b.titleLabel?.font = .systemFont(ofSize: 18)
    }
    b.tintColor = .white
  }

  /// Frosted glass behind a view: a dark blur with an ink tint, rounded,
  /// with a hairline edge, so the camera shows through a little.
  private func frost(_ v: UIView, radius: CGFloat) {
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    blur.isUserInteractionEnabled = false
    blur.frame = v.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blur.contentView.backgroundColor = Self.glassTint
    blur.layer.cornerRadius = radius
    blur.layer.cornerCurve = .continuous
    blur.clipsToBounds = true
    // Always behind the view's own content. A UIButton adds its icon view
    // lazily, during layout, and could end up below the blur: the top-bar
    // buttons then showed as empty dark circles.
    blur.layer.zPosition = -1
    v.insertSubview(blur, at: 0)
    v.backgroundColor = .clear
    v.layer.cornerRadius = radius
    v.layer.cornerCurve = .continuous
    v.layer.borderWidth = 1 / UIScreen.main.scale
    v.layer.borderColor = Self.hairline.cgColor
  }

  /// A label inside a frosted container (a label's own subviews would cover
  /// its text).
  private func wrapFrosted(_ label: UILabel, radius: CGFloat) -> UIView {
    let box = UIView()
    frost(box, radius: radius)
    label.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: box.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: box.trailingAnchor),
      label.topAnchor.constraint(equalTo: box.topAnchor),
      label.bottomAnchor.constraint(equalTo: box.bottomAnchor),
    ])
    return box
  }

  /// The completion and door / window cards.
  private func styleCard(_ card: UIView) {
    card.backgroundColor = Self.cardFill
    card.layer.cornerRadius = 28
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1 / UIScreen.main.scale
    card.layer.borderColor = Self.hairline.cgColor
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.35
    card.layer.shadowRadius = 24
    card.layer.shadowOffset = CGSize(width: 0, height: 8)
  }

  // ------------------------------------------------------------ overlay

  private static let nearW: Float = 0.05

  private func toScreen(_ v: SIMD4<Float>, _ size: CGSize) -> CGPoint {
    CGPoint(x: CGFloat((v.x / v.w + 1) / 2) * size.width,
            y: CGFloat((1 - v.y / v.w) / 2) * size.height)
  }

  private func project(_ vp: simd_float4x4, _ p: V3, _ size: CGSize) -> CGPoint? {
    let v = vp * SIMD4<Float>(p.x, p.y, p.z, 1)
    if v.w <= Self.nearW { return nil }
    return toScreen(v, size)
  }

  /// A line in the scene on screen, cut off where it passes behind the
  /// camera (instead of dropped when one end is behind it).
  private func projectSegment(_ vp: simd_float4x4, _ a: V3, _ b: V3, _ size: CGSize) -> (CGPoint, CGPoint)? {
    var ca = vp * SIMD4<Float>(a.x, a.y, a.z, 1)
    var cb = vp * SIMD4<Float>(b.x, b.y, b.z, 1)
    let n = Self.nearW
    if ca.w <= n && cb.w <= n { return nil }
    if ca.w <= n {
      ca += (cb - ca) * ((n - ca.w) / (cb.w - ca.w))
    } else if cb.w <= n {
      cb += (ca - cb) * ((n - cb.w) / (ca.w - cb.w))
    }
    return (toScreen(ca, size), toScreen(cb, size))
  }

  /// A surface outline on screen, clipped to the part in front of the
  /// camera. The floor you stand on always reaches behind you; without
  /// clipping it (and walls beside you) was not drawn at all.
  private func projectPolygon(_ vp: simd_float4x4, _ pts: [V3], _ size: CGSize) -> [CGPoint] {
    let c = pts.map { vp * SIMD4<Float>($0.x, $0.y, $0.z, 1) }
    let n = Self.nearW
    var out = [CGPoint]()
    for i in c.indices {
      let a = c[i]
      let b = c[(i + 1) % c.count]
      if a.w > n { out.append(toScreen(a, size)) }
      if (a.w > n) != (b.w > n) {
        out.append(toScreen(a + (b - a) * ((n - a.w) / (b.w - a.w)), size))
      }
    }
    return out
  }

  private func strokeLine(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ color: UIColor,
                          width: CGFloat = 2.5, dash: [CGFloat]? = nil) {
    ctx.saveGState()
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()
    ctx.restoreGState()
  }

  private func fillCircle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: UIColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
  }

  private func strokeCircle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: UIColor, _ width: CGFloat) {
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
  }

  private func chip(_ x: CGFloat, _ y: CGFloat, _ text: String,
                    _ bg: UIColor = ArMeasureViewController.chipFill) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: Self.chipFont,
      .foregroundColor: UIColor.white,
    ]
    let s = text as NSString
    let sz = s.size(withAttributes: attrs)
    let rect = CGRect(x: x - sz.width / 2 - 10, y: y - sz.height / 2 - 5,
                      width: sz.width + 20, height: sz.height + 10)
    let pill = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
    if let ctx = UIGraphicsGetCurrentContext() {
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: UIColor(white: 0, alpha: 0.3).cgColor)
      bg.setFill()
      pill.fill()
      ctx.restoreGState()
    } else {
      bg.setFill()
      pill.fill()
    }
    Self.hairline.setStroke()
    pill.lineWidth = 0.5
    pill.stroke()
    s.draw(at: CGPoint(x: x - sz.width / 2, y: y - sz.height / 2), withAttributes: attrs)
  }

  /// The live overlay, or with `forPhoto` only the measurements for an AR
  /// photo: the room outline in use, doors, windows, surfaces and lines,
  /// without surface fills, tracked points, crosshair, live line or mini-map.
  fileprivate func drawOverlay(_ ctx: CGContext, _ size: CGSize, forPhoto: Bool = false) {
    guard let snap = snapshot else { return }
    let cx = size.width / 2
    let cy = size.height / 2
    let vp = snap.viewProj
    if !forPhoto {
      planRect = .null
      miniRect = .null
    }
    // Room scan with the 2D plan: the camera image stays clear; what was
    // found is drawn on the plan.
    let plan2d = !forPhoto && livePlanShown

    if forPhoto {
      if !lineOnly, useAutoRoom(), let room = snap.autoRoom ?? autoRoom {
        drawAutoRoom(ctx, snap, room, size)
      }
    } else if snap.tracking && !(plan2d && mode == .auto) {
      // Corner mode keeps these with its plan: they are aimed at.
      drawSurfaces(ctx, snap, size)
      drawFramePoints(ctx, snap, size)
      if mode == .corner { drawCornerCandidates(ctx, snap, size) }
    }
    // Auto room scan: the walls, corners, doors, windows and furniture
    // outlined in white on the camera image as they are found (lengths are
    // on the plan).
    if !forPhoto && snap.tracking && mode == .auto && !lineOnly {
      drawLiveWalls(ctx, snap, size)
    }
    // Touching a point with the phone: nothing is aimed at.
    let touch = touching
    // Auto finds doors and windows itself: nothing is aimed at either.
    let autoOpenings = openingAuto
    let aim = snap.tracking && !forPhoto && !touch && !autoOpenings ? resolveAim(snap) : nil

    // Marked outline, drawn at floor level when the floor is known.
    let fy = snap.floorY
    func onFloor(_ p: V3) -> V3 { fy.map { p.withY($0) } ?? p }
    let pts = corners.map { project(vp, onFloor($0), size) }
    if corners.count >= 2 {
      for i in 1..<corners.count {
        guard let (a, b) = projectSegment(vp, onFloor(corners[i - 1]), onFloor(corners[i]), size) else { continue }
        strokeLine(ctx, a, b, .white)
        chip((a.x + b.x) / 2, (a.y + b.y) / 2, m(corners[i - 1].dist2d(corners[i])))
      }
    }
    if corners.count >= 3, let (a, b) = projectSegment(vp, onFloor(corners.last!), onFloor(corners[0]), size) {
      if forPhoto {
        // The photo shows the closed outline with every side measured.
        strokeLine(ctx, a, b, .white)
        chip((a.x + b.x) / 2, (a.y + b.y) / 2, m(corners.last!.dist2d(corners[0])))
      } else {
        strokeLine(ctx, a, b, UIColor(white: 1, alpha: 0.8), width: 2, dash: [8, 7])
      }
    }
    for case let p? in pts {
      fillCircle(ctx, p, 7, .white)
      fillCircle(ctx, p, 4, Self.accent)
    }

    @discardableResult
    func line(_ p: V3, _ q: V3, _ color: UIColor, width: CGFloat = 2.5,
              dash: [CGFloat]? = nil) -> (CGPoint, CGPoint)? {
      guard let (a, b) = projectSegment(vp, p, q, size) else { return nil }
      strokeLine(ctx, a, b, color, width: width, dash: dash)
      return (a, b)
    }
    /// The four sides p, q, q + up, p + up; the base solid, the rest as given.
    func rect(_ p: V3, _ q: V3, _ pTop: V3, _ qTop: V3, _ color: UIColor, live: Bool) {
      let dash: [CGFloat]? = live ? [8, 7] : nil
      let w: CGFloat = live ? 2 : 2.5
      line(p, q, color)
      line(p, pTop, color, width: w, dash: dash)
      line(q, qTop, color, width: w, dash: dash)
      line(pTop, qTop, color, width: w, dash: dash)
    }
    // Doors stand on the floor; windows are drawn where they were tapped,
    // as their sill is somewhere up the wall.
    func openingPoint(_ type: Int, _ p: V3) -> V3 { type == Self.typeDoor ? onFloor(p) : p }
    func openingColor(_ type: Int) -> UIColor { type == Self.typeDoor ? Self.door : Self.window }
    func openingChip(_ type: Int) -> UIColor { type == Self.typeDoor ? Self.doorChip : Self.windowChip }

    // Doors and windows (on the 2D plan instead while it is shown).
    // Auto scan: drawn as white frames by drawLiveWalls.
    for o in openings where !(mode == .auto && !forPhoto && !lineOnly) {
      let color = openingColor(o.type)
      let a = openingPoint(o.type, o.a)
      let b = openingPoint(o.type, o.b)
      if let top = o.topY {
        rect(a, b, a.withY(top), b.withY(top), color, live: false)
        let mid = (a + b) / 2
        if let c = project(vp, mid.withY((mid.y + top) / 2), size) {
          chip(c.x, c.y, openingText(o, fy), openingChip(o.type))
        }
      } else if let (p, q) = line(a, b, color) {
        chip((p.x + q.x) / 2, (p.y + q.y) / 2 - 14, openingText(o, fy), openingChip(o.type))
      }
    }

    // Surfaces.
    for s in surfaces {
      let off = s.offset
      rect(s.a, s.b, s.a + off, s.b + off, Self.surface, live: false)
      if let c = project(vp, (s.a + s.b) / 2 + off / 2, size) {
        chip(c.x, c.y, String(format: "%.2f × %.2f m · %.2f m²", s.width, s.height, s.width * s.height),
             Self.surfaceChip)
      }
    }

    // Lines, between the points as tapped.
    /// The round marker of a line's end, staying on its point in the scene;
    /// amber inside when that point is on an estimated surface.
    func lineMarker(_ p: V3, _ estimated: Bool) {
      guard let s = project(vp, p, size) else { return }
      fillCircle(ctx, s, 8, .white)
      fillCircle(ctx, s, 5, estimated ? Self.door : Self.line)
    }
    for l in lines {
      // With an estimated end the length is approximate: dashed and "≈".
      let seg = line(l.a, l.b, Self.line, dash: l.estimated ? [8, 7] : nil)
      lineMarker(l.a, l.aEstimated)
      lineMarker(l.b, l.bEstimated)
      if let c = project(vp, (l.a + l.b) / 2, size) ?? seg.map({ CGPoint(x: ($0.0.x + $0.1.x) / 2,
                                                                       y: ($0.0.y + $0.1.y) / 2) }) {
        chip(c.x, c.y, (l.estimated ? "≈ " : "") + lineText(l.a, l.b), Self.lineChip)
      }
    }

    if forPhoto { return }

    // What the next tap would add, live up to the crosshair.
    if let aim {
      switch mode {
      case .corner:
        if let from = corners.last {
          line(onFloor(from), onFloor(aim.p), .white, width: 2, dash: [8, 7])
          chip(cx, cy - 34, m(from.dist2d(aim.p)))
        }
      case .door, .window:
        let type = mode == .door ? Self.typeDoor : Self.typeWindow
        let color = openingColor(type)
        if pending.count == 1 {
          line(openingPoint(type, pending[0]), openingPoint(type, aim.p), color, width: 2, dash: [8, 7])
          chip(cx, cy - 34, m(pending[0].dist2d(aim.p)))
        } else if pending.count == 2 {
          let a = openingPoint(type, pending[0])
          let b = openingPoint(type, pending[1])
          let top = aim.p.y
          rect(a, b, a.withY(top), b.withY(top), color, live: true)
          var text = "Height \(m(top - openingBaseY(type, pending[0], pending[1], fy)))"
          if type == Self.typeWindow, let fy {
            text += " · sill \(m((pending[0].y + pending[1].y) / 2 - fy))"
          }
          chip(cx, cy - 34, text)
        }
      case .surface:
        if pending.count == 1 {
          line(pending[0], aim.p, Self.surface, width: 2, dash: [8, 7])
          chip(cx, cy - 34, m(simd_length(aim.p - pending[0])))
        } else if pending.count == 2 {
          let a = pending[0], b = pending[1]
          let off = SurfaceMark.perpendicular(a, b, aim.p)
          rect(a, b, a + off, b + off, Self.surface, live: true)
          chip(cx, cy - 34, String(format: "%.2f × %.2f m", simd_length(b - a), simd_length(off)))
        }
      case .line:
        // While a finger is down the live line runs to it instead (below).
        if tapPreview == nil, let a = pending.first {
          line(a, aim.p, Self.line, width: 2, dash: [8, 7])
          chip(cx, cy - 34, (lineStartEstimated || aim.estimated ? "≈ " : "") + lineText(a, aim.p))
        }
      default:
        break
      }
    }
    // Touch method: how far the phone has moved from the first point.
    if touch, snap.tracking, let a = pending.first {
      if touchTurned(snap) {
        chip(cx, cy - 34, "Phone turned: turn it back", Self.errorChip)
      } else if mode == .line {
        chip(cx, cy - 34, lineText(a, snap.camPos))
      } else {
        // Door / window: the width so far, then the frame up to the phone.
        let type = mode == .door ? Self.typeDoor : Self.typeWindow
        if pending.count == 1 {
          line(openingPoint(type, a), openingPoint(type, snap.camPos.withY(a.y)), openingColor(type),
               width: 2, dash: [8, 7])
          chip(cx, cy - 34, "Width \(m(a.dist2d(snap.camPos)))")
        } else if pending.count >= 2 {
          // As placeOpeningTouch: from the phone's own base taps.
          let base = (a.y + pending[1].y) / 2
          let p = a.withY(base), q = pending[1].withY(base)
          let top = snap.camPos.y
          rect(p, q, p.withY(top), q.withY(top), openingColor(type), live: true)
          chip(cx, cy - 34, "Height \(m(top - base))")
        }
      }
    }
    // Auto: the door or window found, amber dashed until the detections
    // agree, then green.
    // Adjusted by hand: solid orange, the side being dragged in blue. Each
    // side has its own handle (the circle at its middle) and moves alone.
    if autoOpenings, snap.tracking, let found = shownOpening {
      let hand = adjusted != nil
      let color = hand ? Self.door : (found.stable ? Self.snap : Self.door)
      let p = found.a, q = found.b
      let pt = p.withY(found.top), qt = q.withY(found.top)
      let dash: [CGFloat]? = found.stable ? nil : [8, 7]
      let corners = [p, q, qt, pt]
      let g = adjustGrab
      for i in 0..<4 {
        // Side i runs from corner i to i + 1.
        line(corners[i], corners[(i + 1) % 4], hand && g == i ? Self.accent : color, width: 2.5, dash: dash)
      }
      // Corners: small dots only (dragging a corner moved two sides).
      for c in corners {
        guard let s = project(vp, c, size) else { continue }
        fillCircle(ctx, s, 3.5, color)
      }
      // One handle per side, at its middle: it moves that side only.
      for i in 0..<4 {
        guard let s = project(vp, (corners[i] + corners[(i + 1) % 4]) / 2, size) else { continue }
        let held = hand && g == i
        let r: CGFloat = held ? 12 : 10
        fillCircle(ctx, s, r, .white)
        fillCircle(ctx, s, r - 2.5, held ? Self.accent : color)
      }
      var text = String(format: "%.2f × %.2f m", p.dist2d(q), found.top - found.bottom)
      if mode == .window, let fy { text += " · sill \(m(found.bottom - fy))" }
      if found.estimated { text = "≈ " + text }
      let mid = (p + q) / 2
      if let c = project(vp, mid.withY((found.bottom + found.top) / 2), size) {
        chip(c.x, c.y, text, found.stable ? Self.snapChip : Self.estChip)
      }
    }
    // Points of the door, window, surface or line being marked.
    let pendingColor = mode == .door ? Self.door
      : (mode == .window ? Self.window : (mode == .line ? Self.line : Self.surface))
    // A finger on the screen: the line so far, from the first point to it.
    if mode == .line, let tp = tapPreview, let pk = tp.pick, let a = pending.first {
      line(a, pk.point, Self.line, width: 2, dash: [8, 7])
    }
    for p in pending {
      if mode == .line {
        // Same marker as on a completed line.
        lineMarker(p, lineStartEstimated)
        continue
      }
      guard let s = project(vp, mode == .door ? onFloor(p) : p, size) else { continue }
      fillCircle(ctx, s, 6, .white)
      fillCircle(ctx, s, 4, pendingColor)
    }
    if mode == .auto {
      if plan2d { drawLivePlan(ctx, snap, size) } else { drawMiniMap(ctx, nil, size) }
      return
    }

    if touch {
      // No crosshair: the phone itself is put on the point.
      if !lineOnly { drawMiniMap(ctx, nil, size) }
      return
    }

    // Crosshair.
    var crossColor = UIColor.white
    if !snap.tracking {
      crossColor = UIColor(white: 1, alpha: 0.7)
    } else if autoOpenings {
      // Only shows where to point; nothing is measured at the crosshair.
      crossColor = .white
    } else if aim == nil {
      crossColor = Self.error
    } else if aim!.snappedCorner {
      crossColor = Self.snap
    } else if aim!.estimated {
      crossColor = Self.door
    }
    // A thin ring with a centre dot and four short ticks, softly shadowed.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: UIColor(white: 0, alpha: 0.45).cgColor)
    let r: CGFloat = 16
    let k = crossColor
    strokeCircle(ctx, CGPoint(x: cx, y: cy), r, k, 2)
    fillCircle(ctx, CGPoint(x: cx, y: cy), 2.5, k)
    let t0 = r + 4, t1 = r + 10
    strokeLine(ctx, CGPoint(x: cx - t1, y: cy), CGPoint(x: cx - t0, y: cy), k, width: 2)
    strokeLine(ctx, CGPoint(x: cx + t0, y: cy), CGPoint(x: cx + t1, y: cy), k, width: 2)
    strokeLine(ctx, CGPoint(x: cx, y: cy - t1), CGPoint(x: cx, y: cy - t0), k, width: 2)
    strokeLine(ctx, CGPoint(x: cx, y: cy + t0), CGPoint(x: cx, y: cy + t1), k, width: 2)
    ctx.restoreGState()

    if snap.tracking && !autoOpenings {
      if aim == nil {
        chip(cx, cy + 46, "No surface here", Self.errorChip)
      } else if aim!.closesRoom {
        chip(cx, cy + 46, "Tap to close the room", Self.snapChip)
      } else if aim!.snappedCorner {
        chip(cx, cy + 46, "Corner detected", Self.snapChip)
      } else if aim!.estimated {
        chip(cx, cy + 46, "Estimated surface", Self.estChip)
      }
    }
    // The map is of the room, which a plain distance measurement has none of.
    if plan2d && mode == .corner {
      drawLivePlan(ctx, snap, size, aim: aim)
    } else if !lineOnly {
      drawMiniMap(ctx, aim, size)
    }

    // The finger on the screen, drawn last so nothing covers it.
    if let tp = tapPreview {
      let color = tp.pick.map { $0.estimated ? Self.door : UIColor.white } ?? Self.error
      let c = tp.at
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: UIColor(white: 0, alpha: 0.45).cgColor)
      strokeCircle(ctx, c, 16, color, 2)
      strokeLine(ctx, CGPoint(x: c.x - 5, y: c.y), CGPoint(x: c.x + 5, y: c.y), color, width: 2)
      strokeLine(ctx, CGPoint(x: c.x, y: c.y - 5), CGPoint(x: c.x, y: c.y + 5), color, width: 2)
      ctx.restoreGState()
      // The finger hides the spot, so what it would give is shown above it
      // (below it where the top card would cover that).
      let chipX = min(max(c.x, 70), max(size.width - 70, 70))
      var chipY = c.y - 64
      if let top = topStack, chipY < top.frame.maxY + 18, chipX < top.frame.maxX + 70 { chipY = c.y + 64 }
      if let pk = tp.pick {
        if let a = pending.first {
          chip(chipX, chipY, (lineStartEstimated || pk.estimated ? "≈ " : "") + lineText(a, pk.point),
               Self.lineChip)
        } else {
          chip(chipX, chipY, "First point")
        }
      } else {
        chip(chipX, chipY, "No depth here", Self.errorChip)
      }
    } else if let f = failedTap, Date() < f.until {
      strokeCircle(ctx, f.at, 16, Self.error, 2)
    }
  }

  /// Tracked points as small dots, so you can see the walls being picked up.
  private func drawFramePoints(_ ctx: CGContext, _ snap: Snapshot, _ size: CGSize) {
    let r: CGFloat = 1.8
    for p in snap.framePoints {
      guard let s = project(snap.viewProj, p, size) else { continue }
      ctx.addEllipse(in: CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r))
    }
    ctx.setFillColor(UIColor(white: 1, alpha: 0.72).cgColor)
    ctx.fillPath()
  }

  private func drawSurfaces(_ ctx: CGContext, _ snap: Snapshot, _ size: CGSize) {
    for pl in snap.planes {
      // Ceilings are drawn through walls and windows and only confuse; they
      // are still used for the room height.
      if pl.kind != .floor && pl.kind != .wall { continue }
      let fill = pl.kind == .floor ? Self.floorFill : Self.wallFill
      let edge = pl.kind == .floor ? Self.floorEdge : Self.wallEdge
      let projected = projectPolygon(snap.viewProj, pl.points, size)
      if projected.count < 3 { continue }
      let path = CGMutablePath()
      path.addLines(between: projected)
      path.closeSubpath()
      ctx.addPath(path)
      ctx.setFillColor(fill.cgColor)
      ctx.fillPath()
      ctx.addPath(path)
      ctx.setStrokeColor(edge.cgColor)
      ctx.setLineWidth(1.25)
      ctx.setLineJoin(.round)
      ctx.strokePath()
    }
  }

  private func drawAutoRoom(_ ctx: CGContext, _ snap: Snapshot, _ room: AutoRoom, _ size: CGSize) {
    let vp = snap.viewProj
    let n = room.corners.count
    for i in 0..<n {
      guard let (a, b) = projectSegment(vp, room.corners[i], room.corners[(i + 1) % n], size) else { continue }
      let est = room.estimated[i]
      if est {
        strokeLine(ctx, a, b, Self.door, width: 2, dash: [8, 7])
      } else {
        strokeLine(ctx, a, b, Self.snap)
      }
      chip((a.x + b.x) / 2, (a.y + b.y) / 2, m(room.side(i)) + (est ? " ?" : ""),
           est ? Self.estChip : Self.snapChip)
    }
    // Corner posts.
    for c in room.corners {
      guard let a = project(vp, c, size) else { continue }
      if let b = project(vp, c.withY(c.y + 0.6), size) {
        strokeLine(ctx, a, b, Self.snap, width: 2)
      }
      fillCircle(ctx, a, 6.5, .white)
      fillCircle(ctx, a, 4, Self.snap)
    }
  }

  /// Auto room scan, drawn like a room scanner's live view: every wall found
  /// so far outlined in white on the camera image (where it meets the floor,
  /// where it meets the ceiling, and up each end, so the corners are white
  /// lines floor to ceiling), doors and windows as white frames, and
  /// furniture as white boxes. It grows wall by wall as the user turns round
  /// the room; once the room's outline is found, that is drawn instead
  /// (sides not measured dashed).
  private func drawLiveWalls(_ ctx: CGContext, _ snap: Snapshot, _ size: CGSize) {
    let vp = snap.viewProj
    let wallPlanes = snap.planes.filter { $0.kind == .wall }
    let wallPoints = wallPlanes.flatMap { $0.points }
    guard let fy = snap.floorY ?? snap.autoRoom?.corners.first?.y ?? wallPoints.map({ $0.y }).min() else { return }
    let segs: [(V3, V3)]
    let est: [Bool]
    if let room = snap.autoRoom, room.corners.count >= 3 {
      let n = room.corners.count
      segs = (0..<n).map { (room.corners[$0].withY(fy), room.corners[($0 + 1) % n].withY(fy)) }
      est = (0..<n).map { $0 < room.estimated.count && room.estimated[$0] }
    } else {
      let joined = LivePlan.connectWalls(LivePlan.mergeWalls(wallPlanes.compactMap { LivePlan.wallLine($0.points) }))
      segs = joined.walls.map { ($0.0.withY(fy), $0.1.withY(fy)) }
      est = segs.map { _ in false }
    }
    // The top: the ceiling when found, otherwise as high as the walls have
    // been seen (once that is clearly more than a skirting).
    let seenTop = wallPoints.map { $0.y }.max()
    let top: Float? = snap.ceilingY.flatMap { $0 - fy > 1.5 ? $0 : nil }
      ?? seenTop.flatMap { $0 - fy > 1.2 ? $0 : nil }
    let shadow = UIColor(white: 0, alpha: 0.31)
    func edge(_ a: V3, _ b: V3, dashed: Bool = false) {
      guard let (p, q) = projectSegment(vp, a, b, size) else { return }
      strokeLine(ctx, p, q, shadow, width: 7)
      strokeLine(ctx, p, q, .white, width: 4, dash: dashed ? [10, 8] : nil)
    }
    for (i, s) in segs.enumerated() {
      let (a, b) = s
      edge(a, b, dashed: est[i])
      if let top {
        edge(a.withY(top), b.withY(top), dashed: est[i])
        edge(a, a.withY(top))
        edge(b, b.withY(top))
      } else {
        // Not seen high enough yet: short posts at the ends.
        edge(a, a.withY(fy + 0.5))
        edge(b, b.withY(fy + 0.5))
      }
    }
    // Doors and windows: a white frame in their wall.
    for o in openings {
      guard let t = o.topY else { continue }
      let a = o.type == Self.typeDoor ? o.a.withY(fy) : o.a
      let b = o.type == Self.typeDoor ? o.b.withY(fy) : o.b
      edge(a, b)
      edge(a, a.withY(t))
      edge(b, b.withY(t))
      edge(a.withY(t), b.withY(t))
    }
    // Furniture found by the AI detector: a white box.
    let thin = UIColor(white: 1, alpha: 0.86)
    for f in furniture.confirmed {
      let base = f.footprint.map { $0.withY(fy) }
      let up = base.map { $0.withY(fy + f.height) }
      for k in 0..<4 {
        for (p, q) in [(base[k], base[(k + 1) % 4]), (up[k], up[(k + 1) % 4]), (base[k], up[k])] {
          if let (sp, sq) = projectSegment(vp, p, q, size) { strokeLine(ctx, sp, sq, thin, width: 2) }
        }
      }
    }
  }

  private func drawCornerCandidates(_ ctx: CGContext, _ snap: Snapshot, _ size: CGSize) {
    for c in snap.cornerCandidates {
      let base = snap.floorY.map { c.withY($0) } ?? c
      guard let a = project(snap.viewProj, base, size) else { continue }
      if let b = project(snap.viewProj, base.withY(base.y + 0.5), size) {
        strokeLine(ctx, a, b, Self.snap, width: 2)
      }
      strokeCircle(ctx, a, 9, Self.snap, 2)
    }
  }

  /// Top-down sketch of what has been marked so far. With the automatic
  /// outline it also shows the scan itself: measured sides in green and
  /// estimated ones dashed amber, where the phone is, and a ring of the
  /// directions already looked in (so the gaps show where to go next).
  private func drawMiniMap(_ ctx: CGContext, _ aim: Aim?, _ size: CGSize) {
    let auto = useAutoRoom() ? snapshot?.autoRoom : nil
    let pts = auto?.corners ?? corners
    // In Auto mode from the start, before any room is found.
    let scanView = auto != nil || mode == .auto
    if pts.isEmpty && !scanView { return }
    let box: CGFloat = 120
    let hintFrame = hintLabel.convert(hintLabel.bounds, to: overlay)
    // Portrait: top right, under the instruction card. Landscape: the bottom
    // right holds the controls, so it goes under the card on the left.
    let left = size.width > size.height ? hintFrame.minX : size.width - box - 16
    let top = hintFrame.maxY + 12
    if (mode == .auto || mode == .corner) && !lineOnly { miniRect = CGRect(x: left, y: top, width: box, height: box) }
    let mapCard = UIBezierPath(roundedRect: CGRect(x: left, y: top, width: box, height: box), cornerRadius: 16)
    Self.ink.withAlphaComponent(0.8).setFill()
    mapCard.fill()
    Self.hairline.setStroke()
    mapCard.lineWidth = 1
    mapCard.stroke()

    if scanView {
      // Under the room. The map has x to the right and z down, so a sector
      // of atan2(z, x) is at that same angle on screen.
      let centre = CGPoint(x: left + box / 2, y: top + box / 2)
      let n = Self.sectorCount
      let step = 2 * CGFloat.pi / CGFloat(n)
      let gap: CGFloat = 0.05
      ctx.saveGState()
      ctx.setLineWidth(3)
      ctx.setLineCap(.round)
      for i in 0..<n {
        let from = -CGFloat.pi + CGFloat(i) * step
        ctx.addArc(center: centre, radius: box / 2 - 4, startAngle: from + gap,
                   endAngle: from + step - gap, clockwise: false)
        ctx.setStrokeColor((sectors[i] ? Self.snap : UIColor(white: 1, alpha: 0.25)).cgColor)
        ctx.strokePath()
      }
      ctx.restoreGState()
    }

    let cam = scanView ? camNow : nil
    var all = pts + openings.flatMap { [$0.a, $0.b] }
    if mode == .corner, let aim { all.append(aim.p) }
    // The phone is kept on the map, also when it is outside the outline.
    if let cam { all.append(cam) }
    guard let minX = all.map({ $0.x }).min(), let maxX = all.map({ $0.x }).max(),
          let minZ = all.map({ $0.z }).min(), let maxZ = all.map({ $0.z }).max() else { return }
    let span = CGFloat(max(max(maxX - minX, maxZ - minZ), 1))
    // More margin with the ring, so the room stays inside it.
    let pad: CGFloat = scanView ? 20 : 14
    let scale = (box - 2 * pad) / span
    let ox = left + pad + ((box - 2 * pad) - CGFloat(maxX - minX) * scale) / 2
    let oy = top + pad + ((box - 2 * pad) - CGFloat(maxZ - minZ) * scale) / 2
    func sp(_ p: V3) -> CGPoint {
      CGPoint(x: ox + CGFloat(p.x - minX) * scale, y: oy + CGFloat(p.z - minZ) * scale)
    }

    if pts.count >= 3 {
      let path = CGMutablePath()
      path.addLines(between: pts.map(sp))
      path.closeSubpath()
      ctx.addPath(path)
      ctx.setFillColor((auto != nil ? Self.snap.withAlphaComponent(0.18) : UIColor(white: 1, alpha: 0.2)).cgColor)
      ctx.fillPath()
    }
    if let auto {
      let n = pts.count
      for i in 0..<n where n >= 2 {
        let a = sp(pts[i]), b = sp(pts[(i + 1) % n])
        if i < auto.estimated.count && auto.estimated[i] {
          strokeLine(ctx, a, b, Self.door, width: 2, dash: [4, 4])
        } else {
          strokeLine(ctx, a, b, Self.snap, width: 2)
        }
      }
    } else {
      if pts.count >= 2 {
        for i in 1..<pts.count { strokeLine(ctx, sp(pts[i - 1]), sp(pts[i]), .white, width: 2) }
      }
      if pts.count >= 3 {
        strokeLine(ctx, sp(pts.last!), sp(pts[0]), UIColor(white: 1, alpha: 0.7), width: 2, dash: [4, 4])
      }
      if let aim, mode == .corner, let last = pts.last {
        strokeLine(ctx, sp(last), sp(aim.p), UIColor(white: 1, alpha: 0.7), width: 2, dash: [4, 4])
      }
    }
    for o in openings {
      strokeLine(ctx, sp(o.a), sp(o.b), o.type == Self.typeDoor ? Self.door : Self.window, width: 4)
    }
    for c in pts { fillCircle(ctx, sp(c), auto != nil ? 2.5 : 3.5, Self.accent) }

    // The phone, with a short line the way it looks.
    if let cam {
      let c = sp(cam)
      let len = (camDir.x * camDir.x + camDir.z * camDir.z).squareRoot()
      if len > 0.2 {
        let tip = CGPoint(x: c.x + CGFloat(camDir.x / len) * 10, y: c.y + CGFloat(camDir.z / len) * 10)
        strokeLine(ctx, c, tip, .white, width: 2)
      }
      fillCircle(ctx, c, 3.5, .white)
    }
  }

  /// Room scan: the live 2D floor plan, in the lower part of the screen
  /// (landscape: the right half), heading-up so the wall in front of the
  /// phone is at its top. It shows the wall surfaces as they are picked up,
  /// the room outline once there is one (measured walls solid with their
  /// lengths, estimated ones amber and dashed), doors with their swing and
  /// windows as found, the phone with its field of view and the directions
  /// looked at so far, and the room's size and counts. Twin of drawLivePlan
  /// in ArMeasureActivity.kt.
  private func drawLivePlan(_ ctx: CGContext, _ snap: Snapshot, _ size: CGSize, aim: Aim? = nil) {
    let landscape = size.width > size.height
    let safe = view.safeAreaInsets
    // Corner mode keeps the crosshair (screen centre) and its hints clear:
    // the plan starts further down (landscape: further right).
    let marking = mode == .corner
    var bottom = size.height - 10
    if let p = bottomPanel, !p.isHidden { bottom = p.convert(p.bounds, to: overlay).minY - 10 }
    let left: CGFloat, right: CGFloat, top: CGFloat
    if landscape {
      left = size.width * (marking ? 0.62 : 0.5)
      right = size.width - 12 - safe.right
      top = 12 + safe.top
    } else {
      left = 12 + safe.left
      right = size.width - 12 - safe.right
      var cardBottom: CGFloat = safe.top
      if let t = topStack, !t.isHidden { cardBottom = t.convert(t.bounds, to: overlay).maxY }
      top = max(cardBottom + 12, marking ? size.height / 2 + 72 : size.height * 0.40)
    }
    if bottom - top < 140 || right - left < 140 {
      drawMiniMap(ctx, aim, size)
      return
    }
    let panel = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    planRect = panel
    let card = UIBezierPath(roundedRect: panel, cornerRadius: 20)
    Self.ink.withAlphaComponent(0.94).setFill()
    card.fill()
    Self.hairline.setStroke()
    card.lineWidth = 1
    card.stroke()
    ctx.saveGState()
    ctx.addPath(card.cgPath)
    ctx.clip()

    let header: CGFloat = 52
    // Corner mode: the walls marked so far, each drawn with its length as it
    // is marked, and a live line to the crosshair.
    let room = marking ? nil : snap.autoRoom
    let corners = marking ? self.corners.map { $0.withY(0) } : (room?.corners ?? [])
    let seen: [(V3, V3)] = snap.tracking
      ? LivePlan.mergeWalls(snap.planes.filter { $0.kind == .wall }.compactMap { LivePlan.wallLine($0.points) })
      : []
    let floors = snap.planes.filter { $0.kind == .floor }
    let aimP = marking ? aim?.p.withY(0) : nil
    var pts = corners
    for (a, b) in seen { pts += [a, b] }
    for o in openings { pts += [o.a, o.b] }
    if let aimP { pts.append(aimP) }
    let body = CGRect(x: left, y: top + header, width: right - left, height: bottom - top - header)
    let t = LivePlan.fit(pts, cam: snap.camPos, forward: snap.camForward, in: body, pad: 26)
    func sp(_ p: V3) -> CGPoint { t.point(p) }

    // 1 m grid, turning with the plan.
    let reach = Int(max(panel.width, panel.height) / t.scale) + 2
    let gx0 = Int(t.cx.rounded(.down)), gz0 = Int(t.cz.rounded(.down))
    ctx.setStrokeColor(UIColor(white: 1, alpha: 0.09).cgColor)
    ctx.setLineWidth(1)
    for k in -reach...reach {
      let gx = Float(gx0 + k), gz = Float(gz0 + k)
      let lo0 = Float(gz0 - reach), hi0 = Float(gz0 + reach)
      let lo1 = Float(gx0 - reach), hi1 = Float(gx0 + reach)
      ctx.move(to: t.point(gx, lo0)); ctx.addLine(to: t.point(gx, hi0))
      ctx.move(to: t.point(lo1, gz)); ctx.addLine(to: t.point(hi1, gz))
    }
    ctx.strokePath()

    // Floor scanned so far.
    ctx.setFillColor(Self.snap.withAlphaComponent(0.18).cgColor)
    for f in floors where f.points.count >= 3 {
      ctx.addLines(between: f.points.map(sp))
      ctx.closePath()
      ctx.fillPath()
    }

    // Room outline.
    let n = corners.count
    // The user stands in the room, so before there is an outline the phone
    // is on the inside.
    let inside = n >= 3
      ? V3(corners.reduce(0) { $0 + $1.x } / Float(n), 0, corners.reduce(0) { $0 + $1.z } / Float(n))
      : snap.camPos

    func wallStroke(_ a: CGPoint, _ b: CGPoint) {
      ctx.saveGState()
      ctx.setStrokeColor(UIColor.white.cgColor)
      ctx.setLineWidth(6)
      ctx.setLineCap(.square)
      ctx.move(to: a)
      ctx.addLine(to: b)
      ctx.strokePath()
      ctx.restoreGState()
    }

    // Walls found so far. Before the outline (Auto) they are drawn as walls,
    // each with its length, the moment they are found; once there is an
    // outline (or while marking) they stay faint.
    let seenAsWalls = !marking && n < 3
    if seenAsWalls {
      for (a, b) in seen { wallStroke(sp(a), sp(b)) }
    } else {
      let seenColor = UIColor(red: 150 / 255, green: 175 / 255, blue: 1, alpha: 0.27)
      for (a, b) in seen { strokeLine(ctx, sp(a), sp(b), seenColor, width: 4) }
    }

    if marking {
      // Marked walls, the room not closed yet: solid, and dashed back to the
      // first corner once it could be closed.
      if n >= 2 { for i in 1..<n { wallStroke(sp(corners[i - 1]), sp(corners[i])) } }
      if n >= 3 { strokeLine(ctx, sp(corners[n - 1]), sp(corners[0]), UIColor(white: 1, alpha: 0.67), width: 2, dash: [5, 5]) }
    } else if n >= 3, let room {
      ctx.addLines(between: corners.map(sp))
      ctx.closePath()
      ctx.setFillColor(UIColor(white: 1, alpha: 0.1).cgColor)
      ctx.fillPath()
      for i in 0..<n {
        let a = sp(corners[i]), b = sp(corners[(i + 1) % n])
        if i < room.estimated.count && room.estimated[i] {
          strokeLine(ctx, a, b, Self.door, width: 3, dash: [7, 5])
        } else {
          ctx.saveGState()
          ctx.setStrokeColor(UIColor.white.cgColor)
          ctx.setLineWidth(6)
          ctx.setLineCap(.square)
          ctx.move(to: a)
          ctx.addLine(to: b)
          ctx.strokePath()
          ctx.restoreGState()
        }
      }
    }

    // Furniture found by the AI detector: its footprint and name.
    if !marking {
      let nameAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: UIColor(white: 1, alpha: 0.7),
      ]
      for f in furniture.confirmed {
        ctx.saveGState()
        ctx.addLines(between: f.footprint.map(sp))
        ctx.closePath()
        ctx.setFillColor(UIColor(white: 1, alpha: 0.16).cgColor)
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.6).cgColor)
        ctx.setLineWidth(1.5)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
        let s = f.kind as NSString
        let sz = s.size(withAttributes: nameAttrs)
        let c = sp(f.center)
        s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: nameAttrs)
      }
    }

    // Doors and windows: the wall cut open, then their symbol.
    for o in openings {
      let a = sp(o.a), b = sp(o.b)
      ctx.saveGState()
      ctx.setStrokeColor(Self.ink.cgColor)
      ctx.setLineWidth(8)
      ctx.setLineCap(.butt)
      ctx.move(to: a)
      ctx.addLine(to: b)
      ctx.strokePath()
      ctx.restoreGState()
      if o.type == Self.typeDoor {
        let swing = LivePlan.doorSwing(o.a, o.b, inside: inside)
        strokeLine(ctx, a, sp(swing.leaf), Self.door, width: 2)
        ctx.saveGState()
        ctx.setStrokeColor(Self.door.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.addLines(between: swing.arc.map(sp))
        ctx.strokePath()
        ctx.restoreGState()
      } else {
        let l = hypot(b.x - a.x, b.y - a.y)
        if l < 1 { continue }
        let nx = -(b.y - a.y) / l * 3.5, ny = (b.x - a.x) / l * 3.5
        ctx.saveGState()
        ctx.setStrokeColor(Self.window.cgColor)
        ctx.setLineWidth(2)
        ctx.addLines(between: [CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny),
                               CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)])
        ctx.closePath()
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()
      }
    }

    // A wall's length in a pill beside its middle, on the side away from the
    // room.
    let ic = sp(inside)
    let lenAttrs: [NSAttributedString.Key: Any] = [
      .font: PlanoraFont.inter(11, .semibold, tabular: true), .foregroundColor: UIColor.white,
    ]
    let labelInk = Self.rgb(30, 41, 59, 230)
    func lengthLabel(_ wa: V3, _ wb: V3, _ str: String, _ bg: UIColor) {
      let a = sp(wa), b = sp(wb)
      let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
      let l = hypot(b.x - a.x, b.y - a.y)
      if l < 18 { return }
      var nx = -(b.y - a.y) / l, ny = (b.x - a.x) / l
      if (ic.x - mid.x) * nx + (ic.y - mid.y) * ny > 0 { nx = -nx; ny = -ny }
      let text = str as NSString
      let sz = text.size(withAttributes: lenAttrs)
      let c = CGPoint(x: mid.x + nx * 16, y: mid.y + ny * 16)
      let pill = UIBezierPath(roundedRect: CGRect(x: c.x - sz.width / 2 - 7, y: c.y - 10,
                                                  width: sz.width + 14, height: 20), cornerRadius: 10)
      bg.setFill()
      pill.fill()
      text.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: lenAttrs)
    }

    // Wall lengths, outside the room.
    if marking {
      if n >= 2 { for i in 1..<n { lengthLabel(corners[i - 1], corners[i], m(corners[i - 1].dist2d(corners[i])), labelInk) } }
    } else if n >= 3, let room {
      for i in 0..<n {
        let est = i < room.estimated.count && room.estimated[i]
        lengthLabel(corners[i], corners[(i + 1) % n], m(room.side(i)) + (est ? " ?" : ""),
                    est ? Self.estChip : labelInk)
      }
    } else if seenAsWalls {
      for (a, b) in seen { lengthLabel(a, b, m(a.dist2d(b)), labelInk) }
    }

    // Corner mode: the wall being measured, from the last corner to the
    // crosshair, with its length as it changes; marked corners.
    if marking {
      if let aimP, let last = corners.last {
        strokeLine(ctx, sp(last), sp(aimP), Self.snap, width: 3, dash: [7, 5])
        lengthLabel(last, aimP, m(last.dist2d(aimP)), Self.snapChip)
      }
      for c in corners { fillCircle(ctx, sp(c), 4.5, Self.accent) }
      if let aimP {
        let c = sp(aimP)
        let hot = aim?.snappedCorner == true || aim?.closesRoom == true
        ctx.saveGState()
        ctx.setStrokeColor((hot ? Self.snap : UIColor.white).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
        ctx.restoreGState()
      }
    }

    // The phone: its field of view (forward is always up), the directions
    // looked at so far round it, and a dot.
    if snap.tracking {
      let c = sp(snap.camPos)
      let reachFov: CGFloat = 70, half = reachFov * 0.58 // tan 30°
      ctx.saveGState()
      ctx.addLines(between: [c, CGPoint(x: c.x - half, y: c.y - reachFov), CGPoint(x: c.x + half, y: c.y - reachFov)])
      ctx.closePath()
      ctx.clip()
      let colors = [Self.accent.withAlphaComponent(0.45).cgColor, Self.accent.withAlphaComponent(0).cgColor] as CFArray
      if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: c, end: CGPoint(x: c.x, y: c.y - reachFov), options: [])
      }
      ctx.restoreGState()
      // Sector i covers world directions from -180° + 30° i (atan2(z, x)).
      let ns = Self.sectorCount
      let step = 2 * CGFloat.pi / CGFloat(ns)
      ctx.saveGState()
      ctx.setLineWidth(3)
      ctx.setLineCap(.round)
      for i in 0..<ns {
        let a = Float(-Double.pi + (Double(i) + 0.5) * Double(step))
        let w = t.point(snap.camPos.x + cos(a), snap.camPos.z + sin(a))
        let ang = atan2(w.y - c.y, w.x - c.x)
        ctx.addArc(center: c, radius: 22, startAngle: ang - step / 2 + 0.05, endAngle: ang + step / 2 - 0.05,
                   clockwise: false)
        ctx.setStrokeColor((sectors[i] ? Self.snap : UIColor(white: 1, alpha: 0.24)).cgColor)
        ctx.strokePath()
      }
      ctx.restoreGState()
      fillCircle(ctx, c, 8, .white)
      fillCircle(ctx, c, 5.5, Self.accent)
    }
    ctx.restoreGState()

    // Header: size and area, then what was counted.
    let title: String
    if marking {
      switch n {
      case 0: title = "Aim at a corner on the floor and mark it"
      case 1: title = "Now aim at the next corner"
      default:
        var total: Float = 0
        for i in 1..<n { total += corners[i - 1].dist2d(corners[i]) }
        title = "\(n - 1) wall\(n == 2 ? "" : "s")  ·  \(m(total))"
          + (n >= 3 ? "  ·  " + String(format: "%.2f m²", LivePlan.area(corners)) : "")
      }
    } else if let room, n >= 3 {
      title = "\(m(room.width)) × \(m(room.depth))  ·  " + String(format: "%.2f m²", LivePlan.area(corners))
    } else if !seen.isEmpty {
      title = "\(seen.count) wall\(seen.count == 1 ? "" : "s") found"
    } else {
      title = "Point at the walls to start the plan"
    }
    (title as NSString).draw(at: CGPoint(x: left + 16, y: top + 10), withAttributes: [
      .font: PlanoraFont.inter(15, .semibold, tabular: true), .foregroundColor: UIColor.white,
    ])
    let sub = (elementsSummary() ?? "No doors or windows yet") + "  ·  tap for camera"
    (sub as NSString).draw(at: CGPoint(x: left + 16, y: top + 30), withAttributes: [
      .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor(white: 1, alpha: 0.67),
    ])
  }

  // ------------------------------------------------------------ constants

  private static let maxCloud = 40000
  /// Auto doors / windows: detections whose centres are this close are the
  /// same opening (an estimated wall shifts it a little between frames).
  private static let sameOpening: Float = 0.3
  /// A tap this soon after the result was stable still adds it.
  private static let stableGrace: TimeInterval = 2.5
  /// Limits for hits on the floor / ceiling beyond their detected area:
  /// at least about 8 degrees below (above) the horizon, at most 6 m away.
  private static let minExtendSlope: Float = 0.14
  private static let maxExtendDistance: Float = 6
  private static let sectorCount = 12
  /// Sectors (of `sectorCount`) seen before a room scan finishes by itself.
  private static let lookRoundSectors = sectorCount - 2
  private static let maxPathSamples = 2000
  /// Turning on the spot: this many sectors looked at while the phone has
  /// moved less than this far (metres).
  private static let spotSectors = 4
  private static let spotMove: Float = 0.4
  /// Auto-completion: the outline counts as unchanged while width and depth
  /// stay within 5 cm or 1.5 % (feature-point outlines jitter by a few
  /// centimetres, more in a large room) and the area within `stableArea`.
  /// It must stay so for `stableFor` seconds (longer without a floor, or
  /// with an estimated side after walking all the way round); the card then
  /// shows for `completeDelay` seconds before the scan finishes.
  private static let stableSideMin: Float = 0.05
  private static let stableSideShare: Float = 0.015
  private static let stableArea: Float = 0.25
  private static let stableFor: TimeInterval = 2.5
  private static let stableForNoFloor: TimeInterval = 6
  private static let stableForWalked: TimeInterval = 8
  /// "All the way round": sectors looked at (of 12) and metres moved.
  private static let walkedSectors = 11
  private static let walkedMove: Float = 0.8
  /// Diagnostics: seconds between files while scanning, files kept, log
  /// lines kept.
  private static let diagInterval: TimeInterval = 4
  private static let diagKeepFiles = 5
  private static let diagLogLines = 300
  private static let completeDelay: TimeInterval = 0.8
  private static let badgeSize: CGFloat = 96
  private static let landscapeTopWidth: CGFloat = 300
  private static let landscapePanelWidth: CGFloat = 320
  private static let typeDoor = 0
  private static let typeWindow = 1
  private static let hCorner = 0
  private static let hEdge = 1
  private static let hOpening = 2
  // 3 was the removed room-height mark.
  /// Second base point of a door / window, or corner B of a surface.
  private static let hBase = 4
  /// A door / window completed with its top (replaces hEdge + hBase).
  private static let hOpeningTop = 5
  /// A completed surface (replaces hEdge + hBase).
  private static let hSurface = 6
  /// A completed line (replaces hEdge).
  private static let hLine = 7
  private static let tabMinWidth: CGFloat = 64

  private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 255) -> UIColor {
    UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a / 255)
  }

  // ECM-AI palette.
  /// Ink #0B1426 and its lighter step #16213A.
  private static let ink = rgb(11, 20, 38)
  private static let ink2 = rgb(22, 33, 58)
  /// Panels: ink at 86 %.
  private static let panel = rgb(11, 20, 38, 219)
  /// Tint over the blur of the frosted panels and pills: ink at 70 %.
  private static let glassTint = rgb(11, 20, 38, 179)
  /// Completion and door / window cards: ink at 94 %.
  private static let cardFill = rgb(11, 20, 38, 240)
  /// Brand / plan blue #2F5BFF: primary emphasis.
  private static let accent = rgb(47, 91, 255)
  /// Scan teal #12C2A4: detected, measured, snapped, success.
  private static let snap = rgb(18, 194, 164)
  /// Danger #E5484D.
  private static let error = rgb(229, 72, 77)
  /// Estimated / door amber #E08A0B.
  private static let door = rgb(224, 138, 11)
  /// Window sky #0EA5E9.
  private static let window = rgb(14, 165, 233)
  /// Surface purple #8B5CF6.
  private static let surface = rgb(139, 92, 246)
  private static let line = rgb(250, 204, 21)
  private static let hairline = UIColor(white: 1, alpha: 0.14)
  /// Undo / disabled Finish button fill.
  private static let sideFill = UIColor(white: 1, alpha: 0.12)
  /// Chips: ink at 88 % by default; coloured ones a shade deeper than their
  /// colour so white text reads on them.
  private static let chipFill = rgb(11, 20, 38, 224)
  private static let snapChip = rgb(10, 138, 117, 235)
  private static let estChip = rgb(176, 104, 6, 235)
  private static let doorChip = rgb(196, 117, 8, 235)
  private static let windowChip = rgb(3, 125, 182, 235)
  private static let surfaceChip = rgb(109, 64, 217, 235)
  private static let errorChip = rgb(205, 52, 58, 235)
  /// Behind a line's length; white text does not read on the yellow itself.
  private static let lineChip = rgb(133, 77, 14, 230)
  /// Floor: teal 18 %; walls: brand blue 16 %.
  private static let floorFill = rgb(18, 194, 164, 46)
  private static let floorEdge = rgb(18, 194, 164, 140)
  private static let wallFill = rgb(47, 91, 255, 41)
  private static let wallEdge = rgb(120, 150, 255, 150)
  fileprivate static let chipFont = PlanoraFont.inter(13, .semibold, tabular: true)
}

/// Inter, the font of the Flutter UI, taken from the Flutter assets and
/// registered once; the system font when that fails.
private enum PlanoraFont {
  private static let registered: Bool = {
    var ok = true
    for name in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold"] {
      let key = FlutterDartProject.lookupKey(forAsset: "assets/fonts/\(name).ttf")
      guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
        ok = false
        continue
      }
      // Fails harmlessly when already registered.
      CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, nil)
    }
    return ok
  }()

  static func inter(_ size: CGFloat, _ weight: UIFont.Weight, tabular: Bool = false) -> UIFont {
    _ = registered
    let name: String
    switch weight {
    case .bold, .heavy, .black: name = "Inter-Bold"
    case .semibold: name = "Inter-SemiBold"
    case .medium: name = "Inter-Medium"
    default: name = "Inter-Regular"
    }
    let font = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    if !tabular { return font }
    let desc = font.fontDescriptor.addingAttributes([
      .featureSettings: [[
        UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
        UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
      ]],
    ])
    return UIFont(descriptor: desc, size: size)
  }
}

/// Draws the scanner overlay (surfaces, outline, crosshair) over the camera.
private final class OverlayView: UIView {
  weak var owner: ArMeasureViewController?

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    owner?.drawOverlay(ctx, bounds.size)
  }
}

/// Transparent view over the camera that passes a finger's position to the
/// scanner: a tap on the scene places a line point there.
private final class TapView: UIView {
  weak var owner: ArMeasureViewController?

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    super.point(inside: point, with: event) && owner?.tapAllowed(at: point) == true
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let t = touches.first else { return }
    owner?.tapMoved(to: t.location(in: self), began: true)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let t = touches.first else { return }
    owner?.tapMoved(to: t.location(in: self), began: false)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let t = touches.first else { return }
    owner?.tapEnded(at: t.location(in: self))
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    owner?.tapCancelled()
  }
}

/// The scrolling row of mode tabs; reports when its width changes.
private final class TabScrollView: UIScrollView {
  var onWidthChange: (() -> Void)?
  private var lastWidth: CGFloat = -1

  /// The row is all buttons: a drag that starts on one must still scroll.
  override func touchesShouldCancel(in view: UIView) -> Bool { true }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.width != lastWidth {
      lastWidth = bounds.width
      onWidthChange?()
    }
  }
}

/// A label with padding around its text.
private final class PaddedLabel: UILabel {
  var insets = UIEdgeInsets.zero

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: insets))
  }

  override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
    let r = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
    return r.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left,
                                    bottom: -insets.bottom, right: -insets.right))
  }
}
