# Build Performance Observability and Baseline

[简体中文](Build-Performance-Baseline.zh-CN.md)

This document records an executable performance baseline for Helix's Xcode-side build work. It is intended to show where time is actually spent and whether later optimizations preserve native-call coverage while reducing Live Reload and Hot Patch build cost.

## Observation boundary

The Xcode integration writes local reports under the active profile's DerivedData output:

```text
HelixGenerated/<profile>/BuildPerformance.prepare.json
HelixGenerated/<profile>/BuildPerformance.bridge.json
HelixGenerated/<profile>/BuildPerformance.finalize.json
HelixGenerated/<profile>/BuildPerformance.patch.json
```

Schema 1 records the operation, workflow and outcome; monotonic total and named-stage durations; aggregated Swift frontend subprocess purpose, executable basename, count, failures, duration and output sizes; relevant source/API/probe/function/NativeImport counters; and relative artifact paths and sizes.

Stages may be nested. For example, `prepare.frontend_receipt` contains several `frontend.*` stages, so all stage durations must not be added together. Subprocess records never contain full arguments, source paths, SDK paths, or signing material.

The reports are local diagnostics only. Neither their bytes nor their measured values enter HLBC, HLXI, `.hlxp`, signing inputs, Shell hashes, Release baseline identity, or the App bundle. They therefore do not change a product protocol version or make product artifacts nondeterministic. If a successful build operation cannot publish its report, that operation fails. If the original operation fails, Helix best-effort publishes a partial `outcome = failure` report while preserving the original error.

## Demo baseline on August 26, 2026

Measurements used the `Helix Live Reload Demo` Debug scheme, a generic iOS Simulator destination, and isolated DerivedData. Available disk space was tight during the run, so these numbers identify order of magnitude and proportions rather than promising results across machines.

| Scenario | Before telemetry | With telemetry | Interpretation |
| --- | ---: | ---: | --- |
| Cold build with new DerivedData | 55.73 s | 61.72 s | Cold results vary with SwiftPM/Xcode caches and disk pressure |
| Immediate unchanged rebuild in the same DerivedData | 39.13 s | 39.10 s | No visible incremental-build regression from telemetry |

The successful unchanged rebuild reported these Helix stages:

| Stage | Duration | Share of Prepare |
| --- | ---: | ---: |
| total `prepare` | 29.144 s | 100% |
| `prepare.frontend_receipt` | 28.111 s | 96.5% |
| `frontend.expand_managed_debug_surface` | 24.688 s | 84.7% |
| `prepare.materialize_shell` | 0.911 s | 3.1% |
| `prepare.publish_artifacts` | 0.037 s | 0.1% |
| total `bridge` | 4.692 s | — |
| `bridge.compile_swift` | 4.645 s | 99.0% of Bridge |

The table preserves the metric name emitted by that historical run. The same
stage is now named `frontend.expand_managed_native_surface` because Release and
development use the shared measured surface with different publication policy.

A representative cold Prepare trace exposed the call volume behind those totals:

- one UIKit symbol-graph extraction took about 14.74 seconds;
- 800 public candidates became 96 probe batches and 469 measured operations;
- 56 of 97 Typed AST invocations were expected probe rejections, not build failures;
- 42 canonical SIL invocations ran;
- SDK path and SDK build were each queried 140 times, for 280 repeated `xcrun` calls;
- the Shell emitted 476 NativeImports and 24 native types;
- the Shell occupied about 3.6 MiB. Its receipt was about 1.05 MiB, the NativeImport Swift shard about 0.97 MiB, and the main Bridge Swift file about 0.83 MiB. Bridge compiled five files totaling about 1.87 MiB into an object of about 4.40 MiB.

## Stage 1 measured result

The first optimization stage kept the same Demo source and full native-import
discovery policy while adding exact reusable facts and content-aware
publication. These are local single-run measurements, not cross-machine or P95
claims:

| Workflow | Priming build | Immediate unchanged build | Result |
| --- | ---: | ---: | --- |
| Live Reload Debug | 42.38 s | 12.15 s | Prepare fell from its pre-optimization 29.144 s baseline to 1.252 s; frontend receipt fell from 28.111 s to 0.237 s |
| Hot Patch Release | 62.51 s | 8.26 s | Prepare state hit took 0.154 s and Bridge state hit took 0.343 s |

