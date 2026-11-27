package com.nativesoftware.room_measure

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.abs

/**
 * The scanner's accuracy helpers (depth voxels, aim smoothing), the hand
 * adjustment of a door / window frame, and the automatic counting of doors
 * and windows during a room scan.
 */
class ScanAccuracyTest {

    // ---------------------------------------------------------------- voxels

    /** Mean x of all voxel means (the wall is the plane x = const). */
    private fun meanX(grid: DepthVoxelGrid): Float {
        var s = 0.0
        var n = 0
        grid.forEachMean(2) { x, _, _ ->
            s += x
            n++
        }
        return (s / n).toFloat()
    }

    @Test
    fun `depth voxels keep the wall where it is, not at the voxel centre`() {
        // A wall at x = 1.012 m: voxel centres would put it at 1.025 m.
        val wallX = 1.012f
        val grid = DepthVoxelGrid(0.05f)
        val rnd = Random(3)
        repeat(4000) {
            grid.add(wallX + rnd.nextGaussian().toFloat() * 0.004f, rnd.nextFloat() * 2f, rnd.nextFloat() * 3f)
        }
        assertEquals(wallX, meanX(grid), 0.002f)
    }

    @Test
    fun `near depth samples outweigh far noisy ones`() {
        // One spot of a wall at x = 2.025 m seen from 1 m (precise) and from
        // 4 m (biased 1.5 cm into the room, weighing 16x less), equally often.
        val wallX = 2.025f
        val grid = DepthVoxelGrid(0.05f)
        val rnd = Random(5)
        repeat(500) {
            grid.add(wallX + rnd.nextGaussian().toFloat() * 0.002f, 0.01f, 0.01f, 1f / (1f * 1f))
            grid.add(wallX - 0.015f + rnd.nextGaussian().toFloat() * 0.002f, 0.01f, 0.01f, 1f / (4f * 4f))
        }
        assertEquals(1, grid.count)
        // Unweighted, the far samples would pull it 7.5 mm into the room.
        assertEquals(wallX, meanX(grid), 0.0015f)
    }

    @Test
    fun `a voxel seen once is not used, and the voxel cap holds`() {
        val grid = DepthVoxelGrid(0.05f, maxVoxels = 2)
        grid.add(0.01f, 0f, 0f)
        grid.add(1.01f, 0f, 0f)
        grid.add(1.02f, 0f, 0f)
        grid.add(2.01f, 0f, 0f) // a third voxel: over the cap, dropped
        assertEquals(2, grid.count)
        val xs = mutableListOf<Float>()
        grid.forEachMean(2) { x, _, _ -> xs.add(x) }
        assertEquals(1, xs.size)
        assertEquals(1.015f, xs[0], 1e-5f)
    }

    // ---------------------------------------------------------------- aim

    @Test
    fun `a steady aim gives the median of recent frames`() {
        val s = AimSmoother()
        val rnd = Random(7)
        val truth = Vec3(1f, 0f, 2f)
        var latest = truth
        for (t in 0 until 10) {
            latest = Vec3(
                truth.x + rnd.nextGaussian().toFloat() * 0.006f, truth.y, truth.z + rnd.nextGaussian().toFloat() * 0.006f,
            )
            s.add(t * 33L, latest)
        }
        // An outlier frame at the moment of the tap no longer decides the point.
        val spike = Vec3(truth.x + 0.02f, truth.y, truth.z)
        s.add(330L, spike)
        val p = s.point(spike)
        assertTrue("x ${p.x}", abs(p.x - truth.x) < 0.006f)
        assertTrue("z ${p.z}", abs(p.z - truth.z) < 0.006f)
    }

    @Test
    fun `a moving aim uses the point under the crosshair now`() {
        val s = AimSmoother()
        for (t in 0 until 10) s.add(t * 33L, Vec3(t * 0.05f, 0f, 0f))
        val now = Vec3(0.5f, 0f, 0f)
        assertEquals(now, s.point(now))
        // Losing the hit starts over.
        s.add(400L, null)
        val next = Vec3(3f, 0f, 0f)
        assertEquals(next, s.point(next))
    }

    // ---------------------------------------------------------------- frame adjust

