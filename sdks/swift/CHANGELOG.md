# Changelog

## 0.22.0 - 2026-07-17

- Reassemble fragmented WebSocket messages, including large subscription snapshots.
- Validate HTTP upgrades, selected subprotocols, frame structure, and control-frame rules.
- Bound frame and reassembled-message sizes to prevent unbounded buffering.
- Ignore stale `NWConnection` callbacks after reconnect and report remote close frames.
- Protect all transport state with Swift 6 `Mutex<State>` and remove unchecked sendability from the transport.
- Build masked client frames in one allocation and perform graceful WebSocket close handshakes.
- Protect observability and async continuation state with Swift 6 synchronization while keeping disabled metrics on an atomic fast path.
- Coalesce cache-to-observation synchronization so update bursts create fewer main-actor tasks.
- Make the process-wide client cache an immutable, thread-safe singleton.
- Make subscription callbacks explicitly main-actor isolated and sendable, removing unchecked sendability from `SubscriptionHandle`.
- Add statically dispatched and inlined BSATN codecs, direct client/server message paths, and hybrid no-copy encoder storage.
- Defer cache-index materialization and batch transaction inserts, raising generated-row bulk insertion above 7 million rows per second in local Apple Silicon benchmarks.
- Move benchmarks to an isolated nested package so SDK consumers have no third-party dependencies.
- Add standalone package CI, including Thread Sanitizer coverage, and align documented Apple deployment targets with `Package.swift`.
- Add the applicable SpacetimeDB Business Source License.

## 0.21.0 - 2026-03-03

- Mirrored `sdks/swift` from upstream `swift-integration` through commit `3ee44cea6`.
- Completed NW transport integration by adding `NWWebSocketTransport`.
- Updated `SpacetimeClient` for Swift 6 performance and concurrency improvements.
- Updated SDK surface wiring in `SpacetimeDB.swift` for the new transport/client behavior.
- Included generated/demo compatibility updates used by Ninja and keynote Swift clients.
- Refreshed mirror README dependency snippet for release consumption from GitHub.
- Updated distribution runbook examples to release as `0.21.0`.
- Updated SPI checklist release version default to `0.21.0`.
