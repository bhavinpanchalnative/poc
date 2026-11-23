package com.nativesoftware.room_measure

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

// Room geometry used by the camera scanner. Kept free of Android and ARCore
// types so it can be unit tested on the JVM.

internal data class Vec3(val x: Float, val y: Float, val z: Float) {
    operator fun plus(o: Vec3) = Vec3(x + o.x, y + o.y, z + o.z)
    operator fun minus(o: Vec3) = Vec3(x - o.x, y - o.y, z - o.z)
    operator fun times(s: Float) = Vec3(x * s, y * s, z * s)
    fun dot(o: Vec3) = x * o.x + y * o.y + z * o.z
    fun dist2d(o: Vec3): Float {
        val dx = x - o.x
        val dz = z - o.z
        return sqrt(dx * dx + dz * dz)
    }
    fun withY(ny: Float) = Vec3(x, ny, z)
}

/** A wall surface as a line on the floor plan with its extent along the line. */
internal class WallSegment(
    val cx: Float, val cz: Float, val dx: Float, val dz: Float,
    val tMin: Float, val tMax: Float,
    /** Highest point of the detected surface. */
    val top: Float,
)

/** Room outline found automatically from the detected walls. */
internal class AutoRoom(
    /** Corners at floor level, in order around the room. */
    val corners: List<Vec3>,
    /** Side i (corner i to i+1) was inferred rather than seen as a wall. */
    val estimated: List<Boolean>,
    val wallsUsed: Int,
    val height: Float?,
    val width: Float,
    val depth: Float,
) {
    val estimatedCount get() = estimated.count { it }

    fun withoutHeight() = AutoRoom(corners, estimated, wallsUsed, null, width, depth)

    fun side(i: Int) = corners[i].dist2d(corners[(i + 1) % corners.size])

    val perimeter get() = corners.indices.sumOf { side(it).toDouble() }.toFloat()

    val area: Float
        get() {
            var s = 0f
            for (i in corners.indices) {
                val a = corners[i]
                val b = corners[(i + 1) % corners.size]
                s += a.x * b.z - b.x * a.z
            }
            return abs(s) / 2f
        }
}

/**
 * A wall aligned to the room's axes, in room-local (u, v) coordinates.
 * [top] is how high above the floor it was seen: walls reach up to the
 * ceiling, furniture (desks, sofas, cabinets) usually stops well below.
 */
internal class AxisWall(
    val horizontal: Boolean, var off: Float, var lo: Float, var hi: Float, var top: Float = 2.5f,
) {
    val len get() = hi - lo
    val midU get() = if (horizontal) (lo + hi) / 2 else off
    val midV get() = if (horizontal) off else (lo + hi) / 2
}

internal object RoomDetector {