    /** Screen corners of a frame 200 px wide, 400 px tall at (100, 100). */
    private val screen = listOf(
        floatArrayOf(100f, 500f), floatArrayOf(300f, 500f), floatArrayOf(300f, 100f), floatArrayOf(100f, 100f),
    )

    @Test
    fun `each side has its own handle at its middle`() {
        val f = OpeningFrameAdjust
        assertEquals(f.BOTTOM, f.pickSide(screen, 200f, 505f, 36f, 24f))
        assertEquals(f.RIGHT, f.pickSide(screen, 296f, 300f, 36f, 24f))
        assertEquals(f.TOP, f.pickSide(screen, 205f, 98f, 36f, 24f))
        assertEquals(f.LEFT, f.pickSide(screen, 104f, 300f, 36f, 24f))
        // Along a line away from its handle: still that side.
        assertEquals(f.LEFT, f.pickSide(screen, 108f, 180f, 36f, 24f))
        // Nowhere near the frame.
        assertEquals(-1, f.pickSide(screen, 200f, 300f, 36f, 24f))
    }

    @Test
    fun `moving one side leaves the other three exactly in place`() {
        val f = OpeningFrameAdjust
        val l = 0.10f
        val r = 0.95f
        val b = 0.00f
        val t = 2.03f
        assertArrayEquals(floatArrayOf(0.02f, r, b, t), f.moveSide(f.LEFT, 0.02f, l, r, b, t), 0f)
        assertArrayEquals(floatArrayOf(l, 1.01f, b, t), f.moveSide(f.RIGHT, 1.01f, l, r, b, t), 0f)
        assertArrayEquals(floatArrayOf(l, r, b, 2.10f), f.moveSide(f.TOP, 2.10f, l, r, b, t), 0f)
        assertArrayEquals(floatArrayOf(l, r, 0.05f, t), f.moveSide(f.BOTTOM, 0.05f, l, r, b, t), 0f)
        // Pushed past the opposite side, it stops 10 cm short; that side stays.
        assertArrayEquals(floatArrayOf(r - 0.10f, r, b, t), f.moveSide(f.LEFT, 2f, l, r, b, t), 1e-6f)
        assertArrayEquals(floatArrayOf(l, r, b, b + 0.10f), f.moveSide(f.TOP, -1f, l, r, b, t), 1e-6f)
    }

    // ---------------------------------------------------------------- counting

    private fun candidate(width: Float, height: Float, bottom: Float, x: Float = 0f) = OpeningCandidate(
        x, x + width, bottom, bottom + height, Vec3(x, bottom, 0f), Vec3(x + width, bottom, 0f), bottom + height,
        width, height, bottom, 5f, false,
    )

    @Test
    fun `only door- and window-shaped detections are counted`() {
        val c = RoomOpeningCounter
        assertTrue(c.plausible(OpeningKind.DOOR, candidate(0.82f, 2.03f, 0f), 0f))
        assertFalse("too narrow", c.plausible(OpeningKind.DOOR, candidate(0.4f, 2.03f, 0f), 0f))
        assertFalse("off the floor", c.plausible(OpeningKind.DOOR, candidate(0.82f, 2.03f, 0.5f), 0f))
        assertFalse("too short", c.plausible(OpeningKind.DOOR, candidate(0.82f, 1.2f, 0f), 0f))
        assertTrue(c.plausible(OpeningKind.WINDOW, candidate(1.2f, 1.1f, 0.9f), 0f))
        assertFalse("on the floor", c.plausible(OpeningKind.WINDOW, candidate(1.2f, 1.1f, 0.02f), 0f))
        assertFalse("too small", c.plausible(OpeningKind.WINDOW, candidate(0.2f, 0.2f, 1f), 0f))
    }

    @Test
    fun `an opening already counted is found again, a new one is not`() {
        val c = RoomOpeningCounter
        val counted = listOf(Vec3(0.4f, 1.0f, 0f), Vec3(3.0f, 1.4f, 0f))
        assertEquals(0, c.duplicateOf(Vec3(0.45f, 1.05f, 0.05f), counted))
        assertEquals(1, c.duplicateOf(Vec3(3.2f, 1.4f, 0f), counted))
        assertEquals(-1, c.duplicateOf(Vec3(1.6f, 1.0f, 0f), counted))
    }
}
