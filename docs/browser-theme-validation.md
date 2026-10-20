# Nostr Browser theme

`BrowserPalette` is the framework-independent source for the dusk-purple frame,
light reading surfaces and orange accents. `BrowserTheme.light()` styles app-owned
reading surfaces, menus, settings and consent dialogs. `BrowserTheme.chrome()`
styles the tab strip and navigation toolbar while retaining light inputs and
menus. The HTML new-tab launcher consumes the same palette as CSS variables.
Ambulando retains its existing theme and launcher styling. Embedded websites
keep their own rendering; no transport, signing or policy code belongs here.

The active tab has an orange marker, purple fill and lavender text. User-selected
tab colours remain available. Light surfaces use dark purple text; errors retain
an explicit red colour. Orange focus in the launcher sits against dark tiles;
the light address field uses a darker burnt-orange focus border. Menus, dialogs
and settings cards use small bevels. Launcher fallback tiles use block shadows;
custom images retain their original backgrounds and label colours remain editable.

## Reproducible validation

From the repository root, verify the output location is ignored and untracked:

```sh
git check-ignore tmp/docs/handoffs/theme/chrome-390.png
git ls-files tmp/docs/handoffs/theme
mkdir -p tmp/docs/handoffs/theme
cd app
flutter analyze
flutter test
flutter build macos --debug
```

The focused widget test exercises production browser tabs/navigation, profile and
tab context menus, the real browser signing-message path and rejection, and the
production settings screen at 320, 390 and 1440 logical pixels. It also checks text,
disabled navigation and error contrast. To capture readable widget previews, set
`BROWSER_THEME_FONT_DIRECTORY` to Flutter's `bin/cache/artifacts/material_fonts`
directory (containing Roboto and MaterialIcons), and run from `app/`:

```sh
BROWSER_THEME_FONT_DIRECTORY="<flutter-sdk>/bin/cache/artifacts/material_fonts" \
BROWSER_THEME_EVIDENCE_DIRECTORY="$PWD/../tmp/docs/handoffs/theme" \
  flutter test test/browser_theme_test.dart
APP_SELECTOR_EVIDENCE_DIRECTORY="$PWD/../tmp/docs/handoffs/theme" \
  flutter test test/browser_app_selector_test.dart
cd ..
node app/test/browser_app_selector_browser_test.mjs tmp/docs/handoffs/theme
```

The launcher browser check needs Playwright. `PLAYWRIGHT_MODULE` may point to an
installed Playwright module and `CHROMIUM_EXECUTABLE` to an available Chromium.
It renders the actual generated launcher HTML with the bundled voxel background
at 320, 390, 768 and 1440 pixels, including edit mode, exact launch URLs and bridge
messages. It checks overflow, fallback images and existing network restrictions.

Widget previews use a simulated webview and local test identity; blank content
below the chrome is the simulated webview. They are not captures of the installed
app or proof of native webview compositing. HTML launcher captures are real
Chromium renders of generated production HTML, separate from Flutter chrome.
Label both kinds when sharing. A successful macOS build does not update the
installed application. The native `dart:ffi` web-build limitation is separate.

For native review, launch a separately built app without replacing the installed
copy. Check the tab strip, address reveal, focus/hover, disabled Back/Forward,
profile menu, tab menu, drawer, launcher edit mode, settings, and signing consent
at desktop and narrow sizes. Verify external pages retain their styling, PINs mask
immediately, and transport/authentication approvals remain distinct. Keep native
screenshots and run-specific evidence ignored or on the authorized task/file
surface; do not put device identifiers in reusable documentation.
