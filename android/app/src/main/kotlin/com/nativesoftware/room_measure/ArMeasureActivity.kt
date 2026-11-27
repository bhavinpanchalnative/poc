package com.nativesoftware.room_measure

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.net.Uri
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.DepthPoint
import com.google.ar.core.Plane
import com.google.ar.core.Point
import com.google.ar.core.RecordingConfig
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.NotYetAvailableException
import com.google.ar.core.exceptions.UnavailableException
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Camera room scanner (ARCore).
 *
 * While the camera runs, ARCore's detected surfaces are classified into the
 * floor, walls and ceiling and drawn over the camera image. Wall surfaces are
 * intersected with each other to find room corners, and the crosshair snaps
 * to a detected corner when it is close to one.
 *
 * The point under the crosshair is the nearest of: a depth measurement, a
 * detected wall or surface, the (infinite) floor plane, or the ceiling plane.
 * Because the floor plane is known, any spot on the floor can be measured,
 * which works on phones without a depth sensor.
 *
 * Modes:
 *  - Corners: mark each room corner in order; aiming at the first corner
 *    closes the room.
 *  - Door / Window: the frame is found automatically in the camera image
 *    (see [OpeningDetector]); the button adds it and shows a 2D drawing
 *    with its dimensions.
 *  - Surface: any flat rectangle from three taps (two corners along one
 *    edge, then a point on the opposite edge).
 *  - Line: the straight-line (3D) distance between any two points.
 *
 * Returns corners (x, z), openings, surfaces and lines (raw 3D points) to
 * Flutter. The ceiling is only used internally (to tell walls from
 * furniture); no room height is measured or returned.
 */
class ArMeasureActivity : Activity(), GLSurfaceView.Renderer {

    private enum class Mode(val label: String) {
        AUTO("Auto"), CORNER("Corners"), DOOR("Door"), WINDOW("Window"), SURFACE("Surface"), LINE("Line"),
    }


    private enum class Surface { FLOOR, WALL, CEILING, OTHER }

    /** How a line's ends are taken: the point under the crosshair, or the
     *  phone's own position (works where no surface can be measured). */
    private enum class LineMethod(val label: String) { AIM("Aim"), TOUCH("Touch") }

    /** How a door or window is measured: found in the camera image, three
     *  aimed taps, or three taps with a corner of the phone on the frame. */
    private enum class OpeningMethod(val label: String) { AUTO("Auto"), MANUAL("Manual"), TOUCH("Touch") }


    private class Ray(val origin: Vec3, val dir: Vec3)
    private class PlaneOutline(val kind: Surface, val points: List<Vec3>)

    /** A door or window: the two base points as tapped (full 3D) and the
     *  height of the tapped top, null while (or if never) marked. [method]
     *  is how it was measured ([METHOD_MANUAL], ...); [estimated] when its
     *  wall or base was assumed. [rawA]: Touch, the first tap as taken (the
     *  base points are moved to the base height). */
    private class OpeningMark(
        val type: Int, val a: Vec3, val b: Vec3, val topY: Float? = null,
        val method: Int = METHOD_MANUAL, val estimated: Boolean = false, val rawA: Vec3? = null,
    ) {
        val width get() = a.dist2d(b)
        val baseY get() = (a.y + b.y) / 2f
    }

    /**
     * A flat rectangle from three taps: corner [a], the next corner [b] along
     * one edge, and any point [c] on the opposite edge. Points are kept as
     * tapped; the size is derived from them.
     */
    private class SurfaceMark(val a: Vec3, val b: Vec3, val c: Vec3) {
        val width get() = len(b - a)
        /** Offset from edge AB to the opposite edge. */
        val up get() = perpendicular(a, b, c)
        val height get() = len(up)
    }

    /**
     * A straight line between two tapped points (kept as tapped, full 3D).
     * An end is estimated when nothing was measured at that spot and its
     * distance was assumed (extended wall, facing wall, nearby points).
     */
    private class LineMark(val a: Vec3, val b: Vec3, val aEstimated: Boolean = false, val bEstimated: Boolean = false) {
        val length get() = len(b - a)
        val estimated get() = aEstimated || bEstimated
    }

    /** A point picked on the GL thread through one screen pixel. */
    private class Pick(val p: Vec3, val source: String, val estimated: Boolean)

    /**
     * A finger on the camera view (Line mode): the pixel to pick, numbered so
     * the answer can be matched. [anchor] is the line's first point when one
     * is waiting; [release] marks the position the finger was lifted at.
     */
    private class TapRequest(val x: Float, val y: Float, val seq: Int, val anchor: Vec3?, val release: Boolean)

    /** The GL thread's answer to [req]: the point there, null when none. */
    private class TapPick(val req: TapRequest, val p: Vec3?, val estimated: Boolean)

    /** The wall a door / window is looked for on, and where it came from
     *  ("plane", "fit", "room", "extended", "cloud", "floor"). */
    private class OpeningWall(val frame: WallFrame, val source: String)

    /** One automatic door / window attempt (no wall: [wall] null). */
    private class OpeningResult(
        val kind: OpeningKind, val gen: Int, val wall: OpeningWall?,
        val image: RectifiedImage?, val detection: OpeningDetection?,
    )

    /** Latest camera state, written by the GL thread and read by the UI. */
    private class Snapshot(
        val tracking: Boolean,
        val failure: TrackingFailureReason,
        val ray: Ray,
        val viewProj: FloatArray,
        val hit: Vec3?,
        val hitSource: String?,
        val planes: List<PlaneOutline>,
        val floorY: Float?,
        val ceilingY: Float?,
        val wallCount: Int,
        val cornerCandidates: List<Vec3>,
        val autoRoom: AutoRoom?,
        /** Feature points tracked in this frame, drawn as scan feedback. */
        val framePoints: List<Vec3>,
        /** Bit i set: the camera has looked into yaw sector i (30° each). */
        val sectors: Int,
        /** Diagonal of the area the camera has moved through on the floor plan (m). */
        val moveExtent: Float,
        val camPos: Vec3,
        /** [hit] is on a wall plane extended beyond its detected area. */
        val hitEstimated: Boolean = false,
        /** Which way the phone is turned (the camera's forward and up axes). */
        val camForward: Vec3 = Vec3(0f, 0f, -1f),
        val camUp: Vec3 = Vec3(0f, 1f, 0f),
    ) {
        val sectorCount get() = Integer.bitCount(sectors)
    }

    /** What a tap on the mark button would do right now. */
    private class Aim(val p: Vec3, val snappedCorner: Boolean, val closesRoom: Boolean)

    private var session: Session? = null
    private var installRequested = false
    private var depthOn = false
    private lateinit var glView: GLSurfaceView
    private lateinit var overlay: OverlayView
    private lateinit var statusText: TextView
    private lateinit var hintText: TextView
    private lateinit var statsText: TextView
    private lateinit var undoButton: View
    private lateinit var markButton: View
    private lateinit var doneButton: View
    private lateinit var topBox: LinearLayout
    private lateinit var panelBox: LinearLayout
    private lateinit var tabScroll: HorizontalScrollView
    /** System bar / display cutout insets (px): left, top, right, bottom. */
    private var insets = IntArray(4)
    private val modeTabs = mutableMapOf<Mode, TextView>()

    // Inter, the Flutter UI's type, read from the Flutter assets in the APK
    // (system font if that fails). Loaded once, on first use.
    private fun interFont(weight: String, fallback: Typeface): Typeface = try {
        Typeface.createFromAsset(assets, "flutter_assets/assets/fonts/Inter-$weight.ttf")
    } catch (e: Exception) {
        fallback
    }
    private val fontRegular by lazy { interFont("Regular", Typeface.DEFAULT) }
    private val fontMedium by lazy { interFont("Medium", Typeface.DEFAULT) }
    private val fontSemiBold by lazy { interFont("SemiBold", Typeface.DEFAULT_BOLD) }
    private val fontBold by lazy { interFont("Bold", Typeface.DEFAULT_BOLD) }

    /** Inner disc of the mark button (teal while a found door / window is ready). */
    private lateinit var markDisc: View
    private var markReadyShown: Boolean? = null
    /** Finish button's circle (brand blue while enabled). */
    private lateinit var doneCircle: View
    private var doneShown: Boolean? = null

    private val background = BackgroundRenderer()
    private var textureSet = false
    private var viewWidth = 0
    private var viewHeight = 0
    @Volatile private var geometryChanged = false

