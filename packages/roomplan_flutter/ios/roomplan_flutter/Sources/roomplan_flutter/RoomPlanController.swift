import ARKit
import AVFoundation
import Darwin
import Flutter
import Foundation
import RoomPlan

/// Comprehensive error types for RoomPlan operations with detailed debugging information
enum RoomPlanError: Error {
    case roomPlanNotSupported
    case cameraPermissionDenied
    case cameraPermissionNotDetermined
    case cameraPermissionUnknown
    case arKitNotSupported
    case insufficientHardware
    case lowPowerMode
    case insufficientStorage
    case sessionInProgress
    case sessionNotRunning
    case worldTrackingFailed
    case memoryPressure
    case backgroundModeActive
    case deviceOverheating
    case networkRequired
    case processingFailed(String)
    case dataCorrupted(String)
    case exportFailed(String)
    case timeout(String)
    
    /// Error code for Flutter communication
    var code: String {
        switch self {
        case .roomPlanNotSupported:
            return "roomplan_not_supported"
        case .cameraPermissionDenied:
            return "camera_permission_denied"
        case .cameraPermissionNotDetermined:
            return "camera_permission_not_determined"
        case .cameraPermissionUnknown:
            return "camera_permission_unknown"
        case .arKitNotSupported:
            return "arkit_not_supported"
        case .insufficientHardware:
            return "insufficient_hardware"
        case .lowPowerMode:
            return "low_power_mode"
        case .insufficientStorage:
            return "insufficient_storage"
        case .sessionInProgress:
            return "session_in_progress"
        case .sessionNotRunning:
            return "session_not_running"
        case .worldTrackingFailed:
            return "world_tracking_failed"
        case .memoryPressure:
            return "memory_pressure"
        case .backgroundModeActive:
            return "background_mode_active"
        case .deviceOverheating:
            return "device_overheating"
        case .networkRequired:
            return "network_required"
        case .processingFailed:
            return "processing_failed"
        case .dataCorrupted:
            return "data_corrupted"
        case .exportFailed:
            return "export_failed"
        case .timeout:
            return "timeout"
        }
    }
    
    /// Human-readable error message
    var message: String {
        switch self {
        case .roomPlanNotSupported:
            return "RoomPlan is not supported on this device. A LiDAR sensor is required."
        case .cameraPermissionDenied:
            return "Camera access has been denied. Please enable camera permission in Settings."
        case .cameraPermissionNotDetermined:
            return "Camera permission has not been requested. Please grant camera access when prompted."
        case .cameraPermissionUnknown:
            return "Camera permission status is unknown. Please check app permissions in Settings."
        case .arKitNotSupported:
            return "ARKit is not supported on this device. World tracking capability is required."
        case .insufficientHardware:
            return "This device lacks the necessary hardware for room scanning. A LiDAR sensor or ARKit scene reconstruction is required."
        case .lowPowerMode:
            return "Room scanning is disabled while Low Power Mode is active. Please disable Low Power Mode in Settings."
        case .insufficientStorage:
            return "Insufficient storage space available. At least 100MB of free space is required for room scanning."
        case .sessionInProgress:
            return "A room scanning session is already in progress. Please complete or cancel the current session before starting a new one."
        case .sessionNotRunning:
            return "No room scanning session is currently running. Please start a session before attempting to stop it."
        case .worldTrackingFailed:
            return "World tracking failed. Please ensure adequate lighting and try scanning in a different area."
        case .memoryPressure:
            return "The device is experiencing memory pressure. Please close other apps and try again."
        case .backgroundModeActive:
            return "Room scanning cannot continue while the app is in the background."
        case .deviceOverheating:
            return "The device is overheating. Please let it cool down before continuing room scanning."
        case .networkRequired:
            return "A network connection is required for this operation."
        case .processingFailed(let details):
            return "Failed to process scan data: \(details)"
        case .dataCorrupted(let details):
            return "Scan data appears to be corrupted: \(details)"
        case .exportFailed(let details):
            return "Failed to export scan results: \(details)"
        case .timeout(let operation):
            return "The operation '\(operation)' timed out. Please try again."
        }
    }
    
