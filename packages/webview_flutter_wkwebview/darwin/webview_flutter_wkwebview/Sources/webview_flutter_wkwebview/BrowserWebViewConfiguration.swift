import WebKit

/// Generic browser capabilities for the repository-owned WebKit integration.
enum BrowserWebViewConfiguration {
  static func make() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    if #available(macOS 12.3, iOS 15.4, *) {
      // WebKit owns entry, Escape/exit and restoration of the native view hierarchy.
      // Keep standard user activation and iframe permissions checks in WebKit.
      configuration.preferences.isElementFullscreenEnabled = true
    }
    return configuration
  }
}
