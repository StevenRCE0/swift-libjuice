import CJuice
import Foundation

/// Idiomatic Swift wrapper around `libjuice` — a small ICE-only library.
///
/// The agent owns a `juice_agent_t*` for its lifetime. C callbacks are
/// trampolined through an unretained `Unmanaged` pointer stored in
/// `juice_config_t.user_ptr`, so the Swift instance survives as long as
/// the caller holds a reference.
///
/// Threading: libjuice callbacks fire on libjuice's internal poll/mux/thread
/// (controlled by the concurrency mode). We hop to a delegate-supplied
/// queue before invoking user code so the public API has predictable
/// dispatch semantics.
public final class ICEAgent: @unchecked Sendable {
    public enum State: Int32, Sendable, CustomStringConvertible {
        case disconnected = 0
        case gathering = 1
        case connecting = 2
        case connected = 3
        case completed = 4
        case failed = 5

        public var description: String {
            switch self {
            case .disconnected: return "disconnected"
            case .gathering: return "gathering"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .completed: return "completed"
            case .failed: return "failed"
            }
        }
    }

    public struct TURNServer: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var username: String
        public var password: String

        public init(host: String, port: UInt16 = 3478, username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    public enum ConcurrencyMode: Sendable {
        /// All agents share a single poll thread. Lowest overhead.
        case poll
        /// Agents share a single UDP socket via multiplexing. Useful when
        /// you want to listen on one port and accept multiple peers.
        case mux
        /// Each agent runs on its own thread. Simplest model, scales poorly.
        case thread

        fileprivate var raw: juice_concurrency_mode_t {
            switch self {
            case .poll: return JUICE_CONCURRENCY_MODE_POLL
            case .mux: return JUICE_CONCURRENCY_MODE_MUX
            case .thread: return JUICE_CONCURRENCY_MODE_THREAD
            }
        }
    }

    public struct Configuration: Sendable {
        public var concurrencyMode: ConcurrencyMode
        public var stunServer: (host: String, port: UInt16)?
        public var turnServers: [TURNServer]
        public var bindAddress: String?
        public var localPortRange: ClosedRange<UInt16>?

        public init(
            concurrencyMode: ConcurrencyMode = .poll,
            stunServer: (host: String, port: UInt16)? = ("stun.l.google.com", 19302),
            turnServers: [TURNServer] = [],
            bindAddress: String? = nil,
            localPortRange: ClosedRange<UInt16>? = nil
        ) {
            self.concurrencyMode = concurrencyMode
            self.stunServer = stunServer
            self.turnServers = turnServers
            self.bindAddress = bindAddress
            self.localPortRange = localPortRange
        }
    }

    public enum AgentError: Error, LocalizedError {
        case createFailed
        case invalidArgument
        case runtimeFailure
        case notAvailable
        case bufferFull
        case datagramTooLarge
        case other(Int32)

        public var errorDescription: String? {
            switch self {
            case .createFailed: return "juice_create returned NULL"
            case .invalidArgument: return "libjuice: invalid argument"
            case .runtimeFailure: return "libjuice: runtime failure"
            case .notAvailable: return "libjuice: element not available"
            case .bufferFull: return "libjuice: buffer full"
            case .datagramTooLarge: return "libjuice: datagram too large"
            case .other(let code): return "libjuice error \(code)"
            }
        }

        fileprivate init(rc: Int32) {
            switch rc {
            case Int32(JUICE_ERR_INVALID): self = .invalidArgument
            case Int32(JUICE_ERR_FAILED): self = .runtimeFailure
            case Int32(JUICE_ERR_NOT_AVAIL): self = .notAvailable
            case Int32(JUICE_ERR_AGAIN): self = .bufferFull
            case Int32(JUICE_ERR_TOO_LARGE): self = .datagramTooLarge
            default: self = .other(rc)
            }
        }
    }

    // MARK: - Public state

    /// Fires for every state transition reported by libjuice. The agent
    /// instance is the same one the caller holds.
    public var onStateChange: (@Sendable (ICEAgent, State) -> Void)?
    /// Fires once per locally-gathered candidate (in SDP line form).
    public var onCandidate: (@Sendable (ICEAgent, String) -> Void)?
    /// Fires once after gathering completes — at this point the local
    /// description (via `localDescription()`) is final.
    public var onGatheringDone: (@Sendable (ICEAgent) -> Void)?
    /// Fires for every inbound application datagram on the negotiated path.
    public var onReceive: (@Sendable (ICEAgent, Data) -> Void)?

    /// Reflects the latest libjuice-reported agent state.
    public private(set) var state: State = .disconnected

    // MARK: - Private storage

    private var agent: OpaquePointer?
    private let configuration: Configuration
    /// libjuice's config struct keeps raw `const char *` pointers — we
    /// hold the backing storage alive for the agent's lifetime.
    private var holdCStrings: [UnsafeMutablePointer<CChar>] = []
    private var turnStorage: [juice_turn_server_t] = []
    private let callbackQueue: DispatchQueue

    public init(
        configuration: Configuration = .init(),
        callbackQueue: DispatchQueue = .global(qos: .userInitiated)
    ) throws {
        self.configuration = configuration
        self.callbackQueue = callbackQueue
        // Finish initializing stored props so `self` is well-formed before
        // we pass an Unmanaged pointer to it into libjuice.
        self.agent = nil

        var cfg = juice_config_t()
        cfg.concurrency_mode = configuration.concurrencyMode.raw
        cfg.user_ptr = Unmanaged.passUnretained(self).toOpaque()

        if let stun = configuration.stunServer {
            let p = strdup(stun.host)
            holdCStrings.append(p!)
            cfg.stun_server_host = UnsafePointer(p)
            cfg.stun_server_port = stun.port
        }

        if !configuration.turnServers.isEmpty {
            turnStorage = configuration.turnServers.map { ts in
                var c = juice_turn_server_t()
                let h = strdup(ts.host); holdCStrings.append(h!)
                let u = strdup(ts.username); holdCStrings.append(u!)
                let p = strdup(ts.password); holdCStrings.append(p!)
                c.host = UnsafePointer(h)
                c.username = UnsafePointer(u)
                c.password = UnsafePointer(p)
                c.port = ts.port
                return c
            }
            turnStorage.withUnsafeMutableBufferPointer { buf in
                cfg.turn_servers = buf.baseAddress
                cfg.turn_servers_count = Int32(buf.count)
            }
        }

        if let bind = configuration.bindAddress {
            let p = strdup(bind); holdCStrings.append(p!)
            cfg.bind_address = UnsafePointer(p)
        }
        if let range = configuration.localPortRange {
            cfg.local_port_range_begin = range.lowerBound
            cfg.local_port_range_end = range.upperBound
        }

        cfg.cb_state_changed = { _, state, userPtr in
            // state is a value-type C enum → Sendable by construction.
            let rawState = state.rawValue
            ICEAgent.dispatch(userPtr) { instance in
                let mapped = State(rawValue: Int32(rawState)) ?? .failed
                instance.state = mapped
                instance.onStateChange?(instance, mapped)
            }
        }
        cfg.cb_candidate = { _, sdp, userPtr in
            // Translate the C string into a Swift String synchronously,
            // before crossing into the @Sendable dispatch closure.
            let str: String? = sdp.flatMap { String(validatingCString: $0) }
            ICEAgent.dispatch(userPtr) { instance in
                if let str { instance.onCandidate?(instance, str) }
            }
        }
        cfg.cb_gathering_done = { _, userPtr in
            ICEAgent.dispatch(userPtr) { instance in
                instance.onGatheringDone?(instance)
            }
        }
        cfg.cb_recv = { _, data, size, userPtr in
            // Copy bytes into a Sendable Data right here on the C-callback
            // thread, then dispatch to the user queue.
            guard let data, size > 0 else { return }
            let payload = Data(bytes: data, count: size)
            ICEAgent.dispatch(userPtr) { instance in
                instance.onReceive?(instance, payload)
            }
        }

        guard let createdAgent = juice_create(&cfg) else {
            holdCStrings.forEach { free($0) }
            throw AgentError.createFailed
        }
        self.agent = createdAgent
        // libjuice copies juice_config_t by value (verified in src/juice.c);
        // const-char fields are *not* deep-copied for stun_server_host,
        // bind_address, or the per-turn-server fields, so we keep those
        // C-string allocations alive until deinit via `holdCStrings`.
    }

    deinit {
        if let agent {
            juice_destroy(agent)
        }
        holdCStrings.forEach { free($0) }
    }

    // MARK: - Public surface

    public func gatherCandidates() throws {
        try check(juice_gather_candidates(agent))
    }

    public func localDescription() throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(JUICE_MAX_SDP_STRING_LEN))
        let rc = juice_get_local_description(agent, &buffer, buffer.count)
        try check(rc)
        return String(cString: buffer)
    }

    public func setRemoteDescription(_ sdp: String) throws {
        try check(sdp.withCString { juice_set_remote_description(agent, $0) })
    }

    public func addRemoteCandidate(_ candidate: String) throws {
        try check(candidate.withCString { juice_add_remote_candidate(agent, $0) })
    }

    public func setRemoteGatheringDone() throws {
        try check(juice_set_remote_gathering_done(agent))
    }

    public func send(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return
            }
            try check(juice_send(agent, base, buf.count))
        }
    }

    /// Returns the negotiated `(local, remote)` socket addresses once the
    /// agent reaches `.connected` or `.completed`. Returns `nil` if not
    /// yet selected.
    public func selectedAddresses() -> (local: String, remote: String)? {
        let len = Int(JUICE_MAX_ADDRESS_STRING_LEN)
        var local = [CChar](repeating: 0, count: len)
        var remote = [CChar](repeating: 0, count: len)
        let rc = juice_get_selected_addresses(agent, &local, len, &remote, len)
        guard rc == 0 else { return nil }
        return (String(cString: local), String(cString: remote))
    }

    // MARK: - Internal

    private func check(_ rc: Int32) throws {
        if rc < 0 { throw AgentError(rc: rc) }
    }

    private static func dispatch(_ userPtr: UnsafeMutableRawPointer?, _ body: @Sendable @escaping (ICEAgent) -> Void) {
        guard let userPtr else { return }
        let instance = Unmanaged<ICEAgent>.fromOpaque(userPtr).takeUnretainedValue()
        instance.callbackQueue.async { body(instance) }
    }
}

// MARK: - Logging

extension ICEAgent {
    public enum LogLevel: Sendable {
        case verbose, debug, info, warn, error, fatal, none

        fileprivate var raw: juice_log_level_t {
            switch self {
            case .verbose: return JUICE_LOG_LEVEL_VERBOSE
            case .debug: return JUICE_LOG_LEVEL_DEBUG
            case .info: return JUICE_LOG_LEVEL_INFO
            case .warn: return JUICE_LOG_LEVEL_WARN
            case .error: return JUICE_LOG_LEVEL_ERROR
            case .fatal: return JUICE_LOG_LEVEL_FATAL
            case .none: return JUICE_LOG_LEVEL_NONE
            }
        }
    }

    public static func setLogLevel(_ level: LogLevel) {
        juice_set_log_level(level.raw)
    }
}
