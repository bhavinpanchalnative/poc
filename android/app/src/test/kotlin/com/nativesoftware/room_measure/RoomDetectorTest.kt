package com.nativesoftware.room_measure

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Simulates what ARCore reports in real rooms (walls detected only in
 * parts, rooms at an arbitrary angle, furniture, missing walls) and checks
 * the automatic room outline and its dimensions.
 */
class RoomDetectorTest {

    private val angle = 0.6f // room rotated ~34 degrees in world space
    private val offX = 1.3f
    private val offZ = -0.7f

    private fun world(x: Float, z: Float): Pair<Float, Float> {
        val c = cos(angle)
        val s = sin(angle)
        return Pair(x * c - z * s + offX, x * s + z * c + offZ)
    }

    /** A wall detected from fraction [f0] to [f1] of the segment a-b. */
    private fun wall(ax: Float, az: Float, bx: Float, bz: Float, f0: Float = 0.2f, f1: Float = 0.8f): WallSegment {
        val (wax, waz) = world(ax, az)
        val (wbx, wbz) = world(bx, bz)
        val len = sqrt((wbx - wax) * (wbx - wax) + (wbz - waz) * (wbz - waz))
        val dx = (wbx - wax) / len
        val dz = (wbz - waz) / len
        val cx = (wax + wbx) / 2
        val cz = (waz + wbz) / 2
        return WallSegment(cx, cz, dx, dz, (f0 - 0.5f) * len, (f1 - 0.5f) * len, 1.9f)
    }

    private fun floor(x0: Float, z0: Float, x1: Float, z1: Float): List<Vec3> =
        listOf(Pair(x0, z0), Pair(x1, z0), Pair(x1, z1), Pair(x0, z1)).map {
            val (x, z) = world(it.first, it.second)
            Vec3(x, 0f, z)
        }

    private fun detect(walls: List<WallSegment>, floorPts: List<Vec3>, cx: Float, cz: Float): AutoRoom {
        val (wx, wz) = world(cx, cz)
        val room = RoomDetector.computeAutoRoom(walls, floorPts, 0f, wx, wz, 2.6f)
        assertNotNull("no room found", room)
        return room!!
    }

    private val rectWalls = listOf(
        wall(0f, 0f, 4.2f, 0f),
        wall(4.2f, 0f, 4.2f, 3.6f),
        wall(4.2f, 3.6f, 0f, 3.6f),
        wall(0f, 3.6f, 0f, 0f),
    )

    @Test
    fun rectangleFromPartlyDetectedWalls() {
        val r = detect(rectWalls, emptyList(), 2.1f, 1.8f)
        assertEquals(4, r.corners.size)
        assertEquals(0, r.estimatedCount)
        assertEquals(4.2f, r.width, 0.01f)
        assertEquals(3.6f, r.depth, 0.01f)
        assertEquals(15.12f, r.area, 0.05f)
        assertEquals(15.6f, r.perimeter, 0.05f)
        assertEquals(2.6f, r.height!!, 0.001f)
    }

    @Test
    fun furnitureInFrontOfAWallIsIgnored() {
        // Wardrobe front 0.6 m in front of the left wall, and a sideboard.
        val walls = rectWalls + wall(0.6f, 1.0f, 0.6f, 2.2f, 0f, 1f) +
            wall(1.0f, 3.1f, 2.5f, 3.1f, 0f, 1f)
        val r = detect(walls, emptyList(), 2.1f, 1.8f)
        assertEquals(4, r.corners.size)
        assertEquals(4.2f, r.width, 0.01f)
        assertEquals(3.6f, r.depth, 0.01f)
    }

    @Test
    fun surfacesCloseInFrontOfAWallDoNotShrinkTheRoom() {
        // A radiator 12 cm in front of the bottom wall and shelving 15 cm in
        // front of the right wall: close enough to merge with the wall, and
        // they used to be averaged with it, pulling the walls in.
        val walls = rectWalls + wall(0.8f, 0.12f, 3.2f, 0.12f, 0f, 1f) +
            wall(4.05f, 0.6f, 4.05f, 3.0f, 0f, 1f)
        val r = detect(walls, emptyList(), 2.1f, 1.8f)
        assertEquals(4, r.corners.size)
        assertEquals(4.2f, r.width, 0.01f)
        assertEquals(3.6f, r.depth, 0.01f)
    }

