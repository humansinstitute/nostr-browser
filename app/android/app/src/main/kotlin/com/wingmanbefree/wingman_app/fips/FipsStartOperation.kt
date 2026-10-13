package com.wingmanbefree.wingman_app.fips

import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

internal fun interface FipsCompletion { fun complete(status: Map<String, Any?>) }
internal fun interface FipsTimeout { fun cancel() }

internal interface FipsStartEnvironment {
    fun runBackground(task: () -> Unit): Boolean
    fun runMain(task: () -> Unit): Boolean
    fun scheduleTimeout(delayMillis: Long, task: () -> Unit): FipsTimeout
    fun resetForStart()
    fun prepareNative(): String
    fun prepareVpnConsent(): Boolean
    fun launchVpnConsent()
    fun startVpnService()
    fun inspectNative(): String
    fun stopNative()
    fun pauseBeforePoll(delayMillis: Long)
    fun log(event: String, failure: Throwable? = null)
}

/** Exactly-once start/consent state machine, isolated for local JVM tests. */
internal class FipsStartOperation(
    private val environment: FipsStartEnvironment,
    private val timeoutMillis: Long = 60_000,
    private val pollAttempts: Int = 100,
    private val pollDelayMillis: Long = 100,
) {
    private data class Pending(
        val id: Long,
        val completion: FipsCompletion,
        var timeout: FipsTimeout? = null,
    )

    private val ids = AtomicLong()
    private var pending: Pending? = null
    private var consentLaunchId: Long? = null
    private var destroyed = false

    fun start(completion: FipsCompletion) {
        environment.log("start_requested")
        val operation = synchronized(this) {
            if (destroyed) {
                completion.complete(failed("activity_unavailable", ACTIVITY_UNAVAILABLE))
                return
            }
            if (pending != null || consentLaunchId != null) {
                completion.complete(failed("operation_in_progress", OPERATION_IN_PROGRESS))
                return
            }
            Pending(ids.incrementAndGet(), completion).also { pending = it }
        }
        operation.timeout = environment.scheduleTimeout(timeoutMillis) {
            environment.log("start_timeout")
            fail(operation.id, "startup_timeout", STARTUP_TIMEOUT, stopNative = true)
        }
        if (!environment.runBackground { prepare(operation.id) }) {
            fail(operation.id, "executor_unavailable", RUNTIME_UNAVAILABLE)
        }
    }

    fun onVpnConsentResult(granted: Boolean): Boolean {
        val id = synchronized(this) {
            val launched = consentLaunchId ?: return false
            consentLaunchId = null
            launched
        }
        if (!isPending(id)) {
            environment.log("late_consent_result")
            return true
        }
        environment.log(if (granted) "consent_granted" else "consent_cancelled")
        if (!granted) fail(id, "consent_cancelled", CONSENT_CANCELLED, stopNative = true)
        else launchService(id)
        return true
    }

    fun destroy() {
        val operation = synchronized(this) {
            if (destroyed) return
            destroyed = true
            consentLaunchId = null
            pending.also { pending = null }
        }
        operation?.timeout?.cancel()
        runCatching { environment.stopNative() }
            .onFailure { environment.log("destroy_stop_failed", it) }
        operation?.completion?.complete(failed("activity_destroyed", ACTIVITY_DESTROYED))
    }

    private fun prepare(id: Long) {
        try {
            environment.resetForStart()
        } catch (failure: Throwable) {
            environment.log("reset_failed", failure)
            fail(id, "reset_failed", RESET_FAILED)
            return
        }
        val prepared = try {
            FipsStatus.fromNative(environment.prepareNative(), PREPARE_FAILED)
        } catch (failure: Throwable) {
            environment.log("native_prepare_failed", failure)
            fail(id, "native_prepare_failed", PREPARE_FAILED, stopNative = true)
            return
        }
        if (prepared["state"] == "failed") {
            fail(id, "native_prepare_failed", PREPARE_FAILED, stopNative = true)
            return
        }
        if (!environment.runMain { prepareConsent(id) }) {
            fail(id, "activity_unavailable", ACTIVITY_UNAVAILABLE, stopNative = true)
        }
    }

    private fun prepareConsent(id: Long) {
        if (!isPending(id)) return
        val required = try {
            environment.prepareVpnConsent()
        } catch (failure: Throwable) {
            environment.log("consent_prepare_failed", failure)
            fail(id, "consent_prepare_failed", CONSENT_PREPARE_FAILED, stopNative = true)
            return
        }
        if (!required) {
            environment.log("consent_not_required")
            launchService(id)
            return
        }
        synchronized(this) {
            if (!isPendingLocked(id)) return
            consentLaunchId = id
        }
        try {
            environment.launchVpnConsent()
            environment.log("consent_launched")
        } catch (failure: Throwable) {
            synchronized(this) { if (consentLaunchId == id) consentLaunchId = null }
            environment.log("consent_launch_failed", failure)
            fail(id, "consent_launch_failed", CONSENT_LAUNCH_FAILED, stopNative = true)
        }
    }

    private fun launchService(id: Long) {
        if (!environment.runMain {
                if (!isPending(id)) return@runMain
                try {
                    environment.startVpnService()
                    environment.log("service_launch_requested")
                } catch (failure: Throwable) {
                    environment.log("service_launch_failed", failure)
                    fail(id, "service_launch_failed", SERVICE_LAUNCH_FAILED, stopNative = true)
                    return@runMain
                }
                if (!environment.runBackground { awaitReady(id) }) {
                    fail(id, "executor_unavailable", RUNTIME_UNAVAILABLE, stopNative = true)
                }
            }
        ) fail(id, "activity_unavailable", ACTIVITY_UNAVAILABLE, stopNative = true)
    }

    private fun awaitReady(id: Long) {
        environment.log("readiness_poll_started")
        repeat(pollAttempts) {
            if (!isPending(id)) return
            FipsVpnServiceFailure.consume()?.let {
                fail(id, it.code, it.detail, stopNative = true)
                return
            }
            val status = try {
                FipsStatus.fromNative(environment.inspectNative(), INSPECT_FAILED)
            } catch (failure: Throwable) {
                environment.log("readiness_inspect_failed", failure)
                fail(id, "readiness_inspect_failed", INSPECT_FAILED, stopNative = true)
                return
            }
            when (status["state"]) {
                "running" -> { environment.log("native_ready"); finish(id, status); return }
                "failed" -> { fail(id, "native_start_failed", NATIVE_START_FAILED, stopNative = true); return }
            }
            try {
                environment.pauseBeforePoll(pollDelayMillis)
            } catch (failure: Throwable) {
                environment.log("readiness_poll_interrupted", failure)
                fail(id, "startup_interrupted", RUNTIME_UNAVAILABLE, stopNative = true)
                return
            }
        }
        fail(id, "startup_timeout", STARTUP_TIMEOUT, stopNative = true)
    }

    private fun fail(id: Long, code: String, detail: String, stopNative: Boolean = false) {
        if (stopNative) runCatching { environment.stopNative() }
            .onFailure { environment.log("failure_stop_failed", it) }
        finish(id, failed(code, detail))
    }

    private fun finish(id: Long, status: Map<String, Any?>) {
        val deliver = {
            val operation = synchronized(this) {
                val current = pending
                if (current?.id != id) null else {
                    pending = null
                    current
                }
            }
            if (operation != null) {
                operation.timeout?.cancel()
                operation.completion.complete(status)
            }
        }
        if (!environment.runMain(deliver)) deliver()
    }

    private fun isPending(id: Long): Boolean = synchronized(this) { isPendingLocked(id) }
    private fun isPendingLocked(id: Long): Boolean = !destroyed && pending?.id == id

    companion object {
        private const val OPERATION_IN_PROGRESS = "Embedded FIPS startup is already in progress."
        private const val ACTIVITY_UNAVAILABLE = "WM-App is not ready to request Android VPN consent. Please retry."
        private const val ACTIVITY_DESTROYED = "WM-App closed before Android VPN startup completed. Please retry."
        private const val RESET_FAILED = "Embedded FIPS could not reset safely. Please retry."
        private const val PREPARE_FAILED = "Embedded FIPS preparation failed. Please retry."
        private const val CONSENT_PREPARE_FAILED = "Android VPN consent could not be prepared. Please retry."
        private const val CONSENT_LAUNCH_FAILED = "Android VPN consent could not be opened. Please retry."
        private const val CONSENT_CANCELLED = "Android VPN consent was cancelled. You can retry."
        private const val SERVICE_LAUNCH_FAILED = "Android blocked the embedded FIPS VPN from starting. Please retry from WM-App."
        private const val NATIVE_START_FAILED = "Embedded FIPS could not become ready. Please retry."
        private const val INSPECT_FAILED = "Embedded FIPS readiness could not be checked. Please retry."
        private const val STARTUP_TIMEOUT = "Embedded FIPS did not become ready in time. Please retry."
        private const val RUNTIME_UNAVAILABLE = "Embedded FIPS startup was interrupted. Please retry."

        fun failed(code: String, detail: String): Map<String, Any?> =
            mapOf("state" to "failed", "code" to code, "detail" to detail)
    }
}

internal object FipsStatus {
    fun fromNative(raw: String, failedDetail: String): Map<String, Any?> {
        val json = JSONObject(raw)
        val state = json.optString("state")
        if (state.isBlank()) throw IllegalArgumentException("missing state")
        if (state == "failed") return FipsStartOperation.failed("native_failed", failedDetail)
        val result = linkedMapOf<String, Any?>(
            "state" to state,
            "detail" to when (state) {
                "running" -> "Embedded FIPS is running."
                "starting" -> "Embedded FIPS is starting."
                "notInstalled" -> "Embedded FIPS is ready to enable."
                else -> "Embedded FIPS status is available."
            },
        )
        json.optString("nodeNpub").takeIf { it.isNotBlank() }?.let { result["nodeNpub"] = it }
        json.optString("ipv6").takeIf { it.isNotBlank() }?.let { result["ipv6"] = it }
        return result
    }
}

internal object FipsVpnServiceFailure {
    data class Failure(val code: String, val detail: String)
    private val current = AtomicReference<Failure?>()
    fun clear() { current.set(null) }
    fun record(code: String, detail: String) { current.set(Failure(code, detail)) }
    fun consume(): Failure? = current.getAndSet(null)
    fun peek(): Failure? = current.get()
}
