package com.nativesoftware.room_measure

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

class LivePlanTest {
    private val room = listOf(Vec3(0f, 0f, 0f), Vec3(4f, 0f, 0f), Vec3(4f, 0f, 3f), Vec3(0f, 0f, 3f))

    @Test
    fun `the way the camera looks is up on the panel`() {
        // Camera in the middle, looking towards -z (at the wall z = 0).
        val t = LivePlan.fit(room, Vec3(2f, 1.4f, 1.5f), Vec3(0f, -0.2f, -1f), 0f, 0f, 400f, 400f, 20f)
        val wallAhead = Vec3(2f, 0f, 0f)
        val wallBehind = Vec3(2f, 0f, 3f)
        assertTrue("ahead is above", t.y(wallAhead) < t.y(wallBehind))
        assertEquals(t.x(wallAhead), t.x(wallBehind), 0.01f)
        // +x is to the camera's right when it looks towards -z.
        assertTrue(t.x(Vec3(4f, 0f, 1.5f)) > t.x(Vec3(0f, 0f, 1.5f)))
        // Turned to look at +x: that wall is now at the top.
        val t2 = LivePlan.fit(room, Vec3(2f, 1.4f, 1.5f), Vec3(1f, 0f, 0f), 0f, 0f, 400f, 400f, 20f)
        assertTrue(t2.y(Vec3(4f, 0f, 1.5f)) < t2.y(Vec3(0f, 0f, 1.5f)))
    }

    @Test
    fun `the plan fits the panel and keeps its scale while turning`() {
        val cam = Vec3(1f, 1.4f, 1f)
        var scale = -1f
        for (deg in 0 until 360 step 15) {
            val a = Math.toRadians(deg.toDouble()).toFloat()
            val t = LivePlan.fit(room, cam, Vec3(cos(a), 0f, sin(a)), 10f, 50f, 410f, 350f, 20f)
            if (scale < 0f) scale = t.scale else assertEquals(scale, t.scale, 1e-4f)
            for (p in room + cam) {
                assertTrue(t.x(p) >= 10f + 19f && t.x(p) <= 410f - 19f)
                assertTrue(t.y(p) >= 50f + 19f && t.y(p) <= 350f - 19f)
            }
            // Distances are kept (no shear): 4 m wall is 4 m long.
            val dx = t.x(room[1]) - t.x(room[0])
            val dy = t.y(room[1]) - t.y(room[0])
            assertEquals(4f * t.scale, sqrt(dx * dx + dy * dy), 0.01f)
        }
    }

    @Test
    fun `a small first wall is not blown up`() {
        val t = LivePlan.fit(listOf(Vec3(0f, 0f, 0f), Vec3(0.5f, 0f, 0f)), Vec3(0.25f, 1f, 0.1f), Vec3(0f, 0f, -1f),
            0f, 0f, 300f, 300f, 0f)
        assertEquals(150f / (LivePlan.MIN_SPAN / 2), t.scale, 0.01f)
    }

    @Test
    fun `a wall surface becomes its line on the plan`() {
        // A wall along x = 2, from z = 0.5 to 2.5, outline points at two heights.
        val pts = listOf(
            Vec3(2f, 0.1f, 0.5f), Vec3(2.01f, 2f, 0.5f), Vec3(1.99f, 2f, 2.5f), Vec3(2f, 0.1f, 2.5f), Vec3(2f, 1f, 1.5f),
        )
        val (a, b) = LivePlan.wallLine(pts)!!
        assertEquals(2f, a.x, 0.02f)
        assertEquals(2f, b.x, 0.02f)
        assertEquals(2f, abs(b.z - a.z), 0.02f)
        assertNull(LivePlan.wallLine(listOf(Vec3(0f, 0f, 0f), Vec3(0.1f, 1f, 0f))))
    }

