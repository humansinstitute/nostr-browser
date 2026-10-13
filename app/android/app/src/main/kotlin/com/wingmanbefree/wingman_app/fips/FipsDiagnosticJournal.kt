package com.wingmanbefree.wingman_app.fips

import android.content.Context
import android.os.Build
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

internal data class FipsDiagnosticEvent(
    val timestampUtc: String,
    val release: String,
    val platform: String,
    val api: String,
    val manufacturer: String,
    val model: String,
    val eventCode: String,
    val phase: String,
    val fipsStatus: String,
    val errorCode: String,
    val consentState: String,
    val serviceState: String,
    val exceptionClass: String,
) {
    fun toJson(): String = JSONObject(linkedMapOf(
        "timestampUtc" to timestampUtc,
        "release" to release,
        "platform" to platform,
        "api" to api,
        "manufacturer" to manufacturer,
        "model" to model,
        "eventCode" to eventCode,
        "phase" to phase,
        "fipsStatus" to fipsStatus,
        "errorCode" to errorCode,
        "consentState" to consentState,
        "serviceState" to serviceState,
        "exceptionClass" to exceptionClass,
    )).toString()

    companion object {
        fun parse(line: String): FipsDiagnosticEvent? = runCatching {
            val value = JSONObject(line)
            FipsDiagnosticEvent(
                value.getString("timestampUtc"), value.getString("release"),
                value.getString("platform"), value.getString("api"),
                value.getString("manufacturer"), value.getString("model"),
                value.getString("eventCode"), value.getString("phase"),
                value.getString("fipsStatus"), value.optString("errorCode", "unknown"),
                value.getString("consentState"),
                value.getString("serviceState"), value.getString("exceptionClass"),
            )
        }.getOrNull()
    }
}

/** Durable, bounded, allowlist-only FIPS lifecycle journal. */
internal class FipsDiagnosticJournal(
    private val file: File,
    private val release: String,
    private val platform: String,
    private val api: String,
    private val manufacturer: String,
    private val model: String,
    private val now: () -> Instant = Instant::now,
    private val maxRecords: Int = 200,
    private val maxBytes: Int = 128 * 1024,
) {
    @Synchronized
    fun record(
        eventCode: String,
        phase: String = "unknown",
        fipsStatus: String = "unknown",
        errorCode: String = "unknown",
        consentState: String = "unknown",
        serviceState: String = "unknown",
        exceptionClass: String? = null,
    ) {
        val records = readValid().toMutableList()
        records += FipsDiagnosticEvent(
            timestampUtc = DateTimeFormatter.ISO_INSTANT.format(now()),
            release = safeMetadata(release), platform = safeMetadata(platform),
            api = safeMetadata(api), manufacturer = safeMetadata(manufacturer),
            model = safeMetadata(model), eventCode = safeToken(eventCode),
            phase = safeToken(phase), fipsStatus = safeToken(fipsStatus),
            errorCode = safeToken(errorCode),
            consentState = safeToken(consentState), serviceState = safeToken(serviceState),
            exceptionClass = safeException(exceptionClass),
        )
        while (records.size > maxRecords || encodedSize(records) > maxBytes) records.removeAt(0)
        atomicWrite(records.joinToString(separator = "\n", postfix = "\n") { it.toJson() })
    }

    @Synchronized fun clear() { atomicWrite("") }
    @Synchronized fun records(): List<FipsDiagnosticEvent> = readValid()

    @Synchronized
    fun exportText(): String = buildString {
        appendLine("WM-App FIPS diagnostics")
        appendLine("Release: ${safeMetadata(release)}")
        appendLine("Privacy: allowlisted lifecycle metadata only; no keys, tokens, payloads, URLs, paths, stack traces, or system logcat.")
        appendLine("Retention: newest $maxRecords records, maximum $maxBytes bytes; Clear diagnostics removes all retained records.")
        appendLine("Generated UTC: ${DateTimeFormatter.ISO_INSTANT.format(now())}")
        appendLine()
        readValid().forEach { appendLine(it.toJson()) }
    }

    private fun readValid(): List<FipsDiagnosticEvent> = if (!file.isFile) emptyList() else
        runCatching { file.readLines(StandardCharsets.UTF_8).mapNotNull(FipsDiagnosticEvent::parse) }
            .getOrDefault(emptyList())

    private fun encodedSize(records: List<FipsDiagnosticEvent>) =
        records.sumOf { it.toJson().toByteArray(StandardCharsets.UTF_8).size + 1 }

    private fun atomicWrite(contents: String) {
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, "${file.name}.tmp")
        FileOutputStream(temporary).use { output ->
            val writer = OutputStreamWriter(output, StandardCharsets.UTF_8)
            writer.write(contents)
            writer.flush()
            output.fd.sync()
        }
        if (!temporary.renameTo(file)) {
            temporary.delete()
            throw IllegalStateException("diagnostic journal replacement failed")
        }
    }

    companion object {
        private val token = Regex("^[a-z0-9_.-]{1,64}$")
        private val metadata = Regex("^[A-Za-z0-9 ._+()-]{1,80}$")
        private val forbidden = Regex(
            "nsec1|authorization|nip.?98|bunker|nostrwalletconnect|nwc|capability|private.?key|secret|token|raw.?event",
            RegexOption.IGNORE_CASE,
        )
        private fun safeToken(value: String) =
            value.takeIf { token.matches(it) && !forbidden.containsMatchIn(it) } ?: "invalid"
        private fun safeMetadata(value: String) =
            value.takeIf { metadata.matches(it) && !forbidden.containsMatchIn(it) } ?: "unknown"
        private fun safeException(value: String?) = value?.substringAfterLast('.')?.takeIf {
            Regex("^[A-Za-z][A-Za-z0-9]{0,63}(Exception|Error)$").matches(it)
        } ?: "none"
    }
}

internal object FipsDiagnostics {
    @Volatile private var journal: FipsDiagnosticJournal? = null
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    fun get(context: Context): FipsDiagnosticJournal = journal ?: synchronized(this) {
        journal ?: FipsDiagnosticJournal(
            file = File(context.applicationContext.filesDir, "fips/diagnostics.jsonl"),
            release = releaseFor(context.applicationContext),
            platform = "Android", api = Build.VERSION.SDK_INT.toString(),
            manufacturer = Build.MANUFACTURER, model = Build.MODEL,
        ).also { journal = it }
    }

    @Suppress("DEPRECATION")
    private fun releaseFor(context: Context): String = runCatching {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
        "${info.versionName ?: "unknown"}+$code"
    }.getOrDefault("unknown")

    fun record(context: Context, eventCode: String, phase: String = "unknown", fipsStatus: String = "unknown", errorCode: String = "unknown", consentState: String = "unknown", serviceState: String = "unknown", failure: Throwable? = null, critical: Boolean = false) {
        val action = { get(context).record(eventCode, phase, fipsStatus, errorCode, consentState, serviceState, failure?.javaClass?.simpleName) }
        if (critical) runCatching(action) else executor.execute { runCatching(action) }
    }
}

internal object FipsDiagnosticFilename {
    private val format = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss'Z'").withZone(ZoneOffset.UTC)
    fun at(instant: Instant = Instant.now()) = "wmapp-fips-diagnostics-${format.format(instant)}.txt"
}
