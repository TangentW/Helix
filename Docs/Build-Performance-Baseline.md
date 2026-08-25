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

## Confirmed bottlenecks and next gates

The evidence says file publication is not the main cost, and reducing API coverage is not the right remedy:

1. Every Prepare rebuilds the same managed SDK surface through symbol-graph extraction, candidate generation, recursive probe bisection, and repeated SDK identity queries.
2. An unchanged build still regenerates about 3.6 MiB of Shell output and recompiles about 1.87 MiB of Bridge source.
3. Hot Patch and Live Reload repeatedly acquire equivalent toolchain, SDK, frontend, and archive facts. They need shared content-addressed facts rather than separate heuristic fast paths.

The next stage must keep toolchain, SDK build, target, minimum OS, semantic arguments, input hashes, and generator versions in every cache key; reuse only deterministic facts and artifacts; fully fall back to the authoritative frontend on a miss; avoid rewriting byte-identical output; and prove the result with these reports, the full test suite, and a real Demo build.

The next priorities are therefore SDK identity, symbol-graph and probe-result reuse, a content-fingerprinted Prepare fast return, and content-aware publication. None of these lowers the target coverage of future native calls.
