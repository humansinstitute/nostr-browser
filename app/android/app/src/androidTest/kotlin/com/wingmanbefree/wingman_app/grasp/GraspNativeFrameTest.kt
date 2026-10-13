package com.wingmanbefree.wingman_app.grasp

import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Synthetic documents only: no signer, profiles, VPN, private service, or network. */
@RunWith(AndroidJUnit4::class)
class GraspNativeFrameTest {
    @Test fun nativeMetadataRejectsSameOriginIframe() = exerciseFrames("https://synthetic.example/", true)

    @Test fun nativeMetadataRejectsHttpGraspWhilePreservingTopFrameSigner() = exerciseFrames("http://synthetic.example/", false)

    @Test fun syntheticHomeSignerAcceptsAfterPageFinished() = exerciseFrames("https://wingman.local/", true, true)

    private fun exerciseFrames(url: String, graspTopAccepted: Boolean, loadData: Boolean = false) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val messages = mutableMapOf<String, Boolean>()
        val metadata = mutableMapOf<String, String>()
        val delivered = CountDownLatch(6)
        var webView: WebView? = null
        try {
            instrumentation.runOnMainSync {
                assertTrue("WEB_MESSAGE_LISTENER is required; never fall back", WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER))
                val view = WebView(instrumentation.targetContext)
                webView = view
                view.settings.javaScriptEnabled = true
                for (name in GraspMessagePolicy.channels) {
                    WebViewCompat.addWebMessageListener(view, name, setOf("*")) { sender, message, origin, mainFrame, _ ->
                        synchronized(messages) {
                            metadata["$name:${message.data}"] = "frame=$mainFrame source=$origin current=${sender.url}"
                            messages["$name:${message.data}"] = GraspMessagePolicy.accepts(name, mainFrame, origin.toString(), sender.url)
                        }
                        delivered.countDown()
                    }
                }
                val topScript = GraspMessagePolicy.channels.joinToString(";") { "$it.postMessage('top')" }
                val frameScript = GraspMessagePolicy.channels.joinToString(";") { "$it.postMessage('iframe')" }
                val html = """
                    <!doctype html><html><body><script>
                    window.runFrames = function() {
                        $topScript;
                        const frame = document.createElement('iframe');
                        frame.srcdoc = "<script>$frameScript<" + "/script>";
                        document.body.appendChild(frame);
                    };
                    </script></body></html>
                """.trimIndent()
                view.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String) {
                        view.evaluateJavascript("window.runFrames()", null)
                    }
                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                        return WebResourceResponse("text/html", "UTF-8", ByteArrayInputStream(html.toByteArray()))
                    }
                }
                if (loadData) GraspChannelCoordinator.loadHomeHtml(view, html) else view.loadUrl(url)
            }
            assertTrue("Both native frame messages must arrive", delivered.await(15, TimeUnit.SECONDS))
            synchronized(messages) {
                for (name in GraspMessagePolicy.channels) {
                    assertEquals("$name ${metadata["$name:top"]}", if (name == "WingmanGrasp") graspTopAccepted else true, messages["$name:top"])
                    assertEquals(name, false, messages["$name:iframe"])
                }
            }
        } finally {
            instrumentation.runOnMainSync { webView?.destroy() }
        }
    }
}
