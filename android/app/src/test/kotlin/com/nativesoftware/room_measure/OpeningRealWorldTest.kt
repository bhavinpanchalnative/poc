package com.nativesoftware.room_measure

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.util.Random
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Doors and windows with the details real ones have, which the plain scenes
 * of [OpeningDetectorTest] lack: a handle and panels on the door leaf (once
 * taken for the frame's inside edge, 12-24 cm too small), a skirting board,
 * a mullion and transom in the window (once taken for the frame, cutting
 * the window in half), low contrast and blur.
 */
class OpeningRealWorldTest {
    private val fx = 1450f; private val fy = 1450f; private val cx = 960f; private val cy = 720f
    private val imgW = 1920; private val imgH = 1440
    private val wallNormal = Vec3(sin(0.4f), 0f, cos(0.4f))
    private val wallAlong = Vec3(wallNormal.z, 0f, -wallNormal.x)
    private val wallPoint = Vec3(0.7f, 0f, -1.2f)

    class Feat(
        val panels: Boolean = false, val mullion: Boolean = false, val transom: Boolean = false,
        val skirting: Boolean = false, val lowContrast: Boolean = false, val blur: Boolean = false,
        val wallErr: Float = 0f, val offsetU: Float = 0.05f, val camH: Float = 1.4f,
        /** The assumed wall is also turned by this much (degrees). */
        val wallTurn: Float = 0f,
        /** The wall was guessed rather than detected. */
        val guessed: Boolean = false,
        /** Floor tiles: grout lines parallel to the wall. */
        val grout: Boolean = false,
    )

    private fun cross(a: Vec3, b: Vec3) = Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    private fun norm(v: Vec3) = v * (1f / sqrt(v.dot(v)))
    private fun wallU(p: Vec3) = (p - wallPoint).dot(wallAlong)

    private fun shade(door: Boolean, f: Feat, l: Float, r: Float, b: Float, t: Float, origin: Vec3, dir: Vec3): Float {
        val wall = 180f
        val casing = if (f.lowContrast) 168f else 140f
        val frame = if (f.lowContrast) 195f else 220f
        val tFloor = if (dir.y < -1e-6f) -origin.y / dir.y else Float.MAX_VALUE
        val denom = wallNormal.dot(dir)
        val tWall = if (denom < -1e-6f) (wallPoint - origin).dot(wallNormal) / denom else Float.MAX_VALUE
        if (tFloor < tWall) {
            if (f.grout) {
                // Grout lines every 60 cm from a cut tile 25 cm out from the wall.
                val dist = (origin + dir * tFloor - wallPoint).dot(wallNormal)
                val k = (dist - 0.25f) / 0.6f
                if (dist > 0.2f && kotlin.math.abs(k - kotlin.math.round(k)) * 0.6f < 0.005f) return 95f
            }
            return 120f
        }
        if (tWall == Float.MAX_VALUE) return 0f
        val hit = origin + dir * tWall
        val u = wallU(hit); val v = hit.y
        val inO = u >= l && u <= r && v >= b && v <= t
        if (door) {
            if (inO) {
                if (f.panels) {
                    val m = 0.12f
                    val mid = (b + t) / 2f + 0.1f
                    val inP = u > l + m && u < r - m && ((v > b + 0.15f && v < mid - 0.06f) || (v > mid + 0.06f && v < t - m))
                    if (inP) return 75f
                }
                if (u in (r - 0.12f)..(r - 0.06f) && v in 0.95f..1.1f) return 230f // handle
                return 90f
            }
            if (u >= l - 0.07f && u <= r + 0.07f && v <= t + 0.07f) return casing
        } else {
            if (inO) {
                if (f.mullion && kotlin.math.abs(u - (l + r) / 2f) < 0.03f) return frame
                if (f.transom && kotlin.math.abs(v - (t - 0.35f)) < 0.03f) return frame
                return 60f
            }
            if (u >= l - 0.08f && u <= r + 0.08f && v >= b - 0.08f && v <= t + 0.08f) return frame
        }
        if (f.skirting && v < 0.10f) return 230f
        return wall
    }

    private fun run(name: String, door: Boolean, width: Float, bottom: Float, top: Float, d: Float, yawDeg: Float, pitchDeg: Float, f: Feat) {
        val yaw = Math.toRadians(yawDeg.toDouble()).toFloat()
        val pitch = Math.toRadians(pitchDeg.toDouble()).toFloat()
        val up = Vec3(0f, 1f, 0f)
        val fh = norm(wallNormal * -1f * cos(yaw) + wallAlong * sin(yaw))
        val camPos = (wallPoint + wallNormal * d + wallAlong * 0.3f).withY(f.camH)
        val fw = norm(fh * cos(pitch) + up * sin(pitch))
        val xd = norm(cross(fh, up)); val zd = fw * -1f; val yd = cross(zd, xd)
        val xs = yd; val ys = xd * -1f; val zs = zd
        val m = FloatArray(16)
        m[0] = xs.x; m[4] = xs.y; m[8] = xs.z; m[12] = -xs.dot(camPos)
        m[1] = ys.x; m[5] = ys.y; m[9] = ys.z; m[13] = -ys.dot(camPos)
        m[2] = zs.x; m[6] = zs.y; m[10] = zs.z; m[14] = -zs.dot(camPos); m[15] = 1f
        val tt = (wallPoint - camPos).dot(wallNormal) / wallNormal.dot(fw)
        val origin = camPos + fw * tt
        val uc = wallU(origin) + f.offsetU
        val l = uc - width / 2; val r = uc + width / 2
        val rnd = Random(3)
        val raw = FloatArray(imgW * imgH)
        for (j in 0 until imgH) for (i in 0 until imgW) {
            val dir = norm(xs * ((i - cx) / fx) + ys * (-(j - cy) / fy) - zs)
            raw[j * imgW + i] = shade(door, f, l, r, bottom, top, camPos, dir)
        }
        val img = ByteArray(imgW * imgH)
        for (j in 0 until imgH) for (i in 0 until imgW) {
            var s = raw[j * imgW + i]
            if (f.blur && i in 2 until imgW - 2 && j in 2 until imgH - 2) {
                s = 0f; for (a in -2..2) for (bb in -2..2) s += raw[(j + a) * imgW + i + bb]; s /= 25f
            }
            img[j * imgW + i] = (s + rnd.nextGaussian().toFloat() * 4f).toInt().coerceIn(0, 255).toByte()
        }
        // The wall plane as the scanner estimates it: f.wallErr m nearer the
        // camera, turned by f.wallTurn about the crosshair point.
        val turn = Math.toRadians(f.wallTurn.toDouble()).toFloat()
        val n2 = norm(wallNormal * cos(turn) + wallAlong * sin(turn))
        val o2 = origin + wallNormal * f.wallErr
        val frame = WallFrame(o2, n2, 0f, f.guessed)
        val cam = CameraModel(m, fx, fy, cx, cy, imgW, imgH)
        val res = OpeningDetector.measure(if (door) OpeningKind.DOOR else OpeningKind.WINDOW, frame, cam, ByteLuminance(img, imgW, imgH))
        res.floorLine?.let { println(String.format("   floor line: moved %+.3f m, turned %.1f deg, %d strips", it.moved, it.turned, it.strips)) }
        val c = res.detection.candidate
        val h = top - bottom
        assertNotNull("$name: not found", c)
        c!!
        println(String.format("%-28s true %.2f x %.2f -> %.3f x %.3f", name, width, h, c.width, c.height))
        assertEquals("$name width", width, c.width, TOL)
        assertEquals("$name height", h, c.height, TOL)
        if (!door) assertEquals("$name sill", bottom, c.sill!!, TOL)
        assertEquals("$name flagged as estimated", false, c.estimated)
    }

    @Test fun doorWithHandle() = run("door with handle", true, 0.82f, 0f, 2.03f, 2.2f, 10f, -5f, Feat())

    @Test fun panelledDoor() = run("panelled door", true, 0.82f, 0f, 2.03f, 2.2f, 10f, -5f, Feat(panels = true))

    @Test fun panelledDoorAimedOffCentre() =
        run("panelled door off-centre", true, 0.82f, 0f, 2.03f, 2.2f, 10f, -5f, Feat(panels = true, offsetU = 0.25f))

    @Test fun panelledDoorWithSkirting() =
        run("panelled door, skirting", true, 0.82f, 0f, 2.03f, 2.2f, 0f, -5f, Feat(panels = true, skirting = true))

    @Test fun doorLowContrastBlurred() =
        run("door low contrast, blur", true, 0.82f, 0f, 2.03f, 2.2f, 10f, -5f, Feat(lowContrast = true, blur = true))

    @Test fun wideDoorClose() = run("wide door close", true, 0.95f, 0f, 2.10f, 1.6f, 0f, 0f, Feat(panels = true))

    @Test fun doorPhoneHeldLowPitchedUp() =
        run("door, phone low", true, 0.82f, 0f, 2.03f, 2.4f, 0f, 10f, Feat(camH = 1.0f, panels = true))

    @Test fun windowWithMullion() = run("window, mullion", false, 1.2f, 0.9f, 2.0f, 2.3f, 10f, -5f, Feat(mullion = true))

    @Test fun windowWithMullionAndTransom() =
        run("window, mullion + transom", false, 1.2f, 0.9f, 2.0f, 2.3f, 10f, 0f, Feat(mullion = true, transom = true))

    @Test fun windowMullionAimedOffCentre() =
        run("window, mullion off-centre", false, 1.2f, 0.9f, 2.0f, 2.3f, 0f, 0f, Feat(mullion = true, offsetU = 0.2f))

    @Test fun wideWindowWithMullion() = run("wide window, mullion", false, 1.8f, 0.8f, 2.1f, 2.6f, 0f, 0f, Feat(mullion = true))

    @Test fun windowLowContrastBlurred() =
        run("window low contrast, blur", false, 1.2f, 0.9f, 2.0f, 2.3f, 10f, -5f, Feat(lowContrast = true, blur = true))

    @Test fun smallWindow() = run("small window", false, 0.6f, 1.2f, 1.8f, 2.0f, 0f, 0f, Feat())

    // The wall plane off: detected a few cm out (corrected by the floor line),
    // or only guessed, tens of cm out and turned.

    @Test fun doorWallDetected5cmTooNear() =
        run("door, wall 5 cm near", true, 0.82f, 0f, 2.03f, 2.2f, 10f, -5f, Feat(wallErr = 0.05f))

    @Test fun doorWallDetected5cmTooFar() =
        run("door, wall 5 cm far", true, 0.82f, 0f, 2.03f, 2.2f, 10f, -5f, Feat(wallErr = -0.05f, skirting = true))

    @Test fun doorWallDetectedTurned() =
        run("door, wall turned 6 deg", true, 0.82f, 0f, 2.03f, 2.4f, 0f, -5f, Feat(wallErr = 0.04f, wallTurn = 6f, panels = true))

    @Test fun doorWallGuessedFarOut() =
        run("door, wall guessed 40 cm near", true, 0.82f, 0f, 2.03f, 2.6f, 15f, -5f, Feat(wallErr = 0.40f, wallTurn = 15f, guessed = true))

    @Test fun doorWallGuessedTooFarWithTiles() = run(
        "door, wall guessed 25 cm far, tiles", true, 0.82f, 0f, 2.03f, 2.2f, -10f, -8f,
        Feat(wallErr = -0.25f, wallTurn = -12f, guessed = true, grout = true, skirting = true, panels = true),
    )

    @Test fun windowWallDetected5cmTooNear() =
        run("window, wall 5 cm near", false, 1.2f, 0.9f, 2.0f, 2.6f, 10f, -3f, Feat(wallErr = 0.05f))

    @Test fun windowWallGuessed() = run(
        "window, wall guessed 30 cm near", false, 1.2f, 0.9f, 2.0f, 2.8f, 0f, -2f,
        Feat(wallErr = 0.30f, wallTurn = 10f, guessed = true, skirting = true, mullion = true),
    )

    companion object {
        private const val TOL = 0.015f
    }
}
