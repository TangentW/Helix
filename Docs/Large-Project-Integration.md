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
  "schemaVersion": 2,
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

Common source forms have the following identity boundaries. See the detailed
[compiler identity inventory](Compiler-Identity.md) for authority and evidence.

| Source form | Current behavior |
| --- | --- |
| Same-named protocol conformers local to different functions | Retain every witness-table occurrence; printed type/protocol names do not establish global uniqueness. Ambiguous types and descendants cannot supply layout, generic or dispatch facts |
| Unmarked classes/structs in `private` / `fileprivate extension` | Inherit extension defaults, respecting explicit member access and private parent limits separately; ambiguous private layouts remain isolated |
| Closures at one coordinate in `optional ?? { ... }()` | Compiler symbol roles distinguish autoclosures from explicit closures; closure discriminators further constrain matching. Remaining ambiguity reports all candidates |
| Private static SDK overlay properties | Structural `Static`/getter evidence distinguishes a `CoreFoundation.CGFloat` AST USR from the `CoreGraphics.CGFloat` SIL getter without selecting a shared-coordinate addressor |
| C callback and reabstraction thunks | Compiler adapter attributes and thunk roles exclude generated entries; unknown shapes retain all conflict evidence |
| Generic archetypes such as `τ_0_0.Element` | Excluded before nominal/alias grouping; independently proven Clang runtime facts remain available and validated |
| `NS_SWIFT_NAME` nested classes and flat Clang names | Normalize using proven Objective-C runtime identity, preserve generic arguments, and do not equate unrelated nested types |

## Declaration scope and local rejection

Live Reload defaults to `excludeUnresolved`: an ambiguous or missing consumed
AST/SIL mapping excludes its source declaration while independently valid entries
continue. Hot Patch and the existing headless receipt API default to `strict`.
The optional `FrontendReceipt.Request.indexing` value allows headless callers to
select the same policy explicitly. These options do not make unsupported Swift
ABIs or invalid compiler/type/Catalog facts acceptable.

A function owns its nested closures and local functions; a property/subscript owns
its accessors. Exclusion identity is the compiler declaration USR plus logical
source file, with source location and every rejected candidate retained as evidence.
Body discovery rolls back operations collected before a nested mapping failure;
property generation rolls back the entire accessor group. Unconsumed synthesized
backing declarations are not source entry candidates; their consumers still require
SIL evidence. Initializers/deinitializers also own their nested closures. A mapping
failure without proven declaration ownership conservatively excludes its entire
validated source file, recording each failure. Coordinates never select an owner,
and callers that may depend on that closure are not retained from that file.
Invalid source membership, malformed SIL, or conflicting type/ABI/Catalog facts
remain fatal.

For a smaller initial scope, use Host Plan schema 2 and add `indexing` to the
feature, then reapply `xcode install`:

```json
{
  "id": "app",
  "targetName": "Example",
  "moduleName": "Example",
  "indexing": {
    "include": ["Sources/Feature/**"],
    "exclude": ["Sources/Feature/Generated/**"],
    "failurePolicy": "excludeUnresolved"
  }
}
```

Patterns match captured logical source paths using the patch configuration's
`*`, `**`, and `?` rules. An explicitly supplied options object defaults to
`include: ["**"]`, `exclude: []`, and `failurePolicy: "strict"` when fields are
omitted. A scope matching no captured source rejects before compiler replay.
All captured files still compile and contribute source/dependency hashes, nominal
and imported-type facts. Scope narrows Helix declaration and source-operation
discovery; it does not promise cheaper whole-module Swift emission, suppress global
conflicts, or remove explicitly supplied Catalog authority.

Use `Sources/**` for a directory tree; `Sources` matches only that complete path.
An unmatched scope reports glob syntax, the total source count and at most eight
source-path examples before compiler replay.

`HLXIDX024` records each excluded declaration and its complete reasons in
`FrontendDiagnostics.json` and the diagnostic report. `HLXIDX025` records each
unowned mapping failure and the resulting whole-file exclusion. Reasons from both
SIL stages merge for each AST inventory node; neither coordinates nor diagnostic
node ordinals are declaration identities. Query the complete build-time list with
`helix xcode exclusions --diagnostics /path/FrontendDiagnostics.json --file Sources/Feature.swift --json`;
omit `--file` for all entries. Text displays at most 20 entries; JSON retains full
evidence. This describes build-time coverage, not device activation. The CLI reports the excluded
count and diagnostic path, including unchanged Prepare hits. Module-receipt and
Prepare identities include the indexing options; changing policy or scope cannot
reuse a result with different authority. A change to an excluded source still
invalidates whole-module compiler facts. Raw compiler checkpoints remain reusable
across policy changes only when all compilation inputs match.

