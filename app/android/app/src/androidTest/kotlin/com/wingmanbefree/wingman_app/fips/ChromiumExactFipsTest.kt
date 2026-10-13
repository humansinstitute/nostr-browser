package com.wingmanbefree.wingman_app.fips

import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.view.ViewGroup
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.wingmanbefree.wingman_app.MainActivity
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class ChromiumExactFipsTest {
    @Test
    fun ordinaryPublicDnsStillResolvesWhileFipsVpnIsActive() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val publicName = InstrumentationRegistry.getArguments().getString("publicDnsName")
            ?: "example.com"
        assertTrue(
            "Grant WM-App VPN consent once before this device test",
            VpnService.prepare(context) == null,
        )

        try {
            val fipsDir = File(context.filesDir, "fips").apply { mkdirs() }
            val prepared = JSONObject(
                FipsNative.nativePrepare(
                    File(fipsDir, "fips.machine.key").absolutePath,
                    File(fipsDir, "control.sock").absolutePath,
                ),
            )
            assertEquals(prepared.optString("detail"), "starting", prepared.optString("state"))
            FipsVpnService.start(context)
            assertTrue("embedded FIPS did not start", waitForRunning())
            assertTrue(
                "ordinary public DNS failed while FIPS VPN was active: $publicName",
                InetAddress.getAllByName(publicName).isNotEmpty(),
            )
        } finally {
            FipsVpnService.stop(context)
        }
    }

    @Test
    fun systemWebViewLoadsExactFipsHostnameWithoutOriginRewrite() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val exactUrl = InstrumentationRegistry.getArguments().getString("fipsUrl")
            ?: error("Pass -e fipsUrl http://<npub>.fips:<port>/")
        val requested = Uri.parse(exactUrl)
        assertEquals("http", requested.scheme)
        assertTrue(requested.host?.matches(Regex("npub1[023456789acdefghjklmnpqrstuvwxyz]{58}\\.fips")) == true)
        assertTrue(requested.port in 1..65535)
        assertTrue(
            "Grant WM-App VPN consent once before this device test",
            VpnService.prepare(context) == null,
        )

        var activity: MainActivity? = null
        var webView: WebView? = null
        try {
            val fipsDir = File(context.filesDir, "fips").apply { mkdirs() }
            val prepared = JSONObject(
                FipsNative.nativePrepare(
                    File(fipsDir, "fips.machine.key").absolutePath,
                    File(fipsDir, "control.sock").absolutePath,
                ),
            )
            assertEquals(prepared.optString("detail"), "starting", prepared.optString("state"))
            FipsVpnService.start(context)
            assertTrue("embedded FIPS did not start", waitForRunning())
            assertTrue("authenticated bootstrap did not connect", waitForBootstrap())

            val launchedActivity = instrumentation.startActivitySync(
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as MainActivity
            activity = launchedActivity
            val finished = CountDownLatch(1)
            var mainFrameError: String? = null
            instrumentation.runOnMainSync {
                webView = WebView(launchedActivity).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    webViewClient = object : WebViewClient() {
                        override fun onReceivedError(
                            view: WebView,
                            request: WebResourceRequest,
                            error: WebResourceError,
                        ) {
                            if (request.isForMainFrame) {
                                mainFrameError = "${error.errorCode}: ${error.description}"
                                finished.countDown()
                            }
                        }

                        override fun onPageFinished(view: WebView, url: String) {
                            finished.countDown()
                        }
                    }
                    launchedActivity.addContentView(
                        this,
                        ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        ),
                    )
                    loadUrl(exactUrl)
                }
            }
            assertTrue("System WebView timed out loading $exactUrl", finished.await(30, TimeUnit.SECONDS))
            assertNull("System WebView failed exact .fips navigation: $mainFrameError", mainFrameError)
            instrumentation.runOnMainSync {
                val finalUrl = Uri.parse(requireNotNull(webView?.url))
                assertEquals(requested.scheme, finalUrl.scheme)
                assertEquals(requested.host, finalUrl.host)
                assertEquals(requested.port, finalUrl.port)
            }
        } finally {
            webView?.let { view ->
                instrumentation.runOnMainSync { view.destroy() }
            }
            FipsVpnService.stop(context)
            activity?.finish()
        }
    }

    private fun waitForRunning(): Boolean {
        repeat(100) {
            if (JSONObject(FipsNative.nativeInspect()).optString("state") == "running") return true
            Thread.sleep(100)
        }
        return false
    }

    private fun waitForBootstrap(): Boolean {
        repeat(30) {
            if (FipsPlatformContract.peerStatus(FipsNative.nativePeerStatus())["connected"] == true) return true
            Thread.sleep(500)
        }
        return false
    }
}
