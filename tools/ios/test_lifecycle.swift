import Foundation

@main struct LifecycleTests {
    static func main() {
        let state = FipsPacketLifecycle()
        for _ in 0..<1000 {
            let starting = state.begin()!
            state.stop() // stop while settings/start completion is pending
            assert(!state.activate(starting))
            let token = state.begin()!
            assert(state.activate(token))
            assert(state.registerRead(token))
            assert(!state.registerRead(token))
            state.stop() // path replacement while a read is outstanding
            let next = state.begin()!
            assert(state.activate(next))
            assert(!state.registerRead(next))
            assert(!state.completeRead(token)) // stale packets must be dropped
            assert(state.registerRead(next))
            assert(state.completeRead(next))
            assert(!state.accepts(token))
            state.stop()
        }
        // Real DispatchSource cancellation from inside its own callback, and
        // descriptor release after pending events, including repeated cancel.
        let queue = DispatchQueue(label: "fips.source.test")
        for _ in 0..<100 {
            var fds: [Int32] = [0,0]
            assert(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            let readFD = fds[0], writeFD = fds[1]
            let done = DispatchSemaphore(value: 0)
            var pump: FipsOutputPump?
            var reads = 0, writes = 0, failures = 0
            queue.sync {
                pump = FipsOutputPump(descriptor: readFD, queue: queue, accepts: { true }, read: { p, _ in
                    reads += 1
                    p[0] = 0x60
                    return 40 // still ready: bound the batch and reject its write
                }, write: { packets in
                    writes += 1; assert(packets.count == 32); return false
                }, failed: { failures += 1; pump?.cancel(); done.signal() })
            }
            var byte: UInt8 = 1
            assert(Darwin.write(writeFD, &byte, 1) == 1)
            assert(done.wait(timeout: .now() + 2) == .success)
            queue.sync { pump?.cancel(); pump = nil }
            // libdispatch enqueues its cancel handler; wait for descriptor close.
            for _ in 0..<100 where fcntl(readFD, F_GETFD) != -1 { Thread.sleep(forTimeInterval: 0.001) }
            assert(fcntl(readFD, F_GETFD) == -1 && errno == EBADF)
            queue.sync { assert(reads == 32 && writes == 1 && failures == 1) }
            close(writeFD)
        }
        print("PASS: 1000 stop-during-start / restart / stale-read races; 100 rejected-write batches and exactly-once descriptor close, no callback-to-stop deadlock")
    }
}
