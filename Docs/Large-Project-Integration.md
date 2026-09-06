# Large-project integration

[简体中文](Large-Project-Integration.zh-CN.md)

Source count, dependency breadth, and compiler configuration are separate
dimensions. A 2,500-file scalar benchmark does not establish the cost of a
2,500-file application importing 100 native modules. Use the counters in
[Build performance](Build-Performance-Baseline.md) to measure the actual project.

## Install without the GUI

The Mac CLI can inspect and install an authored or previously generated Host
Plan. It uses Hub's transactional PBX, package, scheme, configuration, and
generated-file installer. Reapplying the same plan is idempotent. Invalid
target mappings and missing Hot Patch inputs fail before project publication.

```sh
helix xcode inspect --project Example.xcodeproj --json
helix xcode validate --plan HostPlan.json --json
helix xcode install --project Example.xcodeproj --plan HostPlan.json --json
helix xcode doctor --plan .helix/xcode/HostPlan.json --profile live --static
```

Place an authoring plan beside the project, or use its installed copy. Paths
inside the plan remain relative to the project source root. For a single-target
Live Reload project, the plan has this shape; replace the actual target, module,
scheme, configuration, and bundle identifiers with the inspected project values:

```json
{
  "schemaVersion": 1,
  "projectPath": "Example.xcodeproj",
  "integrationRoot": ".helix/xcode",
  "features": [
    { "id": "app", "targetName": "Example", "moduleName": "Example" }
  ],
  "profiles": [
    {
      "id": "live",
      "workflow": "liveReload",
      "schemeName": "Example",
      "applicationTargetName": "Example",
      "configurationName": "Debug",
      "bundleIdentifier": "dev.example.app",
      "namespaceSeed": "example-development",
      "featureID": "app"
    }
  ]
}
```

`inspect` is read-only and lists targets, their configurations, and shared
schemes. `install --json` returns the installed plan and written relative paths.
PBX installation, reconfiguration, and removal edit changed value tokens and
array members using the original syntax coordinates. Unchanged objects, fields,
quotes, comments, and source-list entries retain their original bytes; adding a
trigger does not reformat a large Sources phase. New values use OpenStep's ASCII
bare-token rules, so `libc++`, `@executable_path/Frameworks`, `*.xcassets`, and
conditional setting keys are quoted. Escaped strings retain their decoded values.
The system property-list parser checks input and output independently of Helix's
editor. Every PBX mutation is validated before writing and read back before the
shared file transaction commits; mismatched or invalid output rolls back the
transaction. This validates PBX syntax and intended values, not Xcode's complete
build graph: use `xcodebuild -list` and a real build for that separate check.

`install` preserves the supplied plan, including an explicitly qualified
`deviceNativeMatrixQualified` value. Omitting that field retains the existing
device backend policy; installation does not qualify a physical device.

For Hot Patch, provide the recipe, trusted root, and signing certificate at the
plan's paths before installation. The CLI does not invent signing identities;
private signing material is needed by the later signing operation. Normal
Build/Run and the running Helix service are still required for Live Reload.
`generate` remains useful for producing the kit alone; `install` additionally
applies project edits. Static Doctor checks do not replace a real Xcode build.

## Coexist with compiler infrastructure

The selected source target/configuration must resolve `SWIFT_EXEC` to the
generated Helix proxy. A target-level or command-line override can supersede
the generated xcconfig and must be reconciled. Helix appends its required
`OTHER_SWIFT_FLAGS`, Bridge link inputs, and relevant runtime configuration while
preserving inherited settings. It does not take over `CC` or `LD`.

The selected configurations have these integration costs and setting owners:

