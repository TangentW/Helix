# Mixed Xcode onboarding fixture

This five-file Swift App exercises Foundation, UIKit, AVFoundation, Photos, two
`@TaskLocal` expansions, same-named local protocol conformers, duplicate classes
and structs inheriting `fileprivate extension` access, `?? { ... }()` closure
coordinates, qualified SDK names, and UIKit's `NS_SWIFT_NAME` mapping from
`UIPencilInteractionTap` to `UIPencilInteraction.Tap`. Private nested static
`CGFloat` properties exercise AST/SIL overlay differences, and C callbacks plus
generic higher-order calls exercise generated adapter and reabstraction thunks.
Its deployment target is
iOS 17.5 for that mapped API. It also includes an Objective-C bridging header
and a compiled Objective-C++ implementation.
Debug enables debug information, C++ interop, and explicit modules in Xcode
settings. It is a configuration regression, not a large-source benchmark.

Run on macOS with Xcode and an iOS Simulator SDK:

```sh
HELIX_RUN_MIXED_XCODE=1 \
HELIX_MIXED_XCODE_REPORT_DIR=/absolute/path/outside/the/repository \
swift test --scratch-path .build/validation --filter MixedOnboarding
```

The test copies the project to a temporary path containing spaces and replaces
its local Helix package reference with the checkout's absolute path. It performs
an unsigned arm64 Simulator compile/link with Helix's standalone capture proxy,
then transactional CLI installation, idempotent reinstallation, system PBX
validation, Xcode project loading, selected source/imported-type diagnosis, and
full frontend receipt diagnosis using the real capture. The selected run must
skip SIL replay and Catalog loading; the full run checks independent SIL facts
and AST/SIL mappings. Neither publishes a receipt. Normal builds require the generated non-integrated driver and
`SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS=NO` settings; the standalone fixture's
baseline probe deliberately omits the latter to record toolchain behavior.

Integrated-driver probes run both with the proxy alone and with a sibling real
`swift`. Their status and capture count are observations, not expected failures
or a claim of supported integrated-driver scheduling. Build success without a
complete capture is insufficient for Helix. The direct compiler test
`SystemFrameworkIntegration` independently exercises `-explicit-module-build`.

When a report directory is provided, logs, timing observations, captured
arguments, before/after PBX files, and both schema 3 diagnostic reports are saved there. Temporary
build outputs are deleted. This test does not run the installed App, generate a
complete production Catalog closure, or qualify device runtime activation.
The CLI/Hub tests cover generated phases and publication separately. Compiler
placeholder identity is also covered by synthetic SIL grammar tests because
these small macro sources do not reproduce every commercial compiler spelling.

The test also replays the captured arguments through the real proxy with a
conditional compiler error. It verifies the private attempt record, unchanged
successful capture, input-only preflight without AST/SIL/dependency inventory,
typed preflight failure, and rejection of an attempt by normal post-compile.
`attempt-input-preflight.json`, `attempt-typed-preflight.json`, and the compiler
failure log are retained in the external report directory.

Finally it runs CLI uninstall using the authoring plan backup, checks that the
original user package linkage survives, validates the removed project with
`plutil` and `xcodebuild -list`, restores the deliberate source error and runs a
real build again. The external report includes uninstall JSON, PBX and build logs.

The fixture also exercises a static initializer closure and a generic
`Collection.Element` observation that is called with the nested UIKit
`UIPencilInteraction.Tap` type. These supplement direct and qualified Tap uses;
compiler archetype spellings must not become concrete imported type identities.
The opt-in test accepts `HELIX_MIXED_RUNTIME_PACKAGE=/absolute/package/path` to
validate current tooling with an archived published runtime commit. This is a
local package build with explicit HelixAppIntegration linkage, not remote SwiftPM resolution or generated Shell/Bridge activation evidence. The capture inventory selects the App module explicitly even when package targets also produce captures.
