package com.nativesoftware.room_measure

import kotlin.math.floor

/**
 * Depth samples gathered into [size]-metre voxels, keeping for each voxel
 * the mean of the samples that fell in it and how many there were.
 *
 * Each voxel stands for the mean of its samples, not for its centre: a
 * voxel's centre is up to half a voxel (2.5 cm with 5 cm voxels) away from
 * the surface the samples came from, which moved every wall found from depth
 * by up to that much and a room's width by up to twice that. The mean of
 * many samples is also less noisy than any one of them.
 *
 * Not thread safe (the scanner uses it on its GL thread only). Free of
 * Android types so it can be unit tested on the JVM.
 */
internal class DepthVoxelGrid(private val size: Float = 0.05f, private val maxVoxels: Int = 150_000) {
    /** Weighted sums of the samples, their total weight and their count. */
    private class Cell(var sx: Double, var sy: Double, var sz: Double, var w: Double, var n: Int)

    private val cells = HashMap<Long, Cell>()

    /** Voxels holding at least one sample. */
    val count get() = cells.size

    fun clear() = cells.clear()

    /** Adds one depth sample (world metres) with [weight] (more reliable
     *  samples weigh more). New voxels stop at [maxVoxels]; ones already
     *  there keep collecting samples. */
    fun add(x: Float, y: Float, z: Float, weight: Float = 1f) {
        if (!(weight > 0f)) return
        val key = key(x, y, z)
        val c = cells[key]
        if (c != null) {
            c.sx += x * weight.toDouble()
            c.sy += y * weight.toDouble()
            c.sz += z * weight.toDouble()
            c.w += weight
            c.n++
        } else if (cells.size < maxVoxels) {
            cells[key] = Cell(x * weight.toDouble(), y * weight.toDouble(), z * weight.toDouble(), weight.toDouble(), 1)
        }
    }

    /** Calls [f] with the (weighted) mean position of every voxel seen at
     *  least [minHits] times (one sample alone is too often noise). */
    fun forEachMean(minHits: Int, f: (Float, Float, Float) -> Unit) {
        for (c in cells.values) {
            if (c.n < minHits) continue
            f((c.sx / c.w).toFloat(), (c.sy / c.w).toFloat(), (c.sz / c.w).toFloat())
        }
    }

    private fun key(x: Float, y: Float, z: Float): Long {
        fun idx(a: Float) = (floor(a / size).toLong() + OFFSET) and 0x1FFFFF
        return (idx(x) shl 42) or (idx(y) shl 21) or idx(z)
    }

    private companion object {
        const val OFFSET = 1L shl 20
    }
}