| Setting | Helix behavior and consequence |
| --- | --- |
| `PRODUCT_MODULE_NAME` | Uses the source module selected in the Host Plan |
| `SWIFT_EXEC` | Owns the source target's compiler entry point; another launcher must use the chaining contract below |
| `SWIFT_USE_INTEGRATED_DRIVER` | Sets `NO` for whole-target capture and the post-compile hook; Xcode's built-in Swift compilation cache is unavailable for this configuration |
| `SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS` | Sets `NO`; XCBuild's supplemental linker response file is not produced by this driver path. Swift object autolinking continues to supply imported framework/library inputs |
| `OTHER_SWIFT_FLAGS` | Appends private-import, implicit-dynamic, replacement-chaining, and user-module-version arguments to inherited flags |
| `LD_DYLIB_INSTALL_NAME` | Sets `@rpath/$(EXECUTABLE_PATH)` for the source target |
| `OTHER_LDFLAGS` | Appends generated Bridge/bootstrap objects and the selected workflow's runtime link inputs |
| `ENABLE_USER_SCRIPT_SANDBOXING` | Sets `NO` for generated phases that discover compiler inputs and write DerivedData artifacts |

Doctor reports the driver/cache tradeoff as `HLXXC015`, rejects an observed
source-target driver override as `HLXXC016`, and compares generated files with
the active tool's templates as well as their installed manifest. After updating
Helix, reapply integration in Hub or run `xcode install` with the project and
existing Host Plan to update settings and generated-file ownership together.
`generate` produces a standalone kit; use `install` to refresh an installed project.
Helix's own build-fact caches and a
qualified downstream launcher do not restore Xcode's built-in Swift cache.

The mixed-project regression on Xcode 26.6 reproduced a missing
`*-linker-args.resp` with explicit modules enabled and the old driver settings;
the generated `SWIFT_GENERATE_ADDITIONAL_LINKER_ARGS=NO` setting allowed the
same mixed Swift/ObjC++ application to link. Simply enabling the integrated
driver is insufficient: the proxy alone failed tool lookup; providing a sibling
real `swift` made the build succeed but produced no Helix target capture.
Integrated-driver capture and post-compile scheduling therefore remain
unqualified. These observations do not establish a timing advantage for either
driver or compatibility with every linker customization.

To chain an existing compiler launcher, export an absolute executable path in
the environment that starts the build:

```sh
HELIX_SWIFT_COMPILER_WRAPPER=/absolute/path/to/swift-launcher \
  xcodebuild -project Example.xcodeproj -scheme Example -configuration Debug build
```

The launcher receives the selected real `swiftc`/`swift-driver` as its first
argument and the exact original compiler arguments thereafter. A transparent
launcher starts as follows; insert only the invocation convention supported by
the team's compiler cache or build service:

```sh
#!/bin/sh
set -eu
compiler=$1
shift
exec "$compiler" "$@"
```

The launcher must support compiler discovery calls, preserve argument semantics,
produce the requested local build outputs, and propagate compiler status. It
must call the provided compiler without resolving `SWIFT_EXEC` again. Helix
rejects relative/missing launchers, self-reference, and recursive proxy calls.
Capture records the actual compiler and original arguments, and post-compile
work runs only after success. Later analysis replays that compiler directly.
Hidden semantic flags added only by a wrapper are therefore unsupported: put
them into Xcode's captured settings. Compatibility with a particular third-party
cache still requires that tool's own integration test.

XCBuild does not export arbitrary custom xcconfig settings to its compiler
process. Merely adding `HELIX_SWIFT_COMPILER_WRAPPER` to an xcconfig is not an
environment export. `HELIX_REAL_SWIFT_EXEC`, when explicitly exported, must name
the actual Swift compiler, not another launcher. Otherwise the proxy resolves
the selected compiler with `xcrun`.

## Compiler identity and retry behavior

See the [identity authority inventory](Compiler-Identity.md) for the keys, scopes,
rejection rules, and required conflict evidence across the frontend pipeline.