    /**
     * Builds the room outline from the detected walls, without any taps.
     *
     * Rooms are assumed to have square corners (true for nearly all rooms):
     * the dominant wall direction defines the room's axes, walls are snapped
     * to them and pieces of the same wall are merged. The outermost wall on
     * each side of the room (furniture sits inside) gives a rectangle; with
     * more walls an L-shaped or stepped outline is traced around the room.
     * Sides with no detected wall yet are estimated from the floor's extent.
     *
     * [cx], [cz] is a point inside the room (the mean camera position).
     *
     * [cloud] holds ARCore's tracked feature points. Plain painted walls are
     * often never detected as surfaces on phones without a depth sensor, but
     * their edges, skirting, switches and corners still give feature points;
     * seen from above these line up along each wall, so walls are also found
     * as dense lines of points.
     */
    fun computeAutoRoom(
        walls: List<WallSegment>, floorPts: List<Vec3>, floorY: Float,
        cx: Float, cz: Float, ceilingY: Float?,
        cloud: List<Vec3> = emptyList(),
    ): AutoRoom? {
        // Points on walls and furniture: off the floor, below the ceiling.
        // The upper part of the walls matters: it is what tells a wall from
        // furniture standing in front of it.
        val upper = ceilingY?.let { it - 0.15f }?.takeIf { it > floorY + 1.8f } ?: (floorY + 2.3f)
        val wallPts = cloud.filter { it.y > floorY + 0.1f && it.y < upper }
        val useCloud = wallPts.size >= MIN_CLOUD
        if (walls.isEmpty() && floorPts.size < 3 && !useCloud) return null

        // 1. Room axes: from the detected walls when there are enough of them
        //    (length-weighted mean of 4x angle), else from the direction in
        //    which the feature points line up best, else from the floor.
        val planeLen = walls.sumOf { (it.tMax - it.tMin).toDouble() }
        val theta = when {
            planeLen >= 2.0 || (walls.isNotEmpty() && !useCloud) -> {
                var sx = 0.0
                var sy = 0.0
                for (w in walls) {
                    val a = 4.0 * atan2(w.dz.toDouble(), w.dx.toDouble())
                    val l = (w.tMax - w.tMin).toDouble()
                    sx += l * cos(a)
                    sy += l * sin(a)
                }
                (atan2(sy, sx) / 4.0).toFloat()
            }
            useCloud -> cloudAngle(wallPts)
            else -> floorAngle(floorPts)
        }
        val ct = cos(theta)
        val st = sin(theta)
        fun lu(x: Float, z: Float) = x * ct + z * st
        fun lv(x: Float, z: Float) = -x * st + z * ct
        fun world(u: Float, v: Float) = Vec3(u * ct - v * st, floorY, u * st + v * ct)

        // 2. Snap walls to the axes; drop walls at odd angles.
        val tol = 0.2618f // 15 degrees
        val pi = PI.toFloat()
        val hs = mutableListOf<AxisWall>()
        val vs = mutableListOf<AxisWall>()
        for (w in walls) {
            var a = atan2(w.dz, w.dx) - theta
            while (a < 0f) a += pi
            while (a >= pi) a -= pi
            val horizontal = when {
                a < tol || a > pi - tol -> true
                abs(a - pi / 2) < tol -> false
                else -> continue
            }
            val ax = w.cx + w.dx * w.tMin
            val az = w.cz + w.dz * w.tMin
            val bx = w.cx + w.dx * w.tMax
            val bz = w.cz + w.dz * w.tMax
            val ua = lu(ax, az)
            val va = lv(ax, az)
            val ub = lu(bx, bz)
            val vb = lv(bx, bz)
            val top = w.top - floorY
            if (horizontal) hs.add(AxisWall(true, (va + vb) / 2, minOf(ua, ub), maxOf(ua, ub), top))
            else vs.add(AxisWall(false, (ua + ub) / 2, minOf(va, vb), maxOf(va, vb), top))
        }
        val cu = lu(cx, cz)
        val cv = lv(cx, cz)
        // Walls found as lines of feature points.
        if (useCloud) {
            val us = FloatArray(wallPts.size) { lu(wallPts[it].x, wallPts[it].z) }
            val vsArr = FloatArray(wallPts.size) { lv(wallPts[it].x, wallPts[it].z) }
            val ys = FloatArray(wallPts.size) { wallPts[it].y - floorY }
            hs.addAll(pointWalls(us, vsArr, ys, horizontal = true, c = cv))
            vs.addAll(pointWalls(us, vsArr, ys, horizontal = false, c = cu))
        }
        val all = dropShadowed((mergeWalls(hs, cv) + mergeWalls(vs, cu)).filter { it.len >= 0.5f }, cu, cv)

        val height = ceilingY?.let { it - floorY }?.takeIf { it in 1.8f..5f }
            ?: walls.maxOfOrNull { it.top - floorY }?.takeIf { it in 2.2f..4f }
            ?: cloudHeight(cloud, floorY)

        // 3. L-shaped / stepped rooms: trace the walls around the room
        //    (only surfaces tall enough to be walls).
        traceOutline(all.filter { it.top >= LOW_TOP }, cu, cv)?.let { (pts, est) ->
            return finishRoom(pts.map { world(it.first, it.second) }, est, all.size, height, pts)
        }

        // 4. Rectangle: the most wall-like candidate on each side (the
        //    longest; furniture in front of a wall was dropped above), or
        //    the floor's edge.
        var fMinU = Float.MAX_VALUE
        var fMaxU = -Float.MAX_VALUE
        var fMinV = Float.MAX_VALUE
        var fMaxV = -Float.MAX_VALUE
        for (p in floorPts) {
            val u = lu(p.x, p.z)
            val v = lv(p.x, p.z)
            fMinU = minOf(fMinU, u)
            fMaxU = maxOf(fMaxU, u)
            fMinV = minOf(fMinV, v)
            fMaxV = maxOf(fMaxV, v)
        }
        val hasFloor = floorPts.isNotEmpty()
        // The floor ends at the walls, so a "wall" with floor well beyond it
        // is furniture standing in the room.
        val slack = 0.3f
        // On each side the tallest-looking surface is the wall. When only low
        // surfaces were seen there (a desk or sofa in front of a wall that
        // was never scanned) the side is still drawn there, but flagged as
        // estimated instead of shown as measured.
        val lowOnly = BooleanArray(4)
        fun best(ws: List<AxisWall>, c: Float, side: Int): AxisWall? {
            val tall = ws.filter { it.top >= LOW_TOP }
            lowOnly[side] = tall.isEmpty() && ws.isNotEmpty()
            return (tall.ifEmpty { ws }).maxByOrNull { it.len + 0.1f * abs(it.off - c) }
        }
        // Floor beyond a low surface means furniture. Beyond a surface that
        // reaches wall height it means an open door: the floor continues
        // into the next room, and the wall is still the wall.
        fun tall(w: AxisWall) = w.top >= TALL_TOP
        val bottom = best(all.filter {
            it.horizontal && it.off < cv - 0.3f && (!hasFloor || tall(it) || it.off <= fMinV + slack)
        }, cv, 0)
        val top = best(all.filter {
            it.horizontal && it.off > cv + 0.3f && (!hasFloor || tall(it) || it.off >= fMaxV - slack)
        }, cv, 2)
        val left = best(all.filter {
            !it.horizontal && it.off < cu - 0.3f && (!hasFloor || tall(it) || it.off <= fMinU + slack)
        }, cu, 3)
        val right = best(all.filter {
            !it.horizontal && it.off > cu + 0.3f && (!hasFloor || tall(it) || it.off >= fMaxU - slack)
        }, cu, 1)
        if (!hasFloor && (bottom == null || top == null || left == null || right == null)) return null

        val b = bottom?.off ?: fMinV
        val t = top?.off ?: fMaxV
        val l = left?.off ?: fMinU
        val r = right?.off ?: fMaxU
        if (t - b < 0.8f || r - l < 0.8f) return null
        val local = listOf(Pair(l, b), Pair(r, b), Pair(r, t), Pair(l, t))
        return finishRoom(
            local.map { world(it.first, it.second) },
            listOf(bottom == null || lowOnly[0], right == null || lowOnly[1],
                top == null || lowOnly[2], left == null || lowOnly[3]),
            listOfNotNull(bottom, top, left, right).size, height, local,
        )
    }

