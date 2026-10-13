package com.wingmanbefree.wingman_app.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class FipsStartOperationTest {
    private lateinit var environment: FakeEnvironment

    @Before
    fun setUp() {
        FipsVpnServiceFailure.clear()
        environment = FakeEnvironment()
    }

    @Test
    fun consentRequiredLaunchesAndWaitsWithoutCompleting() {
        environment.consentRequired = true
        val results = mutableListOf<Map<String, Any?>>()

        operation().start { results += it }

        assertTrue(environment.consentLaunched)
        assertTrue(results.isEmpty())
    }

    @Test
    fun consentGrantedStartsServiceAndCompletesRunningExactlyOnce() {
        environment.consentRequired = true
        val results = mutableListOf<Map<String, Any?>>()
        val operation = operation()
        operation.start { results += it }

        assertTrue(operation.onVpnConsentResult(true))
        assertEquals("running", results.single()["state"])
        assertFalse(operation.onVpnConsentResult(true))
        environment.fireTimeout()
        assertEquals(1, results.size)
    }

    @Test
    fun cancelledConsentStopsNativeAndAllowsRetryAfterResult() {
        environment.consentRequired = true
        val operation = operation()
        val first = mutableListOf<Map<String, Any?>>()
        operation.start { first += it }

        assertTrue(operation.onVpnConsentResult(false))
        assertEquals("consent_cancelled", first.single()["code"])
        assertTrue(environment.stopCalls > 0)

        environment.consentRequired = false
        val retry = mutableListOf<Map<String, Any?>>()
        operation.start { retry += it }
        assertEquals("running", retry.single()["state"])
    }

    @Test
    fun consentLaunchThrowCompletesFailed() {
        environment.consentRequired = true
        environment.launchFailure = SecurityException("sensitive path")
        val results = mutableListOf<Map<String, Any?>>()

        operation().start { results += it }

        assertEquals("consent_launch_failed", results.single()["code"])
        assertFalse(results.single()["detail"].toString().contains("sensitive"))
    }

    @Test
    fun resetAndConsentPreparationThrowsCompleteFailed() {
        environment.resetFailure = IllegalStateException("reset path")
        val reset = mutableListOf<Map<String, Any?>>()
        operation().start { reset += it }
        assertEquals("reset_failed", reset.single()["code"])

        environment = FakeEnvironment().also {
            it.consentFailure = SecurityException("framework detail")
        }
        val consent = mutableListOf<Map<String, Any?>>()
        operation().start { consent += it }
        assertEquals("consent_prepare_failed", consent.single()["code"])
    }

    @Test
    fun nativePrepareThrowInvalidJsonAndFailureAllCompleteFailed() {
        val cases = listOf<() -> Unit>(
            { environment.prepareFailure = UnsatisfiedLinkError("private") },
            { environment.prepareResult = "not-json" },
            { environment.prepareResult = """{"state":"failed","detail":"/private/key"}""" },
        )
        cases.forEach { configure ->
            environment = FakeEnvironment()
            configure()
            val results = mutableListOf<Map<String, Any?>>()
            operation().start { results += it }
            assertEquals("failed", results.single()["state"])
            assertEquals("native_prepare_failed", results.single()["code"])
            assertFalse(results.single()["detail"].toString().contains("private"))
        }
    }

    @Test
    fun serviceStartThrowCompletesFailed() {
        environment.serviceFailure = IllegalStateException("background denied")
        val results = mutableListOf<Map<String, Any?>>()

        operation().start { results += it }

        assertEquals("service_launch_failed", results.single()["code"])
    }

    @Test
    fun readinessTimeoutCompletesOnceAndStopsNative() {
        environment.inspectResult = """{"state":"starting"}"""
        val results = mutableListOf<Map<String, Any?>>()

        operation(pollAttempts = 2).start { results += it }
        environment.fireTimeout()

        assertEquals("startup_timeout", results.single()["code"])
        assertTrue(environment.stopCalls > 0)
    }

    @Test
    fun duplicateStartGetsOperationInProgressAndDoesNotReplaceFirst() {
        environment.consentRequired = true
        val operation = operation()
        val first = mutableListOf<Map<String, Any?>>()
        val second = mutableListOf<Map<String, Any?>>()

        operation.start { first += it }
        operation.start { second += it }

        assertTrue(first.isEmpty())
        assertEquals("operation_in_progress", second.single()["code"])
        operation.onVpnConsentResult(false)
        assertEquals("consent_cancelled", first.single()["code"])
    }

    @Test
    fun timeoutThenLateConsentCannotCompleteOrAttachToAnotherCall() {
        environment.consentRequired = true
        val operation = operation()
        val first = mutableListOf<Map<String, Any?>>()
        operation.start { first += it }
        environment.fireTimeout()
        assertEquals("startup_timeout", first.single()["code"])

        val blocked = mutableListOf<Map<String, Any?>>()
        operation.start { blocked += it }
        assertEquals("operation_in_progress", blocked.single()["code"])

        assertTrue(operation.onVpnConsentResult(true))
        assertEquals(1, first.size)

        environment.consentRequired = false
        val retry = mutableListOf<Map<String, Any?>>()
        operation.start { retry += it }
        assertEquals("running", retry.single()["state"])
    }

    @Test
    fun activityDestructionCompletesPendingExactlyOnce() {
        environment.consentRequired = true
        val operation = operation()
        val results = mutableListOf<Map<String, Any?>>()
        operation.start { results += it }

        operation.destroy()
        operation.destroy()
        environment.fireTimeout()
        operation.onVpnConsentResult(true)

        assertEquals("activity_destroyed", results.single()["code"])
    }

    @Test
    fun destructionWinsAgainstQueuedResultDeliveryWithoutDuplicating() {
        environment.deferCompletion = true
        val operation = operation()
        val results = mutableListOf<Map<String, Any?>>()
        operation.start { results += it }
        assertTrue(results.isEmpty())

        operation.destroy()
        environment.runQueuedMain()

        assertEquals("activity_destroyed", results.single()["code"])
    }

    private fun operation(pollAttempts: Int = 3) = FipsStartOperation(
        environment,
        timeoutMillis = 10,
        pollAttempts = pollAttempts,
        pollDelayMillis = 0,
    )

    private class FakeEnvironment : FipsStartEnvironment {
        var consentRequired = false
        var consentLaunched = false
        var prepareResult = """{"state":"starting"}"""
        var inspectResult = """{"state":"running","nodeNpub":"npub1test"}"""
        var prepareFailure: Throwable? = null
        var resetFailure: Throwable? = null
        var consentFailure: Throwable? = null
        var launchFailure: Throwable? = null
        var serviceFailure: Throwable? = null
        var deferCompletion = false
        var stopCalls = 0
        private var queueNextMain = false
        private val queuedMain = mutableListOf<() -> Unit>()
        private var timeout: (() -> Unit)? = null
        private var timeoutCancelled = false

        override fun runBackground(task: () -> Unit): Boolean { task(); return true }
        override fun runMain(task: () -> Unit): Boolean {
            if (queueNextMain) {
                queueNextMain = false
                queuedMain += task
            } else {
                task()
            }
            return true
        }
        override fun scheduleTimeout(delayMillis: Long, task: () -> Unit): FipsTimeout {
            timeout = task
            timeoutCancelled = false
            return FipsTimeout { timeoutCancelled = true }
        }
        override fun resetForStart() { resetFailure?.let { throw it } }
        override fun prepareNative(): String = prepareFailure?.let { throw it } ?: prepareResult
        override fun prepareVpnConsent(): Boolean =
            consentFailure?.let { throw it } ?: consentRequired
        override fun launchVpnConsent() { launchFailure?.let { throw it }; consentLaunched = true }
        override fun startVpnService() { serviceFailure?.let { throw it } }
        override fun inspectNative(): String {
            if (deferCompletion) queueNextMain = true
            return inspectResult
        }
        override fun stopNative() { stopCalls += 1 }
        override fun pauseBeforePoll(delayMillis: Long) = Unit
        override fun log(event: String, failure: Throwable?) = Unit
        fun fireTimeout() { if (!timeoutCancelled) timeout?.invoke() }
        fun runQueuedMain() { queuedMain.toList().also { queuedMain.clear() }.forEach { it() } }
    }
}
