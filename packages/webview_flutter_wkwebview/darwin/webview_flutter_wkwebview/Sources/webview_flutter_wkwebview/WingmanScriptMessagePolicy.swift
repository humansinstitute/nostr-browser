import WebKit

/// Restrict WMapp's privileged channels using native frame metadata. Other
/// plugin clients keep their existing channel behavior.
enum WingmanScriptMessagePolicy {
  static func accepts(_ message: WKScriptMessage) -> Bool {
    guard message.name == "WingmanTower" || message.name == "WingmanSigner" || message.name == "WingmanGrasp" else {
      return true
    }
    guard message.frameInfo.isMainFrame,
      let currentURL = message.webView?.url,
      let frameURL = message.frameInfo.request.url else { return false }
    if message.name == "WingmanGrasp" {
      let origin = message.frameInfo.securityOrigin
      let bundled = origin.protocol == "http" && origin.host == "127.0.0.1" && origin.port == 47831
      let defaultPort = origin.protocol == "https" ? 443 : 80
      guard (origin.protocol == "https" || bundled), origin.host == currentURL.host,
        (origin.port == 0 ? defaultPort : origin.port) == (currentURL.port ?? defaultPort) else { return false }
    }
    return currentURL.scheme == frameURL.scheme
      && currentURL.host == frameURL.host && currentURL.port == frameURL.port
  }
}
