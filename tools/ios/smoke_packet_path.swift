import Foundation
import Security
import Darwin

// macOS host harness: production Rust runtime + production Swift output pump.
// It neither installs a VPN nor measures physical-device battery use.
@main struct PacketSmoke {
    // Optional host investigation mode. CPU is process user+system time;
    // Darwin wakeup counters are NOT all scheduler wakeups or energy use.
    struct Usage {
        let cpu: Double
        let interruptWakeups: UInt64
        let packageIdleWakeups: UInt64
        init() {
            var r = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &r) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
                }
            }
            precondition(result == 0, "process usage unavailable")
            // proc_pid_rusage CPU fields use Mach ticks on this host; use
            // getrusage's explicitly seconds/microseconds CPU accounting.
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0, "CPU usage unavailable")
            cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
                Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            interruptWakeups = r.ri_interrupt_wkups
            packageIdleWakeups = r.ri_pkg_idle_wkups
        }
    }
    static func emit(_ value: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
        fflush(stdout)
    }
    static func measure(_ phase: String, seconds: Double, work: () -> Void,
                        counters: () -> [String: Any] = { [:] }) {
        emit(["phase": phase, "event": "begin", "unixTime": Date().timeIntervalSince1970, "pid": getpid()])
        let began = DispatchTime.now().uptimeNanoseconds
        let before = Usage()
        work()
        let after = Usage()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        var result = counters()
        result.merge(["phase": phase, "event": "end", "unixTime": Date().timeIntervalSince1970,
                      "requestedSeconds": seconds, "elapsedSeconds": elapsed,
                      "cpuSeconds": after.cpu - before.cpu,
                      "cpuPercentOneCore": (after.cpu - before.cpu) / elapsed * 100,
                      "interruptWakeups": after.interruptWakeups - before.interruptWakeups,
                      "packageIdleWakeups": after.packageIdleWakeups - before.packageIdleWakeups],
                     uniquingKeysWith: { _, new in new })
        emit(result)
    }
    static func decode(_ p: UnsafeMutablePointer<CChar>?) -> [String: Any] {
        guard let p else { fatalError("missing JSON") }
        defer { wm_fips_string_free(p) }
        return try! JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as! [String: Any]
    }
    static func query(_ id: UInt16) -> [UInt8] {
        var dns: [UInt8] = [UInt8(id >> 8), UInt8(id & 255),1,0,0,1,0,0,0,0,0,0]
        for label in ["example", "com"] { dns.append(UInt8(label.count)); dns += label.utf8 }
        dns += [0,0,28,0,1]
        var p = [UInt8](repeating: 0, count: 28)
        let length = p.count + dns.count
        p[0]=0x45; p[2]=UInt8(length >> 8); p[3]=UInt8(length & 255); p[9]=17
        p.replaceSubrange(12..<20, with: [10,1,1,2,10,1,1,1])
        p[20]=16; p[21]=146; p[23]=53; p[25]=UInt8(dns.count+8)
        return p + dns
    }
    static func main() {
        let measurementText = ProcessInfo.processInfo.environment["WM_FIPS_MEASURE_SECONDS"]
        let measurementSeconds = measurementText.flatMap(Double.init)
        precondition(measurementText == nil || (measurementSeconds != nil &&
            measurementSeconds! >= 10 && measurementSeconds! <= 300), "measurement duration must be 10...300 seconds")
        if let seconds = measurementSeconds {
            measure("stopped_before", seconds: seconds, work: { Thread.sleep(forTimeInterval: seconds) })
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wm-fips-smoke-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = FileManager.default.currentDirectoryPath
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous); try? FileManager.default.removeItem(at: directory) }
        var key = [UInt8](repeating: 0, count: 32)
        assert(SecRandomCopyBytes(kSecRandomDefault, 32, &key) == errSecSuccess)
        let result = key.withUnsafeBufferPointer { p in directory.path.withCString { decode(wm_fips_start(p.baseAddress, $0)) } }
        key = [UInt8](repeating: 0, count: 32)
        assert(result["state"] as? String == "running")
        let queue = DispatchQueue(label: "fips.host.packets")
        let fd = wm_fips_output_descriptor(); assert(fd >= 0)
        var pump: FipsOutputPump?
        var reads=0, batches=0, packets=0, maxBatch=0, failures=0
        let received = DispatchSemaphore(value: 0)
        queue.sync {
            pump = FipsOutputPump(descriptor: fd, queue: queue, accepts: { true }, read: {
                reads += 1; return wm_fips_output($0, $1)
            }, write: { batch in
                batches += 1; packets += batch.count; maxBatch = max(maxBatch, batch.count)
                for p in batch {
                    assert(p.count > 31 && p[0] >> 4 == 4 && p[31] & 15 == 5) // local REFUSED, no public fallback
                    received.signal()
                }
                return true
            }, failed: { failures += 1 })
        }
        if let seconds = measurementSeconds {
            // Let bootstrap/discovery startup settle before attributing idle CPU.
            Thread.sleep(forTimeInterval: 10)
            let healthFirst = ProcessInfo.processInfo.environment["WM_FIPS_HEALTH_FIRST"] == "1"
            for healthEnabled in (healthFirst ? [true, false] : [false, true]) {
                let connectedBefore = decode(wm_fips_peers())["connected"] as? Bool ?? false
                var health: DispatchSourceTimer?
                var checks = 0
                let beforeReads = queue.sync { reads }
                if healthEnabled {
                    queue.sync {
                        let timer = DispatchSource.makeTimerSource(queue: queue)
                        timer.schedule(deadline: .now() + 5, repeating: .seconds(5), leeway: .seconds(1))
                        timer.setEventHandler {
                            precondition(decode(wm_fips_status())["state"] as? String == "running")
                            checks += 1
                        }
                        health = timer; timer.resume()
                    }
                }
                measure(healthEnabled ? "idle_health_on" : "idle_health_off", seconds: seconds,
                    work: { Thread.sleep(forTimeInterval: seconds) }, counters: {
                        queue.sync { ["healthChecks": checks, "outputReads": reads - beforeReads, "failures": failures] }
                    })
                queue.sync { health?.cancel(); health = nil }
                emit(["event": "connectivity", "healthEnabled": healthEnabled, "before": connectedBefore,
                      "after": decode(wm_fips_peers())["connected"] as? Bool ?? false])
            }
            let beforePackets = queue.sync { packets }
            measure("active_local_dns_20hz", seconds: seconds, work: {
                let activeBegan = DispatchTime.now().uptimeNanoseconds
                for id in 0..<Int(seconds * 20) {
                    let packet = query(UInt16(id))
                    precondition(packet.withUnsafeBufferPointer { wm_fips_input($0.baseAddress, $0.count) } == 0)
                    precondition(received.wait(timeout: .now() + 3) == .success)
                    // Absolute pacing avoids accumulating sleep coalescing
                    // delays; actual elapsed time/rate are still reported.
                    let deadline = activeBegan + UInt64(id + 1) * 50_000_000
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now < deadline { Thread.sleep(forTimeInterval: Double(deadline - now) / 1e9) }
                }
            }, counters: { queue.sync { ["deliveredPackets": packets - beforePackets, "failures": failures] } })
            queue.sync { reads = 0; batches = 0; packets = 0; maxBatch = 0 }
        }
        let began = Date()
        Thread.sleep(forTimeInterval: 5)
        queue.sync { assert(reads == 0 && batches == 0 && failures == 0) }
        print("host_idle_seconds=\(Date().timeIntervalSince(began)) output_reads=0 delivery_batches=0 (old timer scheduled ~500 drains)")
        for id in 0..<256 {
            let packet = query(UInt16(id))
            assert(packet.withUnsafeBufferPointer { wm_fips_input($0.baseAddress, $0.count) } == 0)
            assert(received.wait(timeout: .now() + 3) == .success)
        }
        // Hold the production consumer while DNS produces a real burst.
        // This queues no extra dispatch tasks: the source coalesces readiness.
        queue.sync {
            for id in 256..<272 {
                let packet = query(UInt16(id))
                assert(packet.withUnsafeBufferPointer { wm_fips_input($0.baseAddress, $0.count) } == 0)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        for _ in 0..<16 { assert(received.wait(timeout: .now() + 3) == .success) }
        queue.sync { assert(packets == 272 && failures == 0 && maxBatch > 1 && maxBatch <= 32); print("host_active_dns_packets=\(packets) batches=\(batches) maximum_batch=\(maxBatch) output_reads=\(reads)") }
        // Runtime death / shutdown signals EOF and the production pump cancels
        // itself without a callback->stop wait cycle.
        assert(decode(wm_fips_stop())["state"] as? String == "notInstalled")
        for _ in 0..<100 {
            if queue.sync(execute: { failures == 1 }) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        queue.sync { assert(failures == 1); pump?.cancel(); pump = nil }
        for _ in 0..<100 where fcntl(fd, F_GETFD) != -1 { Thread.sleep(forTimeInterval: 0.001) }
        assert(fcntl(fd, F_GETFD) == -1 && errno == EBADF)
        print("host_terminal_eof_failures=1 descriptor_closed=true")
        if let seconds = measurementSeconds {
            measure("stopped_after", seconds: seconds, work: { Thread.sleep(forTimeInterval: seconds) })
        }
    }
}
