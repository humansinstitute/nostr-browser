package com.wingmanbefree.wingman_app.filepicker

internal object FilePickerPlatformContract {
    const val CHANNEL = "com.wingmanbefree.wingman_app/webview_file_picker"
    const val PICK_FILES = "pickFiles"

    fun acceptTypes(arguments: Map<*, *>?): Array<String> {
        val values = arguments?.get("acceptTypes") as? List<*> ?: emptyList<Any>()
        val types = values.mapNotNull { (it as? String)?.trim() }.filter { it.isNotEmpty() }
        return if (types.isEmpty()) arrayOf("*/*") else types.toTypedArray()
    }

    fun allowsMultipleSelection(arguments: Map<*, *>?): Boolean =
        arguments?.get("allowsMultipleSelection") == true
}
