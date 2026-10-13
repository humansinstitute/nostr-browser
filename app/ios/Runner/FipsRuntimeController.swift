import Flutter
import NetworkExtension
import UniformTypeIdentifiers
import UIKit

final class FipsRuntimeController: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
    private static let providerID = "com.wingmanbefree.wingmanApp.FipsPacketTunnel"
    private var manager: NETunnelProviderManager?
    private var operation: FlutterResult?
    private var operationID = UUID()
    private var observer: NSObjectProtocol?
    private var exportResult: FlutterResult?
    private var exportURL: URL?
    private var events: [[String: String]] = []
    private var lastFailure: String?

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FipsRuntimeController()
        let channel = FlutterMethodChannel(name: "com.wingmanbefree.wingman_app/fips", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.statusChanged()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func value(_ state: String, _ detail: String) -> [String: Any] { ["state": state, "detail": detail] }
    private func record(_ code: String) {
        events.append(["time": ISO8601DateFormatter().string(from: Date()), "event": code])
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
    private func loaded(_ completion: @escaping (Error?) -> Void) {
        let id = operationID
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                guard self.operationID == id else {
                    completion(NSError(domain: "com.wingman.fips.cancelled", code: 1)); return
                }
                self.manager = managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID }
                completion(error)
            }
        }
    }
    private func currentStatus() -> [String: Any] {
        guard let manager else { return value("consentRequired", "Enable FIPS to request iPhone VPN consent.") }
        switch manager.connection.status {
        case .connected: return value("running", "FIPS VPN is connected.")
        case .connecting, .reasserting: return value("starting", "FIPS VPN is connecting or reconnecting.")
        case .disconnecting: return value("starting", "FIPS VPN is stopping.")
        default:
            if let lastFailure { return value("failed", lastFailure) }
            return value("notInstalled", "FIPS VPN is stopped. Enable it to connect.")
        }
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Flutter invokes plugins on main; all NetworkExtension APIs here are async.
        switch call.method {
        case "inspect":
            guard operation == nil else { result(value("starting", "FIPS VPN is changing state.")); return }
            loaded { error in
                if error != nil { result(self.value("failed", "iPhone VPN settings could not be read.")); return }
                if self.manager?.connection.status == .connected { self.message("inspect", result: result) }
                else { result(self.currentStatus()) }
            }
        case "start", "repair": beginStart(repair: call.method == "repair", result: result)
        case "stop":
            operationID = UUID(); let id = operationID
            let pending = operation; operation = result
            pending?(value("failed", "FIPS startup was cancelled."))
            loaded { error in
                guard self.operationID == id else { return }
                guard error == nil else { self.finishStop(self.value("failed", "iPhone VPN settings could not be read.")); return }
                self.manager?.connection.stopVPNTunnel()
                self.lastFailure = nil; self.record("stop_requested")
                self.waitForStop(id, attempt: 0)
            }
        case "peerStatus": message("peerStatus", result: result)
        case "probe":
            let npub = (call.arguments as? [String: Any])?["npub"] as? String ?? ""
            guard npub.count == 63, npub.hasPrefix("npub1"),
                let payload = try? JSONSerialization.data(withJSONObject: ["command": "probe", "npub": npub]),
                payload.count <= 512 else {
                result(["ok": false, "detail": "Invalid FIPS node npub."]); return
            }
            message(payload, disconnected: ["ok": false, "detail": "FIPS VPN is not connected."],
                failure: ["ok": false, "detail": "FIPS probe failed. Please retry."],
                timeout: 18, result: result)
        case "journalEvent":
            let code = (call.arguments as? [String: Any])?["eventCode"] as? String ?? ""
            if ["dart_ui_retry", "dart_export_requested", "dart_export_failed", "dart_inspect_failed", "dart_start_failed"].contains(code) { record(code) }
            result(["ok": true])
        case "clearDiagnostics": events.removeAll(); result(["detail": "FIPS diagnostics cleared."])
        case "exportDiagnostics": exportDiagnostics(result)
        default: result(FlutterMethodNotImplemented)
        }
    }
    private func beginStart(repair: Bool, result: @escaping FlutterResult) {
        guard operation == nil else { result(value("starting", "FIPS startup is already in progress.")); return }
        operation = result; operationID = UUID(); let id = operationID
        lastFailure = nil
        loaded { error in
            guard self.operationID == id, self.operation != nil else { return }
            guard error == nil else { self.finish(self.value("failed", "iPhone VPN settings could not be read.")); return }
            if self.manager?.connection.status == .connected, !repair {
                self.message("inspect") { response in
                    guard self.operationID == id, self.operation != nil else { return }
                    self.finish(response as? [String: Any] ?? self.value("failed", "FIPS runtime did not respond."))
                }
                return
            }
            if let manager = self.manager, [.connected, .connecting, .reasserting, .disconnecting].contains(manager.connection.status) {
                manager.connection.stopVPNTunnel()
                self.restartWhenStopped(id, attempt: 0)
            } else { self.configureAndStart(id) }
        }
    }
    private func restartWhenStopped(_ id: UUID, attempt: Int) {
        guard operationID == id, operation != nil else { return }
        if manager?.connection.status == .disconnected || manager?.connection.status == .invalid { configureAndStart(id); return }
        guard attempt < 40 else { finish(value("failed", "The previous FIPS VPN did not stop. Retry from Setup.")); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.restartWhenStopped(id, attempt: attempt + 1) }
    }
    private func configureAndStart(_ id: UUID) {
        guard operationID == id, operation != nil else { return }
        let manager = self.manager ?? NETunnelProviderManager()
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = Self.providerID
        config.serverAddress = "FIPS mesh (PoC bootstrap)"
        config.disconnectOnSleep = false
        if #available(iOS 14.0, *) { config.includeAllNetworks = false }
        manager.protocolConfiguration = config
        manager.localizedDescription = "Nostr Browser FIPS"
        manager.isEnabled = true
        // Do not install on-demand rules or silently replace a third-party config.
        self.manager = manager
        record("consent_requested")
        manager.saveToPreferences { error in
            DispatchQueue.main.async {
                guard self.operationID == id, self.operation != nil else { return }
                if error != nil {
                    self.record("consent_or_save_failed")
                    self.finish(self.value("failed", "VPN consent was declined or iPhone could not save the FIPS VPN. Enable it again to retry.")); return
                }
                manager.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        guard self.operationID == id, self.operation != nil else { return }
                        guard error == nil else { self.finish(self.value("failed", "Saved VPN settings could not be loaded.")); return }
                        do {
                            try manager.connection.startVPNTunnel()
                            self.record("start_requested")
                            self.pollStart(id, attempt: 0)
                        } catch { self.finish(self.value("failed", "iPhone could not start FIPS. Check VPN settings and retry.")) }
                    }
                }
            }
        }
    }
    private func pollStart(_ id: UUID, attempt: Int) {
        guard operationID == id, operation != nil else { return }
        if manager?.connection.status == .connected {
            message("inspect") { response in
                guard self.operationID == id, self.operation != nil else { return }
                self.finish(response as? [String: Any] ?? self.value("failed", "FIPS runtime did not respond."))
            }; return
        }
        if attempt >= 120 {
            manager?.connection.stopVPNTunnel()
            finish(value("failed", "FIPS VPN startup timed out. Check the active VPN and retry.")); return
        }
        if attempt > 4, manager?.connection.status == .disconnected {
            finish(value("failed", "FIPS VPN stopped during startup. Check VPN settings and retry.")); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.pollStart(id, attempt: attempt + 1) }
    }
    private func finish(_ status: [String: Any]) {
        if status["state"] as? String == "failed" { lastFailure = status["detail"] as? String; record("start_failed") }
        else { record("connected") }
        let pending = operation; operation = nil; pending?(status)
    }
    private func statusChanged() { record("vpn_status_\(manager?.connection.status.rawValue ?? 0)") }
    private func finishStop(_ status: [String: Any]) {
        let pending = operation; operation = nil; pending?(status)
    }
    private func waitForStop(_ id: UUID, attempt: Int) {
        guard operationID == id, operation != nil else { return }
        if manager == nil || manager?.connection.status == .disconnected || manager?.connection.status == .invalid {
            finishStop(currentStatus()); return
        }
        guard attempt < 40 else { finishStop(value("failed", "FIPS VPN is still stopping. Retry shortly.")); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.waitForStop(id, attempt: attempt + 1) }
    }
    private func message(_ command: String, result: @escaping FlutterResult) {
        message(Data(command.utf8),
            disconnected: command == "peerStatus" ? ["connected": false] : currentStatus(),
            failure: value("failed", "FIPS diagnostics did not respond."),
            timeout: 3,
            result: result)
    }
    private func message(_ payload: Data, disconnected: [String: Any], failure: [String: Any], timeout: TimeInterval, result: @escaping FlutterResult) {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else {
            result(disconnected); return
        }
        var completed = false
        let finish: ([String: Any]) -> Void = { value in
            guard !completed else { return }; completed = true; result(value)
        }
        do {
            try session.sendProviderMessage(payload) { data in
                DispatchQueue.main.async {
                    guard let data, data.count <= 16_384,
                        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        finish(failure); return
                    }
                    finish(value)
                }
            }
        } catch { finish(failure) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(failure) }
    }
    private func exportDiagnostics(_ result: @escaping FlutterResult) {
        guard exportResult == nil else { result(["outcome": "failed", "detail": "An export is already open."]); return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var presenter = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
            result(["outcome": "failed", "detail": "Open Nostr Browser to export diagnostics."]); return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let safe: [String: Any] = ["schema": 1, "platform": "iOS", "coreVersion": "0.5.0",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "unknown",
            "vpnStatus": manager?.connection.status.rawValue ?? 0, "events": events,
            "privacy": "No keys, URLs, packet contents or user identity. Last 100 events from this app session only."]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wmapp-fips-diagnostics.json")
        do {
            try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true) }
            else { picker = UIDocumentPickerViewController(url: url, in: .exportToService) }
            picker.delegate = self; exportResult = result; exportURL = url
            presenter.present(picker, animated: true)
        } catch { result(["outcome": "failed", "detail": "Diagnostics export could not be created."]) }
    }
    private func finishExport(_ outcome: String) {
        if let url = exportURL { try? FileManager.default.removeItem(at: url) }; exportURL = nil
        let pending = exportResult; exportResult = nil
        pending?(["outcome": outcome, "detail": outcome == "success" ? "FIPS diagnostics exported." : "Diagnostics export cancelled."])
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishExport("cancelled") }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finishExport("success") }
}