Host Plan schema 1 remains readable without indexing or runtime package options and round-trips its
original canonical bytes. Indexing options require schema 2, so older tools reject
the plan instead of silently ignoring its scope. New plans use schema 2. Existing
public request/feature initializers remain available; indexed overloads are additive.
The receipt and device wire formats are unchanged. PrepareState schema 1 adds an
optional informational `excludedDeclarationCount`, `excludedFileCount` and
`unownedMappingCount`; omission means a legacy count
is unavailable, while independently bound input hashes still control reuse.

## Collect independent frontend failures

Use the target compiler record to diagnose receipt generation. The successful
record remains available for the existing command:

```sh
helix xcode post-compile --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/DerivedData/path/FrontendInvocation.hlxswiftc \
  --diagnose --json
```

Omit `--json` for readable text with per-check elapsed time. The report contains
`passed`, a `checks` array with `passed`/`failed`/`blocked` statuses and evidence,
eligibility diagnostics, and a performance trace when analysis starts. Individual
eligibility diagnostics do not by themselves mean the analysis failed.

To investigate nominal discovery without replaying SIL or loading Catalogs:

```sh
helix xcode post-compile --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/DerivedData/path/FrontendInvocation.hlxswiftc \
  --diagnose --stages source-nominals,imported-types --json
```

`--stages` accepts comma-separated roots, includes their dependencies, and skips
unselected branches. Empty or unknown selections are errors.

| Selection | Work required |
| --- | --- |
| `inputs` | Request, source bytes and toolchain checks; no AST/SIL, Catalog or dependency-cache inventory |
| `typed-ast` | Request, source and toolchain validation; typed AST emission/parsing |
| `identity-sil`, `semantic-sil` | The selected SIL replay and its component checks; no typed AST |
| `source-nominals`, `imported-types` | Typed AST and type demangling; no SIL or Catalogs |
| `source-mappings` | Typed AST, both SIL replays/component checks, and AST/SIL mapping |
| `imported-operations` | Typed AST, type demangling and semantic SIL; no identity SIL or Catalogs |
| `catalogs` | Typed AST imports, toolchain facts and available cached Catalog validation; no SIL |
| `receipt` | Complete frontend receipt analysis and assembly |

Diagnostic JSON now emits **schema 3**. Its optional `requestedStages` records a
sorted, unique selection. A missing field (including schema 1 reports) means full
scope. With a selection that omits `receipt`, `passed: true` and exit zero mean
only that the selected checks and dependencies passed; they do not qualify a full
receipt. Schema-aware consumers must recognize version 3 and inspect this scope. `not_run` explicitly
marks unselected or unexecuted checks, separately from failed dependencies marked
`blocked`. Absence of an error is not evidence of a passed check. Schema 1/2 reports
remain readable.
Omitting `--stages`, or selecting `receipt`, retains full frontend validation.
This diagnostic format change does not change Shell or patch artifact schemas.

Normal generation and diagnosis share the same dependency-aware analysis.
Diagnosis aggregates independent request/source-file errors and compiler-stage
failures. Within each SIL output, function definitions, debug scopes, source
modules, conformance records and nominal declarations are checked independently.
Validated definitions and debug scopes permit function-location binding and
AST/SIL mapping even if unrelated conformance or layout checks fail. Mapping
reports all independent declaration conflicts. Type-environment construction,
imported operations and receipt assembly remain blocked when their facts are
invalid; no empty replacement `CanonicalSIL.File` is created.

Component checks appear under `frontend.identity_sil.*` and
`frontend.semantic_sil.*`, with elapsed time in the performance trace. The trace
also includes CLI input preparation and required Catalog loading. Nested timing
spans overlap; adding every stage duration is not total wall time. Invalid
capture/context prevents compiler work. Final receipt assembly still stops at
its first failure; diagnosis does not promise every violation from malformed input.

