# Capabilities and Limits

[简体中文](Capabilities-and-Limits.zh-CN.md)

Helix is intentionally fail-closed. “The Swift compiler accepts this file” is
not the same as “the production bytecode backend supports this construct,” and
“a dylib could theoretically contain this declaration” is not the same as “the
current Live Reload generator collects it.” This document states the current
practical boundary.

## Product status at a glance

| Area | Implemented | Not yet qualified or implemented |
| --- | --- | --- |
| Release Shell | Exact frontend indexing, Derived Sources, interface archive, permanent bridge, NativeImport discovery, Xcode integration, bundle leakage audit | Broad real-application migration and long-running CI matrix |
| Production HLBC | HLBC 1.9 / HLXI 2.4 compiler path, verifier, HLVM, signed package, safe installation, immutable activation, rollback and revocation | App Store distribution approval, top-200 business corpus, long fuzz/sanitizer campaigns, real-device macro performance |
| Native Live Reload | Exact build capture, stable snapshots, typed-AST body reconstruction, recursion/previous handling, signed dylib, authenticated transfer, `dlopen`, UIKit/SwiftUI refresh | Real-iPhone matrix, 100-generation soak, automatic LLDB symbol loading, large-project latency qualification |
| Development HLBC | Backend routing and session-bound verified HLBC artifacts | The same source coverage as the native compiler; unsupported roots still require a build |
| Control plane | Client-side package and policy contracts | Production Registry, HSM operations, approval, rollout, telemetry, and fleet coordination services |

The checked-in SwiftPM baseline contains 384 tests in 64 suites. Debug,
warnings-as-errors, and optimized Release runs are recorded as passing. An iOS
Simulator target covers 9 runtime and UI cases. Those counts describe repository
evidence, not device or distribution certification.

## Production HLBC 1.9 Swift subset

### Implemented

- `Bool`, signed and unsigned fixed-width integers, `Float`, and `Double`, with
  the documented arithmetic, bitwise, comparison, shift, and supported numeric
  conversion rules.
- `String` literals, concatenation, interpolation for supported scalar values,
  count/empty checks, comparisons, and common prefix/suffix/contains predicates.
- Tuple, `Void`, and `Optional`, including the ordinary control flow produced by
  `if let`, `guard let`, `??`, and `try?`.
- Array value semantics, append, iteration, checked subscript access, and
  value-returning updates; Dictionary construction, lookup, update, and
  iteration for supported key and value types.
- Structured branches, loops, switches, calls, recursion, checked business
  error edges, and local payload-carrying Error values.
- Patch-local nonrecursive stored struct and enum values, concrete `Result`,
  field extraction, enum switch, and supported mutating helpers. These are VM
  values, not newly loaded Swift metadata.
- Synchronous patch-local `inout` and `mutating` helpers under verified address,
  access, aliasing, ownership, and same-frame/same-block restrictions.
- Synchronous nonescaping patch-local closures with copyable VM-managed
  captures, plus compiler-emitted fully concrete specializations that contain
  no remaining archetype, metadata, or witness dependency.
- Top-level non-suspending `async`, `async throws`, and `@MainActor async`
  entries. Exact generated Swift wrappers preserve their ABI while HLVM runs a
  body proven not to suspend.
- Calls to same-image helpers, eligible Shell entries, and exact allowlisted
  NativeImports already emitted in the target Shell.

### Rejected or intentionally incomplete

- Generic roots or any execution that still requires runtime generic metadata,
  witness tables, reabstraction, or dynamic specialization.
- True suspension: `await`, continuations, tasks, async callees, async closures,
  cancellation, and cross-suspension ownership or generation leases.
- Actor-isolated instance roots, custom global actors, and arbitrary executor
  hops. The limited `@MainActor async` leaf case above is distinct.
- Escaping, throwing, async, nested-capture, or native-boundary closures.
- New native classes, new Swift metadata visible across the patch boundary,
  retroactive conformances, layout changes, superclass changes, and enum-case
  changes.
- Generic or `inout` Shell entries, noncopyable roots, arbitrary borrowing and
  consuming ABI, typed-throws roots, `rethrows`, and general unwind cleanup.
- Unrestricted pointers, `unsafeBitCast`, arbitrary Objective-C selector/IMP,
  `dlopen`/`dlsym`, Mirror-driven field mutation, and unknown builtins.