    /** Fewest wall points worth analysing. */
    const val MIN_CLOUD = 150

    /** Wall pieces closer than this (across the wall) are the same surface. */
    const val SAME_WALL_GAP = 0.06f

    /** Surfaces seen no higher than this above the floor are furniture,
     *  not walls, when choosing the room's sides. */
    const val LOW_TOP = 1.3f

    /** Surfaces seen at least this high are walls (or as good as): floor
     *  seen beyond them is a doorway, not a sign of furniture. */
    const val TALL_TOP = 1.6f

    /** Most points a wall is asked for, however large the scan. */
    const val MAX_WALL_POINTS = 30

    /**
     * Walls as dense lines of points along one axis: a histogram of the
     * points' offsets (5 cm bins) peaks where a wall is; the peak's points
     * must spread at least 0.8 m along the wall.
     */
    private fun pointWalls(
        us: FloatArray, vs: FloatArray, ys: FloatArray, horizontal: Boolean, c: Float,
    ): List<AxisWall> {
        val offAll = if (horizontal) vs else us
        val alongAll = if (horizontal) us else vs
        if (offAll.isEmpty()) return emptyList()
        // A share of all points keeps clutter from forming walls, but capped:
        // a plain wall has only so many features, and must not get harder to
        // find the longer the rest of the room is scanned.
        val minCount = maxOf(12, minOf(MAX_WALL_POINTS, (offAll.size * 0.015f).toInt()))

        // Points on strong walls of the other direction would otherwise add
        // up to fake walls crossing them; leave them out.
        // (This threshold stays a share of all points: with many points
        // spread along one wall, a capped one would take random bumps in
        // that spread for crossing walls and delete points everywhere.)
        val other = histogramPeaks(alongAll, maxOf(3 * minCount, (offAll.size * 0.045f).toInt()))
        val keep = offAll.indices.filter { k -> other.none { abs(alongAll[k] - it) < 0.1f } }
        val off = FloatArray(keep.size) { offAll[keep[it]] }
        val along = FloatArray(keep.size) { alongAll[keep[it]] }
        val height = FloatArray(keep.size) { ys[keep[it]] }

        /** The wall made of the points within [half] of [centre], if they
         *  are enough and spread along the wall. */
        fun wallAt(start: Float, half: Float): AxisWall? {
            // The histogram peak is only as exact as its bins, and with noisy
            // points (far walls) a window around it is lopsided: move the
            // window to the mean of its points a few times (at most 3 cm, so
            // it can't slide onto a surface in front of the wall).
            var centre = start
            repeat(3) {
                var s = 0f
                var n = 0
                for (o in off) if (abs(o - centre) < half) {
                    s += o
                    n++
                }
                if (n > 0) centre = (s / n).coerceIn(start - 0.03f, start + 0.03f)
            }
            var sum = 0f
            val alongPts = ArrayList<Float>()
            val heights = ArrayList<Float>()
            for (k in off.indices) {
                if (abs(off[k] - centre) < half) {
                    sum += off[k]
                    alongPts.add(along[k])
                    heights.add(height[k])
                }
            }
            if (alongPts.size < minCount) return null
            alongPts.sort()
            val lo = alongPts[(alongPts.size * 0.05f).toInt()]
            val hi = alongPts[((alongPts.size - 1) * 0.95f).toInt()]
            if (hi - lo < 0.8f) return null
            // A wall has points along most of its length, not just at its ends.
            val cells = ((hi - lo) / 0.2f).toInt() + 1
            val filled = BooleanArray(cells)
            for (a in alongPts) if (a in lo..hi) filled[((a - lo) / 0.2f).toInt().coerceIn(0, cells - 1)] = true
            if (filled.count { it } < cells * 0.5f) return null
            heights.sort()
            val top = heights[((heights.size - 1) * 0.9f).toInt()]
            return AxisWall(horizontal, sum / alongPts.size, lo, hi, top)
        }

        val out = mutableListOf<AxisWall>()
        for (centre in histogramPeaks(off, minCount)) {
            // The 5 cm histogram blurs a wall and a surface 10-20 cm in front
            // of it (radiator, shelves, skirting) into one peak between the
            // two, which put the wall inside the room. Split the peak finely
            // and take the outermost surface: the wall.
            val nearby = off.filter { abs(it - centre) < 0.25f }.toFloatArray()
            val fine = histogramPeaks(nearby, minCount, bin = 0.02f, sep = 3)
                .sortedByDescending { abs(it - c) }
            val w = fine.firstNotNullOfOrNull { wallAt(it, 0.05f) } ?: wallAt(centre, 0.08f) ?: continue
            out.add(w)
        }
        return out
    }