Diagnosis reads needed existing validated Catalogs and reports missing production
coverage without starting cold Catalog generation or background prewarm. It
bypasses complete module-receipt cache hits so current checks run, but can reuse
and retain individually validated compiler checkpoints. Partial SIL facts are
never cached as a successful SIL stage. It does not publish a module receipt,
Shell, Bridge, prepared state, or Hub reservation. Linking, service connection,
and runtime activation require normal Build/Run.

## Mixed configuration regression

[`Tests/Fixtures/MixedOnboarding`](../Tests/Fixtures/MixedOnboarding/README.md)
contains a small real Xcode App with two `@TaskLocal` expansions, same-named local
protocol conformers, classes/structs inheriting `fileprivate extension` access,
`?? { ... }()` closures, and qualified/unqualified SDK names. It includes UIKit's
nested `NS_SWIFT_NAME` reference `UIPencilInteraction.Tap` (iOS 17.5),
Foundation/UIKit/AVFoundation/Photos,
an Objective-C bridging header, C++ interop, `-g`, and explicit modules enabled
in project settings. Its opt-in test performs a native Xcode compile/link,
captures all five Swift files, installs twice, checks PBX syntax with `plutil`,
loads the installed project with `xcodebuild -list`, then runs selected nominal
checks and full receipt diagnosis, including independent SIL and mapping checks.
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
| Native API Catalog | 250,000 entries and 128 MiB encoded document per module; one-to-eight frontend probe workers per producer, coordinated with CLI module workers, in batches of 256 candidates |
| Explicit NativeImport policy | Separate from module Catalogs: 1,024 types, 4,096 candidates, 8 MiB document |
| Host Plan | 128 features, 256 profiles, 1 MiB document |
| Receipt/cache | Shell receipt 32 MiB; module frontend cache payload 64 MiB; compiler checkpoint 256 MiB per stage; oversized cache payloads bypass storage |

Source headers and generated caches should live in separate trees: bridging
header input capture conservatively fingerprints neighboring compiler interface
files, so placing a module cache below that source directory expands the input
set and can disable reuse. Inspect `frontend_cache.compiler_inputs_incomplete_count`
before interpreting a repeated build as a cache performance result.

There is no hard host-process RSS budget or aggregate cache disk quota. AST/SIL
outputs and parsed structures are materialized in memory. The CLI coordinates
module and probe workers using CPU and physical-memory estimates; it is not a
cross-process machine-wide semaphore. Remaining failed checkpoints
can retain disk space; stop users of a private cache before resetting it.
Physical-device native activation, the commercial project's save-to-screen
latency, and its complete cold Catalog cost still need corresponding project
measurements. Host cross-compilation alone does not qualify those paths.

Hub preserves an authored feature indexing policy and the existing device qualification flag when loading and reapplying a project. Workflows sharing a source target inherit an unspecified policy; conflicting explicit policies are rejected with profile, target, project, and value evidence.

## Preflight before a successful build

The proxy atomically writes a private `FrontendAttempt.hlxswiftc` beside
`FrontendInvocation.hlxswiftc` **before** invoking the compiler. Discovery calls
do not create an attempt. Failure preserves the last successful record and
never invokes the post-compile hook. Each invocation retains its own private
record until it exits, so a concurrent attempt cannot be promoted as its success.
The capture byte format remains `HLX.SwiftInvocation.v1`; the new filename is
explicitly diagnostic input, not proof of a successful build.

```sh
helix xcode preflight --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/DerivedData/Build/Intermediates.noindex/Example.build/Debug-iphonesimulator/Example.build/Helix/FrontendAttempt.hlxswiftc \
  --stages inputs --json
```

Omitting `--stages` runs `inputs,typed-ast,catalogs`. The default checks fingerprint
compiler inputs before AST work, then inventory module/Catalog availability.
Unresolved modules fail with provenance; pending cache entries are reported and
do not claim API coverage. Explicit `--stages inputs` retains the lightweight behavior. Use `source-mappings` to include SIL
identity diagnosis and declaration exclusions. `inputs` validates the selected
compiler/SDK, invocation, source inventory and source bytes; it does not
fingerprint the dependency cache or emit AST/SIL. A pass is not type-check or
runtime coverage. Typed checks still require generated dependency modules,
headers and plugins. Xcode must have reached the target compiler proxy at least
once; this is not a replacement for generating its build arguments.

