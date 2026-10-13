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

In edit mode, each app has a startup star, including the built-in Flight Deck /
Ambulando tile. Stars are off by default for new and existing installations.
Legacy v1 bookmark records lacking `startup: true` remain unstarred; malformed
values also fail closed. Saved app stars travel with the bookmark when its URL
is edited and disappear when it is deleted. Metadata refresh and thumbnail
changes preserve the star. The built-in choice is a separate identity-scoped
boolean so it survives changes to the packaged app's local endpoint. It cannot
be deleted. Label colours accept only `#RRGGBB`; invalid stored values fall back
to white. Backgrounds, thumbnails, colours and stars are local to the identity.

A fresh session means creation of the native browser screen, including app
relaunch. After loading preferences, it opens each distinct starred app once,
with the built-in first if selected, then saved apps in launcher order. With no
stars it stays on the launcher. Availability of the packaged app never forces
navigation. Opening or reloading a home tab, changing settings, and native
background/foreground transitions do not run startup selection again. Settings
saves update all existing home documents without closing edit mode.

Disk tab restoration is intentionally superseded by startup selection at the
fresh-session boundary. Existing `wingman.browser.tabs.v1.<identity>` records
are neither read for startup nor removed/overwritten. Normal running tab writes
now use `wingman.browser.tabs.v3.<identity>` (snapshot version 3); these disk
records also do not control startup. Within one browser-screen lifetime,
changing identity saves an in-memory tab snapshot, revokes capabilities, clears
web state and immediately shows a neutral launcher while preferences load. The
first visit to another identity applies its stars; returning to an already
visited identity restores its session URLs, tab order, active tab, titles,
prefixes and colours rather than running startup again. As before, identity
switches recreate webviews, so page memory and back/forward history are not
carried across identities. Ordinary navigation and tab state continue during a
running identity session. Async reads and settings are checked against the
identity/document generation, including A→B→A changes. Startup preferences are
not grants for transport or authentication.

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

- Open several apps and confirm tile taps reuse the active tab and preserve the
  full destination URL. Verify built-in Flight Deck and ordinary tab navigation.
- Star zero, one and several apps (including the built-in), relaunch and verify
  each selection opens exactly once. Old saved tabs must not add unselected
  destinations. Toggle several stars without losing edit mode. Reload a launcher
  and confirm it stays a launcher. Edit a starred URL and verify relaunch follows
  the new URL; delete it and verify it no longer launches.
- Enter edit mode using the cog. Edit a long URL into a deliberately shorter
  route, save, restart the app and reopen it. Verify query/fragment preservation
  for an untouched URL and reject duplicates without dropping either app.
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