    @Test
    fun `a door swings into the room`() {
        // Door in wall z = 0 from x 1 to 1.9; room is z > 0.
        val (leaf, arc) = LivePlan.doorSwing(Vec3(1f, 0f, 0f), Vec3(1.9f, 0f, 0f), Vec3(2f, 0f, 1.5f))
        assertEquals(1f, leaf.x, 1e-4f)
        assertEquals(0.9f, leaf.z, 1e-4f)
        assertEquals(leaf.x, arc.first().x, 1e-4f)
        assertEquals(leaf.z, arc.first().z, 1e-4f)
        assertEquals(1.9f, arc.last().x, 1e-4f)
        assertEquals(0f, arc.last().z, 1e-4f)
        for (p in arc) {
            assertEquals(0.9f, p.dist2d(Vec3(1f, 0f, 0f)), 1e-3f)
            assertTrue(p.z >= -1e-4f)
        }
        // Room on the other side: swings the other way.
        val (leaf2, _) = LivePlan.doorSwing(Vec3(1f, 0f, 0f), Vec3(1.9f, 0f, 0f), Vec3(2f, 0f, -1.5f))
        assertEquals(-0.9f, leaf2.z, 1e-4f)
        assertNotNull(arc)
    }

    @Test
    fun `room area`() {
        assertEquals(12f, LivePlan.area(room), 1e-4f)
    }

    @Test
    fun `parts of one wall are joined into one line with the whole length`() {
        // One 4 m wall seen as two overlapping surfaces, slightly off line.
        val walls = LivePlan.mergeWalls(
            listOf(
                Vec3(0f, 0f, 0f) to Vec3(2.2f, 0f, 0.03f),
                Vec3(1.9f, 1f, -0.02f) to Vec3(4f, 1f, 0.01f),
            ),
        )
        assertEquals(1, walls.size)
        val (a, b) = walls.single()
        assertEquals(4f, a.dist2d(b), 0.05f)
        assertEquals(0f, a.y, 0f)
    }

    @Test
    fun `walls that nearly meet are joined at the corner`() {
        // Two walls of an L, each stopping short of the corner (4, 0).
        val (walls, corners) = LivePlan.connectWalls(
            listOf(
                Vec3(0f, 0f, 0f) to Vec3(3.6f, 0f, 0.02f),
                Vec3(4.01f, 0f, 0.4f) to Vec3(4f, 0f, 3f),
            ),
        )
        assertEquals(1, corners.size)
        assertEquals(4f, corners[0].x, 0.03f)
        assertEquals(0f, corners[0].z, 0.03f)
        // Both walls now end at the corner.
        assertEquals(0f, walls[0].second.dist2d(corners[0]), 1e-4f)
        assertEquals(0f, walls[1].first.dist2d(corners[0]), 1e-4f)
        // The far ends are untouched.
        assertEquals(0f, walls[0].first.dist2d(Vec3(0f, 0f, 0f)), 1e-4f)
    }

    @Test
    fun `walls far from a corner are not joined`() {
        // Parallel walls, and an L whose ends are 2 m from the corner.
        val (_, c1) = LivePlan.connectWalls(
            listOf(Vec3(0f, 0f, 0f) to Vec3(4f, 0f, 0f), Vec3(0f, 0f, 3f) to Vec3(4f, 0f, 3f)),
        )
        assertEquals(0, c1.size)
        val (_, c2) = LivePlan.connectWalls(
            listOf(Vec3(0f, 0f, 0f) to Vec3(2f, 0f, 0f), Vec3(4f, 0f, 2f) to Vec3(4f, 0f, 3f)),
        )
        assertEquals(0, c2.size)
    }

    @Test
    fun `different walls stay apart`() {
        val corner = listOf(
            Vec3(0f, 0f, 0f) to Vec3(4f, 0f, 0f),
            Vec3(4f, 0f, 0f) to Vec3(4f, 0f, 3f),
        )
        assertEquals(2, LivePlan.mergeWalls(corner).size)
        // Parallel but on opposite sides of the room.
        val opposite = listOf(
            Vec3(0f, 0f, 0f) to Vec3(4f, 0f, 0f),
            Vec3(0f, 0f, 3f) to Vec3(4f, 0f, 3f),
        )
        assertEquals(2, LivePlan.mergeWalls(opposite).size)
        // On one line but far apart (a doorway's worth of gap is joined, a
        // whole room is not).
        val apart = listOf(
            Vec3(0f, 0f, 0f) to Vec3(1f, 0f, 0f),
            Vec3(3f, 0f, 0f) to Vec3(4f, 0f, 0f),
        )
        assertEquals(2, LivePlan.mergeWalls(apart).size)
    }
}
