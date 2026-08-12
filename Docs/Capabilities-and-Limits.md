# Capabilities and Limits

[简体中文](Capabilities-and-Limits.zh-CN.md)

Helix is intentionally fail-closed. “The Swift compiler accepts this file” is
not the same as “the bytecode backend supports this construct,” and “the
compiler can emit SIL for this declaration” is not the same as “the current
HLBC lowerer and Shell capability surface support it.” This document states the
current practical boundary.

## Product status at a glance

| Area | Implemented | Not yet qualified or implemented |
| --- | --- | --- |
| Release Shell | Exact frontend indexing, Derived Sources, interface archive, permanent bridge, NativeImport discovery, Xcode integration, bundle leakage audit | Broad real-application migration and long-running CI matrix |
| Production HLBC | HLBC 1.10 / HLXI 2.5 compiler path, verifier, HLVM, signed package, safe installation, immutable activation, rollback and revocation; checked-in business corpus | App Store distribution approval, external top-200 corpus, long fuzz/sanitizer campaigns, real-device macro performance |
| Development Live Reload | Exact build capture, stable snapshots, body diff, session-bound verified HLBC, authenticated transfer, atomic activation, UIKit/SwiftUI refresh, logical source maps and a 128-generation in-process soak | Physical-iPhone matrix, long-duration device soak, interactive bytecode stepping, large-project latency qualification |
| Native experiment | Explicit-only Dynamic Replacement builder, recursion/previous tests, signed dylib and loader probes | Product support; it is intentionally absent from automatic routing |
| Control plane | Client-side package and policy contracts | Production Registry, HSM operations, approval, rollout, telemetry, and fleet coordination services |

The checked-in SwiftPM baseline contains 457 tests in 73 suites. Debug,
warnings-as-errors, and optimized Release runs are recorded as passing. An iOS
Simulator target covers 9 runtime and UI cases. Those counts describe repository
evidence, not device or distribution certification.

## Production HLBC 1.10 Swift subset

### Implemented

- `Bool`, signed and unsigned fixed-width integers, `Float`, and `Double`, with
  the documented arithmetic, bitwise, comparison, shift, and supported numeric
  conversion rules.
- `String` literals, concatenation, interpolation for supported scalar values,
  count/empty checks, comparisons, and common prefix/suffix/contains predicates.
  A one-grapheme `Character` literal is supported for the common
  `String.contains(Character)` form without exposing Swift's private Character
  layout.
- Tuple, `Void`, and `Optional`, including the ordinary control flow produced by
  `if let`, `guard let`, `??`, and `try?`, including address-based Optional
  projection emitted by semantic Dictionary lookup SIL.
- Array value semantics, append, iteration, checked subscript access, and
  value-returning updates; Dictionary construction, lookup, update, and
  iteration for supported key and value types.
- Structured branches, loops, switches, calls, recursion, checked business
  error edges, and local payload-carrying Error values.
- Half-open `Range<Int>` `for` loops, lowered to typed HLBC cursor control flow
  rather than a Swift standard-library Range/Iterator ABI object.
- File- or module-scope patch-local nonrecursive stored struct and enum values,
  concrete `Result`, field extraction, enum switch, and supported mutating
  helpers. These are VM
  values, not newly loaded Swift metadata.
- Synchronous patch-local `inout` and `mutating` helpers under verified address,
  access, aliasing, ownership, and same-frame/same-block restrictions.
- Synchronous patch-local closure values with copyable VM-managed captures.
  This includes `@escaping` parameters on same-image helpers, returning a
  closure from one same-image function to its caller, and a closure capturing
  another closure. The value must be consumed inside the same pinned HLVM
  invocation; `escaping-closure-values-1` gates the return and nested-capture
  semantics independently from the older closure capability. Compiler-emitted
  fully concrete specializations are also supported when no archetype,
  metadata, or witness dependency remains.
- Top-level non-suspending `async`, `async throws`, and `@MainActor async`
  entries. Exact generated Swift wrappers preserve their ABI while HLVM runs a
  body proven not to suspend.
- VM-owned `Any`, `is`, `as?`, and `as!`, including recursive conversions of
  supported Optional, Array, and Dictionary values. Swift existential metadata,
  native objects, and linear lifetimes never enter downloaded bytecode.
- Fully concrete default-argument generators. Production and development
  compilers link reachable `fA...` thunks and include them in transitive
  implementation fingerprints. This covers eligible callers in one complete
  module source set; cross-module public/package defaults, an ineligible caller,
  or a remaining generic ABI require a full build.
- Ordinary `Swift.print` through a synchronous NativeImport frozen into every
  new Shell. It supports common Bridge-compatible `Any` values,
  separator/terminator semantics, and a 64 KiB output bound without App catalog
  configuration.
- Calls to same-image helpers, eligible Shell entries, and exact allowlisted
  NativeImports already emitted in the target Shell. Baseline-used imported
  APIs can be frozen automatically when Typed AST semantics and canonical SIL
  physical ABI agree; current coverage includes references, raw enums,
  OptionSets, opaque copyable values, accessors, methods, global values and
  functions, simple imported C values, Selector, upcasts, and validated
  String/Array Objective-C bridges.

### Rejected or intentionally incomplete

- Generic roots or any execution that still requires runtime generic metadata,
  witness tables, reabstraction, or dynamic specialization.
