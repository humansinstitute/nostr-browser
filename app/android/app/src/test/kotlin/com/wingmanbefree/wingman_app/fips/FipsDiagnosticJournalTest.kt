package com.wingmanbefree.wingman_app.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

class FipsDiagnosticJournalTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun retainsOnlyNewestRecordsWithinCountAndByteBounds() {
        val journal = journal(maxRecords = 3, maxBytes = 2_000)
        repeat(6) { journal.record("event_$it") }

        assertEquals(listOf("event_3", "event_4", "event_5"), journal.records().map { it.eventCode })
        assertTrue(journal.exportText().toByteArray().size < 4_000)

        val byteBounded = journal(fileName = "bytes.jsonl", maxRecords = 20, maxBytes = 600)
        repeat(8) { byteBounded.record("byte_event_$it") }
        assertTrue(byteBounded.records().size < 8)
    }

    @Test
    fun serializesOnlySanitizedAllowlistedFieldsAndNeverSecretInputs() {
        val secrets = listOf(
            "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
            "Authorization: Nostr eyJraW5kIjoyNzIzNX0",
            "bunker://secret-connection?secret=capability",
            "nostrwalletconnect://wallet?secret=nwc-token",
            "capability=admin-secret",
            "/data/user/0/com.example/files/fips.machine.key",
            "https://private.example/path?q=payload",
            "{\"rawEvent\":\"private payload\"}",
        )
        val journal = journal(
            release = secrets[0], platform = secrets[1], api = secrets[2],
            manufacturer = secrets[3], model = secrets[4],
        )
        journal.record(
            eventCode = secrets[5], phase = secrets[6], fipsStatus = secrets[7],
            errorCode = secrets.joinToString(), consentState = secrets[0],
            serviceState = secrets[1], exceptionClass = "java.lang.IllegalStateException: ${secrets[2]}",
        )

        val exported = journal.exportText()
        secrets.forEach { assertFalse("leaked $it", exported.contains(it)) }
        assertTrue(exported.contains("\"eventCode\":\"invalid\""))
        assertTrue(exported.contains("\"exceptionClass\":\"none\""))
    }

    @Test
    fun ignoresCorruptAndTruncatedLinesThenRecoversOnNextWrite() {
        val file = temporary.newFile("corrupt.jsonl")
        val valid = journal(fileName = "source.jsonl").also { it.record("valid_before") }
            .records().single().toJson()
        file.writeText("not-json\n$valid\n{\"timestampUtc\":")
        val recovered = journal(fileName = "corrupt.jsonl")

        assertEquals(listOf("valid_before"), recovered.records().map { it.eventCode })
        recovered.record("valid_after")
        assertEquals(listOf("valid_before", "valid_after"), recovered.records().map { it.eventCode })
        assertFalse(file.readText().contains("not-json"))
    }

    @Test
    fun concurrentAndDuplicateEventsAreSerializedWithoutLossWithinCap() {
        val journal = journal(maxRecords = 500, maxBytes = 400_000)
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val done = CountDownLatch(8)
        repeat(8) { worker ->
            executor.execute {
                start.await()
                repeat(25) { journal.record("worker_${worker}_event_$it") }
                done.countDown()
            }
        }
        start.countDown()
        done.await()
        executor.shutdown()
        journal.record("duplicate")
        journal.record("duplicate")

        assertEquals(202, journal.records().size)
        assertEquals(2, journal.records().count { it.eventCode == "duplicate" })
    }

    @Test
    fun persistsAcrossReinstantiationAndClearRemovesRetainedRecords() {
        journal().record("before_restart")
        val reopened = journal()
        assertEquals("before_restart", reopened.records().single().eventCode)

        reopened.clear()
        assertTrue(journal().records().isEmpty())
    }

    private fun journal(
        fileName: String = "diagnostics.jsonl",
        release: String = "0.1.5+6",
        platform: String = "Android",
        api: String = "35",
        manufacturer: String = "Daylight",
        model: String = "DC-1",
        maxRecords: Int = 200,
        maxBytes: Int = 128 * 1024,
    ) = FipsDiagnosticJournal(
        file = java.io.File(temporary.root, fileName), release = release,
        platform = platform, api = api, manufacturer = manufacturer, model = model,
        now = { Instant.parse("2026-09-02T12:34:56Z") },
        maxRecords = maxRecords, maxBytes = maxBytes,
    )
}
