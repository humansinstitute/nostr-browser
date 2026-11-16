package com.wingmanbefree.wingman_app.grasp

/** Flutter-owned selector HTML, never an incoming web message or remote document. */
object NativeHomeHtmlPolicy {
    // The bundled background alone becomes ~2.2M characters as a data URL.
    // Bound the complete document independently of untrusted message payloads.
    const val MAX_HTML_LENGTH = 8_000_000
    fun accepts(html: String): Boolean = html.length <= MAX_HTML_LENGTH
}