- True suspension: `await`, continuations, tasks, async callees, async closures,
  cancellation, and cross-suspension ownership or generation leases.
- Actor-isolated instance roots, custom global actors, and arbitrary executor
  hops. The limited `@MainActor async` leaf case above is distinct.
- A closure crossing a Shell Entry or NativeImport boundary, being persisted in
  native/global/property state, or outliving its pinned HLVM invocation or
  generation. Throwing, async, `@Sendable`, and closure signatures whose own
  parameter or result is another closure also remain unsupported.
- General `Character` values/APIs beyond the bounded literal predicate above;
  `ClosedRange`, non-`Int` ranges, `stride`, and function-local nominal type
  declarations. Move a patch-local struct or enum to file scope and rebuild the
  Shell before patching it.
- New native classes, new Swift metadata visible across the patch boundary,
  retroactive conformances, layout changes, superclass changes, and enum-case
  changes.
- Generic or `inout` Shell entries, noncopyable roots, arbitrary borrowing and
  consuming ABI, typed-throws roots, `rethrows`, and general unwind cleanup.
- Unrestricted pointers, `unsafeBitCast`, arbitrary Objective-C selector/IMP,
  `dlopen`/`dlsym`, Mirror-driven field mutation, and unknown builtins.
- A native call that does not have an exact `NativeImportID` in the released
  Shell, even if a similarly named Swift function exists. A patch also cannot
  add a framework or use an SDK operation for the first time after that Shell
  was released.

## Development Live Reload boundary

The default Live Reload path uses the same canonical SIL, verifier, and HLVM
core as production. Development changes the session, transport, lifetime, and
diagnostic policy; it does not replace unsupported bytecode with downloaded
machine code.

| Edit | Current result |
| --- | --- |
| Change an indexed global function body | Supported when its canonical SIL is in the documented subset |
| Change an indexed source-class instance method body | Supported; generated TypeOps carry the exact `self` reference into HLVM |
| Change a struct/enum/actor instance method or a static/class method | Rejected until value writeback, executor, and metatype ABI are implemented |
| Call an existing private/internal/public declaration from that body | Supported only when it resolves to a same-image function, eligible Shell Entry, or exact emitted NativeImport |
| Ordinary direct recursion | Resolves to the function in the same immutable HLBC image |
| Deliberately call the previous generation from source | Not supported by HLBC; save/activate a restoring generation instead |
| Use a supported local closure or an already indexed same-image helper with an `@escaping` closure parameter | Lowered into the same image; closure return/capture is allowed only inside the pinned VM invocation |
| Use `for value in lower..<upper` where both bounds are `Int` | Supported with Swift's precondition that `lower <= upper`; other range families require a full build |
| Use a one-grapheme Character literal in supported `String.contains` | Supported as a compiler-only String representation; general Character storage/API is not implied |
| Declare a patch-local struct or enum | Supported at file/module scope; a function-local nominal is rejected with an exact type diagnostic |
| Add an arbitrary file-level helper/type/extension or a new Swift file | Not collected by the current generator; full build required |
| Change a stored property, signature, generic constraint, actor isolation, superclass, conformance, or enum case | Rejected; full build required |
| Change default-argument behavior | A fully concrete generator is patched with eligible archived callers in one complete module; cross-module public/package defaults, an ineligible caller, or a generic ABI require a full build |
| Change a static/global initializer | Existing initialized state is not replayed automatically |
| Add a framework, package, macro/plugin input, bridging header, or source membership | Dev Build Manifest becomes stale; full build required |
| Edit storyboard, XIB, assets, strings, Core Data model, plist, or entitlements | Outside the Swift-body Live Reload path |

Original access control remains part of the captured compiler context, but
visibility is not itself a runtime capability. An operation that cannot be
represented in HLBC and has no exact generated Entry/NativeImport fails at
compile time even when ordinary Swift would allow it.

Simulator and device use the same HLBC protocol and runtime. The checked-in
Simulator E2E has applied a changed body and restored the baseline in one App
process. A separate 128-generation in-process soak proves bounded active,
rollback, failed-save, high-water, and compaction behavior. A physical-iPhone
run and long-duration memory-pressure soak are still required before device
behavior is listed as qualified. Native Dynamic Replacement remains an
explicitly selected internal experiment and is not an alternate product
fallback.

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

## Diagnostics boundary

Canonical Swift debug metadata is lowered into a verified HLBC source map keyed
by function, block, and instruction offset. Production artifacts retain only
unambiguous logical source paths; host absolute paths are removed. The
disassembler can annotate instructions with those locations, and an HLVM trap
reports a structured program counter. `HelixRuntime` enriches it with the pinned
generation, Shell entry, function name, and logical Swift location before
notifying observers.

This is source-level failure attribution, not an LLDB replacement. Interactive
HLBC breakpoints, stepping, expression evaluation, and time-travel debugging
are not implemented. Compile-time unsupported constructs continue to fail on
the Mac with the original logical source diagnostic.

## Security and resource boundaries

Production and development fail closed on unknown versions, capabilities,
targets, identities, duplicate records, malformed containers, and resource
limits. Production bytecode has fuel, deadline, stack, register, call-depth,
value-shape, native import, and memory accounting. Downloads and live transfers
are bounded before allocation or execution.

Development Live Reload bounds artifact bytes and retained generations. A
synchronous Swift NativeImport cannot be forcibly preempted;
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
