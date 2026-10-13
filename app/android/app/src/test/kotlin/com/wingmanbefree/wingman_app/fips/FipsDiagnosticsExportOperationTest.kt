package com.wingmanbefree.wingman_app.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FipsDiagnosticsExportOperationTest {
    @Test
    fun successfulExportWritesOnceAndCompletesOnce() {
        val environment = FakeEnvironment()
        val operation = FipsDiagnosticsExportOperation(environment)
        val results = mutableListOf<Map<String, Any?>>()

        operation.start { results += it }
        operation.onDestination("content://documents/output")
        operation.onDestination("content://documents/duplicate")

        assertEquals("success", results.single()["outcome"])
        assertEquals(listOf("content://documents/output"), environment.destinations)
        assertTrue(environment.filename.matches(Regex("wmapp-fips-diagnostics-\\d{8}-\\d{6}Z\\.txt")))
        assertEquals(listOf("export_complete"), environment.events)
    }

    @Test
    fun cancellationIsRecoverableAndAllowsRetry() {
        val environment = FakeEnvironment()
        val operation = FipsDiagnosticsExportOperation(environment)
        val cancelled = mutableListOf<Map<String, Any?>>()
        operation.start { cancelled += it }
        operation.onDestination(null)
        assertEquals("cancelled", cancelled.single()["outcome"])

        val retry = mutableListOf<Map<String, Any?>>()
        operation.start { retry += it }
        operation.onDestination("content://retry")
        assertEquals("success", retry.single()["outcome"])
    }

    @Test
    fun providerLaunchWriteAndExecutorFailuresAreStructuredAndSanitized() {
        val launchEnvironment = FakeEnvironment().also { it.launchFailure = SecurityException("private path") }
        assertFailure(FipsDiagnosticsExportOperation(launchEnvironment), "export_launch_failed")

        val writeEnvironment = FakeEnvironment().also { it.writeFailure = IllegalStateException("secret payload") }
        assertFailure(FipsDiagnosticsExportOperation(writeEnvironment), "export_write_failed", destination = "content://write")

        val executorEnvironment = FakeEnvironment().also { it.acceptBackground = false }
        assertFailure(FipsDiagnosticsExportOperation(executorEnvironment), "executor_unavailable", destination = "content://executor")
    }

    @Test
    fun missingActivityDuplicateTapAndDestructionCompleteExactlyOnce() {
        val missing = FakeEnvironment().also { it.activityAvailable = false }
        assertFailure(FipsDiagnosticsExportOperation(missing), "activity_unavailable")

        val environment = FakeEnvironment().also { it.deferBackground = true }
        val operation = FipsDiagnosticsExportOperation(environment)
        val first = mutableListOf<Map<String, Any?>>()
        val duplicate = mutableListOf<Map<String, Any?>>()
        operation.start { first += it }
        operation.start { duplicate += it }
        assertEquals("export_in_progress", duplicate.single()["code"])
        operation.onDestination("content://pending")
        operation.destroy()
        environment.runDeferred()
        assertEquals("activity_destroyed", first.single()["code"])
        assertEquals(1, first.size)
    }

    private fun assertFailure(
        operation: FipsDiagnosticsExportOperation,
        code: String,
        destination: String? = null,
    ) {
        val results = mutableListOf<Map<String, Any?>>()
        operation.start { results += it }
        if (destination != null) operation.onDestination(destination)
        assertEquals(code, results.single()["code"])
        assertFalse(results.single()["detail"].toString().contains("secret"))
        assertFalse(results.single()["detail"].toString().contains("private"))
    }

    private class FakeEnvironment : FipsDiagnosticsExportEnvironment {
        var activityAvailable = true
        var launchFailure: Throwable? = null
        var writeFailure: Throwable? = null
        var acceptBackground = true
        var deferBackground = false
        var filename = ""
        val destinations = mutableListOf<String>()
        val events = mutableListOf<String>()
        private val deferred = mutableListOf<() -> Unit>()

        override fun hasActivity() = activityAvailable
        override fun launch(filename: String): Boolean {
            launchFailure?.let { throw it }
            this.filename = filename
            return true
        }
        override fun runBackground(task: () -> Unit): Boolean {
            if (!acceptBackground) return false
            if (deferBackground) deferred += task else task()
            return true
        }
        override fun runMain(task: () -> Unit): Boolean { task(); return true }
        override fun write(destination: String, contents: String) {
            writeFailure?.let { throw it }
            destinations += destination
        }
        override fun contents() = "safe diagnostics"
        override fun record(eventCode: String) { events += eventCode }
        fun runDeferred() = deferred.toList().also { deferred.clear() }.forEach { it() }
    }
}