    @Test
    fun pointsOnARadiatorDoNotShrinkTheRoom() {
        val cloud = wallPoints(0f, 0f, 4.2f, 0f, 120) +
            wallPoints(4.2f, 0f, 4.2f, 3.6f, 100) +
            wallPoints(4.2f, 3.6f, 0f, 3.6f, 120) +
            wallPoints(0f, 3.6f, 0f, 0f, 100) +
            // Radiator 12 cm in front of the bottom wall, densely featured.
            wallPoints(0.8f, 0.12f, 3.4f, 0.12f, 150, 0f, 1f) +
            clutter(150, 4.2f, 3.6f)
        val r = detectCloud(cloud, floor(1f, 1f, 3f, 2.5f), 2.1f, 1.8f)
        assertEquals(4.2f, r.width, 0.05f)
        assertEquals(3.6f, r.depth, 0.05f)
    }

    @Test
    fun deskInFrontOfAnUnscannedWallIsNotTakenAsTheWall() {
        // The bottom wall was never pointed at; only a desk front 0.6 m in
        // front of it (0.3-0.8 m high) was seen. It must not be shown as a
        // measured wall.
        val cloud = wallPoints(4.2f, 0f, 4.2f, 3.6f, 100) +
            wallPoints(4.2f, 3.6f, 0f, 3.6f, 120) +
            wallPoints(0f, 3.6f, 0f, 0f, 100) +
            List(120) {
                val t = 0.25f + rnd.nextFloat() * 0.5f
                val (x, z) = world(4.2f * t, 0.6f + noise(0.015f))
                Vec3(x, 0.3f + rnd.nextFloat() * 0.5f, z)
            } +
            clutter(150, 4.2f, 3.6f)
        val r = detectCloud(cloud, floor(0.4f, 0.4f, 3.8f, 3.2f), 2.1f, 2.0f)
        assert(r.estimatedCount >= 1) { "desk side shown as measured: ${r.width} x ${r.depth}" }
    }

    @Test
    fun tallWallBehindLowFurnitureWins() {
        // Sofa back 0.35 m in front of the bottom wall, seen densely; the wall
        // behind is seen above the sofa, up to 2.2 m.
        val wallHigh = List(90) {
            val t = 0.1f + rnd.nextFloat() * 0.8f
            val (x, z) = world(4.2f * t, noise(0.02f))
            Vec3(x, 1.0f + rnd.nextFloat() * 1.2f, z)
        }
        val sofa = List(200) {
            val t = 0.2f + rnd.nextFloat() * 0.6f
            val (x, z) = world(4.2f * t, 0.35f + noise(0.015f))
            Vec3(x, 0.2f + rnd.nextFloat() * 0.6f, z)
        }
        val cloud = wallHigh + sofa + wallPoints(4.2f, 0f, 4.2f, 3.6f, 100) +
            wallPoints(4.2f, 3.6f, 0f, 3.6f, 120) + wallPoints(0f, 3.6f, 0f, 0f, 100) +
            clutter(150, 4.2f, 3.6f)
        val (wx, wz) = world(2.1f, 1.8f)
        val r = RoomDetector.computeAutoRoom(emptyList(), floor(1f, 1f, 3f, 2.5f), 0f, wx, wz, 2.5f, cloud)!!
        assertEquals(0, r.estimatedCount)
        assertEquals(4.2f, r.width, 0.05f)
        assertEquals(3.6f, r.depth, 0.05f)
    }

    @Test
    fun plainWallIsStillFoundAfterScanningLotsOfTexture() {
        // A long scan: thousands of points on textured things (bookshelves on
        // three walls, clutter), and a plain wall with only a few features.
        // The plain wall must not need a fixed share of all points.
        val cloud = wallPoints(0f, 0f, 4.2f, 0f, 2500) +
            wallPoints(4.2f, 0f, 4.2f, 3.6f, 2500) +
            wallPoints(4.2f, 3.6f, 0f, 3.6f, 2500) +
            wallPoints(0f, 3.6f, 0f, 0f, 45) + // plain wall
            clutter(300, 4.2f, 3.6f)
        val r = detectCloud(cloud, floor(1f, 1f, 3f, 2.5f), 2.1f, 1.8f)
        assertEquals("plain wall not measured", 0, r.estimatedCount)
        assertEquals(4.2f, r.width, 0.05f)
        assertEquals(3.6f, r.depth, 0.05f)
    }

