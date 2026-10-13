import Foundation

// Access only on the provider's serial worker. The outstanding NE read belongs
// to the packetFlow, not a runtime generation: never reset it on stop/restart.
final class FipsPacketLifecycle {
    private(set) var generation = 0
    private(set) var active = false
    private var starting = false
    private var readOutstanding = false
    func begin() -> Int? {
        guard !active, !starting else { return nil }
        generation += 1; starting = true
        return generation
    }
    func activate(_ token: Int) -> Bool {
        guard generation == token, starting else { return false }
        starting = false; active = true; return true
    }
    func stop() { generation += 1; starting = false; active = false }
    func accepts(_ token: Int) -> Bool { active && token == generation }
    func registerRead(_ token: Int) -> Bool {
        guard accepts(token), !readOutstanding else { return false }
        readOutstanding = true; return true
    }
    func completeRead(_ token: Int) -> Bool {
        readOutstanding = false
        return accepts(token)
    }
}

// Owns one duplicated descriptor. Dispatch guarantees the cancel handler runs
// after any event handler; no synchronous callback into Rust or wait-on-self.
final class FipsOutputSource {
    private var source: DispatchSourceRead?
    init(descriptor: Int32, queue: DispatchQueue, ready: @escaping () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler(handler: ready)
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }
    func cancel() { source?.cancel(); source = nil }
    deinit { cancel() }
}

// Production batch loop shared with the host smoke harness. A failed write is
// terminal; cancellation on the source's own queue never waits for itself.
final class FipsOutputPump {
    private var source: FipsOutputSource?
    init(descriptor: Int32, queue: DispatchQueue, accepts: @escaping () -> Bool,
         read: @escaping (UnsafeMutablePointer<UInt8>, Int) -> Int32,
         write: @escaping ([Data]) -> Bool, failed: @escaping () -> Void) {
        source = FipsOutputSource(descriptor: descriptor, queue: queue) { [weak self] in
            guard accepts() else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var packets: [Data] = []
            for _ in 0..<32 {
                let count = read(&buffer, buffer.count)
                if count < 0 || count > buffer.count { self?.cancel(); failed(); return }
                if count == 0 { break }
                guard buffer[0] >> 4 == 4 || buffer[0] >> 4 == 6 else { self?.cancel(); failed(); return }
                packets.append(Data(buffer.prefix(Int(count))))
            }
            if !packets.isEmpty, !write(packets) { self?.cancel(); failed() }
        }
    }
    func cancel() { source?.cancel(); source = nil }
    deinit { cancel() }
}
