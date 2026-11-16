package com.wingmanbefree.wingman_app.fips

import java.math.BigInteger
import java.net.InetAddress
import java.security.MessageDigest
import java.util.UUID

/** No Android/runtime/key custody dependency: exact public peer and consent policy. */
internal data class FipsSharedEndpoint(val endpoint: String, val peerNpub: String, val port: Int, val address: List<Byte>) {
    val ipv6: String get() = InetAddress.getByAddress(address.toByteArray()).hostAddress!!

    companion object {
        private const val alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        private val origin = Regex("^http://(npub1[${alphabet}]{58})\\.fips:([1-9][0-9]{0,4})$")
        private val field = BigInteger("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f", 16)

        fun parse(endpoint: String, peerNpub: String): FipsSharedEndpoint {
            val match = origin.matchEntire(endpoint) ?: throw IllegalArgumentException("invalid endpoint")
            require(match.groupValues[1] == peerNpub)
            val port = match.groupValues[2].toInt().also { require(it in 1..65535) }
            val words = peerNpub.substring(5).map { alphabet.indexOf(it) }
            var checksum = 1
            val generators = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
            val hrp = "npub".map { it.code shr 5 } + listOf(0) + "npub".map { it.code and 31 }
            for (word in hrp + words) {
                val top = checksum ushr 25
                checksum = ((checksum and 0x1ffffff) shl 5) xor word
                for (i in 0..4) if (((top ushr i) and 1) != 0) checksum = checksum xor generators[i]
            }
            require(checksum == 1)
            val bytes = mutableListOf<Byte>()
            var accumulator = 0
            var bits = 0
            for (word in words.dropLast(6)) {
                accumulator = ((accumulator shl 5) or word) and 0xffff
                bits += 5
                if (bits >= 8) { bits -= 8; bytes += (accumulator ushr bits).toByte() }
            }
            require(bytes.size == 32 && bits < 5 && (accumulator and ((1 shl bits) - 1)) == 0)
            // An npub is an x-only secp256k1 point, not any 32-byte string.
            val x = BigInteger(1, bytes.toByteArray())
            require(x < field)
            val ySquared = x.modPow(BigInteger.valueOf(3), field).add(BigInteger.valueOf(7)).mod(field)
            val y = ySquared.modPow(field.add(BigInteger.ONE).shiftRight(2), field)
            require(y.multiply(y).mod(field) == ySquared)
            val hash = MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray())
            return FipsSharedEndpoint(endpoint, peerNpub, port, listOf(0xfd.toByte()) + hash.take(15))
        }
    }
}

internal data class FipsSharedCaller(val uid: Int, val packageName: String, val certificate: String)
internal object FipsSharedEnrollment {
    fun supportsProvider(packageName: String): Boolean = packageName == "com.wingmanbefree.wingman_app"

    fun authorized(caller: FipsSharedCaller, uidPackages: List<String>, currentSigners: List<String>, entries: List<String>): Boolean =
        uidPackages == listOf(caller.packageName) && currentSigners == listOf(caller.certificate) &&
            Regex("[a-f0-9]{64}").matches(caller.certificate) &&
            entries.contains("${caller.packageName}|${caller.certificate}")
}

internal data class FipsSharedBinding(val networkHandle: Long, val generation: String)
internal data class FipsSharedRequest(
    val id: String,
    val caller: FipsSharedCaller,
    val endpoint: FipsSharedEndpoint,
    val binding: FipsSharedBinding,
    val created: Long,
    var state: String = "pending",
    var consentDeadline: Long = 0,
    var leaseDeadline: Long = 0,
)

/** All grants are process-local, short lived and generation-scoped. Never stores a signature. */
internal class FipsSharedPolicy(
    private val now: () -> Long,
    private val token: () -> String = { UUID.randomUUID().toString() },
    private val revoked: (String) -> Unit = {},
) {
    private val requests = linkedMapOf<String, FipsSharedRequest>()
    private var binding: FipsSharedBinding? = null

    @Synchronized fun updateBinding(value: FipsSharedBinding?) {
        if (binding == value) return
        revokeAll()
        binding = value
    }

    @Synchronized fun request(caller: FipsSharedCaller, endpoint: FipsSharedEndpoint): FipsSharedRequest? {
        sweep()
        val current = binding ?: return null
        if (requests.size >= 64 || requests.values.count { it.caller.uid == caller.uid } >= 8) return null
        return FipsSharedRequest(token(), caller, endpoint, current, now()).also { requests[it.id] = it }.copy()
    }

    @Synchronized fun hasBinding() = binding != null
    @Synchronized fun view(id: String, caller: FipsSharedCaller? = null): FipsSharedRequest? {
        sweep()
        val request = requests[id] ?: return null
        if (caller != null && caller != request.caller) return null
        return request.copy()
    }

    @Synchronized fun decide(id: String, caller: FipsSharedCaller, allow: Boolean): Boolean {
        sweep()
        val request = requests[id] ?: return false
        if (request.caller != caller || request.state != "pending" || request.binding != binding) return false
        request.state = if (allow) "ready" else "denied"
        if (allow) {
            request.consentDeadline = now() + CONSENT_MS
            request.leaseDeadline = now() + LEASE_MS
        }
        return true
    }

    @Synchronized fun check(id: String, caller: FipsSharedCaller): FipsSharedRequest? {
        val request = view(id, caller) ?: return null
        if (request.state == "ready") {
            requests.getValue(id).leaseDeadline = minOf(now() + LEASE_MS, request.consentDeadline)
        }
        return requests[id]?.copy()
    }

    @Synchronized fun release(id: String, caller: FipsSharedCaller? = null) {
        val request = requests[id] ?: return
        if (caller != null && request.caller != caller) return
        requests.remove(id)
        revoked(id)
    }

    @Synchronized fun revokeAll() { requests.keys.toList().forEach { release(it) } }
    @Synchronized fun sweep() {
        val time = now()
        requests.values.filter {
            it.binding != binding || when (it.state) {
                "ready" -> time >= it.leaseDeadline || time >= it.consentDeadline
                else -> time >= it.created + PENDING_MS
            }
        }.map { it.id }.forEach { release(it) }
    }

    companion object {
        const val LEASE_MS = 60_000L
        const val CONSENT_MS = 600_000L
        const val PENDING_MS = 120_000L
    }
}

/** Public network facts are still accepted only from Android inside the provider. */
internal object FipsSharedNetworkPolicy {
    fun matches(
        ownUid: Int, ownerUid: Int, isVpn: Boolean,
        expectedAddress: List<Byte>, addresses: List<Pair<List<Byte>, Int>>,
        dnsServers: List<String>, routes: List<Pair<List<Byte>, Int>>,
    ): Boolean = ownUid == ownerUid && isVpn && expectedAddress.size == 16 &&
        expectedAddress.first() == 0xfd.toByte() &&
        addresses.contains(expectedAddress to 128) && dnsServers == listOf("10.1.1.1") &&
        routes.contains((listOf(0xfd.toByte()) + List(15) { 0.toByte() }) to 8)
}