The optimized Live Reload frontend key inspected five direct non-SDK inputs
totalling 533 bytes instead of sweeping unrelated products in Xcode search
roots. The unchanged run performed no Typed AST, SIL, or symbol-graph work.
Live Reload still obtains a fresh single-use Hub reservation, so its
session-bound development-contract source changes between builds. The current
pre-invoker Bridge therefore still compiled five files (about 1.96 MiB) in
5.196 s; content-aware publication nevertheless reused 15 unchanged files and
wrote only three session-bound files. In Hot Patch, where the inputs are stable,
the repeated run performed neither frontend generation nor Swift/C Bridge
compilation. Both fast paths revalidated their complete output manifests before
returning.

## Confirmed bottlenecks and stage conclusion

The evidence says file publication is not the main cost, and reducing API coverage is not the right remedy:

1. Every Prepare rebuilds the same managed SDK surface through symbol-graph extraction, candidate generation, recursive probe bisection, and repeated SDK identity queries.
2. An unchanged build still regenerates about 3.6 MiB of Shell output and recompiles about 1.87 MiB of Bridge source.
3. Hot Patch and Live Reload repeatedly acquire equivalent toolchain, SDK, frontend, and archive facts. They need shared content-addressed facts rather than separate heuristic fast paths.

Stage 1 now keeps toolchain, SDK build, target, minimum OS, semantic arguments,
input hashes, and generator versions in the relevant cache keys; reuses only
validated deterministic facts and artifacts; fully falls back to the
authoritative frontend on a miss; and avoids rewriting byte-identical output.
The transformation fingerprint also covers generated interface and native-call
descriptor semantics, so a tool update invalidates obsolete local facts without
requiring the developer to clear DerivedData or change a protocol version.
The optimization does not lower the target coverage of future native calls.

The remaining structural cost is generated-call-surface size: a Live Reload
session can still change its Bridge input, while a large fixed Swift wrapper
set is expensive on a true miss. Later descriptor-driven Objective-C/C
invokers and cached Swift adapter packs address that cost without reviving a
manual API allowlist.

## Stage 3 measured result

The generic Objective-C execution stage was measured with the real eight-
generation Live Reload Demo flow. It exercised view hierarchy changes, button
configuration, animation completion, presentation, dismissal, and baseline
restoration in one simulator process. The generated Shell contained 479 native
imports: 388 used the shared Objective-C invoker, 87 retained exact generated
Swift adapters, and four used built-in factories.

The result proves that supported Objective-C selectors no longer add one Swift
invocation body each. It also exposes the next structural cost rather than
hiding it:

| Measured item | Result |
| --- | ---: |
| Cold Prepare after descriptor-cache invalidation | 27.320 s |
| Managed Debug expansion within cold Prepare | 21.020 s |
| Bridge total on that build | 13.844 s |
| Swift compilation within Bridge | 13.017 s |
| Immediate unchanged Prepare in the same Hub session | 2.085 s |
| Immediate unchanged Bridge | 13.779 s |
| Generated Swift source | 3,164,111 bytes |
| Main Bridge file | 2,825,004 bytes |
| NativeImport shards | about 202 KiB |

The warm Prepare performed no Typed AST, SIL, or symbol-graph work; frontend
lookup took 0.286 s and materialization took 1.626 s. Bridge still missed its
state and recompiled the source because a fresh Live Reload session contract
changed on each build. Most source bytes now come from verbose descriptor
literals in the main Bridge file, not selector-specific executable wrappers.
Consequently, this stage improved execution architecture and kept coverage,
but did not claim the final no-change latency target. Stage 4 below separates
the stable Bridge and Adapter Pack objects from the single-use Hub contract.

## Stage 4 measured result

The restricted C invoker and Swift Adapter Pack stage was validated with the
same real Simulator Demo. Its behavior-neutral probes force both non-
Objective-C paths: `CACurrentMediaTime()` uses the common C invoker, while two
Foundation value-overlay operations form one two-entry Foundation Adapter
Pack. The resulting Shell reported 383 Objective-C invoker entries, one C
invoker entry, 84 application adapters, and one reusable Adapter Pack.

The first Bridge build used a new transform identity and therefore populated
both object caches:

| First Bridge item | Result |
| --- | ---: |
| Bridge total | 17.044 s |
| Stable application Swift compilation | 15.360 s |
| Application Bridge object | 6,978,432 bytes |
| Foundation Adapter Pack object | 22,008 bytes |
| Session Hub contract compilation | 0.336 s |
| Final relocatable link | 0.170 s |

An immediate unchanged Xcode build acquired a fresh one-time Hub invitation,
so the exact final Bridge state correctly missed. The stable pieces did not
recompile:

| Repeated Bridge item | Result |
| --- | ---: |
| Bridge total | 1.353 s |
| Application object cache | hit |
| Adapter Pack object cache | hit |
| `bridge.compile_application_swift` | absent |
| Session Hub contract compilation | 0.364 s |
| Final relocatable link | 0.064 s |
| Warm Prepare | 2.366 s |

This removes 15.360 seconds from the repeated Bridge on the measured machine,
without reusing an old pairing invitation or reducing the discovered API
surface. The session contract is compiled as a separate small object and then
linked with the validated stable application object and module Pack objects.
The final state identity still covers every generated source, Pack key,
compiler input, module map, toolchain, SDK, Clang binary, and bootstrap source;
only the independently safe intermediate objects are reused.

The remaining measured Bridge costs are import scanning (0.348 s), the small
Hub-contract Swift compile (0.364 s), and toolchain/Pack planning. These are
now bounded secondary costs rather than a reason to enumerate fewer SDK APIs.
All cache and report schemas remain version 1.

## Stage 5 Catalog-first steady-state evidence

The final Catalog-first integration was measured again on August 28, 2026 with
the real arm64 iPhone 17 Simulator destination. After background prewarm had
published the complete two-module, 4,609-entry capability surface, the first
build using the new transform identity populated current Shell and object
facts. Prepare reported 15.505 seconds, including 1.905 seconds to read and
validate Catalogs, 4.691 seconds for the application frontend, and 7.834
seconds to materialize the compact Shell. Bridge reported 1.961 seconds,
including 0.784 seconds for the application Swift object and 0.370 seconds for
two Adapter Pack objects. The immediately unchanged build represented the
stable state:

| Stable Live Reload item | Result |
| --- | ---: |
| Xcode build wall time | about 14.3 s |
| Prepare total | 0.179 s |
| Prepare state | hit |
| Catalog read / application frontend / Shell materialization | absent |
| Bridge total | 0.421 s |
| Bridge state | hit |
| Application and Adapter Pack compilation | absent |

The unconsumed one-time Hub reservation was safely reused by the exact state
hit; after consumption or any semantic input change, the normal session-bound
path runs again. A real Swift-6 Demo prewarm produced an approximately 8.1 MiB
UIKit Catalog. Replaying the exact same canonical job from the user cache
completed in 1.911 seconds, including full payload and projection validation.
These are single local observations, not P95 claims, but they demonstrate that
the minute-scale SDK scan is outside the unchanged Xcode latency path.

## Module Catalog cold-generation evidence

The module-level Catalog producer was exercised against the installed UIKit
from the iPhone Simulator SDK, not only a synthetic fixture. Its opt-in
integration test starts with an empty private cache and requires the resulting
Catalog to contain the exact Objective-C entries for
`UIView.backgroundColor`, `UIViewController.present`, and `UIView.animate`,
plus the exact MainActor Swift Adapter for
`UIActivityViewController.init(activityItems:applicationActivities:)`. The
latest successful cold run on August 28, 2026 took 229.653 seconds; the earlier
August 27 run took 195.123 seconds before the additional assertion. This is
evidence of correct whole-SDK coverage and of a substantial cold indexing cost;
it is not an acceptable per-Prepare latency and is not represented as one.

An earlier sequential run was stopped after roughly five minutes. Bounded
four-worker scheduling raised observed test-process CPU utilization from about
14% to about 95% while its sampled memory share remained around 2%. Process
snapshots during the successful run showed no more than four frontend children.
A default
260-API regression crosses the 256-candidate batch boundary, builds the same
module into two independent cold caches, and requires byte-identical Catalog
documents; it completed in 2.503 seconds in the recorded run.

The UIKit test also exposed two correctness boundaries that small fixtures had
missed: distinct overlay types can share one generic Swift SIL implementation,
and a module graph can surface protocol defaults owned by another module. The
Catalog now keeps the former distinct using owner/USR/signature evidence and
omits the latter from the wrong module. These fixes preserve fail-closed source
discovery and do not broaden Objective-C/C module authority. The Swift-6 Demo
additionally proved that SDK subclasses may inherit MainActor without repeating
the attribute in their Symbol Graph row, and that a legacy imported global may
be diagnosed as concurrency-unsafe shared mutable state. The former is measured
with inherited actor authority; the latter is rejected as one deterministic
candidate instead of aborting the module.

The product conclusion is therefore explicit: full SDK Catalog generation is
one-time background work keyed by SDK/module identity. Catalog-first Prepare
must consume a validated hit or perform a small source-demanded query; it must
never put this roughly 230-second scan back onto every local build. Schema, protocol,
artifact, and product versions remain 1.

