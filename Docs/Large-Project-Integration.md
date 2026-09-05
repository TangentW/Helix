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
It preserves the supplied plan, including an explicitly qualified
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
