# Room Measure

Flutter app that scans a room with the camera and produces a measured 2D floor plan.

## How scanning works per device

| Device | Scanner | Code |
| --- | --- | --- |
| Android with ARCore | Guided scan (auto room detection, or mark corners / doors / windows / height) | `android/app/src/main/kotlin/.../ArMeasureActivity.kt`, `RoomDetector.kt` |
| iPhone / iPad without LiDAR | Same guided scan, on ARKit | `ios/Runner/ArMeasureViewController.swift`, `RoomDetector.swift` |
| iPhone / iPad Pro with LiDAR | Apple RoomPlan (fully automatic) | `roomplan_flutter` plugin, `lib/capture/roomplan_mapper.dart` |

While a room is scanned, every scanner shows a live 2D floor plan under the
camera image (heading-up: the way the phone faces is the top of the plan) with
the walls, doors and windows found so far; tap it to switch to the camera
overlay. Each wall is drawn with its length the moment it is found (parts of
one wall are joined into one line). In Auto mode the camera image also shows
the walls found so far outlined in white (floor, ceiling and the corners
floor to ceiling, joined with `LivePlan.connectWalls`), doors and windows as
white frames and furniture as white boxes, growing as the user turns round
the room. The camera fills the screen; the plan is a small map (tap it for
the big plan).
LiDAR scans do the same with RoomPlan's walls (`WallLinesView`). In Corner mode the plan shows each wall
as its corner is marked, plus a live line from the last corner to the
crosshair with its length. The plan's geometry is in `LivePlan.kt` / `LivePlan.swift` (keep them
in sync). For LiDAR devices `roomplan_flutter` is vendored in
`packages/roomplan_flutter` (MIT) so its scanning screen can show this plan
instead of RoomPlan's 3D view (`PlanScanViewController.swift`).

LiDAR scans also support (all in the vendored plugin plus
`lib/capture/roomplan_mapper.dart`):

- **Several rooms in one go:** "Room done" (or the scan finding the room
  complete) ends a room; then scan the next room or Finish. Rooms share one
  coordinate system and are merged by RoomPlan's `StructureBuilder`; the app
  saves them as rooms on a new floor map, placed as scanned.
- **Ceiling height** from the walls' heights (summary, PDF, CSV, wall area,
  door/window drawings).
- **Photos** taken while scanning, pinned on the plan where they were taken;
  **torch** for dark rooms.
- **CSV** export of rooms, walls and openings (opens in Excel).
- **Room names** suggested from RoomPlan's room type or the furniture found.

### 3D view and CAD export (`lib/scanner/`)

Every scanned room (any scanner) and every floor map can be seen in 3D and
exported for CAD and 3D software, like a LiDAR room-scanner app:

- **3D view** (the 3D button on a room or a floor map;
  `scanner_3d_screen.dart`, `room_3d_view.dart`): walls at the measured
  ceiling height (2.44 m when the scan could not measure it, and the screen
  says so), with doors, windows and gaps cut out at their height and sill,
  and furniture as boxes. It opens on the plan from above and swings up into
  3D. Drag to turn, pinch to zoom, two fingers to move, double tap to reset;
  Plan (2D) / 3D / Turn 90° buttons; walls between the camera and the room
  fade ("See-through walls") so the inside can be seen; tap a wall for its
  length, height, area and openings. Floor area, perimeter, ceiling and wall
  area are shown below. Drawn with a custom painter, so no 3D plugin is needed.
- **CAD drawing (DXF)** (`cad_export.dart`): the plan as a DXF R12 file in
  metres, with walls as double lines (10 cm), door leaves and swings, window
  lines, wall lengths, room names and areas, and furniture, on the layers
  WALLS, DOORS, WINDOWS, OPENINGS, FURNITURE, DIMENSIONS and ROOMS. A floor
  map exports all its rooms where they are placed.
- **3D model (OBJ + MTL)**: the same model as the 3D view, for Blender,
  SketchUp, 3ds Max, etc.

The model is built by `room_model_3d.dart` from the same `FloorPlan` as the
2D plan, so edits to the plan show in 3D and in the exports.

### AI furniture, laser meters and 360° photos

- **AI furniture detection** (camera scanner, Auto mode): an on-device
  detector finds beds, sofas, chairs, tables, toilets, fridges, ovens and
  plants in the camera image, places each where it stands on the floor, and
  keeps it once 3 images agree. Android: MediaPipe Object Detector with
  `android/app/src/main/assets/efficientdet_lite0.tflite` (Apache 2.0).
  iPhone: Vision with `ios/Runner/YOLOv3TinyInt8LUT.mlmodel` (Apple's
  conversion of YOLOv3 Tiny, MIT). Logic in `FurnitureDetector.kt` /
  `FurnitureDetector.swift` (keep in sync). LiDAR scans get furniture from
  RoomPlan. Furniture is drawn on the plan and in exports.
- **Bluetooth laser meter** (Leica DISTO, Bluetooth LE;
  `lib/services/laser_meter.dart`, `flutter_reactive_ble`): every length box
  has a laser button. Press measure on the DISTO and the distance goes into
  the selected box, then the next box is selected. No commands are sent, so
  it works across DISTO models (distance characteristic 3ab10101 or 3ab1010d).
- **360° photos**: Room > ⋮ > Add 360° photo picks a 360° photo from the
  gallery (any 360° camera's app saves them there), the user taps where it
  was taken, and the "360" pin on the plan opens it in a 360° viewer.

Android is compiled against SDK 37 (needed by `flutter_reactive_ble`);
`minSdk` and `targetSdk` are unchanged.

Both guided scanners talk to Dart over the `room_measure/ar` method channel and
return the same result map. `RoomDetector.kt` and `RoomDetector.swift` are the
same algorithm; change them together.

## Running on iOS

iOS builds need a Mac with Xcode 15 or newer and an iPhone/iPad on **iOS 17+**
(the camera does not work in the Simulator).

1. Copy the project to the Mac (or clone it) and run `flutter pub get`.
2. Open `ios/Runner.xcworkspace` in Xcode, select the **Runner** target >
   **Signing & Capabilities**, tick *Automatically manage signing* and pick your
   Team. If the bundle id `com.nativesoftware.roomMeasure` is taken, change it
   to something unique.
3. Connect the phone, trust the Mac, and enable **Developer Mode** on the phone
   (Settings > Privacy & Security > Developer Mode).
4. Run `flutter run` (or press Run in Xcode). The first time, trust the
   developer certificate on the phone under Settings > General > VPN & Device
   Management.

The project uses Swift Package Manager for plugins, so CocoaPods is not needed.
If your Flutter has Swift Package Manager turned off, either turn it on
(`flutter config --enable-swift-package-manager`) or, when Flutter generates an
`ios/Podfile`, set `platform :ios, '17.0'` in it.

Scanner logs (what was detected, the room found, why a scan failed) appear in
the Xcode console and in Console.app filtered by `RoomMeasureAR`.
