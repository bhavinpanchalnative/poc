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

/**
 * A wall placed by [OpeningDetector.wallFromFloorLine]: [moved] is how far
 * the crosshair's point moved (m, negative: towards the camera), [turned]
 * how much the wall turned (degrees), [strips] how many 10 cm strips
 * showed the floor line.
 */
internal class FloorLineWall(val frame: WallFrame, val moved: Float, val turned: Float, val strips: Int)

/** The result of [OpeningDetector.measure]: the wall used (corrected by the
 *  floor line when [floorLine] is set), the image rectified on it and the
 *  detection. */
internal class Measured(
    val frame: WallFrame, val image: RectifiedImage, val detection: OpeningDetection, val floorLine: FloorLineWall?,
)

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
    /** Below the floor too: when the wall is assumed too far away, the line
     *  where it meets the floor shows up below the floor's height. */
    private const val BELOW_BASE = 0.35f
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
    /** A casing's inside edge is at least this share of its strongest edge. */
    private const val CASING_SHARE = 0.45f
    /** A farther edge replacing a window bar is at least this share of its score. */
    private const val BAR_STEP_SHARE = 0.5f

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

    /**
     * One automatic attempt: rectifies the camera image on [frame] and looks
     * for the door / window; then places the wall by the line where it meets
     * the floor ([wallFromFloorLine]) and, if that moved it, looks again on
     * the corrected wall. A wall that was only guessed ([WallFrame.estimated])
     * may move up to 1.5 m and turn up to 30 degrees, and is then measured;
     * a detected wall surface only up to 8 cm and 8 degrees, so that a
     * misread line can never make it worse by more than its own error.
     */
    fun measure(kind: OpeningKind, frame: WallFrame, camera: CameraModel, lum: Luminance, wide: Boolean = false): Measured {
        val find = { f: WallFrame, i: RectifiedImage -> if (wide) search(kind, f, i) else analyze(kind, f, i) }
        val img = rectify(frame, camera, lum)
        val det = find(frame, img)
        val c = det.candidate
        val fl = wallFromFloorLine(frame, camera, img, c?.left ?: Float.NaN, c?.right ?: Float.NaN)
        val ok = fl != null && if (frame.estimated) abs(fl.moved) <= 1.5f && fl.turned <= 30f
        else abs(fl.moved) <= 0.08f && fl.turned <= 8f
        if (fl == null || !ok || (abs(fl.moved) < 0.003f && fl.turned < 0.3f && !frame.estimated)) {
            return Measured(frame, img, det, null)
        }
        val img2 = rectify(fl.frame, camera, lum)
        return Measured(fl.frame, img2, find(fl.frame, img2), fl)
    }

    /** Horizontal aims tried by [search], nearest the crosshair first (m). */
    private val SEARCH_U = floatArrayOf(0f, -0.5f, 0.5f, -1.0f, 1.0f)
    /** Window aim heights tried by [search] above a known floor (m). */
    private val SEARCH_WINDOW_V = floatArrayOf(1.3f, 1.0f, 1.6f)

    /**
     * Room scan: the door / window nearest the crosshair, not only one
     * around it. While a room is scanned the camera sweeps along the walls,
     * often aimed at the corners or where the walls meet the floor, so a
     * door or window is seldom right under the crosshair, and a window
     * hardly ever at its height. [analyze] is tried with the aim moved
     * along the wall ([SEARCH_U]) and, for windows over a known floor, to
     * the heights windows are at ([SEARCH_WINDOW_V]); the first detection
     * (nearest the crosshair) wins. The image is the same: only where the
     * frame is looked for changes.
     */
    fun search(kind: OpeningKind, frame: WallFrame, img: RectifiedImage): OpeningDetection {
        val grad = gradients(img)
        val heights = ArrayList<Float>()
        heights.add(frame.origin.y)
        val fy = frame.floorY
        if (kind == OpeningKind.WINDOW && fy != null) {
            for (dv in SEARCH_WINDOW_V) {
                val y = fy + dv
                if (heights.none { abs(it - y) < 0.2f }) heights.add(y)
            }
        }
        var first: OpeningDetection? = null
        for (y in heights) {
            val f = if (y == frame.origin.y) frame else WallFrame(frame.origin.withY(y), frame.normal, fy, frame.estimated)
            for (du in SEARCH_U) {
                val d = analyze(kind, f, img, du, grad)
                if (first == null) first = d
                if (d.candidate != null) return d
            }
        }
        return first!!
    }

    /** Sobel gradients of a rectified image (/8: luminance levels per
     *  cell); [valid] false (and 0) next to a cell the camera did not see. */
    internal class Gradients(val gx: FloatArray, val gy: FloatArray, val valid: BooleanArray)

    fun gradients(img: RectifiedImage): Gradients {
        val w = img.width
        val h = img.height
        val n = w * h
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
        return Gradients(gx, gy, valid)
    }

    private class Peak(val pos: Float, val value: Float, val prominence: Float)

    /** One edge or a group of parallel ones (casing): [pos] is the member
     *  nearest the crosshair, [outer] the one farthest from it, [score] the
     *  strongest member's prominence. */
    private class Edge(val pos: Float, val prominence: Float, val score: Float, val outer: Float = pos)

    /**
     * Looks for the door / window around the aim: the crosshair's foot
     * ([frame].origin) moved [uRef] m along the wall; its sides are looked
     * for left and right of that point.
     */
    fun analyze(
        kind: OpeningKind, frame: WallFrame, img: RectifiedImage, uRef: Float = 0f, grad: Gradients = gradients(img),
    ): OpeningDetection {
        val w = img.width
        val h = img.height
        val gx = grad.gx
        val gy = grad.gy
        val valid = grad.valid
        val p = img.pixels
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
        val scratch = FloatArray(max(w, h))
        for (c in 0 until w) {
            var cnt = 0
            for (r in body) {
                val i = r * w + c
                if (!valid[i]) continue
                val ax = abs(gx[i])
                scratch[cnt++] = if (ax > 2 * abs(gy[i])) ax else 0f
            }
            colProfile[c] = if (cnt >= minRows) cappedMean(scratch, cnt) else 0f
        }
        val rowProfile = FloatArray(h)
        fun fail() = OpeningDetection(null, colProfile, rowProfile)

        // Sides.
        val lefts = edges(peaks(colProfile, colsFor(uRef - U_HALF, uRef - SIDE_GAP), img::u), uRef)
        val rights = edges(peaks(colProfile, colsFor(uRef + SIDE_GAP, uRef + U_HALF), img::u), uRef)
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
        var left = bestL ?: return fail()
        var right = bestR ?: return fail()

        // Mean brightness of the cells within u [uA, uB], v [vA, vB] (either order).
        fun band(uA: Float, uB: Float, vA: Float, vB: Float): Float {
            val cs = colsFor(min(uA, uB), max(uA, uB))
            val rs = rowsFor(min(vA, vB), max(vA, vB))
            var s = 0f
            var cnt = 0
            for (r in rs) for (c in cs) {
                val x = p[r * w + c]
                if (x.isNaN()) continue
                s += x
                cnt++
            }
            return if (cnt > 0) s / cnt else Float.NaN
        }

        /**
         * Whether the edge group from [inner] to [outer] (along one axis,
         * outward = sign of outer - inner) is a bar inside a window (a
         * mullion or transom: glass on both sides of it) rather than the
         * frame (wall beyond it). [at] gives the band's mean brightness for an
         * interval of that axis.
         */
        fun isBar(inner: Float, outer: Float, at: (Float, Float) -> Float): Boolean {
            val span = outer - inner
            if (abs(span) < 0.02f) return false
            val dir = if (span > 0f) 1f else -1f
            val inside = at(inner - dir * 0.10f, inner - dir * 0.03f)
            val bar = at(inner + dir * 0.01f, outer - dir * 0.01f)
            val beyond = at(outer + dir * 0.03f, outer + dir * 0.10f)
            if (inside.isNaN() || bar.isNaN() || beyond.isNaN()) return false
            val contrast = abs(bar - inside)
            return contrast >= 8f && abs(beyond - inside) < 0.35f * contrast
        }

        /** Windows: the nearest strong edge beyond a bar, else [e]. */
        fun pastBars(e: Edge, candidates: List<Edge>, at: (Float, Float) -> Float, ok: (Edge) -> Boolean): Edge {
            var cur = e
            repeat(3) {
                if (!isBar(cur.pos, cur.outer, at)) return cur
                val dir = if (cur.outer > cur.pos) 1f else -1f
                val next = candidates
                    .filter { (it.pos - cur.outer) * dir > 0.02f && it.score >= BAR_STEP_SHARE * cur.score && ok(it) }
                    .minByOrNull { abs(it.pos - cur.outer) } ?: return cur
                cur = next
            }
            return cur
        }

        if (!door) {
            val bodyLo = img.v(body.last.toFloat())
            val bodyHi = img.v(body.first.toFloat())
            val colBand = { a: Float, b: Float -> band(a, b, bodyLo, bodyHi) }
            val r0 = right
            left = pastBars(left, lefts, colBand) { r0.pos - it.pos <= maxW }
            val l0 = left
            right = pastBars(right, rights, colBand) { it.pos - l0.pos <= maxW }
        }

        // Horizontal edges, row by row, between the sides.
        val inner = colsFor(left.pos + 0.03f, right.pos - 0.03f)
        val minCols = max(5, (inner.last - inner.first + 1) / 5)
        for (r in 0 until h) {
            var cnt = 0
            for (c in inner) {
                val i = r * w + c
                if (!valid[i]) continue
                val ay = abs(gy[i])
                scratch[cnt++] = if (ay > 2 * abs(gx[i])) ay else 0f
            }
            rowProfile[r] = if (cnt >= minCols) cappedMean(scratch, cnt) else 0f
        }

        // Top: the edge nearest the crosshair of the strongest group.
        val topRange = when {
            !door -> rowsFor(o.y + 0.15f, o.y + 1.8f)
            frame.floorY != null -> rowsFor(frame.floorY + 1.8f, frame.floorY + 2.6f)
            else -> rowsFor(o.y + 0.6f, o.y + 1.5f)
        }
        val tops = edges(peaks(rowProfile, topRange, img::v), o.y)
        val rowBand = { a: Float, b: Float -> band(left.pos + 0.03f, right.pos - 0.03f, a, b) }
        val top = tops.maxByOrNull { it.score }?.let { if (door) it else pastBars(it, tops, rowBand) { true } }
            ?: return fail()

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
                val pk = peaks(rowProfile, rowsFor(base - 0.10f, base + 0.4f), img::v).maxByOrNull { it.prominence }
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
            val sills = edges(peaks(rowProfile, rowsFor(lo, hi), img::v), o.y)
            val e = sills.maxByOrNull { it.score }?.let { pastBars(it, sills, rowBand) { true } } ?: return fail()
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
     * Mean of the first [n] values of [v] (reordered), each capped at their
     * 75th percentile: an edge counts by how strong it is along most of its
     * length, so a short bright feature (a door handle, a light switch)
     * next to a frame does not outweigh the frame's own edge.
     */
    private fun cappedMean(v: FloatArray, n: Int): Float {
        if (n == 0) return 0f
        java.util.Arrays.sort(v, 0, n)
        val cap = v[min(n - 1, (n * 3) / 4)]
        var s = 0f
        for (i in 0 until n) s += min(v[i], cap)
        return s / n
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
            // Only edges about as strong as the casing's own count as its
            // inside edge: a door handle or the moulding of a panel a few cm
            // inside the frame is weaker and would make the door too small.
            val strong = members.filter { it.value >= CASING_SHARE * strongest.value }
            val rep = strong.minByOrNull { abs(it.pos - ref) } ?: strongest
            val outer = strong.maxByOrNull { abs(it.pos - ref) } ?: strongest
            out.add(Edge(rep.pos, rep.prominence, strongest.prominence, outer.pos))
        }
        return out
    }

    /**
     * The wall where it really is, from the line along which it meets the
     * floor (its base or skirting), or null when that line is not seen
     * clearly.
     *
     * Door and window sizes are measured on the wall plane, so a wall
     * assumed d cm too near or too far makes them d / distance too small or
     * too large, and a guessed wall (no surface detected) can be off by tens
     * of cm. The floor, though, is known accurately. Each 10 cm strip of
     * [img] (rectified on [frame]) is searched for horizontal edges near the
     * floor's height; the camera ray through each edge meets the floor where
     * that edge really is. Those floor points line up along the wall's base:
     * a line through them gives the wall's true position and direction.
     * Strips over the opening ([skipLo]..[skipHi], wall u) are left out: an
     * open door shows the next room's floor.
     *
     * Of the lines found, the best supported is used, unless one about as
     * well supported lies 4-30 cm nearer the camera: a skirting's top edge
     * seen as a floor line lands behind the wall, and the floor line in
     * front of it is the wall's base.
     */
    fun wallFromFloorLine(
        frame: WallFrame, camera: CameraModel, img: RectifiedImage,
        skipLo: Float = Float.NaN, skipHi: Float = Float.NaN,
    ): FloorLineWall? {
        val fy = frame.floorY ?: return null
        val m = camera.worldToCamera
        val t0 = m[12]
        val t1 = m[13]
        val t2 = m[14]
        val cam = Vec3(
            -(m[0] * t0 + m[1] * t1 + m[2] * t2),
            -(m[4] * t0 + m[5] * t1 + m[6] * t2),
            -(m[8] * t0 + m[9] * t1 + m[10] * t2),
        )
        if (cam.y - fy < 0.4f) return null
        val w = img.width
        val h = img.height
        val p = img.pixels
        val r0 = ceil(img.row(fy + 0.45f)).toInt().coerceIn(1, h - 2)
        val r1 = floor(img.row(fy - 0.30f)).toInt().coerceIn(1, h - 2)
        if (r1 - r0 < 6) return null

        class Sample(val x: Float, val z: Float, val weight: Float, val strip: Int, val u: Float)
        val samples = ArrayList<Sample>()
        val strip = 10
        val profile = FloatArray(h)
        var s = 0
        var c0 = 1
        while (c0 + strip < w - 1) {
            val uMid = img.u(c0 + strip / 2f)
            val skip = !skipLo.isNaN() && uMid > skipLo - 0.10f && uMid < skipHi + 0.10f
            if (!skip) {
                profile.fill(0f)
                for (r in r0..r1) {
                    var sum = 0f
                    var n = 0
                    for (c in c0 until c0 + strip) {
                        val i = r * w + c
                        val a = p[i - w - 1]; val b = p[i - w]; val cc = p[i - w + 1]
                        val d = p[i - 1]; val f = p[i + 1]
                        val g = p[i + w - 1]; val hh = p[i + w]; val k = p[i + w + 1]
                        val gx = ((cc + 2 * f + k) - (a + 2 * d + g)) / 8f
                        val gy = ((g + 2 * hh + k) - (a + 2 * b + cc)) / 8f
                        if (gx.isNaN() || gy.isNaN()) continue
                        n++
                        val ay = abs(gy)
                        if (ay > 2 * abs(gx)) sum += ay
                    }
                    profile[r] = if (n >= strip / 2) sum / n else 0f
                }
                for (pk in peaks(profile, r0..r1, img::v).sortedByDescending { it.value }.take(3)) {
                    val q = frame.world(uMid, pk.pos)
                    val dir = q - cam
                    if (dir.y > -1e-3f) continue
                    val t = (fy - cam.y) / dir.y
                    val x = cam.x + dir.x * t
                    val z = cam.z + dir.z * t
                    val dist = sqrt((x - cam.x) * (x - cam.x) + (z - cam.z) * (z - cam.z))
                    if (dist < 0.3f || dist > 10f) continue
                    samples.add(Sample(x, z, pk.value, s, uMid))
                }
            }
            c0 += strip
            s++
        }
        if (samples.size < 4) return null

        class Line(val px: Float, val pz: Float, val nx: Float, val nz: Float, val support: Float, val inliers: List<Sample>)
        // Every pair of samples from strips at least 30 cm apart proposes a
        // line; its support is the summed strength of the strips with a
        // sample within 3 cm of it (each strip's nearest one).
        val lines = ArrayList<Line>()
        val maxTilt = 0.42f // sin(25 degrees): roughly along the assumed wall
        for (i in samples.indices) for (j in i + 1 until samples.size) {
            val a = samples[i]
            val b = samples[j]
            if (abs(a.u - b.u) < 0.3f) continue
            val l = sqrt((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z))
            if (l < 0.2f) continue
            val dx = (b.x - a.x) / l
            val dz = (b.z - a.z) / l
            if (abs(dx * frame.normal.x + dz * frame.normal.z) > maxTilt) continue
            val nx = -dz
            val nz = dx
            val best = HashMap<Int, Sample>()
            for (q in samples) {
                val e = abs((q.x - a.x) * nx + (q.z - a.z) * nz)
                if (e > 0.03f) continue
                val cur = best[q.strip]
                if (cur == null || q.weight > cur.weight) best[q.strip] = q
            }
            if (best.size < 4) continue
            val inl = best.values.toList()
            if (inl.maxOf { it.u } - inl.minOf { it.u } < 0.5f) continue
            lines.add(Line(a.x, a.z, nx, nz, inl.sumOf { it.weight.toDouble() }.toFloat(), inl))
        }
        val top = lines.maxByOrNull { it.support } ?: return null
        // Distance of a line from the camera along the assumed wall's normal.
        fun depth(l: Line) = abs((l.px - cam.x) * l.nx + (l.pz - cam.z) * l.nz)
        val chosen = lines
            .filter { it.support >= 0.6f * top.support && abs(it.nx * top.nx + it.nz * top.nz) > 0.996f }
            .filter { depth(top) - depth(it) in 0.04f..0.30f }
            .maxByOrNull { it.support } ?: top

        // Least-squares line through the chosen inliers.
        val inl = chosen.inliers
        val mx = inl.sumOf { it.x.toDouble() }.toFloat() / inl.size
        val mz = inl.sumOf { it.z.toDouble() }.toFloat() / inl.size
        var sxx = 0f
        var sxz = 0f
        var szz = 0f
        for (q in inl) {
            val dx = q.x - mx
            val dz = q.z - mz
            sxx += dx * dx
            sxz += dx * dz
            szz += dz * dz
        }
        val ang = 0.5f * kotlin.math.atan2(2f * sxz, sxx - szz)
        var nx = -kotlin.math.sin(ang)
        var nz = kotlin.math.cos(ang)
        // Facing the camera.
        if ((cam.x - mx) * nx + (cam.z - mz) * nz < 0f) {
            nx = -nx
            nz = -nz
        }
        // The crosshair's point: where its ray (camera to the old origin)
        // meets the new wall.
        val o = frame.origin
        val ray = o - cam
        val den = ray.x * nx + ray.z * nz
        if (abs(den) < 1e-3f) return null
        val k = ((mx - cam.x) * nx + (mz - cam.z) * nz) / den
        if (k <= 0f) return null
        val origin = cam + ray * k
        val moved = (origin - o).let { sqrt(it.x * it.x + it.z * it.z) }
        val turned = Math.toDegrees(kotlin.math.acos((nx * frame.normal.x + nz * frame.normal.z).coerceIn(-1f, 1f).toDouble())).toFloat()
        return FloorLineWall(WallFrame(origin, Vec3(nx, 0f, nz), fy, false), moved * if (k < 1f) -1f else 1f, turned, inl.size)
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
internal class OpeningConsensus(
    private val capacity: Int = 8,
    /** Edges agree within this (m). */
    private val agree: Float = AGREE,
    /** Stable once this many agree. */
    private val minAgree: Int = MIN_AGREE,
) {
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
            if (abs(ls[i] - l) <= agree && abs(rs[i] - r) <= agree && abs(bs[i] - b) <= agree && abs(ts[i] - t) <= agree) {
                agreeing++
            }
        }
        val sills = entries.mapNotNull { it.c.sill }
        val med = OpeningCandidate(
            l, r, b, t, frame.world(l, b), frame.world(r, b), t, r - l, t - b,
            if (sills.isEmpty()) null else median(sills),
            median(entries.map { it.c.strength }), c.estimated,
        )
        val s = State(med, frame, agreeing >= minAgree, entries.size, agreeing)
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

        /**
         * For counting during a room scan. There the camera sweeps past a
         * door or window instead of being held on it, so 4 detections within
         * 2 cm (about 2 s held still) were seldom reached and nothing was
         * counted. 3 within 4 cm still rejects one-off misreads; the size can
         * be refined afterwards in Door / Window mode or by hand.
         */
        fun forRoomScan() = OpeningConsensus(capacity = 6, agree = 0.04f, minAgree = 3)
    }
}