`post-compile --diagnose` also accepts attempt records; normal `post-compile`
rejects them. Preflight publishes no receipt, Shell, Bridge, Prepare state or
Hub reservation. The mixed fixture replays real captured arguments with a
compiler error, then verifies that input preflight passes, typed preflight
reports the error, and the successful record is unchanged.

SIL metadata scans now filter record prefixes before allocation, scan comment
boundaries by UTF-8 delimiters, and avoid decoding unescaped paths. Scope
inheritance uses iterative traversal and memoizes absent locations. Both SIL
purposes reuse the selected AST member inventory for bounded symbol classification.
See [the measured parser comparison](Build-Performance-Baseline.md#sil-debug-metadata-scanning)
for its limited measurement scope. Whole-module compiler input invalidation
remains required; per-file WMO reuse and concurrent identity/semantic SIL emission for one source module are
not claimed.

## Team runtime selection and removal

Host Plan schema 2 accepts an optional top-level `runtimePackageRequirement`:

```json
"runtimePackageRequirement": {
  "kind": "revision",
  "value": "<your tested 40-character lowercase commit>"
}
```

Replace the placeholder with a verified commit. `kind: "exactVersion"` accepts
a canonical `major.minor.patch` release version; use a full commit for a
prerelease or other tag. Xcode resolves the reference. Helix validates the shape
and writes the requirement but does not assert the revision exists or certify
the tool/runtime pair. Select and qualify that pair in the team's release process.

The installer reuses a matching existing remote reference and may update a
Helix-owned reference. A conflicting user-owned reference, local package under
an explicit remote pin, or multiple runtime package authorities rejects before
publication and includes package IDs, repository/path and requirement facts.
Hub preserves the requirement through load, edit and reapply. Schema 1 plans
cannot carry this field; their old bytes remain readable.

Omitting the field preserves an existing package requirement. A **new remote
reference** uses the published runtime revision
`df420536312358631c1278d6b3b274e2fda64ddd`, declared by
`XcodeIntegration.RuntimePackageRequirement.defaultRuntime`. This behavior also
applies to legacy plans that create a new reference; it does not silently repin
an existing branch or override a local package. The baseline must be advanced
deliberately with runtime compatibility and package tests. To track a branch,
explicitly use `{"kind":"branch","value":"main"}` in schema 2. Older tools
reject this new enum case; revision/exactVersion plans remain source compatible.
Team plans can select their qualified revision/version explicitly and should
retain Xcode's package resolution file in version control.

Remove an installation without the Hub GUI:

```sh
cp .helix/xcode/HostPlan.json HelixRemovalPlan.json
helix xcode uninstall --project Example.xcodeproj --plan HelixRemovalPlan.json --json
```

A backup must match the current installed plan when that file exists. The
backup also supports repeated removal/recovery after generated files are gone.
The CLI uses Hub's existing transactional ownership cleanup and minimal PBX
edits, restores original configuration references, and preserves application
source, user-owned package references, developer files and signing material.
Removal does not need a successful build, Catalog, recipe or signing key.
A damaged ownership manifest still prevents broad generated-file deletion;
unknown files remain. This command changes the selected project, not GUI
registration records. The mixed Xcode fixture validates project loading and a
real build after removal; physical-device runtime behavior is outside that check.

Portable Catalog import/export and a shared writable cache protocol are still
unsupported. A future bundle must validate both Catalog and compiler projection
against exact compiler, SDK, dependency and artifact identities. The current
owner-private cache must not be advertised as cross-machine-compatible by copying it.

Installation and both removal APIs hold a nonblocking advisory lock on the
canonical `.xcodeproj` directory for the complete read/validate/write operation.
Competing Helix operations on the same project reject before mutation; different
projects remain independent. Locking the directory survives atomic PBX file
replacement and creates no generated lock artifact. This coordinates Helix
operations, not external editors or Git commands that do not take the lock.

## Bootstrap Catalogs from a compiler capture

A successful Prepare is no longer required to create a Catalog job. After Xcode
has built the external dependencies and captured a compiler invocation, run:

```sh
helix xcode catalog-prewarm --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/path/to/Helix/FrontendAttempt.hlxswiftc --plan-only --json
helix xcode catalog-prewarm --plan .helix/xcode/HostPlan.json --profile live \
  --capture /absolute/path/to/Helix/FrontendAttempt.hlxswiftc --max-modules 1
```

Both `FrontendAttempt.hlxswiftc` and `FrontendInvocation.hlxswiftc` are accepted
at their original DerivedData location. Planning reads sources for imports and
validates the captured compiler, SDK and dependency fingerprints; it does not
run the consumer's AST/SIL, create a Shell, or register a live session. The first
command writes a private resumable job and returns schema 1 JSON containing
`cachedModules`, `pendingModules`, `unresolvedModules`, `unresolvedReasons`, and
`jobPath`. `--json` requires `--plan-only`. Without `--plan-only`, cold generation
runs in the foreground with the same 1...256 cold-attempt budget as `--job`. Cache hits
do not consume that budget. Jobs can be resumed from any current directory;
compiler and Symbol Graph processes use the job's validated working directory.
Changing dependency bytes invalidates the job and requires a fresh plan.

`unresolvedModules` means a fingerprint prerequisite is incomplete, not a cache
miss. Reasons include malformed source imports, unsupported directory symlinks,
unreadable/unstable files and traversal limits, with source/input paths. Fix the
reported prerequisite before retrying; Helix does not waive it to populate the
cache. Human output samples at most 20 modules and eight distinct reasons; JSON
retains all reasons. Planning exits 1 if any modules remain unresolved. Normal
Prepare schedules available misses before frontend generation; prewarm failure
does not authorize a partial production capability surface. Cold compilation
still costs time, and this path makes it independently schedulable rather than
eliminating that cost. Existing owner-local cache sharing rules still apply;
copying an unverified job from another machine is not a team-cache protocol.

New live registrations also [guard excluded file saves](Development-Live-Reload.md#saving-code-excluded-from-indexing).
A file containing an unresolved declaration or lying outside the configured
indexing scope requires normal Build/Run when edited, even if that file still
contains other indexed functions. Repeated edits cannot silently become
“no semantic change.” Full stage failure details remain available in diagnosis
JSON; terminal output limits each check's detail to 4 KiB.

Keep compiler-proxy and driver settings on the opted-in target/configuration.
Global `xcodebuild SWIFT_USE_INTEGRATED_DRIVER=NO` overrides also affect package
targets; the Xcode 26.6 fixture reproduced missing `-package-name` diagnostics in
package-access declarations under that setup. The mixed fixture now scopes these
probes to the App, preserving dependency packages' normal driver settings.

### Compiler input and C-member regressions

The large-project regression suite checks inflated Xcode header-map counts against real Clang, keyword member import scanning, CoreGraphics/CoreFoundation parameter identity, C import-as-member with a middle receiver, ambiguous repeated receiver types, and projection version compatibility. These are compiler integration checks on the installed SDK, not commercial-app or device activation acceptance. The C member contract and conservative exclusions are detailed in [Native Calls](Native-Calls.md#c-member-argument-order-and-projection-compatibility).

## Bounded prewarm and module outcomes

Use `--jobs 1...8` in capture-driven or `--job` execution to cap concurrent
modules (default four). The effective compiler budget is capped by active CPUs,
eight workers, and a heuristic reserving 4 GiB then allowing 2 GiB per compiler,
with a minimum of one. Each wave shares that budget between its modules' probe
workers. It controls one CLI invocation, not all Helix processes or peak RSS.

A failed module no longer aborts independent modules. The worker saves a private,
atomically replaced schema 1 report at
`<cache-root>/PrewarmReports/<job-SHA256>.json` after each wave. It records the
budget, completion/pause state, module status (`pending`, `cached`, `generated`,
`failed`, `unresolved`), elapsed microseconds, candidate/entry/probe counts, cache
hits/misses, and rejection/failure reasons. `--job ... --json` emits that report.
Malformed diagnostic JSON is rebuilt; symlinks or unsafe file permissions are
rejected. Reports are advisory retry state, never Catalog authority.

Failed/unresolved runs return nonzero and retain the job; a budget-only pause
returns zero and retains it. Previously failed modules follow unattempted work
on the next run. Completed artifacts are revalidated, including roots that were
already cached when the job was created. Compiler/SDK/input changes require a
fresh job. An invalid Symbol Graph never becomes a fabricated empty Catalog.
Closure discovery remains bounded at 256 modules; team-portable Catalog bundles
and commercial-project/device activation qualification are not added here.