    /// Additional debugging details
    var details: String? {
        switch self {
        case .roomPlanNotSupported:
            return "Device model: \(UIDevice.current.model). RoomCaptureSession.isSupported: \(RoomCaptureSession.isSupported)"
        case .cameraPermissionDenied, .cameraPermissionNotDetermined, .cameraPermissionUnknown:
            return "Current camera authorization status: \(AVCaptureDevice.authorizationStatus(for: .video).debugDescription)"
        case .arKitNotSupported:
            return "ARWorldTrackingConfiguration.isSupported: \(ARWorldTrackingConfiguration.isSupported)"
        case .insufficientHardware:
            let supportsSceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            return "Scene reconstruction support: \(supportsSceneReconstruction), Device model: \(getDeviceModel())"
        case .lowPowerMode:
            return "Low Power Mode enabled: \(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        case .insufficientStorage:
            return "Available storage: \(getAvailableStorageString())"
        case .memoryPressure:
            return "Available memory: \(getAvailableMemoryString())"
        case .deviceOverheating:
            return "Thermal state: \(ProcessInfo.processInfo.thermalState.debugDescription)"
        case .processingFailed(let details), .dataCorrupted(let details), .exportFailed(let details), .timeout(let details):
            return details
        default:
            return nil
        }
    }
    
    /// Recovery suggestions for the user
    var recoverySuggestion: String? {
        switch self {
        case .roomPlanNotSupported:
            return "Use a device with a LiDAR sensor (iPhone 12 Pro or newer Pro models, iPad Pro with LiDAR)."
        case .cameraPermissionDenied:
            return "Go to Settings > Privacy & Security > Camera and enable access for this app."
        case .cameraPermissionNotDetermined:
            return "Grant camera permission when prompted to enable room scanning."
        case .arKitNotSupported:
            return "Use a newer device that supports ARKit world tracking."
        case .insufficientHardware:
            return "Use a device with LiDAR sensor or better ARKit capabilities."
        case .lowPowerMode:
            return "Go to Settings > Battery and turn off Low Power Mode."
        case .insufficientStorage:
            return "Free up at least 100MB of storage space and try again."
        case .sessionInProgress:
            return "Complete or cancel the current scanning session before starting a new one."
        case .worldTrackingFailed:
            return "Ensure good lighting conditions and try scanning a different area with more distinct features."
        case .memoryPressure:
            return "Close other apps and restart the room scanning process."
        case .backgroundModeActive:
            return "Return to the app to continue room scanning."
        case .deviceOverheating:
            return "Let your device cool down for a few minutes before continuing."
        default:
            return "Please try again or contact support if the issue persists."
        }
    }
}

// MARK: - Helper Functions

private func getDeviceModel() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
            String(cString: $0)
        }
    }
}

private func getAvailableStorageString() -> String {
    do {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let values = try documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let bytes = values.volumeAvailableCapacity ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    } catch {
        return "Unknown"
    }
}

private func getAvailableMemoryString() -> String {
    let physicalMemory = ProcessInfo.processInfo.physicalMemory
    return ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
}

// MARK: - Extensions for debugging