    /** Offsets where a [bin]-wide histogram of [values] peaks with at least
     *  [minCount] points; of peaks within [sep] bins the stronger is kept. */
    private fun histogramPeaks(values: FloatArray, minCount: Int, bin: Float = 0.05f, sep: Int = 5): List<Float> {
        if (values.isEmpty()) return emptyList()
        val min = values.min()
        val nb = ((values.max() - min) / bin).toInt() + 1
        if (nb > 2000) return emptyList()
        val counts = IntArray(nb)
        for (o in values) counts[((o - min) / bin).toInt().coerceIn(0, nb - 1)]++
        val smooth = IntArray(nb) { i ->
            counts[i] + (if (i > 0) counts[i - 1] else 0) + (if (i < nb - 1) counts[i + 1] else 0)
        }
        // Local maxima, keeping the stronger of peaks closer than sep bins.
        val peaks = mutableListOf<Int>()
        for (i in 0 until nb) {
            val s = smooth[i]
            if (s < minCount) continue
            if (i > 0 && smooth[i - 1] > s) continue
            if (i < nb - 1 && smooth[i + 1] >= s) continue
            val near = peaks.indexOfFirst { abs(it - i) <= sep }
            if (near < 0) peaks.add(i) else if (smooth[peaks[near]] < s) peaks[near] = i
        }
        return peaks.map { min + (it + 0.5f) * bin }
    }

