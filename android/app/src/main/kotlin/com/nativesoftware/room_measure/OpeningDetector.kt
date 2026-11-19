package com.nativesoftware.room_measure

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.Deflater
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

// Automatic door / window detection for the camera scanner. Kept free of
// Android and ARCore types so it can be unit tested on the JVM.
//
// The camera image is resampled onto the wall plane (1 cm per pixel), so a
// door or window frame becomes an axis-aligned rectangle whatever the angle it
// is seen from; its sides, top and bottom are then found as the strongest
// straight edges around the crosshair.

/**
 * The wall a door or window is looked for on: a vertical plane through
 * [origin] (the crosshair's foot on it) facing the camera.
 *
 * Wall coordinates: u runs horizontally along the wall (to the right as seen
 * from the camera), 0 at [origin]; v is the absolute world height.
 */
internal class WallFrame(val origin: Vec3, normal: Vec3, val floorY: Float?, val estimated: Boolean) {
    /** Horizontal unit normal, towards the camera. */
    val normal: Vec3

    /** Horizontal unit vector along the wall: up × normal. */
    val along: Vec3

    init {
        val l = sqrt(normal.x * normal.x + normal.z * normal.z)
        this.normal = if (l > 1e-6f) Vec3(normal.x / l, 0f, normal.z / l) else Vec3(0f, 0f, 1f)
        along = Vec3(this.normal.z, 0f, -this.normal.x)
    }

    /** World point of wall coordinates ([u], [v]). */
    fun world(u: Float, v: Float) = Vec3(origin.x + along.x * u, v, origin.z + along.z * u)

    /** u of world point [p] (projected onto the wall). */
    fun uOf(p: Vec3) = (p.x - origin.x) * along.x + (p.z - origin.z) * along.z

    /** The floor, or where it is assumed to be (1.4 m below the crosshair). */
    val base get() = floorY ?: (origin.y - 1.4f)
}

/**
 * Pinhole model of the CPU camera image: [worldToCamera] is a 4x4
 * column-major matrix (the inverse of the camera's sensor pose; x right, y up,
 * looking down -z), the intrinsics are in image pixels (x right, y down).
 */
internal class CameraModel(
    val worldToCamera: FloatArray,
    val fx: Float, val fy: Float, val cx: Float, val cy: Float,
    val width: Int, val height: Int,
)

/** Image brightness at a pixel position (bilinear), NaN outside the image. */
internal fun interface Luminance {
    fun at(x: Float, y: Float): Float
}

/** [Luminance] over an 8-bit image (the camera's Y plane), row by row. */
internal class ByteLuminance(val pixels: ByteArray, val width: Int, val height: Int) : Luminance {
    override fun at(x: Float, y: Float): Float {
        if (!(x >= 0f && y >= 0f && x <= width - 1f && y <= height - 1f)) return Float.NaN
        val x0 = min(x.toInt(), width - 2).coerceAtLeast(0)
        val y0 = min(y.toInt(), height - 2).coerceAtLeast(0)
        val fx = x - x0
        val fy = y - y0
        val i = y0 * width + x0
        val p00 = (pixels[i].toInt() and 0xFF).toFloat()
        val p10 = (pixels[i + 1].toInt() and 0xFF).toFloat()
        val p01 = (pixels[i + width].toInt() and 0xFF).toFloat()
        val p11 = (pixels[i + width + 1].toInt() and 0xFF).toFloat()
        val top = p00 + (p10 - p00) * fx
        val bottom = p01 + (p11 - p01) * fx
        return top + (bottom - top) * fy
    }
}

internal enum class OpeningKind { DOOR, WINDOW }

/**
 * A door or window found on a wall. [left], [right] are wall u, [bottom],
 * [top] world heights (all metres); [a] and [b] are its bottom-left and
 * bottom-right corners in world space. [sill] is the bottom's height above the
 * floor (windows, floor known). [estimated] when the wall or the bottom was
 * assumed rather than measured.
 */
internal class OpeningCandidate(
    val left: Float, val right: Float, val bottom: Float, val top: Float,
    val a: Vec3, val b: Vec3, val topY: Float,
    val width: Float, val height: Float, val sill: Float?,
    val strength: Float, val estimated: Boolean,
)

