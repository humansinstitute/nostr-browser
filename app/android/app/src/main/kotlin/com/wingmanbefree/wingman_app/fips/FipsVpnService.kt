package com.wingmanbefree.wingman_app.fips

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import com.wingmanbefree.wingman_app.MainActivity
import com.wingmanbefree.wingman_app.R
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class FipsVpnService : VpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private var tun: ParcelFileDescriptor? = null
    @Volatile private var stopped = false
    @Volatile private var creationFailed = false

    override fun onCreate() {
        super.onCreate()
        diagnostic("service_create_started", serviceState = "creating", critical = true)
        try {
            promote("Starting embedded FIPS mesh…")
            current = this
            Log.i(TAG, "service_created")
            diagnostic("foreground_promoted", serviceState = "foreground", critical = true)
        } catch (failure: Throwable) {
            creationFailed = true
            recordFailure("foreground_start_failed", "Android could not show the FIPS VPN foreground service.", failure)
            runCatching { stopSelf() }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            executeWorker { shutdown() }
            return START_NOT_STICKY
        }
        if (creationFailed) {
            safeShutdown()
            return START_NOT_STICKY
        }
        try {
            promote("Starting embedded FIPS mesh…")
        } catch (failure: Throwable) {
            recordFailure("foreground_start_failed", "Android could not start the FIPS VPN foreground service.", failure)
            safeShutdown()
            return START_NOT_STICKY
        }
        if (!executeWorker {
            stopped = false
            try {
                establishAndRun()
            } catch (failure: Throwable) {
                recordFailure("vpn_establish_failed", "The embedded FIPS VPN could not be established.", failure)
                safeShutdown()
            }
        }) {
            recordFailure("service_executor_failed", "The embedded FIPS VPN startup was interrupted.")
            safeShutdown()
        }
        return START_NOT_STICKY
    }

    @Synchronized
    private fun establishAndRun() {
        if (stopped || tun != null) return
        diagnostic("vpn_establish_started", phase = "vpn", serviceState = "starting", critical = true)
        val metadata = JSONObject(FipsNative.nativeInspect())
        val ipv6 = metadata.optString("ipv6")
        if (ipv6.isBlank()) {
            failClosed("native_metadata_failed", "Embedded FIPS startup data was unavailable.")
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            failClosed("android_version_unsupported", "Embedded FIPS requires Android 10 or later.")
            return
        }
        val underlyingNetwork = selectUnderlyingNetwork()
        if (underlyingNetwork == null) {
            failClosed("network_unavailable", "No eligible internet connection was available for embedded FIPS.")
            return
        }

        val spec = FipsPlatformContract.vpnSpec
        // Deliberately no addDisallowedApplication(packageName): WM-App's own
        // WebView must enter this VPN. FIPS UDP sockets are protected below.
        val descriptor = Builder()
            .setSession("Nostr Browser FIPS mesh")
            .addAddress(ipv6, spec.ipv6Prefix)
            .addAddress(FipsPlatformContract.VPN_ADDRESS, spec.dnsPrefix)
            .addRoute(FipsPlatformContract.MESH_ROUTE, spec.meshPrefix)
            .addRoute(FipsPlatformContract.DNS_ADDRESS, spec.dnsPrefix)
            .addDnsServer(FipsPlatformContract.DNS_ADDRESS)
            .setUnderlyingNetworks(arrayOf(underlyingNetwork))
            .setMtu(spec.mtu)
            .setBlocking(true)
            .establish()
        if (descriptor == null) {
            failClosed("vpn_establish_denied", "Android did not create the embedded FIPS VPN interface.")
            return
        }
        tun = descriptor
        diagnostic("vpn_established", phase = "vpn", serviceState = "established", critical = true)

        diagnostic("native_start_started", phase = "native_start", fipsStatus = "starting", critical = true)
        val started = JSONObject(FipsNative.nativeStartNode())
        val sockets = started.optJSONArray("transportSockets")
        if (!started.optBoolean("ok") || sockets == null || sockets.length() == 0) {
            failClosed("native_start_failed", "Embedded FIPS transport startup failed.")
            return
        }
        for (index in 0 until sockets.length()) {
            val fd = sockets.getJSONObject(index).getInt("fd")
            if (!protect(fd)) {
                failClosed("socket_protection_failed", "Android could not protect the FIPS transport socket.")
                return
            }
        }

        val rustFd = ParcelFileDescriptor.dup(descriptor.fileDescriptor).detachFd()
        val running = JSONObject(
            FipsNative.nativeRunNode(rustFd, underlyingNetwork.networkHandle),
        )
        if (running.optString("state") != "running") {
            failClosed("native_run_failed", "Embedded FIPS did not enter its running state.")
            return
        }
        diagnostic("native_running", phase = "readiness", fipsStatus = "running", serviceState = "running", critical = true)
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification("Routing fd00::/8 and .fips DNS"))
    }

    private fun selectUnderlyingNetwork(): Network? {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val active = connectivity.activeNetwork
        val candidates = buildList {
            if (active != null) add(active)
            addAll(connectivity.allNetworks.filterNot { it == active })
        }
        return candidates.firstOrNull { network ->
            val capabilities = connectivity.getNetworkCapabilities(network) ?: return@firstOrNull false
            FipsPlatformContract.isEligibleUnderlyingNetwork(
                hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                isVpn = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
            )
        }
    }

    private fun failClosed(code: String, detail: String) {
        recordFailure(code, detail)
        safeShutdown()
    }

    @Synchronized
    private fun resetForStart() {
        // The coordinator owns and sanitizes reset errors so the originating
        // method call is completed rather than silently continuing.
        FipsNative.nativeStop()
        tun?.close()
        tun = null
        stopped = false
    }

    @Synchronized
    private fun shutdown() {
        if (stopped) return
        stopped = true
        runCatching { FipsNative.nativeStop() }
            .onFailure { Log.e(TAG, "native_stop_failed (${it.javaClass.simpleName})") }
        runCatching { tun?.close() }
            .onFailure { Log.e(TAG, "tun_close_failed (${it.javaClass.simpleName})") }
        tun = null
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        runCatching { stopSelf() }
    }

    override fun onRevoke() {
        diagnostic("vpn_revoked", phase = "vpn", consentState = "revoked", serviceState = "stopping")
        executeWorker { shutdown() }
        super.onRevoke()
    }

    override fun onDestroy() {
        diagnostic("service_destroyed", serviceState = "destroyed", critical = true)
        if (current === this) current = null
        if (!stopped && !worker.isShutdown) {
            executeWorker { shutdown() }
        }
        worker.shutdown()
        super.onDestroy()
    }

    private fun notification(detail: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "FIPS mesh VPN", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return builder
            .setContentTitle("Nostr Browser FIPS VPN active")
            .setContentText(detail)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .build()
    }

    private fun promote(detail: String) {
        // POST_NOTIFICATIONS is not a prerequisite for foreground-service
        // correctness on Android 13+: a denied notification permission hides
        // the drawer notification but Android still exposes the FGS in Task
        // Manager. VPN consent is the only runtime permission requested here.
        startForeground(NOTIFICATION_ID, notification(detail))
    }

    private fun safeShutdown() {
        runCatching { shutdown() }
            .onFailure { Log.e(TAG, "shutdown_failed (${it.javaClass.simpleName})") }
    }

    private fun executeWorker(task: () -> Unit): Boolean = try {
        if (worker.isShutdown) false else {
            worker.execute { runCatching(task).onFailure { recordFailure("service_worker_failed", "The embedded FIPS VPN stopped unexpectedly.", it) } }
            true
        }
    } catch (_: RejectedExecutionException) {
        false
    }

    private fun recordFailure(code: String, detail: String, failure: Throwable? = null) {
        FipsVpnServiceFailure.record(code, detail)
        diagnostic(code, fipsStatus = "failed", errorCode = code, serviceState = "failed", failure = failure, critical = true)
        if (failure == null) Log.e(TAG, code)
        else Log.e(TAG, "$code (${failure.javaClass.simpleName})")
    }

    private fun diagnostic(
        event: String,
        phase: String = "service",
        fipsStatus: String = "unknown",
        errorCode: String = "unknown",
        consentState: String = "unknown",
        serviceState: String = "unknown",
        failure: Throwable? = null,
        critical: Boolean = false,
    ) = FipsDiagnostics.record(
        this, event, phase, fipsStatus, errorCode, consentState, serviceState, failure, critical,
    )

    companion object {
        private const val ACTION_STOP = "com.wingmanbefree.wingman_app.fips.STOP"
        private const val CHANNEL_ID = "wmapp_fips_vpn"
        private const val NOTIFICATION_ID = 2121
        private const val TAG = "WMAppFipsVpn"
        @Volatile private var current: FipsVpnService? = null

        fun start(context: Context) {
            val intent = Intent(context, FipsVpnService::class.java)
            FipsVpnServiceFailure.clear()
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (failure: Throwable) {
                FipsVpnServiceFailure.record(
                    "service_launch_failed",
                    "Android blocked the embedded FIPS VPN from starting. Please retry from WM-App.",
                )
                Log.e(TAG, "service_launch_failed (${failure.javaClass.simpleName})")
                FipsDiagnostics.record(context, "service_launch_failed", phase = "service", fipsStatus = "failed", errorCode = "service_launch_failed", serviceState = "failed", failure = failure, critical = true)
                throw failure
            }
        }

        fun stop(context: Context) {
            val service = current
            if (service != null) {
                service.shutdown()
            } else {
                FipsNative.nativeStop()
                context.stopService(Intent(context, FipsVpnService::class.java))
            }
        }

        fun resetForStart(context: Context) {
            val service = current
            if (service != null) {
                service.resetForStart()
            } else {
                FipsNative.nativeStop()
                context.stopService(Intent(context, FipsVpnService::class.java))
            }
        }
    }
}