    /**
     * Rotation (radians, 0..90 degrees) at which the points line up best
     * with the axes: the one giving the sharpest histograms.
     */
    private fun cloudAngle(pts: List<Vec3>): Float {
        val step = maxOf(1, pts.size / 3000)
        val xs = FloatArray((pts.size + step - 1) / step) { pts[it * step].x }
        val zs = FloatArray(xs.size) { pts[it * step].z }
        fun score(a: Float): Long {
            val c = cos(a)
            val s = sin(a)
            val bin = 0.05f
            var total = 0L
            for (axis in 0..1) {
                val vals = FloatArray(xs.size) {
                    if (axis == 0) xs[it] * c + zs[it] * s else -xs[it] * s + zs[it] * c
                }
                val min = vals.min()
                val nb = (((vals.max() - min) / bin).toInt() + 1).coerceAtMost(4000)
                val counts = IntArray(nb)
                for (v in vals) counts[((v - min) / bin).toInt().coerceIn(0, nb - 1)]++
                for (k in counts) total += k.toLong() * k
            }
            return total
        }
        var best = 0f
        var bestScore = -1L
        for (deg in 0 until 90) {
            val a = Math.toRadians(deg.toDouble()).toFloat()
            val sc = score(a)
            if (sc > bestScore) {
                bestScore = sc
                best = a
            }
        }
        // Refine to a quarter degree.
        val coarse = best
        for (k in -4..4) {
            val a = coarse + Math.toRadians(k * 0.25).toFloat()
            val sc = score(a)
            if (sc > bestScore) {
                bestScore = sc
                best = a
            }
        }
        return best
    }

    /** Ceiling height from points high up on the walls and ceiling. */
    private fun cloudHeight(cloud: List<Vec3>, floorY: Float): Float? {
        val high = cloud.map { it.y - floorY }.filter { it in 2.1f..4.0f }.sorted()
        if (high.size < 40) return null
        return high[(high.size * 0.9f).toInt().coerceAtMost(high.size - 1)]
    }

    private fun finishRoom(
        corners: List<Vec3>, estimated: List<Boolean>, wallsUsed: Int,
        height: Float?, local: List<Pair<Float, Float>>,
    ): AutoRoom {
        val w = local.maxOf { it.first } - local.minOf { it.first }
        val d = local.maxOf { it.second } - local.minOf { it.second }
        return AutoRoom(corners, estimated, wallsUsed, height, maxOf(w, d), minOf(w, d))
    }

