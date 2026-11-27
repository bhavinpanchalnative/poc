package com.nativesoftware.room_measure

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingBluetooth: MethodChannel.Result? = null

    /** Android 12+: scan and connect; older: location (needed to scan). */
    private fun bluetoothPermissions(): List<String> =
        if (android.os.Build.VERSION.SDK_INT >= 31) {
            listOf(android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_BLUETOOTH) return
        pendingBluetooth?.success(
            grantResults.isNotEmpty() && grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED },
        )
        pendingBluetooth = null
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        forwardPlayback(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        forwardPlayback(intent)
    }

    /**
     * Debug builds only: replays a recorded scan in the scanner, for tuning
     * detection without re-scanning a room:
     * adb shell am start -n com.nativesoftware.room_measure/.MainActivity --es playback <file.mp4>
     */
    private fun forwardPlayback(i: Intent?) {
        val path = i?.getStringExtra(ArMeasureActivity.EXTRA_PLAYBACK) ?: return
        if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) == 0) return
        i.removeExtra(ArMeasureActivity.EXTRA_PLAYBACK)
        startActivity(Intent(this, ArMeasureActivity::class.java).putExtra(ArMeasureActivity.EXTRA_PLAYBACK, path))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Opens the camera measuring screen. Returns null when the
                    // user backs out, {error} on failure, or {xs, zs,
                    // openings, floorY?, openingDetails, surfaces, lines,
                    // lineOnly, ...}. With {"startMode": "line"} it opens just
                    // to measure distances: xs and zs are then empty.
                    "measure" -> {
                        if (pending != null) {
                            result.error("busy", "Measuring is already open", null)
                        } else {
                            pending = result
                            @Suppress("DEPRECATION")
                            startActivityForResult(
                                Intent(this, ArMeasureActivity::class.java).apply {
                                    call.argument<String>("startMode")?.let {
                                        putExtra(ArMeasureActivity.EXTRA_START_MODE, it)
                                    }
                                },
                                REQ_MEASURE,
                            )
                        }
                    }
                    // Laser meter: asks for the Bluetooth permissions needed
                    // to find and connect to it. Returns true when granted.
                    "bluetoothPermission" -> {
                        val needed = bluetoothPermissions().filter {
                            checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED
                        }
                        if (needed.isEmpty()) {
                            result.success(true)
                        } else if (pendingBluetooth != null) {
                            result.error("busy", "Already asking", null)
                        } else {
                            pendingBluetooth = result
                            requestPermissions(needed.toTypedArray(), REQ_BLUETOOTH)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_MEASURE) return
        val result = pending ?: return
        pending = null
        if (resultCode != RESULT_OK || data == null) {
            result.success(null)
            return
        }
        val error = data.getStringExtra(ArMeasureActivity.EXTRA_ERROR)
        if (error != null) {
            result.success(mapOf("error" to error))
            return
        }
        // Empty (not null) arrays when only distances were measured.
        val xs = data.getDoubleArrayExtra(ArMeasureActivity.EXTRA_XS)
        val zs = data.getDoubleArrayExtra(ArMeasureActivity.EXTRA_ZS)
        if (xs == null || zs == null) {
            result.success(null)
            return
        }
        val out = mutableMapOf<String, Any>("xs" to xs.toList(), "zs" to zs.toList())
        data.getDoubleArrayExtra(ArMeasureActivity.EXTRA_OPENINGS)?.let {
            out["openings"] = it.toList()
        }
        out["auto"] = data.getBooleanExtra(ArMeasureActivity.EXTRA_AUTO, false)
        out["estimated"] = data.getIntExtra(ArMeasureActivity.EXTRA_ESTIMATED, 0)
        if (data.hasExtra(ArMeasureActivity.EXTRA_FLOOR_Y)) {
            out["floorY"] = data.getDoubleExtra(ArMeasureActivity.EXTRA_FLOOR_Y, 0.0)
        }
        // Raw 3D points; Flutter derives the sizes from them.
        out["openingDetails"] =
            (data.getDoubleArrayExtra(ArMeasureActivity.EXTRA_OPENING_DETAILS) ?: DoubleArray(0)).toList()
        // Per door / window, in the same order: how it was measured (0 by
        // hand, 1 automatically, 2 with the phone) and 0 / 1 estimated.
        out["openingMethods"] =
            (data.getIntArrayExtra(ArMeasureActivity.EXTRA_OPENING_METHODS) ?: IntArray(0)).toList()
        out["openingEstimated"] =
            (data.getIntArrayExtra(ArMeasureActivity.EXTRA_OPENING_ESTIMATED) ?: IntArray(0)).toList()
        out["surfaces"] = (data.getDoubleArrayExtra(ArMeasureActivity.EXTRA_SURFACES) ?: DoubleArray(0)).toList()
        // 6 values per line: both ends as tapped (x, y, z each).
        out["lines"] = (data.getDoubleArrayExtra(ArMeasureActivity.EXTRA_LINES) ?: DoubleArray(0)).toList()
        // 0 / 1 per line, in the same order: 1 when an end was estimated.
        out["linesEstimated"] = (data.getIntArrayExtra(ArMeasureActivity.EXTRA_LINES_ESTIMATED) ?: IntArray(0)).toList()
        out["lineOnly"] = data.getBooleanExtra(ArMeasureActivity.EXTRA_LINE_ONLY, false)
        // Index (openings order) of the door / window whose ✓ finished the scan.
        if (data.hasExtra(ArMeasureActivity.EXTRA_FOCUS_OPENING)) {
            out["focusOpening"] = data.getIntExtra(ArMeasureActivity.EXTRA_FOCUS_OPENING, 0)
        }
        // AR photos with the measurements drawn in (absolute JPEG paths).
        out["photos"] = data.getStringArrayExtra(ArMeasureActivity.EXTRA_PHOTOS)?.toList() ?: emptyList<String>()
        // Furniture found by the AI detector: 6 values each, kinds alongside.
        out["elements"] = (data.getDoubleArrayExtra(ArMeasureActivity.EXTRA_ELEMENTS) ?: DoubleArray(0)).toList()
        out["elementKinds"] = data.getStringArrayExtra(ArMeasureActivity.EXTRA_ELEMENT_KINDS)?.toList() ?: emptyList<String>()
        result.success(out)
    }

    companion object {
        private const val CHANNEL = "room_measure/ar"
        private const val REQ_MEASURE = 4201
        private const val REQ_BLUETOOTH = 4202
    }
}