/**
 * The camera image resampled onto the wall: [width] x [height] cells of
 * [OpeningDetector.CELL] metres, row 0 at the top. Cells the camera did not see
 * are NaN.
 */
internal class RectifiedImage(
    val width: Int, val height: Int,
    /** u of the left edge, v of the bottom edge (metres). */
    val u0: Float, val v0: Float,
    val pixels: FloatArray,
) {
    val u1 get() = u0 + width * OpeningDetector.CELL
    val v1 get() = v0 + height * OpeningDetector.CELL
    fun u(col: Float) = u0 + (col + 0.5f) * OpeningDetector.CELL
    fun v(row: Float) = v1 - (row + 0.5f) * OpeningDetector.CELL
    fun col(u: Float) = (u - u0) / OpeningDetector.CELL - 0.5f
    fun row(v: Float) = (v1 - v) / OpeningDetector.CELL - 0.5f
    operator fun get(c: Int, r: Int) = pixels[r * width + c]
}

/** A detection with the edge profiles it was made from (for diagnostics). */
internal class OpeningDetection(
    val candidate: OpeningCandidate?,
    /** Mean vertical-edge strength per column over the opening's body. */
    val columnProfile: FloatArray,
    /** Mean horizontal-edge strength per row between the sides found (zeros when none). */
    val rowProfile: FloatArray,
)

internal object OpeningDetector {
    /** Rectified cell size (m). */
    const val CELL = 0.01f
    private const val U_HALF = 1.6f
    private const val BELOW_BASE = 0.10f
    private const val ABOVE_BASE = 2.80f

    /** A peak must be this many times the median of its search range... */
    private const val PROMINENCE = 2.5f
    /** ...which is taken as at least this (flat, noiseless walls)... */
    private const val MIN_MEDIAN = 0.5f
    /** ...and be at least this strong (Sobel / 8, luminance levels per cell). */
    private const val MIN_PEAK = 2.0f
    /** Edges of one frame or casing (its inner and outer edge) lie within this. */
    private const val CASING = 0.15f
    /** The sides are looked for at least this far from the crosshair. */
    private const val SIDE_GAP = 0.12f

    /**
     * Samples the camera image ([lum], described by [camera]) on the wall
     * [frame]: u from -1.6 to +1.6 m, v from 0.10 m below to 2.80 m above the
     * floor (or where it is assumed), 1 cm per cell.
     */
    fun rectify(frame: WallFrame, camera: CameraModel, lum: Luminance): RectifiedImage {
        val w = (2 * U_HALF / CELL + 0.5f).toInt()
        val h = ((BELOW_BASE + ABOVE_BASE) / CELL + 0.5f).toInt()
        val u0 = -U_HALF
        val v0 = frame.base - BELOW_BASE
        val v1 = v0 + h * CELL
        val m = camera.worldToCamera
        val o = frame.origin
        val ax = frame.along.x
        val az = frame.along.z
        val px = FloatArray(w * h)
        for (r in 0 until h) {
            val y = v1 - (r + 0.5f) * CELL
            for (c in 0 until w) {
                val u = u0 + (c + 0.5f) * CELL
                val x = o.x + ax * u
                val z = o.z + az * u
                val cz = m[2] * x + m[6] * y + m[10] * z + m[14]
                if (cz >= -0.1f) {
                    px[r * w + c] = Float.NaN
                    continue
                }
                val cx = m[0] * x + m[4] * y + m[8] * z + m[12]
                val cy = m[1] * x + m[5] * y + m[9] * z + m[13]
                val ix = camera.fx * (cx / -cz) + camera.cx
                val iy = camera.fy * (-cy / -cz) + camera.cy
                px[r * w + c] = lum.at(ix, iy)
            }
        }
        return RectifiedImage(w, h, u0, v0, px)
    }

    fun detect(kind: OpeningKind, frame: WallFrame, image: RectifiedImage): OpeningCandidate? =
        analyze(kind, frame, image).candidate

    private class Peak(val pos: Float, val value: Float, val prominence: Float)

    /** One edge or a group of parallel ones (casing): [pos] is the member
     *  nearest the crosshair, [score] the strongest member's prominence. */
    private class Edge(val pos: Float, val prominence: Float, val score: Float)

