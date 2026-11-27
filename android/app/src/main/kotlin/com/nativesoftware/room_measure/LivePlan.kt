package com.nativesoftware.room_measure

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// Geometry of the live 2D floor plan drawn while a room is scanned. Kept free
// of Android types so it can be unit tested; LivePlan.swift is its twin (keep
// them in sync).

/**
 * World floor plan (x, z) to panel pixels, heading-up: the way the camera
 * looks is always up on the panel, so the wall in front of the phone is the
 * one at the top of the plan, right under the camera view. [cx], [cz] (the
 * room's centre) is drawn at the panel's centre ([px], [py]).
 */
internal class PlanTransform(
    val cx: Float, val cz: Float,
    /** Unit horizontal forward of the camera. */
    val fx: Float, val fz: Float,
    /** Pixels per metre. */
    val scale: Float,
    val px: Float, val py: Float,
) {
    // Camera right on the floor: forward turned 90° clockwise seen from above.
    private val rx = -fz
    private val rz = fx

    fun x(wx: Float, wz: Float) = px + ((wx - cx) * rx + (wz - cz) * rz) * scale
    fun y(wx: Float, wz: Float) = py - ((wx - cx) * fx + (wz - cz) * fz) * scale
    fun x(p: Vec3) = x(p.x, p.z)
    fun y(p: Vec3) = y(p.x, p.z)
}

internal object LivePlan {
    /** Smallest area shown (m across), so the first wall found isn't huge. */
    const val MIN_SPAN = 3f

    /**
     * The transform fitting [points] (and the camera at [cam]) in the panel
     * [left], [top], [right], [bottom] with [pad] pixels to spare. The scale
     * comes from the distance of the farthest point from the centre, which
     * does not change as the plan turns with the camera, so the plan doesn't
     * zoom in and out while the user turns round.
     */
    fun fit(
        points: List<Vec3>, cam: Vec3, forward: Vec3,
        left: Float, top: Float, right: Float, bottom: Float, pad: Float,
    ): PlanTransform {
        val all = points + cam
        var minX = Float.MAX_VALUE
        var maxX = -Float.MAX_VALUE
        var minZ = Float.MAX_VALUE
        var maxZ = -Float.MAX_VALUE
        for (p in all) {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minZ = min(minZ, p.z)
            maxZ = max(maxZ, p.z)
        }
        val cx = (minX + maxX) / 2
        val cz = (minZ + maxZ) / 2
        var r = MIN_SPAN / 2
        for (p in all) {
            val dx = p.x - cx
            val dz = p.z - cz
            r = max(r, sqrt(dx * dx + dz * dz))
        }
        val half = max(1f, min(right - left, bottom - top) / 2 - pad)
        var fx = forward.x
        var fz = forward.z
        val l = sqrt(fx * fx + fz * fz)
        if (l < 1e-3f) {
            fx = 0f
            fz = -1f
        } else {
            fx /= l
            fz /= l
        }
        return PlanTransform(cx, cz, fx, fz, half / r, (left + right) / 2, (top + bottom) / 2)
    }

    /**
     * A detected wall surface (its outline, world points) as a line on the
     * floor plan: its two extreme points along its main direction. Null when
     * it is too small to show.
     */
    fun wallLine(points: List<Vec3>, minLength: Float = 0.25f): Pair<Vec3, Vec3>? {
        if (points.size < 2) return null
        var mx = 0f
        var mz = 0f
        for (p in points) {
            mx += p.x
            mz += p.z
        }
        mx /= points.size
        mz /= points.size
        var sxx = 0f
        var sxz = 0f
        var szz = 0f
        for (p in points) {
            val dx = p.x - mx
            val dz = p.z - mz
            sxx += dx * dx
            sxz += dx * dz
            szz += dz * dz
        }
        val ang = 0.5f * atan2(2 * sxz, sxx - szz)
        val dx = cos(ang)
        val dz = sin(ang)
        var lo = Float.MAX_VALUE
        var hi = -Float.MAX_VALUE
        for (p in points) {
            val t = (p.x - mx) * dx + (p.z - mz) * dz
            lo = min(lo, t)
            hi = max(hi, t)
        }
        if (hi - lo < minLength) return null
        return Vec3(mx + dx * lo, 0f, mz + dz * lo) to Vec3(mx + dx * hi, 0f, mz + dz * hi)
    }

    /**
     * A door drawn as on a floor plan: the leaf standing open at 90° from
     * the hinge [a] into the room (towards [inside]), and its swing, a
     * quarter circle from the leaf's end to [b]. Returns the leaf's end and
     * the arc's points (from the leaf's end to [b]), on the floor (y 0).
     */
    fun doorSwing(a: Vec3, b: Vec3, inside: Vec3, steps: Int = 12): Pair<Vec3, List<Vec3>> {
        val wx = b.x - a.x
        val wz = b.z - a.z
        val w = sqrt(wx * wx + wz * wz)
        if (w < 1e-4f) return a.withY(0f) to listOf(a.withY(0f))
        var nx = -wz / w
        var nz = wx / w
        // Into the room: the side of the wall [inside] is on.
        if ((inside.x - a.x) * nx + (inside.z - a.z) * nz < 0f) {
            nx = -nx
            nz = -nz
        }
        val leaf = Vec3(a.x + nx * w, 0f, a.z + nz * w)
        val ux = wx / w
        val uz = wz / w
        val arc = (0..steps).map { i ->
            val t = (Math.PI / 2 * i / steps).toFloat()
            // From the leaf (normal) round to the wall (along b).
            val c = cos(t)
            val s = sin(t)
            Vec3(a.x + (nx * c + ux * s) * w, 0f, a.z + (nz * c + uz * s) * w)
        }
        return leaf to arc
    }

