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
| Production HLBC | HLBC 1.0 / HLXI 1.0 compiler path, verifier, HLVM, signed package, safe installation, immutable activation, rollback and revocation; checked-in business corpus | App Store distribution approval, external top-200 corpus, long fuzz/sanitizer campaigns, real-device macro performance, and hosted UIKit-page soak |
| Development Live Reload | Exact build capture, stable snapshots, body diff, session-bound verified HLBC, authenticated transfer, atomic activation, UIKit/SwiftUI refresh, logical source maps and a 128-generation in-process soak | Physical-iPhone matrix, long-duration device soak, interactive bytecode stepping, large-project latency qualification |
| Helix Hub | SwiftUI status-bar app, project discovery, transactional Hot Patch/Live Reload onboarding, secure helper discovery, unified service, exact Build Context registry, Xcode automatic invitation, and manual four-character pairing | Distribution signing/notarization and broad third-party project migration matrix |
| Native experiment | Explicit-only Dynamic Replacement builder, recursion/previous tests, signed dylib and loader probes | Product support; it is intentionally absent from automatic routing |
| Control plane | Client-side package and policy contracts | Production Registry, HSM operations, approval, rollout, telemetry, and fleet coordination services |

The full SwiftPM suite, warnings-as-errors build, optimized Release build, iOS
fixtures, and checked-in Demo flows are separate evidence gates. Passing them
does not by itself certify a physical device or distribution channel.

## Production HLBC 1.0 Swift subset

### Implemented

- `Bool`, signed and unsigned fixed-width integers, `Float`, `Double`, and
  64-bit Apple-platform `CGFloat`, with
  the documented arithmetic, bitwise, comparison, shift, and supported numeric
  conversion rules. Fully concrete scalar `min`/`max` and signed numeric `abs`
  preserve Swift's operand-order, overflow, signed-zero, and NaN behavior.
  HLBC constants and HLVM values retain destination-width raw bits: the entire
  `UInt64` domain is representable, and binary32 never passes through binary64
  storage, so infinities, signed zero, NaN payloads, and signaling state survive
  canonical encoding and typed Bridge round trips. Common concrete scalar
  standard-library APIs use operation- and value-type-driven lowering across
  the whole supported family rather than SDK-type shims. Fixed-width integers
  include `min`/`max`, `bitWidth`, `isSigned`, `magnitude`, population and zero
  bit counts, `byteSwapped`, `bigEndian`/`littleEndian`, `signum()`, clamping
  and truncating conversions, `isMultiple(of:)`,
  `quotientAndRemainder(dividingBy:)`, full-width multiply/divide, and the five
  reporting-overflow operations. `Float` and `Double` include their common
  constants, bit-pattern round trips, exponent/significand decomposition,
  classification predicates, `magnitude`, `squareRoot()`, `ulp`, `nextUp`,
  `binade`, `significand`, `sign`, every rounding rule, IEEE and truncating
  remainders, fused `addingProduct`/`addProduct`, total ordering, and the four
  NaN- and signed-zero-aware min/max operations. Their ordinary mutating forms
  lower to the same typed operations. Division by zero, an unrepresentable
  full-width quotient, signed minimum divided by minus one, signed zero,
  subnormal values, and signaling NaNs retain Swift behavior; undefined
  zero-count builtin forms are rejected rather than guessed.
- `String` literals, concatenation, interpolation for supported scalar values,
  Unicode `uppercased`/`lowercased` transforms, count/empty checks, comparisons,
  and common prefix/suffix/contains predicates. Variable-size transforms reserve
  a proven output bound before allocation and charge only their measured UTF-8
  result. A one-grapheme `Character` literal is supported for the common
  `String.contains(Character)` form without exposing Swift's private Character
  layout.
- Tuple, `Void`, and `Optional`, including the ordinary control flow produced by
  `if let`, `guard let`, `??`, and `try?`, including address-based Optional
  projection emitted by semantic Dictionary lookup SIL.
- Array value semantics, append, `first`/`last`, `popLast`, iteration, checked
  subscript access, and value-returning updates; Dictionary construction,
  lookup, update, `removeValue(forKey:)`, and iteration for supported key and
  value types. Set supports empty, literal, Array, and Set construction;
  `count`, `isEmpty`, `first`, `contains`, `insert`, `update`, `remove`,
  `popFirst`, `removeFirst`, `removeAll`, the capacity hint, iteration, the
  union/intersection/subtraction/symmetric-difference families, and the common
  equality/subset/superset/disjoint relations. Set order is deliberately not
  observable through equality; HLVM keeps deterministic iteration within one
  value only so execution and diagnostics remain reproducible. Dictionary keys
  and Set elements use one VM-defined Hashable family: Bool, fixed-width
  integers, floating-point values, String, and recursively supported Optional,
  Array, Dictionary, and Set values. User-defined `Hashable` witnesses remain
  fail-closed because downloaded code cannot invoke arbitrary hashing or
  equality. Fully concrete Array-backed `map`, `filter`, `compactMap`,
  `reduce`, `forEach`, `first(where:)`, `contains(where:)`, and `allSatisfy`
  use verified closure control flow and a linear, invocation-local Array
  builder instead of repeated copy-on-write append. `Optional.map`/`flatMap`
  and concrete `Result.map`/`mapError`/`flatMap`/`flatMapError` whose payloads
  are valid patch-local values use one selected-case transform with explicit
  payload ownership; `Result.get()` projects success and failure onto verified
  normal and error edges. A local `Result` cannot currently embed a native
  handle.