extension AVAuthorizationStatus {
    var debugDescription: String {
        switch self {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
}

extension ProcessInfo.ThermalState {
    var debugDescription: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// A singleton class that manages the RoomPlan session and communication with Flutter.
///
/// This class is responsible for:
/// - Starting and stopping the `RoomCaptureSession`.
/// - Handling the `RoomCaptureSessionDelegate` events.
/// - Acting as a `FlutterStreamHandler` to send real-time scan updates to Flutter.
class RoomPlanController: NSObject, RoomCaptureSessionDelegate, FlutterStreamHandler, UIAdaptivePresentationControllerDelegate {
  /// The shared singleton instance.
  static let shared = RoomPlanController()

  /// The method channel used to communicate with Flutter.
  var channel: FlutterMethodChannel?
  /// Room Measure: a bare session shown by PlanScanViewController (camera +
  /// live 2D plan) instead of RoomCaptureView's 3D view.
  private var captureSession: RoomCaptureSession?
  private weak var planVC: PlanScanViewController?
  private var flutterResult: FlutterResult?
  private var startTime: Date?
  private var endTime: Date?

  /// The event sink for the Flutter event channel.
  private var eventSink: FlutterEventSink?

  // Room Measure: several rooms in one session. Each room is captured on its
  // own ("Room done"), keeping the AR session running in between so every
  // room is in the same coordinates; at the end RoomPlan's StructureBuilder
  // merges them into one floor.
  /// The rooms finished so far, in the order scanned.
  private var rooms: [CapturedRoom] = []
  /// Photos taken while scanning (see ScanPhoto in Dart).
  private var photos: [SerializablePhoto] = []
  /// A room is being captured now.
  private var capturing = false
  /// What to do once the room being stopped is built.
  private var finishAllAfterStop = false
  private let configuration = RoomCaptureSession.Configuration()

  private override init() {}

  /// Starts a new RoomPlan session.
  ///
  /// This method presents the `RoomCaptureView` and starts the scanning process.
  /// The `result` closure is called when the scan is finished or an error occurs.
  func startSession(result: @escaping FlutterResult) {
    // Ask for camera access on first use; without this the status stays notDetermined forever
    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
        DispatchQueue.main.async { self?.startSession(result: result) }
      }
      return
    }

    self.flutterResult = result

    // Pre-flight checks with detailed error codes
    do {
      try performPreflightChecks()
    } catch let error as RoomPlanError {
      result(FlutterError(code: error.code, message: error.message, details: error.details))
      return
    } catch {
      result(FlutterError(code: "unknown_error", message: "An unexpected error occurred.", details: error.localizedDescription))
      return
    }

    let session = RoomCaptureSession()
    session.delegate = self
    captureSession = session
    rooms = []
    photos = []
    finishAllAfterStop = false

    let vc = PlanScanViewController(session: session)
    vc.onRoomDone = { [weak self] in self?.finishRoom() }
    vc.onNextRoom = { [weak self] in self?.startNextRoom() }
    vc.onFinish = { [weak self] in self?.doneScanning() }
    vc.onPhoto = { [weak self] photo in
      guard let self else { return }
      var p = photo
      p.room = self.rooms.count
      self.photos.append(p)
    }
    planVC = vc

    let navVC = UINavigationController(rootViewController: vc)
    // Full screen: a swipe down must not throw the rooms scanned away.
    navVC.modalPresentationStyle = .fullScreen

    // Handle swipe-to-dismiss: ensure the Dart Future always completes
    if #available(iOS 13.0, *) {
      navVC.presentationController?.delegate = self
    }

    let doneButton = UIBarButtonItem(
      title: "Finish", style: .done, target: self, action: #selector(doneScanning))
    let cancelButton = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(cancelScanning))
    vc.navigationItem.rightBarButtonItem = doneButton
    vc.navigationItem.leftBarButtonItem = cancelButton
    vc.navigationItem.title = "Room 1"

    guard let rootViewController = getRootViewController() else {
      result(FlutterError(code: "ui_error", message: "Unable to access root view controller.", details: "The app's UI hierarchy might not be properly initialized."))
      return
    }
    
    rootViewController.present(navVC, animated: true) { [weak self] in
      guard let self else { return }
      self.captureSession?.run(configuration: self.configuration)
      self.capturing = true
    }
  }

  /// Room Measure: ends the room being captured ("Room done", or the scan
  /// found it complete). Once RoomPlan has built it, the screen offers the
  /// next room or Finish.
  func finishRoom() {
    guard capturing, let session = captureSession else { return }
    capturing = false
    finishAllAfterStop = false
    planVC?.showBusy("Saving room \(rooms.count + 1)…")
    // The AR session keeps running, so the next room is in the same
    // coordinates as this one.
    session.stop(pauseARSession: false)
  }

  /// Room Measure: starts capturing the next room in the same session.
  private func startNextRoom() {
    guard !capturing, let session = captureSession else { return }
    planVC?.startRoom(index: rooms.count, done: rooms)
    session.run(configuration: configuration)
    capturing = true
  }

