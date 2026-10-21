# Browser keyboard focus validation

Embedded native content and Flutter shell controls have separate focus systems.
A shell menu button deliberately focused by keyboard supports standard Space and
Enter activation. Touching the embedded browser transfers Flutter focus to a
neutral, non-traversal target so a stale shell button cannot activate while
WebKit owns text input. The boundary does not inspect DOM contents, cancel keys,
or alter native responder ownership, signing, or transport.

Run `flutter test` and `flutter analyze` from `app`. The focus regression tests
cover stale menu focus, key down/up/repeat, Space with Shift/Control/Alt/Meta,
intentional menu activation, and Flutter text input composition. Widget tests
use simulated content; they do not prove UIKit/WKWebView event delivery.

Before approving on iPad, use both a hardware keyboard and the software keyboard:

1. Open and close the sidebar, then tap a browser editor. Enter `two words `
   in input, textarea, contenteditable, and an embedded WApp editor, including
   an iframe editor. Repeat after switching tabs and entering/exiting focus mode.
2. Hold Space for repetition. Test Shift+Space and editor shortcuts with
   Control, Option, and Command. Confirm the sidebar stays closed and the page
   retains its expected keyboard behavior. Ctrl+Tab remains the shell tab action.
3. Use an IME or predictive input; commit and cancel composition, and insert
   spaces during and after composition. Test multiline Enter as well.
4. Navigate to the menu with keyboard traversal and activate it with Space and
   Enter. Verify touch and accessibility activation also open the sidebar.
5. Test Full Keyboard Access and VoiceOver, including keyboard-only movement
   from shell to page and programmatic editor focus without a page touch. These
   native focus paths require device confirmation beyond widget coverage.

Activation requires a newly built, appropriately signed WM App package installed
through the normal approved device distribution process. Updating WApp content
alone does not update this Flutter focus change. No service restart is required.

## Command-arrow app navigation

Command+Right uses the same next-tab action as the mobile right-edge swipe:
all open tabs, including the launcher, in strip order, wrapping to the first.
With one tab it stays put. Command+Left opens the sidebar (it does not toggle it
or navigate backward). Both work with controls visible or in focus mode.
Holding an arrow performs one action per press. Shift, Option and Control
combinations retain their existing behavior; Ctrl+Tab is unchanged.

Flutter handles shell events while WebKit handles native page events through a
small document-start script in every frame. The script uses actual DOM focus,
including shadow focus, rather than assuming the shell's focus reflects WebKit.
It preserves input, textarea, select, contenteditable, designMode, ARIA text
editors, Monaco and CodeMirror, composition, and events already handled by an
app. Custom or closed-shadow editors can mark their host with
`data-wingman-keyboard="editor"`, use a textbox role, or handle the key with
`preventDefault`/`stopPropagation`. The navigation channel exposes only next-app
and open-menu actions; it adds no network capability. Native messages from
inactive/closed tabs and shortcuts while a modal or drawer is open are ignored.

Run these from the repository root on macOS:

```sh
mkdir -p tmp/docs/handoffs/keyboard-validation
cd app
KEYBOARD_EVIDENCE_DIR="$PWD/../tmp/docs/handoffs/keyboard-validation" \
  flutter test test/browser_keyboard_shortcuts_test.dart
cd ..
swiftc tools/tests/browser_keyboard_shortcuts.swift \
  -o tmp/docs/handoffs/keyboard-validation/native-keyboard
tmp/docs/handoffs/keyboard-validation/native-keyboard \
  tmp/docs/handoffs/keyboard-validation/keyboard.js
```

The harness opens a disposable native WKWebView window and sends injected
NSEvents through the macOS responder chain. This verifies WebKit event delivery,
page/iframe handling and editor exclusion; it is simulated keyboard input,
not physical keyboard acceptance or a full Flutter/native integration test.

On the installed Nostr Browser build, confirm with a hardware keyboard:

1. Open three apps. From a non-editing page area, press Command+Right repeatedly
   and verify order and wraparound; confirm page state survives and no reload
   occurs. Repeat with one tab, after reordering/closing tabs, from the launcher,
   after tab restoration, and in focus mode.
2. Press Command+Left on the launcher and each app. Confirm the sidebar opens;
   a second press keeps it open. Close the sidebar and resume app navigation.
3. Repeat both arrows in the address field, input, textarea, contenteditable,
   Monaco/CodeMirror, custom editors, shadow editors and same/cross-origin iframe
   editors. Verify normal caret movement, unchanged values and selection,
   no tab switch or sidebar activation, and composition commit/cancel.
4. Verify extra modifiers, held keys, custom app key handlers, and modal dialogs.
   Switch between shell controls and programmatically focused page editors.
5. On mobile, confirm the top/right/left edge gestures still reveal controls,
   cycle apps and open the drawer. Physical mobile acceptance requires a device;
   the existing gesture tests simulate touch sequences.

Use the README's local macOS build/launch procedure. A direct documented
`flutter build macos --debug` preserves the currently bundled Flight Deck assets;
`runapp.sh` launches that build. Verify the intended NBrowser process before
using the launcher, which stops existing processes with its executable name.
