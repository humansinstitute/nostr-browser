# WebView file-picker validation

WMAPP uses the platform WebView file-selection APIs independently of its
`window.open` and `_blank` tab routing.

## Architecture and upgrade note

- Android registers `AndroidWebViewController.setOnShowFileSelector` and sends
  the request to `ActivityResultContracts.OpenDocument` or
  `OpenMultipleDocuments`. Those contracts return `content://` URIs and require
  no broad storage permission.
- macOS uses a repository-owned path copy of
  `webview_flutter_wkwebview` 3.26.0. It includes generic fullscreen configuration (see
  [fullscreen/media validation](webview-fullscreen-media-validation.md)) and the missing
  `WKUIDelegate.runOpenPanelWith` callback, which presents `NSOpenPanel` and
  returns file URLs to WebKit. When upgrading the upstream package, compare
  `UIDelegateProxyAPIDelegate.swift` and the configuration constructor. Remove the
  fork when upstream supplies both capabilities, preserving browser settings.
- `WKOpenPanelParameters` exposes multiple-selection and directory-selection
  policy, but no accepted MIME types or extensions on macOS. WMAPP therefore
  cannot configure `NSOpenPanel.allowedContentTypes` from an HTML `accept`
  attribute through this API. Android does receive and apply MIME accept types.
- iOS behavior is unchanged. This integration is not evidence of iOS file-input
  support or validation.

## Deterministic fixture

`app/test/fixtures/webview_file_picker.html` contains single-file,
multiple-file, and image-filtered inputs plus visible selected-file names. The
pre-change failure is also deterministic in the pinned upstream source:
`UIDelegateImpl` did not respond to WebKit's
`runOpenPanelWithParameters` selector, so this fixture's buttons had no native
delegate path on macOS. The repository fork adds exactly that missing selector.

## Manual checklist

1. Open `app/test/fixtures/webview_file_picker.html` in WMAPP on macOS and
   confirm each button opens
   `NSOpenPanel`.
2. Cancel each panel; confirm the page remains responsive and does not navigate
   or reload.
3. Select one file in **Single file** and confirm its name appears.
4. Select two files in **Multiple files** and confirm both names appear.
5. Open Forgejo profile settings, choose a valid custom-avatar image, submit,
   and confirm the avatar changes.
6. On Android, repeat the single, multiple, cancellation, and image-only checks;
   confirm the system document picker is used and app permissions do not include
   broad file/storage access.
7. On both platforms, activate a `_blank` link separately and confirm it still
   opens a WMAPP tab rather than invoking a file picker.