| Fact | Normalization and authority |
| --- | --- |
| Source nominal | Compiler declaration USR plus logical file scope distinguish file-private duplicates; a display name alone is not identity |
| Imported nominal | Group by established ABI/runtime identity, then normalize qualified and relative Swift spellings using proven module roots before all merges and alias consumers |
| Imported operation | Exact declaration/descriptor, signature, owner module, and measured ABI remain authoritative; a shared SIL implementation is not proof that two API declarations are identical |
| Source and dependency inputs | Logical source membership and content hashes; compiler input roles and bytes; private compiler checkpoints additionally bind physical source paths |
| Reusable compiler fact | Exact toolchain, SDK, target, semantic arguments, source/dependency content, and transform identity; a spelling match alone never grants reuse |

Thus `Progress` and `Foundation.Progress` can refer to the same `NSProgress`
without collapsing unrelated modules or nested scopes. True conflicts report
the observed spellings, canonical/runtime identities, declaring/imported modules,
representation and isolation evidence, and one source example per distinct fact.
Diagnostic source positions stay in memory and do not change persisted identity.

Prepare retains individually validated typed AST, identity SIL, and semantic SIL
after a later failure. If those compiler inputs still match, correcting a later
policy/Catalog problem can reuse all three outputs. Every hit is parsed and its
inputs confirmed again. Compiler or parser failures are not cached. A source,
dependency, toolchain, or semantic-setting change invalidates the checkpoints.
Successful receipt publication retires the large intermediate payloads when
their locks are available. Confirming inputs at each checkpoint adds scanning
work for large dependency trees; the commercial project's retry/cold cost still
needs measurement. See [Incremental build facts](Incremental-Build-Facts.md)
for cache isolation, invalidation, and counters.

Bridging headers, C++ interoperability, and toolchain macros share the same
replay path. Driver-only explicit-module scheduling is not copied into direct
AST analysis; captured module-loading inputs remain subject to replay validation.
Canonical SIL is read from a dedicated private output file because bridging-PCH
driver jobs can write `-o -` SIL to stderr. Diagnostics are never parsed as SIL.

## Collect independent frontend failures

Use the successful target's captured invocation to diagnose receipt generation:

```sh
helix xcode post-compile --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/DerivedData/path/FrontendInvocation.hlxswiftc \
  --diagnose --json
```

Omit `--json` for readable text. The report contains `passed`, a `checks` array
with `passed`/`failed`/`blocked` statuses and evidence, eligibility diagnostics,
and a performance trace when analysis starts. Exit zero means the checked
frontend receipt analysis passed. Eligibility diagnostics describe individual
declarations and do not by themselves mean the analysis failed.

Normal generation and diagnosis share the same dependency-aware analysis.
Diagnosis aggregates independent request/source-file errors, runs typed AST and
both SIL checks independently, then checks source nominals, imported types,
operations and Catalog consistency wherever their prerequisites succeeded.
Failed facts are never substituted as valid input; their consumers are marked
blocked. Invalid capture/context prevents dependent compiler work. After these
independent checks, final receipt assembly still stops at its first failure;
this mode does not promise every possible violation from malformed input.

Diagnosis reads existing validated Catalogs and reports missing production
coverage without starting cold Catalog generation or background prewarm. It
bypasses complete module-receipt cache hits so current checks run, but can reuse
and retain individually validated compiler checkpoints. It does not publish a
module receipt, Shell, Bridge, prepared state, or Hub reservation. Linking,
service connection, and runtime activation require normal Build/Run.

## Mixed configuration regression

[`Tests/Fixtures/MixedOnboarding`](../Tests/Fixtures/MixedOnboarding/README.md)
contains a small real Xcode App with two `@TaskLocal` expansions, file-private
types, qualified/unqualified SDK names, Foundation/UIKit/AVFoundation/Photos,
an Objective-C bridging header, C++ interop, `-g`, and explicit modules enabled
in project settings. Its opt-in test performs a native Xcode compile/link,
captures all five Swift files, installs twice, checks PBX syntax with `plutil`,
loads the installed project with `xcodebuild -list`, and diagnoses the receipt.
Driver probes record build status separately from capture availability.
The direct `SystemFrameworkIntegration` test additionally invokes the compiler
with `-explicit-module-build` and verifies emitted debug scopes.

