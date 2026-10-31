# Saved-app selector

The native browser new-tab page shows saved apps directly over the voxel wallpaper,
with 116px thumbnails (100px on narrow phones), smaller white labels and a dark
text shadow. Images keep their intrinsic backgrounds; no card or thumbnail
backing is added. The accessible cog floats in the top-right corner. Use it to
choose an opaque RGB label colour (white by default), change the background or
enter edit mode: editable apps expose an Edit pill and a small corner ×. Flight
Deck remains a built-in launch tile and cannot be edited or deleted. The native
editor changes the app name and **actual launch URL**. Save validates the complete
HTTP(S) URL and rejects conflicts with another app or built-in Flight Deck.
Cancel discards changes. Query strings and fragments are preserved unless the
user deliberately edits them; route paths and trailing slashes remain distinct.

Custom thumbnails use a native image chooser, are decoded and normalized into
bounded PNG data, and persist with each identity's existing v1 bookmark records.
They take precedence over automatic icons. Use automatic icon removes the custom
image when saved. Existing title/URL records need no migration. Background
selection is also identity scoped; Default background restores the bundled voxel
beach sunset. Image input is limited to 5 MB/40 megapixels and PNG output to 2 MB;
thumbnail dimensions are at most 512 pixels and background dimensions at most
1920 pixels. Images are stored locally without uploading or signing.

Automatic icons start with the origin's `/favicon.ico`. Saving or visiting a saved
app reads its favicon/apple-touch-icon links and bounded same-origin manifest in
that visited document's ordinary web context. A manifest icon takes precedence
when available. Cross-origin manifest/icon discovery, redirects, credentials and
FIPS metadata fetching are excluded. Legacy entries can obtain manifest metadata
on their next visit. Invalid or unavailable metadata leaves the icon/initial
fallback. These decorative values never change a launch URL, service identity,
consent decision or signature. The selector has a restrictive CSP, no-referrer
images and no network connection capability beyond decorative image loads.

## Startup stars and tab restoration

In edit mode, each saved app has a startup star. Stars are off by default;
malformed values fail closed. Stars follow bookmark URL edits and disappear
when the bookmark is deleted. Metadata refresh preserves the star. Retired
built-in app choices and the retired browser-owned loopback endpoint are ignored.
Label colours accept only `#RRGGBB`; invalid values fall back to white.
Backgrounds, thumbnails, colours and stars are local to the identity.

After PIN unlock on a cold relaunch, a valid identity-scoped
`wingman.browser.tabs.v3.<identity>` snapshot takes precedence over startup
stars. Recovery recreates webviews with saved URLs, titles, tab order, active
tab, prefixes and colours. A saved home-only session is intentional and stays
home; closing windows does not resurrect older ones. Recovery does not restore
unsaved forms, page memory or back/forward history. PIN entry is still required
on cold startup, and document capabilities require fresh consent/authentication.
No secrets, signatures or transport grants are stored in the snapshot.

When no recoverable v3 snapshot exists, each distinct starred external app opens
once in launcher order. With no stars, the launcher stays open. Corrupt,
unsupported or invalid snapshots safely fall back to this startup behavior.
Older v1 records are left untouched. Editing stars does not discard a working
session or navigate existing windows; stars define the fallback launch set.
Opening/reloading home and background/foreground transitions never rerun stars.

Tab changes capture state immediately and serialize platform preference writes
per identity, including across screen recreation. Background and disposal flush
the latest state; sudden process termination can still lose a write the OS has
not committed. Disk reads wait for pending writes and verify the identity and
screen generation before applying results. Within one screen lifetime, identity
switches capture the departing state, revoke document capabilities and clear web
state before restoring the destination's own session. A temporary neutral home
is never saved over a pending restore. Same-identity lock/unlock keeps windows
and active tab, revokes capabilities on lock, and reloads pages on unlock.
Startup preferences are not transport or authentication grants.

## Focused checks

Run from `app/`:

