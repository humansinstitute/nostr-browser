// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import WebKit

/// Implementation of `WKNavigationDelegate` that calls to Dart in callback methods.
public class NavigationDelegateImpl: NSObject, WKNavigationDelegate {
  let api: PigeonApiProtocolWKNavigationDelegate
  unowned let registrar: ProxyAPIRegistrar
  private var authenticationHeadersByURL: [String: [String: String]] = [:]

  private func authenticationHeaders(for request: URLRequest) -> [String: String] {
    guard let value = request.value(forHTTPHeaderField: "Authorization"), !value.isEmpty else {
      return [:]
    }
    return ["authorization": value]
  }

  private func isDirectDownloadURL(_ url: URL?) -> Bool {
    guard let url, url.scheme == "http" || url.scheme == "https" else { return false }
    let extensions: Set<String> = [
      "7z", "apk", "avi", "bin", "bz2", "csv", "doc", "docx", "dmg", "epub", "gz",
      "ics", "iso", "json", "m4a", "mkv", "mov", "mp3", "mp4", "odp", "ods", "odt",
      "pdf", "pkg", "ppt", "pptx", "rar", "rtf", "tar", "tgz", "txt", "wav", "webm",
      "xls", "xlsx", "xml", "xz", "zip",
    ]
    return extensions.contains(url.pathExtension.lowercased())
  }

  private func authenticationHeaders(for responseURL: URL?) -> [String: String] {
    guard let responseURL else { return [:] }
    func effectivePort(_ url: URL) -> Int? {
      url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
    let match = authenticationHeadersByURL.first { rawURL, _ in
      guard let requestURL = URL(string: rawURL) else { return false }
      return requestURL.scheme?.lowercased() == responseURL.scheme?.lowercased()
        && requestURL.host?.lowercased() == responseURL.host?.lowercased()
        && effectivePort(requestURL) == effectivePort(responseURL)
    }
    guard let match else { return [:] }
    authenticationHeadersByURL.removeValue(forKey: match.key)
    return match.value
  }

  init(api: PigeonApiProtocolWKNavigationDelegate, registrar: ProxyAPIRegistrar) {
    self.api = api
    self.registrar = registrar
  }

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    registrar.dispatchOnMainThread { onFailure in
      self.api.didFinishNavigation(
        pigeonInstance: self, webView: webView, url: webView.url?.absoluteString
      ) { result in
        if case .failure(let error) = result {
          onFailure("WKNavigationDelegate.didFinishNavigation", error)
        }
      }
    }
  }

