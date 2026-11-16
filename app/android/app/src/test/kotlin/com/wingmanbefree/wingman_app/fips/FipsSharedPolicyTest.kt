package com.wingmanbefree.wingman_app.fips

import org.junit.Assert.*
import org.junit.Test

class FipsSharedPolicyTest {
    private val peer = "npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d"
    private val endpoint get() = FipsSharedEndpoint.parse("http://$peer.fips:8787", peer)
    private val caller = FipsSharedCaller(20001, "example.approved", "ab".repeat(32))
    private val other = caller.copy(uid = 20002, packageName = "example.other")
    private var time = 1000L
    private var sequence = 0
    private val revoked = mutableListOf<String>()
    private val policy = FipsSharedPolicy({ time }, { "request-${sequence++}" }, revoked::add)
    private val binding = FipsSharedBinding(1234L, "runtime-a")
    private fun request(): FipsSharedRequest {
        policy.updateBinding(binding)
        return policy.request(caller, endpoint)!!
    }

    @Test fun peerAddressMatchesPinnedRustVector() {
        assertEquals("fd132f39a98c31baaddba6525f5d43f2", endpoint.address.joinToString("") { "%02x".format(it) })
        assertEquals(8787, endpoint.port)
    }

    @Test fun canonicalEndpointRejectsAliasesPortsPathsAndWrongPeer() {
        listOf("https://$peer.fips:8787", "http://$peer.fips:08787", "http://$peer.fips:0",
            "http://$peer.fips:65536", "http://$peer.fips:8787/", "http://$peer.fips:8787/path",
            "http://$peer.fips:8787?x=1", "http://user@$peer.fips:8787", "http://${peer.uppercase()}.fips:8787",
            "http://$peer.fips.:8787", "http://127.0.0.1:8787").forEach {
            assertThrows(it, IllegalArgumentException::class.java) { FipsSharedEndpoint.parse(it, peer) }
        }
        assertThrows(IllegalArgumentException::class.java) { FipsSharedEndpoint.parse(endpoint.endpoint, peer.dropLast(1) + "q") }
    }

    @Test fun rejectsInvalidBech32Checksum() {
        val invalid = peer.dropLast(1) + "q"
        assertThrows(IllegalArgumentException::class.java) { FipsSharedEndpoint.parse("http://$invalid.fips:8787", invalid) }
    }

    @Test fun enrollmentRequiresActualSingleUidPackageAndCurrentCertificate() {
        val entry = listOf("${caller.packageName}|${caller.certificate}")
        assertTrue(FipsSharedEnrollment.authorized(caller, listOf(caller.packageName), listOf(caller.certificate), entry))
        assertFalse(FipsSharedEnrollment.authorized(caller, listOf(other.packageName), listOf(caller.certificate), entry))
        assertFalse(FipsSharedEnrollment.authorized(caller, listOf(caller.packageName, other.packageName), listOf(caller.certificate), entry))
        assertFalse(FipsSharedEnrollment.authorized(caller, listOf(caller.packageName), listOf("cd".repeat(32)), entry))
        assertFalse(FipsSharedEnrollment.authorized(caller, listOf(caller.packageName), listOf(caller.certificate, "cd".repeat(32)), entry))
        assertFalse(FipsSharedEnrollment.authorized(caller, listOf(caller.packageName), listOf(caller.certificate), emptyList()))
        assertFalse(FipsSharedEnrollment.authorized(caller.copy(certificate = "debug"), listOf(caller.packageName), listOf("debug"), listOf("${caller.packageName}|debug")))
    }