- Structured branches, loops, switches, calls, recursion, checked business
  error edges, and local payload-carrying Error values. Real-frontend coverage
  includes ternary expressions, `repeat-while`, labeled `break`/`continue`,
  tuple and Optional pattern matching, `for case`, `while let`, `fallthrough`,
  early returns, and `defer` on loop and return cleanup paths.
- `Range` and `ClosedRange` `for` loops over every supported fixed-width signed
  or unsigned integer, plus `stride(from:to:by:)` and
  `stride(from:through:by:)` over those integers, `Float`, `Double`, and
  64-bit `CGFloat`.
  `Range.contains` and `ClosedRange.contains` also accept supported integer,
  floating, and String bounds. Lowering uses one typed, Optional-cursor HLBC
  progression operation rather than standard-library iterator ABI objects;
  zero strides and invalid range bounds preserve Swift traps, and integer
  extrema terminate without sentinel collisions.
- Newly introduced, non-exported file- or module-scope patch-local nonrecursive
  stored struct and enum values, concrete `Result`, field extraction, enum
  switch, instance/static computed getters and setters, and supported mutating
  helpers. Nested declarations keep their namespace-qualified identity. These
  are generation-local VM values, not newly loaded Swift metadata.
- Newly introduced ordinary functions, private methods, and computed accessors
  are transitively linked as same-image functions, getters, or setters without
  requiring a pre-existing Shell EntryIndex. A patch-local `final class` has
  HLVM-owned reference identity, field storage, and method dispatch; a pure
  HLVM class cannot cross the native boundary.
- A new `final` class may name an HLXI-frozen, `NSObject`-compatible reference
  superclass. Runtime registers an Objective-C host per immutable image so the
  instance can cross into native code as that superclass, including a project
  base class or `UIViewController`. The current hosted profile permits only an
  inherited no-argument initializer, no new stored properties, and `Void`
  overrides with either no arguments or one `Bool`; native code cannot identify
  the patch's concrete Swift type.
- Synchronous patch-local `inout` and `mutating` helpers under verified address,
  access, aliasing, ownership, and same-frame/same-block restrictions. This
  includes the `@inout_aliasable`/`@closureCapture $*T` physical conventions
  emitted for mutable locals captured by compiler-generated `defer` helpers.
- Synchronous patch-local closure values with copyable VM-managed captures,
  including nonthrowing and throwing invocation paths. Mutable local values
  are promoted through one type-independent VM cell model, covering scalar,
  String, Optional, Array, Dictionary, Set, tuple, and patch-local struct storage,
  projected fields, nested captures, and the `{ var T }` boxes emitted for
  escaping Swift closures. Field-sensitive definite/possible initialization
  also covers branch initialization, conditional replacement, and cleanup
  without treating a maybe-initialized value as readable. This includes
  `@escaping` parameters on same-image
  helpers, returning a closure from one same-image function to its caller, and
  a closure capturing another closure. Concrete closure ABIs preserve
  per-parameter owned/borrowed conventions, including `@in_guaranteed`
  Optional and imported SDK reference values used by the supported higher-order
  operations. The value must be consumed inside the
  same pinned HLVM invocation; `escaping-closure-values-1` gates return and
  nested-capture semantics, while `mutable-captures-1` gates managed cells.
  Compiler-emitted fully concrete specializations are also supported when no
  archetype, metadata, or witness dependency remains.
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
- Managed Debug measurement of public members for every module contributing an
  already-frozen imported native type. The captured toolchain's symbol graph
  nominates minimum-OS-valid APIs, and the same typed AST/canonical SIL pipeline
  freezes only unique, Bridge-compatible initializers, synchronous instance or
  static methods, and readable or writable properties. The generic path covers
  Swift and Objective-C declarations, Swift-overlay/physical aliases, SDK
  isolation, and the exact canonical `NSError **` bridge for an Objective-C
  instance method imported as logical Swift `throws -> Void`. Examples include
  `UIColor.black`, `UIColor.init(white:alpha:)`, `UIView.alpha`, `UIView.setNeedsLayout()`,
  `UIView.setAnimationsEnabled(_:)`, `URLCache.shared`,
  `Bundle.path(forResource:ofType:)`, and `FileManager.removeItem(atPath:)`.
  Production Shells do not receive this convenience surface, and it does not
  introduce a new boundary type by itself.
