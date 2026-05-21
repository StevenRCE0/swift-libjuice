# swift-libjuice

Swift bindings for [libjuice](https://github.com/paullouisageneau/libjuice) — a small, pure-C **ICE-only** library (RFC 8445) for UDP NAT traversal.

If you're shipping a Swift app on Apple platforms that needs peer-to-peer connectivity (P2P data, voice, custom protocols) and you've concluded that pulling in the full libwebrtc stack just for ICE is over-engineering: this is the tightener.

## What you get

A focused Swift wrapper around libjuice's ~20 C functions:

- `ICEAgent` — create/destroy, gather candidates, exchange SDP, send/receive datagrams, observe state transitions.
- STUN + TURN configuration.
- ICE-Lite mode (server-side) by configuring with no STUN/TURN.
- The result of ICE: the negotiated `(local, remote)` UDP 5-tuple, ready for whatever upper-layer protocol you want to layer on top (QUIC, your own framing, raw datagrams, etc).

What you **don't** get (deliberately):

- DTLS, SCTP, RTP, audio/video codecs, NetEQ, AEC, NACK/FEC. If you want any of those, you're shopping for libwebrtc — this library is the leftmost rung on the spectrum: ICE only, ~5k LoC of C.

## Why not just use LiveKitWebRTC / Google's WebRTC?

`libjuice` is the right size for KT-shaped projects: small enough to read, no GN/Bazel build chain, no 50 MB binary tail. The C source is MPL-2.0; this Swift wrapper is MIT. The libjuice sources are vendored under `Sources/CJuice/` — building this package gets you a static C library plus a Swift module, no system dependencies beyond `pthread`.

## Platforms

- iOS 17+
- macOS 13+
- visionOS 1+

(Linux support is plausible — the C source compiles, but the Package.swift would need its platforms list extended. PR welcome.)

## Install

```swift
.package(url: "https://github.com/StevenRCE0/swift-libjuice.git", from: "1.7.1"),
```

Then add `SwiftJUICE` as a dependency of your target.

### Versioning

Tags follow `vX.Y.Z+swift.N` — the upstream libjuice version (`X.Y.Z`)
plus a wrapper-iteration suffix (`+swift.N`). SemVer build metadata
doesn't affect SwiftPM resolution: pinning `from: "1.7.1"` picks up the
latest matching tag including any `+swift.N` updates that ship only
Swift-wrapper changes. A jump to a new libjuice version bumps `X.Y.Z`
and resets the wrapper suffix.

## Usage

The flow is the standard ICE flow: each side gathers candidates, exchanges SDP via any side channel (your signaling server, manual paste, a QR code), then sends datagrams once connectivity completes.

```swift
import SwiftJUICE

// 1. Create an agent. STUN defaults to Google's public server.
let agent = try ICEAgent()

agent.onCandidate = { _, sdpLine in
    // optional: forward each candidate immediately (trickle ICE)
}
agent.onGatheringDone = { agent in
    let localSDP = try? agent.localDescription()
    // Send localSDP to the remote peer via your signaling channel.
}
agent.onStateChange = { _, state in
    print("ICE state: \(state)")
}
agent.onReceive = { _, data in
    // Inbound datagram from the connected peer.
}

// 2. Start gathering. State goes idle → gathering → ...
try agent.gatherCandidates()

// 3. When the remote SDP arrives via your signaling channel:
try agent.setRemoteDescription(remoteSDP)

// 4. Once `agent.onStateChange` reports `.connected`:
try agent.send(Data("hello".utf8))

// 5. Discover the negotiated socket pair if you need it:
if let (local, remote) = agent.selectedAddresses() {
    print("ICE selected \(local) ↔ \(remote)")
}
```

## TURN

To route through a TURN relay (necessary for symmetric NATs and UDP-blocked networks):

```swift
let agent = try ICEAgent(configuration: .init(
    stunServer: ("stun.l.google.com", 19302),
    turnServers: [
        .init(host: "turn.example.com", port: 3478,
              username: "user", password: "pass")
    ]
))
```

## Concurrency

The `ICEAgent` callbacks (`onCandidate`, `onGatheringDone`, `onStateChange`, `onReceive`) fire on a `DispatchQueue` you supply at init (defaults to `.global(qos: .userInitiated)`). The libjuice internal thread feeds events into the queue; user code never runs on libjuice's poll thread.

## Logging

```swift
ICEAgent.setLogLevel(.info)  // or .debug / .warn / .verbose / .none
```

Logs go to libjuice's default sink (stderr). Set `juice_set_log_handler` directly if you want to redirect — the binding for that is on the "should-have" list, not yet exposed.

## Vendoring

The upstream libjuice 1.7.1 sources are vendored under `Sources/CJuice/` so you don't need libjuice installed system-wide. Two defines tune the build for the wrapper:

- `USE_NETTLE=0` — use libjuice's built-in hash implementations rather than Nettle, so the target has no system-library dependencies.
- `JUICE_EXPORTS` — export visibility for the static library.

The upstream source license (Mozilla Public License 2.0) is preserved under `LICENSE-libjuice`.

## Status

| Feature | Status |
|---|---|
| ICE agent (gather / negotiate / send / receive) | ✅ exposed |
| STUN config | ✅ exposed |
| TURN client config | ✅ exposed |
| Selected address inspection | ✅ exposed |
| Custom concurrency mode (poll / mux / thread) | ✅ exposed |
| Log level | ✅ exposed |
| `juice_set_local_ice_attributes` (custom ufrag/pwd) | ⚠️ not yet wrapped |
| `juice_add_turn_server` post-init | ⚠️ not yet wrapped |
| `juice_set_ice_tcp_mode` (ICE-TCP for UDP-blocked nets) | ⚠️ not yet wrapped |
| `juice_set_log_handler` (custom log sink) | ⚠️ not yet wrapped |
| TURN server (`juice_server_*`) | ⚠️ C side compiled, no Swift wrapper |

## License

MIT for the Swift wrapper — see [LICENSE](./LICENSE).
MPL-2.0 for the vendored libjuice C source — see [LICENSE-libjuice](./LICENSE-libjuice).

## Acknowledgements

[paullouisageneau/libjuice](https://github.com/paullouisageneau/libjuice) — Paul-Louis Ageneau's clean little ICE library that makes this possible.