/**
 * Doors and windows counted automatically while a room is scanned (Auto
 * mode): which steady detections are real doors / windows, and which repeat
 * one already counted. Free of Android types so it can be unit tested.
 */
internal object RoomOpeningCounter {
    /** Detections whose centres are closer than this (m) are one opening. */
    const val DUPLICATE = 0.5f

    /** Whether a steady detection has a door's or a window's proportions
     *  (and, when the floor is known, sits where one would). Anything else
     *  (a picture frame, a wardrobe front, a radiator) is not counted. */
    fun plausible(kind: OpeningKind, c: OpeningCandidate, floorY: Float?): Boolean = when (kind) {
        OpeningKind.DOOR ->
            c.width in 0.6f..1.4f && c.height in 1.75f..2.5f &&
                (floorY == null || abs(c.bottom - floorY) <= 0.12f)
        OpeningKind.WINDOW ->
            c.width in 0.35f..3.2f && c.height in 0.35f..2.3f &&
                (floorY == null || (c.bottom - floorY) in 0.15f..1.9f)
    }

    /**
     * Whether door detection [door] is really the window [window] found in
     * the same image: the door's bottom is taken at the floor, so a window's
     * sides and top can read as a door. A window clearly above the floor
     * (sill over 30 cm) spanning most of the door's width means it is not one.
     */
    fun doorIsWindow(door: OpeningCandidate, window: OpeningCandidate?, floorY: Float?): Boolean {
        if (window == null) return false
        val sill = window.sill ?: floorY?.let { window.bottom - it } ?: return false
        if (sill < 0.30f) return false
        val overlap = min(door.right, window.right) - max(door.left, window.left)
        return overlap >= 0.5f * min(door.width, window.width)
    }

