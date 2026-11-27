package com.nativesoftware.room_measure

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

// AI furniture detection for the camera scanner: an on-device object
// detector (EfficientDet-Lite0, COCO classes) finds furniture in the camera
// image; each box is placed on the floor plan through where its bottom meets
// the floor, and kept once several images agree. The geometry here has no
// Android types so it can be unit tested; FurnitureDetector.swift is its twin.

/** A furniture kind the plan shows, with its usual depth front to back (m). */
internal class FurnitureKind(val name: String, val depth: Float)

internal object FurnitureKinds {
    /**
     * Detector labels (COCO) kept, and what the plan calls them. Things that
     * usually stand on something else (a TV, a sink, a microwave) are left
     * out: the bottom of their box is not where they meet the floor.
     */
    val byLabel = mapOf(
        "bed" to FurnitureKind("Bed", 2.0f),
        "couch" to FurnitureKind("Sofa", 0.9f),
        "chair" to FurnitureKind("Chair", 0.55f),
        "dining table" to FurnitureKind("Table", 0.9f),
        "toilet" to FurnitureKind("Toilet", 0.7f),
        "refrigerator" to FurnitureKind("Refrigerator", 0.7f),
        "oven" to FurnitureKind("Oven", 0.6f),
        "potted plant" to FurnitureKind("Plant", 0.5f),
    )

    /** Lowest detector score taken. */
    const val MIN_SCORE = 0.5f
}

/**
 * A pinhole camera for the CPU image: [sensorToWorld] is the sensor pose as a
 * 4x4 column-major matrix (camera x right, y up, looking down -z), the
 * intrinsics in image pixels (x right, y down).
 */
internal class PinholeCamera(
    val sensorToWorld: FloatArray,
    val fx: Float, val fy: Float, val cx: Float, val cy: Float,
    val width: Int, val height: Int,
) {
    val origin get() = Vec3(sensorToWorld[12], sensorToWorld[13], sensorToWorld[14])

    /** Direction (world, not normalised) of the ray through pixel (u, v). */
    fun ray(u: Float, v: Float): Vec3 {
        val x = (u - cx) / fx
        val y = -(v - cy) / fy
        val z = -1f
        val m = sensorToWorld
        return Vec3(m[0] * x + m[4] * y + m[8] * z, m[1] * x + m[5] * y + m[9] * z, m[2] * x + m[6] * y + m[10] * z)
    }

    /** Where the ray through (u, v) meets the floor (height [floorY]); null
     *  when it does not (above the horizon, or too far). */
    fun onFloor(u: Float, v: Float, floorY: Float, maxDistance: Float = 7f): Vec3? {
        val o = origin
        val d = ray(u, v)
        if (d.y > -1e-3f) return null
        val t = (floorY - o.y) / d.y
        if (t <= 0f) return null
        val p = Vec3(o.x + d.x * t, floorY, o.z + d.z * t)
        if (hypot(p.x - o.x, p.z - o.z) > maxDistance) return null
        return p
    }
}

/** A detection in the upright image: box in pixels (y down), label, score. */
internal class Detection2D(
    val label: String, val score: Float,
    val left: Float, val top: Float, val right: Float, val bottom: Float,
)

/** A piece of furniture on the floor plan. [yaw] is the direction of its
 *  width (radians, atan2(z, x)). */
internal class Furniture(
    val kind: String, val center: Vec3, val width: Float, val depth: Float, val height: Float, val yaw: Float,
)

