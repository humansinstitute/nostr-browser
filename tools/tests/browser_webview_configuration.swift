import AppKit
import WebKit

// Compile with BrowserWebViewConfiguration.swift; no Flutter runtime required.
@main
struct BrowserConfigurationCheck {
  static func main() {
    _ = NSApplication.shared
    let configuration = BrowserWebViewConfiguration.make()
    if #available(macOS 12.3, *) {
      precondition(configuration.preferences.isElementFullscreenEnabled)
    }
    // Enabling fullscreen must not relax media or app-bound-domain policy.
    let defaults = WKWebViewConfiguration()
    precondition(configuration.mediaTypesRequiringUserActionForPlayback ==
      defaults.mediaTypesRequiringUserActionForPlayback)
    precondition(configuration.limitsNavigationsToAppBoundDomains ==
      defaults.limitsNavigationsToAppBoundDomains)
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
      configuration: configuration)
    precondition(view.configuration.preferences === configuration.preferences)
    let probe = CapabilityProbe()
    view.navigationDelegate = probe
    view.loadHTMLString("""
      <!doctype html><html><body>
      <iframe id="allowed" allow="fullscreen" srcdoc="<p>Allowed</p>"></iframe>
      <iframe id="denied" allow="fullscreen 'none'" srcdoc="<p>Denied</p>"></iframe>
      </body></html>
      """, baseURL: URL(string: "https://example.org/"))
    let deadline = Date().addingTimeInterval(20)
    while !probe.done && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    precondition(probe.done, "WebKit capability probe timed out")
    print("PASS: native fullscreen configuration, browser API, iframe denial and unchanged media/domain policy")
  }
}

final class CapabilityProbe: NSObject, WKNavigationDelegate {
  var done = false
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.evaluateJavaScript("""
      ({enabled:document.fullscreenEnabled,
        allowed:document.querySelector('#allowed').contentDocument.fullscreenEnabled,
        denied:document.querySelector('#denied').contentDocument.fullscreenEnabled})
      """) { result, error in
        precondition(error == nil, "Capability evaluation failed")
        guard let values = result as? [String: Bool] else {
          preconditionFailure("Unexpected capability result")
        }
        if #available(macOS 12.3, *) {
          precondition(values["enabled"] == true)
          precondition(values["allowed"] == true)
        }
        precondition(values["denied"] == false, "Iframe policy must fail closed")
        self.done = true
    }
  }
}