    /**
     * Wall lines found so far ([wallLine] of each wall surface) joined where
     * they are parts of the same wall: about parallel (within [maxAngleDeg]),
     * on the same line (within [maxOffset] m) and overlapping or close end to
     * end (gap up to [maxGap] m). A wall seen as several surfaces is then
     * drawn, and measured, as one line, as soon as it is found.
     */
    fun mergeWalls(
        lines: List<Pair<Vec3, Vec3>>,
        maxAngleDeg: Float = 12f, maxOffset: Float = 0.15f, maxGap: Float = 0.3f,
    ): List<Pair<Vec3, Vec3>> {
        val out = lines.map { it.first.withY(0f) to it.second.withY(0f) }.toMutableList()
        val cosMax = cos(Math.toRadians(maxAngleDeg.toDouble())).toFloat()
        var merged = true
        while (merged) {
            merged = false
            loop@ for (i in out.indices) for (j in i + 1 until out.size) {
                val m = join(out[i], out[j], cosMax, maxOffset, maxGap) ?: continue
                out[i] = m
                out.removeAt(j)
                merged = true
                break@loop
            }
        }
        return out
    }

    /**
     * Walls found so far ([mergeWalls]) joined at the corners: where two
     * walls meet at an angle (at least [minAngleDeg]) and an end of each is
     * within [reach] m of where their lines cross, both ends are moved to
     * that point, which becomes a corner. So the lines drawn run along the
     * walls and turn at the corners, growing as more walls are found.
     * Returns the walls and the corners.
     */
    fun connectWalls(
        walls: List<Pair<Vec3, Vec3>>, reach: Float = 0.6f, minAngleDeg: Float = 30f,
    ): Pair<List<Pair<Vec3, Vec3>>, List<Vec3>> {
        val ends = walls.map { arrayOf(it.first.withY(0f), it.second.withY(0f)) }
        val used = Array(walls.size) { BooleanArray(2) }
        val corners = ArrayList<Vec3>()
        val sinMin = sin(Math.toRadians(minAngleDeg.toDouble())).toFloat()
        for (i in walls.indices) for (j in i + 1 until walls.size) {
            val (a0, a1) = walls[i]
            val (b0, b1) = walls[j]
            val la = a0.dist2d(a1)
            val lb = b0.dist2d(b1)
            if (la < 1e-4f || lb < 1e-4f) continue
            val ux = (a1.x - a0.x) / la
            val uz = (a1.z - a0.z) / la
            val vx = (b1.x - b0.x) / lb
            val vz = (b1.z - b0.z) / lb
            val cross = ux * vz - uz * vx
            if (abs(cross) < sinMin) continue
            val t = ((b0.x - a0.x) * vz - (b0.z - a0.z) * vx) / cross
            val p = Vec3(a0.x + ux * t, 0f, a0.z + uz * t)
            val ei = if (a0.dist2d(p) <= a1.dist2d(p)) 0 else 1
            val ej = if (b0.dist2d(p) <= b1.dist2d(p)) 0 else 1
            if (used[i][ei] || used[j][ej]) continue
            if (walls[i].toList()[ei].dist2d(p) > reach || walls[j].toList()[ej].dist2d(p) > reach) continue
            ends[i][ei] = p
            ends[j][ej] = p
            used[i][ei] = true
            used[j][ej] = true
            corners.add(p)
        }
        return ends.map { it[0] to it[1] } to corners
    }

    /** [a] and [b] as one line, or null when they are different walls. */
    private fun join(
        a: Pair<Vec3, Vec3>, b: Pair<Vec3, Vec3>, cosMax: Float, maxOffset: Float, maxGap: Float,
    ): Pair<Vec3, Vec3>? {
        val (a0, a1) = a
        val (b0, b1) = b
        val la = a0.dist2d(a1)
        val lb = b0.dist2d(b1)
        if (la < 1e-4f || lb < 1e-4f) return null
        // The longer line's direction is the wall's.
        val (o, ol) = if (la >= lb) a0 to a1 else b0 to b1
        val len = max(la, lb)
        val ux = (ol.x - o.x) / len
        val uz = (ol.z - o.z) / len
        val vx = if (la >= lb) (b1.x - b0.x) / lb else (a1.x - a0.x) / la
        val vz = if (la >= lb) (b1.z - b0.z) / lb else (a1.z - a0.z) / la
        if (abs(ux * vx + uz * vz) < cosMax) return null
        val pts = listOf(a0, a1, b0, b1)
        // Every end close to the wall's line.
        for (p in pts) if (abs(-(p.x - o.x) * uz + (p.z - o.z) * ux) > maxOffset) return null
        fun t(p: Vec3) = (p.x - o.x) * ux + (p.z - o.z) * uz
        val (alo, ahi) = min(t(a0), t(a1)) to max(t(a0), t(a1))
        val (blo, bhi) = min(t(b0), t(b1)) to max(t(b0), t(b1))
        if (max(alo, blo) - min(ahi, bhi) > maxGap) return null
        val lo = min(alo, blo)
        val hi = max(ahi, bhi)
        // Along the line through the middle of both.
        var off = 0f
        for (p in pts) off += -(p.x - o.x) * uz + (p.z - o.z) * ux
        off /= pts.size
        val bx = o.x - uz * off
        val bz = o.z + ux * off
        return Vec3(bx + ux * lo, 0f, bz + uz * lo) to Vec3(bx + ux * hi, 0f, bz + uz * hi)
    }

    /** Area of a polygon on the floor plan (m², shoelace). */
    fun area(corners: List<Vec3>): Float {
        var s = 0f
        for (i in corners.indices) {
            val p = corners[i]
            val q = corners[(i + 1) % corners.size]
            s += p.x * q.z - q.x * p.z
        }
        return abs(s) / 2
    }
}
