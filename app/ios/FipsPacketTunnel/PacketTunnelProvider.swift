import NetworkExtension
import Security
import Network

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let worker = DispatchQueue(label: "com.wingman.fips.packet", qos: .userInitiated)
    private let diagnostics = DispatchQueue(label: "com.wingman.fips.diagnostics", qos: .utility)
    private let lifecycle = FipsPacketLifecycle()
    private var generation: Int { lifecycle.generation }
    private var active: Bool { lifecycle.active }
    private var outputSource: FipsOutputPump?
    private var timer: DispatchSourceTimer?
    private var startTimeout: DispatchSourceTimer?
    private var pathMonitors: [NWPathMonitor] = []
    private var initializedPaths = Set<Int>()
    private var pathDebounce: DispatchSourceTimer?
    private var startCompletion: ((Error?) -> Void)?

    private func decode(_ pointer: UnsafeMutablePointer<CChar>?) -> [String: Any] {
        guard let pointer else { return ["state": "failed"] }
        defer { wm_fips_string_free(pointer) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))) as? [String: Any] ?? ["state": "failed"]
    }
    private func error(_ code: Int) -> NSError {
        NSError(domain: "com.wingman.fips", code: code, userInfo: [NSLocalizedDescriptionKey: "FIPS VPN could not start. Open Setup to retry."])
    }
    // No access group: only the extension can retrieve this node key. It is
    // unrelated to WMAPP's user signer and remains available after screen lock.
    private func nodeKey() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.wingman.fips.node.v1", kSecAttrAccount as String: "node"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let bytes = item as? Data, bytes.count == 32 { return bytes }
        guard status == errSecItemNotFound else { throw error(10) }
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw error(11) }
        var insert = query
        insert[kSecValueData as String] = bytes
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { bytes.resetBytes(in: 0..<bytes.count); throw error(12) }
        return bytes
    }
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        worker.async { self.start(completionHandler) }
    }
    private func start(_ completionHandler: @escaping (Error?) -> Void) {
        guard self.startCompletion == nil, let generation = lifecycle.begin() else { completionHandler(self.error(1)); return }
        self.startCompletion = completionHandler
        do {
            var key = try self.nodeKey()
            defer { key.resetBytes(in: 0..<key.count) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fips", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let status = key.withUnsafeBytes { key in
                directory.path.withCString { self.decode(wm_fips_start(key.bindMemory(to: UInt8.self).baseAddress!, $0)) }
            }
            guard status["state"] as? String == "running", let ipv6 = status["ipv6"] as? String else { throw self.error(2) }
            let settings = FipsTunnelSettings.make(ipv6: ipv6)
            self.setTunnelNetworkSettings(settings) { error in
                self.worker.async {
                    guard self.generation == generation else { return }
                    if let error { self.finishStart(error); return }
                    guard self.lifecycle.activate(generation) else { return }
                    guard self.startDrain(generation) else { self.finishStart(self.error(6)); return }
                    self.readPackets(generation)
                    self.monitorPath()
                    self.finishStart(nil)
                }
            }
            let timeout = DispatchSource.makeTimerSource(queue: self.worker)
            timeout.schedule(deadline: .now() + 20)
            timeout.setEventHandler { [weak self] in
                guard let self else { return }
                guard self.generation == generation, self.startCompletion != nil else { return }
                self.finishStart(self.error(3))
            }
            self.startTimeout = timeout; timeout.resume()
        } catch { self.finishStart(error) }
    }
    private func finishStart(_ error: Error?) {
        startTimeout?.cancel(); startTimeout = nil
        if error != nil {
            teardown()
        }
        let completion = startCompletion; startCompletion = nil
        completion?(error)
    }
    private func readPackets(_ generation: Int) {
        guard lifecycle.registerRead(generation) else { return }
        packetFlow.readPackets { packets, protocols in
            // Bound the single queued callback before crossing to the worker;
            // never retain an arbitrarily large OS batch while startup is busy.
            let batch = zip(packets.prefix(64), protocols.prefix(64)).compactMap { packet, proto -> Data? in
                guard !packet.isEmpty, packet.count <= 1280,
                    (packet[0] >> 4 == 4 && proto.int32Value == AF_INET) ||
                    (packet[0] >> 4 == 6 && proto.int32Value == AF_INET6) else { return nil }
                return packet
            }
            self.worker.async {
                guard self.lifecycle.completeRead(generation) else { self.readPackets(self.generation); return }
                for packet in batch {
                    let result = packet.withUnsafeBytes { wm_fips_input($0.bindMemory(to: UInt8.self).baseAddress, packet.count) }
                    if result == -2 { self.failRuntime(); return }
                    // Malformed packets (-1) and bounded queue loss (1) drop.
                }
                self.readPackets(generation)
            }
        }
    }
    private func startDrain(_ generation: Int) -> Bool {
        let descriptor = wm_fips_output_descriptor()
        guard descriptor >= 0 else { return false }
        outputSource = FipsOutputPump(descriptor: descriptor, queue: worker,
            accepts: { [weak self] in self?.lifecycle.accepts(generation) == true },
            read: { wm_fips_output($0, $1) },
            write: { [weak self] packets in
                guard let self else { return false }
                return self.packetFlow.writePackets(packets, withProtocols: packets.map {
                    NSNumber(value: $0[0] >> 4 == 6 ? AF_INET6 : AF_INET)
                })
            }, failed: { [weak self] in self?.failRuntime() })
        let health = DispatchSource.makeTimerSource(queue: worker)
        health.schedule(deadline: .now() + 5, repeating: .seconds(5), leeway: .seconds(1))
        health.setEventHandler { [weak self] in
            guard let self, self.lifecycle.accepts(generation) else { return }
            if self.decode(wm_fips_status())["state"] as? String != "running" { self.failRuntime() }
        }
        timer = health; health.resume()
        return true
    }
    private func teardown() {
        lifecycle.stop()
        startTimeout?.cancel(); startTimeout = nil
        outputSource?.cancel(); outputSource = nil
        timer?.cancel(); timer = nil
        pathDebounce?.cancel(); pathDebounce = nil
        pathMonitors.forEach { $0.cancel() }; pathMonitors.removeAll()
        initializedPaths.removeAll()
        reasserting = false
        _ = decode(wm_fips_stop())
    }
    private func failRuntime() {
        teardown()
        let pending = startCompletion; startCompletion = nil
        pending?(error(5))
        cancelTunnelWithError(error(5))
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        worker.async {
            self.teardown()
            let pending = self.startCompletion; self.startCompletion = nil
            pending?(self.error(4))
            completionHandler()
        }
    }
    private func monitorPath() {
        guard pathMonitors.isEmpty else { return }
        let generation = self.generation
        // Physical Wi-Fi can change while the general VPN path stays satisfied.
        let monitors = [NWPathMonitor(), NWPathMonitor(requiredInterfaceType: .wifi)]
        for (index, monitor) in monitors.enumerated() {
            monitor.pathUpdateHandler = { [weak self] _ in
                guard let self, self.lifecycle.accepts(generation) else { return }
                guard !self.initializedPaths.insert(index).inserted else { return }
                self.reasserting = true
                // Reschedule ONE timer for every update, including same-interface
                // changes. No signature ABA race or unbounded delayed work items.
                if let debounce = self.pathDebounce { debounce.schedule(deadline: .now() + 1); return }
                let debounce = DispatchSource.makeTimerSource(queue: self.worker)
                debounce.schedule(deadline: .now() + 1)
                debounce.setEventHandler { [weak self] in
                    guard let self, self.lifecycle.accepts(generation) else { return }
                    self.teardown()
                    self.reasserting = true
                    // Stay on this worker: a queued stop cannot be overtaken by
                    // a restart enqueued from a previous generation.
                    self.start { error in
                        self.reasserting = false
                        if let error { self.cancelTunnelWithError(error) }
                    }
                }
                self.pathDebounce = debounce; debounce.resume()
            }
            monitor.start(queue: worker)
        }
        pathMonitors = monitors
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Commands are fixed and contain no key/configuration access. Keep
        // diagnostics off the packet worker so a probe cannot pause packet I/O.
        diagnostics.async {
            guard messageData.count <= 512 else { completionHandler?(nil); return }
            let command: String?
            let npub: String?
            if let text = String(data: messageData, encoding: .utf8),
                text == "inspect" || text == "peerStatus" {
                command = text
                npub = nil
            } else if let value = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any] {
                command = value["command"] as? String
                npub = value["npub"] as? String
            } else {
                command = nil
                npub = nil
            }
            let result: [String: Any]
            switch command {
            case "inspect": result = self.decode(wm_fips_status())
            case "peerStatus": result = self.decode(wm_fips_peers())
            case "probe":
                guard let npub, npub.count == 63, npub.hasPrefix("npub1") else {
                    result = ["ok": false, "detail": "Invalid FIPS node npub."]
                    break
                }
                result = npub.withCString { self.decode(wm_fips_probe($0)) }
            default: result = ["state": "failed", "detail": "Unsupported FIPS diagnostic command."]
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: result))
        }
    }
}