- A native call that does not have an exact `NativeImportID` in the released
  Shell, even if a similarly named Swift function exists.

## Native Live Reload boundary

Native Live Reload preserves more Swift semantics because the exact Swift
compiler produces ordinary machine code and metadata. The current generator is
nevertheless scoped to existing declaration bodies.

| Edit | Current result |
| --- | --- |
| Change an indexed global, instance, static, or class function body | Supported on a qualified Native target |
| Call an existing private/internal/public declaration from that body | Supported when it resolves in the captured module and links against the Dev Shell |
| Ordinary direct recursion | Rebound to the current generation by exact typed-AST identity |
| Deliberately call the previous generation | Use the constrained `LiveReload.previous { ... }` marker |
| Add a local helper, closure, or local type inside the changed body | Compiled with that body when valid Swift |
| Add an arbitrary file-level helper/type/extension or a new Swift file | Not collected by the current generator; full build required |
| Change a stored property, signature, generic constraint, actor isolation, superclass, conformance, or enum case | Rejected; full build required |
| Change default-argument behavior | Existing call sites may already contain the old generator; full build is required for a reliable result |
| Change a static/global initializer | Existing initialized state is not replayed automatically |
| Add a framework, package, macro/plugin input, bridging header, or source membership | Dev Build Manifest becomes stale; full build required |
| Edit storyboard, XIB, assets, strings, Core Data model, plist, or entitlements | Outside the Swift-body Live Reload path |

Native replacements can access private members because Helix compiles them with
the original source-file identity using the captured module context. This does
not make arbitrary process symbols callable, and it does not bypass linker,
code-signing, Team ID, AMFI, or library-validation decisions.

Simulator Native is the validated path. Physical-iPhone Native support remains
experimental until each exact compiler, OS, architecture, code-sign identity,
provisioning, Team ID, and dependency combination passes the device matrix.

## UI refresh boundary

Code replacement affects the next function call; UI invalidation determines
whether a user sees that behavior immediately.

- Helix derives controller/view identities from displayed runtime classes and
  automatically matches changed types, including superclass changes; no UIKit
  type registry is required.
- Common rendering and layout callbacks infer constraint, layout, and display
  invalidation and preserve the existing page instance and in-memory state.
- Initialization or application-owned refresh work may use an idempotent
  `LiveReload.Reloadable` hook; it is not routine setup.
- Controller reconstruction requires a registered factory, route context, state
  capture/restore, and container support.
- SwiftUI requires a `liveReloadBoundary`; `invalidateBody` attempts to preserve
  identity, while `recreateSubtree` resets that boundary's local state.
- Helix does not automatically replay `viewDidLoad`, `loadView`, initializers,
  observer registration, subscriptions, or arbitrary lifecycle callbacks.
- If there is no safe target or rule, code can remain active while the result is
  `manualRefreshRequired`.

The checked-in fixtures prove automatic UIKit controller/view and superclass
matching without registration, invalidation, state preservation, SwiftUI pulse
routing, and Debug Overlay behavior. They do not qualify every custom
container, navigation/sheet interaction, observation graph, or long-running
side effect pattern.

## Security and resource boundaries

Production and development fail closed on unknown versions, capabilities,
targets, identities, duplicate records, malformed containers, and resource
limits. Production bytecode has fuel, deadline, stack, register, call-depth,
value-shape, native import, and memory accounting. Downloads and live transfers
are bounded before allocation or execution.

Native Live Reload keeps loaded images mapped and therefore has explicit image
and byte limits. A synchronous Swift NativeImport cannot be forcibly preempted;
only bounded/cooperative imports with deadlines and checkpoints should enter a
production catalog. Real-device tail latency and memory pressure remain gates.

## Compatibility and distribution

The Swift package targets macOS 14 and iOS 15 or newer. A patch is tied to one
finalized Shell interface and target identity; a package for one App build must
not be guessed compatible with another.

The implemented release builder permits internal and enterprise HLBC policies.
The App Store channel remains `policyBlocked`, and the controlled native release
backend is not implemented. Platform policy, signing, and organizational
approval are independent of whether the bytecode engine works technically.

For the surrounding flows, read [Architecture](Architecture.md),
[Production Hot Patching](Production-Hot-Patching.md), and
[Development Live Reload](Development-Live-Reload.md).