- Objective-C superclass dispatch and address-form Optional control flow when
  their exact native operations are frozen. Same-type receiver casts are
  accepted only as aliases of one reference `TypeID`, and Optional payload takes
  require a dominating `.some` edge even after an exact address copy.
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
  generation. Async, `@Sendable`, and closure signatures whose own parameter
  or result is another closure remain unsupported. Capturing a caller-owned
  `inout` parameter also remains fail-closed because it requires explicit
  writeback to the caller; ordinary mutable locals and Swift escape boxes use
  the managed-cell path above.
- General `Character` values/APIs beyond the bounded literal predicate above;
  progression element types beyond the fixed-width integer and floating
  iteration surface above, exporting a Range/stride value across a Shell or
  NativeImport boundary, and function-local nominal type declarations. Move a
  non-exported patch-local struct or enum to file/module scope in an existing
  watched source file; no Shell rebuild is needed when the resulting
  declaration remains private to the HLBC image.
- User-defined `Hashable` semantics for Dictionary keys or Set elements, and
  dynamic Set payloads inside VM-owned `Any`. Typed Set Shell bridges are
  supported, but the bounded dynamic-Any codec does not guess an element type.
- Arbitrary new Swift metadata, a patch concrete class identity visible to
  native code, retroactive conformances, or changes to a Shell type's layout,
  superclass, or enum cases. The hosted Objective-C subclass above is a frozen
  superclass projection, not arbitrary Swift metadata generation.
- Generic or `inout` Shell entries, noncopyable roots, arbitrary borrowing and
  consuming ABI, typed-throws roots, general `rethrows` outside the concrete
  standard-library operations listed above, and general unwind cleanup.
- Unrestricted pointers, `unsafeBitCast`, arbitrary Objective-C selector/IMP,
  `dlopen`/`dlsym`, Mirror-driven field mutation, and unknown builtins.
- A native call that does not have an exact `NativeImportID` in the target
  Shell, even if a similarly named Swift function exists. A production patch
  also cannot add a framework or use an SDK operation for the first time after
  that Shell was released. The measured managed-Debug color palette above works
  precisely because those individual IDs are frozen during the normal Debug
  build.

## Development Live Reload boundary

The default Live Reload path uses the same canonical SIL, verifier, and HLVM
core as production. Development changes the session, transport, lifetime, and
diagnostic policy; it does not replace unsupported bytecode with downloaded
machine code.

| Edit | Current result |
| --- | --- |
| Change an indexed global function body | Supported when its canonical SIL is in the documented subset |
| Change an indexed source-class instance method body | Supported; generated TypeOps carry the exact `self` reference into HLVM |
| Change an existing Shell struct/enum/actor instance root or existing native static/class method | Rejected until Shell value writeback, executor, and native metatype ABI are implemented; this does not restrict image-local value-type accessors/helpers |
| Call an existing private/internal/public declaration from that body | Supported only when it resolves to a same-image function, eligible Shell Entry, or exact emitted NativeImport |
| First use a public SDK member in a managed Debug body | Supported for a uniquely measured, synchronous initializer, instance/static method, or readable/writable property when every boundary type is already representable in the frozen imported/Bridge surface and the declaration is valid at the Shell minimum OS; unfamiliar `NSError` bridges, async/generic/closure-bearing members, subscripts, and unrepresentable signatures require a full build |
| Add an ordinary top-level helper, private class instance method, or computed accessor in an existing source file | Supported when reachable from a changed root and its concrete signature/body fit HLBC; it remains private to that image |
| Ordinary direct recursion | Resolves to the function in the same immutable HLBC image |
| Deliberately call the previous generation from source | Not supported by HLBC; save/activate a restoring generation instead |
| Use a supported local closure or an already indexed same-image helper with an `@escaping` closure parameter | Lowered into the same image; closure return/capture is allowed only inside the pinned VM invocation |
| Use integer `Range`/`ClosedRange` iteration, numeric `stride`, or scalar `contains` | Supported for the concrete local families above; bounds, direction, inclusive/exclusive endpoints, zero-stride traps, and integer extrema retain their verified Swift semantics. Progression values remain image-local and cannot cross Shell/NativeImport boundaries |
| Use a one-grapheme Character literal in supported `String.contains` | Supported as a compiler-only String representation; general Character storage/API is not implied |
| Declare a patch-local struct or enum | A newly introduced non-exported type is supported at file/module scope, including namespace nesting and supported computed accessors; a function-local nominal is rejected with an exact type diagnostic |
| Declare a pure patch-local class | A final, nongeneric type used only inside one image supports reference identity, stored properties, private/ordinary methods, and computed accessors; it cannot cross into native code |
| Declare a hosted class inheriting a project or system type | The superclass must be frozen as `NSObject`-compatible reference TypeOps; the current profile supports inherited no-argument initialization, no new stored properties, and no-argument/Bool `Void` overrides, and projects the instance to native code as its superclass |
| Add an unrelated declaration, a new native ABI surface, or a new Swift file | Not collected merely by existence; a source-membership or native ABI change requires a full build |
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
value-shape, native import, and memory accounting. Variable-size VM operations
atomically reserve a verified worst-case allocation, refund the unused portion,
and retain the measured charge. Downloads and live transfers are bounded before
allocation or execution.

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