    fun analyze(kind: OpeningKind, frame: WallFrame, img: RectifiedImage): OpeningDetection {
        val w = img.width
        val h = img.height
        val n = w * h
        // Sobel gradients (/8: luminance levels per cell); 0 next to NaN.
        val gx = FloatArray(n)
        val gy = FloatArray(n)
        val valid = BooleanArray(n)
        val p = img.pixels
        for (r in 1 until h - 1) {
            for (c in 1 until w - 1) {
                val i = r * w + c
                val a = p[i - w - 1]
                val b = p[i - w]
                val cc = p[i - w + 1]
                val d = p[i - 1]
                val e = p[i]
                val f = p[i + 1]
                val g = p[i + w - 1]
                val hh = p[i + w]
                val k = p[i + w + 1]
                if (a.isNaN() || b.isNaN() || cc.isNaN() || d.isNaN() || e.isNaN() || f.isNaN() ||
                    g.isNaN() || hh.isNaN() || k.isNaN()
                ) continue
                valid[i] = true
                gx[i] = ((cc + 2 * f + k) - (a + 2 * d + g)) / 8f
                gy[i] = ((g + 2 * hh + k) - (a + 2 * b + cc)) / 8f
            }
        }
        val o = frame.origin
        val base = frame.base
        val door = kind == OpeningKind.DOOR

        fun rowsFor(vLo: Float, vHi: Float): IntRange {
            val r0 = ceil(img.row(vHi)).toInt().coerceIn(0, h - 1)
            val r1 = floor(img.row(vLo)).toInt().coerceIn(0, h - 1)
            return r0..r1
        }

        fun colsFor(uLo: Float, uHi: Float): IntRange {
            val c0 = ceil(img.col(uLo)).toInt().coerceIn(0, w - 1)
            val c1 = floor(img.col(uHi)).toInt().coerceIn(0, w - 1)
            return c0..c1
        }

        // Vertical edges, column by column, over the opening's body.
        val body = if (door) rowsFor(base + 0.3f, base + 1.8f) else rowsFor(o.y - 0.3f, o.y + 0.5f)
        val colProfile = FloatArray(w)
        val minRows = max(10, (body.last - body.first + 1) / 5)
        for (c in 0 until w) {
            var sum = 0f
            var cnt = 0
            for (r in body) {
                val i = r * w + c
                if (!valid[i]) continue
                cnt++
                val ax = abs(gx[i])
                if (ax > 2 * abs(gy[i])) sum += ax
            }
            colProfile[c] = if (cnt >= minRows) sum / cnt else 0f
        }
        val rowProfile = FloatArray(h)
        fun fail() = OpeningDetection(null, colProfile, rowProfile)

        // Sides.
        val lefts = edges(peaks(colProfile, colsFor(-U_HALF, -SIDE_GAP), img::u), 0f)
        val rights = edges(peaks(colProfile, colsFor(SIDE_GAP, U_HALF), img::u), 0f)
        val (minW, maxW) = if (door) 0.55f to 2.0f else 0.3f to 3.0f
        var bestL: Edge? = null
        var bestR: Edge? = null
        var bestScore = -1f
        for (l in lefts) for (rt in rights) {
            val width = rt.pos - l.pos
            if (width < minW || width > maxW) continue
            val s = l.score + rt.score
            if (s > bestScore) {
                bestScore = s
                bestL = l
                bestR = rt
            }
        }
        val left = bestL ?: return fail()
        val right = bestR ?: return fail()

        // Horizontal edges, row by row, between the sides.
        val inner = colsFor(left.pos + 0.03f, right.pos - 0.03f)
        val minCols = max(5, (inner.last - inner.first + 1) / 5)
        for (r in 0 until h) {
            var sum = 0f
            var cnt = 0
            for (c in inner) {
                val i = r * w + c
                if (!valid[i]) continue
                cnt++
                val ay = abs(gy[i])
                if (ay > 2 * abs(gx[i])) sum += ay
            }
            rowProfile[r] = if (cnt >= minCols) sum / cnt else 0f
        }

        // Top: the edge nearest the crosshair of the strongest group.
        val topRange = when {
            !door -> rowsFor(o.y + 0.15f, o.y + 1.8f)
            frame.floorY != null -> rowsFor(frame.floorY + 1.8f, frame.floorY + 2.6f)
            else -> rowsFor(o.y + 0.6f, o.y + 1.5f)
        }
        val top = edges(peaks(rowProfile, topRange, img::v), o.y).maxByOrNull { it.score } ?: return fail()

        // Bottom.
        var bottomEstimated = false
        var bottomProm: Float? = null
        val bottom: Float
        if (door) {
            val fy = frame.floorY
            if (fy != null) {
                bottom = fy
            } else {
                // The floor line under the door, near where the floor is assumed.
                val pk = peaks(rowProfile, rowsFor(img.v0, base + 0.4f), img::v).maxByOrNull { it.prominence }
                if (pk != null) {
                    bottom = pk.pos
                    bottomProm = pk.prominence
                } else {
                    bottom = base
                    bottomEstimated = true
                }
            }
        } else {
            val lo = frame.floorY?.let { max(o.y - 1.6f, it + 0.05f) } ?: (o.y - 1.6f)
            val hi = o.y - 0.1f
            if (hi <= lo) return fail()
            val e = edges(peaks(rowProfile, rowsFor(lo, hi), img::v), o.y).maxByOrNull { it.score } ?: return fail()
            bottom = e.pos
            bottomProm = e.prominence
        }

        val height = top.pos - bottom
        val sill = if (door) null else frame.floorY?.let { bottom - it }
        val plausible = if (door) height in 1.7f..2.7f
        else height in 0.25f..2.6f && (sill == null || sill in 0f..1.8f)
        if (!plausible) return fail()
        var strength = min(min(left.prominence, right.prominence), top.prominence)
        bottomProm?.let { strength = min(strength, it) }
        val cand = OpeningCandidate(
            left.pos, right.pos, bottom, top.pos,
            frame.world(left.pos, bottom), frame.world(right.pos, bottom), top.pos,
            right.pos - left.pos, height, sill, strength,
            frame.estimated || bottomEstimated,
        )
        return OpeningDetection(cand, colProfile, rowProfile)
    }