  /// Room Measure: the whole scan is done: the rooms are merged into one
  /// floor (several rooms) and sent to Flutter.
  private func finishAll() {
    let captured = rooms
    let shots = photos
    planVC?.showBusy(captured.count > 1 ? "Joining \(captured.count) rooms…" : "Building the floor plan…")
    if captured.isEmpty {
      finish(FlutterError(code: "processing_failed", message: "No room was scanned.", details: nil))
      return
    }
    let metadata: [String: Any] = [
      "session_duration": Date().timeIntervalSince(startTime ?? Date()),
      "device_model": UIDevice.current.model,
      "has_lidar": detectLiDAR(),
    ]
    Task.detached(priority: .userInitiated) { [weak self] in
      let payload: Any
      do {
        payload = try await RoomPlanController.finalPayload(rooms: captured, photos: shots, metadata: metadata)
      } catch {
        payload = FlutterError(
          code: "serialization_error", message: "Failed to serialize final room data.",
          details: error.localizedDescription)
      }
      await MainActor.run { self?.finish(payload) }
    }
  }

  /// The final JSON: every room (merged into one structure when there are
  /// several), its type, and the photos. Only 2D data: no 3D model is made.
  private static func finalPayload(rooms captured: [CapturedRoom], photos: [SerializablePhoto],
                                   metadata: [String: Any]) async throws -> String? {
    var final = captured
    if captured.count > 1 {
      // Merged: walls shared by two rooms are joined, and the rooms line up.
      // Without it the rooms are still in one coordinate system.
      if let structure = try? await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: captured),
         !structure.rooms.isEmpty {
        final = structure.rooms
      }
    }
    let types = final.map { RoomPlanJSONConverter.roomType($0) }
    return try RoomPlanJSONConverter.convertFinal(
      rooms: final, types: types, photos: photos, metadata: metadata)
  }

  /// Returns the root view controller using the modern UIWindowScene API.
  private func getRootViewController() -> UIViewController? {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) else {
      return nil
    }
    return keyWindow.rootViewController
  }
  
  /// Performs comprehensive pre-flight checks before starting a scan
  private func performPreflightChecks() throws {
    // Check RoomPlan availability
    guard RoomCaptureSession.isSupported else {
      throw RoomPlanError.roomPlanNotSupported
    }
    
    // Check camera permission
    let cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
    switch cameraAuthStatus {
    case .denied, .restricted:
      throw RoomPlanError.cameraPermissionDenied
    case .notDetermined:
      throw RoomPlanError.cameraPermissionNotDetermined
    case .authorized:
      break
    @unknown default:
      throw RoomPlanError.cameraPermissionUnknown
    }
    
    // Check ARKit availability
    guard ARWorldTrackingConfiguration.isSupported else {
      throw RoomPlanError.arKitNotSupported
    }
    
    // Check device capabilities
    let hasRequiredFeatures = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) || isLiDARDevice()
    guard hasRequiredFeatures else {
      throw RoomPlanError.insufficientHardware
    }
    
    // Check system resources
    if ProcessInfo.processInfo.isLowPowerModeEnabled {
      throw RoomPlanError.lowPowerMode
    }
    
    // Check available storage (need at least 100MB for scan data)
    let freeSpace = try getAvailableStorage()
    if freeSpace < 100 * 1024 * 1024 { // 100MB in bytes
      throw RoomPlanError.insufficientStorage
    }
  }
  
  /// Gets available storage space in bytes
  private func getAvailableStorage() throws -> Int64 {
    let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let values = try documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
    return Int64(values.volumeAvailableCapacity ?? 0)
  }

  /// Called when the user taps the 'Done' button in the scanning UI.
  /// The view is dismissed in `didEndWith`, after RoomBuilder finishes processing.
  /// Room Measure: Finish: the room being captured (if any) is built first,
  /// then everything is sent.
  @objc func doneScanning() {
    planVC?.navigationItem.rightBarButtonItem?.isEnabled = false
    if capturing, let session = captureSession {
      capturing = false
      finishAllAfterStop = true
      planVC?.showBusy("Saving room \(rooms.count + 1)…")
      session.stop()
    } else {
      finishAll()
    }
  }

  /// Called when the user taps the 'Cancel' button in the scanning UI.
  @objc func cancelScanning() {
    capturing = false
    rooms = []
    photos = []
    // Answered now (a dismiss from code is not a swipe-dismiss, so nothing
    // else would answer); the room being stopped is then ignored.
    flutterResult?(FlutterError(code: "CANCELED", message: "Scan was cancelled by the user.", details: nil))
    flutterResult = nil
    captureSession?.stop()
    captureSession = nil
    dismiss()
  }

  /// Stops the current RoomPlan session: as Finish (everything scanned so
  /// far is sent through startScanning's result).
  func stopSession(result: @escaping FlutterResult) {
    doneScanning()
    result(nil)
  }

  /// Dismisses the presented view controller.
  func dismiss() {
    guard let rootViewController = getRootViewController() else { return }
    rootViewController.dismiss(animated: true)
  }

  // MARK: - UIAdaptivePresentationControllerDelegate

  /// Called when the user swipe-dismisses the scanning UI.
  /// Ensures the Dart Future always completes instead of hanging forever.
  public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if let result = flutterResult {
      result(FlutterError(
        code: "CANCELED",
        message: "Scan was cancelled by the user.",
        details: nil))
      flutterResult = nil
    }
  }

  // MARK: - RoomCaptureSessionDelegate
  /// Called when the room layout is updated during a scan.
  public func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
    // The live 2D plan, and how far round the user has looked (read on the
    // main thread, where the plan tracks it).
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.planVC?.update(room)
      let seen = self.planVC?.sectorsSeen ?? 0
      self.sendUpdate(room, metadata: ["lookRoundSectors": seen, "roomIndex": self.rooms.count])
    }
  }

  /// Sends a live room update to Flutter (main thread).
  private func sendUpdate(_ room: CapturedRoom, metadata: [String: Any]) {
    if let eventSink = eventSink {
      // Go to a background thread to do the heavy encoding work
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let json = try RoomPlanJSONConverter.convertToJSON(capturedRoom: room, metadata: metadata)
          // Go back to the main thread to send the result to Flutter
          DispatchQueue.main.async {
            eventSink(json)
          }
        } catch {
          // Go back to the main thread to send the error to Flutter
          DispatchQueue.main.async {
            eventSink(
              FlutterError(
                code: "serialization_error", message: "Failed to serialize room data.",
                details: error.localizedDescription))
          }
        }
      }
    }
  }

  /// Called when the scanning session ends.
  public func captureSession(
    _ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?
  ) {
    endTime = Date()
    // Cancelled: Flutter has had its answer; nothing is kept.
    if flutterResult == nil { return }

    // Room Measure: one room has ended. It is built (off the main thread),
    // then either the next room is offered or, after Finish, everything is
    // sent.
    let failed: (String) -> Void = { [weak self] message in
      guard let self else { return }
      if self.rooms.isEmpty {
        self.finish(FlutterError(code: "processing_failed", message: message, details: nil))
      } else if self.finishAllAfterStop {
        // The rooms already scanned are kept.
        self.finishAll()
      } else {
        self.planVC?.showRoomDone(index: self.rooms.count, room: nil, failure: message)
      }
    }
    if let error = error {
      DispatchQueue.main.async { failed(error.localizedDescription) }
      return
    }
    Task.detached(priority: .userInitiated) { [weak self] in
      do {
        let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
        await MainActor.run {
          guard let self, self.flutterResult != nil else { return }
          self.rooms.append(room)
          if self.finishAllAfterStop {
            self.finishAll()
          } else {
            self.planVC?.showRoomDone(index: self.rooms.count - 1, room: room, failure: nil)
          }
        }
      } catch {
        await MainActor.run { failed("This room could not be built: \(error.localizedDescription)") }
      }
    }
  }

  /// Sends the final result to Flutter once, then dismisses the scanning UI.
  private func finish(_ payload: Any) {
    flutterResult?(payload)
    flutterResult = nil
    captureSession = nil
    capturing = false
    rooms = []
    photos = []
    dismiss()
  }

  /// RoomPlan's coaching (move closer, slow down...), shown over the camera.
  public func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
    DispatchQueue.main.async { [weak self] in self?.planVC?.show(instruction) }
  }

  /// Called when the scanning session starts.
  public func captureSession(
    _ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration
  ) {
    startTime = Date()
  }

  /// Called when the scanning session fails.
  public func captureSession(
    _ session: RoomCaptureSession, didFailWith error: Error
  ) {
    let roomPlanError = classifyError(error)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.flutterResult != nil else { return }
      self.capturing = false
      // Rooms already finished are not lost: they are sent as the result.
      if !self.rooms.isEmpty {
        self.finishAll()
        return
      }
      self.finish(FlutterError(
        code: roomPlanError.code,
        message: roomPlanError.message,
        details: roomPlanError.details
      ))
    }
  }
  
  /// Classifies native errors into specific RoomPlanError types
  private func classifyError(_ error: Error) -> RoomPlanError {
    let errorDescription = error.localizedDescription.lowercased()
    
    // Check for specific error patterns
    if errorDescription.contains("world tracking") || errorDescription.contains("not available") {
      return .worldTrackingFailed
    } else if errorDescription.contains("memory") || errorDescription.contains("resources") {
      return .memoryPressure
    } else if errorDescription.contains("permission") || errorDescription.contains("camera") {
      return .cameraPermissionDenied
    } else if errorDescription.contains("background") {
      return .backgroundModeActive
    } else if errorDescription.contains("thermal") || errorDescription.contains("overheat") {
      return .deviceOverheating
    } else if errorDescription.contains("timeout") {
      return .timeout("Room scanning session")
    } else if errorDescription.contains("corrupt") || errorDescription.contains("invalid") {
      return .dataCorrupted(error.localizedDescription)
    } else {
      return .processingFailed(error.localizedDescription)
    }
  }

  // MARK: - FlutterStreamHandler
  /// Sets up the event channel stream.
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    self.eventSink = events
    return nil
  }

  /// Tears down the event channel stream.
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  /// Detects LiDAR capability using multiple methods for better accuracy
  private func detectLiDAR() -> Bool {
    let supportsSceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(
      .mesh)
    let hasLidarByModel = isLiDARDevice()

    return supportsSceneReconstruction || hasLidarByModel
  }

  /// Checks if the current device model supports LiDAR
  private func isLiDARDevice() -> Bool {
    var systemInfo = utsname()
    uname(&systemInfo)
    let modelCode = withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        ptr in String(cString: ptr)
      }
    }

    let model = modelCode

    // iPhone models with LiDAR
    let lidarIPhones = [
      "iPhone13,2", "iPhone13,3", "iPhone13,4",  // iPhone 12 Pro, 12 Pro Max
      "iPhone14,2", "iPhone14,3",  // iPhone 13 Pro, 13 Pro Max
      "iPhone15,2", "iPhone15,3",  // iPhone 14 Pro, 14 Pro Max
      "iPhone16,1", "iPhone16,2",  // iPhone 15 Pro, 15 Pro Max
      "iPhone17,1", "iPhone17,2",  // iPhone 16 Pro, 16 Pro Max
      "iPhone18,1", "iPhone18,2",  // iPhone 17 Pro, 17 Pro Max
      "iPhone19,2", "iPhone19,3", "iPhone19,7",  // iPhone 18 Pro, 18 Pro Max (19,3 US, 19,7 other regions)
    ]

    // iPad models with LiDAR
    let lidarIPads = [
      "iPad8,9", "iPad8,10", "iPad8,11", "iPad8,12",  // iPad Pro 11" (4th gen), 12.9" (4th gen)
      "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7", "iPad13,8", "iPad13,9", "iPad13,10",
      "iPad13,11",  // iPad Pro 11" (5th gen), 12.9" (5th gen)
      "iPad14,3", "iPad14,4", "iPad14,5", "iPad14,6",  // iPad Pro 11" (6th gen), 12.9" (6th gen)
      "iPad16,3", "iPad16,4", "iPad16,5", "iPad16,6",  // iPad Pro 11" (M4), 13" (M4)
      "iPad17,1", "iPad17,2", "iPad17,3", "iPad17,4",  // iPad Pro 11" (M5), 13" (M5)
    ]

    return lidarIPhones.contains(model) || lidarIPads.contains(model)
  }
}
