#if os(macOS)
import Cocoa
#else
import UIKit
#endif
import WebKit
// Separate stock WKWebView process with ephemeral storage; never touches WMapp's
// profile/keychain. The Dart harness consent callback is test-controlled.
#if os(macOS)
let app = NSApplication.shared
#endif
let rpc = CommandLine.arguments[1]
let page = CommandLine.arguments[2]
let tests = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
class Probe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  var view: WKWebView!
  var rejectedFrames = 0
  var injected = false
  var negativeViews: [WKWebView] = []
  var rejectedMainOrigins = 0
  func checkNegativeOrigins() {
    for origin in ["http://example.invalid", "data:text/html,opaque"] {
      let c = WKWebViewConfiguration()
      c.websiteDataStore = .nonPersistent()
      c.userContentController.add(self, name: "WingmanGrasp")
      let negative = WKWebView(frame: .zero, configuration: c)
      negativeViews.append(negative)
      negative.loadHTMLString("<script>window.webkit.messageHandlers.WingmanGrasp.postMessage('negative-main-origin')</script>", baseURL: URL(string: origin))
    }
  }
  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    if negativeViews.contains(where: { $0 === m.webView }) {
      guard m.frameInfo.isMainFrame && !WingmanScriptMessagePolicy.accepts(m) else {
        print("FAIL native policy accepted insecure/opaque main origin"); exit(1)
      }
      print("Native rejected main frame security origin scheme: \(m.frameInfo.securityOrigin.protocol)")
      rejectedMainOrigins += 1
      if rejectedMainOrigins == 2 { view.load(URLRequest(url: URL(string: page)!)) }
      return
    }
    if m.name == "Result" {
      let result=String(describing:m.body)
      print(result); print("Native rejected subframe messages: \(rejectedFrames); insecure/opaque main origins: \(rejectedMainOrigins)")
      fflush(stdout)
#if os(macOS)
      if CommandLine.arguments.count > 4 {
        view.takeSnapshot(with:nil) { image,error in
          if let image=image, let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) {
            try? png.write(to:URL(fileURLWithPath:CommandLine.arguments[4]))
          }
          exit(result.hasPrefix("PASS") && self.rejectedFrames > 0 ? 0:1)
        }
      } else { exit(result.hasPrefix("PASS") && rejectedFrames > 0 ? 0:1) }
#else
      exit(result.hasPrefix("PASS") && rejectedFrames > 0 && rejectedMainOrigins == 2 ? 0:1)
#endif
#if os(macOS)
      return
#endif
    }
    guard WingmanScriptMessagePolicy.accepts(m) else { rejectedFrames += 1; return }
    var request=URLRequest(url:URL(string:rpc+"/rpc")!)
    request.httpMethod="POST";request.httpBody=String(describing:m.body).data(using:.utf8)
    URLSession.shared.dataTask(with:request) { data,_,error in
      guard let data=data, let script=String(data:data,encoding:.utf8), error==nil else { return }
      DispatchQueue.main.async { self.view.evaluateJavaScript(script) }
    }.resume()
  }
  func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
    if injected { return }; injected=true
    URLSession.shared.dataTask(with:URL(string:rpc+"/script")!) { data,_,_ in
      guard let data=data, let script=String(data:data,encoding:.utf8) else { return }
      DispatchQueue.main.async {
        webView.evaluateJavaScript("window.WingmanGrasp={postMessage:s=>window.webkit.messageHandlers.WingmanGrasp.postMessage(s)};"+script) { _,error in
          if let error=error { print("FAIL injection \(error)");exit(1) }
          webView.evaluateJavaScript(tests+";void 0;") { _,error in
            if let error=error {print("FAIL tests \(error)");exit(1)}
          }
        }
      }
    }.resume()
  }
  func start() {
    let c=WKWebViewConfiguration();c.websiteDataStore = .nonPersistent()
    c.userContentController.add(self,name:"WingmanGrasp");c.userContentController.add(self,name:"Result")
    view=WKWebView(frame:CGRect(x:0,y:0,width:1300,height:900),configuration:c);view.navigationDelegate=self
    checkNegativeOrigins()
  }
}
#if os(macOS)
let p=Probe();p.start()
DispatchQueue.main.asyncAfter(deadline:.now()+55){print("FAIL TIMEOUT");exit(2)}
app.run()
#else
class ProbeAppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  let probe = Probe()
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    let controller = UIViewController()
    window.rootViewController = controller
    self.window = window
    window.makeKeyAndVisible()
    probe.start()
    controller.view.addSubview(probe.view)
    probe.view.frame = controller.view.bounds
    DispatchQueue.main.asyncAfter(deadline:.now()+55){print("FAIL TIMEOUT");exit(2)}
    return true
  }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ProbeAppDelegate.self))
#endif
