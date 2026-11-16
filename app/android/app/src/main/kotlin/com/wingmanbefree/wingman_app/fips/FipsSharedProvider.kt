package com.wingmanbefree.wingman_app.fips

import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.SystemClock
import com.wingmanbefree.wingman_app.R
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

internal object FipsSharedAccess {
    private data class Watch(val messenger: Messenger, val death: IBinder.DeathRecipient)
    private val watches = ConcurrentHashMap<String, Watch>()
    val lifecycle = Binder()
    val policy = FipsSharedPolicy(SystemClock::elapsedRealtime, revoked = { id ->
        watches.remove(id)?.let { watch ->
            runCatching { watch.messenger.binder.unlinkToDeath(watch.death, 0) }
            runCatching { watch.messenger.send(Message.obtain().apply {
                what = 1
                data = reply("revoked").apply { putString("requestId", id) }
            }) }
        }
    })

    fun watch(id: String, messenger: Messenger) {
        val death = IBinder.DeathRecipient { policy.release(id) }
        val watch = Watch(messenger, death)
        watches[id] = watch
        try {
            messenger.binder.linkToDeath(death, 0)
            // The runtime or client may have died between allocation and linkToDeath.
            if (policy.view(id) == null) {
                watches.remove(id, watch)
                runCatching { messenger.binder.unlinkToDeath(death, 0) }
            }
        } catch (_: Exception) { policy.release(id) }
    }

    @Suppress("DEPRECATION")
    fun authenticate(context: Context, uid: Int, packageName: String): FipsSharedCaller? = runCatching {
        if (Build.VERSION.SDK_INT < 29) return null
        val pm = context.packageManager
        val packages = pm.getPackagesForUid(uid)?.toList() ?: return null
        val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        if (info.applicationInfo?.uid != uid) return null
        val certificates = info.signingInfo?.apkContentsSigners?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
        } ?: return null
        if (certificates.size != 1) return null
        val caller = FipsSharedCaller(uid, packageName, certificates.single())
        caller.takeIf { FipsSharedEnrollment.authorized(it, packages, certificates,
            context.resources.getStringArray(R.array.fips_shared_clients).toList()) }
    }.getOrNull()

    fun reply(status: String) = Bundle().apply { putInt("version", 1); putString("status", status) }
}

/** Exported metadata-only IPC. Every method authenticates the real Binder caller. */
class FipsSharedProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val context = context ?: return FipsSharedAccess.reply("unavailable")
        if (!FipsSharedEnrollment.supportsProvider(context.packageName)) return FipsSharedAccess.reply("unavailable")
        val caller = runCatching {
            val packageName = callingPackage ?: return@runCatching null
            FipsSharedAccess.authenticate(context, Binder.getCallingUid(), packageName)
        }.getOrNull() ?: return FipsSharedAccess.reply("unauthorized")
        if (extras?.getInt("version", 0) != 1) return FipsSharedAccess.reply("unsupported_version")
        val identity = Binder.clearCallingIdentity()
        return try {
            FipsSharedRuntime.refresh()
            when (method) {
                "request" -> request(context, caller, extras)
                "check" -> check(caller, arg)
                "release" -> {
                    if (arg == null) FipsSharedAccess.reply("invalid_request") else {
                        FipsSharedAccess.policy.release(arg, caller)
                        FipsSharedAccess.reply("released")
                    }
                }
                else -> FipsSharedAccess.reply("unsupported_method")
            }
        } catch (_: Exception) { FipsSharedAccess.reply("invalid_request") }
        finally { Binder.restoreCallingIdentity(identity) }
    }

    @Suppress("DEPRECATION")
    private fun request(context: Context, caller: FipsSharedCaller, extras: Bundle): Bundle {
        if (extras.getString("purpose") != "nstack") return FipsSharedAccess.reply("invalid_request")
        val endpoint = FipsSharedEndpoint.parse(extras.getString("endpoint") ?: "", extras.getString("peerNpub") ?: "")
        val messenger = extras.getParcelable<Messenger>("callback") ?: return FipsSharedAccess.reply("invalid_request")
        if (!FipsSharedAccess.policy.hasBinding() || context.getSystemService(KeyguardManager::class.java).isDeviceLocked)
            return FipsSharedAccess.reply("unavailable")
        val request = FipsSharedAccess.policy.request(caller, endpoint)
            ?: return FipsSharedAccess.reply(if (FipsSharedAccess.policy.hasBinding()) "busy" else "unavailable")
        FipsSharedAccess.watch(request.id, messenger)
        if (FipsSharedAccess.policy.view(request.id) == null) return FipsSharedAccess.reply("revoked")
        // Clear IPC identity only AFTER authentication; PendingIntent must belong to provider.
        val identity = Binder.clearCallingIdentity()
        val intent = try {
            PendingIntent.getActivity(context, 0, Intent(context, FipsSharedConsentActivity::class.java).apply {
                data = Uri.parse("fips-shared-consent:${request.id}")
            }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
        } finally { Binder.restoreCallingIdentity(identity) }
        return FipsSharedAccess.reply("consent_required").apply {
            putString("requestId", request.id)
            putParcelable("consentIntent", intent)
        }
    }

    private fun check(caller: FipsSharedCaller, id: String?): Bundle {
        if (id == null || id.length > 128) return FipsSharedAccess.reply("invalid_request")
        val request = FipsSharedAccess.policy.check(id, caller) ?: return FipsSharedAccess.reply("revoked")
        return FipsSharedAccess.reply(request.state).apply {
            putString("requestId", request.id)
            if (request.state == "ready") {
                putString("grant", request.id)
                putString("endpoint", request.endpoint.endpoint)
                putString("peerNpub", request.endpoint.peerNpub)
                putString("purpose", "nstack")
                putString("peerIpv6", request.endpoint.ipv6)
                putByteArray("peerIpv6Bytes", request.endpoint.address.toByteArray())
                putLong("networkHandle", request.binding.networkHandle)
                putString("generation", request.binding.generation)
                putLong("expiresElapsedRealtime", request.leaseDeadline)
                putLong("expiresAt", (System.currentTimeMillis() + request.leaseDeadline - SystemClock.elapsedRealtime()) / 1000)
                putBinder("lifecycle", FipsSharedAccess.lifecycle)
            }
        }
    }

    // No query, files, URI grants or mutable data surface is exposed.
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw SecurityException("unsupported")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw SecurityException("unsupported")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw SecurityException("unsupported")
}
