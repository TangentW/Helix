# LiveReloadE2E

This fixture is Helix's executable acceptance case for development-time HLBC
Live Reload. It builds a normal Swift framework and UIKit host, captures the
real Xcode frontend invocation, boots the requested Apple Silicon iOS Simulator
when necessary, launches the host, and verifies eight generations in one
unchanged process:

1. `HELIX BASELINE` → `HELIX PATCHED` through a nonempty verified HLBC image.
2. `HELIX PATCHED` → `HELIX BASELINE` through a zero-bytecode restoring
   generation that removes the inherited route.
3. A button action creates, configures, constrains, and retains a new `UILabel`.
4. An escaping `UIButton.configurationUpdateHandler` weakly captures its owner.
5. `UIView.performWithoutAnimation` and multi-trailing-closure
   `UIView.animate` execute nonescaping and escaping callbacks.
6. A newly constructed `UIViewController` is presented with a weakly capturing
   completion callback.
7. The presented controller is dismissed with another completion callback.
8. Restoring the committed source reactivates the original button action.

Run it from the repository root with an available Simulator UDID:

```bash
Tests/Fixtures/LiveReloadE2E/run-simulator-e2e.sh \
  AF763A53-66CF-405B-AE92-F5A9CDECE0CE
```

The script regenerates the hidden Xcode Integration Kit, starts the same
persistent-service implementation used by Helix Hub, builds the Feature and
App, performs an ordinary debugger launch without a custom LLDB init file,
restores the Swift source byte-for-byte on every exit path, and leaves Hub,
debugger, build, and scenario screenshot evidence under `.helix-e2e` for
diagnosis. Generated Bridge Swift is compiled only into
DerivedData; it is not referenced by the project. The host imports neither
Helix product and contains no runtime initialization, `typeRegistry`, or
`LiveReload.Reloadable` hook; the generated bootstrap object starts the
configuration-scoped development support automatically. This makes the fixture
an acceptance test for both zero-code integration and automatic UIKit instance
discovery. The changed
callback also executes an imported `NSTextAlignment` setter and interpolated
`print`. It additionally calls QuartzCore's `CACurrentMediaTime`, covering
an imported C global function outside UIKit. The same generation therefore
exercises NativeImport discovery, generated Bridge invocation, and unoptimized
SIL ownership. Each interaction scenario replaces only the marked private
button-action body. A host-side command file invokes
`UIControl.sendActions(for:)`, so the path entering patched code is the same
target-action path used by a physical tap rather than a test-only Helix callback
registry. The host continuously persists the resulting title, button
configuration, presentation, and view-tree state in the App data container;
the script waits for that observable UIKit state instead of treating
compilation or activation alone as success.

The fixture requires Xcode, an arm64 Mac, and an installed iOS Simulator
runtime. It waits for the requested device to finish booting. No third-party
test driver is required.

The host links the production-safe `HelixAppIntegration` product. Its Live
Reload configuration also makes dynamic `HelixDevSupport` available and embeds
it automatically; the Release fixture contains only `HelixAppIntegration`.
Application source imports neither product and does not initialize a runtime.
The Live Reload API contract remains internal to the development graph and is
not published as a standalone package product.

Run the independent production-graph check from the repository root:

```bash
Tests/Fixtures/LiveReloadE2E/run-release-audit.sh
```

It builds `ReleaseRuntimeHost` for the iOS 15 Simulator deployment target,
links only `HelixAppIntegration`, and runs `helix shell audit-release` across every
Mach-O and `Info.plist` in the resulting App. The audit rejects Dev runtime,
protocol, or Live Reload API images, launch-secret markers, and the Helix
Bonjour service.

UIKit-specific runtime tests execute in the Simulator rather than being skipped
by a macOS `swift test` run:

```bash
Tests/Fixtures/LiveReloadE2E/run-ios-runtime-tests.sh \
  AF763A53-66CF-405B-AE92-F5A9CDECE0CE
```

The dedicated Xcode logic-test target compiles only the App runtime graph. It
does not pull macOS compiler/CLI products into an iOS test build.