  public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!)
  {
    registrar.dispatchOnMainThread { onFailure in
      self.api.didStartProvisionalNavigation(
        pigeonInstance: self, webView: webView, url: webView.url?.absoluteString
      ) { result in
        if case .failure(let error) = result {
          onFailure("WKNavigationDelegate.didStartProvisionalNavigation", error)
        }
      }
    }
  }

  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    registrar.dispatchOnMainThread { onFailure in
      self.api.didFailNavigation(pigeonInstance: self, webView: webView, error: error as NSError) {
        result in
        if case .failure(let error) = result {
          onFailure("WKNavigationDelegate.didFailNavigation", error)
        }
      }
    }
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    registrar.dispatchOnMainThread { onFailure in
      self.api.didFailProvisionalNavigation(
        pigeonInstance: self, webView: webView, error: error as NSError
      ) { result in
        if case .failure(let error) = result {
          onFailure("WKNavigationDelegate.didFailProvisionalNavigation", error)
        }
      }
    }
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    registrar.dispatchOnMainThread { onFailure in
      self.api.webViewWebContentProcessDidTerminate(pigeonInstance: self, webView: webView) {
        result in
        if case .failure(let error) = result {
          onFailure("WKNavigationDelegate.webViewWebContentProcessDidTerminate", error)
        }
      }
    }
  }

  #if compiler(>=6.0)
    public func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WebKit.WKNavigationAction,
      decisionHandler: @escaping @MainActor (WebKit.WKNavigationActionPolicy) -> Void
    ) {
      let headers = authenticationHeaders(for: navigationAction.request)
      if let url = navigationAction.request.url, !headers.isEmpty {
        authenticationHeadersByURL[url.absoluteString] = headers
      }
      var shouldDownload = isDirectDownloadURL(navigationAction.request.url)
      if #available(iOS 14.5, macOS 11.3, *) {
        shouldDownload = shouldDownload || navigationAction.shouldPerformDownload
      }
      if let bridge = BrowserDownloadBridge.shared, shouldDownload {
        bridge.request(
          url: navigationAction.request.url,
          signal: isDirectDownloadURL(navigationAction.request.url) ? "directLink" : "htmlDownload",
          suggestedFilename: navigationAction.request.url?.lastPathComponent,
          contentDisposition: nil, mimeType: nil, headers: headers
        ) { accepted in
          DispatchQueue.main.async { decisionHandler(accepted ? .cancel : .allow) }
        }
        return
      }
      registrar.dispatchOnMainThread { onFailure in
        self.api.decidePolicyForNavigationAction(
          pigeonInstance: self, webView: webView, navigationAction: navigationAction
        ) { result in
          DispatchQueue.main.async {
            switch result {
            case .success(let policy):
              switch policy {
              case .allow:
                decisionHandler(.allow)
              case .cancel:
                decisionHandler(.cancel)
              case .download:
                if #available(iOS 14.5, macOS 11.3, *) {
                  decisionHandler(.download)
                } else {
                  decisionHandler(.cancel)
                  assertionFailure(
                    self.registrar.createUnsupportedVersionMessage(
                      "WKNavigationActionPolicy.download",
                      versionRequirements: "iOS 14.5, macOS 11.3"
                    ))
                }
              }
            case .failure(let error):
              decisionHandler(.cancel)
              onFailure("WKNavigationDelegate.decidePolicyForNavigationAction", error)
            }
          }
        }
      }
    }
  #else
    public func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      let headers = authenticationHeaders(for: navigationAction.request)
      if let url = navigationAction.request.url, !headers.isEmpty {
        authenticationHeadersByURL[url.absoluteString] = headers
      }
      var shouldDownload = isDirectDownloadURL(navigationAction.request.url)
      if #available(iOS 14.5, macOS 11.3, *) {
        shouldDownload = shouldDownload || navigationAction.shouldPerformDownload
      }
      if let bridge = BrowserDownloadBridge.shared, shouldDownload {
        bridge.request(
          url: navigationAction.request.url,
          signal: isDirectDownloadURL(navigationAction.request.url) ? "directLink" : "htmlDownload",
          suggestedFilename: navigationAction.request.url?.lastPathComponent,
          contentDisposition: nil, mimeType: nil, headers: headers
        ) { accepted in
          DispatchQueue.main.async { decisionHandler(accepted ? .cancel : .allow) }
        }
        return
      }
      registrar.dispatchOnMainThread { onFailure in
        self.api.decidePolicyForNavigationAction(
          pigeonInstance: self, webView: webView, navigationAction: navigationAction
        ) { result in
          DispatchQueue.main.async {
            switch result {
            case .success(let policy):
              switch policy {
              case .allow:
                decisionHandler(.allow)
              case .cancel:
                decisionHandler(.cancel)
              case .download:
                if #available(iOS 14.5, macOS 11.3, *) {
                  decisionHandler(.download)
                } else {
                  decisionHandler(.cancel)
                  assertionFailure(
                    self.registrar.createUnsupportedVersionMessage(
                      "WKNavigationActionPolicy.download",
                      versionRequirements: "iOS 14.5, macOS 11.3"
                    ))
                }
              }
            case .failure(let error):
              decisionHandler(.cancel)
              onFailure("WKNavigationDelegate.decidePolicyForNavigationAction", error)
            }
          }
        }
      }
    }
  #endif

  #if compiler(>=6.0)
    public func webView(
      _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
      decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
      if let bridge = BrowserDownloadBridge.shared,
        let response = navigationResponse.response as? HTTPURLResponse
      {
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")
        let attachment = disposition?.split(separator: ";", maxSplits: 1).first?
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
        let headers = authenticationHeaders(for: response.url)
        if attachment || !navigationResponse.canShowMIMEType {
          bridge.request(
            url: response.url, signal: "response", suggestedFilename: response.suggestedFilename,
            contentDisposition: disposition, mimeType: response.mimeType, headers: headers
          ) { accepted in
            DispatchQueue.main.async { decisionHandler(accepted ? .cancel : .allow) }
          }
          return
        }
      }
      registrar.dispatchOnMainThread { onFailure in
        self.api.decidePolicyForNavigationResponse(
          pigeonInstance: self, webView: webView, navigationResponse: navigationResponse
        ) { result in
          DispatchQueue.main.async {
            switch result {
            case .success(let policy):
              switch policy {
              case .allow:
                decisionHandler(.allow)
              case .cancel:
                decisionHandler(.cancel)
              case .download:
                if #available(iOS 14.5, macOS 11.3, *) {
                  decisionHandler(.download)
                } else {
                  decisionHandler(.cancel)
                  assertionFailure(
                    self.registrar.createUnsupportedVersionMessage(
                      "WKNavigationResponsePolicy.download",
                      versionRequirements: "iOS 14.5, macOS 11.3"
                    ))
                }
              }
            case .failure(let error):
              decisionHandler(.cancel)
              onFailure("WKNavigationDelegate.decidePolicyForNavigationResponse", error)
            }
          }
        }
      }
    }
  #else
    public func webView(
      _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
      decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
      if let bridge = BrowserDownloadBridge.shared,
        let response = navigationResponse.response as? HTTPURLResponse
      {
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")
        let attachment = disposition?.split(separator: ";", maxSplits: 1).first?
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
        let headers = authenticationHeaders(for: response.url)
        if attachment || !navigationResponse.canShowMIMEType {
          bridge.request(
            url: response.url, signal: "response", suggestedFilename: response.suggestedFilename,
            contentDisposition: disposition, mimeType: response.mimeType, headers: headers
          ) { accepted in
            DispatchQueue.main.async { decisionHandler(accepted ? .cancel : .allow) }
          }
          return
        }
      }
      registrar.dispatchOnMainThread { onFailure in
        self.api.decidePolicyForNavigationResponse(
          pigeonInstance: self, webView: webView, navigationResponse: navigationResponse
        ) { result in
          DispatchQueue.main.async {
            switch result {
            case .success(let policy):
              switch policy {
              case .allow:
                decisionHandler(.allow)
              case .cancel:
                decisionHandler(.cancel)
              case .download:
                if #available(iOS 14.5, macOS 11.3, *) {
                  decisionHandler(.download)
                } else {
                  decisionHandler(.cancel)
                  assertionFailure(
                    self.registrar.createUnsupportedVersionMessage(
                      "WKNavigationResponsePolicy.download",
                      versionRequirements: "iOS 14.5, macOS 11.3"
                    ))
                }
              }
            case .failure(let error):
              decisionHandler(.cancel)
              onFailure("WKNavigationDelegate.decidePolicyForNavigationResponse", error)
            }
          }
        }
      }
    }
  #endif

  #if compiler(>=6.0)
    public func webView(
      _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?)
        ->
        Void
    ) {
      registrar.dispatchOnMainThread { onFailure in
        self.api.didReceiveAuthenticationChallenge(
          pigeonInstance: self, webView: webView, challenge: challenge
        ) { result in
          DispatchQueue.main.async {
            switch result {
            case .success(let response):
              completionHandler(response.disposition, response.credential)
            case .failure(let error):
              completionHandler(.cancelAuthenticationChallenge, nil)
              onFailure("WKNavigationDelegate.didReceiveAuthenticationChallenge", error)
            }
          }
        }
      }
    }
  #else
    public func webView(
      _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping (URLSession.AuthChallengeDisposition, URLCredential?) ->
        Void
    ) {
      registrar.dispatchOnMainThread { onFailure in
        self.api.didReceiveAuthenticationChallenge(
          pigeonInstance: self, webView: webView, challenge: challenge
        ) { result in
          DispatchQueue.main.async {
            switch result {
            case .success(let response):
              completionHandler(response.disposition, response.credential)
            case .failure(let error):
              completionHandler(.cancelAuthenticationChallenge, nil)
              onFailure("WKNavigationDelegate.didReceiveAuthenticationChallenge", error)
            }
          }
        }
      }
    }
  #endif
}
/// ProxyApi implementation for `WKNavigationDelegate`.
///
/// This class may handle instantiating native object instances that are attached to a Dart instance
/// or handle method calls on the associated native class or an instance of that class.
class NavigationDelegateProxyAPIDelegate: PigeonApiDelegateWKNavigationDelegate {
  func pigeonDefaultConstructor(pigeonApi: PigeonApiWKNavigationDelegate) throws
    -> WKNavigationDelegate
  {
    return NavigationDelegateImpl(
      api: pigeonApi, registrar: pigeonApi.pigeonRegistrar as! ProxyAPIRegistrar)
  }
}