internal object FurniturePlacement {
    /**
     * [d] (in the upright image, [toSensor] mapping its pixels back to the
     * sensor image the camera model is for) placed on the floor: its front
     * edge is where the bottom of the box meets the floor, its width from the
     * box's width at that distance, its depth the usual one for the kind
     * (the camera sees only the front), its width square to the view. Null
     * when it can't be placed: an unknown label, the bottom cut off by the
     * image edge, or the floor not seen there.
     */
    fun place(
        d: Detection2D, cam: PinholeCamera, floorY: Float, uprightHeight: Float,
        toSensor: (Float, Float) -> Pair<Float, Float>,
    ): Furniture? {
        val kind = FurnitureKinds.byLabel[d.label] ?: return null
        if (d.score < FurnitureKinds.MIN_SCORE) return null
        // Its bottom must be in view to know where it stands.
        if (d.bottom > uprightHeight - 4f) return null
        val mid = (d.left + d.right) / 2
        val (bu, bv) = toSensor(mid, d.bottom)
        val (lu, lv) = toSensor(d.left, d.bottom)
        val (ru, rv) = toSensor(d.right, d.bottom)
        val front = cam.onFloor(bu, bv, floorY) ?: return null
        val l = cam.onFloor(lu, lv, floorY) ?: return null
        val r = cam.onFloor(ru, rv, floorY) ?: return null
        val width = hypot(r.x - l.x, r.z - l.z)
        if (width < 0.2f || width > 4f) return null
        // Height: the top of the box on the upright plane through the front.
        val o = cam.origin
        val (tu, tv) = toSensor(mid, d.top)
        val top = cam.ray(tu, tv)
        val dist = hypot(front.x - o.x, front.z - o.z)
        val horiz = hypot(top.x, top.z)
        val height = if (horiz > 1e-4f) (o.y + top.y / horiz * dist - floorY).coerceIn(0.1f, 3f) else 0.5f
        // Far taller than that kind ever is: the floor (or the box) is wrong.
        if (height > (if (kind.name == "Refrigerator") 2.4f else 1.6f)) return null
        // Away from the camera, through the front edge.
        var ax = front.x - o.x
        var az = front.z - o.z
        val al = hypot(ax, az).coerceAtLeast(1e-4f)
        ax /= al
        az /= al
        // A bed seen from its side is long across: then it is less deep.
        val depth = if (kind.name == "Bed" && width > 1.7f) 1.5f else kind.depth
        val center = Vec3(front.x + ax * depth / 2, floorY, front.z + az * depth / 2)
        val yaw = atan2(ax, -az) // width runs square to the view
        return Furniture(kind.name, center, width, depth, height, yaw)
    }
}

/**
 * Furniture found while scanning: detections of the same kind close
 * together are one piece, averaged; a piece counts once it has been seen in
 * [minHits] images (one image may be wrong).
 */
internal class FurnitureTracker(private val minHits: Int = 3, private val sameDistance: Float = 0.8f) {
    private class Track(var f: Furniture, var hits: Int)

    private val tracks = ArrayList<Track>()

    fun add(f: Furniture) {
        val near = tracks.filter { it.f.kind == f.kind }
            .minByOrNull { hypot(it.f.center.x - f.center.x, it.f.center.z - f.center.z) }
        if (near != null && hypot(near.f.center.x - f.center.x, near.f.center.z - f.center.z) < sameDistance) {
            val n = near.hits.toFloat()
            val k = 1f / (n + 1f)
            val a = near.f
            // Average the yaw as an axis (0 and 180° are the same line).
            val c = cos(2 * a.yaw) * n + cos(2 * f.yaw)
            val s = sin(2 * a.yaw) * n + sin(2 * f.yaw)
            near.f = Furniture(
                a.kind,
                Vec3(a.center.x + (f.center.x - a.center.x) * k, a.center.y, a.center.z + (f.center.z - a.center.z) * k),
                a.width + (f.width - a.width) * k,
                a.depth + (f.depth - a.depth) * k,
                a.height + (f.height - a.height) * k,
                atan2(s, c) / 2,
            )
            near.hits++
        } else {
            tracks.add(Track(f, 1))
        }
    }

    /** Pieces seen often enough. */
    fun confirmed(): List<Furniture> = tracks.filter { it.hits >= minHits }.map { it.f }

    fun clear() = tracks.clear()

    /** The rectangle of [f] on the floor (x, z), corner by corner. */
    companion object {
        fun footprint(f: Furniture): List<Vec3> {
            val ux = cos(f.yaw) * f.width / 2
            val uz = sin(f.yaw) * f.width / 2
            val vx = -sin(f.yaw) * f.depth / 2
            val vz = cos(f.yaw) * f.depth / 2
            val c = f.center
            return listOf(
                Vec3(c.x - ux - vx, c.y, c.z - uz - vz), Vec3(c.x + ux - vx, c.y, c.z + uz - vz),
                Vec3(c.x + ux + vx, c.y, c.z + uz + vz), Vec3(c.x - ux + vx, c.y, c.z - uz + vz),
            )
        }
    }
}

/** Maps a pixel of the image turned upright by [degrees] (clockwise) back to
 *  the sensor image ([w] × [h]). */
internal fun uprightToSensor(degrees: Int, w: Int, h: Int): (Float, Float) -> Pair<Float, Float> =
    when (((degrees % 360) + 360) % 360) {
        90 -> { x, y -> y to (h - 1 - x) }
        180 -> { x, y -> (w - 1 - x) to (h - 1 - y) }
        270 -> { x, y -> (w - 1 - y) to x }
        else -> { x, y -> x to y }
    }
