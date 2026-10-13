package com.wingmanbefree.wingman_app.fips

internal interface FipsDiagnosticsExportEnvironment {
    fun hasActivity(): Boolean
    fun launch(filename: String): Boolean
    fun runBackground(task: () -> Unit): Boolean
    fun runMain(task: () -> Unit): Boolean
    fun write(destination: String, contents: String)
    fun contents(): String
    fun record(eventCode: String)
}

/** Exactly-once document export state machine, isolated for JVM tests. */
internal class FipsDiagnosticsExportOperation(private val environment: FipsDiagnosticsExportEnvironment) {
    private var pending: FipsCompletion? = null
    private var destinationAccepted = false
    private var destroyed = false

    fun start(completion: FipsCompletion) {
        synchronized(this) {
            if (destroyed || !environment.hasActivity()) {
                completion.complete(result("failed", "activity_unavailable", "WM-App is not ready to export diagnostics. Please retry.")); return
            }
            if (pending != null) {
                completion.complete(result("failed", "export_in_progress", "A diagnostics export is already in progress.")); return
            }
            pending = completion
            destinationAccepted = false
        }
        if (!runCatching { environment.launch(FipsDiagnosticFilename.at()) }.getOrDefault(false)) {
            environment.record("export_launch_failed")
            finish(result("failed", "export_launch_failed", "Android could not open the diagnostics file picker. Please retry."))
        }
    }

    fun onDestination(destination: String?) {
        val accepted = synchronized(this) {
            if (pending == null || destinationAccepted) false
            else { destinationAccepted = true; true }
        }
        if (!accepted) return
        if (destination == null) {
            environment.record("export_cancelled")
            finish(result("cancelled", "export_cancelled", "Diagnostics export cancelled.")); return
        }
        if (!environment.runBackground {
                val outcome = try {
                    environment.write(destination, environment.contents())
                    environment.record("export_complete")
                    result("success", "export_complete", "FIPS diagnostics exported.")
                } catch (_: Throwable) {
                    environment.record("export_write_failed")
                    result("failed", "export_write_failed", "Android could not write the diagnostics file. Please retry.")
                }
                if (!environment.runMain { finish(outcome) }) finish(outcome)
            }) {
            environment.record("export_executor_unavailable")
            finish(result("failed", "executor_unavailable", "Diagnostics export was interrupted. Please retry."))
        }
    }

    fun destroy() {
        val hadPending = synchronized(this) {
            destroyed = true
            pending != null
        }
        if (hadPending) environment.record("export_activity_destroyed")
        finish(result("failed", "activity_destroyed", "WM-App closed before diagnostics export completed. Please retry."))
    }

    private fun finish(value: Map<String, Any?>) {
        val completion = synchronized(this) { pending.also { pending = null } }
        completion?.complete(value)
    }

    companion object {
        private fun result(outcome: String, code: String, detail: String) =
            mapOf("outcome" to outcome, "code" to code, "detail" to detail)
    }
}
