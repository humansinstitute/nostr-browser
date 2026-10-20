#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif
import WebKit

final class BrowserDownloadBridge: NSObject {
  static weak var shared: BrowserDownloadBridge?
  static let channelName = "wingman/browser_download"

  private let channel: FlutterMethodChannel
  private var exportResult: FlutterResult?
  private var exportURL: URL?
  private var exportFilename: String?

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "export" else { result(FlutterMethodNotImplemented); return }
      self?.export(call.arguments as? [String: Any], result: result)
    }
  }

  func request(
    url: URL?, signal: String, suggestedFilename: String?,
    contentDisposition: String?, mimeType: String?, headers: [String: String] = [:],
    completion: @escaping (Bool) -> Void
  ) {
    guard let url, url.scheme == "http" || url.scheme == "https" else {
      completion(false); return
    }
    var arguments: [String: Any] = [
      "url": url.absoluteString,
      "signal": signal,
      "headers": headers,
    ]
    if let suggestedFilename { arguments["suggestedFilename"] = suggestedFilename }
    if let contentDisposition { arguments["contentDisposition"] = contentDisposition }
    if let mimeType { arguments["mimeType"] = mimeType }
    channel.invokeMethod("request", arguments: arguments) { value in
      completion(value as? Bool == true)
    }
  }

  private func export(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard exportResult == nil,
      let path = arguments?["path"] as? String,
      let filename = arguments?["filename"] as? String,
      FileManager.default.fileExists(atPath: path)
    else {
      result(FlutterError(code: "export_unavailable", message: "A save flow is already open or the downloaded file is unavailable.", details: nil))
      return
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("wmapp-browser-download-\(UUID().uuidString)", isDirectory: true)
    let staged = directory.appendingPathComponent(filename)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: staged)
      exportResult = result; exportURL = staged; exportFilename = filename
      #if os(iOS)
        guard let presenter = Self.presenter() else {
          finishExport(outcome: "failed", detail: "Open the app to choose a Files destination.")
          return
        }
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
          picker = UIDocumentPickerViewController(forExporting: [staged], asCopy: true)
        } else {
          picker = UIDocumentPickerViewController(url: staged, in: .exportToService)
        }
        picker.delegate = self
        presenter.present(picker, animated: true)
      #elseif os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
          finishExport(outcome: "cancelled", detail: "Save cancelled."); return
        }
        do {
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.copyItem(at: staged, to: destination)
          finishExport(outcome: "success", detail: destination.path)
        } catch {
          finishExport(outcome: "failed", detail: "The selected file could not be saved.")
        }
      #endif
    } catch {
      try? FileManager.default.removeItem(at: directory)
      result(FlutterError(code: "export_failed", message: "The downloaded file could not be prepared for saving.", details: nil))
    }
  }

  private func finishExport(outcome: String, detail: String) {
    let pending = exportResult
    let staged = exportURL
    let filename = exportFilename
    exportResult = nil; exportURL = nil; exportFilename = nil
    if let directory = staged?.deletingLastPathComponent() {
      try? FileManager.default.removeItem(at: directory)
    }
    var response: [String: Any] = [
      "outcome": outcome,
      "detail": detail,
      "destination": outcome == "success" ? detail : "",
    ]
    if let filename { response["filename"] = filename }
    pending?(response)
  }

  func dispose() {
    channel.setMethodCallHandler(nil)
    if exportResult != nil { finishExport(outcome: "cancelled", detail: "Save cancelled.") }
  }
}

#if os(iOS)
  extension BrowserDownloadBridge: UIDocumentPickerDelegate {
    private static func presenter() -> UIViewController? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      guard var controller = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
        return nil
      }
      while let presented = controller.presentedViewController { controller = presented }
      return controller
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      finishExport(outcome: "cancelled", detail: "Save cancelled.")
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      let destination = urls.first?.path ?? "Files/\(exportFilename ?? "download")"
      finishExport(outcome: "success", detail: destination)
    }
  }
#endif
