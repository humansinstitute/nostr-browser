import Cocoa
import WebKit

// Run: swift tools/fips_bridge/wk_loopback_smoke.swift HTTPS_PAGE LOOPBACK_URL
final class Smoke: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  var web: WKWebView!
  var window: NSWindow!
  let target = CommandLine.arguments[2]
  func start() {
    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "result")
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    web.navigationDelegate = self
    window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web
    web.load(URLRequest(url: URL(string: CommandLine.arguments[1])!))
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("TIMEOUT"); exit(2) }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let url = String(data: try! JSONSerialization.data(withJSONObject: [target]), encoding: .utf8)!
    web.evaluateJavaScript("""
      (async () => {
        const url = \(url)[0];
        const result = {origin: location.origin, secureContext: isSecureContext};
        try { const r = await fetch(url, {headers: {Authorization: 'smoke'}}); result.page = {status:r.status, body:await r.text()}; } catch(e) {result.page = String(e);}
        try { result.worker = await new Promise((resolve,reject) => {
          const script = `onmessage = async e => { try { const r = await fetch(e.data, {headers:{Authorization:'smoke'}}); postMessage({status:r.status, body:await r.text()}); } catch(e) {postMessage(String(e));} };`;
          const worker = new Worker(URL.createObjectURL(new Blob([script], {type:'text/javascript'})));
          worker.onmessage = e => {resolve(e.data); worker.terminate();}; worker.onerror = reject; worker.postMessage(url);
        }); } catch(e) {result.worker = String(e);}
        webkit.messageHandlers.result.postMessage(JSON.stringify(result));
      })(); void 0;
    """) { _, error in if let error = error { print(error); exit(3) } }
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    print(message.body); exit(0)
  }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let smoke = Smoke()
smoke.start()
app.run()
