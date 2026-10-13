# Generic WebView fullscreen and media

The repository-owned WebKit fork creates each `WKWebViewConfiguration` through
`BrowserWebViewConfiguration.make()`. On macOS 12.3+ and iOS 15.4+ it enables
public `WKPreferences.isElementFullscreenEnabled`. Older systems keep their
existing behavior. WebKit still enforces user activation, document lifecycle,
and iframe fullscreen permissions. No browser JavaScript capability is added.

Apple documents that fullscreen moves the webview out of the application's
view hierarchy. WebKit owns fullscreen entry, exit, and view restoration. The
WM App Focus Mode only hides shell chrome and remains independent; the macOS
menu's `toggleFullScreen:` action controls the shell window separately.

The browser explicitly allows inline WebKit media, while audio and video still
require a user gesture. iPhone videos also require HTML `playsinline`.
The inline option is a no-op on macOS. Android retains the pinned plugin's
standard custom-view fullscreen callbacks; this change does not establish
Android system-bar behavior or device validation. iOS fullscreen availability
also depends on WebKit's device/element support and must be tested on the target
device. A supported OS version alone is not proof of successful entry.

References: [Apple fullscreen preference](https://developer.apple.com/documentation/webkit/wkpreferences/iselementfullscreenenabled),
[inline media](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/allowsinlinemediaplayback),
and [media user activation](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/mediatypesrequiringuseractionforplayback).

## Automated configuration check

From the repository root on macOS, compile the production configuration helper
with the independent native regression check into a temporary directory:

```sh
check_dir=$(mktemp -d)
xcrun swiftc packages/webview_flutter_wkwebview/darwin/webview_flutter_wkwebview/Sources/webview_flutter_wkwebview/BrowserWebViewConfiguration.swift tools/tests/browser_webview_configuration.swift -o "$check_dir/browser-check"
"$check_dir/browser-check"
```

This checks the actual WebKit configuration, its use by a WKWebView, and that
media/domain policies retain native defaults. It loads real WebKit documents to
check top-level/allowed-iframe capability and denial in a forbidden iframe. The vendored Pigeon constructor
unit test also asserts fullscreen is enabled. Neither check proves interactive
fullscreen entry or Flutter platform-view restoration.

## Runtime checklist

Serve `app/test/fixtures/webview_fullscreen_media.html` from an approved local
origin or HTTPS test host and open it in the newly built WM App. Record the
binary version/hash and OS version using generic device labels.

1. Confirm `fullscreenEnabled=true` on a supported device. Click Enter fullscreen;
   verify screen takeover and absence of WM tab/address bars. Click Exit; confirm
   the webview returns, shell chrome is restored, and the page responds.
2. Repeat with Escape and with Focus Mode already active. Exiting DOM fullscreen
   should preserve the preceding Focus Mode setting.
3. Enter the allowed iframe fullscreen; exit and confirm recovery. The denied
   iframe must reject fullscreen. Keep user activation and permissions intact.
4. Navigate/reload while fullscreen, then re-enter and exit. Confirm the returned
   webview remains usable, tabs can switch/close, and navigation works.
5. Supply a known playable HTTPS MP4. Load metadata, press Play, verify advancing
   playback/audio, pause, and player fullscreen/exit. Repeat on iOS with inline
   playback and on Android with the standard custom view and Back recovery.
6. In the actual WApp, repeat outer-viewer and nested-presentation fullscreen
   with iframe permissions, then direct video and YouTube. Record provider errors,
   embed URL, iframe policy and referrer behavior. A placeholder UI, native
   gesture policy, media decode/network failure, and provider refusal are separate
   diagnoses. Do not disable origin enforcement or create a media network bridge.

A source build does not update an installed/running binary. Activation and the
interactive checklist are separate completion evidence.