    /**
     * Removes surfaces standing in front of a wall (wardrobes, fridges): a
     * wall with a parallel wall behind it, on the same side of the room,
     * that overlaps it along its length.
     */
    private fun dropShadowed(ws: List<AxisWall>, cu: Float, cv: Float): List<AxisWall> =
        ws.filter { w ->
            val c = if (w.horizontal) cv else cu
            ws.none { o ->
                o !== w && o.horizontal == w.horizontal &&
                    (o.off - c) * (w.off - c) > 0f &&
                    abs(o.off - c) > abs(w.off - c) &&
                    minOf(o.hi, w.hi) - maxOf(o.lo, w.lo) > 0.3f
            }
        }

    /** Joins wall pieces lying on the same line (within 20 cm). */
    /**
     * Joins wall pieces lying on the same line (within 20 cm). [c] is the
     * room centre's offset across these walls.
     *
     * Pieces a few centimetres apart are the same wall seen twice and are
     * averaged. Further apart, the inner one is something standing against
     * the wall (skirting, radiator, shelves, curtains): the outer one is the
     * wall. Averaging those pulled every wall into the room, so rooms came
     * out too small.
     */
    private fun mergeWalls(ws: List<AxisWall>, c: Float): List<AxisWall> {
        val out = mutableListOf<AxisWall>()
        for (w in ws.sortedBy { it.off }) {
            val m = out.firstOrNull {
                abs(it.off - w.off) < 0.2f && w.lo < it.hi + 1.0f && w.hi > it.lo - 1.0f
            }
            if (m == null) {
                out.add(AxisWall(w.horizontal, w.off, w.lo, w.hi, w.top))
            } else {
                val lm = m.len
                val lw = w.len
                if (abs(m.off - w.off) <= SAME_WALL_GAP) {
                    m.off = (m.off * lm + w.off * lw) / (lm + lw)
                } else if (abs(w.off - c) > abs(m.off - c)) {
                    m.off = w.off
                }
                m.lo = minOf(m.lo, w.lo)
                m.hi = maxOf(m.hi, w.hi)
                m.top = maxOf(m.top, w.top)
            }
        }
        return out
    }

