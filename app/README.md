# Nostr Browser Flutter Shell

This is the first Flutter shell shape for Nostr Browser.

It is intentionally thin:

- Setup manages browser approvals and optional Tower configuration. Identity fields come from the encrypted signer vault.
- Status calls a bridge abstraction for `wmapp-core` where the local process is available.
- Drive shows the expected workspace/scope/channel/file surface.
- Browser provides the embedded WApp/WebView signer area.
- Encrypted signer onboarding, NIP-07 `signEvent`, and NIP-98 signing are implemented in Dart for desktop and mobile.

Flutter platform folders have been generated for macOS, Linux, web, Android,
and iOS. To run the current shell locally:

```bash
../tools/update_flightdeck_bundle.sh
flutter pub get
flutter test
flutter build web
flutter build macos --debug
flutter run -d macos
flutter build apk --debug
flutter build ios --debug --no-codesign
```

The root repo also has convenience scripts:

```bash
../build_runapp.sh
../build_android_apk.sh
../build_ios_debug.sh
../build_ios_debug.sh simulator
```

Desktop still uses `wmapp-core` for Drive sync, device registration, channel
validation, local file mounting, and NIP-44 encryption/decryption. Mobile builds
currently report those process-backed operations as unavailable instead of
attempting to shell out to Rust.

Signer keys are not loaded from shell environment variables. First launch opens
the browser without requiring Tower configuration. Use the avatar menu's
**Create identity / Import key** action to generate a key securely in Dart or
import your existing nsec. Choose a PIN; the existing vault encrypts the key with
the PIN plus a per-install secure-storage secret. The clear nsec stays in memory
after unlock. On startup, an existing vault requires its PIN before saved browser
tabs open and authenticate. After logout, **Unlock identity** retries authentication
in the existing tabs without clearing browser storage. An existing vault offers **Unlock identity** and cannot be replaced
without an explicit destructive reset. Keep the vault and PIN safe. **Edit profile → Export private key (nsec)**
requires a risk acknowledgement and PIN confirmation. The key is hidden after
60 seconds or when the app loses focus; copying is explicit and the clipboard
is not automatically cleared.

New identities continue to profile setup. The avatar's **Edit profile** supports
name, display name, avatar URL, NIP-05 address, website, and about. **Save** signs and
publishes a public Nostr kind-0 event on the existing profile relays (Damus and
Primal). A successful acknowledgement closes the editor. Failed publication
keeps the draft and editor open; tap **Save** to retry. Status appears in toasts. Publication does not verify NIP-05 or
register a Tower account/device. Unpublished local edits, including legacy saved profiles,
remain protected across restarts and identity switches. After acknowledgement
of the current draft, automatic refresh accepts strictly newer remote profiles.
Delayed acknowledgements cannot clear subsequent edits; publication timestamps
increase even when multiple publishes occur within the same second.

If Tower URL, workspace service npub, and device identity are configured, Setup
also exposes **Register device** through the existing desktop native-core path.
Mobile still reports this process-backed operation as unavailable. Public Nostr
profile publication works without Tower and does not require the native core.

The profile editor displays a shortened npub with an icon that copies the full key.
The upload icon in the **Avatar URL** field accepts JPEG, PNG and WebP files up to 5 MiB and 40 megapixels.
Images are resized proportionally to fit 512 × 512 pixels and re-encoded as PNG
without source metadata, with a 2 MiB output cap. Animated images use the first
frame. Uploads go to `https://blossom.primal.net/upload` using a short-lived,
hash-scoped Blossom authorization event; the private key stays on the device.
The server receipt must match the uploaded hash, size and Primal HTTPS URL.
Uploading makes the image public immediately; Save signs and publishes the
updated Nostr profile. Cancelling does not delete
an uploaded image. Primal storage/payment errors leave existing profile fields
intact and allow retry.

## Tower FIPS sync

In your existing Flight Deck workspace, select FIPS in Connection settings,
enter the exact mesh endpoint and approve native pairing. The workspace's Tower
service identity is verified over that mesh route before signing is enabled.
No native Tower URL or reachable public Tower is required. HTTPS is optional.

Built-in Flight Deck is eligible by default. For an external Flight Deck page,
set its URL in native Setup → Flight Deck browser, save and reload the same tab.
This explicit page-origin boundary remains separate from general signer trust.
Keep the same page and workspace to retain local data and pending writes.
Native Drive sync has its own optional Tower configuration.