    /** A 180° turn (landscape to the other landscape) keeps the surface size,
     *  so onSurfaceChanged is not called; ARCore must still be told about the
     *  new rotation or the camera image and overlay are drawn upside down. */
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            geometryChanged = true
        }
    }

    // GL thread state.
    private var glFloorY: Float? = null
    private var glCeilingY: Float? = null
    @Volatile
    private var glAutoRoom: AutoRoom? = null
    private var frameCount = 0L

    /** Feature points seen so far, by ARCore point id (GL thread only). */
    private val cloud = HashMap<Int, Vec3>()

    /**
     * Depth samples by 5 cm voxel, each standing for the mean of its samples
     * (GL thread only). Depth works on plain walls and floors, where ARCore
     * finds few feature points and often no planes at all.
     */
    private val depthVoxels = DepthVoxelGrid(VOXEL, MAX_VOXELS)
    private var depthDots: List<Vec3> = emptyList()
    private var lastDepthCount = 0

    /** Room detection runs here so the camera view stays smooth. */
    private val detector = Executors.newSingleThreadExecutor()

    /** Door / window detection (and its diagnostics) runs here. */
    private val openingExecutor = Executors.newSingleThreadExecutor()

    /** AI furniture detection runs here (its model is made, and used, only
     *  on this thread). */
    private val furnitureExecutor = Executors.newSingleThreadExecutor()
    private var furnitureModel: FurnitureModel? = null
    private var furnitureModelFailed = false
    @Volatile
    private var furnitureInFlight = false
    private var lastFurnitureAttempt = 0L

    /** Furniture found so far in the room scan (UI thread). */
    private val furniture = FurnitureTracker()

    /** How the camera sensor is turned against the phone (degrees). */
    private val sensorOrientation by lazy {
        runCatching {
            val id = session?.cameraConfig?.cameraId ?: return@runCatching 90
            getSystemService(android.hardware.camera2.CameraManager::class.java)
                .getCameraCharacteristics(id)
                .get(android.hardware.camera2.CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        }.getOrDefault(90)
    }

    /** Door / window Auto: what to look for, set by the UI thread; null when
     *  not looking. */
    @Volatile
    private var autoOpeningKind: OpeningKind? = null

    /**
     * Room scan (Auto mode): doors and windows are looked for on whatever
     * wall is in view while the room is measured (both kinds in each image),
     * and counted automatically once a detection holds steady.
     * Set by the UI thread.
     */
    @Volatile
    private var roomOpeningScan = false

    /**
     * Room scan (Auto mode): the live 2D floor plan fills the lower part of
     * the screen and the walls, doors and windows found are drawn on it
     * instead of over the camera image. Tapping the plan switches to the
     * camera overlay with the small mini-map, and back (UI thread).
     */
    // The camera view, with the walls outlined in it, fills the screen, and
    // the plan is a small map; tap the map for the big plan.
    private var planBig = false

    private fun livePlanShown() = (mode == Mode.AUTO || mode == Mode.CORNER) && !lineOnly && planBig

    /** Room scan: detections so far, per kind (UI thread). */
    private val roomConsensus = mapOf(
        OpeningKind.DOOR to OpeningConsensus.forRoomScan(),
        OpeningKind.WINDOW to OpeningConsensus.forRoomScan(),
    )

    /** A door / window attempt is being computed (at most one at a time). */
    @Volatile
    private var openingInFlight = false
    /** When the GL thread last started one. */
    private var lastOpeningAttempt = 0L
    private var lastWallSource: String? = null

    /** When the floor-line wall correction was last logged (opening thread). */
    @Volatile private var lastFloorLineDiagAt = 0L

    @Volatile
    private var detecting = false

    /** Bumped by "Start over", so a room still being computed for the old
     *  scan is thrown away. */
    @Volatile
    private var scanGeneration = 0

    // Diagnostics (debug builds): a log and an ARCore recording of each scan.
    private var diagWriter: java.io.Writer? = null
    private var scanStamp = ""
    private var lastTrackingLogged: Boolean? = null
    /** Progress last written to the log: sectors covered and walls measured. */
    private var loggedSectors = -1
    private var loggedWalls = -1
    private val playbackPath by lazy {
        intent.getStringExtra(EXTRA_PLAYBACK)?.takeIf { isDebuggable() }
    }

    // Mean camera position on the floor plan: a point inside the room.
    private var camSumX = 0.0
    private var camSumZ = 0.0
    private var camSumY = 0.0
    private var camSamples = 0

    // How the user scanned (GL thread): the directions looked in, as a bit
    // per 30° yaw sector, and the box the camera moved through. Without a
    // depth sensor distance comes from sideways movement, so turning on the
    // spot covers every direction but measures next to nothing.
    private var glSectors = 0
    private var glMinX = Float.MAX_VALUE
    private var glMaxX = -Float.MAX_VALUE
    private var glMinZ = Float.MAX_VALUE
    private var glMaxZ = -Float.MAX_VALUE

    /** Floor height found from depth / feature points when ARCore finds no floor plane. */
    private var glPointFloorY: Float? = null

    @Volatile
    private var snapshot: Snapshot? = null

    // UI thread state.
    private var mode = Mode.AUTO

    /** The room outline comes from corners marked by hand (Corners mode was
     *  chosen) instead of the automatic outline. */
    private var manualOutline = false
    private val corners = mutableListOf<Vec3>()
    private val openings = mutableListOf<OpeningMark>()
    private var pendingEdge: Vec3? = null
    /** Door / window with both base points, waiting for its top. */
    private var pendingOpening: OpeningMark? = null
    private val surfaces = mutableListOf<SurfaceMark>()
    /** First one or two corners of the surface being marked. */
    private val pendingSurface = mutableListOf<Vec3>()
    private val lines = mutableListOf<LineMark>()
    /** First end of the line being measured. */
    private var pendingLine: Vec3? = null
    /** [pendingLine] was estimated (set whenever it is). */
    private var pendingLineEstimated = false

    // Tap to place line points (Line mode, Aim). The finger's pixel goes to
    // the GL thread, which alone can ask ARCore what is there; its answer
    // comes back one frame later.
    @Volatile
    private var tapRequest: TapRequest? = null
    @Volatile
    private var tapPick: TapPick? = null
    private var tapSeq = 0
    /** A finger is on the camera view. */
    private var tapDown = false
    /** Where that finger is (or was lifted), in overlay pixels. */
    private var tapX = 0f
    private var tapY = 0f
    /** First request of the current touch: older answers are not its preview. */
    private var tapGestureSeq = 0
    /** The request made when the finger was lifted, -1 when none is awaited. */
    private var tapReleaseSeq = -1
    /** A tap that found nothing: a red ring stays there until [tapMissUntil]. */
    private var tapMissX = 0f
    private var tapMissY = 0f
    private var tapMissUntil = 0L
    private var lineMethod = LineMethod.AIM
    private lateinit var methodBox: LinearLayout
    private val methodTabs = mutableMapOf<LineMethod, TextView>()
    private var methodShown: LineMethod? = null
    /** Doors and windows are always found automatically (there is no
     *  choice of method), so this never changes. */
    private val openingMethod = OpeningMethod.AUTO
    /** The "+" on the mark button ("✓" while it accepts a found door / window). */
    private lateinit var markGlyph: TextView

    // Door / window Auto (UI thread).
    private val consensus = OpeningConsensus()
    /** The kind being looked for, as last told to the GL thread. */
    private var autoKindShown: OpeningKind? = null
    /** When the current search started. */
    private var autoSearchSince = 0L
    /** When the last candidate came in. */
    private var lastAutoCandidateAt = 0L
    /** The last attempt found no wall to look on. */
    private var autoNoWall = false

    /** The last stable result and when (uptime ms) it was stable: the
     *  estimated wall can drop out for a frame, and a tap a moment after the
     *  frame turned green must still add it. */
    private var lastStable: OpeningConsensus.State? = null

    /**
     * The door / window found, adjusted by hand on the camera view: its
     * edges in [frame]'s wall coordinates (u along the wall, heights). Once
     * the user drags one of its circles or lines it no longer follows new
     * detections; ✓ adds it as adjusted, Undo goes back to automatic.
     */
    private class AdjustedOpening(
        val frame: WallFrame, var left: Float, var right: Float, var bottom: Float, var top: Float,
        val estimated: Boolean,
    ) {
        fun candidate() = OpeningCandidate(
            left, right, bottom, top, frame.world(left, bottom), frame.world(right, bottom), top,
            right - left, top - bottom, frame.floorY?.let { bottom - it }, 0f, estimated,
        )
    }

    private var adjusted: AdjustedOpening? = null

    /** The side the finger holds: 0 bottom, 1 right, 2 top, 3 left; -1 none.
     *  Only that side moves: the opposite and adjacent sides stay put. */
    private var adjustGrab = -1

    /** Where the held side was relative to the finger when grabbed (m along
     *  the wall, or height), so it moves with the finger without jumping. */
    private var adjustOffset = 0f
    private var lastStableAt = 0L
    /** The latest attempt with a wall (its image is saved with diagnostics). */
    private var lastOpeningResult: OpeningResult? = null
    private var lastOpeningDiagAt = 0L
    /** Just accepted: candidates around it are ignored for a moment. */
    private var acceptedCentre: Vec3? = null
    private var acceptedAt = 0L
    /** Started just to measure distances ([EXTRA_START_MODE] "line"): no room
     *  outline is needed to finish, and none is returned. */
    private var lineOnly = false
    private val history = mutableListOf<Int>()
    private var flashMessage: String? = null
    private var flashUntil = 0L

    /** Set by the photo button; the GL thread reads the camera image on its
     *  next frame and clears it. */
    @Volatile
    private var captureRequested = false

    /** AR photos taken in this scan (absolute paths). Not part of Undo. */
    private val photos = mutableListOf<String>()

    // Auto-completion (UI thread): in Auto mode the scan finishes on its own
    // once every wall is measured and the outline has stopped changing, so
    // the user doesn't have to notice that it is done and tap Finish.
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var completeCard: View
    private lateinit var completeSize: TextView
    /** Second line: what the result lacks (estimated walls, no height). */
    private lateinit var completeNote: TextView
    /** The checkmark is showing and the scan finishes after [AUTO_FINISH_DELAY_MS]. */
    private var completing = false
    /** Corners mode was chosen since the last Start over: the user is outlining
     *  by hand, so only Finish ends the scan. */
    private var cornersChosen = false

    /** The "room not measured yet" question, while it shows. */
    private var weakFinishDialog: AlertDialog? = null

    /** Half or more of the outline's sides were guessed, not measured. */
    private fun mostlyEstimated(room: AutoRoom) = room.estimatedCount * 2 >= room.corners.size
    /** When the auto room last changed noticeably (or stopped qualifying). */
    private var stableSince = 0L
    /** The room [stableSince] refers to; compared against that, not the
     *  previous frame, so a slow drift still restarts the wait. */
    private var stableCorners = -1
    private var stableWidth = 0f
    private var stableDepth = 0f
    private var stableArea = 0f
    private val autoFinish = Runnable {
        if (!completing || isFinishing) return@Runnable
        diag("auto-complete: finishing")
        onDone()
        // onDone only returns without finishing when there is no room; then
        // go back to scanning rather than leave the checkmark up.
        if (!isFinishing) cancelAutoComplete("finish refused")
    }

    // ------------------------------------------------------------ lifecycle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        lineOnly = intent.getStringExtra(EXTRA_START_MODE) == START_MODE_LINE
        if (lineOnly) mode = Mode.LINE
        openDiagnostics()
        if (lineOnly) diag("started for line measuring only")
        buildUi()
        refreshUi()
    }

    private fun isDebuggable() = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /** Folder holding scan logs and recordings (adb pull-able). */
    private fun diagDir(): File? = getExternalFilesDir("scans")

    private fun openDiagnostics() {
        if (!isDebuggable()) return
        val dir = diagDir() ?: return
        scanStamp = java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US).format(java.util.Date())
        // Keep the 5 most recent scans (never while replaying one).
        if (playbackPath == null) dir.listFiles()?.filter { it.name.startsWith("scan_") }
            ?.groupBy { it.nameWithoutExtension }?.keys?.sortedDescending()?.drop(5)
            ?.forEach { stem -> dir.listFiles()?.filter { it.nameWithoutExtension == stem }?.forEach { it.delete() } }
        diagWriter = try {
            File(dir, (if (playbackPath == null) "scan_" else "replay_") + "$scanStamp.log").bufferedWriter()
        } catch (e: Exception) {
            null
        }
        diag("scan started on ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}" +
            (playbackPath?.let { ", playing back $it" } ?: ""))
    }

    /** Writes a line to logcat and, in debug builds, to the scan's log file. */
    private fun diag(msg: String) {
        Log.i(TAG, msg)
        val w = diagWriter ?: return
        synchronized(w) {
            try {
                w.write("${SystemClock.elapsedRealtime()} $msg\n")
                w.flush()
            } catch (_: Exception) {
            }
        }
    }

    override fun onResume() {
        super.onResume()
        resumeSession()
        getSystemService(DisplayManager::class.java)?.registerDisplayListener(displayListener, null)
    }

    /** Creates the ARCore session if there is none, and runs it. */
    private fun resumeSession() {
        if (session == null) {
            if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
                return
            }
            try {
                if (ArCoreApk.getInstance().requestInstall(this, !installRequested) ==
                    ArCoreApk.InstallStatus.INSTALL_REQUESTED
                ) {
                    installRequested = true
                    return
                }
                val s = Session(this)
                depthOn = s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
                val config = Config(s).apply {
                    planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                    focusMode = Config.FocusMode.AUTO
                    lightEstimationMode = Config.LightEstimationMode.DISABLED
                    depthMode = if (depthOn) Config.DepthMode.AUTOMATIC else Config.DepthMode.DISABLED
                }
                s.configure(config)
                val playback = playbackPath
                if (playback != null) {
                    s.setPlaybackDatasetUri(Uri.fromFile(File(playback)))
                } else if (isDebuggable()) {
                    // Record camera + motion so a real scan can be replayed
                    // later to tune detection.
                    try {
                        val f = File(diagDir(), "scan_$scanStamp.mp4")
                        s.startRecording(
                            RecordingConfig(s).setMp4DatasetUri(Uri.fromFile(f)).setAutoStopOnPause(true),
                        )
                        diag("recording to ${f.name}")
                    } catch (e: Exception) {
                        diag("recording unavailable: $e")
                    }
                }
                session = s
                diag("session started, depth supported: $depthOn")
            } catch (e: UnavailableException) {
                finishWithError("Camera scanning is not available on this phone (${e.javaClass.simpleName}).")
                return
            } catch (e: Exception) {
                finishWithError("Could not start the camera scanner: ${e.message}")
                return
            }
        }
        try {
            session?.resume()
        } catch (e: CameraNotAvailableException) {
            finishWithError("The camera is in use by another app. Close it and try again.")
            return
        }
        glView.onResume()
        geometryChanged = true
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // The activity handles rotation itself (so the scan is not lost):
        // move the cards for the new orientation.
        applyLayout()
        geometryChanged = true
    }

    override fun onPause() {
        super.onPause()
        // The camera stops: don't finish in the background. The wait starts
        // again after onResume.
        cancelAutoComplete("paused")
        // No frames while paused: a lifted finger's point would never arrive.
        clearTap()
        getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(displayListener)
        if (session != null) {
            glView.onPause()
            session?.pause()
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(autoFinish)
        detector.shutdownNow()
        openingExecutor.shutdownNow()
        furnitureExecutor.execute { runCatching { furnitureModel?.close() } }
        furnitureExecutor.shutdown()
        session?.close()
        session = null
        diag("scan closed")
        diagWriter?.let { synchronized(it) { runCatching { it.close() } } }
        diagWriter = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CAMERA &&
            grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED
        ) {
            finishWithError("Camera permission is needed to scan a room.")
        }
        // On success onResume runs again and starts the session.
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        cancelAutoComplete("close")
        if (corners.isEmpty() && openings.isEmpty() && pendingOpening == null && surfaces.isEmpty() &&
            lines.isEmpty() && photos.isEmpty()
        ) {
            @Suppress("DEPRECATION")
            super.onBackPressed()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Discard this scan?")
            .setMessage(
                if (photos.isEmpty()) "Everything you have marked will be lost."
                else "Everything you have marked and the photos you have taken will be lost."
            )
            .setNegativeButton("Keep scanning", null)
            .setPositiveButton("Discard") { _, _ ->
                deletePhotos()
                finish()
            }
            .show()
    }

    private fun deletePhotos() {
        for (p in photos) runCatching { File(p).delete() }
        photos.clear()
    }

    private fun finishWithError(msg: String) {
        setResult(RESULT_OK, Intent().putExtra(EXTRA_ERROR, msg))
        finish()
    }

    // ------------------------------------------------------------ GL thread

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        background.create()
        textureSet = false
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        viewWidth = width
        viewHeight = height
        geometryChanged = true
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val s = session ?: return
        if (!textureSet) {
            s.setCameraTextureName(background.textureId)
            textureSet = true
        }
        if (geometryChanged) {
            @Suppress("DEPRECATION")
            s.setDisplayGeometry(windowManager.defaultDisplay.rotation, viewWidth, viewHeight)
            geometryChanged = false
        }
        val frame = try {
            s.update()
        } catch (e: Exception) {
            Log.w(TAG, "update failed", e)
            return
        }
        background.draw(frame)
        // AR photo: the camera image alone, before anything else is drawn.
        var captured: Bitmap? = null
        if (captureRequested && viewWidth > 0 && viewHeight > 0) {
            captured = try {
                readFramebuffer(viewWidth, viewHeight)
            } catch (e: Throwable) {
                Log.w(TAG, "photo capture failed", e)
                null
            }
            captureRequested = false
            if (captured == null) runOnUiThread { flash("Could not take the photo. Try again.") }
        }

        val camera = frame.camera
        val tracking = camera.trackingState == TrackingState.TRACKING
        val pose = camera.displayOrientedPose
        val origin = Vec3(pose.tx(), pose.ty(), pose.tz())

        val view = FloatArray(16)
        val proj = FloatArray(16)
        val viewProj = FloatArray(16)
        camera.getViewMatrix(view, 0)
        camera.getProjectionMatrix(proj, 0, 0.05f, 50f)
        Matrix.multiplyMM(viewProj, 0, proj, 0, view, 0)
        // The line of sight through the crosshair, i.e. the screen centre.
        // The camera's optical axis is not exactly that line (lens centre
        // offset, the camera image is cropped to fill the screen), so the
        // point measured was not the point under the crosshair.
        val ray = centreRay(viewProj) ?: run {
            val zAxis = pose.zAxis
            Ray(origin, Vec3(-zAxis[0], -zAxis[1], -zAxis[2]))
        }

        val outlines = mutableListOf<PlaneOutline>()
        val corners2d = mutableListOf<Vec3>()
        var wallCount = 0
        var hit: Vec3? = null
        var source: String? = null
        var hitEstimated = false

        // Read once: the answer must name the request it was computed for.
        val req = tapRequest
        var tapPoint: Vec3? = null
        var tapEstimated = false

        frameCount++
        var framePoints: List<Vec3> = emptyList()
        if (tracking) {
            camSumX += origin.x
            camSumZ += origin.z
            camSumY += origin.y
            camSamples++
            if (abs(ray.dir.y) < 0.85f) {
                val sector = ((atan2(ray.dir.z, ray.dir.x) + PI) / (2 * PI) * SECTORS).toInt().coerceIn(0, SECTORS - 1)
                glSectors = glSectors or (1 shl sector)
            }
            if (origin.x < glMinX) glMinX = origin.x
            if (origin.x > glMaxX) glMaxX = origin.x
            if (origin.z < glMinZ) glMinZ = origin.z
            if (origin.z > glMaxZ) glMaxZ = origin.z
            framePoints = collectPoints(frame, origin)
            if (depthOn && frameCount % 10 == 0L) {
                val d = collectDepth(frame, camera)
                lastDepthCount = d.size
                depthDots = if (d.size > 400) d.filterIndexed { i, _ -> i % (d.size / 400 + 1) == 0 } else d
            }
            framePoints = framePoints + depthDots
            val planes = s.getAllTrackables(Plane::class.java).filter {
                it.trackingState == TrackingState.TRACKING && it.subsumedBy == null
            }
            val polygons = planes.associateWith { readPolygon(it) }
            detectFloorAndCeiling(planes, origin.y)
            if (frameCount % 60 == 0L) {
                diag(
                    "frame: camY=${String.format("%.2f", origin.y)} points=${cloud.size} " +
                        "depthVoxels=${depthVoxels.count} lastDepth=$lastDepthCount " +
                        "floorY=${glFloorY?.let { String.format("%.2f", it) }} " +
                        "pointFloorY=${glPointFloorY?.let { String.format("%.2f", it) }} surfaces=" +
                        planes.joinToString(" ") {
                            val t = when (it.type) {
                                Plane.Type.HORIZONTAL_UPWARD_FACING -> "UP"
                                Plane.Type.HORIZONTAL_DOWNWARD_FACING -> "DOWN"
                                else -> "VERT"
                            }
                            String.format("%s(dy=%.2f,%.1fx%.1f)", t, it.centerPose.ty() - origin.y, it.extentX, it.extentZ)
                        },
                )
            }
            val planeFloorY = glFloorY
            val floorY = planeFloorY ?: glPointFloorY

            // Classify surfaces and collect their outlines in world space.
            val walls = mutableListOf<WallSegment>()
            for (p in planes) {
                val poly = polygons[p] ?: continue
                if (poly.size < 6) continue
                val cp = p.centerPose
                val pts = ArrayList<Vec3>(poly.size / 2)
                for (i in 0 until poly.size / 2) {
                    val w = cp.transformPoint(floatArrayOf(poly[2 * i], 0f, poly[2 * i + 1]))
                    pts.add(Vec3(w[0], w[1], w[2]))
                }
                val kind = when (p.type) {
                    Plane.Type.VERTICAL -> Surface.WALL
                    Plane.Type.HORIZONTAL_UPWARD_FACING ->
                        if (floorY != null && abs(cp.ty() - floorY) < 0.12f) Surface.FLOOR else Surface.OTHER
                    Plane.Type.HORIZONTAL_DOWNWARD_FACING -> Surface.CEILING
                    else -> Surface.OTHER
                }
                outlines.add(PlaneOutline(kind, pts))
                if (kind == Surface.WALL) wallSegment(cp.yAxis, cp.tx(), cp.tz(), pts)?.let { walls.add(it) }
            }
            wallCount = walls.size
            corners2d.addAll(findCorners(walls, floorY ?: (origin.y - 1.3f)))

            // Automatic room outline, refreshed a few times per second on the
            // detector thread (the last good outline is kept meanwhile).
            if (frameCount % 10 == 0L && camSamples > 0 && !detecting) {
                val cloudNow = ArrayList<Vec3>(cloud.size + depthVoxels.count)
                cloudNow.addAll(cloud.values)
                depthVoxels.forEachMean(2) { x, y, z -> cloudNow.add(Vec3(x, y, z)) }
                val camY = (camSumY / camSamples).toFloat()
                if (planeFloorY == null && frameCount % 30 == 0L) {
                    estimateFloor(cloudNow, camY)?.let { glPointFloorY = it }
                }
                // Without a floor plane or a floor from points, assume the
                // phone is held at a typical height; the height of the room
                // is then left for the user to enter.
                val guessed = floorY == null
                val useFloor = floorY ?: (camY - 1.35f)
                if (!guessed || cloudNow.size >= RoomDetector.MIN_CLOUD) {
                    detecting = true
                    val floorPts = outlines.filter { it.kind == Surface.FLOOR }.flatMap { it.points }
                    val wallsNow = walls.toList()
                    val cx = (camSumX / camSamples).toFloat()
                    val cz = (camSumZ / camSamples).toFloat()
                    val ceiling = glCeilingY
                    val surfaces = planes.size
                    val source = if (planeFloorY != null) "plane" else if (!guessed) "points" else "guess"
                    val gen = scanGeneration
                    detector.execute {
                        try {
                            RoomDetector.computeAutoRoom(wallsNow, floorPts, useFloor, cx, cz, ceiling, cloudNow)
                                ?.let { if (gen == scanGeneration) glAutoRoom = if (guessed) it.withoutHeight() else it }
                        } catch (e: Exception) {
                            Log.w(TAG, "auto room failed", e)
                        }
                        logScanState(surfaces, wallsNow.size, cloudNow.size, useFloor, source, glAutoRoom)
                        detecting = false
                    }
                }
            }

            // The point under the crosshair.
            pickAt(frame, planes, polygons, floorY, ray, viewWidth / 2f, viewHeight / 2f)?.let {
                hit = it.p
                source = it.source
                hitEstimated = it.estimated
            }

            // Door / window Auto: a few times per second, the camera image
            // goes to the detector with the wall it is looked for on.
            autoOpeningKind?.let { kind ->
                val now = SystemClock.uptimeMillis()
                if (!openingInFlight && now - lastOpeningAttempt >= OPENING_INTERVAL_MS) {
                    lastOpeningAttempt = now
                    startOpeningAttempt(kind, frame, camera, planes, polygons, floorY, ray, viewProj)
                }
            } ?: run {
                // Room scan: doors and windows are found along the way, both
                // looked for in each image (a little less often, so the room
                // detection keeps its share of the phone). They used to
                // alternate, which halved how often each was seen while the
                // camera swept past.
                if (!roomOpeningScan) return@run
                val now = SystemClock.uptimeMillis()
                if (!openingInFlight && now - lastOpeningAttempt >= ROOM_OPENING_INTERVAL_MS) {
                    lastOpeningAttempt = now
                    startOpeningAttempt(OpeningKind.DOOR, frame, camera, planes, polygons, floorY, ray, viewProj, roomScan = true)
                }
                // AI furniture detection, once the floor is known (furniture
                // is placed where it stands on it).
                if (floorY != null && !furnitureInFlight && !furnitureModelFailed &&
                    now - lastFurnitureAttempt >= FURNITURE_INTERVAL_MS
                ) {
                    lastFurnitureAttempt = now
                    startFurnitureAttempt(frame, camera, floorY)
                }
            }

            // The point under the finger (Line mode): the same pick through
            // that pixel, then the tap-only estimates when nothing is there.
            if (req != null && viewWidth > 0 && viewHeight > 0) {
                val tapRay = screenRay(viewProj, 2f * req.x / viewWidth - 1f, 1f - 2f * req.y / viewHeight)
                if (tapRay != null) {
                    val pick = pickAt(frame, planes, polygons, floorY, tapRay, req.x, req.y)
                    if (pick != null) {
                        tapPoint = pick.p
                        tapEstimated = pick.estimated
                    } else {
                        val z = pose.zAxis
                        tapPoint = tapEstimate(tapRay, req.anchor, Vec3(-z[0], -z[1], -z[2]))
                        tapEstimated = tapPoint != null
                    }
                }
            }
        }
        // Published even without tracking (no point), so a tap always gets
        // its answer.
        if (req != null) tapPick = TapPick(req, tapPoint, tapEstimated)

        val moveExtent = if (glMaxX < glMinX) 0f else {
            val dx = glMaxX - glMinX
            val dz = glMaxZ - glMinZ
            sqrt(dx * dx + dz * dz)
        }
        val snap = Snapshot(
            tracking, camera.trackingFailureReason, ray, viewProj, hit, source,
            outlines, glFloorY ?: glPointFloorY, glCeilingY, wallCount, corners2d, glAutoRoom, framePoints,
            glSectors, moveExtent, origin, hitEstimated,
            pose.zAxis.let { Vec3(-it[0], -it[1], -it[2]) }, pose.yAxis.let { Vec3(it[0], it[1], it[2]) },
        )
        snapshot = snap
        // Posted with this frame's camera state, so the overlay lines up
        // with the photo.
        captured?.let { bmp -> runOnUiThread { onPhotoCaptured(bmp, snap) } }
        runOnUiThread { onFrame() }
    }

    /**
     * The point seen through screen pixel ([sx], [sy]), whose line of sight
     * is [ray]: the nearest of a depth measurement, a detected surface, the
     * (infinite) floor or ceiling plane, a side of the room outline and the
     * points gathered so far; failing all of those a detected wall's plane
     * extended beyond its detected area (estimated). Null when nothing is
     * there. GL thread; used for the crosshair (screen centre) and for taps.
     */
    private fun pickAt(
        frame: com.google.ar.core.Frame, planes: List<Plane>, polygons: Map<Plane, FloatArray>, floorY: Float?,
        ray: Ray, sx: Float, sy: Float,
    ): Pick? {
        var hit: Vec3? = null
        var source: String? = null
        var hitEstimated = false

        // Nearest surface along the line of sight.
        var bestT = Float.MAX_VALUE
        // Height of the floor / ceiling when the best hit is on it beyond
        // its detected area (it is treated as an infinite plane).
        var bestExtendedY: Float? = null
        fun consider(t: Float, label: String, extendedY: Float? = null) {
            if (t > 0.15f && t < 12f && t < bestT) {
                bestT = t
                hit = ray.origin + ray.dir * t
                source = label
                bestExtendedY = extendedY
            }
        }
        for (p in planes) {
            val poly = polygons[p] ?: continue
            if (poly.size < 6) continue
            val cp = p.centerPose
            val n = cp.yAxis
            val normal = Vec3(n[0], n[1], n[2])
            val denom = normal.dot(ray.dir)
            if (abs(denom) < 1e-3f) continue
            val t = (Vec3(cp.tx(), cp.ty(), cp.tz()) - ray.origin).dot(normal) / denom
            if (t <= 0.15f || t >= 12f) continue
            val w = ray.origin + ray.dir * t
            val local = cp.inverse().transformPoint(floatArrayOf(w.x, w.y, w.z))
            val vertical = p.type == Plane.Type.VERTICAL
            if (!inPolygon(poly, local[0], local[2], if (vertical) 0.3f else 0f)) continue
            consider(t, if (vertical) "wall" else "surface")
        }
        // The floor and ceiling are extended beyond their detected area, but
        // not at a shallow angle or far away: there a degree of tilt moves
        // the point by metres (a "9 m" line across a small room).
        if (floorY != null && ray.dir.y < -MIN_EXTEND_SLOPE) {
            val t = (floorY - ray.origin.y) / ray.dir.y
            if (t < MAX_EXTEND_DISTANCE) consider(t, "floor", floorY)
        }
        glCeilingY?.let { cy ->
            if (ray.dir.y > MIN_EXTEND_SLOPE) {
                val t = (cy - ray.origin.y) / ray.dir.y
                if (t < MAX_EXTEND_DISTANCE) consider(t, "ceiling", cy)
            }
        }

        // Walls of the room outline already found: each side is a
        // vertical plane from the floor up to the ceiling, so an already
        // scanned plain wall can still be measured.
        glAutoRoom?.let { room -> considerRoomWalls(room, ray, ::consider) }

        // Points gathered earlier (feature points and depth voxels) along
        // the line of sight: aiming back at a scanned area works without
        // fresh detail in the current frame.
        val cloudS = cloudAlongRay(ray)
        if (cloudS != null) {
            val cand = ray.origin + ray.dir * cloudS
            val ey = bestExtendedY
            val use = hit == null ||
                (ey != null && cloudS < bestT - 0.03f && abs(cand.y - ey) > 0.05f) ||
                cloudS < bestT - 0.35f
            if (use) {
                hit = cand
                bestT = cloudS
                bestExtendedY = null
                source = "cloud"
            }
        }

        // Depth (when supported) beats everything; a tracked detail point
        // is used when nothing else is there, or when it is clearly in
        // front of the surface found above (an undetected wall).
        if (viewWidth > 0) {
            var depthHit: Vec3? = null
            var pointHit: Vec3? = null
            var pointDist = 0f
            // Same line of sight as above (hitTest takes the screen
            // position the ray goes through).
            for (h in frame.hitTest(sx, sy)) {
                if (h.distance > 12f) continue
                val hp = h.hitPose
                when (h.trackable) {
                    is DepthPoint -> if (depthHit == null) depthHit = Vec3(hp.tx(), hp.ty(), hp.tz())
                    is Point -> if (pointHit == null) {
                        pointHit = Vec3(hp.tx(), hp.ty(), hp.tz())
                        pointDist = h.distance
                    }
                    else -> {}
                }
            }
            if (depthHit != null) {
                hit = depthHit
                source = "depth"
            } else if (pointHit != null) {
                val ey = bestExtendedY
                // Aiming at the foot of an undetected wall, the extended
                // floor is hit *behind* the wall (often 10-40 cm). Any
                // point off the floor in front of it is the wall itself.
                val inFront = if (ey != null) {
                    pointDist < bestT - 0.03f && abs(pointHit.y - ey) > 0.05f
                } else {
                    pointDist < bestT - 0.35f
                }
                if (hit == null || inFront) {
                    hit = pointHit
                    source = "point"
                }
            }
        }

        // Last resort, for plain walls: a detected wall's plane extended
        // up to 2 m beyond its detected area (flagged as estimated).
        if (hit == null) {
            var nearest = Float.MAX_VALUE
            for (p in planes) {
                if (p.type != Plane.Type.VERTICAL) continue
                val poly = polygons[p] ?: continue
                if (poly.size < 6) continue
                val cp = p.centerPose
                val n = cp.yAxis
                val normal = Vec3(n[0], n[1], n[2])
                val denom = normal.dot(ray.dir)
                if (abs(denom) < 1e-3f) continue
                val t = (Vec3(cp.tx(), cp.ty(), cp.tz()) - ray.origin).dot(normal) / denom
                if (t <= 0.15f || t >= 8f || t >= nearest) continue
                val w = ray.origin + ray.dir * t
                if (floorY != null && (w.y < floorY - 0.05f || w.y > floorY + 3.5f)) continue
                val local = cp.inverse().transformPoint(floatArrayOf(w.x, w.y, w.z))
                if (!inPolygon(poly, local[0], local[2], 2.0f)) continue
                nearest = t
                hit = w
                source = "wall~"
                hitEstimated = true
            }
        }
        val p = hit ?: return null
        return Pick(p, source ?: "", hitEstimated)
    }

    /**
     * Door / window Auto, GL thread: finds the wall under the crosshair,
     * copies the camera image's brightness (Y plane) and hands both to
     * [openingExecutor], which rectifies the image onto the wall, looks for
     * the frame and posts the result to [onOpeningResult].
     */
    private fun startOpeningAttempt(
        kind: OpeningKind, frame: com.google.ar.core.Frame, camera: com.google.ar.core.Camera,
        planes: List<Plane>, polygons: Map<Plane, FloatArray>, floorY: Float?, ray: Ray, viewProj: FloatArray,
        roomScan: Boolean = false,
    ) {
        val gen = scanGeneration
        val wall = openingWall(kind, frame, planes, polygons, floorY, ray, viewProj)
        if (wall?.source != lastWallSource) {
            lastWallSource = wall?.source
            diag("opening wall: ${wall?.source ?: "none"}")
        }
        if (wall == null) {
            runOnUiThread { onOpeningResult(OpeningResult(kind, gen, null, null, null)) }
            return
        }
        val lum = copyLuminance(frame) ?: return
        // Intrinsics of the CPU image (sensor orientation), scaled in case
        // they were given for another resolution.
        val intr = camera.imageIntrinsics
        val f = intr.focalLength
        val c = intr.principalPoint
        val dims = intr.imageDimensions
        val sx = if (dims[0] > 0) lum.width.toFloat() / dims[0] else 1f
        val sy = if (dims[1] > 0) lum.height.toFloat() / dims[1] else 1f
        // World to sensor (camera.pose, not the display-oriented pose).
        val m = FloatArray(16)
        camera.pose.inverse().toMatrix(m, 0)
        val cam = CameraModel(m, f[0] * sx, f[1] * sy, c[0] * sx, c[1] * sy, lum.width, lum.height)
        openingInFlight = true
        try {
            openingExecutor.execute {
                try {
                    // The wall is then placed by where it meets the floor
                    // when that line is in view (see OpeningDetector.measure):
                    // a detected wall a few cm out, or a guessed one, made the
                    // door / window that much too small or too large.
                    val res = OpeningDetector.measure(kind, wall.frame, cam, lum, wide = roomScan)
                    val fl = res.floorLine
                    if (fl != null && System.currentTimeMillis() - lastFloorLineDiagAt > 2000L) {
                        lastFloorLineDiagAt = System.currentTimeMillis()
                        diag(String.format("opening wall %s corrected by the floor line: %+.1f cm, %.1f°, %d strips",
                            wall.source, fl.moved * 100, fl.turned, fl.strips))
                    }
                    val used = if (fl != null) OpeningWall(res.frame, wall.source + "+floor line") else wall
                    // A window's wall taken through the floor at the bottom of
                    // the screen is only a guess, of no use unless the floor
                    // line confirmed where the wall is.
                    val windowWallOk = fl != null || wall.source != "floor"
                    if (roomScan) {
                        // The same image and wall, searched for a window too.
                        val win = if (windowWallOk) OpeningDetector.search(OpeningKind.WINDOW, res.frame, res.image) else null
                        var doorDet = res.detection
                        val d = doorDet.candidate
                        if (d != null && RoomOpeningCounter.doorIsWindow(d, win?.candidate, res.frame.floorY)) {
                            doorDet = OpeningDetection(null, doorDet.columnProfile, doorDet.rowProfile)
                        }
                        runOnUiThread {
                            onOpeningResult(OpeningResult(OpeningKind.DOOR, gen, used, res.image, doorDet))
                            onOpeningResult(OpeningResult(OpeningKind.WINDOW, gen, if (win != null) used else null, res.image, win))
                        }
                    } else if (!windowWallOk && kind == OpeningKind.WINDOW) {
                        runOnUiThread { onOpeningResult(OpeningResult(kind, gen, null, null, null)) }
                    } else {
                        runOnUiThread { onOpeningResult(OpeningResult(kind, gen, used, res.image, res.detection)) }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "opening detection failed", e)
                } finally {
                    openingInFlight = false
                }
            }
        } catch (e: Exception) {
            openingInFlight = false
        }
    }

    /**
     * AI furniture detection (GL thread): the camera image, copied at half
     * size, goes to the detector on its own thread; what it finds is placed
     * on the floor and added to [furniture] on the UI thread.
     */
    private fun startFurnitureAttempt(frame: com.google.ar.core.Frame, camera: com.google.ar.core.Camera, floorY: Float) {
        val image = try {
            frame.acquireCameraImage()
        } catch (e: Exception) {
            return
        }
        val yuv = try {
            HalfYuv.copy(image)
        } catch (e: Exception) {
            Log.w(TAG, "camera image copy failed", e)
            return
        } finally {
            image.close()
        }
        val intr = camera.imageIntrinsics
        val dims = intr.imageDimensions
        val sx = if (dims[0] > 0) yuv.sensorWidth.toFloat() / dims[0] else 1f
        val sy = if (dims[1] > 0) yuv.sensorHeight.toFloat() / dims[1] else 1f
        val pose = FloatArray(16)
        camera.pose.toMatrix(pose, 0)
        val cam = PinholeCamera(
            pose, intr.focalLength[0] * sx, intr.focalLength[1] * sy,
            intr.principalPoint[0] * sx, intr.principalPoint[1] * sy, yuv.sensorWidth, yuv.sensorHeight,
        )
        @Suppress("DEPRECATION")
        val display = windowManager.defaultDisplay.rotation * 90
        val degrees = ((sensorOrientation - display) % 360 + 360) % 360
        val gen = scanGeneration
        furnitureInFlight = true
        try {
            furnitureExecutor.execute {
                try {
                    val model = furnitureModel ?: FurnitureModel(this).also { furnitureModel = it }
                    val bmp = yuv.toUprightBitmap(degrees)
                    // Boxes are in the half-size upright picture.
                    val toSensor = uprightToSensor(degrees, yuv.sensorWidth, yuv.sensorHeight)
                    val uprightH = if (degrees % 180 == 0) yuv.sensorHeight else yuv.sensorWidth
                    val found = model.detect(bmp).mapNotNull { d ->
                        val full = Detection2D(d.label, d.score, d.left * 2, d.top * 2, d.right * 2, d.bottom * 2)
                        FurniturePlacement.place(full, cam, floorY, uprightH.toFloat(), toSensor)
                    }
                    bmp.recycle()
                    if (found.isNotEmpty()) {
                        runOnUiThread { if (gen == scanGeneration) found.forEach(furniture::add) }
                    }
                } catch (e: Throwable) {
                    // No model on this phone (or it failed to load): scan on
                    // without furniture.
                    Log.w(TAG, "furniture detection failed", e)
                    if (furnitureModel == null) furnitureModelFailed = true
                } finally {
                    furnitureInFlight = false
                }
            }
        } catch (e: Exception) {
            furnitureInFlight = false
        }
    }

    /** The camera image's Y plane, copied (the image is closed at once);
     *  null when there is none this frame. */
    private fun copyLuminance(frame: com.google.ar.core.Frame): ByteLuminance? {
        val image = try {
            frame.acquireCameraImage()
        } catch (e: NotYetAvailableException) {
            return null
        } catch (e: Exception) {
            Log.w(TAG, "camera image unavailable", e)
            return null
        }
        return try {
            val w = image.width
            val h = image.height
            val plane = image.planes[0]
            val buf = plane.buffer
            val rs = plane.rowStride
            val ps = plane.pixelStride
            val out = ByteArray(w * h)
            if (ps == 1) {
                for (r in 0 until h) {
                    buf.position(r * rs)
                    buf.get(out, r * w, w)
                }
            } else {
                for (r in 0 until h) {
                    val row = r * rs
                    for (col in 0 until w) out[r * w + col] = buf.get(row + col * ps)
                }
            }
            ByteLuminance(out, w, h)
        } catch (e: Exception) {
            Log.w(TAG, "camera image copy failed", e)
            null
        } finally {
            image.close()
        }
    }

    /**
     * The wall a door / window is looked for on (GL thread), the first of:
     *  a. a detected wall surface under the crosshair;
     *  b. a vertical plane fitted to points measured left and right of the
     *     crosshair (it may look through an open doorway);
     *  c. the side of the room outline under the crosshair;
     *  d. a detected wall surface extended beyond its area (estimated);
     *  e. the scan points around the crosshair, facing the camera (estimated);
     *  f. doors, floor known: through the floor at the bottom of the screen,
     *     facing the camera (estimated).
     * Null when none.
     */
    private fun openingWall(
        kind: OpeningKind, frame: com.google.ar.core.Frame, planes: List<Plane>, polygons: Map<Plane, FloatArray>,
        floorY: Float?, ray: Ray, viewProj: FloatArray,
    ): OpeningWall? {
        val o = ray.origin
        fun make(px: Float, pz: Float, nx: Float, nz: Float, source: String, estimated: Boolean): OpeningWall? {
            val l = sqrt(nx * nx + nz * nz)
            if (l < 1e-3f) return null
            var ux = nx / l
            var uz = nz / l
            // Facing the camera.
            if ((o.x - px) * ux + (o.z - pz) * uz < 0f) {
                ux = -ux
                uz = -uz
            }
            // Seen at a grazing angle the image says little about it.
            val denom = ux * ray.dir.x + uz * ray.dir.z
            if (abs(denom) < 0.2f) return null
            val t = ((px - o.x) * ux + (pz - o.z) * uz) / denom
            if (t < 0.3f || t > 10f) return null
            return OpeningWall(WallFrame(o + ray.dir * t, Vec3(ux, 0f, uz), floorY, estimated), source)
        }

        // a. A detected wall surface.
        var best: OpeningWall? = null
        var bestT = Float.MAX_VALUE
        for (p in planes) {
            if (p.type != Plane.Type.VERTICAL) continue
            val poly = polygons[p] ?: continue
            if (poly.size < 6) continue
            val cp = p.centerPose
            val n = cp.yAxis
            val normal = Vec3(n[0], n[1], n[2])
            val denom = normal.dot(ray.dir)
            if (abs(denom) < 1e-3f) continue
            val t = (Vec3(cp.tx(), cp.ty(), cp.tz()) - o).dot(normal) / denom
            if (t <= 0.3f || t >= 10f || t >= bestT) continue
            val w = o + ray.dir * t
            val local = cp.inverse().transformPoint(floatArrayOf(w.x, w.y, w.z))
            if (!inPolygon(poly, local[0], local[2], 0f)) continue
            make(w.x, w.z, n[0], n[2], "plane", false)?.let {
                best = it
                bestT = t
            }
        }
        best?.let { return it }

        // b. Points measured around the crosshair, on its row and lower.
        if (viewWidth > 0 && viewHeight > 0) {
            val pts = ArrayList<Vec3>()
            for (fy in floatArrayOf(0.5f, 0.7f)) for (fx in floatArrayOf(0.15f, 0.3f, 0.7f, 0.85f)) {
                val r = screenRay(viewProj, 2f * fx - 1f, 1f - 2f * fy) ?: continue
                val pk = pickAt(frame, planes, polygons, floorY, r, fx * viewWidth, fy * viewHeight) ?: continue
                if (pk.estimated || pk.source == "floor" || pk.source == "ceiling" || pk.source == "surface") continue
                if (floorY != null && pk.p.y < floorY + 0.05f) continue
                pts.add(pk.p)
            }
            fitWallLine(pts, o)?.let { l -> make(l[0], l[1], l[2], l[3], "fit", false)?.let { return it } }
        }

        // c. The room outline's side under the crosshair.
        glAutoRoom?.let { room ->
            val n = room.corners.size
            var near = Float.MAX_VALUE
            var hit: OpeningWall? = null
            for (i in 0 until if (n >= 3) n else 0) {
                val a = room.corners[i]
                val b = room.corners[(i + 1) % n]
                val ex = b.x - a.x
                val ez = b.z - a.z
                val l = sqrt(ex * ex + ez * ez)
                if (l < 0.05f) continue
                val ux = ex / l
                val uz = ez / l
                val denom = -uz * ray.dir.x + ux * ray.dir.z
                if (abs(denom) < 1e-3f) continue
                val t = ((a.x - o.x) * -uz + (a.z - o.z) * ux) / denom
                if (t <= 0.3f || t >= 10f || t >= near) continue
                val hx = o.x + ray.dir.x * t
                val hz = o.z + ray.dir.z * t
                val along = (hx - a.x) * ux + (hz - a.z) * uz
                if (along < -0.15f || along > l + 0.15f) continue
                make(hx, hz, -uz, ux, "room", false)?.let {
                    near = t
                    hit = it
                }
            }
            hit?.let { return it }
        }

        // d. A detected wall surface extended up to 2 m beyond its area.
        var nearest = Float.MAX_VALUE
        for (p in planes) {
            if (p.type != Plane.Type.VERTICAL) continue
            val poly = polygons[p] ?: continue
            if (poly.size < 6) continue
            val cp = p.centerPose
            val n = cp.yAxis
            val normal = Vec3(n[0], n[1], n[2])
            val denom = normal.dot(ray.dir)
            if (abs(denom) < 1e-3f) continue
            val t = (Vec3(cp.tx(), cp.ty(), cp.tz()) - o).dot(normal) / denom
            if (t <= 0.3f || t >= 8f || t >= nearest) continue
            val w = o + ray.dir * t
            if (floorY != null && (w.y < floorY - 0.05f || w.y > floorY + 3.5f)) continue
            val local = cp.inverse().transformPoint(floatArrayOf(w.x, w.y, w.z))
            if (!inPolygon(poly, local[0], local[2], 2.0f)) continue
            make(w.x, w.z, n[0], n[2], "extended", true)?.let {
                nearest = t
                best = it
            }
        }
        best?.let { return it }

        // e, f: facing the camera.
        val hl = sqrt(ray.dir.x * ray.dir.x + ray.dir.z * ray.dir.z)
        if (hl < 0.3f) return null
        val nx = -ray.dir.x / hl
        val nz = -ray.dir.z / hl
        cloudMedianNearRay(ray)?.let { s ->
            val p = o + ray.dir * s
            make(p.x, p.z, nx, nz, "cloud", true)?.let { return it }
        }
        // (Windows too: the floor line then places the wall; see startOpeningAttempt.)
        if (floorY != null) {
            val r = screenRay(viewProj, 0f, -1f)
            if (r != null && r.dir.y < -0.05f) {
                val t = (floorY - r.origin.y) / r.dir.y
                if (t in 0.2f..10f) {
                    val p = r.origin + r.dir * t
                    make(p.x, p.z, nx, nz, "floor", true)?.let { return it }
                }
            }
        }
        return null
    }

    /**
     * A vertical plane through [pts] (x, z): the line through two points at
     * least 0.4 m apart with the most points within 8 cm of it (the nearer
     * one to [cam] on a tie), refitted to those. Returns a point on it and
     * its normal (px, pz, nx, nz), or null.
     */
    private fun fitWallLine(pts: List<Vec3>, cam: Vec3): FloatArray? {
        var bestIn: List<Vec3>? = null
        var bestDist = Float.MAX_VALUE
        for (i in pts.indices) for (j in i + 1 until pts.size) {
            val a = pts[i]
            val b = pts[j]
            val l = a.dist2d(b)
            if (l < 0.4f) continue
            val nx = -(b.z - a.z) / l
            val nz = (b.x - a.x) / l
            val inliers = pts.filter { abs((it.x - a.x) * nx + (it.z - a.z) * nz) <= 0.08f }
            val dist = inliers.sumOf { it.dist2d(cam).toDouble() }.toFloat() / inliers.size
            val cur = bestIn
            if (cur == null || inliers.size > cur.size || (inliers.size == cur.size && dist < bestDist)) {
                bestIn = inliers
                bestDist = dist
            }
        }
        val inl = bestIn ?: return null
        if (inl.size < 2) return null
        var mx = 0f
        var mz = 0f
        for (p in inl) {
            mx += p.x
            mz += p.z
        }
        mx /= inl.size
        mz /= inl.size
        var sxx = 0f
        var sxz = 0f
        var szz = 0f
        for (p in inl) {
            val dx = p.x - mx
            val dz = p.z - mz
            sxx += dx * dx
            sxz += dx * dz
            szz += dz * dz
        }
        // Direction of the line: the principal axis.
        val ang = 0.5f * atan2(2f * sxz, sxx - szz)
        return floatArrayOf(mx, mz, -sin(ang), cos(ang))
    }

    /** Median distance along [ray] of the scan points within 10° of it
     *  (0.2-8 m away), or null when fewer than 6. */
    private fun cloudMedianNearRay(ray: Ray): Float? {
        val ds = ArrayList<Float>()
        fun test(px: Float, py: Float, pz: Float) {
            val vx = px - ray.origin.x
            val vy = py - ray.origin.y
            val vz = pz - ray.origin.z
            val s = vx * ray.dir.x + vy * ray.dir.y + vz * ray.dir.z
            if (s <= 0.2f || s >= 8f) return
            if (s * s / (vx * vx + vy * vy + vz * vz) < COS2_10) return
            ds.add(s)
        }
        for (p in cloud.values) test(p.x, p.y, p.z)
        depthVoxels.forEachMean(2) { x, y, z -> test(x, y, z) }
        if (ds.size < 6) return null
        ds.sort()
        return ds[ds.size / 2]
    }

    /** The current framebuffer as a bitmap (GL origin is bottom-left, so the
     *  rows are flipped). */
    private fun readFramebuffer(w: Int, h: Int): Bitmap {
        val buf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
        buf.rewind()
        val src = IntArray(w * h)
        buf.order(ByteOrder.LITTLE_ENDIAN).asIntBuffer().get(src)
        val out = IntArray(w * h)
        for (y in 0 until h) {
            val from = y * w
            val to = (h - 1 - y) * w
            for (x in 0 until w) {
                // Bytes R, G, B, A read little-endian: 0xAABBGGRR -> 0xFFRRGGBB.
                val c = src[from + x]
                out[to + x] = (0xFF shl 24) or ((c and 0xFF) shl 16) or (c and 0xFF00) or ((c ushr 16) and 0xFF)
            }
        }
        return Bitmap.createBitmap(out, w, h, Bitmap.Config.ARGB_8888)
    }

    /**
     * Each side of [room] (corner i to i + 1, at floor level) as a vertical
     * wall from the floor up to the ceiling (or 3 m): passes the ray's
     * distance to [consider] where the ray hits it.
     */
    private fun considerRoomWalls(room: AutoRoom, ray: Ray, consider: (Float, String, Float?) -> Unit) {
        val n = room.corners.size
        if (n < 3) return
        val o = ray.origin
        val d = ray.dir
        for (i in 0 until n) {
            val a = room.corners[i]
            val b = room.corners[(i + 1) % n]
            val ex = b.x - a.x
            val ez = b.z - a.z
            val l = sqrt(ex * ex + ez * ez)
            if (l < 0.05f) continue
            val ux = ex / l
            val uz = ez / l
            // Horizontal wall normal.
            val nx = -uz
            val nz = ux
            val denom = nx * d.x + nz * d.z
            if (abs(denom) < 1e-3f) continue
            val t = ((a.x - o.x) * nx + (a.z - o.z) * nz) / denom
            if (t <= 0.15f || t >= 12f) continue
            val hx = o.x + d.x * t
            val hy = o.y + d.y * t
            val hz = o.z + d.z * t
            val along = (hx - a.x) * ux + (hz - a.z) * uz
            if (along < -0.15f || along > l + 0.15f) continue
            val floor = (a.y + b.y) / 2f
            val top = glCeilingY ?: (floor + 3.0f)
            if (hy < floor - 0.05f || hy > top) continue
            consider(t, "room", null)
        }
    }

    /** Matching distances along the ray, reused between frames (GL thread). */
    private var rayHits = FloatArray(256)

    /**
     * Distance along [ray] to the accumulated points ([cloud] and depth voxels
     * seen at least twice) lying close to it: the 25th percentile of the
     * matches, or null when fewer than 6 match.
     */
    private fun cloudAlongRay(ray: Ray): Float? {
        val ox = ray.origin.x
        val oy = ray.origin.y
        val oz = ray.origin.z
        val dx = ray.dir.x
        val dy = ray.dir.y
        val dz = ray.dir.z
        var n = 0
        fun test(px: Float, py: Float, pz: Float) {
            val vx = px - ox
            val vy = py - oy
            val vz = pz - oz
            val s = vx * dx + vy * dy + vz * dz
            if (s <= 0.2f || s >= 12f) return
            val perp2 = vx * vx + vy * vy + vz * vz - s * s
            val tol = max(0.03f, 0.012f * s)
            if (perp2 > tol * tol) return
            if (n == rayHits.size) rayHits = rayHits.copyOf(n * 2)
            rayHits[n++] = s
        }
        for (p in cloud.values) test(p.x, p.y, p.z)
        depthVoxels.forEachMean(2) { x, y, z -> test(x, y, z) }
        if (n < 6) return null
        java.util.Arrays.sort(rayHits, 0, n)
        return rayHits[(n - 1) / 4]
    }

    /**
     * Estimates for a tapped spot where nothing can be measured (GL thread):
     *  a. with the line's first point [anchor] set, the vertical plane
     *     through it that faces the camera ([forward] is where the camera
     *     looks): the user is assumed to stand facing the wall both points
     *     are on;
     *  b. else (or when that plane is not ahead) the typical distance of the
     *     scan points seen around the tapped direction.
     */
    private fun tapEstimate(ray: Ray, anchor: Vec3?, forward: Vec3): Vec3? {
        if (anchor != null) {
            val fl = sqrt(forward.x * forward.x + forward.z * forward.z)
            // Looking straight down or up there is no facing wall.
            if (fl > 0.2f) {
                val n = Vec3(forward.x / fl, 0f, forward.z / fl)
                val denom = n.dot(ray.dir)
                if (abs(denom) > 1e-3f) {
                    val t = (anchor - ray.origin).dot(n) / denom
                    if (t > 0.15f && t < 8f) return ray.origin + ray.dir * t
                }
            }
        }
        val s = cloudNearRay(ray) ?: return null
        return ray.origin + ray.dir * s
    }

    /** The scan points angularly nearest to a ray, reused between frames
     *  (GL thread): cos² of the angle, and the distance along the ray. */
    private val nearCos = FloatArray(9)
    private val nearDist = FloatArray(9)

    /**
     * Distance along [ray] taken from the accumulated points ([cloud] and
     * depth voxels seen at least twice) within 15° of it, 0.2-8 m along it:
     * the median distance of the 9 angularly nearest, or null when fewer
     * than 5 lie in that cone. Much looser than [cloudAlongRay], which needs
     * points on the line of sight itself; plain walls have none.
     */
    private fun cloudNearRay(ray: Ray): Float? {
        val ox = ray.origin.x
        val oy = ray.origin.y
        val oz = ray.origin.z
        val dx = ray.dir.x
        val dy = ray.dir.y
        val dz = ray.dir.z
        var n = 0
        var kept = 0
        fun test(px: Float, py: Float, pz: Float) {
            val vx = px - ox
            val vy = py - oy
            val vz = pz - oz
            val s = vx * dx + vy * dy + vz * dz
            if (s <= 0.2f || s >= 8f) return
            val c2 = s * s / (vx * vx + vy * vy + vz * vz)
            if (c2 < COS2_15) return
            n++
            if (kept == nearCos.size && c2 <= nearCos[kept - 1]) return
            // Insert, keeping the nearest (largest cos²) first.
            var i = if (kept < nearCos.size) kept++ else kept - 1
            while (i > 0 && nearCos[i - 1] < c2) {
                nearCos[i] = nearCos[i - 1]
                nearDist[i] = nearDist[i - 1]
                i--
            }
            nearCos[i] = c2
            nearDist[i] = s
        }
        for (p in cloud.values) test(p.x, p.y, p.z)
        depthVoxels.forEachMean(2) { x, y, z -> test(x, y, z) }
        if (n < 5) return null
        val d = nearDist.copyOf(kept)
        d.sort()
        return if (kept % 2 == 1) d[kept / 2] else (d[kept / 2 - 1] + d[kept / 2]) / 2f
    }

    /** The world-space ray through the centre of the screen. */
    private fun centreRay(viewProj: FloatArray) = screenRay(viewProj, 0f, 0f)

    /** The world-space ray through a screen position given in normalised
     *  device coordinates (x right, y up, -1..1; the centre is 0, 0). */
    private fun screenRay(viewProj: FloatArray, ndcX: Float, ndcY: Float): Ray? {
        val inv = FloatArray(16)
        if (!Matrix.invertM(inv, 0, viewProj, 0)) return null
        fun unproject(ndcZ: Float): Vec3? {
            val v = FloatArray(4)
            Matrix.multiplyMV(v, 0, inv, 0, floatArrayOf(ndcX, ndcY, ndcZ, 1f), 0)
            if (abs(v[3]) < 1e-9f) return null
            return Vec3(v[0] / v[3], v[1] / v[3], v[2] / v[3])
        }
        val near = unproject(-1f) ?: return null
        val far = unproject(1f) ?: return null
        val d = far - near
        val len = sqrt(d.dot(d))
        if (len < 1e-6f) return null
        return Ray(near, d * (1f / len))
    }

    /**
     * Adds this frame's confident feature points (within 6 m) to [cloud] and
     * returns them.
     */
    private fun collectPoints(frame: com.google.ar.core.Frame, cam: Vec3): List<Vec3> {
        val pc = try {
            frame.acquirePointCloud()
        } catch (e: Exception) {
            return emptyList()
        }
        val seen = ArrayList<Vec3>()
        try {
            val pts = pc.points
            val ids = pc.ids
            val n = minOf(pts.remaining() / 4, ids.remaining())
            for (i in 0 until n) {
                if (pts.get(i * 4 + 3) < 0.3f) continue
                val p = Vec3(pts.get(i * 4), pts.get(i * 4 + 1), pts.get(i * 4 + 2))
                if (p.dist2d(cam) > 6f) continue
                val id = ids.get(i)
                seen.add(p)
                if (cloud.size >= MAX_CLOUD && !cloud.containsKey(id)) continue
                cloud[id] = p
            }
        } finally {
            pc.release()
        }
        return seen
    }

    /**
     * Adds the confident pixels of ARCore's raw depth image (0.3-4.5 m away)
     * to [depthVoxels] and returns them as world points.
     */
    private fun collectDepth(frame: com.google.ar.core.Frame, camera: com.google.ar.core.Camera): List<Vec3> {
        val depth = try {
            frame.acquireRawDepthImage16Bits()
        } catch (e: Exception) {
            return emptyList()
        }
        val conf = try {
            frame.acquireRawDepthConfidenceImage()
        } catch (e: Exception) {
            depth.close()
            return emptyList()
        }
        val out = ArrayList<Vec3>()
        try {
            val w = depth.width
            val h = depth.height
            if (conf.width != w || conf.height != h) return emptyList()
            val intr = camera.textureIntrinsics
            val dims = intr.imageDimensions
            val f = intr.focalLength
            val c = intr.principalPoint
            val sx = w.toFloat() / dims[0]
            val sy = h.toFloat() / dims[1]
            val fx = f[0] * sx
            val fy = f[1] * sy
            val px = c[0] * sx
            val py = c[1] * sy
            // The depth image is in the camera sensor's frame (camera.pose):
            // +x right, +y up, looking down -z.
            val m = FloatArray(16)
            camera.pose.toMatrix(m, 0)
            val dp = depth.planes[0]
            val dBuf = dp.buffer.order(ByteOrder.nativeOrder())
            val cp = conf.planes[0]
            val cBuf = cp.buffer
            for (v in 0 until h step 2) {
                for (u in 0 until w step 2) {
                    val cv = cBuf.get(v * cp.rowStride + u * cp.pixelStride).toInt() and 0xFF
                    if (cv < CONF_MIN) continue
                    val mm = dBuf.getShort(v * dp.rowStride + u * dp.pixelStride).toInt() and 0xFFFF
                    if (mm < 300 || mm > 4500) continue
                    val d = mm / 1000f
                    val xc = (u + 0.5f - px) / fx * d
                    val yc = -(v + 0.5f - py) / fy * d
                    val zc = -d
                    val p = Vec3(
                        m[0] * xc + m[4] * yc + m[8] * zc + m[12],
                        m[1] * xc + m[5] * yc + m[9] * zc + m[13],
                        m[2] * xc + m[6] * yc + m[10] * zc + m[14],
                    )
                    out.add(p)
                    // Depth error grows with the square of the distance:
                    // near samples count for more in their voxel's mean.
                    depthVoxels.add(p.x, p.y, p.z, 1f / (d * d))
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "depth sampling failed", e)
        } finally {
            depth.close()
            conf.close()
        }
        return out
    }

    /**
     * Floor height from points: the lowest well-filled 5 cm layer between
     * 0.6 m and 2.2 m below the phone (the floor is the largest flat area
     * below it; a lower sparse layer is noise, a smaller higher one is
     * furniture).
     */
    private fun estimateFloor(pts: List<Vec3>, camY: Float): Float? {
        // No lower than 1.85 m under the phone: nobody holds it higher. Depth
        // noise under desks made a "floor" 2.2 m down, so every line drawn
        // and the room height were wrong.
        val lo = camY - 1.85f
        val bins = IntArray(32)
        var n = 0
        for (p in pts) {
            val dy = p.y - lo
            if (dy < 0f || p.y > camY - 0.6f) continue
            bins[(dy / 0.05f).toInt().coerceIn(0, 31)]++
            n++
        }
        if (n < 80) return null
        val smooth = IntArray(32) { i -> bins[i] + (if (i > 0) bins[i - 1] else 0) + (if (i < 31) bins[i + 1] else 0) }
        val best = smooth.max()
        if (best < 40) return null
        val i = smooth.indices.first { smooth[it] >= maxOf(40, (best * 0.4f).toInt()) }
        // At the bottom of the range: the points go on below it, so this is
        // the edge of depth noise, not a floor (a floor has little under it).
        if (i <= 1) return null
        // Centre of the layer around that bin.
        var sum = 0f
        var cnt = 0
        for (j in maxOf(0, i - 1)..minOf(31, i + 1)) {
            sum += bins[j] * (lo + (j + 0.5f) * 0.05f)
            cnt += bins[j]
        }
        return if (cnt > 0) sum / cnt else null
    }

    private var lastScanLog = ""

    /** Logs what the scanner sees whenever it changes (adb logcat -s RoomMeasureAR). */
    private fun logScanState(planes: Int, walls: Int, points: Int, floorY: Float, floorSource: String, room: AutoRoom?) {
        val r = room?.let {
            String.format(
                "%d corners %.2f x %.2f m, area %.2f m², estimated sides %d, height %s",
                it.corners.size, it.width, it.depth, it.area, it.estimatedCount,
                it.height?.let { h -> String.format("%.2f", h) } ?: "-",
            )
        } ?: "none"
        // Point counts change every frame; log them in steps of 500.
        val msg = "surfaces=$planes walls=$walls points~${points / 500 * 500} " +
            "floorY=${String.format("%.2f", floorY)} ($floorSource) room: $r"
        if (msg != lastScanLog) {
            lastScanLog = msg
            diag("scan: $msg")
        }
    }

    private fun readPolygon(p: Plane): FloatArray {
        val buf = p.polygon
        buf.rewind()
        val out = FloatArray(buf.remaining())
        buf.get(out)
        return out
    }

    /** Floor = lowest large upward surface well below the phone; ceiling likewise. */
    private fun detectFloorAndCeiling(planes: List<Plane>, camY: Float) {
        var floor: Float? = null
        var floorArea = 0f
        var ceiling: Float? = null
        var ceilingArea = 0f
        for (p in planes) {
            val y = p.centerPose.ty()
            val area = p.extentX * p.extentZ
            if (area < 0.2f) continue
            when (p.type) {
                Plane.Type.HORIZONTAL_UPWARD_FACING -> {
                    if (y > camY - 0.5f) continue
                    val f = floor
                    if (f == null || y < f - 0.08f || (abs(y - f) <= 0.08f && area > floorArea)) {
                        floor = y
                        floorArea = area
                    }
                }
                Plane.Type.HORIZONTAL_DOWNWARD_FACING -> {
                    if (y < camY + 0.2f) continue
                    if (area > ceilingArea) {
                        ceiling = y
                        ceilingArea = area
                    }
                }
                else -> {}
            }
        }
        if (floor != null) glFloorY = floor
        if (ceiling != null) glCeilingY = ceiling
    }


    private fun wallSegment(normal: FloatArray, cx: Float, cz: Float, pts: List<Vec3>): WallSegment? {
        val nl = sqrt(normal[0] * normal[0] + normal[2] * normal[2])
        if (nl < 0.5f) return null
        val dx = -normal[2] / nl
        val dz = normal[0] / nl
        var tMin = Float.MAX_VALUE
        var tMax = -Float.MAX_VALUE
        for (p in pts) {
            val t = (p.x - cx) * dx + (p.z - cz) * dz
            tMin = minOf(tMin, t)
            tMax = maxOf(tMax, t)
        }
        if (tMax - tMin < 0.25f) return null
        return WallSegment(cx, cz, dx, dz, tMin, tMax, pts.maxOf { it.y })
    }


    /** Corners where two detected walls (at least 50 degrees apart) meet. */
    private fun findCorners(walls: List<WallSegment>, y: Float): List<Vec3> {
        val out = mutableListOf<Vec3>()
        val reach = 0.6f
        for (i in walls.indices) for (j in i + 1 until walls.size) {
            val a = walls[i]
            val b = walls[j]
            val denom = a.dx * b.dz - a.dz * b.dx
            if (abs(denom) < 0.766f) continue // sin(50 deg)
            val wx = b.cx - a.cx
            val wz = b.cz - a.cz
            val ta = (wx * b.dz - wz * b.dx) / denom
            val tb = (wx * a.dz - wz * a.dx) / denom
            if (ta < a.tMin - reach || ta > a.tMax + reach) continue
            if (tb < b.tMin - reach || tb > b.tMax + reach) continue
            val c = Vec3(a.cx + a.dx * ta, y, a.cz + a.dz * ta)
            if (out.none { it.dist2d(c) < 0.15f }) out.add(c)
        }
        return out
    }

    /** Point in polygon (x, z pairs), or within [margin] metres of its edge. */
    private fun inPolygon(poly: FloatArray, x: Float, z: Float, margin: Float): Boolean {
        val n = poly.size / 2
        var inside = false
        var j = n - 1
        for (i in 0 until n) {
            val xi = poly[2 * i]
            val zi = poly[2 * i + 1]
            val xj = poly[2 * j]
            val zj = poly[2 * j + 1]
            if ((zi > z) != (zj > z) && x < (xj - xi) * (z - zi) / (zj - zi) + xi) inside = !inside
            j = i
        }
        if (inside || margin <= 0f) return inside
        j = n - 1
        for (i in 0 until n) {
            val ax = poly[2 * j]
            val az = poly[2 * j + 1]
            val ex = poly[2 * i] - ax
            val ez = poly[2 * i + 1] - az
            val len2 = ex * ex + ez * ez
            val t = if (len2 > 0f) (((x - ax) * ex + (z - az) * ez) / len2).coerceIn(0f, 1f) else 0f
            val px = ax + ex * t - x
            val pz = az + ez * t - z
            if (px * px + pz * pz <= margin * margin) return true
            j = i
        }
        return false
    }

    // ------------------------------------------------------------ measuring logic

    /** The automatic room is used unless the user marked corners by hand. */
    /** The automatic outline is used unless Corners mode was chosen. */
    private fun useAutoRoom() = !manualOutline

    /** Steadies the crosshair's point over the last few frames (UI thread). */
    private val aimSmoother = AimSmoother()

    private fun resolveAim(snap: Snapshot): Aim? {
        // Held still, the median of the last few frames' hits: one frame's
        // depth / tracking noise no longer goes into the measurement.
        val hit = snap.hit?.let { aimSmoother.point(it) } ?: return null
        if (mode == Mode.CORNER) {
            if (corners.size >= 3 && hit.dist2d(corners[0]) < 0.25f) return Aim(corners[0], true, true)
            val c = snap.cornerCandidates.minByOrNull { it.dist2d(hit) }
            if (c != null && c.dist2d(hit) < 0.3f) return Aim(Vec3(c.x, hit.y, c.z), true, false)
        }
        return Aim(hit, false, false)
    }

    private fun perimeter(): Float {
        var s = 0f
        for (i in 1 until corners.size) s += corners[i - 1].dist2d(corners[i])
        if (corners.size >= 3) s += corners.last().dist2d(corners.first())
        return s
    }

    private fun area(): Float {
        if (corners.size < 3) return 0f
        var s = 0f
        for (i in corners.indices) {
            val a = corners[i]
            val b = corners[(i + 1) % corners.size]
            s += a.x * b.z - b.x * a.z
        }
        return abs(s) / 2f
    }

    private fun m(v: Float) = String.format("%.2f m", v)

    private fun area2(v: Float) = String.format("%.2f m²", v)

    /** "0.82 × 2.03 m", or just the width when the height is unknown. */
    private fun sizeText(w: Float, h: Float?) =
        if (h == null) m(w) else String.format("%.2f × %.2f m", w, h)

    /**
     * Height of an opening up to [topY]. A door is measured from the floor
     * when it is known (its sides are marked at floor level, but the point
     * hit there can sit a little above it); a window from its sill.
     */
    private fun openingHeight(o: OpeningMark, floorY: Float?, topY: Float? = o.topY): Float? {
        val top = topY ?: return null
        // A touched door's base is its own floor-level taps, not the floor.
        val touched = o.method == METHOD_TOUCH
        return top - (if (o.type == TYPE_DOOR && !touched) floorY ?: o.baseY else o.baseY)
    }

    /** Length of a..b in 3D; with the horizontal and vertical parts when the
     *  line is clearly neither level nor upright. */
    private fun lineText(a: Vec3, b: Vec3): String {
        val h = a.dist2d(b)
        val v = abs(b.y - a.y)
        val d = m(len(b - a))
        return if (h > 0.05f && v > 0.05f) "$d  (↔ ${m(h)}  ↕ ${m(v)})" else d
    }

    private fun linesSummary() =
        if (lines.isEmpty()) "No lines measured yet"
        else "${lines.size} line${if (lines.size == 1) "" else "s"}:  " + lines.joinToString(",  ") { m(it.length) }

    /** A lone first end of a line is dropped (mode switch, Finish). */
    private fun dropPendingLine() {
        if (pendingLine == null) return
        pendingLine = null
        if (history.lastOrNull() == H_LINE_POINT) history.removeAt(history.lastIndex)
    }

    private fun flash(msg: String) {
        flashMessage = msg
        flashUntil = SystemClock.uptimeMillis() + 2600
        refreshUi()
    }

    private fun touchLine() = mode == Mode.LINE && lineMethod == LineMethod.TOUCH

    /** Touch method: how the phone was turned when the first point was set. */
    private var touchForward = Vec3(0f, 0f, -1f)
    private var touchUp = Vec3(0f, 1f, 0f)

    /**
     * Touch method with the first point set: the phone has since been turned
     * by more than about 12 degrees. The method measures how far the phone
     * moved, which is only the distance between the two points when the same
     * corner touches both and the phone is not turned in between.
     */
    private fun touchTurned(snap: Snapshot?): Boolean {
        if (snap == null || !touchLine() || pendingLine == null) return false
        val limit = 0.978f // cos(12 degrees)
        return snap.camForward.dot(touchForward) < limit || snap.camUp.dot(touchUp) < limit
    }

    /** Taps on the camera view place line points (Line mode, Aim). */
    private fun tapLine() = mode == Mode.LINE && lineMethod == LineMethod.AIM

    /** The finger's preview ring is showing: down, or lifted and its point
     *  not back from the GL thread yet. */
    private fun tapShown() = tapDown || tapReleaseSeq >= 0

    /** The latest answer for the current touch, null before the first. */
    private fun tapPreview() = tapPick?.takeIf { it.req.seq >= tapGestureSeq }

    private fun requestTap(x: Float, y: Float, release: Boolean) {
        tapX = x
        tapY = y
        tapRequest = TapRequest(x, y, ++tapSeq, pendingLine, release)
    }

    private fun onTapDown(x: Float, y: Float) {
        tapDown = true
        tapReleaseSeq = -1
        tapMissUntil = 0L
        tapGestureSeq = tapSeq + 1
        requestTap(x, y, false)
    }

    private fun onTapMove(x: Float, y: Float) {
        if (tapDown) requestTap(x, y, false)
    }

    /** The point is placed where the finger was lifted, so it is picked
     *  again for exactly that position (see [resolveTap]). */
    private fun onTapUp(x: Float, y: Float) {
        if (!tapDown) return
        tapDown = false
        requestTap(x, y, true)
        tapReleaseSeq = tapSeq
    }

    private fun clearTap() {
        tapDown = false
        tapReleaseSeq = -1
        tapRequest = null
        tapPick = null
    }

    /** Places the tapped point once the pick for the release position is in. */
    private fun resolveTap() {
        val pick = tapPick ?: return
        if (tapReleaseSeq < 0 || pick.req.seq != tapReleaseSeq) return
        clearTap()
        val p = pick.p
        if (p == null) {
            tapMissX = pick.req.x
            tapMissY = pick.req.y
            tapMissUntil = SystemClock.uptimeMillis() + 1500
            flash("Can't tell how far that spot is. Move the phone a little sideways and tap again, or use Touch.")
            return
        }
        if (placeLinePoint(p, pick.estimated, "tap")) {
            overlay.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
        }
        overlay.invalidate()
    }

    /**
     * Adds [p] as the line's first end, or as the second end completing it.
     * [how] is how it was taken ("tap", "aim", "touch"). False when refused
     * (the same spot as the first end).
     */
    private fun placeLinePoint(p: Vec3, estimated: Boolean, how: String): Boolean {
        val a = pendingLine
        if (a == null) {
            pendingLine = p
            pendingLineEstimated = estimated
            history.add(H_LINE_POINT)
            flash("First point marked")
            return true
        }
        if (len(p - a) < 0.01f) {
            flash(
                when (how) {
                    "touch" -> "Move the phone to the second point first."
                    "tap" -> "Tap a different point for the other end."
                    else -> "Aim at a different point for the other end."
                }
            )
            return false
        }
        val l = LineMark(a, p, pendingLineEstimated, estimated)
        lines.add(l)
        pendingLine = null
        pendingLineEstimated = false
        history.add(H_LINE)
        diag("line ${lines.size} ($how${if (l.estimated) ", estimated" else ""}): ${m(l.length)}")
        flash("Line added: ${if (l.estimated) "≈ " else ""}${lineText(a, p)}")
        return true
    }

    private fun onLineMethod(method: LineMethod) {
        if (method == lineMethod) return
        dropPendingLine()
        lineMethod = method
        diag("line method ${method.label.lowercase()}")
        flashMessage = null
        refreshUi()
        overlay.invalidate()
    }

    // ------------------------------------------------------------ doors / windows: Auto and Touch

    private fun openingMode() = mode == Mode.DOOR || mode == Mode.WINDOW

    /** Door / window found automatically in the camera image. */
    private fun autoOpening() = openingMode() && openingMethod == OpeningMethod.AUTO

    /** Door / window from the phone's own position at each side and the top. */
    private fun touchOpening() = openingMode() && openingMethod == OpeningMethod.TOUCH

    private fun openingName() = if (mode == Mode.DOOR) "door" else "window"

    /**
     * Touch with the first side set: the phone has been turned by more than
     * about 12 degrees since (see [touchTurned]).
     */
    private fun openingTouchTurned(snap: Snapshot?): Boolean {
        if (snap == null || !touchOpening() || (pendingEdge == null && pendingOpening == null)) return false
        val limit = 0.978f // cos(12 degrees)
        return snap.camForward.dot(touchForward) < limit || snap.camUp.dot(touchUp) < limit
    }

    /** The automatic candidate is recent enough to show (and accept). */
    private fun autoFresh(now: Long = SystemClock.uptimeMillis()) =
        consensus.state != null && now - lastAutoCandidateAt < AUTO_FRESH_MS

    private fun autoStable() = autoFresh() && consensus.state?.stable == true

    /** Tells the GL thread what to look for; a new search starts afresh. */
    private fun syncAutoOpening() {
        val kind = if (!autoOpening()) null
        else if (mode == Mode.DOOR) OpeningKind.DOOR else OpeningKind.WINDOW
        if (kind != autoKindShown) {
            autoKindShown = kind
            resetAutoSearch()
        }
        autoOpeningKind = kind
        // Auto (room) mode also counts the doors and windows it sees.
        val roomScan = mode == Mode.AUTO && !lineOnly && !completing
        if (roomScan != roomOpeningScan) {
            roomOpeningScan = roomScan
            roomConsensus.values.forEach { it.clear() }
        }
    }

    /** The frame drawn on the camera view: the hand-adjusted one, else the
     *  detection while it is fresh; with the wall it lies on. */
    private fun shownOpening(): Pair<OpeningCandidate, WallFrame>? {
        adjusted?.let { return it.candidate() to it.frame }
        val st = consensus.state ?: return null
        if (!autoFresh()) return null
        return st.candidate to st.frame
    }

    /** World point to pixels of a [w] x [h] view, or null behind the camera. */
    private fun viewPoint(vp: FloatArray, p: Vec3, w: Int, h: Int): FloatArray? {
        val v = FloatArray(4)
        Matrix.multiplyMV(v, 0, vp, 0, floatArrayOf(p.x, p.y, p.z, 1f), 0)
        if (v[3] <= NEAR_W) return null
        return floatArrayOf((v[0] / v[3] + 1f) / 2f * w, (1f - v[1] / v[3]) / 2f * h)
    }

    /**
     * Where the finger at ([x], [y]) on the [w] x [h] camera view meets the
     * wall of [f]: (u along the wall, height), or null when the line of
     * sight runs (nearly) along the wall or the hit is behind / too far.
     */
    private fun wallHit(f: WallFrame, x: Float, y: Float, w: Int, h: Int): FloatArray? {
        if (w <= 0 || h <= 0) return null
        val snap = snapshot ?: return null
        val ray = screenRay(snap.viewProj, 2f * x / w - 1f, 1f - 2f * y / h) ?: return null
        val n = f.normal
        val den = ray.dir.x * n.x + ray.dir.z * n.z
        if (abs(den) < 0.05f) return null
        val t = ((f.origin.x - ray.origin.x) * n.x + (f.origin.z - ray.origin.z) * n.z) / den
        if (t <= 0.1f || t > 15f) return null
        val p = ray.origin + ray.dir * t
        return floatArrayOf(f.uOf(p), p.y)
    }

    /**
     * A finger down at ([x], [y]) on the [w] x [h] camera view: grabs one
     * side of the door / window frame shown, by its handle (the circle in
     * the middle of each side) or anywhere along its line. The frame then
     * stays as the user leaves it.
     */
    private fun grabOpening(x: Float, y: Float, w: Int, h: Int): Boolean {
        if (!autoOpening()) return false
        val snap = snapshot ?: return false
        val (c, frame) = shownOpening() ?: return false
        val corners = listOf(c.a, c.b, c.b.withY(c.topY), c.a.withY(c.topY))
        val s = corners.map { viewPoint(snap.viewProj, it, w, h) }
        val side = OpeningFrameAdjust.pickSide(s, x, y, dp(36f), dp(24f))
        if (side < 0) return false
        val adj = adjusted ?: AdjustedOpening(frame, c.left, c.right, c.bottom, c.top, c.estimated).also {
            adjusted = it
            diag("opening auto: adjusting by hand")
        }
        // Keep where the side is relative to the finger: the side follows
        // the finger's movement from here, instead of jumping onto it.
        val hit = wallHit(adj.frame, x, y, w, h)
        adjustOffset = if (hit == null) 0f else OpeningFrameAdjust.sideValue(side, adj.left, adj.right, adj.bottom, adj.top) -
            (if (side == OpeningFrameAdjust.LEFT || side == OpeningFrameAdjust.RIGHT) hit[0] else hit[1])
        adjustGrab = side
        return true
    }

    /** The held side follows the finger at ([x], [y]) on the wall the frame
     *  lies on. Only that side moves. */
    private fun dragOpening(x: Float, y: Float, w: Int, h: Int) {
        val adj = adjusted ?: return
        val g = adjustGrab
        if (g < 0) return
        val hit = wallHit(adj.frame, x, y, w, h) ?: return
        val along = g == OpeningFrameAdjust.LEFT || g == OpeningFrameAdjust.RIGHT
        val e = OpeningFrameAdjust.moveSide(
            g, (if (along) hit[0] else hit[1]) + adjustOffset, adj.left, adj.right, adj.bottom, adj.top,
        )
        adj.left = e[0]
        adj.right = e[1]
        adj.bottom = e[2]
        adj.top = e[3]
    }

    private fun resetAutoSearch() {
        consensus.clear()
        lastStable = null
        adjusted = null
        adjustGrab = -1
        autoNoWall = false
        lastOpeningResult = null
        autoSearchSince = SystemClock.uptimeMillis()
        lastAutoCandidateAt = 0L
    }

    /** An automatic attempt is back from [openingExecutor]. */
    private fun onOpeningResult(r: OpeningResult) {
        if (isFinishing || r.gen != scanGeneration) return
        if (mode == Mode.AUTO) {
            onRoomOpeningResult(r)
            return
        }
        if (!autoOpening() || r.kind != autoKindShown) return
        val now = SystemClock.uptimeMillis()
        val wall = r.wall
        if (wall == null) {
            // The detections so far are kept: an estimated wall often drops
            // out for a frame or two; they are shown while fresh.
            autoNoWall = true
            return
        }
        autoNoWall = false
        lastOpeningResult = r
        var c = r.detection?.candidate
        // The one just added is still in view: don't offer it again.
        val ac = acceptedCentre
        if (c != null && ac != null && now - acceptedAt < ACCEPTED_IGNORE_MS) {
            val mid = Vec3((c.a.x + c.b.x) / 2f, (c.bottom + c.top) / 2f, (c.a.z + c.b.z) / 2f)
            if (len(mid - ac) < 0.2f) c = null
        }
        if (c != null) {
            val was = consensus.state?.stable == true && autoFresh(now)
            val st = consensus.add(wall.frame, c)
            lastAutoCandidateAt = now
            if (st.stable) {
                lastStable = st
                lastStableAt = now
            }
            if (st.stable && !was) {
                diag(
                    "opening auto: ${openingName()} stable ${sizeText(st.candidate.width, st.candidate.height)}" +
                        " (${wall.source}${if (st.candidate.estimated) ", estimated" else ""}, " +
                        String.format("strength %.1f", st.candidate.strength) + ")",
                )
            }
        }
        if (!autoStable() && now - lastOpeningDiagAt >= OPENING_DIAG_INTERVAL_MS) {
            lastOpeningDiagAt = now
            saveOpeningDiag(r, false)
        }
    }

    /** Centres of the doors / windows of [type] counted so far. */
    private fun openingCentres(type: Int) = openings.map {
        if (it.type != type) Vec3(Float.MAX_VALUE, 0f, Float.MAX_VALUE)
        else RoomOpeningCounter.centre(it.a, it.b, it.baseY, it.topY ?: (it.baseY + 1f))
    }

    /**
     * Room scan (Auto mode): a door / window attempt is back. Once the
     * detections of one hold steady, have a door's or window's proportions
     * and are not one already counted, it is added: the room's doors and
     * windows are counted as it is walked round, with no tap needed.
     */
    private fun onRoomOpeningResult(r: OpeningResult) {
        if (!roomOpeningScan || completing) return
        val wall = r.wall ?: return
        val c = r.detection?.candidate ?: return
        val consensus = roomConsensus.getValue(r.kind)
        val st = consensus.add(wall.frame, c)
        if (!st.stable) return
        val found = st.candidate
        val type = if (r.kind == OpeningKind.DOOR) TYPE_DOOR else TYPE_WINDOW
        val name = if (type == TYPE_DOOR) "Door" else "Window"
        // Counted without a tap, so only on firm ground: the floor known (a
        // window's sill and a door's foot are checked against it) and a size
        // a real one has. Small "windows" counted on a guessed floor were
        // posters and panels.
        val floorY = snapshot?.floorY
        if (floorY == null || found.width < ROOM_MIN_OPENING || found.height < ROOM_MIN_OPENING ||
            !RoomOpeningCounter.plausible(r.kind, found, floorY)
        ) {
            consensus.clear()
            return
        }
        val centre = RoomOpeningCounter.centre(found.a, found.b, found.bottom, found.top)
        // Already counted (as either kind: a glazed door must not count twice).
        if (RoomOpeningCounter.duplicateOf(centre, openingCentres(TYPE_DOOR)) >= 0 ||
            RoomOpeningCounter.duplicateOf(centre, openingCentres(TYPE_WINDOW)) >= 0
        ) {
            consensus.clear()
            return
        }
        openings.add(OpeningMark(type, found.a, found.b, found.topY, METHOD_AUTO, found.estimated))
        history.add(H_OPENING_AUTO)
        consensus.clear()
        diag(
            "room scan: ${name.lowercase()} counted automatically " +
                "${sizeText(found.width, found.height)} (${wall.source}${if (found.estimated) ", estimated" else ""}), " +
                (elementsSummary() ?: ""),
        )
        flash("$name found: ${if (found.estimated) "≈ " else ""}${sizeText(found.width, found.height)}  ·  ${elementsSummary()}")
        overlay.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
        overlay.invalidate()
    }

    /**
     * Mark button in Door / Window: adds the door / window found: the stable
     * result (or one that was stable a moment ago), else the detection so
     * far, flagged as approximate. With nothing detected it says where to
     * point. The scan goes on, so every door and window of the room can be
     * added (and counted); one already counted at the same spot is replaced
     * rather than counted twice. Finish ends the scan.
     */
    private fun acceptAutoOpening() {
        val now = SystemClock.uptimeMillis()
        val cur = consensus.state
        val held = lastStable
        var settled = true
        val adj = adjusted
        val st = when {
            // Adjusted by hand: exactly as the user left it.
            adj != null -> OpeningConsensus.State(adj.candidate(), adj.frame, true, 0, 0)
            cur != null && autoStable() -> cur
            held != null && now - lastStableAt <= STABLE_GRACE_MS -> held
            cur != null && now - lastAutoCandidateAt <= STABLE_GRACE_MS -> {
                settled = false
                cur
            }
            else -> null
        }
        if (st == null) {
            diag("opening auto: nothing detected on tap")
            flash(
                if (mode == Mode.DOOR) "No door found yet. Point at the middle of the door with the whole frame and the floor below it in view."
                else "No window found yet. Point at the middle of the window with the whole frame in view.",
            )
            markButton.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            return
        }
        val c = st.candidate
        val type = if (mode == Mode.DOOR) TYPE_DOOR else TYPE_WINDOW
        val est = c.estimated || !settled
        val o = OpeningMark(type, c.a, c.b, c.topY, METHOD_AUTO, est)
        // The same door / window counted already (e.g. found during the
        // room scan): this one, as accepted or adjusted, replaces it.
        val dup = RoomOpeningCounter.duplicateOf(
            RoomOpeningCounter.centre(c.a, c.b, c.bottom, c.top), openingCentres(type),
        )
        val replaced = dup >= 0
        if (replaced) {
            openings[dup] = o
        } else {
            openings.add(o)
            history.add(H_OPENING_AUTO)
        }
        val size = (if (est) "≈ " else "") + sizeText(c.width, c.height)
        diag(
            "${openingName()} ${openings.size} (auto, ${lastOpeningResult?.wall?.source}" +
                "${if (est) ", estimated" else ""}${if (settled) "" else ", not settled"}${if (adj != null) ", adjusted by hand" else ""}): $size" +
                (c.sill?.let { " sill ${m(it)}" } ?: "") + String.format(", strength %.1f", c.strength),
        )
        lastOpeningResult?.let { saveOpeningDiag(it, true) }
        acceptedCentre = Vec3((c.a.x + c.b.x) / 2f, (c.bottom + c.top) / 2f, (c.a.z + c.b.z) / 2f)
        acceptedAt = now
        resetAutoSearch()
        markButton.performHapticFeedback(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM
            else HapticFeedbackConstants.LONG_PRESS,
        )
        // The scan goes on: point at the next door / window, or tap Finish.
        flash(
            "${mode.label} ${if (replaced) "updated" else "added"}: $size  ·  ${elementsSummary()}" +
                if (settled) "" else ". The frame had not settled: check its size on the plan.",
        )
        overlay.invalidate()
    }

    /**
     * Mark button in Touch: the phone's position is taken. Tap 1 and 2 are
     * the sides (door: only x / z count) or the window's bottom corners, tap 3
     * any point on the top edge (its height is the top).
     */
    private fun markTouchOpening(snap: Snapshot) {
        val p = snap.camPos
        val first = pendingEdge
        val base = pendingOpening
        if ((first != null || base != null) && openingTouchTurned(snap)) {
            flash("Turn the phone back the way it was at the first point, then tap.")
            return
        }
        val name = mode.label.lowercase()
        when {
            base != null -> {
                val h = openingHeight(base, snap.floorY, p.y) ?: return
                if (h < 0.3f || h > 3.5f) {
                    flash(
                        if (h < 0.3f) "That point is only ${m(h)} above the base. Put the corner on the top of the $name."
                        else "That point is ${m(h)} above the base, too high. Put the corner on the top of the $name."
                    )
                    return
                }
                val done = OpeningMark(base.type, base.a, base.b, p.y, METHOD_TOUCH, base.estimated, base.rawA)
                openings.add(done)
                pendingOpening = null
                history.add(H_OPENING_TOP)
                diag("$name ${openings.size} (touch${if (done.estimated) ", estimated" else ""}): ${sizeText(done.width, h)}")
                flash("${mode.label} added: ${if (done.estimated) "≈ " else ""}${sizeText(done.width, h)}")
            }
            first == null -> {
                pendingEdge = p
                touchForward = snap.camForward
                touchUp = snap.camUp
                history.add(H_EDGE)
                flash(if (mode == Mode.DOOR) "Left side marked" else "Bottom-left corner marked")
            }
            else -> {
                val w = first.dist2d(p)
                if (w < 0.3f || w > 6f) {
                    flash("That opening would be ${m(w)} wide. Move to the other side.")
                    return
                }
                val type = if (mode == Mode.DOOR) TYPE_DOOR else TYPE_WINDOW
                // The base is where the phone was at these two taps (at the
                // floor for a door, at the sill for a window), not the
                // detected floor: the camera sits a few cm from the phone's
                // corner, and measured from the same phone position at both
                // ends that offset cancels out.
                val bottom = (first.y + p.y) / 2f
                val est = false
                pendingOpening = OpeningMark(type, first.withY(bottom), p.withY(bottom), null, METHOD_TOUCH, est, first)
                pendingEdge = null
                history.add(H_OPENING_BASE)
                flash("Width ${m(w)}. Now the top.")
            }
        }
        markButton.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
        overlay.invalidate()
    }

    private fun autoInstruction(): String {
        val name = openingName()
        val now = SystemClock.uptimeMillis()
        return when {
            adjusted != null -> "Drag a side's circle (or its line) onto the $name's frame: only that side moves. Then tap ✓. Undo goes back to automatic."
            autoNoWall -> "Point at the wall around the $name so it can be found."
            autoStable() -> "${mode.label} found. Tap ✓ to add it."
            autoFresh(now) -> "Hold still…"
            now - max(lastAutoCandidateAt, autoSearchSince) >= AUTO_GIVE_UP_MS ->
                "Can't find the frame edges. Step back so the whole frame is in view."
            mode == Mode.DOOR -> "Point at the middle of the door. Keep the whole frame and the floor below it in view."
            else -> "Point at the middle of the window. Keep the whole window frame, and the bottom of the wall below it if you can, in view."
        }
    }

    private fun touchOpeningInstruction(snap: Snapshot): String {
        if (openingTouchTurned(snap)) {
            return "The phone has been turned. Turn it back the way it was at the first point, then put the SAME corner on the frame."
        }
        val door = mode == Mode.DOOR
        val where = when {
            pendingOpening != null -> if (door) "the top of the frame" else "the top edge of the window"
            pendingEdge != null -> if (door) "the floor at the right side of the door frame" else "the bottom-right corner of the window"
            else -> if (door) "the floor at the left side of the door frame" else "the bottom-left corner of the window"
        }
        val keep = if (pendingEdge != null || pendingOpening != null) " Don't turn the phone; use the same corner." else ""
        return "Put one corner of the phone on $where and tap. Don't cover the camera.$keep"
    }

    /**
     * Debug builds: the rectified image of [r] as a PNG with a JSON sidecar
     * (wall, region, candidate, edge profiles) in the scans folder, for
     * tuning. The newest [OPENING_DIAG_KEEP] are kept. Background thread;
     * failures are ignored.
     */
    private fun saveOpeningDiag(r: OpeningResult, accepted: Boolean) {
        if (!isDebuggable()) return
        val dir = diagDir() ?: return
        val img = r.image ?: return
        val wall = r.wall ?: return
        val det = r.detection
        try {
            openingExecutor.execute {
                try {
                    val stamp = System.currentTimeMillis()
                    File(dir, "opening_$stamp.png").writeBytes(OpeningDetector.grayPng(img))
                    fun num(v: Float) = if (v.isNaN() || v.isInfinite()) 0.0 else Math.round(v * 1000.0) / 1000.0
                    fun vec(v: Vec3) = org.json.JSONArray().put(num(v.x)).put(num(v.y)).put(num(v.z))
                    fun arr(a: FloatArray) = org.json.JSONArray().also { j -> a.forEach { j.put(num(it)) } }
                    val f = wall.frame
                    val c = det?.candidate
                    val json = org.json.JSONObject()
                        .put("kind", r.kind.name.lowercase())
                        .put("accepted", accepted)
                        .put("wallSource", wall.source)
                        .put("estimated", f.estimated)
                        .put("floorY", f.floorY?.let { num(it) } ?: org.json.JSONObject.NULL)
                        .put("origin", vec(f.origin))
                        .put("normal", vec(f.normal))
                        .put(
                            "region",
                            org.json.JSONObject().put("u0", num(img.u0)).put("u1", num(img.u1))
                                .put("v0", num(img.v0)).put("v1", num(img.v1)),
                        )
                        .put(
                            "candidate",
                            if (c == null) org.json.JSONObject.NULL
                            else org.json.JSONObject().put("left", num(c.left)).put("right", num(c.right))
                                .put("bottom", num(c.bottom)).put("top", num(c.top)).put("strength", num(c.strength)),
                        )
                        .put("columnProfile", arr(det?.columnProfile ?: FloatArray(0)))
                        .put("rowProfile", arr(det?.rowProfile ?: FloatArray(0)))
                    File(dir, "opening_$stamp.json").writeText(json.toString())
                    dir.listFiles()?.filter { it.name.startsWith("opening_") }
                        ?.groupBy { it.nameWithoutExtension }?.keys?.sortedDescending()?.drop(OPENING_DIAG_KEEP)
                        ?.forEach { stem -> File(dir, "$stem.png").delete(); File(dir, "$stem.json").delete() }
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun instruction(snap: Snapshot?): String {
        if (snap != null && !snap.tracking && (touchLine() || touchOpening())) {
            return "Tracking lost. Keep the camera's view clear and move slowly."
        }
        if (snap == null || !snap.tracking) {
            return snap?.let { trackingHint(it.failure) } ?: "Starting camera..."
        }
        // Auto and Touch find doors and windows without the floor (it is
        // used when known).
        if (snap.floorY == null && mode != Mode.AUTO && mode != Mode.LINE && !autoOpening() && !touchOpening()) {
            return "Point the camera at the floor and move the phone slowly from side to side until the floor is highlighted."
        }
        if (autoOpening()) return autoInstruction()
        if (touchOpening()) return touchOpeningInstruction(snap)
        return when (mode) {
            Mode.AUTO -> {
                val room = snap.autoRoom
                when {
                    // Looked around without moving: not said once every wall
                    // is measured anyway.
                    snap.sectorCount >= 4 && snap.moveExtent < 0.4f && (room == null || room.estimatedCount > 0) ->
                        "Walls aren't measured by turning on the spot: walk slowly along them with the phone facing them. " +
                            "Or tap Corners to mark each corner from where you stand."
                    snap.wallCount == 0 && room == null ->
                        "Walk slowly around the room, about 1–2 m from the walls, with the phone facing the wall. Keep the floor's edge in view. Doors and windows in view are counted automatically."
                    room == null ->
                        "Keep walking along the walls. The outline appears once enough of them are measured."
                    room.estimatedCount > 0 ->
                        "Room found. ${room.estimatedCount} dashed side${if (room.estimatedCount == 1) " is" else "s are"} estimated. Point the camera at ${if (room.estimatedCount == 1) "that wall" else "those walls"} to measure ${if (room.estimatedCount == 1) "it" else "them"}, or tap Finish."
                    else -> "All walls found${elementsSummary()?.let { " ($it)" } ?: ""}. Tap Finish, or point at any door or window not counted yet."
                }
            }
            Mode.CORNER -> when (corners.size) {
                0 -> "Aim the crosshair where two walls meet the floor, then tap the button to mark the first corner."
                1, 2 -> "Aim at the next corner, going round the room in order, and mark it. You can stay where you are."
                else -> "Mark the next corner. To close the room, aim at the first corner or tap Finish."
            }
            Mode.DOOR -> when {
                pendingOpening != null ->
                    "Step 3 of 3: aim at the top of the door frame and tap the button to set the height."
                pendingEdge != null ->
                    "Step 2 of 3: aim at the other side of the door frame at floor level and tap the button."
                else -> "Step 1 of 3: aim at one side of the door frame at floor level and tap the button."
            }
            Mode.WINDOW -> when {
                pendingOpening != null ->
                    "Step 3 of 3: aim at the top edge of the window and tap the button to set the height."
                pendingEdge != null ->
                    "Step 2 of 3: aim at the bottom-right corner of the window, on the sill, and tap the button."
                else -> "Step 1 of 3: aim at the bottom-left corner of the window, on the sill, and tap the button."
            }
            Mode.SURFACE -> when (pendingSurface.size) {
                0 -> "Step 1 of 3: aim at a corner of the surface (wall section, worktop, cabinet front, floor area) and tap the button."
                1 -> "Step 2 of 3: aim at the next corner along one edge and tap the button."
                else -> "Step 3 of 3: aim at any point on the opposite edge and tap the button."
            }
            Mode.LINE ->
                if (lineMethod == LineMethod.TOUCH) {
                    if (pendingLine == null) "Put one corner of the phone on the first point and tap the button. Don't cover the camera."
                    else if (touchTurned(snap)) "The phone has been turned. Turn it back the way it was at the first point, then put the SAME corner on the second point."
                    else "Slide the phone to the second point WITHOUT turning it, with the SAME corner on the point (not the other side of the phone), and tap."
                } else if (pendingLine == null) "Tap the first point on the screen, or aim the crosshair at it and press the button."
                else "Tap the second point. The distance updates as you move."
        }
    }

    private fun trackingHint(reason: TrackingFailureReason) = when (reason) {
        TrackingFailureReason.INSUFFICIENT_LIGHT -> "It's too dark. Turn on more lights."
        TrackingFailureReason.EXCESSIVE_MOTION -> "Moving too fast. Slow down."
        TrackingFailureReason.INSUFFICIENT_FEATURES -> "Point the camera at an area with more detail."
        TrackingFailureReason.CAMERA_UNAVAILABLE -> "Camera unavailable."
        TrackingFailureReason.NONE -> "Move the phone slowly from side to side to start measuring."
        else -> "Move the phone slowly to start tracking."
    }

    // ------------------------------------------------------------ UI thread

    private fun onFrame() {
        snapshot?.let { s -> aimSmoother.add(SystemClock.uptimeMillis(), s.hit?.takeIf { s.tracking }) }
        snapshot?.let { s ->
            if (s.tracking != lastTrackingLogged) {
                lastTrackingLogged = s.tracking
                diag(if (s.tracking) "tracking" else "tracking lost: ${s.failure}")
            }
            val room = s.autoRoom
            val measured = room?.let { it.corners.size - it.estimatedCount } ?: -1
            if (s.tracking && (s.sectorCount != loggedSectors || measured != loggedWalls)) {
                loggedSectors = s.sectorCount
                loggedWalls = measured
                diag(
                    "progress: " + (room?.let { "$measured/${it.corners.size} walls" } ?: "no room") +
                        ", ${s.sectorCount}/$SECTORS sectors, extent " + String.format("%.1f m", s.moveExtent),
                )
            }
        }
        // A touch ends when its mode does (mode tab, method, undo, start over).
        if (tapLine()) resolveTap() else if (tapShown() || tapRequest != null) clearTap()
        refreshUi()
        overlay.invalidate()
    }

    private fun onMark() {
        val snap = snapshot ?: return
        if (!snap.tracking) return
        if (autoOpening()) {
            acceptAutoOpening()
            return
        }
        if (touchOpening()) {
            markTouchOpening(snap)
            return
        }
        // Touch: the phone's own position is the point, no surface needed.
        val aim = if (touchLine()) Aim(snap.camPos, false, false) else resolveAim(snap)
        if (touchLine()) {
            if (pendingLine == null) {
                touchForward = snap.camForward
                touchUp = snap.camUp
            } else if (touchTurned(snap)) {
                // A turned phone moves its corner without moving the camera
                // the same way: the result would be off by up to the phone's
                // size.
                flash("Turn the phone back the way it was at the first point, then tap.")
                return
            }
        }
        if (aim == null) {
            flash("Can't measure that spot. Aim at the floor or a highlighted wall.")
            return
        }
        when (mode) {
            Mode.AUTO -> return
            Mode.CORNER -> {
                if (aim.closesRoom) {
                    onDone()
                    return
                }
                val last = corners.lastOrNull()
                if (last != null && last.dist2d(aim.p) < 0.1f) {
                    flash("That is the same corner. Aim at the next one.")
                    return
                }
                corners.add(aim.p)
                history.add(H_CORNER)
                flash(
                    if (last != null) "Wall ${corners.size - 1}: ${m(last.dist2d(aim.p))}"
                    else "First corner marked"
                )
            }
            Mode.DOOR, Mode.WINDOW -> {
                val first = pendingEdge
                val base = pendingOpening
                if (base != null) {
                    val h = aim.p.y - base.baseY
                    if (h < 0.3f || h > 3.5f) {
                        flash(
                            if (h < 0.3f) "That point is only ${m(h)} above the base. Aim at the top of the ${mode.label.lowercase()}."
                            else "That point is ${m(h)} above the base, too high. Aim at the top of the ${mode.label.lowercase()}."
                        )
                        return
                    }
                    val done = OpeningMark(base.type, base.a, base.b, aim.p.y)
                    openings.add(done)
                    pendingOpening = null
                    history.add(H_OPENING_TOP)
                    flash("${mode.label} added: ${sizeText(done.width, openingHeight(done, snap.floorY))}")
                } else if (first == null) {
                    pendingEdge = aim.p
                    history.add(H_EDGE)
                    flash("First side marked")
                } else {
                    val w = first.dist2d(aim.p)
                    if (w < 0.3f || w > 6f) {
                        flash("That opening would be ${m(w)} wide. Aim at the other edge.")
                        return
                    }
                    val type = if (mode == Mode.DOOR) TYPE_DOOR else TYPE_WINDOW
                    pendingOpening = OpeningMark(type, first, aim.p)
                    pendingEdge = null
                    history.add(H_OPENING_BASE)
                    flash("Width ${m(w)}. Now mark the top.")
                }
            }
            Mode.SURFACE -> {
                when (pendingSurface.size) {
                    0 -> flash("First corner marked")
                    1 -> {
                        val w = len(aim.p - pendingSurface[0])
                        if (w < 0.1f) {
                            flash("That is the same corner. Aim at the next corner along the edge.")
                            return
                        }
                        flash("Edge ${m(w)}. Now mark a point on the opposite edge.")
                    }
                    else -> {
                        val s = SurfaceMark(pendingSurface[0], pendingSurface[1], aim.p)
                        if (s.height < 0.1f) {
                            flash("That point is on the first edge. Aim at the opposite edge.")
                            return
                        }
                        surfaces.add(s)
                        pendingSurface.clear()
                        history.add(H_SURFACE)
                        flash("Surface added: ${sizeText(s.width, s.height)}  ·  ${area2(s.width * s.height)}")
                        markButton.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                        overlay.invalidate()
                        return
                    }
                }
                pendingSurface.add(aim.p)
                history.add(H_SURFACE_POINT)
            }
            Mode.LINE -> {
                // The phone's own position is measured, never estimated.
                val touch = lineMethod == LineMethod.TOUCH
                if (!placeLinePoint(aim.p, !touch && snap.hitEstimated, if (touch) "touch" else "aim")) return
            }
        }
        markButton.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
        overlay.invalidate()
    }

    private fun onUndo() {
        cancelAutoComplete("undo")
        if (adjusted != null) {
            // First undo drops the hand adjustment: the frame follows the
            // detections again.
            adjusted = null
            adjustGrab = -1
            flash("Back to automatic")
            overlay.invalidate()
            return
        }
        when (history.removeLastOrNull()) {
            H_CORNER -> corners.removeAt(corners.lastIndex)
            H_EDGE -> pendingEdge = null
            H_OPENING_BASE -> {
                pendingEdge = pendingOpening?.let { it.rawA ?: it.a }
                pendingOpening = null
            }
            H_OPENING_TOP -> {
                // Back to waiting for the top, in the mode that marks it (the
                // user may have switched modes since).
                val o = openings.removeAt(openings.lastIndex)
                pendingOpening = OpeningMark(o.type, o.a, o.b, null, o.method, o.estimated, o.rawA)
                switchModeQuietly(if (o.type == TYPE_DOOR) Mode.DOOR else Mode.WINDOW)
            }
            H_OPENING, H_OPENING_AUTO -> openings.removeAt(openings.lastIndex)
            H_SURFACE_POINT -> pendingSurface.removeAt(pendingSurface.lastIndex)
            H_SURFACE -> {
                val s = surfaces.removeAt(surfaces.lastIndex)
                pendingSurface.clear()
                pendingSurface.addAll(listOf(s.a, s.b))
                switchModeQuietly(Mode.SURFACE)
            }
            H_LINE_POINT -> pendingLine = null
            H_LINE -> {
                // Back to waiting for the second end, in Line mode.
                val l = lines.removeAt(lines.lastIndex)
                pendingLine = l.a
                pendingLineEstimated = l.aEstimated
                switchModeQuietly(Mode.LINE)
            }
            else -> return
        }
        flash("Undone")
        overlay.invalidate()
    }

    /** Mode change made by undo: none of the side effects of [onMode]. */
    private fun switchModeQuietly(m: Mode) {
        if (m == mode) return
        cancelAutoComplete("mode ${m.label}")
        mode = m
        diag("mode ${m.label} (undo)")
        refreshUi()
    }

    /**
     * A door or window with both sides marked but no top yet is kept without
     * a height (its width is still useful); a lone first point is dropped.
     * Its tap-by-tap undo steps collapse into one, which removes it.
     */
    private fun commitPendingOpening() {
        val o = pendingOpening ?: return
        openings.add(o)
        pendingOpening = null
        if (history.lastOrNull() == H_OPENING_BASE) history.removeAt(history.lastIndex)
        if (history.lastOrNull() == H_EDGE) history.removeAt(history.lastIndex)
        history.add(H_OPENING)
        diag("opening committed without height, ${m(o.width)} wide")
    }

    private fun onMode(m: Mode) {
        if (m == mode) return
        cancelAutoComplete("mode ${m.label}")
        if (m == Mode.CORNER) cornersChosen = true
        commitPendingOpening()
        if (pendingEdge != null) {
            pendingEdge = null
            if (history.lastOrNull() == H_EDGE) history.removeAt(history.lastIndex)
        }
        if (pendingSurface.isNotEmpty()) {
            pendingSurface.clear()
            while (history.lastOrNull() == H_SURFACE_POINT) history.removeAt(history.lastIndex)
        }
        dropPendingLine()
        mode = m
        diag("mode ${m.label}")
        flashMessage = null
        // Auto and Corners each measure the outline from scratch: switching
        // between them drops the other one's result.
        if (m == Mode.CORNER && !manualOutline) {
            manualOutline = true
            flash("Mark the room's corners. The automatic outline is no longer used.")
        } else if (m == Mode.AUTO && manualOutline) {
            manualOutline = false
            val had = corners.isNotEmpty()
            corners.clear()
            history.removeAll { it == H_CORNER }
            flash(if (had) "Marked corners cleared. Measuring the room automatically." else "Measuring the room automatically.")
        }
        refreshUi()
        overlay.invalidate()
    }

    private fun onReset() {
        cancelAutoComplete("start over")
        val hasData = corners.isNotEmpty() || openings.isNotEmpty() ||
            pendingOpening != null || surfaces.isNotEmpty() || lines.isNotEmpty() || pendingLine != null ||
            snapshot?.autoRoom != null || photos.isNotEmpty()
        if (!hasData) {
            resetScan()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Start over?")
            .setMessage("This clears the room outline, every door, window, surface and line measured and the photos taken, and scans the room again.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Start over") { _, _ -> resetScan() }
            .show()
    }

    /**
     * Clears every measurement and starts a new ARCore session (ARCore can't
     * forget the surfaces it found), so the room is scanned again from
     * scratch.
     */
    private fun resetScan() {
        scanGeneration++
        furniture.clear()
        // Stop the GL thread before touching its state.
        glView.onPause()
        session?.let {
            it.pause()
            it.close()
        }
        session = null
        textureSet = false
        glFloorY = null
        glCeilingY = null
        glPointFloorY = null
        glAutoRoom = null
        cloud.clear()
        depthVoxels.clear()
        depthDots = emptyList()
        camSumX = 0.0
        camSumY = 0.0
        camSumZ = 0.0
        camSamples = 0
        glSectors = 0
        glMinX = Float.MAX_VALUE
        glMaxX = -Float.MAX_VALUE
        glMinZ = Float.MAX_VALUE
        glMaxZ = -Float.MAX_VALUE
        loggedSectors = -1
        loggedWalls = -1
        snapshot = null
        corners.clear()
        openings.clear()
        pendingEdge = null
        pendingOpening = null
        autoOpeningKind = null
        autoKindShown = null
        lastWallSource = null
        acceptedCentre = null
        resetAutoSearch()
        roomConsensus.values.forEach { it.clear() }
        surfaces.clear()
        pendingSurface.clear()
        lines.clear()
        pendingLine = null
        clearTap()
        tapMissUntil = 0L
        history.clear()
        captureRequested = false
        deletePhotos()
        manualOutline = false
        mode = if (lineOnly) Mode.LINE else Mode.AUTO
        cancelAutoComplete(null)
        cornersChosen = false
        stableSince = 0L
        stableCorners = -1
        diag("scan reset")
        resumeSession()
        flash(if (lineOnly) "Starting over. Mark the first point." else "Starting over. Walk slowly along the walls.")
        overlay.invalidate()
    }

    /**
     * Finishes the scan with everything measured. [focusOpening]: index in
     * [openings] of the door / window just added with ✓, which the app shows
     * first.
     */
    private fun onDone(focusOpening: Int? = null, confirmed: Boolean = false) {
        // Finish tapped while the checkmark shows: finish once, now.
        handler.removeCallbacks(autoFinish)
        val snap = snapshot
        val auto = snap?.autoRoom
        // An automatic outline that is mostly guesswork (half its sides or
        // more estimated) is not saved without asking: plain walls the
        // camera can't measure gave rooms like 4.6 × 0.9 m. Marking the
        // corners works there.
        val noWalls = snap != null && snap.wallCount == 0
        if (!confirmed && !lineOnly && useAutoRoom() && auto != null && (mostlyEstimated(auto) || noWalls)) {
            if (weakFinishDialog?.isShowing == true) return
            val measured = (auto.corners.size - auto.estimatedCount).coerceAtLeast(0)
            diag("finish: outline unreliable (estimated ${auto.estimatedCount} of ${auto.corners.size}, walls ${snap?.wallCount}), asking")
            val why = if (mostlyEstimated(auto)) {
                "Only $measured of ${auto.corners.size} walls were measured; the rest of this outline is a guess"
            } else {
                "No wall was measured directly; this outline only comes from the edges of the floor and ceiling"
            }
            weakFinishDialog = AlertDialog.Builder(this)
                .setTitle("Room not measured yet")
                .setMessage(
                    "$why, so its size is probably wrong.\n\nPlain walls are hard for the camera. Mark the " +
                        "corners instead: stand in the room, aim at each corner where the walls meet the floor " +
                        "and tap +.",
                )
                .setPositiveButton("Mark corners") { _, _ -> onMode(Mode.CORNER) }
                .setNeutralButton("Save anyway") { _, _ -> onDone(focusOpening, confirmed = true) }
                .setNegativeButton("Keep scanning", null)
                .show()
            return
        }
        // Measuring distances only: no outline is needed, none is returned.
        // The result holds distances only, no room: asked for at the start,
        // or lines were measured in a normal scan before any room outline
        // existed.
        var linesOnly = lineOnly
        // No room outline is returned (lines only, or only doors / windows).
        var noOutline = lineOnly
        val outline: List<Vec3> = when {
            lineOnly -> {
                if (lines.isEmpty()) {
                    flash("Measure at least one line first.")
                    return
                }
                emptyList()
            }
            !useAutoRoom() && corners.size >= 3 -> corners
            useAutoRoom() && auto != null -> auto.corners
            lines.isNotEmpty() -> {
                linesOnly = true
                noOutline = true
                emptyList()
            }
            // Doors / windows measured without a room outline: returned on
            // their own, with everything else measured.
            openings.isNotEmpty() || pendingOpening != null -> {
                noOutline = true
                emptyList()
            }
            !useAutoRoom() -> {
                flash("Mark at least 3 corners, or switch to Auto.")
                return
            }
            else -> {
                diag("finish tapped, but no room found yet")
                flash("No room found yet. Keep walking along the walls, or mark the corners by hand.")
                return
            }
        }
        // A door or window still waiting for its top is returned without a
        // height rather than lost.
        commitPendingOpening()
        dropPendingLine()
        val autoOutline = !noOutline && useAutoRoom()
        diag(
            "finish: " + (if (linesOnly) "lines only, no" else if (noOutline) "no" else if (autoOutline) "auto" else "manual") +
                " outline " +
                outline.joinToString(" ") { String.format("(%.2f,%.2f)", it.x, it.z) } +
                (auto?.takeIf { autoOutline }?.let {
                    String.format(" %.2f x %.2f m, estimated sides %d", it.width, it.depth, it.estimatedCount)
                } ?: "") + ", openings ${openings.size}, surfaces ${surfaces.size}, lines ${lines.size}",
        )
        fun d(v: Float) = v.toDouble()
        val data = Intent()
            .putExtra(EXTRA_XS, outline.map { it.x.toDouble() }.toDoubleArray())
            .putExtra(EXTRA_ZS, outline.map { it.z.toDouble() }.toDoubleArray())
            .putExtra(EXTRA_AUTO, autoOutline)
            .putExtra(EXTRA_ESTIMATED, if (autoOutline) auto?.estimatedCount ?: 0 else 0)
            .putExtra(
                EXTRA_OPENINGS,
                openings.flatMap {
                    listOf(it.type.toDouble(), it.a.x.toDouble(), it.a.z.toDouble(), it.b.x.toDouble(), it.b.z.toDouble())
                }.toDoubleArray(),
            )
            .putExtra(
                EXTRA_OPENING_DETAILS,
                openings.flatMap {
                    listOf(
                        it.type.toDouble(), d(it.a.x), d(it.a.y), d(it.a.z), d(it.b.x), d(it.b.y), d(it.b.z),
                        it.topY?.let(::d) ?: NO_TOP,
                    )
                }.toDoubleArray(),
            )
            .putExtra(
                EXTRA_SURFACES,
                surfaces.flatMap { s -> listOf(s.a, s.b, s.c).flatMap { listOf(d(it.x), d(it.y), d(it.z)) } }
                    .toDoubleArray(),
            )
            .putExtra(
                EXTRA_LINES,
                lines.flatMap { l -> listOf(l.a, l.b).flatMap { listOf(d(it.x), d(it.y), d(it.z)) } }.toDoubleArray(),
            )
            .putExtra(EXTRA_LINES_ESTIMATED, lines.map { if (it.estimated) 1 else 0 }.toIntArray())
            .putExtra(EXTRA_OPENING_METHODS, openings.map { it.method }.toIntArray())
            .putExtra(EXTRA_OPENING_ESTIMATED, openings.map { if (it.estimated) 1 else 0 }.toIntArray())
            .putExtra(EXTRA_LINE_ONLY, linesOnly)
        data.putExtra(EXTRA_PHOTOS, photos.toTypedArray())
        if (!linesOnly) {
            val found = furniture.confirmed()
            data.putExtra(
                EXTRA_ELEMENTS,
                found.flatMap {
                    listOf(d(it.center.x), d(it.center.z), d(it.width), d(it.depth), d(it.height), d(it.yaw))
                }.toDoubleArray(),
            )
            data.putExtra(EXTRA_ELEMENT_KINDS, found.map { it.kind }.toTypedArray())
        }
        snap?.floorY?.let { data.putExtra(EXTRA_FLOOR_Y, it.toDouble()) }
        focusOpening?.takeIf { it in openings.indices }?.let {
            diag("finish: focus on opening $it")
            data.putExtra(EXTRA_FOCUS_OPENING, it)
        }
        setResult(RESULT_OK, data)
        finish()
    }

    // ------------------------------------------------------------ AR photo

    private fun onPhoto() {
        val snap = snapshot
        if (snap == null || !snap.tracking) {
            flash("Wait for tracking, then take the photo.")
            return
        }
        if (lineOnly) {
            // No room outline is needed for a photo of measured lines.
            if (!captureRequested) captureRequested = true
            return
        }
        if (useAutoRoom() && snap.autoRoom == null) {
            flash("Keep panning across the walls until the room outline appears, then take the photo.")
            return
        }
        if (!useAutoRoom() && corners.size < 3) {
            flash("Mark at least 3 corners first.")
            return
        }
        if (captureRequested) return
        captureRequested = true
    }

    /** Draws the measurements over the captured camera image and saves it. */
    private fun onPhotoCaptured(raw: Bitmap, snap: Snapshot) {
        if (isFinishing || isDestroyed) return
        val w = overlay.width
        val h = overlay.height
        val photo = try {
            if (w > 0 && h > 0 && (raw.width != w || raw.height != h)) {
                Bitmap.createScaledBitmap(raw, w, h, true)
            } else {
                raw.copy(Bitmap.Config.ARGB_8888, true)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "photo compose failed", e)
            flash("Could not take the photo. Try again.")
            return
        }
        if (photo !== raw) raw.recycle()
        val pw = photo.width
        val ph = photo.height
        val canvas = Canvas(photo)
        overlay.drawForPhoto(canvas, snap)
        photoCaption(snap).takeIf { it.isNotEmpty() }?.let { drawCaption(canvas, pw, ph, it) }

        val file = File(cacheDir, "photos/room_photo_${System.currentTimeMillis()}.jpg")
        val ok = try {
            file.parentFile?.mkdirs()
            file.outputStream().use { photo.compress(Bitmap.CompressFormat.JPEG, 88, it) }
        } catch (e: Exception) {
            Log.w(TAG, "photo save failed", e)
            false
        } finally {
            photo.recycle()
        }
        if (!ok) {
            file.delete()
            flash("Could not save the photo.")
            return
        }
        photos.add(file.absolutePath)
        overlay.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
        flash("Photo saved with measurements (${photos.size})")
        diag("photo ${photos.size} saved: ${file.name} (${pw}x$ph)")
    }

    /** The room's numbers for the photo caption, as in the stats line. */
    private fun photoCaption(snap: Snapshot): String {
        if (lineOnly) {
            return when {
                lines.isEmpty() -> ""
                lines.size <= 3 -> linesSummary()
                else -> "${lines.size} lines"
            }
        }
        val sep = "  ·  "
        val parts = mutableListOf<String>()
        val auto = snap.autoRoom
        if (useAutoRoom() && auto != null) {
            parts.add(String.format("%.2f × %.2f m", auto.width, auto.depth))
            parts.add("Area ${area2(auto.area)}")
        } else {
            parts.add("Area ${area2(area())}")
            parts.add("Perimeter ${m(perimeter())}")
        }
        return parts.joinToString(sep)
    }

    private fun drawCaption(canvas: Canvas, w: Int, h: Int, text: String) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            typeface = fontSemiBold
            fontFeatureSettings = "tnum"
            textAlign = Paint.Align.CENTER
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 16f, resources.displayMetrics)
        }
        val margin = dp(16f)
        val padX = dp(16f)
        val maxText = w - 2 * margin - 2 * padX
        val tw = paint.measureText(text)
        if (tw > maxText && maxText > 0) paint.textSize *= maxText / tw
        val textW = paint.measureText(text)
        val fm = paint.fontMetrics
        val boxH = (fm.descent - fm.ascent) + dp(20f)
        val bottom = h - margin - insets[3]
        val left = (w - textW) / 2 - padX
        val right = (w + textW) / 2 + padX
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = PANEL }
        canvas.drawRoundRect(left, bottom - boxH, right, bottom, boxH / 2, boxH / 2, bg)
        val baseline = bottom - boxH / 2 - (fm.ascent + fm.descent) / 2
        canvas.drawText(text, w / 2f, baseline, paint)
    }

    private fun refreshUi() {
        val snap = snapshot
        val tracking = snap?.tracking == true

        val now = SystemClock.uptimeMillis()
        if (completing && !tracking) cancelAutoComplete("tracking lost")
        val autoReady = checkAutoComplete(snap, now)
        val room = snap?.autoRoom
        val status = when {
            !tracking -> "Initializing"
            completing -> "Room scanned ✓"
            mode == Mode.AUTO && autoReady -> "All walls found  ·  hold steady…"
            mode == Mode.AUTO && room != null && room.corners.size >= 4 && room.estimatedCount == 0 &&
                !lookedRound(snap) -> {
                val around = (snap.sectorCount * 100f / SECTORS / 5f).roundToInt() * 5
                "All walls found  ·  turn round for doors & windows  ·  $around%"
            }
            // Auto-finish is off (card tapped away, or Corners was used).
            mode == Mode.AUTO && room != null && room.corners.size >= 4 && room.estimatedCount == 0 ->
                "All walls found  ·  tap Finish"
            mode == Mode.AUTO -> {
                val around = (snap.sectorCount * 100f / SECTORS / 5f).roundToInt() * 5
                if (room == null) "Scanning  ·  $around% around"
                else {
                    val total = room.corners.size
                    "Scanning  ·  ${total - room.estimatedCount} of $total walls  ·  $around% around"
                }
            }
            mode == Mode.LINE -> "Distance  ·  ${lines.size} line${if (lines.size == 1) "" else "s"}"
            snap?.floorY == null && snap?.autoRoom != null -> "Room found  ·  tilt down to the floor"
            snap?.floorY == null -> "Scanning  ·  include some floor"
            else -> {
                val w = snap.wallCount
                val c = snap.cornerCandidates.size
                "Floor ✓  ·  $w wall${if (w == 1) "" else "s"}  ·  $c corner${if (c == 1) "" else "s"} found"
            }
        }
        setIfChanged(statusText, status)

        val msg = flashMessage?.takeIf { now < flashUntil } ?: instruction(snap)
        setIfChanged(hintText, msg)

        val auto = snap?.autoRoom
        setIfChanged(statsText, statsLine(auto))

        syncAutoOpening()
        setEnabled(
            markButton,
            when {
                // Door / Window: the button always responds while tracking
                // (it says why when it can't use the tap), so a tap is never
                // silently ignored.
                openingMode() -> tracking
                else -> mode != Mode.AUTO && tracking && (touchLine() || touchOpening() || snap?.hit != null)
            },
        )
        setIfChanged(markGlyph, if (autoOpening()) "✓" else "+")
        // Door / Window: the disc turns teal (white ✓) while a found frame is
        // steady and ready to add.
        val markReady = autoOpening() && (autoStable() || adjusted != null)
        if (markReadyShown != markReady) {
            markReadyShown = markReady
            markDisc.background = circle(if (markReady) SNAP else Color.WHITE)
            markGlyph.setTextColor(if (markReady) Color.WHITE else INK)
        }
        val methodVisibility = if (mode == Mode.LINE) View.VISIBLE else View.GONE
        if (methodBox.visibility != methodVisibility) methodBox.visibility = methodVisibility
        if (methodShown != lineMethod) {
            methodShown = lineMethod
            for ((md, tv) in methodTabs) {
                val on = md == lineMethod
                tv.background = if (on) rounded(Color.WHITE, dp(18f)) else null
                tv.setTextColor(if (on) INK else TAB_IDLE)
            }
        }
        setEnabled(undoButton, history.isNotEmpty() || adjusted != null)
        val canFinish =
            // A measured line, door or window can be finished with on its
            // own, without a room outline.
            lines.isNotEmpty() || (!lineOnly && (openings.isNotEmpty() || pendingOpening != null ||
                (if (useAutoRoom()) auto != null else corners.size >= 3)))
        setEnabled(doneButton, canFinish)
        if (doneShown != canFinish) {
            doneShown = canFinish
            doneCircle.background =
                if (canFinish) circle(ACCENT) else circle(INK2, HAIRLINE, 1f)
        }
        if (tabsMode != mode) {
            tabsMode = mode
            for ((md, tv) in modeTabs) {
                val on = md == mode
                tv.background = if (on) rounded(Color.WHITE, dp(18f)) else null
                tv.setTextColor(if (on) INK else TAB_IDLE)
            }
            // After layout, so it also works for the first refresh.
            tabScroll.post { scrollToSelectedTab(true) }
        }
    }

    /** Scrolls the mode row so the selected tab is in view (centred when the
     *  row is wider than the panel). */
    private fun scrollToSelectedTab(smooth: Boolean) {
        val tv = modeTabs[mode] ?: return
        val room = tabScroll.width - tabScroll.paddingLeft - tabScroll.paddingRight
        if (room <= 0) return
        val x = (tv.left - (room - tv.width) / 2).coerceAtLeast(0)
        if (smooth) tabScroll.smoothScrollTo(x, 0) else tabScroll.scrollTo(x, 0)
    }

    private var tabsMode: Mode? = null

    /**
     * Auto-completion check, run with every UI refresh. Returns true when
     * every wall is measured and only the steadiness wait is left (for the
     * status line), and shows the checkmark once one of these holds:
     *  a. every wall measured, floor known, steady for [AUTO_STABLE_MS];
     *  b. every wall measured, floor not known, steady for
     *     [AUTO_STABLE_NO_FLOOR_MS] (finishes without a height rather than never);
     *  c. the user has been all the way round (nearly every direction looked
     *     in, and actually moved), at most one side (two with more than four
     *     corners) is still estimated and nothing changed for
     *     [AUTO_STABLE_ROUND_MS]; the result stays flagged as estimated.
     */
    private fun checkAutoComplete(snap: Snapshot?, now: Long): Boolean {
        if (completing) return false
        val room = snap?.autoRoom
        val eligible = snap != null && room != null &&
            !lineOnly &&
            mode == Mode.AUTO && !manualOutline && !cornersChosen &&
            snap.tracking &&
            pendingEdge == null && pendingOpening == null && pendingSurface.isEmpty() && pendingLine == null &&
            room.corners.size >= 4 && !mostlyEstimated(room)
        if (!eligible || snap == null || room == null) {
            stableSince = now
            stableCorners = -1
            return false
        }
        val est = room.estimatedCount
        // Against the size when the wait last restarted, so a slow drift
        // restarts it too. A guessed floor does not: the horizontal sizes
        // don't depend on the floor's height.
        val changed = room.corners.size != stableCorners ||
            abs(room.width - stableWidth) > max(0.05f, stableWidth * 0.015f) ||
            abs(room.depth - stableDepth) > max(0.05f, stableDepth * 0.015f) ||
            abs(room.area - stableArea) > 0.25f
        if (changed) {
            stableSince = now
            stableCorners = room.corners.size
            stableWidth = room.width
            stableDepth = room.depth
            stableArea = room.area
            return est == 0
        }
        val steady = now - stableSince
        val floorKnown = snap.floorY != null
        // Doors and windows are only counted on walls the camera has looked
        // at: finishing as soon as the walls were found (often from a few
        // corners) ended the scan before most of them had been in view.
        val lookedRound = lookedRound(snap)
        val rule = when {
            est == 0 && floorKnown && lookedRound && steady >= AUTO_STABLE_MS -> "a"
            est == 0 && !floorKnown && lookedRound && steady >= AUTO_STABLE_NO_FLOOR_MS -> "b"
            // Some walls measured as walls, not only outlined from the floor
            // and ceiling edges: turning on the spot gave a different room
            // size every time from those alone.
            snap.sectorCount >= SECTORS - 1 && snap.moveExtent >= 0.8f && snap.wallCount >= 2 &&
                est <= (if (room.corners.size == 4) 1 else 2) && steady >= AUTO_STABLE_ROUND_MS -> "c"
            else -> null
        }
        if (rule != null) startAutoComplete(room, snap, rule)
        return est == 0 && lookedRound
    }

    /** The camera has looked nearly all the way round the room (every wall
     *  in view at some point), so its doors and windows had their chance. */
    private fun lookedRound(snap: Snapshot) = snap.sectorCount >= LOOK_ROUND_SECTORS

    /** Shows the checkmark and finishes after [AUTO_FINISH_DELAY_MS] unless cancelled. */
    private fun startAutoComplete(room: AutoRoom, snap: Snapshot, rule: String) {
        completing = true
        val size = String.format("%.2f × %.2f m  ·  Area %.2f m²", room.width, room.depth, room.area)
        val est = room.estimatedCount
        val notes = listOfNotNull(
            if (est > 0) "$est wall${if (est == 1) "" else "s"} estimated — check ${if (est == 1) "it" else "them"} on the plan" else null,
            elementsSummary(),
        )
        diag(
            "auto-complete: room scanned (rule $rule), " + String.format(
                "%d corners %.2f x %.2f m, area %.2f m², estimated sides %d, %d/%d sectors, extent %.1f m",
                room.corners.size, room.width, room.depth, room.area,
                est, snap.sectorCount, SECTORS, snap.moveExtent,
            ) + ", ${elementsSummary() ?: "no doors or windows"}",
        )
        completeSize.text = size
        completeNote.text = notes.joinToString("  ·  ")
        completeNote.visibility = if (notes.isEmpty()) View.GONE else View.VISIBLE
        completeCard.animate().cancel()
        completeCard.visibility = View.VISIBLE
        completeCard.alpha = 0f
        completeCard.scaleX = 0.8f
        completeCard.scaleY = 0.8f
        completeCard.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(250).start()
        overlay.performHapticFeedback(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM
            else HapticFeedbackConstants.LONG_PRESS,
        )
        handler.removeCallbacks(autoFinish)
        handler.postDelayed(autoFinish, AUTO_FINISH_DELAY_MS)
    }

    /**
     * Stops a pending auto-finish and hides the checkmark. The steadiness
     * wait starts again, so it can complete later. [reason] is logged; null
     * logs nothing.
     */
    private fun cancelAutoComplete(reason: String?) {
        handler.removeCallbacks(autoFinish)
        stableSince = SystemClock.uptimeMillis()
        if (!completing) return
        completing = false
        if (::completeCard.isInitialized) {
            completeCard.animate().cancel()
            completeCard.visibility = View.GONE
        }
        if (reason != null) diag("auto-complete cancelled: $reason")
    }

    /**
     * The measurements line under the camera view, for the selected mode:
     * the room in Auto and Corners (with the doors and windows counted so
     * far), the marked openings in Door and Window.
     */
    private fun statsLine(auto: AutoRoom?): String {
        val sep = "   ·   "
        return when (mode) {
            Mode.AUTO -> {
                val counts = elementsSummary()
                if (auto == null) return "Measuring the room..." + (counts?.let { "$sep$it" } ?: "")
                val parts = mutableListOf(
                    "${m(auto.width)} × ${m(auto.depth)}",
                    "Area ${String.format("%.2f m²", auto.area)}",
                    "Perimeter ${m(auto.perimeter)}",
                    "${auto.corners.size} walls",
                )
                counts?.let { parts.add(it) }
                parts.joinToString(sep)
            }
            Mode.CORNER -> {
                val parts = mutableListOf("${corners.size} corner${if (corners.size == 1) "" else "s"}")
                if (corners.size >= 2) parts.add("Perimeter ${m(perimeter())}")
                if (corners.size >= 3) parts.add("Area ${String.format("%.2f m²", area())}")
                elementsSummary()?.let { parts.add(it) }
                parts.joinToString(sep)
            }
            Mode.DOOR, Mode.WINDOW -> {
                val type = if (mode == Mode.DOOR) TYPE_DOOR else TYPE_WINDOW
                val name = if (mode == Mode.DOOR) "door" else "window"
                val fy = snapshot?.floorY
                val sizes = openings.filter { it.type == type }.map { o ->
                    val sill = if (type == TYPE_WINDOW && fy != null) " (sill ${m(o.baseY - fy)})" else ""
                    sizeText(o.width, openingHeight(o, fy)) + sill
                }
                if (sizes.isEmpty()) "No ${name}s marked yet"
                else "${sizes.size} $name${if (sizes.size == 1) "" else "s"}:  " + sizes.joinToString(",  ")
            }
            Mode.SURFACE -> {
                if (surfaces.isEmpty()) "No surfaces marked yet"
                else "${surfaces.size} surface${if (surfaces.size == 1) "" else "s"}:  " +
                    surfaces.joinToString(",  ") { sizeText(it.width, it.height) } +
                    "  ·  " + area2(surfaces.sumOf { (it.width * it.height).toDouble() }.toFloat())
            }
            Mode.LINE -> linesSummary()
        }
    }

    /** "2 doors · 3 windows" for what this scan has found so far (marked,
     *  accepted or detected automatically); null when there are none. */
    private fun elementsSummary(): String? {
        val doors = openings.count { it.type == TYPE_DOOR }
        val windows = openings.count { it.type == TYPE_WINDOW }
        val things = if (mode == Mode.AUTO) furniture.confirmed().size else 0
        if (doors == 0 && windows == 0 && things == 0) return null
        return "$doors door${if (doors == 1) "" else "s"} · $windows window${if (windows == 1) "" else "s"}" +
            if (things > 0) " · $things object${if (things == 1) "" else "s"}" else ""
    }

    private fun setIfChanged(tv: TextView, text: String) {
        if (tv.text.toString() != text) tv.text = text
    }

    private fun setEnabled(v: View, on: Boolean) {
        v.isEnabled = on
        v.alpha = if (on) 1f else 0.4f
    }

    // ------------------------------------------------------------ layout

    private fun dp(v: Float) =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics)

    private fun rounded(color: Int, radius: Float, strokeColor: Int? = null, strokeWidth: Float = 0f) =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius
            if (strokeColor != null) setStroke(dp(strokeWidth).toInt(), strokeColor)
        }

    private fun circle(color: Int, strokeColor: Int? = null, strokeWidth: Float = 0f) =
        GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(color)
            if (strokeColor != null) setStroke(dp(strokeWidth).toInt(), strokeColor)
        }

    /** A white line icon (24 dp vector) centred on a round button background [bg]. */
    private fun iconButton(icon: Int, desc: String, bg: android.graphics.drawable.Drawable?): android.widget.ImageView =
        android.widget.ImageView(this).apply {
            setImageResource(icon)
            scaleType = android.widget.ImageView.ScaleType.CENTER
            background = bg
            contentDescription = desc
        }

    /** Teal disc with a white check, [pad] px around the icon. */
    private fun checkBadge(pad: Int): View = android.widget.ImageView(this).apply {
        setImageResource(R.drawable.ic_ar_check)
        scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
        background = circle(SNAP)
        setPadding(pad, pad, pad, pad)
    }

    /**
     * The bottom panel: ink fill with large rounded corners and a 1 dp white
     * hairline along the top edge only.
     */
    private inner class PanelBackground(private val radius: Float) : android.graphics.drawable.Drawable() {
        private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = PANEL }
        private val hairPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(1f)
            color = HAIRLINE
        }

        override fun draw(canvas: Canvas) {
            val b = bounds
            val l = b.left.toFloat()
            val t = b.top.toFloat()
            val r = b.right.toFloat()
            val btm = b.bottom.toFloat()
            canvas.drawRoundRect(l, t, r, btm, radius, radius, fillPaint)
            val half = hairPaint.strokeWidth / 2
            canvas.save()
            canvas.clipRect(l, t, r, t + radius * 0.6f)
            canvas.drawRoundRect(l + half, t + half, r - half, btm - half, radius - half, radius - half, hairPaint)
            canvas.restore()
        }

        override fun getOutline(outline: android.graphics.Outline) {
            outline.setRoundRect(bounds, radius)
        }

        override fun setAlpha(alpha: Int) {
            fillPaint.alpha = alpha
        }

        override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {
            fillPaint.colorFilter = colorFilter
        }

        @Deprecated("Deprecated in Java")
        override fun getOpacity() = android.graphics.PixelFormat.TRANSLUCENT
    }

    @SuppressLint("SetTextI18n")
    private fun buildUi() {
        val root = FrameLayout(this)
        glView = GLSurfaceView(this).apply {
            preserveEGLContextOnPause = true
            setEGLContextClientVersion(2)
            setEGLConfigChooser(8, 8, 8, 8, 16, 0)
            setRenderer(this@ArMeasureActivity)
            renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        }
        root.addView(glView, FrameLayout.LayoutParams(-1, -1))
        overlay = OverlayView(this)
        root.addView(overlay, FrameLayout.LayoutParams(-1, -1))

        // ---- top: close button, status pill, instruction card
        val top = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        topBox = top
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val round = dp(44f).toInt()
        val close = iconButton(R.drawable.ic_ar_close, "Close", circle(PANEL, HAIRLINE, 1f)).apply {
            setOnClickListener {
                @Suppress("DEPRECATION")
                onBackPressed()
            }
        }
        bar.addView(close, LinearLayout.LayoutParams(round, round))
        statusText = TextView(this).apply {
            textSize = 13f
            setTextColor(Color.WHITE)
            typeface = fontSemiBold
            fontFeatureSettings = "tnum"
            letterSpacing = 0.01f
            gravity = Gravity.CENTER
            background = rounded(PANEL, dp(22f), HAIRLINE, 1f)
            setPadding(dp(16f).toInt(), 0, dp(16f).toInt(), 0)
            maxLines = 1
            // Three round buttons share the 300 dp landscape bar: the status
            // shrinks rather than pushing them off.
            ellipsize = TextUtils.TruncateAt.END
        }
        bar.addView(statusText, LinearLayout.LayoutParams(0, round, 1f).apply {
            marginStart = dp(8f).toInt()
        })
        val photo = iconButton(R.drawable.ic_ar_camera, "Take photo", circle(PANEL, HAIRLINE, 1f)).apply {
            setOnClickListener { onPhoto() }
        }
        bar.addView(photo, LinearLayout.LayoutParams(round, round).apply {
            marginStart = dp(8f).toInt()
        })
        val reset = iconButton(R.drawable.ic_ar_restart, "Start over", circle(PANEL, HAIRLINE, 1f)).apply {
            setOnClickListener { onReset() }
        }
        bar.addView(reset, LinearLayout.LayoutParams(round, round).apply {
            marginStart = dp(8f).toInt()
        })
        top.addView(bar)
        hintText = TextView(this).apply {
            textSize = 15f
            typeface = fontRegular
            setTextColor(Color.WHITE)
            setLineSpacing(0f, 1.25f)
            background = rounded(PANEL, dp(18f), HAIRLINE, 1f)
            setPadding(dp(16f).toInt(), dp(14f).toInt(), dp(16f).toInt(), dp(14f).toInt())
        }
        top.addView(hintText, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10f).toInt() })
        root.addView(top)

        // ---- bottom: stats, mode tabs, actions
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = PanelBackground(dp(28f))
            setPadding(dp(16f).toInt(), dp(16f).toInt(), dp(16f).toInt(), dp(14f).toInt())
        }
        panelBox = panel
        statsText = TextView(this).apply {
            textSize = 13f
            typeface = fontMedium
            fontFeatureSettings = "tnum"
            setTextColor(Color.argb(224, 255, 255, 255))
            setLineSpacing(0f, 1.15f)
            gravity = Gravity.CENTER
            maxLines = 2
        }
        panel.addView(statsText, LinearLayout.LayoutParams(-1, -2))

        // Line mode only: how a line's ends are taken.
        methodBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = rounded(TRACK, dp(21f))
            val p = dp(3f).toInt()
            setPadding(p, p, p, p)
            visibility = View.GONE
        }
        for (md in LineMethod.values()) {
            val tv = TextView(this).apply {
                text = md.label
                typeface = fontSemiBold
                gravity = Gravity.CENTER
                textSize = 13f
                setSingleLine()
                setTextColor(TAB_IDLE)
                setOnClickListener { onLineMethod(md) }
            }
            methodTabs[md] = tv
            methodBox.addView(tv, LinearLayout.LayoutParams(0, dp(36f).toInt(), 1f))
        }
        panel.addView(methodBox, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12f).toInt() })

        // The mode row scrolls when its tabs (at least 64 dp each) don't fit
        // the panel; when they do, they share its width equally.
        val tabs = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        tabScroll = HorizontalScrollView(this).apply {
            isFillViewport = true
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            background = rounded(TRACK, dp(21f))
            // Tabs scrolled to the ends stay inside the pill.
            clipToOutline = true
            val p = dp(3f).toInt()
            setPadding(p, p, p, p)
            addOnLayoutChangeListener { _, l, _, rt, _, ol, _, ort, _ ->
                // Rotation changes the panel's width: keep the selected tab in view.
                if (rt - l != ort - ol) post { scrollToSelectedTab(false) }
            }
        }
        for (md in Mode.values()) {
            // Surface measuring is hidden from the camera.
            if (md == Mode.SURFACE) continue
            // Measuring distances only: no room outline is returned, so the
            // room modes (whose result would be thrown away) are not offered.
            if (lineOnly && (md == Mode.AUTO || md == Mode.CORNER)) continue
            val tv = TextView(this).apply {
                text = md.label
                typeface = fontSemiBold
                gravity = Gravity.CENTER
                setTextColor(TAB_IDLE)
                // Shrink the text rather than wrap or cut off a label.
                minWidth = dp(64f).toInt()
                setSingleLine()
                ellipsize = null
                if (Build.VERSION.SDK_INT >= 26) {
                    textSize = 13f
                    setAutoSizeTextTypeUniformWithConfiguration(8, 13, 1, TypedValue.COMPLEX_UNIT_SP)
                } else {
                    textSize = 12f
                }
                setOnClickListener { onMode(md) }
            }
            modeTabs[md] = tv
            tabs.addView(tv, LinearLayout.LayoutParams(0, dp(36f).toInt(), 1f))
        }
        tabScroll.addView(tabs, FrameLayout.LayoutParams(-2, -2))
        panel.addView(tabScroll, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12f).toInt() })

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        fun sideButton(label: String, icon: Int, onClick: () -> Unit): Pair<View, View> {
            val col = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                contentDescription = label
                setOnClickListener { onClick() }
            }
            val circleView = android.widget.ImageView(this).apply {
                setImageResource(icon)
                scaleType = android.widget.ImageView.ScaleType.CENTER
                background = circle(INK2, HAIRLINE, 1f)
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            col.addView(circleView, LinearLayout.LayoutParams(dp(52f).toInt(), dp(52f).toInt()))
            col.addView(TextView(this).apply {
                text = label
                textSize = 11f
                typeface = fontMedium
                letterSpacing = 0.02f
                setTextColor(Color.argb(204, 255, 255, 255))
                gravity = Gravity.CENTER
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(6f).toInt() })
            actions.addView(col, LinearLayout.LayoutParams(0, -2, 1f))
            return col to circleView
        }
        undoButton = sideButton("Undo", R.drawable.ic_ar_undo) { onUndo() }.first
        markButton = FrameLayout(this).apply {
            background = circle(Color.TRANSPARENT, Color.WHITE, 3f)
            setOnClickListener { onMark() }
            markDisc = View(context).apply { background = circle(Color.WHITE) }
            addView(markDisc, FrameLayout.LayoutParams(dp(62f).toInt(), dp(62f).toInt(), Gravity.CENTER))
            markGlyph = TextView(context).apply {
                text = "+"
                textSize = 30f
                typeface = fontMedium
                includeFontPadding = false
                setTextColor(INK)
                gravity = Gravity.CENTER
            }
            addView(markGlyph, FrameLayout.LayoutParams(-1, -1))
        }
        actions.addView(markButton, LinearLayout.LayoutParams(dp(76f).toInt(), dp(76f).toInt()))
        val (done, doneIcon) = sideButton("Finish", R.drawable.ic_ar_check) { onDone() }
        doneButton = done
        doneCircle = doneIcon
        panel.addView(actions, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(16f).toInt() })

        root.addView(panel)

        // ---- auto-completion checkmark, centred over everything (wrap
        // content, so it fits portrait and landscape alike)
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            background = rounded(CARD, dp(28f), HAIRLINE, 1f)
            val p = dp(24f).toInt()
            setPadding(p, p, p, dp(20f).toInt())
            visibility = View.GONE
        }
        card.addView(checkBadge(dp(20f).toInt()), LinearLayout.LayoutParams(dp(80f).toInt(), dp(80f).toInt()))
        card.addView(TextView(this).apply {
            text = "Room scanned"
            textSize = 20f
            typeface = fontBold
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
        }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(16f).toInt() })
        completeSize = TextView(this).apply {
            textSize = 15f
            typeface = fontMedium
            fontFeatureSettings = "tnum"
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
        }
        card.addView(completeSize, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(8f).toInt() })
        completeNote = TextView(this).apply {
            textSize = 13f
            typeface = fontMedium
            gravity = Gravity.CENTER
            setTextColor(DOOR)
            visibility = View.GONE
        }
        card.addView(completeNote, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(6f).toInt() })
        card.addView(TextView(this).apply {
            text = "Opening your floor plan…"
            textSize = 13f
            typeface = fontRegular
            gravity = Gravity.CENTER
            setTextColor(Color.argb(179, 255, 255, 255))
        }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(14f).toInt() })
        completeCard = card
        root.addView(card, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER).apply {
            val mgn = dp(16f).toInt()
            setMargins(mgn, mgn, mgn, mgn)
        })

        root.setOnApplyWindowInsetsListener { _, wi ->
            insets = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val i = wi.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                intArrayOf(i.left, i.top, i.right, i.bottom)
            } else {
                @Suppress("DEPRECATION")
                intArrayOf(wi.systemWindowInsetLeft, wi.systemWindowInsetTop,
                    wi.systemWindowInsetRight, wi.systemWindowInsetBottom)
            }
            applyLayout()
            wi
        }
        applyLayout()
        setContentView(root)
    }

    /**
     * Portrait: instruction card across the top, controls across the bottom.
     * Landscape: instruction card top-left and controls bottom-right, so the
     * crosshair in the centre of the camera view stays clear.
     */
    private fun applyLayout() {
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val (il, itop, ir, ib) = insets.toList()
        topBox.layoutParams = if (landscape) {
            FrameLayout.LayoutParams(dp(300f).toInt(), -2, Gravity.TOP or Gravity.LEFT).apply {
                setMargins(dp(16f).toInt() + il, dp(12f).toInt() + itop, 0, 0)
            }
        } else {
            FrameLayout.LayoutParams(-1, -2, Gravity.TOP).apply {
                setMargins(dp(16f).toInt() + il, max(dp(40f).toInt(), dp(12f).toInt() + itop),
                    dp(16f).toInt() + ir, 0)
            }
        }
        panelBox.layoutParams = if (landscape) {
            FrameLayout.LayoutParams(dp(320f).toInt(), -2, Gravity.BOTTOM or Gravity.RIGHT).apply {
                setMargins(0, 0, dp(12f).toInt() + ir, dp(12f).toInt() + ib)
            }
        } else {
            FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM).apply {
                setMargins(dp(12f).toInt() + il, 0, dp(12f).toInt() + ir,
                    max(dp(28f).toInt(), dp(12f).toInt() + ib))
            }
        }
        if (::overlay.isInitialized) overlay.invalidate()
    }

    // ------------------------------------------------------------ overlay

    private inner class OverlayView(context: Context) : View(context) {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(1.5f)
        }
        private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(2.5f)
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            color = Color.WHITE
        }
        private val dashed = Paint(line).apply {
            // Round caps lengthen each dash by the stroke width.
            pathEffect = DashPathEffect(floatArrayOf(dp(8f), dp(9f)), 0f)
            strokeWidth = dp(2.5f)
        }
        /** Auto scan: the white lines along the walls found (drawLiveWalls). */
        private val liveWall = Paint(line).apply {
            strokeWidth = dp(4f)
            color = Color.WHITE
        }
        private val liveWallDash = Paint(liveWall).apply {
            pathEffect = DashPathEffect(floatArrayOf(dp(10f), dp(8f)), 0f)
        }
        /** A soft dark edge so the white lines show on light walls too. */
        private val liveShadow = Paint(line).apply {
            strokeWidth = dp(7f)
            color = Color.argb(80, 0, 0, 0)
        }
        /** Furniture boxes in the live view: thinner white lines. */
        private val liveThin = Paint(line).apply {
            strokeWidth = dp(2f)
            color = Color.argb(220, 255, 255, 255)
        }
        private val dot = Paint(Paint.ANTI_ALIAS_FLAG)
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(2f)
            strokeCap = Paint.Cap.ROUND
        }
        private val cross = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(2f)
            strokeCap = Paint.Cap.ROUND
            setShadowLayer(dp(4f), 0f, dp(1f), Color.argb(120, 0, 0, 0))
        }
        /** The crosshair's centre dot (filled, same soft shadow). */
        private val crossDot = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            setShadowLayer(dp(4f), 0f, dp(1f), Color.argb(120, 0, 0, 0))
        }
        private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 13f, resources.displayMetrics)
            typeface = fontSemiBold
            fontFeatureSettings = "tnum"
            textAlign = Paint.Align.CENTER
        }
        private val labelBg = Paint(Paint.ANTI_ALIAS_FLAG)
        private val mapBg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = MAP_BG }
        private val mapBorder = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(1f)
            color = HAIRLINE
        }
        private val mapLine = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(2f)
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            color = Color.WHITE
        }
        private val mapDash = Paint(mapLine).apply {
            color = Color.argb(180, 255, 255, 255)
            strokeCap = Paint.Cap.BUTT
            pathEffect = DashPathEffect(floatArrayOf(dp(4f), dp(4f)), 0f)
        }
        private val mapEst = Paint(mapLine).apply {
            color = DOOR
            strokeCap = Paint.Cap.BUTT
            pathEffect = DashPathEffect(floatArrayOf(dp(4f), dp(3f)), 0f)
        }
        private val mapArc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(3f)
            strokeCap = Paint.Cap.ROUND
        }
        private val path = Path()

        // Live 2D plan (room scan).
        /** Where the plan / the mini-map was last drawn (taps toggle them). */
        val planRect = android.graphics.RectF()
        val miniRect = android.graphics.RectF()
        private val planBg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(240, 11, 20, 38) }
        private val planGrid = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(1f)
            color = Color.argb(22, 255, 255, 255)
        }
        private val planWall = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(6f)
            strokeCap = Paint.Cap.SQUARE
            strokeJoin = Paint.Join.MITER
            color = Color.WHITE
        }
        private val planEst = Paint(planWall).apply {
            strokeWidth = dp(3f)
            strokeCap = Paint.Cap.BUTT
            color = DOOR
            pathEffect = DashPathEffect(floatArrayOf(dp(7f), dp(5f)), 0f)
        }
        /** Wall surfaces seen so far (before / beside the room outline). */
        private val planSeen = Paint(planWall).apply {
            strokeWidth = dp(4f)
            strokeCap = Paint.Cap.ROUND
            color = Color.argb(110, 150, 175, 255)
        }
        /** Cuts the wall open where a door or window is (plan background). */
        private val gap = Paint(planWall).apply {
            color = Color.rgb(11, 20, 38)
            strokeWidth = dp(8f)
            strokeCap = Paint.Cap.BUTT
        }
        private val planThin = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(2f)
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        private val planText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 15f, resources.displayMetrics)
            typeface = fontSemiBold
            fontFeatureSettings = "tnum"
        }
        private val planSub = Paint(planText).apply {
            color = Color.argb(170, 255, 255, 255)
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 12f, resources.displayMetrics)
            typeface = Typeface.DEFAULT
        }
        private val planLen = Paint(label).apply {
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 11f, resources.displayMetrics)
        }

        init {
            setLayerType(LAYER_TYPE_SOFTWARE, null) // for the crosshair shadow
        }

        /** The finger placing a line point; a second finger is ignored. */
        private var pointerId = -1

        /** The cards lie over this view but only their buttons take touches:
         *  a touch on a card's background must not place a point under it. */
        private fun onPanel(x: Float, y: Float) = listOf(topBox, panelBox).any {
            it.visibility == VISIBLE && x >= it.left && x <= it.right && y >= it.top && y <= it.bottom
        }

        /** The finger dragging the door / window frame's circle or line. */
        private var adjustPointer = -1

        /** Door / Window: the orange frame found can be dragged into place,
         *  one side at a time, by its handle or its line. Returns whether it took [e]. */
        private fun adjustTouch(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    if (onPanel(e.x, e.y) || !grabOpening(e.x, e.y, width, height)) return false
                    adjustPointer = e.getPointerId(0)
                    performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                }
                MotionEvent.ACTION_MOVE -> {
                    val i = e.findPointerIndex(adjustPointer)
                    if (i < 0) return adjustPointer >= 0
                    dragOpening(e.getX(i), e.getY(i), width, height)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_CANCEL -> {
                    if (adjustPointer < 0) return false
                    if (e.actionMasked == MotionEvent.ACTION_POINTER_UP &&
                        e.getPointerId(e.actionIndex) != adjustPointer
                    ) return true
                    adjustPointer = -1
                    adjustGrab = -1
                }
                else -> return adjustPointer >= 0
            }
            invalidate()
            return true
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            if (autoOpening() && adjustTouch(e)) return true
            // Room scan: a tap on the 2D plan shows the camera overlay with
            // the small map; a tap on that map brings the plan back.
            if (e.actionMasked == MotionEvent.ACTION_DOWN && (mode == Mode.AUTO || mode == Mode.CORNER) && !lineOnly &&
                (planRect.contains(e.x, e.y) || miniRect.contains(e.x, e.y))
            ) {
                planBig = !planBig
                performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                invalidate()
                return true
            }
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    // Not handled in other modes: as before, nothing happens.
                    if (!tapLine() || onPanel(e.x, e.y)) return false
                    pointerId = e.getPointerId(0)
                    onTapDown(e.x, e.y)
                }
                MotionEvent.ACTION_MOVE -> {
                    val i = e.findPointerIndex(pointerId)
                    if (i >= 0) onTapMove(e.getX(i), e.getY(i))
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                    val i = e.actionIndex
                    if (e.getPointerId(i) == pointerId) {
                        pointerId = -1
                        onTapUp(e.getX(i), e.getY(i))
                    }
                }
                MotionEvent.ACTION_CANCEL -> {
                    pointerId = -1
                    clearTap()
                }
            }
            invalidate()
            return true
        }

        /** World point to screen pixels, or null if behind the camera. */
        private fun clip(vp: FloatArray, p: Vec3): FloatArray {
            val v = FloatArray(4)
            Matrix.multiplyMV(v, 0, vp, 0, floatArrayOf(p.x, p.y, p.z, 1f), 0)
            return v
        }

        private fun toScreen(v: FloatArray) =
            floatArrayOf((v[0] / v[3] + 1f) / 2f * width, (1f - v[1] / v[3]) / 2f * height)

        /** Clip-space point where a..b crosses the near limit. */
        private fun cut(a: FloatArray, b: FloatArray): FloatArray {
            val t = (NEAR_W - a[3]) / (b[3] - a[3])
            return FloatArray(4) { a[it] + (b[it] - a[it]) * t }
        }

        private fun project(vp: FloatArray, p: Vec3): FloatArray? {
            val v = clip(vp, p)
            if (v[3] <= NEAR_W) return null
            return toScreen(v)
        }

        /** A line in the scene on screen, cut off where it passes behind the
         *  camera (instead of dropped when one end is behind it). */
        private fun projectSegment(vp: FloatArray, a: Vec3, b: Vec3): Pair<FloatArray, FloatArray>? {
            var ca = clip(vp, a)
            var cb = clip(vp, b)
            if (ca[3] <= NEAR_W && cb[3] <= NEAR_W) return null
            if (ca[3] <= NEAR_W) ca = cut(ca, cb) else if (cb[3] <= NEAR_W) cb = cut(cb, ca)
            return toScreen(ca) to toScreen(cb)
        }

        /** A surface outline on screen, clipped to the part in front of the
         *  camera. The floor you stand on always reaches behind you; without
         *  clipping it (and walls beside you) was not drawn at all. */
        private fun projectPolygon(vp: FloatArray, pts: List<Vec3>): List<FloatArray> {
            val c = pts.map { clip(vp, it) }
            val out = ArrayList<FloatArray>(c.size + 2)
            for (i in c.indices) {
                val a = c[i]
                val b = c[(i + 1) % c.size]
                if (a[3] > NEAR_W) out.add(toScreen(a))
                if ((a[3] > NEAR_W) != (b[3] > NEAR_W)) out.add(toScreen(cut(a, b)))
            }
            return out
        }

        /** A fully rounded measurement chip, its text's baseline at [y]. */
        private fun chip(canvas: Canvas, x: Float, y: Float, text: String, bg: Int = CHIP) {
            val w = label.measureText(text) / 2 + dp(10f)
            labelBg.color = bg
            val t = y - dp(18f)
            val b = y + dp(8f)
            val r = (b - t) / 2
            canvas.drawRoundRect(x - w, t, x + w, b, r, r, labelBg)
            // Centre the text in the pill whatever the font's metrics.
            val fm = label.fontMetrics
            canvas.drawText(text, x, (t + b) / 2 - (fm.ascent + fm.descent) / 2, label)
        }

        /** A placed line point: stays on its spot in the scene. Amber inside
         *  when its distance was estimated. */
        private fun marker(canvas: Canvas, x: Float, y: Float, estimated: Boolean) {
            dot.color = Color.WHITE
            canvas.drawCircle(x, y, dp(9f), dot)
            dot.color = if (estimated) DOOR else LINE
            canvas.drawCircle(x, y, dp(6f), dot)
        }

        /** The ring under the finger, with a "+" marking the exact spot. */
        private fun tapRing(canvas: Canvas, x: Float, y: Float, colour: Int) {
            cross.color = colour
            canvas.drawCircle(x, y, dp(16f), cross)
            val arm = dp(5f)
            canvas.drawLine(x - arm, y, x + arm, y, cross)
            canvas.drawLine(x, y - arm, x, y + arm, cross)
        }

        /**
         * Tap feedback (Line mode): the ring under the finger, white on a
         * measured point, amber on an estimated one, red where there is
         * none; the live line from the first point; and, because the finger
         * hides the spot, a chip above it.
         */
        private fun drawTap(canvas: Canvas, snap: Snapshot) {
            if (SystemClock.uptimeMillis() < tapMissUntil) tapRing(canvas, tapMissX, tapMissY, ERROR)
            if (!tapShown()) return
            val pick = tapPreview()
            val p = pick?.p
            val a = pendingLine
            if (a != null && p != null) {
                // Ends at the finger itself: the pick is a frame behind it.
                projectSegment(snap.viewProj, a, p)?.let { (sa, _) ->
                    dashed.color = LINE
                    canvas.drawLine(sa[0], sa[1], tapX, tapY, dashed)
                }
            }
            tapRing(
                canvas, tapX, tapY,
                when {
                    // Not answered yet (the first frame of a touch).
                    pick == null -> Color.argb(170, 255, 255, 255)
                    p == null -> ERROR
                    pick.estimated -> DOOR
                    else -> Color.WHITE
                },
            )
            if (pick == null) return
            val text = when {
                p == null -> "No depth here"
                a == null -> "First point"
                else -> (if (pendingLineEstimated || pick.estimated) "≈ " else "") + lineText(a, p)
            }
            // Above the finger; below it when that would leave the screen.
            val half = label.measureText(text) / 2 + dp(12f)
            val x = if (width > 2 * half) tapX.coerceIn(half, width - half) else width / 2f
            val y = if (tapY - dp(64f) > insets[1] + dp(24f)) tapY - dp(64f) else tapY + dp(64f)
            chip(canvas, x, y, text, if (p == null) ERROR else CHIP)
        }

        private fun segment(canvas: Canvas, vp: FloatArray, a: Vec3, b: Vec3, paint: Paint) {
            val (sa, sb) = projectSegment(vp, a, b) ?: return
            canvas.drawLine(sa[0], sa[1], sb[0], sb[1], paint)
        }

        /**
         * Door / window frame: the base a..b and, when [topY] is known, the
         * jambs up to it and the top. Returns the frame's centre on screen
         * (for its label), or null when it is off screen.
         */
        private fun drawFrame(
            canvas: Canvas, vp: FloatArray, a: Vec3, b: Vec3, topY: Float?, colour: Int, paint: Paint,
            baseLine: Boolean = true,
        ): FloatArray? {
            paint.color = colour
            if (baseLine) segment(canvas, vp, a, b, paint)
            if (topY == null) return projectSegment(vp, a, b)?.let { (p, q) -> floatArrayOf((p[0] + q[0]) / 2, (p[1] + q[1]) / 2) }
            val at = a.withY(topY)
            val bt = b.withY(topY)
            segment(canvas, vp, a, at, paint)
            segment(canvas, vp, b, bt, paint)
            segment(canvas, vp, at, bt, paint)
            return project(vp, (a + b + at + bt) * 0.25f)
        }

        /** Rectangle a, b, b + up, a + up. Returns its centre on screen. */
        private fun drawQuad(canvas: Canvas, vp: FloatArray, a: Vec3, b: Vec3, up: Vec3, colour: Int, paint: Paint): FloatArray? {
            paint.color = colour
            val bu = b + up
            val au = a + up
            segment(canvas, vp, a, b, paint)
            segment(canvas, vp, b, bu, paint)
            segment(canvas, vp, bu, au, paint)
            segment(canvas, vp, au, a, paint)
            return project(vp, (a + b + bu + au) * 0.25f)
        }

        override fun onDraw(canvas: Canvas) {
            val snap = snapshot ?: return
            drawScene(canvas, snap, false)
        }

        /**
         * The measurements for an AR photo: the room outline in use with its
         * side lengths, doors, windows and surfaces; no crosshair, mini-map,
         * live line, scan dots or surface fills. [canvas] is the size of
         * this view.
         */
        fun drawForPhoto(canvas: Canvas, snap: Snapshot) = drawScene(canvas, snap, true)

        private fun drawScene(canvas: Canvas, snap: Snapshot, forPhoto: Boolean) {
            val cx = width / 2f
            val cy = height / 2f
            val vp = snap.viewProj

            planRect.setEmpty()
            miniRect.setEmpty()
            // Room scan with the 2D plan: the camera image stays clear; what
            // was found is drawn on the plan.
            val plan2d = !forPhoto && livePlanShown()
            if (forPhoto) {
                if (useAutoRoom() && !lineOnly) snap.autoRoom?.let { drawAutoRoom(canvas, snap, it) }
            } else if (snap.tracking && !(plan2d && mode == Mode.AUTO)) {
                // Corner mode keeps these with its plan: they are aimed at.
                drawSurfaces(canvas, snap)
                drawFramePoints(canvas, snap)
                if (mode == Mode.CORNER) drawCornerCandidates(canvas, snap)
            }
            // Auto room scan: the walls, corners, doors, windows and
            // furniture outlined in white on the camera image as they are
            // found (lengths are on the plan).
            if (!forPhoto && snap.tracking && mode == Mode.AUTO && !lineOnly) drawLiveWalls(canvas, snap)
            val touch = touchLine()
            val touchOp = touchOpening()
            val autoOp = autoOpening()
            val aim = if (snap.tracking && !forPhoto && !touch && !touchOp && !autoOp) resolveAim(snap) else null

            // Marked outline, drawn at floor level when the floor is known.
            val fy = snap.floorY
            fun onFloor(p: Vec3) = if (fy != null) p.withY(fy) else p
            val pts = corners.map { project(vp, onFloor(it)) }
            line.color = Color.WHITE
            for (i in 1 until corners.size) {
                val (a, b) = projectSegment(vp, onFloor(corners[i - 1]), onFloor(corners[i])) ?: continue
                canvas.drawLine(a[0], a[1], b[0], b[1], line)
                chip(canvas, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, m(corners[i - 1].dist2d(corners[i])))
            }
            if (corners.size >= 3) {
                projectSegment(vp, onFloor(corners.last()), onFloor(corners.first()))?.let { (a, b) ->
                    if (forPhoto) {
                        // The photo shows the closed room with every side.
                        canvas.drawLine(a[0], a[1], b[0], b[1], line)
                        chip(canvas, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, m(corners.last().dist2d(corners.first())))
                    } else {
                        dashed.color = Color.argb(200, 255, 255, 255)
                        canvas.drawLine(a[0], a[1], b[0], b[1], dashed)
                    }
                }
            }
            for (p in pts) {
                if (p == null) continue
                dot.color = Color.WHITE
                canvas.drawCircle(p[0], p[1], dp(7f), dot)
                dot.color = ACCENT
                canvas.drawCircle(p[0], p[1], dp(4.5f), dot)
            }

            // Doors and windows. A door's base is drawn on the floor; a
            // window's base is its sill, so it stays where it was tapped.
            fun base(o: OpeningMark, p: Vec3) = if (o.type == TYPE_DOOR) onFloor(p) else p
            for (o in openings) {
                // Auto scan: drawn as white frames by drawLiveWalls.
                if (mode == Mode.AUTO && !forPhoto && !lineOnly) break
                val colour = if (o.type == TYPE_DOOR) DOOR else WINDOW
                val a0 = base(o, o.a)
                val b0 = base(o, o.b)
                val mid = drawFrame(canvas, vp, a0, b0, o.topY, colour, line) ?: continue
                chip(canvas, mid[0], mid[1] - dp(14f), sizeText(o.width, openingHeight(o, fy)), colour)
            }
            pendingOpening?.let { o ->
                val colour = if (o.type == TYPE_DOOR) DOOR else WINDOW
                val a0 = base(o, o.a)
                val b0 = base(o, o.b)
                // Live frame up to the crosshair's height (Touch: the phone's).
                val top = if (touchOp && snap.tracking && !forPhoto) snap.camPos.y else aim?.p?.y
                drawFrame(canvas, vp, a0, b0, null, colour, line)
                if (top != null) {
                    drawFrame(canvas, vp, a0, b0, top, colour, dashed, baseLine = false)
                    var text = "Height ${openingHeight(o, fy, top)?.let { m(it) }}"
                    if (o.type == TYPE_WINDOW && fy != null) text += " · sill ${m(o.baseY - fy)}"
                    chip(canvas, cx, cy - dp(34f), text, colour)
                }
            }

            // Surfaces.
            for (s in surfaces) {
                val mid = drawQuad(canvas, vp, s.a, s.b, s.up, SURFACE, line) ?: continue
                chip(canvas, mid[0], mid[1], "${sizeText(s.width, s.height)} · ${area2(s.width * s.height)}", SURFACE)
            }
            // Measured lines, where they were tapped (3D).
            for (l in lines) {
                val (a, b) = projectSegment(vp, l.a, l.b) ?: continue
                // Dashed and "≈" when an end was estimated, not measured.
                val paint = if (l.estimated) dashed else line
                paint.color = LINE
                canvas.drawLine(a[0], a[1], b[0], b[1], paint)
                project(vp, l.a)?.let { marker(canvas, it[0], it[1], l.aEstimated) }
                project(vp, l.b)?.let { marker(canvas, it[0], it[1], l.bEstimated) }
                chip(
                    canvas, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2,
                    (if (l.estimated) "≈ " else "") + lineText(l.a, l.b),
                )
            }
            // Live marking aids, crosshair and mini-map are not in photos.
            if (forPhoto) return
            if (pendingSurface.size == 2) {
                val sa = pendingSurface[0]
                val sb = pendingSurface[1]
                projectSegment(vp, sa, sb)?.let { (a, b) ->
                    line.color = SURFACE
                    canvas.drawLine(a[0], a[1], b[0], b[1], line)
                }
                if (aim != null) {
                    val up = perpendicular(sa, sb, aim.p)
                    drawQuad(canvas, vp, sa, sb, up, SURFACE, dashed)
                    chip(canvas, cx, cy - dp(34f), sizeText(len(sb - sa), len(up)), SURFACE)
                }
            }

            // Live line from the last mark to the crosshair.
            val from = when (mode) {
                Mode.AUTO -> null
                Mode.CORNER -> corners.lastOrNull()
                Mode.DOOR -> pendingEdge?.let { onFloor(it) }
                Mode.WINDOW -> pendingEdge
                Mode.SURFACE -> pendingSurface.singleOrNull()
                Mode.LINE -> pendingLine
            }
            // While a finger is down the line follows it instead (drawTap).
            val tapping = mode == Mode.LINE && !touch && tapShown()
            if (aim != null && from != null && !tapping) {
                // Surfaces are measured in 3D; everything else on the floor plan.
                val to = when (mode) {
                    Mode.SURFACE, Mode.WINDOW, Mode.LINE -> aim.p
                    else -> onFloor(aim.p)
                }
                projectSegment(vp, if (mode == Mode.CORNER) onFloor(from) else from, to)?.let { (a, b) ->
                    dashed.color = when (mode) {
                        Mode.DOOR -> DOOR
                        Mode.WINDOW -> WINDOW
                        Mode.SURFACE -> SURFACE
                        Mode.LINE -> LINE
                        else -> Color.WHITE
                    }
                    canvas.drawLine(a[0], a[1], b[0], b[1], dashed)
                }
                chip(
                    canvas, cx, cy - dp(34f),
                    when (mode) {
                        Mode.LINE ->
                            (if (pendingLineEstimated || snap.hitEstimated) "≈ " else "") + lineText(from, aim.p)
                        Mode.SURFACE -> m(len(aim.p - from))
                        else -> m(from.dist2d(aim.p))
                    },
                )
            }
            // Marked points not drawn as part of a line yet.
            val loose = when (mode) {
                Mode.DOOR -> listOfNotNull(pendingEdge?.let { onFloor(it) })
                Mode.WINDOW -> listOfNotNull(pendingEdge)
                Mode.SURFACE -> pendingSurface
                Mode.LINE -> listOfNotNull(pendingLine)
                else -> emptyList()
            }
            for (p in loose) {
                val s = project(vp, p) ?: continue
                if (mode == Mode.LINE) {
                    marker(canvas, s[0], s[1], pendingLineEstimated)
                    continue
                }
                dot.color = Color.WHITE
                canvas.drawCircle(s[0], s[1], dp(6f), dot)
                dot.color = when (mode) {
                    Mode.DOOR -> DOOR
                    Mode.WINDOW -> WINDOW
                    Mode.LINE -> LINE
                    else -> SURFACE
                }
                canvas.drawCircle(s[0], s[1], dp(4f), dot)
            }
            if (mode == Mode.AUTO) {
                if (plan2d) drawLivePlan(canvas, snap) else drawMiniMap(canvas, null)
                return
            }

            // Door / window Auto: the frame found, and a plain crosshair to
            // point at its middle.
            if (autoOp) {
                if (snap.tracking) drawAutoOpening(canvas, snap)
                crosshair(canvas, cx, cy, if (snap.tracking) Color.WHITE else Color.argb(180, 255, 255, 255))
                drawMiniMap(canvas, null)
                return
            }

            // Door / window Touch: no crosshair; the width so far, or a
            // warning when the phone was turned.
            if (touchOp) {
                val e = pendingEdge
                if (snap.tracking && (e != null || pendingOpening != null)) {
                    if (openingTouchTurned(snap)) chip(canvas, cx, cy, "Phone turned: turn it back", ERROR)
                    else if (e != null) chip(canvas, cx, cy - dp(34f), "Width ${m(e.dist2d(snap.camPos))}")
                }
                drawMiniMap(canvas, null)
                return
            }

            // Touch: the phone itself is the pointer, so no crosshair; the
            // distance moved from the first point is shown instead.
            if (touch) {
                val a = pendingLine
                if (snap.tracking && a != null) {
                    if (touchTurned(snap)) chip(canvas, cx, cy - dp(34f), "Phone turned: turn it back", ERROR)
                    else chip(canvas, cx, cy - dp(34f), lineText(a, snap.camPos))
                }
                drawMiniMap(canvas, null)
                return
            }

            // Crosshair.
            val estimated = aim != null && snap.hitEstimated && !aim.snappedCorner
            cross.color = when {
                !snap.tracking -> Color.argb(180, 255, 255, 255)
                aim == null -> ERROR
                aim.snappedCorner -> SNAP
                estimated -> DOOR
                else -> Color.WHITE
            }
            crosshair(canvas, cx, cy, cross.color)

            if (snap.tracking) {
                when {
                    aim == null -> chip(canvas, cx, cy + dp(46f), "No surface here", ERROR)
                    aim.closesRoom -> chip(canvas, cx, cy + dp(46f), "Tap to close the room", SNAP)
                    aim.snappedCorner -> chip(canvas, cx, cy + dp(46f), "Corner detected", SNAP)
                    estimated -> chip(canvas, cx, cy + dp(46f), "Estimated surface", DOOR)
                }
            }
            if (mode == Mode.LINE) drawTap(canvas, snap)
            if (plan2d && mode == Mode.CORNER) drawLivePlan(canvas, snap, aim) else drawMiniMap(canvas, aim)
        }

        /** Thin ring, centre dot and four short ticks, with a soft shadow. */
        private fun crosshair(canvas: Canvas, cx: Float, cy: Float, colour: Int) {
            cross.color = colour
            crossDot.color = colour
            val r = dp(14f)
            canvas.drawCircle(cx, cy, r, cross)
            canvas.drawCircle(cx, cy, dp(2.25f), crossDot)
            val t0 = r + dp(4f)
            val t1 = r + dp(9f)
            canvas.drawLine(cx - t1, cy, cx - t0, cy, cross)
            canvas.drawLine(cx + t0, cy, cx + t1, cy, cross)
            canvas.drawLine(cx, cy - t1, cx, cy - t0, cross)
            canvas.drawLine(cx, cy + t0, cx, cy + t1, cross)
        }

        /**
         * The door / window found automatically: its rectangle on the wall,
         * amber and dashed while the detections still disagree, green once
         * steady, with corner dots and its size.
         */
        private fun drawAutoOpening(canvas: Canvas, snap: Snapshot) {
            val (c, _) = shownOpening() ?: return
            val vp = snap.viewProj
            val hand = adjusted != null
            val stable = hand || consensus.state?.stable == true
            // Adjusted by hand: solid orange; found: dashed orange until the
            // detections agree, then green.
            val colour = if (hand) DOOR else if (stable) SNAP else DOOR
            val paint = if (stable) line else dashed
            paint.color = colour
            val a = c.a
            val b = c.b
            val at = a.withY(c.topY)
            val bt = b.withY(c.topY)
            val corners = listOf(a, b, bt, at)
            val g = adjustGrab
            for (i in 0 until 4) {
                // Side i runs from corner i to i + 1; the one held in blue.
                paint.color = if (hand && g == i) ACCENT else colour
                segment(canvas, vp, corners[i], corners[(i + 1) % 4], paint)
            }
            paint.color = colour
            // Corners: small dots only (dragging a corner moved two sides).
            for (p in corners) {
                val s = project(vp, p) ?: continue
                dot.color = colour
                canvas.drawCircle(s[0], s[1], dp(3.5f), dot)
            }
            // One handle per side, at its middle: it moves that side only.
            for (i in 0 until 4) {
                val s = project(vp, (corners[i] + corners[(i + 1) % 4]) * 0.5f) ?: continue
                val r = if (hand && g == i) dp(12f) else dp(10f)
                dot.color = Color.WHITE
                canvas.drawCircle(s[0], s[1], r, dot)
                dot.color = if (hand && g == i) ACCENT else colour
                canvas.drawCircle(s[0], s[1], r - dp(2.5f), dot)
            }
            var text = (if (c.estimated) "≈ " else "") + sizeText(c.width, c.height)
            if (mode == Mode.WINDOW) c.sill?.let { text += " · sill ${m(it)}" }
            val mid = project(vp, (a + b + at + bt) * 0.25f) ?: return
            chip(canvas, mid[0], mid[1] - dp(14f), text, colour)
        }

        /** Tracked points as small dots, so you can see the walls being picked up. */
        private fun drawFramePoints(canvas: Canvas, snap: Snapshot) {
            val vp = snap.viewProj
            dot.color = Color.argb(200, 255, 255, 255)
            val r = dp(1.8f)
            for (p in snap.framePoints) {
                val s = project(vp, p) ?: continue
                canvas.drawCircle(s[0], s[1], r, dot)
            }
        }

        private fun drawSurfaces(canvas: Canvas, snap: Snapshot) {
            val vp = snap.viewProj
            for (pl in snap.planes) {
                val (fc, ec) = when (pl.kind) {
                    Surface.FLOOR -> FLOOR_FILL to FLOOR_EDGE
                    Surface.WALL -> WALL_FILL to WALL_EDGE
                    // Ceilings are drawn through walls and windows and only
                    // confuse; they are still used for the room height.
                    Surface.CEILING, Surface.OTHER -> continue
                }
                val screen = projectPolygon(vp, pl.points)
                if (screen.size < 3) continue
                path.reset()
                for ((i, s) in screen.withIndex()) {
                    if (i == 0) path.moveTo(s[0], s[1]) else path.lineTo(s[0], s[1])
                }
                path.close()
                fill.color = fc
                edge.color = ec
                canvas.drawPath(path, fill)
                canvas.drawPath(path, edge)
            }
        }

        private fun drawAutoRoom(canvas: Canvas, snap: Snapshot, room: AutoRoom) {
            val vp = snap.viewProj
            val n = room.corners.size
            for (i in 0 until n) {
                val (a, b) = projectSegment(vp, room.corners[i], room.corners[(i + 1) % n]) ?: continue
                val est = room.estimated[i]
                if (est) {
                    dashed.color = DOOR
                    canvas.drawLine(a[0], a[1], b[0], b[1], dashed)
                } else {
                    line.color = SNAP
                    canvas.drawLine(a[0], a[1], b[0], b[1], line)
                }
                chip(
                    canvas, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2,
                    m(room.side(i)) + if (est) " ?" else "",
                    if (est) DOOR_DEEP else SNAP_DEEP,
                )
            }
            // Corner posts.
            for (c in room.corners) {
                val a = project(vp, c) ?: continue
                val b = project(vp, c.withY(c.y + 0.6f))
                ring.color = SNAP
                if (b != null) canvas.drawLine(a[0], a[1], b[0], b[1], ring)
                dot.color = Color.WHITE
                canvas.drawCircle(a[0], a[1], dp(6f), dot)
                dot.color = SNAP
                canvas.drawCircle(a[0], a[1], dp(4f), dot)
            }
        }

        /**
         * Auto room scan, drawn like a room scanner's live view: every wall
         * found so far outlined in white on the camera image (where it meets
         * the floor, where it meets the ceiling, and up each end, so the
         * corners are white lines floor to ceiling), doors and windows as
         * white frames, and furniture as white boxes. It grows wall by wall
         * as the user turns round the room; once the room's outline is found,
         * that is drawn instead (sides not measured dashed).
         */
        private fun drawLiveWalls(canvas: Canvas, snap: Snapshot) {
            val vp = snap.viewProj
            val room = snap.autoRoom
            val wallPlanes = snap.planes.filter { it.kind == Surface.WALL }
            val fy = snap.floorY ?: room?.corners?.firstOrNull()?.y
                ?: wallPlanes.flatMap { it.points }.minOfOrNull { it.y } ?: return
            val segs: List<Pair<Vec3, Vec3>>
            val est: List<Boolean>
            if (room != null && room.corners.size >= 3) {
                val n = room.corners.size
                segs = (0 until n).map { room.corners[it].withY(fy) to room.corners[(it + 1) % n].withY(fy) }
                est = (0 until n).map { room.estimated[it] }
            } else {
                val (lines, _) = LivePlan.connectWalls(
                    LivePlan.mergeWalls(wallPlanes.mapNotNull { LivePlan.wallLine(it.points) }),
                )
                segs = lines.map { it.first.withY(fy) to it.second.withY(fy) }
                est = segs.map { false }
            }
            // The top: the ceiling when found, otherwise as high as the walls
            // have been seen (once that is clearly more than a skirting).
            val top = snap.ceilingY?.takeIf { it - fy > 1.5f }
                ?: wallPlanes.flatMap { it.points }.maxOfOrNull { it.y }?.takeIf { it - fy > 1.2f }
            fun edge(a: Vec3, b: Vec3, dashed: Boolean = false) {
                val (p, q) = projectSegment(vp, a, b) ?: return
                canvas.drawLine(p[0], p[1], q[0], q[1], liveShadow)
                canvas.drawLine(p[0], p[1], q[0], q[1], if (dashed) liveWallDash else liveWall)
            }
            for ((i, s) in segs.withIndex()) {
                val (a, b) = s
                edge(a, b, est[i])
                if (top != null) {
                    edge(a.withY(top), b.withY(top), est[i])
                    edge(a, a.withY(top))
                    edge(b, b.withY(top))
                } else {
                    // Not seen high enough yet: short posts at the ends.
                    edge(a, a.withY(fy + 0.5f))
                    edge(b, b.withY(fy + 0.5f))
                }
            }
            // Doors and windows: a white frame in their wall.
            for (o in openings) {
                val a = if (o.type == TYPE_DOOR) o.a.withY(fy) else o.a
                val b = if (o.type == TYPE_DOOR) o.b.withY(fy) else o.b
                val t = o.topY ?: continue
                edge(a, b)
                edge(a, a.withY(t))
                edge(b, b.withY(t))
                edge(a.withY(t), b.withY(t))
            }
            // Furniture found by the AI detector: a white box.
            for (f in furniture.confirmed()) {
                val base = FurnitureTracker.footprint(f).map { it.withY(fy) }
                val up = base.map { it.withY(fy + f.height) }
                for (k in 0 until 4) {
                    segment(canvas, vp, base[k], base[(k + 1) % 4], liveThin)
                    segment(canvas, vp, up[k], up[(k + 1) % 4], liveThin)
                    segment(canvas, vp, base[k], up[k], liveThin)
                }
            }
        }

        private fun drawCornerCandidates(canvas: Canvas, snap: Snapshot) {
            val vp = snap.viewProj
            val fy = snap.floorY
            for (c in snap.cornerCandidates) {
                val base = if (fy != null) c.withY(fy) else c
                val a = project(vp, base) ?: continue
                val b = project(vp, base.withY(base.y + 0.5f))
                ring.color = SNAP
                if (b != null) canvas.drawLine(a[0], a[1], b[0], b[1], ring)
                canvas.drawCircle(a[0], a[1], dp(9f), ring)
            }
        }

        /**
         * Top-down sketch of what has been marked so far. With the automatic
         * outline (and in Auto mode before there is one) also how the scan is
         * going: measured sides green, estimated ones amber and dashed, where
         * the camera is and looks, and a ring showing the directions covered.
         */
        private fun drawMiniMap(canvas: Canvas, aim: Aim?) {
            val snap = snapshot
            val auto = if (useAutoRoom()) snap?.autoRoom else null
            val corners = auto?.corners ?: this@ArMeasureActivity.corners
            val progress = snap != null && snap.tracking && useAutoRoom() && (auto != null || mode == Mode.AUTO)
            if (corners.isEmpty() && !progress) return
            val size = dp(120f)
            // Portrait: top right, under the instruction card. Landscape: the
            // bottom right holds the controls, so it goes under the card.
            val landscape = width > height
            val left = if (landscape) topBox.left.toFloat() else width - size - dp(16f)
            val top = topBox.bottom + dp(12f)
            canvas.drawRoundRect(left, top, left + size, top + size, dp(16f), dp(16f), mapBg)
            if ((mode == Mode.AUTO || mode == Mode.CORNER) && !lineOnly) miniRect.set(left, top, left + size, top + size)
            val hb = mapBorder.strokeWidth / 2
            canvas.drawRoundRect(left + hb, top + hb, left + size - hb, top + size - hb, dp(16f) - hb, dp(16f) - hb, mapBorder)

            val cam = if (progress) snap?.camPos else null
            val all = corners + openings.flatMap { listOf(it.a, it.b) } +
                listOfNotNull(aim?.p.takeIf { mode == Mode.CORNER }, cam)
            val minX = all.minOf { it.x }
            val maxX = all.maxOf { it.x }
            val minZ = all.minOf { it.z }
            val maxZ = all.maxOf { it.z }
            val span = max(max(maxX - minX, maxZ - minZ), 1f)
            // With the ring the sketch has to fit inside that circle.
            val pad = dp(if (progress) 23f else 14f)
            val scale = (size - 2 * pad) / span
            val ox = left + pad + ((size - 2 * pad) - (maxX - minX) * scale) / 2
            val oy = top + pad + ((size - 2 * pad) - (maxZ - minZ) * scale) / 2
            fun sx(p: Vec3) = ox + (p.x - minX) * scale
            fun sy(p: Vec3) = oy + (p.z - minZ) * scale

            if (progress && snap != null) {
                // The map has x to the right and z down, as the canvas measures
                // angles, so sector i is drawn where the camera looked.
                val r = size / 2 - dp(6f)
                val step = 360f / SECTORS
                for (i in 0 until SECTORS) {
                    mapArc.color = if (snap.sectors and (1 shl i) != 0) SNAP else Color.argb(64, 255, 255, 255)
                    canvas.drawArc(
                        left + size / 2 - r, top + size / 2 - r, left + size / 2 + r, top + size / 2 + r,
                        -180f + i * step + 3f, step - 6f, false, mapArc,
                    )
                }
            }

            if (corners.size >= 3) {
                path.reset()
                for ((i, c) in corners.withIndex()) if (i == 0) path.moveTo(sx(c), sy(c)) else path.lineTo(sx(c), sy(c))
                path.close()
                fill.color = Color.argb(46, 255, 255, 255)
                canvas.drawPath(path, fill)
            }
            if (auto != null) {
                val n = corners.size
                mapLine.color = SNAP
                for (i in 0 until n) {
                    val a = corners[i]
                    val b = corners[(i + 1) % n]
                    canvas.drawLine(sx(a), sy(a), sx(b), sy(b), if (auto.estimated[i]) mapEst else mapLine)
                }
                mapLine.color = Color.WHITE
            } else {
                for (i in 1 until corners.size) {
                    canvas.drawLine(sx(corners[i - 1]), sy(corners[i - 1]), sx(corners[i]), sy(corners[i]), mapLine)
                }
                if (corners.size >= 3) {
                    canvas.drawLine(
                        sx(corners.last()), sy(corners.last()), sx(corners.first()), sy(corners.first()), mapDash,
                    )
                }
                if (aim != null && mode == Mode.CORNER && corners.isNotEmpty()) {
                    canvas.drawLine(sx(corners.last()), sy(corners.last()), sx(aim.p), sy(aim.p), mapDash)
                }
            }
            for (o in openings) {
                mapLine.color = if (o.type == TYPE_DOOR) DOOR else WINDOW
                mapLine.strokeWidth = dp(4f)
                canvas.drawLine(sx(o.a), sy(o.a), sx(o.b), sy(o.b), mapLine)
            }
            mapLine.color = Color.WHITE
            mapLine.strokeWidth = dp(2f)
            dot.color = if (auto != null) Color.argb(200, 255, 255, 255) else ACCENT
            for (c in corners) canvas.drawCircle(sx(c), sy(c), dp(if (auto != null) 2f else 3.5f), dot)

            // Where the camera is, with a short line the way it looks.
            if (cam != null && snap != null) {
                val px = sx(cam)
                val py = sy(cam)
                val d = snap.ray.dir
                val h = sqrt(d.x * d.x + d.z * d.z)
                if (h > 0.2f) canvas.drawLine(px, py, px + d.x / h * dp(10f), py + d.z / h * dp(10f), mapLine)
                dot.color = Color.WHITE
                canvas.drawCircle(px, py, dp(3.5f), dot)
            }
        }

        /**
         * Room scan: the live 2D floor plan, in the lower part of the screen
         * (landscape: the right half), heading-up so the wall in front of the
         * phone is at its top. It shows the wall surfaces as they are picked
         * up, the room outline once there is one (measured walls solid with
         * their lengths, estimated ones amber and dashed), doors with their
         * swing and windows as found, the phone with its field of view and the
         * directions looked at so far, and the room's size and counts.
         */
        private fun drawLivePlan(canvas: Canvas, snap: Snapshot, aim: Aim? = null) {
            val landscape = width > height
            // Corner mode keeps the crosshair (screen centre) and its hints
            // clear: the plan starts further down (landscape: further right).
            val cornerMode = mode == Mode.CORNER
            val bottom = (if (panelBox.visibility == VISIBLE) panelBox.top.toFloat() else height.toFloat()) - dp(10f)
            val left: Float
            val right: Float
            val top: Float
            if (landscape) {
                left = width * if (cornerMode) 0.62f else 0.5f
                right = width - dp(12f) - insets[2]
                top = dp(12f) + insets[1]
            } else {
                left = dp(12f) + insets[0]
                right = width - dp(12f) - insets[2]
                top = max(topBox.bottom + dp(12f), if (cornerMode) height / 2f + dp(72f) else height * 0.40f)
            }
            if (bottom - top < dp(140f) || right - left < dp(140f)) {
                drawMiniMap(canvas, aim)
                return
            }
            planRect.set(left, top, right, bottom)
            val radius = dp(20f)
            canvas.drawRoundRect(planRect, radius, radius, planBg)
            canvas.drawRoundRect(planRect, radius, radius, mapBorder)
            canvas.save()
            canvas.clipRect(planRect)

            val header = dp(52f)
            // Corner mode: the walls marked so far, each drawn with its length
            // as it is marked, and a live line to the crosshair.
            val marking = mode == Mode.CORNER
            val marked = this@ArMeasureActivity.corners.map { it.withY(0f) }
            val room = if (marking) null else snap.autoRoom
            val corners = if (marking) marked else room?.corners ?: emptyList()
            val seen = if (snap.tracking) {
                LivePlan.mergeWalls(
                    snap.planes.filter { it.kind == Surface.WALL }.mapNotNull { LivePlan.wallLine(it.points) },
                )
            } else emptyList()
            val floors = snap.planes.filter { it.kind == Surface.FLOOR }
            val aimP = if (marking) aim?.p?.withY(0f) else null
            val pts = ArrayList<Vec3>()
            pts.addAll(corners)
            for ((a, b) in seen) { pts.add(a); pts.add(b) }
            for (o in openings) { pts.add(o.a); pts.add(o.b) }
            aimP?.let { pts.add(it) }
            val fwd = snap.camForward
            val t = LivePlan.fit(pts, snap.camPos, fwd, left, top + header, right, bottom, dp(26f))
            fun x(p: Vec3) = t.x(p)
            fun y(p: Vec3) = t.y(p)

            // 1 m grid, turning with the plan.
            val reach = (max(right - left, bottom - top) / t.scale).toInt() + 2
            val gx0 = kotlin.math.floor(t.cx).toInt()
            val gz0 = kotlin.math.floor(t.cz).toInt()
            for (k in -reach..reach) {
                val gx = (gx0 + k).toFloat()
                val gz = (gz0 + k).toFloat()
                val z0 = (gz0 - reach).toFloat()
                val z1 = (gz0 + reach).toFloat()
                val x0 = (gx0 - reach).toFloat()
                val x1 = (gx0 + reach).toFloat()
                canvas.drawLine(t.x(gx, z0), t.y(gx, z0), t.x(gx, z1), t.y(gx, z1), planGrid)
                canvas.drawLine(t.x(x0, gz), t.y(x0, gz), t.x(x1, gz), t.y(x1, gz), planGrid)
            }

            // Floor scanned so far.
            fill.color = FLOOR_FILL
            for (f in floors) {
                if (f.points.size < 3) continue
                path.reset()
                for ((i, p) in f.points.withIndex()) if (i == 0) path.moveTo(x(p), y(p)) else path.lineTo(x(p), y(p))
                path.close()
                canvas.drawPath(path, fill)
            }

            // Room outline.
            val n = corners.size
            var mx = 0f
            var mz = 0f
            for (c in corners) { mx += c.x; mz += c.z }
            // The user stands in the room, so before there is an outline the
            // phone is on the inside.
            val inside = if (n >= 3) Vec3(mx / n, 0f, mz / n) else snap.camPos
            val icx = x(inside)
            val icy = y(inside)

            // Walls found so far. Before the outline (Auto) they are drawn as
            // walls, each with its length, the moment they are found; once
            // there is an outline (or while marking) they stay faint.
            val seenAsWalls = !marking && n < 3
            if (seenAsWalls) {
                for ((a, b) in seen) canvas.drawLine(x(a), y(a), x(b), y(b), planWall)
            } else {
                planSeen.alpha = 70
                for ((a, b) in seen) canvas.drawLine(x(a), y(a), x(b), y(b), planSeen)
            }

            if (marking && n >= 2) {
                // Marked walls, the room not closed yet: solid, and dashed
                // back to the first corner once it could be closed.
                for (i in 1 until n) {
                    canvas.drawLine(x(corners[i - 1]), y(corners[i - 1]), x(corners[i]), y(corners[i]), planWall)
                }
                if (n >= 3) {
                    planThin.color = Color.argb(170, 255, 255, 255)
                    planThin.pathEffect = DashPathEffect(floatArrayOf(dp(5f), dp(5f)), 0f)
                    canvas.drawLine(x(corners.last()), y(corners.last()), x(corners[0]), y(corners[0]), planThin)
                    planThin.pathEffect = null
                }
            } else if (n >= 3) {
                path.reset()
                for ((i, c) in corners.withIndex()) if (i == 0) path.moveTo(x(c), y(c)) else path.lineTo(x(c), y(c))
                path.close()
                fill.color = Color.argb(26, 255, 255, 255)
                canvas.drawPath(path, fill)
                for (i in 0 until n) {
                    val a = corners[i]
                    val b = corners[(i + 1) % n]
                    val est = room!!.estimated[i]
                    canvas.drawLine(x(a), y(a), x(b), y(b), if (est) planEst else planWall)
                }
            }

            // Furniture found by the AI detector: its footprint and name.
            if (!marking) {
                for (f in furniture.confirmed()) {
                    val fp = FurnitureTracker.footprint(f)
                    path.reset()
                    for ((i, p) in fp.withIndex()) if (i == 0) path.moveTo(x(p), y(p)) else path.lineTo(x(p), y(p))
                    path.close()
                    fill.color = Color.argb(40, 255, 255, 255)
                    canvas.drawPath(path, fill)
                    planThin.color = Color.argb(150, 255, 255, 255)
                    canvas.drawPath(path, planThin)
                    val fm = planSub.fontMetrics
                    canvas.drawText(
                        f.kind, x(f.center) - planSub.measureText(f.kind) / 2,
                        y(f.center) - (fm.ascent + fm.descent) / 2, planSub,
                    )
                }
            }

            // Doors and windows: the wall cut open, then their symbol.
            for (o in openings) {
                val ax = x(o.a)
                val ay = y(o.a)
                val bx = x(o.b)
                val by = y(o.b)
                canvas.drawLine(ax, ay, bx, by, gap)
                if (o.type == TYPE_DOOR) {
                    val (leaf, arc) = LivePlan.doorSwing(o.a, o.b, inside)
                    planThin.color = DOOR
                    planThin.pathEffect = null
                    canvas.drawLine(ax, ay, x(leaf), y(leaf), planThin)
                    path.reset()
                    for ((i, p) in arc.withIndex()) if (i == 0) path.moveTo(x(p), y(p)) else path.lineTo(x(p), y(p))
                    planThin.pathEffect = DashPathEffect(floatArrayOf(dp(3f), dp(3f)), 0f)
                    canvas.drawPath(path, planThin)
                    planThin.pathEffect = null
                } else {
                    // Two thin lines along the wall, closed at the ends.
                    val l = kotlin.math.hypot(bx - ax, by - ay)
                    if (l < 1f) continue
                    val nx = -(by - ay) / l * dp(3.5f)
                    val ny = (bx - ax) / l * dp(3.5f)
                    planThin.color = WINDOW
                    path.reset()
                    path.moveTo(ax + nx, ay + ny); path.lineTo(bx + nx, by + ny)
                    path.lineTo(bx - nx, by - ny); path.lineTo(ax - nx, ay - ny); path.close()
                    canvas.drawPath(path, planThin)
                    canvas.drawLine(ax, ay, bx, by, planThin)
                }
            }

            // A wall's length in a pill beside its middle, on the side away
            // from the room.
            fun lengthLabel(a: Vec3, b: Vec3, text: String, bg: Int) {
                val sx = (x(a) + x(b)) / 2
                val sy = (y(a) + y(b)) / 2
                // Away from the inside along the wall's normal on screen.
                val lx = x(b) - x(a)
                val ly = y(b) - y(a)
                val l = kotlin.math.hypot(lx, ly)
                if (l < dp(18f)) return
                var nx = -ly / l
                var ny = lx / l
                if ((icx - sx) * nx + (icy - sy) * ny > 0) { nx = -nx; ny = -ny }
                val w = planLen.measureText(text) / 2 + dp(7f)
                val cx = sx + nx * dp(16f)
                val cy = sy + ny * dp(16f)
                labelBg.color = bg
                canvas.drawRoundRect(cx - w, cy - dp(10f), cx + w, cy + dp(10f), dp(10f), dp(10f), labelBg)
                val fm = planLen.fontMetrics
                canvas.drawText(text, cx, cy - (fm.ascent + fm.descent) / 2, planLen)
            }
            val labelInk = Color.argb(230, 30, 41, 59)

            // Wall lengths, outside the room.
            if (marking) {
                for (i in 1 until n) lengthLabel(corners[i - 1], corners[i], m(corners[i - 1].dist2d(corners[i])), labelInk)
            } else if (n >= 3) {
                for (i in 0 until n) {
                    val est = room!!.estimated[i]
                    val text = m(room.side(i)) + if (est) " ?" else ""
                    lengthLabel(corners[i], corners[(i + 1) % n], text, if (est) DOOR_DEEP else labelInk)
                }
            } else if (seenAsWalls) {
                for ((a, b) in seen) lengthLabel(a, b, m(a.dist2d(b)), labelInk)
            }

            // Corner mode: the wall being measured, from the last corner to
            // the crosshair, with its length as it changes; marked corners.
            if (marking) {
                val last = corners.lastOrNull()
                if (aimP != null && last != null) {
                    planThin.color = SNAP
                    planThin.strokeWidth = dp(3f)
                    planThin.pathEffect = DashPathEffect(floatArrayOf(dp(7f), dp(5f)), 0f)
                    canvas.drawLine(x(last), y(last), x(aimP), y(aimP), planThin)
                    planThin.pathEffect = null
                    planThin.strokeWidth = dp(2f)
                    lengthLabel(last, aimP, m(last.dist2d(aimP)), SNAP_DEEP)
                }
                dot.color = ACCENT
                for (c in corners) canvas.drawCircle(x(c), y(c), dp(4.5f), dot)
                if (aimP != null) {
                    ring.color = if (aim?.snappedCorner == true || aim?.closesRoom == true) SNAP else Color.WHITE
                    canvas.drawCircle(x(aimP), y(aimP), dp(6f), ring)
                }
            }

            // The phone: its field of view (forward is always up), the
            // directions looked at so far round it, and a dot.
            if (snap.tracking) {
                val px = x(snap.camPos)
                val py = y(snap.camPos)
                val reachFov = dp(70f)
                val half = reachFov * 0.58f // tan 30°
                path.reset()
                path.moveTo(px, py)
                path.lineTo(px - half, py - reachFov)
                path.lineTo(px + half, py - reachFov)
                path.close()
                fill.shader = android.graphics.LinearGradient(
                    px, py, px, py - reachFov, Color.argb(110, 47, 91, 255), Color.argb(0, 47, 91, 255),
                    android.graphics.Shader.TileMode.CLAMP,
                )
                canvas.drawPath(path, fill)
                fill.shader = null
                // Sector i covers world directions from -180° + 30° i (atan2(z, x)).
                val r = dp(22f)
                val step = 360f / SECTORS
                for (i in 0 until SECTORS) {
                    val a = Math.toRadians((-180.0 + (i + 0.5) * step)).toFloat()
                    val wx = snap.camPos.x + cos(a)
                    val wz = snap.camPos.z + sin(a)
                    val ang = Math.toDegrees(atan2((t.y(wx, wz) - py).toDouble(), (t.x(wx, wz) - px).toDouble())).toFloat()
                    mapArc.color = if (snap.sectors and (1 shl i) != 0) SNAP else Color.argb(60, 255, 255, 255)
                    canvas.drawArc(px - r, py - r, px + r, py + r, ang - step / 2 + 3f, step - 6f, false, mapArc)
                }
                dot.color = Color.WHITE
                canvas.drawCircle(px, py, dp(8f), dot)
                dot.color = ACCENT
                canvas.drawCircle(px, py, dp(5.5f), dot)
            }
            canvas.restore()

            // Header: size and area, then what was counted.
            val tx = left + dp(16f)
            val title = if (marking) {
                when {
                    n == 0 -> "Aim at a corner on the floor and mark it"
                    n == 1 -> "Now aim at the next corner"
                    else -> {
                        var total = 0f
                        for (i in 1 until n) total += corners[i - 1].dist2d(corners[i])
                        "${n - 1} wall${if (n == 2) "" else "s"}  ·  ${m(total)}" +
                            if (n >= 3) "  ·  ${area2(LivePlan.area(corners))}" else ""
                    }
                }
            } else if (room != null && n >= 3) {
                "${m(room.width)} × ${m(room.depth)}  ·  ${area2(LivePlan.area(corners))}"
            } else if (seen.isNotEmpty()) "${seen.size} wall${if (seen.size == 1) "" else "s"} found"
            else "Point at the walls to start the plan"
            canvas.drawText(title, tx, top + dp(24f), planText)
            val counts = elementsSummary() ?: "No doors or windows yet"
            canvas.drawText("$counts  ·  tap for camera", tx, top + dp(42f), planSub)
        }
    }

    companion object {
        /** Clip-space w (distance in front of the camera) below which scene
         *  lines and surfaces are cut off when drawn. */
        const val NEAR_W = 0.05f

        /** Limits for hits on the floor / ceiling beyond their detected area:
         *  at least about 8 degrees below (above) the horizon, at most 6 m away. */
        const val MIN_EXTEND_SLOPE = 0.14f
        const val MAX_EXTEND_DISTANCE = 6f
        private const val TAG = "RoomMeasureAR"
        private const val REQ_CAMERA = 1
        /** How long the complete auto room must hold still before the checkmark. */
        private const val AUTO_STABLE_MS = 2500L
        /** The same without a known floor: the scan finishes without a height. */
        private const val AUTO_STABLE_NO_FLOOR_MS = 6000L
        /** The same after a full round with a side or two still estimated. */
        private const val AUTO_STABLE_ROUND_MS = 8000L
        /** Yaw sectors (30° each) used to tell how far round the user has looked. */
        private const val SECTORS = 12
        /** Sectors (of [SECTORS]) seen before a room scan finishes by itself. */
        private const val LOOK_ROUND_SECTORS = SECTORS - 2
        /** How long the checkmark shows (and can be tapped away) before finishing. */
        private const val AUTO_FINISH_DELAY_MS = 800L
        const val EXTRA_XS = "xs"
        const val EXTRA_ZS = "zs"
        const val EXTRA_OPENINGS = "openings"
        /** Floor height (world y), only when known. */
        const val EXTRA_FLOOR_Y = "floorY"
        /** 8 values per door / window: type, ax, ay, az, bx, by, bz, topY
         *  (base points as tapped; topY is [NO_TOP] when not marked). */
        const val EXTRA_OPENING_DETAILS = "openingDetails"
        /** 9 values per surface: the tapped points A, B, C (x, y, z each). */
        const val EXTRA_SURFACES = "surfaces"
        /** 6 values per measured line: the tapped ends A, B (x, y, z each).
         *  Always present, may be empty. */
        const val EXTRA_LINES = "lines"
        /** Int array, 0 / 1 per line in [EXTRA_LINES] order: 1 when an end of
         *  the line was estimated rather than measured. Always present. */
        const val EXTRA_LINES_ESTIMATED = "linesEstimated"
        /** Furniture found by the AI detector: 6 values each (centre x, z,
         *  width, depth, height, yaw: the direction of its width as
         *  atan2(z, x)), with its kind in [EXTRA_ELEMENT_KINDS]. */
        const val EXTRA_ELEMENTS = "elements"
        const val EXTRA_ELEMENT_KINDS = "elementKinds"
        /** True when started with [EXTRA_START_MODE] "line": xs / zs are empty. */
        const val EXTRA_LINE_ONLY = "lineOnly"
        /** Int: index (in the openings order) of the door / window just
         *  added with ✓, which finished the scan. Only then. */
        const val EXTRA_FOCUS_OPENING = "focusOpening"
        /** In: [START_MODE_LINE] opens the scanner just to measure distances. */
        const val EXTRA_START_MODE = "startMode"
        const val START_MODE_LINE = "line"
        const val EXTRA_AUTO = "auto"
        const val EXTRA_ESTIMATED = "estimated"
        const val EXTRA_ERROR = "error"
        const val EXTRA_PLAYBACK = "playback"
        /** Int array, one per door / window in [EXTRA_OPENING_DETAILS] order:
         *  0 marked by hand (aimed), 1 found automatically, 2 marked with the
         *  phone (Touch). Always present. */
        const val EXTRA_OPENING_METHODS = "openingMethods"
        /** Int array, 0 / 1 per door / window in the same order: 1 when its
         *  wall or base was assumed rather than measured. Always present. */
        const val EXTRA_OPENING_ESTIMATED = "openingEstimated"
        /** Absolute paths of the AR photos taken (String array, may be empty). */
        const val EXTRA_PHOTOS = "photos"
        private const val MAX_CLOUD = 40000
        private const val MAX_VOXELS = 150000
        private const val VOXEL = 0.05f
        /** cos² of 15°: how far from a tapped direction scan points count. */
        private const val COS2_15 = 0.9330127f

        /** Lowest raw-depth confidence (0-255) used. */
        private const val CONF_MIN = 100

        const val TYPE_DOOR = 0
        const val TYPE_WINDOW = 1

        private const val H_CORNER = 0
        /** Door / window: first side marked. */
        private const val H_EDGE = 1
        /** Door / window kept without its top (mode switch or Finish). */
        private const val H_OPENING = 2
        // 3 was the removed room-height mark.
        /** Door / window: second side marked, waiting for the top. */
        private const val H_OPENING_BASE = 4
        /** Door / window: top marked, opening complete. */
        private const val H_OPENING_TOP = 5
        /** Surface: first or second corner marked. */
        private const val H_SURFACE_POINT = 6
        /** Surface: third point marked, surface complete. */
        private const val H_SURFACE = 7
        /** Line: first end marked. */
        private const val H_LINE_POINT = 8
        /** Line: second end marked, line complete. */
        private const val H_LINE = 9

        /** Door / window: found automatically and accepted (one step). */
        private const val H_OPENING_AUTO = 10

        /** How a door / window was measured ([EXTRA_OPENING_METHODS]). */
        const val METHOD_MANUAL = 0
        const val METHOD_AUTO = 1
        const val METHOD_TOUCH = 2

        /** Door / window Auto: time between attempts, how long a candidate
         *  stays shown, how long without one before giving advice, how long
         *  an accepted one is not offered again. */
        private const val OPENING_INTERVAL_MS = 200L
        /** Room scan: door / window attempts alternate kinds at this pace. */
        private const val ROOM_OPENING_INTERVAL_MS = 250L
        /** Room scan: smallest door / window side counted automatically (m). */
        private const val ROOM_MIN_OPENING = 0.5f
        /** How often the camera image goes to the AI furniture detector. */
        private const val FURNITURE_INTERVAL_MS = 700L
        private const val AUTO_FRESH_MS = 1500L

        /** A tap this soon after the result was stable still adds it. */
        private const val STABLE_GRACE_MS = 2500L
        private const val AUTO_GIVE_UP_MS = 3000L
        private const val ACCEPTED_IGNORE_MS = 2000L
        /** Diagnostics: at most one search image per interval; files kept. */
        private const val OPENING_DIAG_INTERVAL_MS = 3000L
        private const val OPENING_DIAG_KEEP = 30
        /** cos² of 10°: scan points around the crosshair for a wall estimate. */
        private const val COS2_10 = 0.96984631f

        /** topY in [EXTRA_OPENING_DETAILS] when no top was marked. */
        private const val NO_TOP = -999.0

        // ECM-AI palette.
        /** Ink #0B1426: text on white, the base of every panel. */
        private val INK = Color.rgb(11, 20, 38)
        /** Ink 2 #16213A: raised surfaces on ink. */
        private val INK2 = Color.rgb(22, 33, 58)
        /** Panels and floating controls: ink at 86 %. */
        private val PANEL = Color.argb(219, 11, 20, 38)
        /** Measurement chips: ink at 88 %. */
        private val CHIP = Color.argb(224, 11, 20, 38)
        /** Cards over the camera (room scanned, door / window added): ink at 94 %. */
        private val CARD = Color.argb(240, 11, 20, 38)
        /** Mini-map: ink at 80 %. */
        private val MAP_BG = Color.argb(204, 11, 20, 38)
        /** Hairline borders: white at 14 %. */
        private val HAIRLINE = Color.argb(36, 255, 255, 255)
        /** Tab / toggle track: white at 10 %; unselected labels: white at 80 %. */
        private val TRACK = Color.argb(26, 255, 255, 255)
        private val TAB_IDLE = Color.argb(204, 255, 255, 255)
        /** Brand / plan blue #2F5BFF: primary emphasis. */
        private val ACCENT = Color.rgb(47, 91, 255)
        /** Scan teal #12C2A4: detected, measured, snapped, success. */
        private val SNAP = Color.rgb(18, 194, 164)
        /** Teal deepened for chips carrying white text. */
        private val SNAP_DEEP = Color.argb(235, 10, 142, 120)
        private val ERROR = Color.rgb(229, 72, 77)
        /** Estimated / door amber #E08A0B. */
        private val DOOR = Color.rgb(224, 138, 11)
        /** Amber deepened for chips carrying white text. */
        private val DOOR_DEEP = Color.argb(235, 176, 104, 6)
        private val WINDOW = Color.rgb(14, 165, 233)
        private val SURFACE = Color.rgb(139, 92, 246)
        private val LINE = Color.rgb(250, 204, 21)
        private val FLOOR_FILL = Color.argb(46, 18, 194, 164)
        private val FLOOR_EDGE = Color.argb(140, 18, 194, 164)
        private val WALL_FILL = Color.argb(41, 47, 91, 255)
        private val WALL_EDGE = Color.argb(150, 120, 150, 255)
    }
}

private fun len(v: Vec3) = sqrt(v.dot(v))

/** The part of (c - a) perpendicular to the line through a and b (3D): from
 *  that line to c, the shortest way. */
private fun perpendicular(a: Vec3, b: Vec3, c: Vec3): Vec3 {
    val ab = b - a
    val ac = c - a
    val l2 = ab.dot(ab)
    if (l2 < 1e-9f) return ac
    return ac - ab * (ac.dot(ab) / l2)
}