## Final Hot Patch Release evidence

The final implementation was also exercised end to end on August 28, 2026
against the checked-in Release Demo and the same arm64 iPhone 17 Simulator. Its
published schema-1 capability manifest contained 3,657 entries. After the new
transform identity had populated its cold facts, an unchanged Release build
reported a 0.406-second Prepare state hit and a 2.824-second Bridge state hit;
the complete Xcode invocation took 20.83 seconds on a machine with only about
469 MiB of free disk space. Bridge performed no Swift compilation on that hit.

Changing the one marked pricing body produced, signed, verified, and staged a
one-entry patch in 19.101 seconds. The installed Release App then changed the
observed delivery fee from `¥19.99` to `¥0.00` at generation 1 and restored the
audited original after rollback. This verifies that the compact Catalog-backed
manifest, generic invokers, generated Swift Adapter Pack, patch compiler, and
runtime activation path agree on the current schema-1 contract; it is a local
functional measurement, not a cross-machine latency promise.

## 2026-09-05 large-module indexing

The integration report prompted a synthetic 2,500-file, single-module benchmark.
It contains 2,500 public scalar functions and 147,780 source bytes, with no
external imports. Helix was a Debug test build on arm64 macOS, using Apple Swift
6.3.3, Simulator SDK build `23F81a`, and target
`arm64-apple-ios15.0-simulator`. Each case ran once, without concurrent builds.
Toolchain discovery and fixture creation are outside the timed receipt operation.
The cold case starts with an empty Helix fixture cache, while system compiler
caches can already be warm.

The comparison below isolates SIL resolver reuse: both versions already contain
the large-argument replay and file-scoped identity fixes. CPU sampling found that
source declaration indexing rebuilt the entire module's symbol/location maps
and resolved filesystem paths for every declaration. The adapter now builds one
immutable resolver per SIL module, reuses it for functions, properties, and
observers, and canonicalizes each distinct source path once during construction.
`frontend.index_sil_functions` records that separate construction stage.

| Receipt operation | Before resolver reuse | After resolver reuse |
| --- | ---: | ---: |
| Cold receipt | 99.020 s | 12.884 s |
| Unchanged receipt cache hit | 0.829 s | 0.828 s |
| One function-body edit, receipt miss | 100.116 s | 12.806 s |
| Cold source-declaration indexing substage | 86.598 s | 0.439 s |

The new resolver construction took 0.036 s. The unchanged hit launched zero
compiler subprocesses; each miss launched seven measured subprocesses and still
indexed all 2,500 declarations. The receipt was about 7.04 MB. The regression
checks hit/miss behavior, unchanged receipt equality, body-change invalidation,
and stable root symbols. Existing negative tests retain ambiguous-location
rejection. The [reproducible fixture](../Tests/HelixBuildToolsTests/BuildToolsTests.LargeModulePerformance.swift)
can export the exact toolchain and per-stage/subprocess trace with
`HELIX_LARGE_MODULE_REPORT`; intermediate measurement files are not repository artifacts.

Reproduce at large scale from the repository root:

```sh
HELIX_LARGE_MODULE_SOURCE_COUNT=2500 \
HELIX_LARGE_MODULE_REPORT=/tmp/helix-large-module.json \
swift test --scratch-path .build/validation --filter LargeModulePerformance
```

