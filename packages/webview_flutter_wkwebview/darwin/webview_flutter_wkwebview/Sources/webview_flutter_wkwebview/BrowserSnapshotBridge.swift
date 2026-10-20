#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif
import WebKit

/// Captures a small in-memory preview of an attached WKWebView for the tab
/// overview. Detached or hidden views report nil so callers use a fallback.
final class BrowserSnapshotBridge: NSObject {
  static let channelName = "wingman/browser_snapshot"
  private static let maxWidth = 640.0

  private let channel: FlutterMethodChannel
  private let lookup: (Int64) -> WKWebView?

  init(binaryMessenger: FlutterBinaryMessenger, lookup: @escaping (Int64) -> WKWebView?) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: binaryMessenger)
    self.lookup = lookup
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "capture" else { result(FlutterMethodNotImplemented); return }
      self?.capture(call.arguments as? [String: Any], result: result)
    }
  }

  private func capture(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard let identifier = (arguments?["webViewIdentifier"] as? NSNumber)?.int64Value,
      let webView = lookup(identifier), webView.window != nil, !webView.isHidden,
      webView.bounds.width > 0, webView.bounds.height > 0
    else {
      result(nil)
      return
    }
    let requested = (arguments?["width"] as? NSNumber)?.doubleValue ?? Self.maxWidth
    let configuration = WKSnapshotConfiguration()
    configuration.snapshotWidth = NSNumber(value: min(max(requested, 1), Self.maxWidth))
    webView.takeSnapshot(with: configuration) { image, _ in
      guard let image, let data = Self.jpeg(image) else { result(nil); return }
      result(FlutterStandardTypedData(bytes: data))
    }
  }

  #if os(iOS)
    private static func jpeg(_ image: UIImage) -> Data? {
      image.jpegData(compressionQuality: 0.7)
    }
  #elseif os(macOS)
    private static func jpeg(_ image: NSImage) -> Data? {
      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
        return nil
      }
      return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
  #endif

  func dispose() {
    channel.setMethodCallHandler(nil)
  }
}