This fixture checks configuration interactions; it is not a 100-module Catalog
benchmark or a physical-device activation test. Debug-only placeholder identity
also has a SIL grammar regression: the small Swift macro fixture does not claim
to reproduce the commercial compiler's `__unknown_macro__` spelling.

## Plan for cold Catalog work

The historical cold UIKit Catalog measurement is about 230 seconds for one
specific SDK/toolchain. Module count alone cannot predict total cost: API breadth,
dependency overlap, candidate rejection, and validated cache hits differ greatly.
There is no measured 100-module end-to-end cold total yet. Do not multiply the
UIKit number by 100 or interpret a scalar-source benchmark as that measurement.

Record cold Prepare, Catalog job completion, artifact bytes, and subsequent
cache hits separately. Run the background job in bounded resumable increments:

```sh
helix xcode catalog-prewarm --job /absolute/path/to/job.json --max-modules 1
```

Verified hits do not consume that budget. Completed modules survive interruption;
an interrupted unfinished module may restart. Run from the captured working
directory. The job lock prevents two workers from competing for one job; repeating
the command resumes it. See the [job location and lifecycle](Incremental-Build-Facts.md#search-paths-and-resumable-catalog-prewarm).

Team provisioning can run prewarm under each developer's account with the exact
toolchain/SDK and inputs. The current cache is owner-private and has no supported
portable Catalog import/export or shared writable multi-user cache protocol.
Copying DerivedData or a teammate's cache is not proof of compatibility.

## Current build-side resource bounds

These are enforced limits or cache cutoffs, not a guarantee that every project
below them fits memory or compiles quickly. MiB/GiB use powers of 1,024.

| Area | Bound and behavior |
| --- | --- |
| Direct process argv | Above 3,000 arguments or 128 KiB, supported compiler executables use response files; unsupported executables receive a launch error |
| Swift source loading | 64 MiB per file; Shell materialization defaults to 512 MiB total; source-size violations fail validation |
| Compiler input scan | 250,000 entries per root, 100,000 files and 1 GiB tracked bytes; incomplete or unstable scans disable reuse |
| Explicit scan inputs | Module map 8 MiB, VFS overlay 16 MiB, bridging header/header map 64 MiB, other explicit compiler inputs 512 MiB |
| Planning inventory | At most 250,000 retained root/entry records within one synchronous plan; no persistent directory listing cache |
| Catalog closure | 256 modules, including dependency expansion |
| Native API Catalog | 250,000 entries and 128 MiB encoded document per module; at most four frontend probe workers per producer, in batches of 256 candidates |
| Explicit NativeImport policy | Separate from module Catalogs: 1,024 types, 4,096 candidates, 8 MiB document |
| Host Plan | 128 features, 256 profiles, 1 MiB document |
| Receipt/cache | Shell receipt 32 MiB; module frontend cache payload 64 MiB; compiler checkpoint 256 MiB per stage; oversized cache payloads bypass storage |

Source headers and generated caches should live in separate trees: bridging
header input capture conservatively fingerprints neighboring compiler interface
files, so placing a module cache below that source directory expands the input
set and can disable reuse. Inspect `frontend_cache.compiler_inputs_incomplete_count`
before interpreting a repeated build as a cache performance result.

There is no hard host-process RSS budget or aggregate cache disk quota. AST/SIL
outputs and parsed structures are materialized in memory. Four workers is a
per-producer bound, not a machine-wide semaphore. Remaining failed checkpoints
can retain disk space; stop users of a private cache before resetting it.
Physical-device native activation, the commercial project's save-to-screen
latency, and its complete cold Catalog cost still need corresponding project
measurements. Host cross-compilation alone does not qualify those paths.