    @Test
    fun floorSeenThroughAnOpenDoorDoesNotCancelTheWall() {
        // The floor surface continues through a doorway in the bottom wall
        // into a corridor (1.5 m beyond). The wall is still the wall.
        val cloud = wallPoints(0f, 0f, 4.2f, 0f, 120) +
            wallPoints(4.2f, 0f, 4.2f, 3.6f, 100) +
            wallPoints(4.2f, 3.6f, 0f, 3.6f, 120) +
            wallPoints(0f, 3.6f, 0f, 0f, 100) +
            clutter(150, 4.2f, 3.6f)
        val floorWithCorridor = listOf(
            Pair(0.3f, 0.3f), Pair(1.5f, 0.3f), Pair(1.4f, -1.5f), Pair(2.6f, -1.5f),
            Pair(2.4f, 0.3f), Pair(3.9f, 0.3f), Pair(3.9f, 3.3f), Pair(0.3f, 3.3f),
        ).map { val (x, z) = world(it.first, it.second); Vec3(x, 0f, z) }
        val r = detectCloud(cloud, floorWithCorridor, 2.1f, 1.8f)
        assertEquals(0, r.estimatedCount)
        assertEquals(4.2f, r.width, 0.05f)
        assertEquals(3.6f, r.depth, 0.05f)
    }

    @Test
    fun missingWallIsEstimatedFromTheFloor() {
        val walls = rectWalls.take(3)
        val r = detect(walls, floor(0.3f, 0.2f, 4.0f, 3.4f), 2.1f, 1.8f)
        assertEquals(4, r.corners.size)
        assertEquals(1, r.estimatedCount)
        // The left side comes from the floor's edge at x = 0.3.
        assertEquals(3.9f, r.width, 0.02f)
        assertEquals(3.6f, r.depth, 0.02f)
    }

    @Test
    fun lShapedRoom() {
        val walls = listOf(
            wall(0f, 0f, 6f, 0f, 0.15f, 0.85f),
            wall(6f, 0f, 6f, 2.8f),
            wall(6f, 2.8f, 3.5f, 2.8f),
            wall(3.5f, 2.8f, 3.5f, 5f),
            wall(3.5f, 5f, 0f, 5f),
            wall(0f, 5f, 0f, 0f, 0.15f, 0.85f),
        )
        val r = detect(walls, emptyList(), 2f, 2f)
        assertEquals(6, r.corners.size)
        assertEquals(0, r.estimatedCount)
        assertEquals(6f * 5f - 2.5f * 2.2f, r.area, 0.1f)
        assertEquals(6f, r.width, 0.02f)
        assertEquals(5f, r.depth, 0.02f)
    }

    // ---- feature points only (plain walls, no wall surfaces detected) ----

    private val rnd = java.util.Random(42)
    private fun noise(s: Float) = (rnd.nextGaussian() * s).toFloat()

    /** Points scattered along part of a wall, like ARCore features on it. */
    private fun wallPoints(
        ax: Float, az: Float, bx: Float, bz: Float, count: Int,
        f0: Float = 0.1f, f1: Float = 0.9f,
    ): List<Vec3> = List(count) {
        val t = f0 + rnd.nextFloat() * (f1 - f0)
        val (x, z) = world(ax + (bx - ax) * t + noise(0.02f), az + (bz - az) * t + noise(0.02f))
        Vec3(x, 0.15f + rnd.nextFloat() * 1.7f, z)
    }

    /** Furniture and clutter: points anywhere inside the room. */
    private fun clutter(count: Int, w: Float, d: Float): List<Vec3> = List(count) {
        val (x, z) = world(0.3f + rnd.nextFloat() * (w - 0.6f), 0.3f + rnd.nextFloat() * (d - 0.6f))
        Vec3(x, 0.2f + rnd.nextFloat() * 0.8f, z)
    }

    private fun detectCloud(cloud: List<Vec3>, floorPts: List<Vec3>, cx: Float, cz: Float): AutoRoom {
        val (wx, wz) = world(cx, cz)
        val room = RoomDetector.computeAutoRoom(emptyList(), floorPts, 0f, wx, wz, null, cloud)
        assertNotNull("no room found", room)
        return room!!
    }

    @Test
    fun rectangleFromFeaturePointsOnly() {
        val cloud = wallPoints(0f, 0f, 4.2f, 0f, 120) +
            wallPoints(4.2f, 0f, 4.2f, 3.6f, 60, 0.3f, 0.7f) + // a plain wall: few points
            wallPoints(4.2f, 3.6f, 0f, 3.6f, 150) +
            wallPoints(0f, 3.6f, 0f, 0f, 90) +
            // Desk front standing 0.7 m in front of the bottom wall.
            wallPoints(1.0f, 0.7f, 2.4f, 0.7f, 80) +
            clutter(200, 4.2f, 3.6f)
        val r = detectCloud(cloud, floor(1f, 1f, 3f, 2.5f), 2.1f, 1.8f)
        assertEquals(4, r.corners.size)
        assertEquals(0, r.estimatedCount)
        assertEquals(4.2f, r.width, 0.05f)
        assertEquals(3.6f, r.depth, 0.05f)
        assertEquals(15.12f, r.area, 0.4f)
    }