    /**
     * Prominent local maxima of [profile] within [range] (indices), with
     * sub-cell positions from a parabola fit, converted to metres by [toPos].
     */
    private fun peaks(profile: FloatArray, range: IntRange, toPos: (Float) -> Float): List<Peak> {
        if (range.isEmpty() || range.last - range.first < 2) return emptyList()
        val vals = FloatArray(range.last - range.first + 1) { profile[range.first + it] }
        vals.sort()
        val med = if (vals.size % 2 == 1) vals[vals.size / 2] else (vals[vals.size / 2 - 1] + vals[vals.size / 2]) / 2f
        val floorVal = max(med, MIN_MEDIAN)
        val out = ArrayList<Peak>()
        for (i in range) {
            if (i < 1 || i > profile.size - 2) continue
            val v = profile[i]
            val l = profile[i - 1]
            val r = profile[i + 1]
            if (v < MIN_PEAK || v < l || v <= r) continue
            val prom = v / floorVal
            if (prom < PROMINENCE) continue
            val den = l - 2 * v + r
            val off = if (den < 0f) (0.5f * (l - r) / den).coerceIn(-0.5f, 0.5f) else 0f
            out.add(Peak(toPos(i + off), v, prom))
        }
        return out
    }

    /**
     * Groups peaks lying within [CASING] of a stronger one (the parallel
     * edges of one casing or frame), strongest group first; each group is
     * represented by its member nearest [ref] (the crosshair), the opening's
     * inside edge.
     */
    private fun edges(peaks: List<Peak>, ref: Float): List<Edge> {
        val left = peaks.sortedByDescending { it.prominence }.toMutableList()
        val out = ArrayList<Edge>()
        while (left.isNotEmpty()) {
            val strongest = left[0]
            val members = left.filter { abs(it.pos - strongest.pos) <= CASING }
            left.removeAll(members)
            val rep = members.minByOrNull { abs(it.pos - ref) } ?: strongest
            out.add(Edge(rep.pos, rep.prominence, strongest.prominence))
        }
        return out
    }

