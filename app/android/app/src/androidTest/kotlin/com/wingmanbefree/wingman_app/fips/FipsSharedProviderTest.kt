package com.wingmanbefree.wingman_app.fips

import android.content.ComponentName
import android.net.Uri
import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Real Android IPC/manifest checks; production enrollment must remain fail-closed. */
class FipsSharedProviderTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val authority get() = "${context.packageName}.fips.shared"

    @Test fun providerIsExplicitAndConsentActivityCannotBeLaunchedByOtherApps() {
        val provider = context.packageManager.resolveContentProvider(authority, 0)!!
        assertTrue(FipsSharedEnrollment.supportsProvider(context.packageName))
        assertEquals(authority, provider.authority)
        assertEquals(context.applicationInfo.uid, provider.applicationInfo.uid)
        assertEquals(context.packageName, provider.packageName)
        assertTrue(provider.exported)
        assertFalse(provider.grantUriPermissions)
        @Suppress("DEPRECATION")
        val activity = context.packageManager.getActivityInfo(ComponentName(context, FipsSharedConsentActivity::class.java), 0)
        assertFalse(activity.exported)
    }

    @Test fun unenrolledCallerDeniedBeforeAnyRuntimeOrRequestParsing() {
        listOf("request", "check", "release", "unknown").forEach { method ->
            val reply = context.contentResolver.call(Uri.parse("content://$authority"), method, "forged", Bundle().apply {
                putInt("version", 1)
                putString("packageName", context.packageName)
                putString("certificate", "ab".repeat(32))
            })!!
            assertEquals(1, reply.getInt("version"))
            assertEquals("unauthorized", reply.getString("status"))
            assertFalse(reply.containsKey("networkHandle"))
            assertFalse(reply.containsKey("consentIntent"))
        }
    }

    @Test fun actualShellUidCannotSpoofAnApprovedPackage() {
        val descriptor = instrumentation.uiAutomation.executeShellCommand(
            "content call --uri content://$authority --method request --extra packageName:s:${context.packageName}")
        val output = android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use { it.readText() }
        assertTrue(output, output.contains("unauthorized"))
    }
    @Test fun externalShellCannotOpenConsentWithForgedRequestId() {
        if (android.os.Build.VERSION.SDK_INT < 34) {
            org.junit.Assume.assumeTrue("Shell stderr capture requires API 34", false)
            return
        }
        val pipes = instrumentation.uiAutomation.executeShellCommandRwe(
            "am start -W -n ${context.packageName}/com.wingmanbefree.wingman_app.fips.FipsSharedConsentActivity -d fips-shared-consent:forged")
        pipes[1].close()
        val output = android.os.ParcelFileDescriptor.AutoCloseInputStream(pipes[0]).bufferedReader().use { it.readText() } +
            android.os.ParcelFileDescriptor.AutoCloseInputStream(pipes[2]).bufferedReader().use { it.readText() }
        assertTrue(output, output.contains("Permission Denial") || output.contains("not exported"))
    }

    @Test fun productionEnrollmentPinsOnlyExactApprovedPackagesAndCertificates() {
        val entries = context.resources.getStringArray(com.wingmanbefree.wingman_app.R.array.fips_shared_clients).toList()
        assertEquals(2, entries.size)
        entries.forEach { entry ->
            val (pkg, cert) = entry.split('|')
            val caller = FipsSharedCaller(20001, pkg, cert)
            assertTrue(FipsSharedEnrollment.authorized(caller, listOf(pkg), listOf(cert), entries))
            val replacement = caller.copy(certificate = "ab".repeat(32))
            assertFalse(FipsSharedEnrollment.authorized(replacement, listOf(pkg), listOf(replacement.certificate), entries))
            assertFalse(FipsSharedEnrollment.authorized(caller.copy(packageName = "$pkg.nightly"), listOf("$pkg.nightly"), listOf(cert), entries))
            assertFalse(FipsSharedEnrollment.authorized(caller.copy(packageName = "example.forged"), listOf("example.forged"), listOf(cert), entries))
        }
    }

}
