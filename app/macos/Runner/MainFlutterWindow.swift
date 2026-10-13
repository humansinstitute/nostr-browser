import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let menuChannelName = "au.com.otherstuff.wingman/menu"
  private static let showWingmanMenuMethod = "showWingmanMenu"
  private var menuChannel: FlutterMethodChannel?
  private var driveChannel: FlutterMethodChannel?
  private var driveRoots: [URL] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    menuChannel = FlutterMethodChannel(
      name: Self.menuChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    driveChannel = FlutterMethodChannel(name: "au.com.otherstuff.wingman/drive", binaryMessenger: flutterViewController.engine.binaryMessenger)
    driveChannel?.setMethodCallHandler { [weak self] call, result in
      do {
        if call.method == "pick" {
          let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
          panel.prompt = "Share folder"
          guard panel.runModal() == .OK, let url = panel.url else { result(nil); return }
          _ = url.startAccessingSecurityScopedResource(); self?.driveRoots.append(url)
          let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
          result(["path": url.path, "bookmark": data.base64EncodedString()])
        } else if call.method == "restore", let raw = call.arguments as? String, let data = Data(base64Encoded: raw) {
          var stale = false
          let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
          guard !stale else { result(FlutterError(code: "folder_access_expired", message: "Select the folder again", details: nil)); return }
          _ = url.startAccessingSecurityScopedResource(); self?.driveRoots.append(url); result(url.path)
        } else if call.method == "open", let path = call.arguments as? String {
          NSWorkspace.shared.open(URL(fileURLWithPath: path)); result(nil)
        } else if call.method == "release" {
          self?.driveRoots.forEach { $0.stopAccessingSecurityScopedResource() }; self?.driveRoots.removeAll(); result(nil)
        } else { result(FlutterMethodNotImplemented) }
      } catch { result(FlutterError(code: "folder_access_failed", message: "Folder access unavailable", details: nil)) }
    }
    super.awakeFromNib()
  }

  @IBAction func showWingmanMenu(_ sender: Any?) {
    menuChannel?.invokeMethod(Self.showWingmanMenuMethod, arguments: nil)
  }
}
