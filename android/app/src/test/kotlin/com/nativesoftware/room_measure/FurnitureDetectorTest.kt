package com.nativesoftware.room_measure

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

class FurnitureDetectorTest {
    /** Camera 1.5 m above the floor (y 0) at the origin, looking along -z,
     *  level; 640 × 480 image, 500 px focal length. */
    private fun camera(): PinholeCamera {
        val m = FloatArray(16)
        m[0] = 1f; m[5] = 1f; m[10] = 1f; m[15] = 1f
        m[13] = 1.5f
        return PinholeCamera(m, 500f, 500f, 320f, 240f, 640, 480)
    }

    /** The pixel row where the floor at [distance] m ahead is seen. */
    private fun rowAt(distance: Float) = 240f + 500f * 1.5f / distance

    @Test
    fun `a sofa is placed where it stands, its width from the box`() {
        val cam = camera()
        // Front edge 4 m ahead, 2 m wide: 2 / 4 * 500 px across.
        val half = 500f / 4f
        val d = Detection2D("couch", 0.8f, 320f - half, 300f, 320f + half, rowAt(4f))
        val f = FurniturePlacement.place(d, cam, 0f, 480f) { x, y -> x to y }
        assertNotNull(f)
        f!!
        assertEquals("Sofa", f.kind)
        assertEquals(2f, f.width, 0.05f)
        // Centre behind the front edge by half its depth.
        assertEquals(-4f - 0.45f, f.center.z, 0.05f)
        assertEquals(0f, f.center.x, 0.05f)
        // Width runs across the view (along x).
        assertTrue(abs(cos(f.yaw)) > 0.99f)
    }

    @Test
    fun `things that are cut off, not furniture, or unsure are left out`() {
        val cam = camera()
        val id = { x: Float, y: Float -> x to y }
        // Bottom at the image edge: where it stands is not seen.
        assertNull(FurniturePlacement.place(Detection2D("bed", 0.9f, 200f, 300f, 400f, 479f), cam, 0f, 480f, id))
        assertNull(FurniturePlacement.place(Detection2D("tv", 0.9f, 200f, 300f, 400f, rowAt(3f)), cam, 0f, 480f, id))
        assertNull(FurniturePlacement.place(Detection2D("chair", 0.3f, 300f, 300f, 340f, rowAt(3f)), cam, 0f, 480f, id))
        // Above the horizon: not on the floor.
        assertNull(FurniturePlacement.place(Detection2D("chair", 0.9f, 300f, 100f, 340f, 200f), cam, 0f, 480f, id))
    }

    @Test
    fun `a piece seen in several images is kept once, averaged`() {
        val t = FurnitureTracker(minHits = 3)
        fun sofa(x: Float) = Furniture("Sofa", Vec3(x, 0f, -3f), 2f, 0.9f, 0.8f, 0f)
        t.add(sofa(0f))
        t.add(sofa(0.1f))
        assertEquals(0, t.confirmed().size)
        t.add(sofa(0.2f))
        assertEquals(1, t.confirmed().size)
        assertEquals(0.1f, t.confirmed()[0].center.x, 1e-4f)
        // Another kind at the same place, and the same kind far away, are new.
        repeat(3) { t.add(Furniture("Chair", Vec3(0f, 0f, -3f), 0.5f, 0.5f, 0.9f, 0f)) }
        repeat(3) { t.add(sofa(3f)) }
        assertEquals(3, t.confirmed().size)
    }

    @Test
    fun `upright pixels map back to the sensor image`() {
        // Turned 90° clockwise: the upright image's top left is the sensor's
        // bottom left.
        val f = uprightToSensor(90, 640, 480)
        assertEquals(0f to 479f, f(0f, 0f))
        assertEquals(639f to 479f, f(0f, 639f))
        val g = uprightToSensor(270, 640, 480)
        assertEquals(639f to 0f, g(0f, 0f))
        // A footprint is a rectangle of the right size.
        val fp = FurnitureTracker.footprint(Furniture("Bed", Vec3(0f, 0f, 0f), 1.6f, 2f, 0.5f, 0.3f))
        assertEquals(1.6f, fp[0].dist2d(fp[1]), 1e-4f)
        assertEquals(2f, fp[1].dist2d(fp[2]), 1e-4f)
        assertEquals(0f, (fp[1].x - fp[0].x) * -sin(0.3f) + (fp[1].z - fp[0].z) * cos(0.3f), 1e-4f)
    }
}
