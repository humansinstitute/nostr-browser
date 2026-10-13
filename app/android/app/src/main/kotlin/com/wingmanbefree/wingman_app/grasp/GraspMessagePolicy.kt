package com.wingmanbefree.wingman_app.grasp

import java.net.URI
import java.util.Locale

/** Native frame authority; page-supplied origin fields are never trusted. */
object GraspMessagePolicy {
    val channels = setOf("WingmanGrasp", "WingmanSigner")
    const val MAX_MESSAGE_LENGTH = 1_500_000

    fun accepts(channel: String, mainFrame: Boolean, sourceOrigin: String, currentUrl: String?): Boolean {
        if (!mainFrame || channel !in channels || currentUrl == null) return false
        val source = origin(sourceOrigin) ?: return false
        val current = origin(currentUrl) ?: return false
        if (channel == "WingmanGrasp" && source.scheme != "https" && source != Origin("http", "127.0.0.1", 47831)) return false
        return source == current
    }

    private data class Origin(val scheme: String, val host: String, val port: Int)

    private fun origin(value: String): Origin? = try {
        val uri = URI(value)
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
        val host = uri.host?.lowercase(Locale.ROOT)
        if (scheme !in setOf("https", "http") || host.isNullOrEmpty() || uri.rawUserInfo != null ||
            uri.port < -1 || uri.port > 65535) null
        else Origin(scheme!!, host, if (uri.port == -1) (if (scheme == "https") 443 else 80) else uri.port)
    } catch (_: Exception) { null }
}
