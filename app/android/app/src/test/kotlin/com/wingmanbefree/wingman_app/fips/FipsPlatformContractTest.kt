package com.wingmanbefree.wingman_app.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FipsPlatformContractTest {
    @Test
    fun vpnSpecKeepsWmAppInsideVpnAndRoutesOnlyMeshAndDns() {
        val spec = FipsPlatformContract.vpnSpec
        assertEquals(8, spec.meshPrefix)
        assertEquals(32, spec.dnsPrefix)
        assertEquals(1280, spec.mtu)
        assertTrue(spec.disallowedApplications.isEmpty())
    }

    @Test
    fun publicDnsRequiresAnInternetCapableNonVpnUnderlyingNetwork() {
        assertTrue(FipsPlatformContract.isEligibleUnderlyingNetwork(hasInternet = true, isVpn = false))
        assertFalse(FipsPlatformContract.isEligibleUnderlyingNetwork(hasInternet = true, isVpn = true))
        assertFalse(FipsPlatformContract.isEligibleUnderlyingNetwork(hasInternet = false, isVpn = false))
    }

    @Test
    fun mapsAuthenticatedBootstrapConnection() {
        val connected = FipsPlatformContract.peerStatus(
            """{"data":{"peers":[{"npub":"${FipsPlatformContract.BOOTSTRAP_NPUB}","connectivity":"connected"}]}}""",
        )
        assertEquals(true, connected["connected"])

        val other = FipsPlatformContract.peerStatus("""{"data":{"peers":[]}}""")
        assertFalse(other["connected"] as Boolean)

        val disconnected = FipsPlatformContract.peerStatus(
            """{"peers":[{"npub":"${FipsPlatformContract.BOOTSTRAP_NPUB}","connectivity":"disconnected"},{"npub":"other","connectivity":"connected"}]}""",
        )
        assertFalse(disconnected["connected"] as Boolean)

        val spoofed = FipsPlatformContract.peerStatus(
            """{"data":{"peers":[{"npub":"other","display_name":"${FipsPlatformContract.BOOTSTRAP_NPUB}","connectivity":"connected"}]}}""",
        )
        assertFalse(spoofed["connected"] as Boolean)

        assertFalse(FipsPlatformContract.peerStatus("not json")["connected"] as Boolean)
    }

    @Test
    fun mapsProbeOutcomeWithoutSecrets() {
        val result = FipsPlatformContract.probe("""{"data":{"overall":"ok"}}""")
        assertEquals(true, result["ok"])
        assertFalse(result["detail"].toString().contains("nsec1"))
    }
}
