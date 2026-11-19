package com.nativesoftware.room_measure

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * Renders synthetic camera images of a painted wall with a door or window
 * (ray-cast per pixel, with sensor noise), then checks that rectifying the
 * image onto the wall and detecting the frame gives its true size.
 */
class OpeningDetectorTest {

    // Camera: 1920 x 1440 sensor image, as ARCore's CPU image intrinsics.
    private val fx = 1450f
    private val fy = 1450f
    private val cx = 960f
    private val cy = 720f
    private val imgW = 1920
    private val imgH = 1440
    private val camHeight = 1.4f

    // The wall: through wallPoint, facing +normal, at an arbitrary angle in
    // the world. The floor is y = 0.
    private val wallAngle = 0.4f
    private val wallNormal = Vec3(sin(wallAngle), 0f, cos(wallAngle))
    private val wallAlong = Vec3(wallNormal.z, 0f, -wallNormal.x)
    private val wallPoint = Vec3(0.7f, 0f, -1.2f)

    private enum class Scene { DOOR, OPEN_DOORWAY, WINDOW, PLAIN }

    private class Opening(val left: Float, val right: Float, val bottom: Float, val top: Float)

    private class View(val frame: WallFrame, val camera: CameraModel, val image: ByteArray)

    private fun cross(a: Vec3, b: Vec3) = Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)

    private fun norm(v: Vec3): Vec3 {
        val l = sqrt(v.dot(v))
        return v * (1f / l)
    }

    /** Wall u of world point [p]. */
    private fun wallU(p: Vec3) = (p - wallPoint).dot(wallAlong)

    /**
     * Brightness seen along a ray: the wall with its door / window, the
     * floor, and (open doorway) a farther wall 2 m behind the opening.
     */
    private fun shade(scene: Scene, o: Opening, origin: Vec3, dir: Vec3): Float {
        val tFloor = if (dir.y < -1e-6f) -origin.y / dir.y else Float.MAX_VALUE
        val denom = wallNormal.dot(dir)
        val tWall = if (denom < -1e-6f) (wallPoint - origin).dot(wallNormal) / denom else Float.MAX_VALUE
        if (tFloor < tWall) return FLOOR
        if (tWall == Float.MAX_VALUE) return 0f
        val hit = origin + dir * tWall
        val u = wallU(hit)
        val v = hit.y
        val inOpening = u >= o.left && u <= o.right && v >= o.bottom && v <= o.top
        return when (scene) {
            Scene.PLAIN -> WALL
            Scene.DOOR, Scene.OPEN_DOORWAY -> when {
                inOpening && scene == Scene.DOOR -> LEAF
                inOpening -> {
                    // Through the doorway: the floor continues to a wall 2 m behind.
                    val farPoint = wallPoint - wallNormal * 2f
                    val tFar = (farPoint - origin).dot(wallNormal) / denom
                    if (tFloor < tFar) FLOOR else FAR_WALL
                }
                // Casing, 7 cm wide, on both sides and the top.
                u >= o.left - 0.07f && u <= o.right + 0.07f && v <= o.top + 0.07f -> CASING
                else -> WALL
            }
            Scene.WINDOW -> when {
                inOpening -> GLASS
                // Frame, 8 cm wide, all round.
                u >= o.left - 0.08f && u <= o.right + 0.08f && v >= o.bottom - 0.08f && v <= o.top + 0.08f -> FRAME
                else -> WALL
            }
        }
    }

    /**
     * Renders the wall seen from [distance] m (perpendicular), the camera
     * 1.4 m high, turned [yawDeg] off the wall's normal and pitched
     * [pitchDeg] (up positive). [portrait]: the phone held upright, so the
     * sensor's long side (image x) is vertical. The opening is placed with
     * its centre [offsetU] m right of the crosshair; [opening] gives its
     * bottom / top and width.
     */
    private fun render(
        scene: Scene, width: Float, bottom: Float, top: Float,
        distance: Float, yawDeg: Float, pitchDeg: Float, portrait: Boolean,
        floorKnown: Boolean = true, offsetU: Float = 0.05f, seed: Long = 1,
    ): Pair<View, Opening> {
        val yaw = Math.toRadians(yawDeg.toDouble()).toFloat()
        val pitch = Math.toRadians(pitchDeg.toDouble()).toFloat()
        val up = Vec3(0f, 1f, 0f)
        // Horizontal forward: -normal turned by yaw about up.
        val n = wallNormal * -1f
        val fh = norm(n * cos(yaw) + wallAlong * sin(yaw))
        val camPos = (wallPoint + wallNormal * distance + wallAlong * 0.3f).withY(camHeight)
        val f = norm(fh * cos(pitch) + up * sin(pitch))
        val xd = norm(cross(fh, up))
        val zd = f * -1f
        val yd = cross(zd, xd)
        // Sensor axes: portrait holds the sensor turned by 90° about z.
        val xs = if (portrait) yd else xd
        val ys = if (portrait) xd * -1f else yd
        val zs = zd
        val m = FloatArray(16)
        m[0] = xs.x; m[4] = xs.y; m[8] = xs.z; m[12] = -xs.dot(camPos)
        m[1] = ys.x; m[5] = ys.y; m[9] = ys.z; m[13] = -ys.dot(camPos)
        m[2] = zs.x; m[6] = zs.y; m[10] = zs.z; m[14] = -zs.dot(camPos)
        m[15] = 1f

        // The crosshair's foot on the wall.
        val t = (wallPoint - camPos).dot(wallNormal) / wallNormal.dot(f)
        val origin = camPos + f * t
        val uc = wallU(origin) + offsetU
        val o = Opening(uc - width / 2, uc + width / 2, bottom, top)

        val rnd = Random(seed)
        val img = ByteArray(imgW * imgH)
        for (j in 0 until imgH) {
            for (i in 0 until imgW) {
                val dx = (i - cx) / fx
                val dy = -(j - cy) / fy
                val dir = norm(xs * dx + ys * dy - zs)
                val l = shade(scene, o, camPos, dir) + rnd.nextGaussian().toFloat() * 3f
                img[j * imgW + i] = l.toInt().coerceIn(0, 255).toByte()
            }
        }
        val frame = WallFrame(origin, wallNormal, if (floorKnown) 0f else null, false)
        return View(frame, CameraModel(m, fx, fy, cx, cy, imgW, imgH), img) to o
    }

    private fun detect(kind: OpeningKind, v: View): OpeningCandidate? {
        val img = OpeningDetector.rectify(v.frame, v.camera, ByteLuminance(v.image, imgW, imgH))
        return OpeningDetector.detect(kind, v.frame, img)
    }

    private fun checkDoor(
        distance: Float, yaw: Float, pitch: Float, portrait: Boolean,
        scene: Scene = Scene.DOOR, floorKnown: Boolean = true,
    ) {
        val (view, o) = render(scene, 0.82f, 0f, 2.03f, distance, yaw, pitch, portrait, floorKnown)
        val c = detect(OpeningKind.DOOR, view)
        val what = "door d=$distance yaw=$yaw pitch=$pitch portrait=$portrait $scene floor=$floorKnown"
        assertNotNull("$what: not found", c)
        c!!
        println(String.format("%s: %.3f x %.3f (strength %.1f)", what, c.width, c.height, c.strength))
        assertEquals("$what width", 0.82f, c.width, TOL)
        assertEquals("$what height", 2.03f, c.height, TOL)
        assertEquals("$what left", o.left, wallU(c.a), TOL)
        // World corners on the wall at the right place.
        assertEquals("$what a on wall", 0f, (c.a - wallPoint).dot(wallNormal), 0.005f)
        assertEquals("$what top", 2.03f, c.topY, TOL)
        assertEquals("$what estimated", false, c.estimated)
    }

    private fun checkWindow(distance: Float, yaw: Float, pitch: Float, portrait: Boolean, floorKnown: Boolean = true) {
        val (view, _) = render(Scene.WINDOW, 1.20f, 0.90f, 2.00f, distance, yaw, pitch, portrait, floorKnown)
        val c = detect(OpeningKind.WINDOW, view)
        val what = "window d=$distance yaw=$yaw pitch=$pitch portrait=$portrait floor=$floorKnown"
        assertNotNull("$what: not found", c)
        c!!
        println(String.format("%s: %.3f x %.3f sill %s (strength %.1f)", what, c.width, c.height, c.sill?.let { String.format("%.3f", it) }, c.strength))
        assertEquals("$what width", 1.20f, c.width, TOL)
        assertEquals("$what height", 1.10f, c.height, TOL)
        assertEquals("$what bottom", 0.90f, c.bottom, TOL)
        if (floorKnown) assertEquals("$what sill", 0.90f, c.sill!!, TOL) else assertNull(c.sill)
    }

    @Test fun doorFacingPitchedDown() = checkDoor(2.0f, 0f, -10f, true)

    @Test fun doorYawed15() = checkDoor(2.4f, 15f, 0f, true)

    @Test fun doorYawed25PitchedUp() = checkDoor(2.8f, 25f, 10f, true)

    @Test fun doorYawedOtherWay() = checkDoor(2.3f, -20f, -5f, true)

    @Test fun doorLandscape() = checkDoor(2.8f, 10f, 0f, false)

    @Test fun doorFloorUnknown() = checkDoor(2.5f, 10f, -5f, true, floorKnown = false)

    @Test fun openDoorway() = checkDoor(2.2f, 20f, -5f, true, scene = Scene.OPEN_DOORWAY)

    @Test fun openDoorwayFacing() = checkDoor(2.6f, 0f, 0f, true, scene = Scene.OPEN_DOORWAY)

    @Test fun windowPitchedDown() = checkWindow(2.0f, 0f, -10f, true)

    @Test fun windowYawed20PitchedUp() = checkWindow(2.6f, 20f, 5f, true)

    @Test fun windowLandscapeYawed25() = checkWindow(2.8f, 25f, 0f, false)

    @Test fun windowFloorUnknown() = checkWindow(2.3f, 10f, -5f, true, floorKnown = false)

    @Test
    fun plainWallHasNoDoorOrWindow() {
        for ((d, yaw, pitch) in listOf(Triple(2.4f, 10f, 0f), Triple(2.0f, 0f, -10f), Triple(2.8f, 25f, 10f))) {
            val (view, _) = render(Scene.PLAIN, 0.82f, 0f, 2.03f, d, yaw, pitch, true, seed = 7)
            assertNull("door on plain wall d=$d yaw=$yaw", detect(OpeningKind.DOOR, view))
            assertNull("window on plain wall d=$d yaw=$yaw", detect(OpeningKind.WINDOW, view))
        }
    }

    @Test
    fun consensusBecomesStableAndResetsElsewhere() {
        val frame = WallFrame(Vec3(0f, 1.2f, 0f), Vec3(0f, 0f, 1f), 0f, false)
        fun cand(f: WallFrame, l: Float, r: Float, t: Float) = OpeningCandidate(
            l, r, 0f, t, f.world(l, 0f), f.world(r, 0f), t, r - l, t, null, 5f, false,
        )
        val c = OpeningConsensus()
        val jitter = listOf(0f, 0.004f, -0.006f, 0.003f)
        for ((i, j) in jitter.withIndex()) {
            // The crosshair moves a little between frames: the wall origin shifts.
            val f = WallFrame(Vec3(0.02f * i, 1.2f, 0f), Vec3(0f, 0f, 1f), 0f, false)
            val s = c.add(f, cand(f, -0.40f + j - 0.02f * i, 0.42f + j - 0.02f * i, 2.03f + j))
            assertEquals(i == jitter.lastIndex, s.stable)
        }
        val s = c.state!!
        assertEquals(0.82f, s.candidate.width, 0.01f)
        assertEquals(2.03f, s.candidate.height, 0.01f)
        // Pointing at another door 1.5 m along: starts again.
        val s2 = c.add(frame, cand(frame, 1.1f, 1.9f, 2.0f))
        assertEquals(1, s2.count)
        assertTrue(!s2.stable)
    }

    @Test
    fun pngHasHeader() {
        val img = RectifiedImage(3, 2, 0f, 0f, floatArrayOf(0f, 128f, 255f, Float.NaN, 10f, 20f))
        val png = OpeningDetector.grayPng(img)
        assertEquals(0x89.toByte(), png[0])
        assertEquals('P'.code.toByte(), png[1])
        assertTrue(png.size > 40)
        assertTrue(abs(png.size) < 200)
    }

    companion object {
        private const val TOL = 0.015f
        private const val WALL = 180f
        private const val LEAF = 90f
        private const val CASING = 140f
        private const val FLOOR = 120f
        private const val FAR_WALL = 160f
        private const val GLASS = 60f
        private const val FRAME = 220f
    }
}