The regular suite uses 32 files; the explicit benchmark accepts 2 through 5,000.
These results measure frontend receipt generation, not full Xcode Prepare,
Bridge compilation, or save-to-device activation/UI latency. A 148 KB scalar
fixture does not model the reported commercial module's business complexity,
100 native imports, or 240 MB of compiler inputs. The report's 405.3-second failed
cold Prepare and roughly 89-second typed AST are external observations, not
before/after measurements of this fixture. Commercial-project steady saves and
its complete cold Catalog closure still need measurement in that project.
The supported pause/resume and local-cache prewarming workflow is documented in
[Incremental build facts](Incremental-Build-Facts.md#search-paths-and-resumable-catalog-prewarm).

The subsequent parser optimization reuses the declaration inventory across
closed-dispatch rewriting and compiles the five fixed declaration expressions
once. Repeating the same 2,500-file fixture with the same toolchain produced
10.144 s for cold receipt generation, 10.093 s after a body edit, and 0.843 s for
an unchanged hit. Identity and semantic SIL parsing each took about 1.93 s,
compared with about 3.30 s above. This is another single-run Debug-build
observation within the same receipt-only measurement boundary. Factory-body
replacement and concurrent modules are covered by `CompilerTests.ModuleParsing`.

## Large dependency input planning

The 2026-09-05 planning fixture creates 100 framework directories with 20 headers
and one module map each: 2,100 input files, 4,137,190 bytes. With a Debug Helix
build on the same machine, planning those 100 module identities took 14.034 s
before directory-inventory reuse and path-filter optimization, and 2.560 s after.
All 100 module content hashes matched across the two runs. Each planned identity
also matched a fresh independent capture in the regression test.

The measurement includes Catalog input planning only. Fixture creation, the
initial aggregate capture, and reference checks are outside the timed operation;
it does not compile dependencies or generate their API Catalogs. These are
single-run observations, not a benchmark of the commercial project's complete
240 MB input set. Directory creation/removal, nested changes, permission changes,
directory links, content edits, and retention limits have dedicated regressions.

```sh
HELIX_DEPENDENCY_MODULE_COUNT=100 \
HELIX_DEPENDENCY_PLANNING_REPORT=/tmp/helix-dependency-planning.json \
swift test --scratch-path .build/validation --filter DependencyPlanning
```

The regular suite uses eight modules; explicit measurements accept 1 through 256.
The fixture is maintained in
[BuildToolsTests.DependencyPlanning](../Tests/HelixBuildToolsTests/BuildToolsTests.DependencyPlanning.swift).

## Recoverable compiler stages

The same 2,500-file scalar fixture was rerun after introducing validated compiler
checkpoints. On this host, cold receipt generation took 10.532 s, an unchanged
receipt hit 0.892 s, and a body-edit miss 10.577 s. Each miss recorded six
subprocesses and retired all three intermediate payloads after receipt storage;
the unchanged hit launched none. This single observation is close to the earlier
10.144/0.843/10.093 s parser baseline; checkpoints primarily reduce failed-run
retries rather than cold compiler work.

`BuildToolsTests.CompilerCheckpoints` runs a real compiler through all three
stages, deliberately fails later on a source/native codec conflict, corrects
only that configuration, and requires three checkpoint hits with no repeated
AST/SIL emission. Its recovered receipt must equal a full uncached receipt.
Input changes, malformed output, corrupt data, locked entries and symlinks have
separate regression coverage. These observations do not measure the commercial
project's approximately 380-second failed Prepare.

## Mixed system-framework integration

On September 5, 2026, the system-framework fixture compiled and produced a valid
receipt with Foundation, UIKit, AVFoundation and Photos in one module. It combines
qualified/unqualified `Progress`, an Objective-C bridging header, C++ interoperability
with `gnu++20`, the `@TaskLocal` macro, implicit dynamic replacement, and an initial
driver build using explicit modules. Target: `arm64-apple-ios15.0-simulator`,
iPhone Simulator SDK build `23F81a`, Swift 6.3.3. Each measurement starts with an
empty private Helix cache; it does not clear system or toolchain caches.

| Source files | Source bytes | Initial explicit-module build | Cold receipt | Unchanged receipt hit |
| --- | --- | --- | --- | --- |
| 32 | 4,014 | 7.118 s | 16.956 s | 0.016 s |
| 2,500 | 280,628 | 7.385 s | 30.010 s | 0.924 s |

Both runs require byte-equivalent warm receipts and no warm compiler subprocesses.
The larger run records 2,504 declarations, six native types, four native imports,
three generated/retired checkpoints, and four declaration-module symbol graphs.
These are source-demanded SDK queries, not four complete Native API Catalogs.
They do not measure 100-module cold prewarm, commercial save-to-screen latency,
Bridge linking, or device activation.

This fixture found an additional replay bug: with a bridging-PCH job, Swift
driver writes `-o -` SIL to stderr. The driver now reads an explicit private SIL
file and validates its canonical header before analysis. The mixed-language
regression covers both SIL entry points; missing output fails immediately.

```sh
HELIX_SYSTEM_FRAMEWORK_SOURCE_COUNT=2500 \
HELIX_SYSTEM_FRAMEWORK_REPORT=/tmp/helix-system-frameworks.json \
swift test --scratch-path .build/validation --no-parallel --filter SystemFrameworkIntegrationTests
```

The regular suite uses eight sources; measurements accept 2 through 2,500.
The JSON retains SDK/toolchain identity, target, timings and the cold trace.
See [Large-project integration](Large-Project-Integration.md) for the installation
and compiler-wrapper contracts and the current resource bounds.