    /** [img] as an 8-bit grayscale PNG (NaN as black), for diagnostics. */
    fun grayPng(img: RectifiedImage): ByteArray {
        val w = img.width
        val h = img.height
        val raw = ByteArray((w + 1) * h)
        for (r in 0 until h) {
            raw[r * (w + 1)] = 0 // filter: none
            for (c in 0 until w) {
                val v = img[c, r]
                raw[r * (w + 1) + 1 + c] = (if (v.isNaN()) 0 else v.toInt().coerceIn(0, 255)).toByte()
            }
        }
        val deflater = Deflater()
        deflater.setInput(raw)
        deflater.finish()
        val z = ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (!deflater.finished()) z.write(buf, 0, deflater.deflate(buf))
        deflater.end()
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10))
        fun int(v: Int) = byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())
        fun chunk(type: String, data: ByteArray) {
            out.write(int(data.size))
            val t = type.toByteArray(Charsets.US_ASCII)
            out.write(t)
            out.write(data)
            val crc = CRC32()
            crc.update(t)
            crc.update(data)
            out.write(int(crc.value.toInt()))
        }
        // Width, height, bit depth 8, colour type 0 (grayscale), deflate,
        // adaptive filtering, no interlace.
        chunk("IHDR", int(w) + int(h) + byteArrayOf(8, 0, 0, 0, 0))
        chunk("IDAT", z.toByteArray())
        chunk("IEND", ByteArray(0))
        return out.toByteArray()
    }
}

/**
 * Agreement between successive detections while the camera is held on a door
 * or window: the last [capacity] candidates found on the same wall (within
 * 10 cm / 10°) around the same spot (centres within 20 cm). Stable once at
 * least 4 agree with the per-edge median within 2 cm; that median is the
 * result. A candidate elsewhere drops the others.
 */
internal class OpeningConsensus(private val capacity: Int = 8) {
    private class Entry(val frame: WallFrame, val c: OpeningCandidate)

    class State(val candidate: OpeningCandidate, val frame: WallFrame, val stable: Boolean, val count: Int, val agreeing: Int)

    private val entries = ArrayList<Entry>()

    var state: State? = null
        private set

    val size get() = entries.size

    fun clear() {
        entries.clear()
        state = null
    }

    fun add(frame: WallFrame, c: OpeningCandidate): State {
        val centre = centre(c)
        // Whether earlier detections are the same opening is decided by where
        // it is, not by the wall estimate: an estimated wall jitters between
        // frames, and dropping the detections whenever it moved meant the
        // result rarely stayed stable long enough to be added.
        entries.removeAll { e -> len(centre(e.c) - centre) > SAME_OPENING }
        entries.add(Entry(frame, c))
        while (entries.size > capacity) entries.removeAt(0)
        // Every edge in the latest frame's wall coordinates.
        val ls = entries.map { frame.uOf(it.c.a) }
        val rs = entries.map { frame.uOf(it.c.b) }
        val bs = entries.map { it.c.bottom }
        val ts = entries.map { it.c.top }
        val l = median(ls)
        val r = median(rs)
        val b = median(bs)
        val t = median(ts)
        var agreeing = 0
        for (i in entries.indices) {
            if (abs(ls[i] - l) <= AGREE && abs(rs[i] - r) <= AGREE && abs(bs[i] - b) <= AGREE && abs(ts[i] - t) <= AGREE) {
                agreeing++
            }
        }
        val sills = entries.mapNotNull { it.c.sill }
        val med = OpeningCandidate(
            l, r, b, t, frame.world(l, b), frame.world(r, b), t, r - l, t - b,
            if (sills.isEmpty()) null else median(sills),
            median(entries.map { it.c.strength }), c.estimated,
        )
        val s = State(med, frame, agreeing >= MIN_AGREE, entries.size, agreeing)
        state = s
        return s
    }

    private fun centre(c: OpeningCandidate) = Vec3((c.a.x + c.b.x) / 2f, (c.bottom + c.top) / 2f, (c.a.z + c.b.z) / 2f)

    private fun len(v: Vec3) = sqrt(v.dot(v))

    private fun median(v: List<Float>): Float {
        val s = v.sorted()
        return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2f
    }

    companion object {
        /** Detections whose centres are this close are the same opening. */
        const val SAME_OPENING = 0.30f
        private const val AGREE = 0.02f
        const val MIN_AGREE = 4
    }
}
