// Native WebKit regression harness; see docs/browser-keyboard-validation.md.
import Cocoa
import WebKit

final class Harness: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
  var window: NSWindow!
  var web: WKWebView!
  var calls = [String]()
  func sendArrow(_ code: UInt16, _ character: String,
                 modifiers: NSEvent.ModifierFlags = [.command], repeatKey: Bool = false) async throws {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = NSEvent.keyEvent(with: type, location: .zero,
        modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: repeatKey, keyCode: code)!
      NSApp.sendEvent(event)
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    let config = WKWebViewConfiguration()
    let script = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    config.userContentController.add(self, name: "WingmanNavigation")
    config.userContentController.addUserScript(WKUserScript(source: "window.WingmanNavigation = webkit.messageHandlers.WingmanNavigation;\n" + script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: config)
    web.navigationDelegate = self
    window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "NBrowser keyboard verification"
    window.contentView = web
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    web.loadHTMLString("<body tabindex='0'><input id='input' value='two words'><textarea id='textarea'>two words</textarea><div id='editable' contenteditable>two words</div><div id='custom' role='textbox' tabindex='0'>editor</div><iframe id='frame' srcdoc=\"<body tabindex='0'><input id='inner' value='two words'></body>\"></iframe></body>", baseURL: URL(string: "https://test.invalid"))
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { calls.append(message.body as! String) }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 500_000_000)
        window.makeFirstResponder(web)
        for (focus, expected) in [("document.body.focus()", 1), ("input.focus()", 0), ("textarea.focus()", 0), ("editable.focus()", 0), ("custom.focus()", 0), ("frame.contentDocument.body.focus()", 1), ("frame.contentDocument.getElementById('inner').focus()", 0)] {
          _ = try await web.evaluateJavaScript(focus)
          let before = calls.count
          for (code, character) in [(UInt16(124), "\u{f703}"), (UInt16(123), "\u{f702}")] {
            try await sendArrow(code, character)
          }
          let got = calls.count - before
          print("\(focus): expected \(expected * 2), got \(got)")
          if got != expected * 2 { exit(1) }
        }
        _ = try await web.evaluateJavaScript("document.body.focus()")
        let before = calls.count
        for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control], []] {
          try await sendArrow(124, "\u{f703}", modifiers: modifiers)
        }
        try await sendArrow(124, "\u{f703}", repeatKey: true)
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight', metaKey:true, bubbles:true, cancelable:true}))")
        _ = try await web.evaluateJavaScript("document.addEventListener('keydown', event => event.preventDefault())")
        try await sendArrow(124, "\u{f703}")
        guard calls.count == before else { print("FAIL: modifiers/repeats/untrusted/app-owned keys"); exit(1) }
        print("PASS: modifiers, repeats, untrusted events and app-owned shortcuts preserved")
        print("PASS: native WKWebView responder delivery with injected NSEvents; not physical keyboard acceptance")
        exit(0)
      } catch { print(error); exit(1) }
    }
  }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let harness = Harness()
app.delegate = harness
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("TIMEOUT"); exit(2) }
app.run()