    @Test fun exactStableAndNightlyProviderChannelsAreSupported() {
        assertTrue(FipsSharedEnrollment.supportsProvider("com.wingmanbefree.wingman_app"))
        assertTrue(FipsSharedEnrollment.supportsProvider("com.wingmanbefree.wingman_app.nightly"))
    }
    @Test fun unknownPrefixDebugAndSuffixProviderPackagesAreDenied() {
        listOf("", "example.forged", "com.wingmanbefree", "com.wingmanbefree.wingman_app.",
            "com.wingmanbefree.wingman_app.debug", "com.wingmanbefree.wingman_app.nightly.debug",
            "com.wingmanbefree.wingman_app.nightly.extra", "com.wingmanbefree.wingman_appnightly",
            "prefix.com.wingmanbefree.wingman_app", "com.wingmanbefree.wingman_app.NIGHTLY").forEach {
            assertFalse(it, FipsSharedEnrollment.supportsProvider(it))
        }
    }
    @Test fun missingRuntimeCannotMintRequest() { assertNull(policy.request(caller, endpoint)) }
    @Test fun requestCannotBeUsedUntilConsent() {
        val request = request()
        assertEquals("pending", policy.check(request.id, caller)!!.state)
        assertEquals(0, policy.check(request.id, caller)!!.leaseDeadline)
    }
    @Test fun denialIsNotAnAllowAndCannotBeReplayed() {
        val request = request()
        assertTrue(policy.decide(request.id, caller, false))
        assertEquals("denied", policy.check(request.id, caller)!!.state)
        assertFalse(policy.decide(request.id, caller, true))
    }
    @Test fun consentAndChecksAreBoundToUidPackageCertificate() {
        val request = request()
        listOf(other, caller.copy(packageName = other.packageName), caller.copy(certificate = "cd".repeat(32))).forEach {
            assertFalse(policy.decide(request.id, it, true))
            assertNull(policy.check(request.id, it))
            policy.release(request.id, it)
            assertNotNull(policy.view(request.id, caller))
        }
    }
    @Test fun readyChecksPreserveExactBindingAndRenewWithinHardLimit() {
        val request = request()
        assertTrue(policy.decide(request.id, caller, true))
        repeat(39) { time += 15_000; assertEquals(binding, policy.check(request.id, caller)!!.binding) }
        assertEquals(601000L, policy.check(request.id, caller)!!.leaseDeadline)
        time = 601000L
        assertNull(policy.check(request.id, caller))
        assertEquals(listOf(request.id), revoked)
    }
    @Test fun missedLeaseDeadlineRevokesEvenWhenRuntimeStillPresent() {
        val request = request()
        policy.decide(request.id, caller, true)
        time += FipsSharedPolicy.LEASE_MS
        assertNull(policy.check(request.id, caller))
        assertEquals(listOf(request.id), revoked)
    }
    @Test fun pendingConsentExpiresAndOldIntentCannotAllow() {
        val request = request()
        time += FipsSharedPolicy.PENDING_MS
        assertFalse(policy.decide(request.id, caller, true))
        assertNull(policy.view(request.id))
    }
    @Test fun runtimeStopRevokesPendingAndReadyRequests() {
        val request = request()
        policy.decide(request.id, caller, true)
        val pending = policy.request(caller, endpoint)!!
        policy.updateBinding(null)
        assertNull(policy.check(request.id, caller))
        assertFalse(policy.decide(pending.id, caller, true))
        assertEquals(setOf(request.id, pending.id), revoked.toSet())
    }
    @Test fun generationChangeRevokesEvenIfNetworkHandleIsReused() {
        val request = request()
        policy.decide(request.id, caller, true)
        policy.updateBinding(binding.copy(generation = "runtime-b"))
        assertNull(policy.check(request.id, caller))
    }
    @Test fun networkReplacementCannotRebindExistingGrant() {
        val request = request()
        policy.decide(request.id, caller, true)
        policy.updateBinding(binding.copy(networkHandle = 5678L))
        assertNull(policy.check(request.id, caller))
    }
    @Test fun concurrentPortsAreIsolatedAndReleaseIsIdempotent() {
        val first = request()
        val secondEndpoint = FipsSharedEndpoint.parse("http://$peer.fips:8080", peer)
        val second = policy.request(caller, secondEndpoint)!!
        policy.decide(first.id, caller, true)
        policy.decide(second.id, caller, true)
        policy.release(first.id, caller)
        policy.release(first.id, caller)
        assertNull(policy.check(first.id, caller))
        assertEquals(secondEndpoint, policy.check(second.id, caller)!!.endpoint)
        assertEquals(listOf(first.id), revoked)
    }
    @Test fun requestFloodIsBoundedAndExpiredSlotsAreReclaimed() {
        request()
        repeat(7) { assertNotNull(policy.request(caller, endpoint)) }
        assertNull(policy.request(caller, endpoint))
        assertNotNull(policy.request(other, endpoint))
        time += FipsSharedPolicy.PENDING_MS
        assertNotNull(policy.request(caller, endpoint))
    }
    @Test fun returnedStateCannotMutateStoredConsent() {
        val request = request()
        request.state = "ready"
        assertEquals("pending", policy.check(request.id, caller)!!.state)
    }
    @Test fun revokeAllIsImmediateAndRequiresNewConsent() {
        val request = request()
        policy.decide(request.id, caller, true)
        policy.revokeAll()
        assertNull(policy.check(request.id, caller))
        assertEquals("pending", policy.request(caller, endpoint)!!.state)
    }
    @Test fun networkReadinessRequiresOwnedVpnAndExactAddressDnsAndMeshRoute() {
        val address = endpoint.address
        val route = (listOf(0xfd.toByte()) + List(15) { 0.toByte() }) to 8
        fun matches(owner: Int = caller.uid, vpn: Boolean = true,
                    addresses: List<Pair<List<Byte>, Int>> = listOf(address to 128),
                    dns: List<String> = listOf("10.1.1.1"),
                    routes: List<Pair<List<Byte>, Int>> = listOf(route)) =
            FipsSharedNetworkPolicy.matches(caller.uid, owner, vpn, address, addresses, dns, routes)
        assertTrue(matches())
        assertFalse(matches(owner = -1)) // external owner UID redaction never authorizes
        assertFalse(matches(owner = other.uid))
        assertFalse(matches(vpn = false))
        assertFalse(matches(addresses = listOf(address to 64)))
        assertFalse(matches(addresses = emptyList()))
        assertFalse(matches(dns = listOf("8.8.8.8")))
        assertFalse(matches(dns = listOf("10.1.1.1", "8.8.8.8")))
        assertFalse(matches(routes = listOf(route.first to 16)))
        assertFalse(matches(routes = emptyList()))
    }

}
