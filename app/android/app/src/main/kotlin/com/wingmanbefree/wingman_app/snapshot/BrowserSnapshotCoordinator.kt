package com.wingmanbefree.wingman_app.snapshot

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.webkit.WebView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/** Draws an attached, visible WebView into a small in-memory tab preview. */
class BrowserSnapshotCoordinator(
    private val lookup: (Long) -> WebView?,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "wingman/browser_snapshot"
        private const val MAX_WIDTH = 640
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "capture") {
            result.notImplemented()
            return
        }
        val id = call.argument<Number>("webViewIdentifier")?.toLong()
        val view = id?.let(lookup)
        if (view == null || !view.isAttachedToWindow || view.visibility != View.VISIBLE ||
            view.width <= 0 || view.height <= 0) {
            result.success(null)
            return
        }
        val requested = call.argument<Number>("width")?.toInt() ?: MAX_WIDTH
        val width = requested.coerceIn(1, MAX_WIDTH).coerceAtMost(view.width)
        val scale = width.toFloat() / view.width
        val height = (view.height * scale).toInt().coerceAtLeast(1)
        try {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.scale(scale, scale)
            view.draw(canvas)
            val output = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 70, output)
            bitmap.recycle()
            result.success(output.toByteArray())
        } catch (_: RuntimeException) {
            result.success(null)
        } catch (_: OutOfMemoryError) {
            result.success(null)
        }
    }
}
