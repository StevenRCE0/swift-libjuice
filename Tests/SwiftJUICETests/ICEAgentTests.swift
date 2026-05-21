import Foundation
import Testing
@testable import SwiftJUICE

@Suite("ICEAgent")
struct ICEAgentTests {
    @Test("agent creation and destruction is clean")
    func createDestroy() async throws {
        let agent = try ICEAgent(configuration: .init(stunServer: nil))
        #expect(agent.state == .disconnected)
        _ = agent
    }

    @Test("gathering with no STUN produces a local candidate")
    func gathersLocalCandidate() async throws {
        let candidates = LockedBox<[String]>(value: [])
        let gatheringDone = AsyncFlag()
        let agent = try ICEAgent(configuration: .init(stunServer: nil))
        agent.onCandidate = { _, sdp in
            candidates.mutate { $0.append(sdp) }
        }
        agent.onGatheringDone = { _ in
            gatheringDone.signal()
        }
        try agent.gatherCandidates()
        await gatheringDone.wait(timeoutSeconds: 5)
        let collected = candidates.get()
        // Expect at least one host candidate even without STUN.
        #expect(!collected.isEmpty, "expected at least one local candidate, got none")
    }

    @Test("local description includes ufrag and pwd")
    func localDescriptionContainsAttributes() async throws {
        let gatheringDone = AsyncFlag()
        let agent = try ICEAgent(configuration: .init(stunServer: nil))
        agent.onGatheringDone = { _ in gatheringDone.signal() }
        try agent.gatherCandidates()
        await gatheringDone.wait(timeoutSeconds: 5)
        let desc = try agent.localDescription()
        #expect(desc.contains("a=ice-ufrag:"))
        #expect(desc.contains("a=ice-pwd:"))
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(value: Value) { self.value = value }
    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}

final class AsyncFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait(timeoutSeconds: Double = 30) async {
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            self.signal()
        }
        await withCheckedContinuation { cont in
            lock.lock()
            if signalled {
                lock.unlock()
                cont.resume()
                return
            }
            continuations.append(cont)
            lock.unlock()
        }
        timeout.cancel()
    }

    func signal() {
        lock.lock()
        signalled = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for cont in pending { cont.resume() }
    }
}
