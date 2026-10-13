package com.wingmanbefree.wingman_app.fips

internal object FipsPlatformContract {
    const val CHANNEL = "com.wingmanbefree.wingman_app/fips"
    const val BOOTSTRAP_NPUB =
        "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98"
    const val DNS_ADDRESS = "10.1.1.1"
    const val VPN_ADDRESS = "10.1.1.2"
    const val MESH_ROUTE = "fd00::"

    val vpnSpec = VpnSpec(
        ipv6Prefix = 128,
        meshPrefix = 8,
        dnsPrefix = 32,
        mtu = 1280,
        disallowedApplications = emptyList(),
    )

    fun isEligibleUnderlyingNetwork(hasInternet: Boolean, isVpn: Boolean): Boolean =
        hasInternet && !isVpn

    fun peerStatus(raw: String): Map<String, Any?> {
        val connected = runCatching {
            val response = org.json.JSONObject(raw)
            val data = response.optJSONObject("data") ?: response
            val peers = data.optJSONArray("peers") ?: return@runCatching false
            (0 until peers.length()).any { index ->
                val peer = peers.optJSONObject(index) ?: return@any false
                peer.optString("npub") == BOOTSTRAP_NPUB &&
                    peer.optString("connectivity").equals("connected", ignoreCase = true)
            }
        }.getOrDefault(false)
        return mapOf(
            "connected" to connected,
            "detail" to if (connected) {
                "Authenticated Wingman bootstrap connected."
            } else {
                "Waiting for authenticated Wingman bootstrap over UDP 2121."
            },
        )
    }

    fun probe(raw: String): Map<String, Any?> {
        val overall = Regex("""[\"']overall[\"']\s*:\s*[\"']([^\"']+)[\"']""")
            .find(raw)?.groupValues?.getOrNull(1)
        return mapOf(
            "ok" to (overall == "ok"),
            "detail" to when (overall) {
                null, "" -> "FIPS probe failed."
                else -> "FIPS probe completed: $overall."
            },
        )
    }
}

internal data class VpnSpec(
    val ipv6Prefix: Int,
    val meshPrefix: Int,
    val dnsPrefix: Int,
    val mtu: Int,
    val disallowedApplications: List<String>,
)
