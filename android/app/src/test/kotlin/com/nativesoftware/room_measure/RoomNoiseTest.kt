package com.nativesoftware.room_measure

import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * Auto room size with noisy feature points (real ones on a wall 3-4 m away
 * scatter several cm in depth) and stray points either side of the wall.
 */
class RoomNoiseTest {
    private fun runSet(noise: Float, outliers: Float, label: String): Float {
        var sumW = 0.0; var sumD = 0.0; var worst = 0f; var n = 0; var flagged = 0
        for (seed in 1..50) {
            val r = java.util.Random(seed.toLong())
            val w = 2.5f + r.nextFloat() * 3.5f
            val d = 2.0f + r.nextFloat() * 3.0f
            val rot = r.nextFloat() * 6.28f
            fun wp(x: Float, z: Float, y: Float): Vec3 {
                val c = cos(rot); val s = sin(rot)
                return Vec3(x * c - z * s, y, x * s + z * c)
            }
            fun g(s: Float) = (r.nextGaussian() * s).toFloat()
            val cloud = ArrayList<Vec3>()
            val corners = listOf(Pair(0f, 0f), Pair(w, 0f), Pair(w, d), Pair(0f, d))
            for (i in 0 until 4) {
                val (ax, az) = corners[i]
                val (bx, bz) = corners[(i + 1) % 4]
                val len = kotlin.math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))
                val nx = -(bz - az) / len; val nz = (bx - ax) / len // inward normal
                repeat(40 + r.nextInt(110)) {
                    val t = 0.1f + r.nextFloat() * 0.8f
                    // Depth noise across the wall, outliers either side.
                    val off = if (r.nextFloat() < outliers) (r.nextFloat() * 0.5f - 0.25f) else g(noise)
                    cloud.add(wp(ax + (bx - ax) * t + nx * off, az + (bz - az) * t + nz * off, 0.15f + r.nextFloat() * 1.7f))
                }
            }
            repeat(150) {
                cloud.add(wp(0.4f + r.nextFloat() * (w - 0.8f), 0.4f + r.nextFloat() * (d - 0.8f), 0.2f + r.nextFloat() * 0.8f))
            }
            val floorPts = listOf(Pair(0.3f, 0.3f), Pair(w - 0.3f, 0.3f), Pair(w - 0.3f, d - 0.3f), Pair(0.3f, d - 0.3f))
                .map { wp(it.first, it.second, 0f) }
            val c = wp(w / 2, d / 2, 0f)
            val room = RoomDetector.computeAutoRoom(emptyList(), floorPts, 0f, c.x, c.z, null, cloud)
            if (room == null || room.estimatedCount > 0) { flagged++; continue }
            val ew = room.width - maxOf(w, d); val ed = room.depth - minOf(w, d)
            sumW += ew; sumD += ed; n++
            worst = maxOf(worst, abs(ew), abs(ed))
        }
        println(String.format(" %-28s n=%d flagged=%d  mean err W %+5.1f cm  D %+5.1f cm  worst %.1f cm",
            label, n, flagged, sumW / n * 100, sumD / n * 100, worst * 100))
        assertTrue("$label: $flagged rooms not measured", flagged <= 2)
        return worst
    }

    @Test fun lowNoise() = assertTrue(runSet(0.01f, 0f, "sigma 1cm") <= 0.01f)

    @Test fun typicalNoise() = assertTrue(runSet(0.025f, 0f, "sigma 2.5cm") <= 0.02f)

    @Test fun farWallNoise() = assertTrue(runSet(0.04f, 0f, "sigma 4cm") <= 0.05f)

    @Test fun farWallNoiseWithOutliers() = assertTrue(runSet(0.04f, 0.05f, "sigma 4cm + 5% outliers") <= 0.05f)
}
