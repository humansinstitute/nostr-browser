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
