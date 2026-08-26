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
Consequently, this stage improves execution architecture and keeps coverage,
but does not claim the final no-change latency target. Compact descriptor
tables, reuse of a still-valid Hub reservation, and stable Adapter Pack inputs
remain required in the later Live Reload stage.
