# Android embedded FIPS first-run lifecycle

## First-run sequence

1. Setup's **Install or repair** action calls `FipsRuntimeService.installOrRepair`; opening an exact `.fips` target calls `ensureReadyForAppAccess`, which inspects first and activates the runtime when needed.
2. `MethodChannelFipsAndroidRuntime` invokes `inspect`, then `start` or `repair`, on `com.wingmanbefree.wingman_app/fips`.
3. Native inspection runs on the coordinator worker. Android VPN consent inspection (`VpnService.prepare`) runs on the activity thread.
4. One `FipsStartOperation` owns the start. It resets the prior Java/native TUN owner, creates the private FIPS directory, and invokes JNI `nativePrepare` on the worker.
5. The coordinator prepares VPN consent on the activity thread. If Android returns an intent, `MainActivity` launches it through the Activity Result API. Cancellation completes the original channel call as `failed`; approval continues the same operation.
6. Foreground-service launch runs on the activity thread. `FipsVpnService` promotes itself, selects an eligible non-VPN underlying network, creates the split-route TUN, starts the native node, protects its UDP sockets, and passes the TUN and underlying network handle to Rust.
7. The coordinator polls sanitized native status until `running`, a structured service/native failure, or timeout. It then completes the original method result exactly once.
8. Dart maps the result to `FipsRuntimeStatus`. A running runtime waits briefly for its authenticated bootstrap peer; setup or the shell then opens the target or shows a concise failure with a retry path.

## Code-supported pre-0.1.4 failure modes

No physical-device logcat exists for the reported failure, so none of these is claimed as the single confirmed root cause.

- **High confidence:** `inspectWithConsentState` called `VpnService.prepare(activity)` from a worker executor even though VPN consent is activity/UI lifecycle work.
- **High confidence:** exceptions from reset, directory creation, JNI preparation, preparation JSON decoding, consent launch, foreground-service launch, and readiness JSON decoding could escape their task or the activity callback without completing the stored `MethodChannel.Result`.
- **High confidence:** activity destruction or engine detach did not complete or clear the stored result, so Dart's operation could remain pending and `_operationInProgress` could remain set.
- **High confidence:** `FipsVpnService.onCreate` called notification construction and `startForeground` without a guard; service/notification restrictions could escape as a process-level framework exception.
- **Medium confidence:** repeated taps or a late activity result could race the single unscoped stored result because the old request-code callback had no operation generation/lifecycle guard.
- **Medium confidence:** malformed or failed native JSON could throw from coordinator or service code; native error details could also contain more filesystem context than should reach UI.
- **Device-dependent:** foreground-service launch denial, OEM VPN consent behavior, unavailable eligible underlying networks, notification-channel failures, or VPN establishment denial are plausible on Android 10–16, but require Owner's device logcat to distinguish.

## Notification permission

`POST_NOTIFICATIONS` is not required for foreground-service launch correctness on Android 13 and later. A user denial can suppress the notification from the notification drawer, while Android still surfaces the foreground service in Task Manager. WMAPP therefore does not add a notification permission prompt to this first-run flow; Android VPN consent remains the only required system interaction.

## Exporting startup diagnostics

After reproducing a failed start, Owner can export without Tower, a WebView, or a running FIPS node: open the profile/avatar menu, select **Setup**, find **FIPS transport**, and tap **Export diagnostics**. Android opens its document picker with a name such as `wmapp-fips-diagnostics-20260902-123456Z.txt`; choose a destination, then attach that file to the diagnostic report. A failed `.fips` navigation also offers an immediate **Export** action, while **Setup** remains available for retry or repair.

The UTF-8 file starts with the WMAPP release/build, generation time, privacy notice, and retention policy. Each following JSON line contains only UTC time, release/build, Android/API and safe manufacturer/model metadata, event code, lifecycle phase, FIPS status/error code, consent/service state, and an exception class when it matches the strict class-name allowlist. It does not read system logcat and never includes private keys, nsec, raw Nostr events, NIP-98 or Authorization tokens, bunker/NWC/capability material, certificate or identity secrets, full sensitive paths, request/response payloads, browsing history, arbitrary WebView URLs, exception messages, stack traces, or a broad Android bug report.

The app-private journal survives process restarts and retains only the newest 200 records with a 128 KiB cap. Writes are serialized and atomically replace the prior journal; malformed or truncated lines are ignored during recovery. Normal events run off the activity thread, while a small set of immediately pre-crash lifecycle checkpoints is flushed synchronously. **Clear diagnostics** removes all retained records. Export cancellation, unavailable activity, picker/provider failure, lifecycle destruction, and duplicate taps return concise recoverable outcomes and do not disable **Install or repair**.
