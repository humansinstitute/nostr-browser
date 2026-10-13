package com.wingmanbefree.wingman_app.fips

import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.wingmanbefree.wingman_app.MainActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

internal class FipsRuntimeCoordinator(
    private val activity: MainActivity,
    private val launchConsent: (Intent) -> Unit,
    private val launchDiagnosticsExport: (String) -> Unit,
) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val timer: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var alive = true
    private var preparedConsentIntent: Intent? = null
    private val journal = FipsDiagnostics.get(activity.applicationContext)

    private val exportOperation = FipsDiagnosticsExportOperation(object : FipsDiagnosticsExportEnvironment {
        override fun hasActivity() = alive && !activity.isFinishing && !activity.isDestroyed
        override fun launch(filename: String): Boolean {
            launchDiagnosticsExport(filename)
            FipsDiagnostics.record(activity, "export_picker_launched", phase = "export")
            return true
        }
        override fun runBackground(task: () -> Unit) = execute(worker, task)
        override fun runMain(task: () -> Unit) = postMain(task)
        override fun contents() = journal.exportText()
        override fun record(eventCode: String) =
            FipsDiagnostics.record(activity, eventCode, phase = "export")
        override fun write(destination: String, contents: String) {
            val stream = activity.contentResolver.openOutputStream(Uri.parse(destination), "wt")
                ?: throw IllegalStateException("output unavailable")
            stream.bufferedWriter(Charsets.UTF_8).use { it.write(contents) }
        }
    })

    private val startOperation = FipsStartOperation(object : FipsStartEnvironment {
        override fun runBackground(task: () -> Unit): Boolean = execute(worker, task)
        override fun runMain(task: () -> Unit): Boolean = postMain(task)

        override fun scheduleTimeout(delayMillis: Long, task: () -> Unit): FipsTimeout {
            val future = timer.schedule({ if (alive) task() }, delayMillis, TimeUnit.MILLISECONDS)
            return FipsTimeout { future.cancel(false) }
        }

        override fun resetForStart() {
            log("reset_started")
            FipsVpnServiceFailure.clear()
            FipsVpnService.resetForStart(activity.applicationContext)
            log("reset_completed")
        }

        override fun prepareNative(): String {
            log("native_prepare_started")
            val fipsDir = File(activity.filesDir, "fips")
            if (!fipsDir.exists() && !fipsDir.mkdirs()) throw IllegalStateException("directory unavailable")
            return FipsNative.nativePrepare(
                File(fipsDir, "fips.machine.key").absolutePath,
                File(fipsDir, "control.sock").absolutePath,
            ).also { log("native_prepare_completed") }
        }

        override fun prepareVpnConsent(): Boolean {
            check(Looper.myLooper() == Looper.getMainLooper())
            preparedConsentIntent = VpnService.prepare(activity)
            return preparedConsentIntent != null
        }

        override fun launchVpnConsent() {
            check(Looper.myLooper() == Looper.getMainLooper())
            val intent = preparedConsentIntent
                ?: throw IllegalStateException("consent intent unavailable")
            preparedConsentIntent = null
            launchConsent(intent)
        }

        override fun startVpnService() {
            check(Looper.myLooper() == Looper.getMainLooper())
            FipsVpnService.start(activity.applicationContext)
        }

        override fun inspectNative(): String = FipsNative.nativeInspect()

        override fun stopNative() {
            runCatching { FipsNative.nativeStop() }
            FipsVpnService.stop(activity.applicationContext)
        }

        override fun pauseBeforePoll(delayMillis: Long) = Thread.sleep(delayMillis)

        override fun log(event: String, failure: Throwable?) {
            if (failure == null) Log.i(TAG, event)
            else Log.e(TAG, "$event (${failure.javaClass.simpleName})")
            FipsDiagnostics.record(
                activity, event, phase = phaseFor(event),
                fipsStatus = statusFor(event), consentState = consentFor(event),
                errorCode = errorFor(event), serviceState = serviceFor(event), failure = failure,
                critical = event in CRITICAL_EVENTS,
            )
        }
    })

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "inspect" -> inspect(result)
                "start", "repair" -> startOperation.start(result.asCompletion())
                "exportDiagnostics" -> exportOperation.start(result.asCompletion())
                "clearDiagnostics" -> backgroundMap(result) {
                    journal.clear()
                    mapOf("outcome" to "success", "code" to "diagnostics_cleared", "detail" to "FIPS diagnostics cleared.")
                }
                "journalEvent" -> {
                    val event = call.argument<String>("eventCode")
                    if (event !in DART_EVENTS) safeSuccess(result, mapOf("outcome" to "failed", "code" to "invalid_event", "detail" to "Diagnostic event rejected."))
                    else {
                        FipsDiagnostics.record(activity, event!!, phase = "dart_boundary")
                        safeSuccess(result, mapOf("outcome" to "success", "code" to "event_recorded", "detail" to "Diagnostic event recorded."))
                    }
                }
                "stop" -> backgroundStatus(result) {
                    FipsVpnService.stop(activity.applicationContext)
                    FipsStatus.fromNative(FipsNative.nativeInspect(), "Embedded FIPS could not stop safely.")
                }
                "peerStatus" -> backgroundMap(result) {
                    FipsPlatformContract.peerStatus(FipsNative.nativePeerStatus())
                }
                "probe" -> {
                    val npub = call.argument<String>("npub")
                    if (npub == null) {
                        result.success(FipsStartOperation.failed("invalid_argument", "A FIPS node is required."))
                    } else {
                        backgroundMap(result) { FipsPlatformContract.probe(FipsNative.nativeProbe(npub)) }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (failure: Throwable) {
            logFailure("method_dispatch_failed", failure)
            safeSuccess(
                result,
                FipsStartOperation.failed(
                    "android_bridge_failed",
                    "Android embedded FIPS is unavailable. Please retry.",
                ),
            )
        }
    }

    fun onVpnConsentResult(granted: Boolean): Boolean = startOperation.onVpnConsentResult(granted)
    fun onDiagnosticsDestination(destination: String?) = exportOperation.onDestination(destination)

    fun destroy() {
        if (!alive) return
        startOperation.destroy()
        exportOperation.destroy()
        FipsDiagnostics.record(activity, "activity_destroyed", phase = "activity", critical = true)
        alive = false
        preparedConsentIntent = null
        worker.shutdownNow()
        timer.shutdownNow()
        main.removeCallbacksAndMessages(null)
    }

    private fun inspect(result: MethodChannel.Result) {
        if (!execute(worker) {
                val native = try {
                    FipsStatus.fromNative(FipsNative.nativeInspect(), "Embedded FIPS inspection failed.")
                } catch (failure: Throwable) {
                    logFailure("inspect_native_failed", failure)
                    FipsStartOperation.failed("inspect_failed", "Embedded FIPS inspection failed. Please retry.")
                }
                postMain {
                    val serviceFailure = FipsVpnServiceFailure.peek()
                    val status = if (serviceFailure != null) {
                        FipsStartOperation.failed(serviceFailure.code, serviceFailure.detail)
                    } else if (native["state"] == "notInstalled") {
                        try {
                            if (VpnService.prepare(activity) != null) {
                                native + mapOf(
                                    "state" to "consentRequired",
                                    "detail" to "Android VPN consent is required to start embedded FIPS.",
                                )
                            } else native
                        } catch (failure: Throwable) {
                            logFailure("inspect_consent_failed", failure)
                            FipsStartOperation.failed(
                                "consent_prepare_failed",
                                "Android VPN consent could not be checked. Please retry.",
                            )
                        }
                    } else native
                    safeSuccess(result, status)
                }
            }
        ) {
            safeSuccess(
                result,
                FipsStartOperation.failed(
                    "executor_unavailable",
                    "Embedded FIPS inspection was interrupted. Please retry.",
                ),
            )
        }
    }

    private fun backgroundStatus(result: MethodChannel.Result, action: () -> Map<String, Any?>) {
        if (!execute(worker) {
                val status = try {
                    action()
                } catch (failure: Throwable) {
                    logFailure("background_status_failed", failure)
                    FipsStartOperation.failed("native_failed", "Android embedded FIPS failed. Please retry.")
                }
                postMain { safeSuccess(result, status) }
            }
        ) {
            safeSuccess(
                result,
                FipsStartOperation.failed(
                    "executor_unavailable",
                    "Android embedded FIPS was interrupted. Please retry.",
                ),
            )
        }
    }

    private fun backgroundMap(result: MethodChannel.Result, action: () -> Map<String, Any?>) {
        if (!execute(worker) {
                val value = try {
                    action()
                } catch (failure: Throwable) {
                    logFailure("background_map_failed", failure)
                    mapOf(
                        "ok" to false,
                        "connected" to false,
                        "detail" to "Android embedded FIPS request failed. Please retry.",
                    )
                }
                postMain { safeSuccess(result, value) }
            }
        ) {
            safeSuccess(
                result,
                mapOf(
                    "ok" to false,
                    "connected" to false,
                    "detail" to "Android embedded FIPS was interrupted. Please retry.",
                ),
            )
        }
    }

    private fun MethodChannel.Result.asCompletion() = FipsCompletion { safeSuccess(this, it) }

    private fun safeSuccess(result: MethodChannel.Result, value: Map<String, Any?>) {
        try {
            result.success(value)
        } catch (failure: Throwable) {
            logFailure("result_delivery_failed", failure)
        }
    }

    private fun postMain(task: () -> Unit): Boolean {
        if (!alive || activity.isFinishing || activity.isDestroyed) return false
        return if (Looper.myLooper() == Looper.getMainLooper()) {
            task()
            true
        } else {
            main.post { if (alive && !activity.isDestroyed) task() }
        }
    }

    private fun execute(executor: ExecutorService, task: () -> Unit): Boolean {
        if (!alive || executor.isShutdown) return false
        return try {
            executor.execute { if (alive) task() }
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    private fun logFailure(event: String, failure: Throwable) {
        // Event codes plus exception classes are actionable in logcat without
        // exposing native payloads, identities, secrets, or filesystem paths.
        Log.e(TAG, "$event (${failure.javaClass.simpleName})")
        FipsDiagnostics.record(
            activity, event, phase = phaseFor(event), fipsStatus = "failed",
            errorCode = event, failure = failure,
        )
    }

    private fun phaseFor(event: String) = when {
        event.contains("consent") -> "consent"
        event.contains("service") || event.contains("foreground") -> "service"
        event.contains("ready") || event.contains("readiness") || event.contains("poll") -> "readiness"
        event.contains("prepare") || event.contains("reset") -> "native_prepare"
        event.contains("timeout") -> "timeout"
        event.contains("destroy") -> "activity"
        else -> "coordinator"
    }
    private fun statusFor(event: String) = when {
        event == "native_ready" -> "running"
        event.contains("failed") || event.contains("timeout") || event.contains("interrupted") -> "failed"
        event.contains("start") || event.contains("prepare") || event.contains("poll") -> "starting"
        else -> "unknown"
    }
    private fun consentFor(event: String) = when (event) {
        "consent_launched" -> "launched"
        "consent_granted" -> "granted"
        "consent_cancelled" -> "cancelled"
        "consent_not_required" -> "already_granted"
        else -> "unknown"
    }
    private fun errorFor(event: String) =
        event.takeIf { it.contains("failed") || it.contains("timeout") || it.contains("cancelled") }
            ?: "none"
    private fun serviceFor(event: String) = when {
        event == "service_launch_requested" -> "requested"
        event.contains("service") && event.contains("failed") -> "failed"
        else -> "unknown"
    }

    companion object {
        private const val TAG = "WMAppFips"
        private val CRITICAL_EVENTS = setOf("native_prepare_started", "service_launch_requested", "start_timeout", "activity_destroyed")
        private val DART_EVENTS = setOf("dart_inspect_failed", "dart_start_requested", "dart_start_failed", "dart_ui_retry", "dart_export_requested", "dart_export_failed")
    }
}
