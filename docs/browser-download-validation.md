# Browser download validation

Nostr Browser treats common HTTP(S) file extensions, `Content-Disposition:
attachment`, MIME types that WebKit/Chromium cannot display, and HTML
`download` links as downloads. The browser shows transfer progress and hands
the completed file to the platform's user-visible save surface.

## Local fixture

From `app/`, run:

```sh
dart run tool/browser_download_fixture.dart
```

Open `http://127.0.0.1:8787/` in Nostr Browser and check:

1. **Direct file URL** starts a download rather than replacing the page.
2. **Content-Disposition attachment** saves as `server-report.txt`.
3. **HTML download attribute** opens the platform save flow.
4. **Duplicate filename** clicked twice does not silently overwrite the first
   file. Android allocates a numbered Downloads name; Apple save panels apply
   their normal collision confirmation/renaming behavior.
5. **Failed response** reports the HTTP failure instead of leaving an inert
   click.

Confirm the start message, percentage updates when content length is known,
completion destination, Cancel action, and failure message. On iOS, complete
the Files picker and verify the file outside the app. On Android 10 and later,
verify the file under the public Downloads collection. Older Android versions
use the system create-document flow. macOS uses the system save panel.

## Automated checks

```sh
cd app
flutter analyze
flutter test test/browser_download_test.dart
flutter test
flutter build ios --debug --simulator --no-codesign
flutter build apk --debug
flutter build macos --debug
```

The focused tests use a real loopback HTTP server. They cover direct and
attachment responses, safe server filenames, duplicate destinations,
cancellation, failed responses, WebView cookie use, same-origin Authorization
preservation, and removal of Authorization on a cross-origin redirect.

The download channel is native-shell-only. It is not exposed to web content
and does not change `window.fipsTransport`, signing, navigation consent, or
Nostr key boundaries.
