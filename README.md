# Room Measure

Flutter app that scans a room with the camera and produces a measured 2D floor plan.

## How scanning works per device

| Device | Scanner | Code |
| --- | --- | --- |
| Android with ARCore | Guided scan (auto room detection, or mark corners / doors / windows / height) | `android/app/src/main/kotlin/.../ArMeasureActivity.kt`, `RoomDetector.kt` |
| iPhone / iPad without LiDAR | Same guided scan, on ARKit | `ios/Runner/ArMeasureViewController.swift`, `RoomDetector.swift` |
| iPhone / iPad Pro with LiDAR | Apple RoomPlan (fully automatic) | `roomplan_flutter` plugin, `lib/capture/roomplan_mapper.dart` |

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
