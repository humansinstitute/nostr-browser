package com.wingmanbefree.wingman_app.download

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.DownloadListener
import android.webkit.WebView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

internal class BrowserDownloadCoordinator(
    private val context: Context,
    private val channel: MethodChannel,
    private val lookup: (Long) -> WebView?,
    private val launchLegacyDestination: (String) -> Unit,
) : MethodChannel.MethodCallHandler {
    companion object { const val CHANNEL = "wingman/browser_download" }

    private val installed = mutableMapOf<Long, WebView>()
    private val executor = Executors.newSingleThreadExecutor()
    private var pendingLegacy: Pair<Map<*, *>, MethodChannel.Result>? = null
    private var destroyed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "install" -> {
                val id = call.argument<Number>("webViewIdentifier")?.toLong()
                result.success(id != null && install(id))
            }
            "export" -> export(call.arguments as? Map<*, *>, result)
            else -> result.notImplemented()
        }
    }

    private fun install(id: Long): Boolean {
        if (destroyed) return false
        val view = lookup(id) ?: return false
        if (installed[id] === view) return true
        val listener = DownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
            if (destroyed || installed[id] !== view || url.isNullOrBlank()) return@DownloadListener
            channel.invokeMethod("request", mapOf(
                "url" to url,
                "signal" to if (contentDisposition?.contains("attachment", ignoreCase = true) == true) "response" else "htmlDownload",
                "contentDisposition" to contentDisposition,
                "mimeType" to mimeType,
                "userAgent" to userAgent,
            ))
        }
        view.setDownloadListener(listener)
        installed[id] = view
        return true
    }

    private fun export(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val path = arguments?.get("path") as? String
        val filename = arguments?.get("filename") as? String
        if (destroyed || path.isNullOrBlank() || filename.isNullOrBlank() || !File(path).isFile) {
            result.error("invalid_export", "The downloaded file is unavailable.", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            if (pendingLegacy != null) {
                result.error("export_active", "Another save destination is already open.", null)
                return
            }
            pendingLegacy = arguments to result
            launchLegacyDestination(filename)
            return
        }
        executor.execute {
            try {
                val resolver = context.contentResolver
                val relative = Environment.DIRECTORY_DOWNLOADS + "/"
                val safeName = availableName(filename, relative)
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, safeName)
                    put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                    put(MediaStore.Downloads.RELATIVE_PATH, relative)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: error("Downloads did not provide a destination")
                try {
                    resolver.openOutputStream(uri, "w")!!.use { output ->
                        File(path).inputStream().use { it.copyTo(output) }
                    }
                    values.clear(); values.put(MediaStore.Downloads.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                } catch (error: Throwable) {
                    resolver.delete(uri, null, null)
                    throw error
                }
                context.mainExecutor.execute {
                    result.success(mapOf("outcome" to "success", "destination" to "Downloads/$safeName"))
                }
            } catch (_: Throwable) {
                context.mainExecutor.execute {
                    result.error("export_failed", "Android could not save the file to Downloads.", null)
                }
            }
        }
    }

    private fun availableName(filename: String, relative: String): String {
        val dot = filename.lastIndexOf('.')
        val stem = if (dot > 0) filename.substring(0, dot) else filename
        val extension = if (dot > 0) filename.substring(dot) else ""
        var candidate = filename
        var suffix = 1
        while (exists(candidate, relative)) candidate = "$stem (${suffix++})$extension"
        return candidate
    }

    private fun exists(filename: String, relative: String): Boolean {
        context.contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Downloads._ID),
            "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?",
            arrayOf(filename, relative),
            null,
        ).use { return it?.moveToFirst() == true }
    }

    fun completeLegacyDestination(uriText: String?) {
        val pending = pendingLegacy ?: return
        pendingLegacy = null
        if (uriText == null) {
            pending.second.success(mapOf("outcome" to "cancelled", "destination" to ""))
            return
        }
        try {
            val path = pending.first["path"] as String
            context.contentResolver.openOutputStream(Uri.parse(uriText), "w")!!.use { output ->
                File(path).inputStream().use { it.copyTo(output) }
            }
            pending.second.success(mapOf("outcome" to "success", "destination" to "selected folder"))
        } catch (_: Throwable) {
            pending.second.error("export_failed", "Android could not save the selected file.", null)
        }
    }

    fun destroy() {
        destroyed = true
        installed.values.forEach { it.setDownloadListener(null) }
        installed.clear()
        pendingLegacy?.second?.success(mapOf("outcome" to "cancelled", "destination" to ""))
        pendingLegacy = null
        executor.shutdownNow()
    }
}