    @Test
    fun featurePointsWithAnUnseenWall() {
        val cloud = wallPoints(0f, 0f, 4.2f, 0f, 120) +
            wallPoints(4.2f, 0f, 4.2f, 3.6f, 100) +
            wallPoints(4.2f, 3.6f, 0f, 3.6f, 120) +
            clutter(150, 4.2f, 3.6f)
        // Left wall never pointed at; the floor reaches to x = 0.2.
        val r = detectCloud(cloud, floor(0.2f, 0.4f, 3.8f, 3.2f), 2.1f, 1.8f)
        assertEquals(1, r.estimatedCount)
        assertEquals(4.0f, r.width, 0.06f)
        assertEquals(3.6f, r.depth, 0.05f)
    }

    @Test
    fun pointsSeenThroughAWindowAreIgnored() {
        val cloud = wallPoints(0f, 0f, 4.2f, 0f, 120) +
            wallPoints(4.2f, 0f, 4.2f, 3.6f, 100) +
            wallPoints(4.2f, 3.6f, 0f, 3.6f, 120) +
            wallPoints(0f, 3.6f, 0f, 0f, 100) +
            // A tree 3 m outside the right wall, seen through a 0.6 m window.
            wallPoints(7.2f, 1.5f, 7.2f, 2.1f, 60, 0f, 1f) +
            clutter(150, 4.2f, 3.6f)
        val r = detectCloud(cloud, floor(1f, 1f, 3f, 2.5f), 2.1f, 1.8f)
        assertEquals(4.2f, r.width, 0.05f)
        assertEquals(3.6f, r.depth, 0.05f)
    }

    @Test
    fun manyRandomRoomsFromFeaturePoints() {
        var failures = 0
        val report = StringBuilder()
        for (seed in 1..50) {
            val r = java.util.Random(seed.toLong())
            val w = 2.5f + r.nextFloat() * 3.5f
            val d = 2.0f + r.nextFloat() * 3.0f
            val rot = r.nextFloat() * 6.28f
            val ox = r.nextFloat() * 4 - 2
            val oz = r.nextFloat() * 4 - 2
            fun wp(x: Float, z: Float, y: Float): Vec3 {
                val c = cos(rot)
                val s = sin(rot)
                return Vec3(x * c - z * s + ox, y, x * s + z * c + oz)
            }
            fun g(s: Float) = (r.nextGaussian() * s).toFloat()
            val cloud = ArrayList<Vec3>()
            val corners = listOf(Pair(0f, 0f), Pair(w, 0f), Pair(w, d), Pair(0f, d))
            for (i in 0 until 4) {
                val (ax, az) = corners[i]
                val (bx, bz) = corners[(i + 1) % 4]
                // Each wall only partly covered, with 40-150 points.
                val f0 = r.nextFloat() * 0.3f
                val f1 = 0.6f + r.nextFloat() * 0.4f
                repeat(40 + r.nextInt(110)) {
                    val t = f0 + r.nextFloat() * (f1 - f0)
                    cloud.add(wp(ax + (bx - ax) * t + g(0.025f), az + (bz - az) * t + g(0.025f), 0.15f + r.nextFloat() * 1.7f))
                }
            }
            // Clutter, and a sofa or desk in front of a random wall.
            repeat(100 + r.nextInt(200)) {
                cloud.add(wp(0.3f + r.nextFloat() * (w - 0.6f), 0.3f + r.nextFloat() * (d - 0.6f), 0.2f + r.nextFloat() * 0.8f))
            }
            val inset = 0.5f + r.nextFloat() * 0.4f
            repeat(70) {
                val t = 0.25f + r.nextFloat() * 0.4f
                cloud.add(wp(w * t, inset + g(0.02f), 0.3f + r.nextFloat() * 0.5f))
            }
            // Floor detected over the middle of the room.
            val floorPts = listOf(Pair(0.25f, 0.25f), Pair(w - 0.3f, 0.3f), Pair(w - 0.3f, d - 0.25f), Pair(0.3f, d - 0.3f))
                .map { wp(it.first, it.second, 0f) }
            val c = wp(w / 2 + g(0.3f), d / 2 + g(0.3f), 0f)
            val room = RoomDetector.computeAutoRoom(emptyList(), floorPts, 0f, c.x, c.z, null, cloud)
            val exact = room != null &&
                abs(room.width - maxOf(w, d)) < 0.06f && abs(room.depth - minOf(w, d)) < 0.06f
            val line = "seed $seed: true ${"%.2f".format(w)} x ${"%.2f".format(d)}, got " +
                (room?.let { "${"%.2f".format(it.width)} x ${"%.2f".format(it.depth)} est=${it.estimatedCount}" } ?: "none") + "\n"
            when {
                // A wrong size must never be shown as fully measured.
                room != null && !exact && room.estimatedCount == 0 -> {
                    failures++
                    report.append("WRONG ").append(line)
                }
                room == null || room.estimatedCount > 0 -> {
                    flagged++
                    report.append("flagged ").append(line)
                }
            }
        }
        assertEquals(report.toString(), 0, failures)
        assert(flagged <= 5) { "too many rooms with unmeasured sides:\n$report" }
    }