```sh
flutter test test/browser_bookmark_store_test.dart test/bookmark_editor_test.dart \
  test/browser_app_selector_test.dart test/browser_startup_test.dart test/widget_test.dart \
  test/profile_avatar_picker_test.dart test/grasp_browser_consent_test.dart \
  test/native_signer_lock_test.dart test/mesh_auth_signing_test.dart
flutter analyze
flutter build macos --debug
flutter build ios --debug --no-codesign
flutter build apk --debug
```

Build availability depends on the local Flutter, Xcode, Android SDK/JDK and native
FIPS libraries. A build does not install or update a running app.

## Rendered browser checks

Generate fixtures only in a verified ignored directory. From the repository root:

```sh
git check-ignore tmp/docs/handoffs/app-selector-validation/selector.html
cd app
APP_SELECTOR_EVIDENCE_DIRECTORY="$(pwd)/../tmp/docs/handoffs/app-selector-validation" \
  flutter test test/browser_app_selector_test.dart
cd ..
node app/test/browser_app_selector_browser_test.mjs \
  tmp/docs/handoffs/app-selector-validation
```

The Node check uses Playwright. If it is installed outside the current repo, set
`PLAYWRIGHT_MODULE` to its absolute module entry; optionally set
`CHROMIUM_EXECUTABLE` to a supported local Chromium/Chrome binary. It blocks real
network traffic, validates exact launch URLs and controls, checks layouts at
320/390/768/1440 pixels and writes screenshots to the supplied ignored directory.
It exercises favicon/manifest resolution, malformed/oversized manifests,
credential omission, custom-image precedence and service/cross-origin rejection.
Browser renders complement the fake-WebView native wiring tests. Native device
photo chooser and WebView appearance still require manual review in a separately
installed build.

## Manual review

Use a disposable test profile/build for relaunch checks; preserve any existing
user session and do not reset its storage.

- Open several external apps and confirm tile taps reuse the active tab and
  preserve the full URL, including query and fragment. Select a nonfirst tab,
  relaunch, unlock with the PIN and verify tab order and active selection.
- Verify wrong PIN leaves saved pages unopened. Lock and unlock the same identity
  while running: windows and selection remain, signing is denied while locked,
  and document capabilities require fresh authorization after reload.
- In a profile with no recovery snapshot, star zero, one and several external
  apps and verify the fallback set opens exactly once. Toggle stars without
  losing edit mode or navigating current pages. Existing recovered windows must
  take precedence over changed stars. Reload home and confirm it stays home.
- Close all working tabs until only home remains, relaunch and confirm home
  remains without resurrecting closed pages or opening stars.
- Navigate rapidly, immediately background/relaunch, then verify the latest
  committed URL is restored. Repeat with an identity switch; pages from the
  departing identity must not appear in the destination session. Test corrupt
  snapshots only with synthetic fixtures, never by modifying user storage.
- Enter edit mode using the cog. Edit a long URL to a shorter route, save and
  reopen its tile. Verify untouched query/fragment preservation and reject
  duplicates without dropping either app.
- Choose a custom thumbnail, cancel to discard, then choose again and save.
  Restart and verify persistence. Restore the automatic icon and test a missing
  favicon/manifest. Verify unreadable and oversized images report an error.
- Select/reset a background and switch identities. Each identity must restore its
  own saved apps, thumbnails, label colour, stars and custom background. Change identity or lock while
  editing; a stale editor must not save into another identity.
- Check keyboard focus, readable names, corner-delete touch targets, narrow
  portrait/tall scrolling and wide desktop layouts.

The bundled `app/assets/app-selector/voxel-beach.png` was generated using the
built-in imagegen tool from a user-supplied beach sunset reference. Prompt:
transform the reference into a polished voxel beach sunset; preserve the low
horizon, broad blue-gray-to-orange sky, ocean waves, sand, sparse volleyball poles,
small distant people, foreground path and grass; wide landscape, quiet warm mood,
no text, logos, UI, watermark or borders.
