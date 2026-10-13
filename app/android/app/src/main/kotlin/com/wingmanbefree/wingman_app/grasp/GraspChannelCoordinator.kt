package com.wingmanbefree.wingman_app.grasp

import android.webkit.WebView
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Frame-aware bridge on the exact WebView owned by webview_flutter. */
class GraspChannelCoordinator(
    private val channel: MethodChannel,
    private val lookup: (Long) -> WebView?,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "wingman/grasp_android"
        const val HOME_ORIGIN = "https://wingman.local/"

        // Flutter's stock loadHtmlString supplies null historyUrl, leaving the
        // native current URL about:blank. Fix that only for native-owned home
        // content; retain the exact-origin policy used by normal documents.
        fun loadHomeHtml(view: WebView, html: String) {
            view.loadDataWithBaseURL(HOME_ORIGIN, html, "text/html", "UTF-8", HOME_ORIGIN)
        }
    }
    private val installed = mutableMapOf<Long, WebView>()
    private var destroyed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Number>("webViewIdentifier")?.toLong()
        if (id == null) {
            result.error("invalid_webview", "A native WebView identifier is required", null)
            return
        }
        when (call.method) {
            "loadHomeHtml" -> {
                val html = call.argument<String>("html")
                val view = if (destroyed) null else lookup(id)
                if (view == null || html == null || html.length > GraspMessagePolicy.MAX_MESSAGE_LENGTH) {
                    result.error("invalid_home", "A live WebView and bounded home HTML are required", null)
                } else {
                    loadHomeHtml(view, html)
                    result.success(null)
                }
            }
            "install" -> result.success(install(id))
            "remove" -> { remove(id); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun install(id: Long): Boolean {
        if (destroyed || !WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) return false
        val view = lookup(id) ?: return false
        if (installed[id] === view) return true
        remove(id)
        installed[id] = view
        try {
            for (name in GraspMessagePolicy.channels) {
                // A general browser changes origins. Wildcard makes the channel available;
                // native frame/scheme/exact-current-origin checks below confer authority.
                // addJavascriptInterface is never an acceptable fallback.
                WebViewCompat.addWebMessageListener(view, name, setOf("*")) { sender, message, origin, mainFrame, _ ->
                    if (destroyed || installed[id] !== sender || message.type != WebMessageCompat.TYPE_STRING ||
                        !GraspMessagePolicy.accepts(name, mainFrame, origin.toString(), sender.url)) return@addWebMessageListener
                    val body = message.data ?: return@addWebMessageListener
                    if (body.length > GraspMessagePolicy.MAX_MESSAGE_LENGTH) return@addWebMessageListener
                    channel.invokeMethod("message", mapOf("webViewIdentifier" to id, "channel" to name, "message" to body))
                }
            }
            return true
        } catch (_: RuntimeException) {
            remove(id)
            return false
        }
    }

    private fun remove(id: Long) {
        val view = installed.remove(id) ?: return
        for (name in GraspMessagePolicy.channels) {
            try { WebViewCompat.removeWebMessageListener(view, name) } catch (_: RuntimeException) { }
        }
    }

    fun destroy() {
        destroyed = true
        installed.keys.toList().forEach(::remove)
    }
}
