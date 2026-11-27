package com.nativesoftware.room_measure

import kotlin.math.sqrt

/**
 * Steadies the point under the crosshair. A single frame's hit jitters by
 * a centimetre or more (depth noise, tracking noise, the hand), and a mark
 * used to take whichever frame the button was pressed on. When the phone is
 * held still, the per-axis median of the last [windowMs] of hits is used
 * instead: noise from single frames drops out and a measurement no longer
 * depends on the exact moment of the tap.
 *
 * Free of Android types so it can be unit tested on the JVM.
 */
internal class AimSmoother(
    private val windowMs: Long = 350L,
    /** Hits further than this from the median (m) mean the aim moved. */
    private val steady: Float = 0.03f,
    /** Fewest hits worth a median. */
    private val minHits: Int = 4,
) {
    private val times = ArrayDeque<Long>()
    private val points = ArrayDeque<Vec3>()

    /** Records the hit of the frame at [now] (ms); null when nothing is
     *  under the crosshair, which starts over. */
    fun add(now: Long, hit: Vec3?) {
        if (hit == null) {
            clear()
            return
        }
        times.addLast(now)
        points.addLast(hit)
        while (times.isNotEmpty() && now - times.first() > windowMs) {
            times.removeFirst()
            points.removeFirst()
        }
    }

    fun clear() {
        times.clear()
        points.clear()
    }

    /**
     * The point to mark: the median of the recent hits when there are
     * enough of them and they all agree (the aim was held still), else
     * [latest] (the aim is moving: what is under the crosshair now).
     */
    fun point(latest: Vec3): Vec3 {
        if (points.size < minHits) return latest
        val m = Vec3(
            median(points.map { it.x }), median(points.map { it.y }), median(points.map { it.z }),
        )
        for (p in points) {
            val d = p - m
            if (sqrt(d.dot(d)) > steady) return latest
        }
        // The latest hit must still be on the same spot.
        val d = latest - m
        return if (sqrt(d.dot(d)) > steady) latest else m
    }

    private fun median(v: List<Float>): Float {
        val s = v.sorted()
        return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2f
    }
}
