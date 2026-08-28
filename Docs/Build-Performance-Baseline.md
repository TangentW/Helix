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
