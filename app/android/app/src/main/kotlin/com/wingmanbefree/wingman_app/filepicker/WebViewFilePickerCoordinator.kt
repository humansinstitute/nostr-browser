package com.wingmanbefree.wingman_app.filepicker

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class WebViewFilePickerCoordinator(
    private val launchSingleDocument: (Array<String>) -> Unit,
    private val launchMultipleDocuments: (Array<String>) -> Unit,
) : MethodChannel.MethodCallHandler {
    private var pendingResult: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != FilePickerPlatformContract.PICK_FILES) {
            result.notImplemented()
            return
        }
        if (pendingResult != null) {
            result.error("picker_active", "A file picker is already open.", null)
            return
        }

        val arguments = call.arguments as? Map<*, *>
        val acceptTypes = FilePickerPlatformContract.acceptTypes(arguments)
        pendingResult = result
        try {
            if (FilePickerPlatformContract.allowsMultipleSelection(arguments)) {
                launchMultipleDocuments(acceptTypes)
            } else {
                launchSingleDocument(acceptTypes)
            }
        } catch (_: RuntimeException) {
            pendingResult = null
            result.error("picker_unavailable", "The system file picker is unavailable.", null)
        }
    }

    fun complete(uri: String?) = complete(uri?.let(::listOf) ?: emptyList())

    fun complete(uris: List<String>) {
        pendingResult?.success(uris)
        pendingResult = null
    }

    fun destroy() {
        pendingResult?.success(emptyList<String>())
        pendingResult = null
    }
}
