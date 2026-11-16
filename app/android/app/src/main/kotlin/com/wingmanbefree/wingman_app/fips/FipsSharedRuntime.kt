package com.wingmanbefree.wingman_app.fips

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.InetAddresses
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.PowerManager
import android.os.Process
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Observes only the existing VPN. Never starts a runtime or binds an ordinary network. */
internal object FipsSharedRuntime {
    private var connectivity: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var receiver: BroadcastReceiver? = null
    private var app: Context? = null
    private var localAddress: ByteArray? = null
    private var underlying: Network? = null
    private var captured: Network? = null
    private var generation: String? = null
    private val monitor = Executors.newSingleThreadScheduledExecutor()
    private var tick: ScheduledFuture<*>? = null

    @Synchronized fun start(context: Context, ipv6: String, publicNetwork: Network) {
        stop()
        if (Build.VERSION.SDK_INT < 30) return
        val application = context.applicationContext
        app = application
        connectivity = application.getSystemService(ConnectivityManager::class.java)
        localAddress = InetAddresses.parseNumericAddress(ipv6).address
        underlying = publicNetwork
        generation = UUID.randomUUID().toString()
        val observer = object : ConnectivityManager.NetworkCallback() {
            private fun refreshIfCurrent() = synchronized(this@FipsSharedRuntime) {
                if (callback === this) refresh()
            }
            override fun onAvailable(network: Network) { refreshIfCurrent() }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { refreshIfCurrent() }
            override fun onLinkPropertiesChanged(network: Network, properties: android.net.LinkProperties) { refreshIfCurrent() }
            override fun onLost(network: Network) {
                synchronized(this@FipsSharedRuntime) {
                    if (callback === this && (network == captured || network == underlying)) invalidate()
                }
            }
        }
        callback = observer
        try {
            // Observe all networks so loss of the captured non-VPN underlay also revokes.
            connectivity!!.registerNetworkCallback(NetworkRequest.Builder().clearCapabilities().build(), observer)
            val lockReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    synchronized(this@FipsSharedRuntime) { if (receiver === this) suspendConsent() }
                }
            }
            receiver = lockReceiver
            val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= 33) application.registerReceiver(lockReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            else application.registerReceiver(lockReceiver, filter)
            refresh()
            tick = monitor.scheduleWithFixedDelay({
                try { refresh(); FipsSharedAccess.policy.sweep() }
                catch (_: Exception) { synchronized(this) { invalidate() } }
            }, 1, 1, TimeUnit.SECONDS)
        } catch (_: Exception) { stop() }
    }

    @Synchronized fun refresh(): FipsSharedBinding? {
        val cm = connectivity ?: return null
        val epoch = generation ?: return null
        val context = app ?: return null
        if (context.getSystemService(KeyguardManager::class.java).isDeviceLocked ||
            !context.getSystemService(PowerManager::class.java).isInteractive) {
            suspendConsent()
            return null
        }
        val underlayCaps = cm.getNetworkCapabilities(underlying ?: return null)
        if (underlayCaps == null || !FipsPlatformContract.isEligibleUnderlyingNetwork(
                underlayCaps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                underlayCaps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) || !nativeRunning()) {
            invalidate()
            return null
        }
        val network = captured
        if (network != null && !matches(network)) {
            invalidate()
            return null
        }
        // Capture exactly once per runtime. Never replace a grant's Network silently.
        val selected = network ?: cm.allNetworks.filter { matches(it) }.singleOrNull()
        if (selected == null) return null
        captured = selected
        return FipsSharedBinding(selected.networkHandle, epoch).also { FipsSharedAccess.policy.updateBinding(it) }
    }

    private fun nativeRunning(): Boolean = runCatching {
        if (Build.VERSION.SDK_INT < 29) return false
        val metadata = JSONObject(FipsNative.nativeInspect())
        metadata.optString("state") == "running" &&
            InetAddresses.parseNumericAddress(metadata.getString("ipv6")).address.contentEquals(localAddress)
    }.getOrDefault(false)

    private fun matches(network: Network): Boolean {
        if (Build.VERSION.SDK_INT < 30) return false
        val cm = connectivity ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        val links = cm.getLinkProperties(network) ?: return false
        val address = localAddress ?: return false
        return FipsSharedNetworkPolicy.matches(
            ownUid = Process.myUid(), ownerUid = caps.ownerUid,
            isVpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
            expectedAddress = address.toList(),
            addresses = links.linkAddresses.map { it.address.address.toList() to it.prefixLength },
            dnsServers = links.dnsServers.map { it.hostAddress ?: "" },
            routes = links.routes.map { it.destination.address.address.toList() to it.destination.prefixLength },
        )
    }

    private fun suspendConsent() {
        if (generation != null) generation = UUID.randomUUID().toString()
        FipsSharedAccess.policy.updateBinding(null)
    }

    private fun invalidate() {
        generation = null
        captured = null
        tick?.cancel(false)
        tick = null
        FipsSharedAccess.policy.updateBinding(null)
    }

    @Synchronized fun stop() {
        invalidate()
        callback?.let { observer -> runCatching { connectivity?.unregisterNetworkCallback(observer) } }
        receiver?.let { observer -> runCatching { app?.unregisterReceiver(observer) } }
        callback = null
        receiver = null
        connectivity = null
        app = null
        localAddress = null
        underlying = null
    }
}