    private var flagged = 0

    @Test
    fun manyRandomRoomsWithSurfacesAgainstAWall() {
        val report = StringBuilder()
        var failures = 0
        var missed = 0
        for (seed in 101..150) {
            val r = java.util.Random(seed.toLong())
            val w = 2.5f + r.nextFloat() * 3.5f
            val d = 2.0f + r.nextFloat() * 3.0f
            val rot = r.nextFloat() * 6.28f
            fun wp(x: Float, z: Float, y: Float): Vec3 {
                val c = cos(rot)
                val s = sin(rot)
                return Vec3(x * c - z * s, y, x * s + z * c)
            }
            fun g(s: Float) = (r.nextGaussian() * s).toFloat()
            val cloud = ArrayList<Vec3>()
            val corners = listOf(Pair(0f, 0f), Pair(w, 0f), Pair(w, d), Pair(0f, d))
            for (i in 0 until 4) {
                val (ax, az) = corners[i]
                val (bx, bz) = corners[(i + 1) % 4]
                repeat(60 + r.nextInt(90)) {
                    val t = 0.1f + r.nextFloat() * 0.8f
                    cloud.add(wp(ax + (bx - ax) * t + g(0.025f), az + (bz - az) * t + g(0.025f), 0.15f + r.nextFloat() * 1.7f))
                }
            }
            // A radiator / shelving 8-18 cm in front of the bottom wall, with
            // more feature points than the plain wall behind it.
            val gap = 0.08f + r.nextFloat() * 0.10f
            repeat(120 + r.nextInt(80)) {
                val t = 0.2f + r.nextFloat() * 0.6f
                cloud.add(wp(w * t, gap + g(0.015f), 0.2f + r.nextFloat() * 0.7f))
            }
            repeat(150) {
                cloud.add(wp(0.4f + r.nextFloat() * (w - 0.8f), 0.4f + r.nextFloat() * (d - 0.8f), 0.2f + r.nextFloat() * 0.8f))
            }
            val floorPts = listOf(Pair(0.3f, 0.3f), Pair(w - 0.3f, 0.3f), Pair(w - 0.3f, d - 0.3f), Pair(0.3f, d - 0.3f))
                .map { wp(it.first, it.second, 0f) }
            val c = wp(w / 2, d / 2, 0f)
            val room = RoomDetector.computeAutoRoom(emptyList(), floorPts, 0f, c.x, c.z, null, cloud)
            val line = "seed $seed: true ${"%.2f".format(w)} x ${"%.2f".format(d)} gap ${"%.2f".format(gap)}, got " +
                (room?.let { "${"%.2f".format(it.width)} x ${"%.2f".format(it.depth)} est=${it.estimatedCount}" } ?: "none") + "\n"
            if (room == null || room.estimatedCount > 0) {
                missed++
                report.append("flagged ").append(line)
                continue
            }
            if (abs(room.width - maxOf(w, d)) > 0.05f || abs(room.depth - minOf(w, d)) > 0.05f) {
                failures++
                report.append("WRONG ").append(line)
            }
        }
        assertEquals(report.toString(), 0, failures)
        assert(missed <= 5) { "too many rooms with unmeasured sides:\n$report" }
    }

    @Test
    fun floorOnlyGivesAnEstimate() {
        val r = detect(emptyList(), floor(0f, 0f, 3f, 2.5f), 1.5f, 1.2f)
        assertEquals(4, r.estimatedCount)
        assertEquals(3f, r.width, 0.05f)
        assertEquals(2.5f, r.depth, 0.05f)
    }
}
