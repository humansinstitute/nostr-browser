import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DriveExport") {
      FlutterMethodChannel(name: "au.com.otherstuff.wingman/drive", binaryMessenger: registrar.messenger()).setMethodCallHandler { call, result in
        guard call.method == "open", let path = call.arguments as? String else { result(FlutterMethodNotImplemented); return }
        let url = URL(fileURLWithPath: path)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
          let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController else { result(FlutterError(code: "unavailable", message: "No export window", details: nil)); return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        controller.completionWithItemsHandler = { _, completed, _, error in
          if let error = error { result(FlutterError(code: "export_failed", message: error.localizedDescription, details: nil)) }
          else { result(["localSaved": true, "exportCompleted": completed]) }
        }
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(controller, animated: true)
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FipsRuntimeController") {
      FipsRuntimeController.register(with: registrar)
    }
  }
}
