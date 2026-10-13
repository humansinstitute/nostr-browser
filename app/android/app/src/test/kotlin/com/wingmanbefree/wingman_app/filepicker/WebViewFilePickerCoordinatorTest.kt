package com.wingmanbefree.wingman_app.filepicker

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WebViewFilePickerCoordinatorTest {
    @Test
    fun `routes multiple selection and returns content URIs`() {
        var singleTypes: Array<String>? = null
        var multipleTypes: Array<String>? = null
        val coordinator = WebViewFilePickerCoordinator(
            launchSingleDocument = { singleTypes = it },
            launchMultipleDocuments = { multipleTypes = it },
        )
        val result = RecordingResult()

        coordinator.onMethodCall(
            MethodCall(
                FilePickerPlatformContract.PICK_FILES,
                mapOf(
                    "acceptTypes" to listOf("image/*"),
                    "allowsMultipleSelection" to true,
                ),
            ),
            result,
        )
        coordinator.complete(listOf("content://picker/one", "content://picker/two"))

        assertNull(singleTypes)
        assertEquals(listOf("image/*"), multipleTypes?.toList())
        assertEquals(
            listOf("content://picker/one", "content://picker/two"),
            result.successValue,
        )
    }

    @Test
    fun `routes single selection and cancellation as an empty result`() {
        var singleTypes: Array<String>? = null
        val coordinator = WebViewFilePickerCoordinator(
            launchSingleDocument = { singleTypes = it },
            launchMultipleDocuments = {},
        )
        val result = RecordingResult()

        coordinator.onMethodCall(
            MethodCall(FilePickerPlatformContract.PICK_FILES, emptyMap<String, Any>()),
            result,
        )
        coordinator.complete(null as String?)

        assertEquals(listOf("*/*"), singleTypes?.toList())
        assertEquals(emptyList<String>(), result.successValue)
    }
}

private class RecordingResult : MethodChannel.Result {
    var successValue: Any? = null

    override fun success(result: Any?) {
        successValue = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        throw AssertionError("Unexpected method-channel error: $errorCode $errorMessage")
    }

    override fun notImplemented() {
        throw AssertionError("Unexpected notImplemented response")
    }
}
