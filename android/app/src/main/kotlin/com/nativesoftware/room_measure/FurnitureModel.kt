package com.nativesoftware.room_measure

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.Image
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector

/**
 * The on-device furniture detector (MediaPipe Object Detector with
 * EfficientDet-Lite0, trained on COCO; assets/efficientdet_lite0.tflite).
 * Works offline. Use from one thread.
 */
internal class FurnitureModel(context: Context) : AutoCloseable {
    private val detector: ObjectDetector = ObjectDetector.createFromOptions(
        context,
        ObjectDetector.ObjectDetectorOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath("efficientdet_lite0.tflite").build())
            .setRunningMode(RunningMode.IMAGE)
            .setScoreThreshold(FurnitureKinds.MIN_SCORE)
            .setMaxResults(10)
            .setCategoryAllowlist(FurnitureKinds.byLabel.keys.toList())
            .build(),
    )

    /** Furniture in [bitmap] (upright), boxes in its pixels. */
    fun detect(bitmap: Bitmap): List<Detection2D> {
        val result = detector.detect(BitmapImageBuilder(bitmap).build())
        return result.detections().mapNotNull { d ->
            val c = d.categories().maxByOrNull { it.score() } ?: return@mapNotNull null
            val b = d.boundingBox()
            Detection2D(c.categoryName(), c.score(), b.left, b.top, b.right, b.bottom)
        }
    }

    override fun close() = detector.close()
}

/**
 * The camera's YUV image copied (the ARCore image must be closed at once),
 * at half size, to turn into an upright colour picture on another thread.
 */
internal class HalfYuv private constructor(val w: Int, val h: Int, private val y: ByteArray, private val uv: ByteArray) {
    /** Full-size sensor image dimensions. */
    val sensorWidth get() = w * 2
    val sensorHeight get() = h * 2

    /** An upright ARGB picture: the half-size image turned [degrees] clockwise. */
    fun toUprightBitmap(degrees: Int): Bitmap {
        val px = IntArray(w * h)
        for (r in 0 until h) {
            for (c in 0 until w) {
                val yy = (y[r * w + c].toInt() and 0xFF) - 16
                val u = (uv[2 * (r * w + c)].toInt() and 0xFF) - 128
                val v = (uv[2 * (r * w + c) + 1].toInt() and 0xFF) - 128
                val y1 = 1.164f * yy
                val red = (y1 + 1.596f * v).toInt().coerceIn(0, 255)
                val green = (y1 - 0.392f * u - 0.813f * v).toInt().coerceIn(0, 255)
                val blue = (y1 + 2.017f * u).toInt().coerceIn(0, 255)
                px[r * w + c] = (0xFF shl 24) or (red shl 16) or (green shl 8) or blue
            }
        }
        val bmp = Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
        if (degrees % 360 == 0) return bmp
        val m = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(bmp, 0, 0, w, h, m, true).also { if (it !== bmp) bmp.recycle() }
    }

    companion object {
        /** Every other pixel of [image] (YUV_420_888): Y, then U and V per pixel. */
        fun copy(image: Image): HalfYuv {
            val w = image.width / 2
            val h = image.height / 2
            val yp = image.planes[0]
            val up = image.planes[1]
            val vp = image.planes[2]
            val y = ByteArray(w * h)
            val uv = ByteArray(w * h * 2)
            val yb = yp.buffer
            val ub = up.buffer
            val vb = vp.buffer
            for (r in 0 until h) {
                for (c in 0 until w) {
                    y[r * w + c] = yb.get(2 * r * yp.rowStride + 2 * c * yp.pixelStride)
                    // Chroma is at half resolution already.
                    uv[2 * (r * w + c)] = ub.get(r * up.rowStride + c * up.pixelStride)
                    uv[2 * (r * w + c) + 1] = vb.get(r * vp.rowStride + c * vp.pixelStride)
                }
            }
            return HalfYuv(w, h, y, uv)
        }
    }
}
