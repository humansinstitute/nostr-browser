package com.wingmanbefree.wingman_app.fips

import android.net.DnsResolver
import android.net.Network
import android.os.Build
import android.os.CancellationSignal
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

internal object FipsNative {
    init {
        System.loadLibrary("wmapp_fips_android")
    }

    external fun nativePrepare(identityPath: String, controlPath: String): String
    external fun nativeStartNode(): String
    external fun nativeRunNode(tunFd: Int, publicNetworkHandle: Long): String
    external fun nativeInspect(): String
    external fun nativeStop(): String
    external fun nativePeerStatus(): String
    external fun nativeProbe(npub: String): String

    /** Uses Android's resolver on the captured non-VPN network, including Private DNS policy. */
    @JvmStatic
    fun resolvePublicDns(query: ByteArray, networkHandle: Long): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || networkHandle == 0L) return null
        return runCatching {
            val answer = AtomicReference<ByteArray?>()
            val done = CountDownLatch(1)
            val cancellation = CancellationSignal()
            @Suppress("DEPRECATION")
            DnsResolver.getInstance().rawQuery(
                Network.fromNetworkHandle(networkHandle),
                query,
                DnsResolver.FLAG_EMPTY,
                { command -> command.run() },
                cancellation,
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(result: ByteArray, rcode: Int) {
                        answer.set(result)
                        done.countDown()
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        done.countDown()
                    }
                },
            )
            if (!done.await(PUBLIC_DNS_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                cancellation.cancel()
                null
            } else {
                answer.get()
            }
        }.getOrNull()
    }

    private const val PUBLIC_DNS_TIMEOUT_SECONDS = 5L
}
