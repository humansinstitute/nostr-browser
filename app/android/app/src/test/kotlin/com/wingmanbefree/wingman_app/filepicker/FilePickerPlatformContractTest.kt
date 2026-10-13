package com.wingmanbefree.wingman_app.filepicker

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FilePickerPlatformContractTest {
    @Test
    fun `accept types preserve WebView MIME filters`() {
        assertArrayEquals(
            arrayOf("image/*", "image/png"),
            FilePickerPlatformContract.acceptTypes(
                mapOf("acceptTypes" to listOf("image/*", "image/png")),
            ),
        )
    }

    @Test
    fun `empty accept types fall back to all documents`() {
        assertArrayEquals(
            arrayOf("*/*"),
            FilePickerPlatformContract.acceptTypes(mapOf("acceptTypes" to emptyList<String>())),
        )
    }

    @Test
    fun `multiple selection requires the explicit WebView flag`() {
        assertTrue(
            FilePickerPlatformContract.allowsMultipleSelection(
                mapOf("allowsMultipleSelection" to true),
            ),
        )
        assertFalse(FilePickerPlatformContract.allowsMultipleSelection(emptyMap<String, Any>()))
    }
}