    /** Centre of an opening from its bottom corners and heights. */
    fun centre(a: Vec3, b: Vec3, bottom: Float, top: Float) =
        Vec3((a.x + b.x) / 2f, (bottom + top) / 2f, (a.z + b.z) / 2f)

    /** Index in [existing] (opening centres) of the one at [centre], or -1. */
    fun duplicateOf(centre: Vec3, existing: List<Vec3>): Int {
        var best = -1
        var bestD = DUPLICATE
        for ((i, e) in existing.withIndex()) {
            val d = e - centre
            val dist = sqrt(d.dot(d))
            if (dist < bestD) {
                bestD = dist
                best = i
            }
        }
        return best
    }
}

/**
 * Adjusting the door / window frame found by hand, on the camera view. The
 * frame is a rectangle on its wall: left / right (m along the wall), bottom
 * / top (heights). Each side has its own handle, a circle at its middle,
 * and moving one side never moves another: no corner handles, which moved
 * two sides at once.
 */
internal object OpeningFrameAdjust {
    const val BOTTOM = 0
    const val RIGHT = 1
    const val TOP = 2
    const val LEFT = 3

    /** Smallest width / height a side may leave (m). */
    const val MIN_SIZE = 0.10f

    /**
     * The side under a finger at ([x], [y]): [s] are the frame's corners on
     * screen (bottom-left, bottom-right, top-right, top-left; null behind
     * the camera), side i running from corner i to i + 1. A handle (side
     * middle) within [handleRadius] wins; otherwise the nearest line within
     * [lineRadius]. -1 when none.
     */
    fun pickSide(s: List<FloatArray?>, x: Float, y: Float, handleRadius: Float, lineRadius: Float): Int {
        var best = -1
        var bestD = handleRadius
        for (i in 0 until 4) {
            val p = s[i] ?: continue
            val q = s[(i + 1) % 4] ?: continue
            val d = kotlin.math.hypot((p[0] + q[0]) / 2f - x, (p[1] + q[1]) / 2f - y)
            if (d < bestD) {
                bestD = d
                best = i
            }
        }
        if (best >= 0) return best
        bestD = lineRadius
        for (i in 0 until 4) {
            val p = s[i] ?: continue
            val q = s[(i + 1) % 4] ?: continue
            val dx = q[0] - p[0]
            val dy = q[1] - p[1]
            val len2 = dx * dx + dy * dy
            // Not the last bit near a corner: that is as close to the other side.
            val t = if (len2 > 0f) (((x - p[0]) * dx + (y - p[1]) * dy) / len2).coerceIn(0f, 1f) else 0f
            val d = kotlin.math.hypot(p[0] + dx * t - x, p[1] + dy * t - y)
            if (d < bestD) {
                bestD = d
                best = i
            }
        }
        return best
    }

    /** The current position of [side]. */
    fun sideValue(side: Int, left: Float, right: Float, bottom: Float, top: Float) = when (side) {
        LEFT -> left
        RIGHT -> right
        BOTTOM -> bottom
        else -> top
    }

    /**
     * [side] moved to [value]; every other side stays exactly where it is.
     * The side stops [MIN_SIZE] short of the opposite one. Returns
     * (left, right, bottom, top).
     */
    fun moveSide(side: Int, value: Float, left: Float, right: Float, bottom: Float, top: Float): FloatArray =
        when (side) {
            LEFT -> floatArrayOf(min(value, right - MIN_SIZE), right, bottom, top)
            RIGHT -> floatArrayOf(left, max(value, left + MIN_SIZE), bottom, top)
            BOTTOM -> floatArrayOf(left, right, min(value, top - MIN_SIZE), top)
            TOP -> floatArrayOf(left, right, bottom, max(value, bottom + MIN_SIZE))
            else -> floatArrayOf(left, right, bottom, top)
        }
}
