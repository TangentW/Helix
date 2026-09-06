# Mixed Xcode onboarding fixture

This five-file Swift App exercises Foundation, UIKit, AVFoundation, Photos, two
`@TaskLocal` expansions, duplicate file-private type names, qualified SDK names,
an Objective-C bridging header, and a compiled Objective-C++ implementation.
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
validation, Xcode project loading, and frontend receipt diagnosis using the real
capture. Normal builds require the generated non-integrated driver and
`SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS=NO` settings; the standalone fixture's
baseline probe deliberately omits the latter to record toolchain behavior.

Integrated-driver probes run both with the proxy alone and with a sibling real
`swift`. Their status and capture count are observations, not expected failures
or a claim of supported integrated-driver scheduling. Build success without a
complete capture is insufficient for Helix. The direct compiler test
`SystemFrameworkIntegration` independently exercises `-explicit-module-build`.

When a report directory is provided, logs, timing observations, captured
arguments, before/after PBX files, and the diagnosis are saved there. Temporary
build outputs are deleted. This test does not run the installed App, generate a
complete production Catalog closure, or qualify device runtime activation.
The CLI/Hub tests cover generated phases and publication separately. Compiler
placeholder identity is also covered by synthetic SIL grammar tests because
these small macro sources do not reproduce every commercial compiler spelling.
