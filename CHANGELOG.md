# Changelog

Version tags follow `vX.Y.Z+swift.N`, mirroring the upstream libjuice
version (`X.Y.Z`) plus a wrapper iteration (`+swift.N`). SemVer build
metadata after `+` doesn't affect SwiftPM version comparisons — consumers
pinning `from: "1.7.1"` resolve to the latest matching tag, including
later `+swift.N` iterations.

## 1.7.1+swift.1

Initial release.

- Wraps libjuice 1.7.1 (vendored under `Sources/CJuice/`).
- `ICEAgent` class exposing the agent lifecycle, callbacks, STUN/TURN config, send/receive, and selected-address inspection.
- Built-in hash implementations (`USE_NETTLE=0`) — no system-library dependencies beyond `pthread`.
- Platforms: iOS 17+, macOS 13+, visionOS 1+.
