package com.wingmanbefree.wingman_app.fips

import android.app.Activity
import android.app.AlertDialog
import android.app.KeyguardManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager

/** Non-exported; the only external entry is an immutable provider PendingIntent. */
class FipsSharedConsentActivity : Activity() {
    private var id: String? = null
    private var decided = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= 31) window.setHideOverlayWindows(true)
        setFinishOnTouchOutside(false)
        id = intent.data?.takeIf { it.scheme == "fips-shared-consent" }?.schemeSpecificPart
        FipsSharedRuntime.refresh()
        val request = id?.let { FipsSharedAccess.policy.view(it) }
        if (request == null || request.state != "pending" || getSystemService(KeyguardManager::class.java).isDeviceLocked) {
            finish()
            return
        }
        val caller = FipsSharedAccess.authenticate(this, request.caller.uid, request.caller.packageName)
        if (caller != request.caller) { FipsSharedAccess.policy.release(request.id); finish(); return }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Share running FIPS connection?")
            .setMessage("App: ${caller.packageName}\nSigning certificate SHA-256:\n${caller.certificate}\n\n" +
                "Endpoint: ${request.endpoint.endpoint}\nPeer: ${request.endpoint.peerNpub}\nPort: ${request.endpoint.port}\nPurpose: NStack\n\n" +
                "Allow this app to use the existing VPN for this exact endpoint for up to 10 minutes. " +
                "No signing permission, keys or credentials are shared. Stop the VPN or lock the device to revoke.")
            .setPositiveButton("Allow once") { _, _ -> decide(true) }
            .setNegativeButton("Deny") { _, _ -> decide(false) }
            .setNeutralButton("Revoke all shared grants") { _, _ ->
                decided = true
                FipsSharedAccess.policy.revokeAll()
                finish()
            }
            .setOnCancelListener { decide(false) }
            .create()
        dialog.setOnShowListener {
            listOf(AlertDialog.BUTTON_POSITIVE, AlertDialog.BUTTON_NEGATIVE, AlertDialog.BUTTON_NEUTRAL).forEach {
                dialog.getButton(it).filterTouchesWhenObscured = true
            }
        }
        dialog.show()
    }

    private fun decide(allow: Boolean) {
        if (decided) return
        decided = true
        FipsSharedRuntime.refresh()
        id?.let { key -> FipsSharedAccess.policy.view(key)?.let { request ->
            val caller = FipsSharedAccess.authenticate(this, request.caller.uid, request.caller.packageName)
            if (caller == request.caller && !getSystemService(KeyguardManager::class.java).isDeviceLocked)
                FipsSharedAccess.policy.decide(key, caller, allow)
            else FipsSharedAccess.policy.release(key)
        } }
        finish()
    }

    override fun onDestroy() {
        // Back, configuration teardown and any uncompleted prompt fail closed.
        if (!decided) id?.let { key -> FipsSharedAccess.policy.view(key)?.let {
            FipsSharedAccess.policy.decide(key, it.caller, false)
        } }
        super.onDestroy()
    }
}