    /**
     * Traces a room with more than four walls (L-shapes, alcoves) by going
     * round the room centre. Returns local corners and, per side, whether
     * it was inferred; null when the walls don't form a clean outline.
     */
    private fun traceOutline(
        walls: List<AxisWall>, cu: Float, cv: Float,
    ): Pair<List<Pair<Float, Float>>, List<Boolean>>? {
        if (walls.size < 5) return null
        // Keep walls seen directly from the centre (not hidden behind another).
        fun crosses(w: AxisWall, o: AxisWall): Boolean {
            val (mu, mv) = Pair(w.midU, w.midV)
            return if (o.horizontal) {
                if ((cv - o.off) * (mv - o.off) >= 0f) false
                else {
                    val t = (o.off - cv) / (mv - cv)
                    val u = cu + (mu - cu) * t
                    u > o.lo && u < o.hi
                }
            } else {
                if ((cu - o.off) * (mu - o.off) >= 0f) false
                else {
                    val t = (o.off - cu) / (mu - cu)
                    val v = cv + (mv - cv) * t
                    v > o.lo && v < o.hi
                }
            }
        }
        val visible = walls.filter { w -> walls.none { o -> o !== w && crosses(w, o) } }
        if (visible.size < 5) return null
        val ring = visible.sortedBy { atan2(it.midV - cv, it.midU - cu) }

        val pts = mutableListOf<Pair<Float, Float>>()
        val est = mutableListOf<Boolean>()
        // Walls are often only partly detected, so corners may lie this far
        // beyond a wall's detected extent.
        val reach = 2.0f
        for (i in ring.indices) {
            val a = ring[i]
            val b = ring[(i + 1) % ring.size]
            if (a.horizontal != b.horizontal) {
                val h = if (a.horizontal) a else b
                val v = if (a.horizontal) b else a
                if (v.off < h.lo - reach || v.off > h.hi + reach) return null
                if (h.off < v.lo - reach || h.off > v.hi + reach) return null
                pts.add(Pair(v.off, h.off))
                est.add(false)
            } else {
                // Two parallel walls in a row: join them with a step.
                val sideA = if (a.horizontal) a.off < cv else a.off > cu
                val sideB = if (b.horizontal) b.off < cv else b.off > cu
                if (sideA != sideB) return null
                // Shallow steps are more likely furniture than an alcove.
                if (abs(a.off - b.off) < 0.5f) return null
                val forward = if (a.horizontal) a.off < cv else a.off > cu
                val endA = if (forward) a.hi else a.lo
                val startB = if (forward) b.lo else b.hi
                if ((startB - endA) * (if (forward) 1 else -1) < -0.5f) return null
                val s = (endA + startB) / 2
                if (a.horizontal) {
                    pts.add(Pair(s, a.off)); est.add(true)
                    pts.add(Pair(s, b.off)); est.add(false)
                } else {
                    pts.add(Pair(a.off, s)); est.add(true)
                    pts.add(Pair(b.off, s)); est.add(false)
                }
            }
        }
        if (pts.size < 4 || !isSimple(pts)) return null
        var area = 0f
        for (i in pts.indices) {
            val p = pts[i]
            val q = pts[(i + 1) % pts.size]
            area += p.first * q.second - q.first * p.second
        }
        if (abs(area) / 2 < 1f) return null
        for (i in pts.indices) {
            val p = pts[i]
            val q = pts[(i + 1) % pts.size]
            if (abs(p.first - q.first) + abs(p.second - q.second) < 0.15f) return null
        }
        return Pair(pts, est)
    }

    private fun isSimple(pts: List<Pair<Float, Float>>): Boolean {
        val n = pts.size
        fun cross(ox: Float, oy: Float, ax: Float, ay: Float, bx: Float, by: Float) =
            (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)
        for (i in 0 until n) for (j in i + 2 until n) {
            if (i == 0 && j == n - 1) continue
            val a = pts[i]
            val b = pts[(i + 1) % n]
            val c = pts[j]
            val d = pts[(j + 1) % n]
            val d1 = cross(a.first, a.second, b.first, b.second, c.first, c.second)
            val d2 = cross(a.first, a.second, b.first, b.second, d.first, d.second)
            val d3 = cross(c.first, c.second, d.first, d.second, a.first, a.second)
            val d4 = cross(c.first, c.second, d.first, d.second, b.first, b.second)
            if (d1 * d2 < 0 && d3 * d4 < 0) return false
        }
        return true
    }

    /** Rotation (radians) giving the floor's smallest bounding box. */
    private fun floorAngle(pts: List<Vec3>): Float {
        var best = 0f
        var bestArea = Float.MAX_VALUE
        for (deg in 0 until 90 step 2) {
            val a = Math.toRadians(deg.toDouble()).toFloat()
            val c = cos(a)
            val s = sin(a)
            var minU = Float.MAX_VALUE
            var maxU = -Float.MAX_VALUE
            var minV = Float.MAX_VALUE
            var maxV = -Float.MAX_VALUE
            for (p in pts) {
                val u = p.x * c + p.z * s
                val v = -p.x * s + p.z * c
                minU = minOf(minU, u); maxU = maxOf(maxU, u)
                minV = minOf(minV, v); maxV = maxOf(maxV, v)
            }
            val area = (maxU - minU) * (maxV - minV)
            if (area < bestArea) {
                bestArea = area
                best = a
            }
        }
        return best
    }
}
