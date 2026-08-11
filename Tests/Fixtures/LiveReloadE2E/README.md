# LiveReloadE2E

This fixture is Helix's executable acceptance case for development-time HLBC
Live Reload. It builds a normal Swift framework and UIKit host, captures the
real Xcode frontend invocation, boots the requested Apple Silicon iOS Simulator
when necessary, launches the host, and verifies two generations in one
unchanged process:

1. `HELIX BASELINE` → `HELIX PATCHED` through a nonempty verified HLBC image.
2. `HELIX PATCHED` → `HELIX BASELINE` through a zero-bytecode restoring
   generation that removes the inherited route.

Run it from the repository root with an available Simulator UDID:

```bash
Tests/Fixtures/LiveReloadE2E/run-simulator-e2e.sh \
  AF763A53-66CF-405B-AE92-F5A9CDECE0CE
```

The script regenerates the hidden Xcode Integration Kit, builds the Feature and
App, starts an ephemeral authenticated Dev session, restores the Swift source
byte-for-byte on every exit path, and leaves build/daemon logs under
`.helix-e2e` for diagnosis. Generated Bridge Swift is compiled only into
DerivedData; it is not referenced by the project. The host imports only
`HelixDevRuntime`, creates one `ApplicationSession`, and has no `typeRegistry`
or `LiveReload.Reloadable` hook. This makes the fixture an acceptance test for
both low-cost integration and automatic UIKit instance discovery.

The fixture requires Xcode, an arm64 Mac, and an installed iOS Simulator
runtime. It waits for the requested device to finish booting. No third-party
test driver is required.

The host links only the `HelixDevAppRuntime` Swift package product; the hidden
Bridge object uses that same runtime image. Adding overlapping leaf products
can load the same Swift metadata more than once, so Helix rejects that topology
through the generated `RuntimeImageIdentity` contract. A Release target instead
links only `HelixAppRuntime`, which excludes Dev transport, dynamic loading, and
overlay code.

Run the independent production-graph check from the repository root:

```bash
Tests/Fixtures/LiveReloadE2E/run-release-audit.sh
```

It builds `ReleaseRuntimeHost` for the iOS 15 Simulator deployment target,
links only `HelixAppRuntime`, and runs `helix shell audit-release` across every
Mach-O and `Info.plist` in the resulting App. The audit rejects Dev runtime or
protocol images, launch-secret markers, and the Helix Bonjour service.

UIKit-specific runtime tests execute in the Simulator rather than being skipped
by a macOS `swift test` run:

```bash
Tests/Fixtures/LiveReloadE2E/run-ios-runtime-tests.sh \
  AF763A53-66CF-405B-AE92-F5A9CDECE0CE
```

The dedicated Xcode logic-test target compiles only the App runtime graph. It
does not pull macOS compiler/CLI products into an iOS test build.
