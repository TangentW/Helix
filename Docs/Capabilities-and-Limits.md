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
- `Bool.toggle()` and global `swap` use one type-directed value-mutation path.
  Swap supports represented copyable scalar, text, Optional, tuple, and
  patch-local aggregate values in ordinary, projected, frame, or mutable
  closure-cell storage; overlapping storage is rejected and both reads precede
  either assignment. Neither operation adds an API-specific opcode or
  NativeImport.
- `String`, `Character`, and `Substring` use explicit logical text contracts
  without importing their private standard-library layouts. A represented
  `Character` is validated as exactly one extended grapheme cluster at every
  producer or Shell boundary; `Substring` is normalized to its Character
  sequence and does not preserve private slice storage or index identity.
  Supported operations include String/Character literals and equality/
  ordering, String append of a Character or String, Substring append of a
  Character, and finite Character-Sequence `append(contentsOf:)`/`+=` for
  both String and Substring,
  scalar and text interpolation, repeating and
  common String construction, Unicode `uppercased`/`lowercased`, count/empty,
  prefix/suffix/contains predicates, String/Substring conversion, Character-
  sequence construction, String-sequence joining, grapheme-correct
  `removeFirst`/`removeLast` (including counted forms), `popLast`, clearing, and
  capacity hints. These mutations share one represented
  `RangeReplaceableCollection` plan with Array-backed values rather than text-
  specific bytecode. Direct Character/String suffixes avoid segmenting the
  existing String; other represented Character sequences are materialized and
  joined once. Failable scalar construction additionally covers `Bool` from
  String, every represented signed and unsigned fixed-width integer from String
  or Substring with decimal or runtime radix, and `Float`/`Double` from String
  or Substring. Integer `String(_:radix:uppercase:)` supports the same complete
  integer family. Two target-type-driven HLBC operations cover those families;
  verifier checks reject mismatched scalar/radix shapes, radix outside `2...36`
  preserves Swift's precondition as a controlled trap, and no generic
  standard-library NativeImport or per-width operation is introduced.
  Variable-size text operations precharge deterministic UTF-8 work and output
  storage.
- Tuple, `Void`, and `Optional`, including the ordinary control flow produced by
  `if let`, `guard let`, `??`, and `try?`, including address-based Optional
  projection emitted by semantic Dictionary lookup SIL. Explicit
  `.some`/`.none` clauses and canonical SIL's exhaustive one-case-plus-`default`
  spelling use the same semantic case plan. A `default` edge never invents an
  unbound payload argument, and a discarded linear payload is released exactly
  once. Optional case evidence
  is field-sensitive through Tuple and patch-local struct projections: a proven
  projected payload take consumes only that field, while sibling or
  caller-owned storage cannot borrow its proof. Definite and conditional
  projected cleanup preserve independently initialized sibling fields.
  Detached Optional payload addresses are classified from their physical
  consumers rather than their opcode spelling: read-only loads preserve the
  parent, consuming loads and `@in` take it, and stores or `@inout` mutation
  rebuild nested Tuple/local-struct fields before writeback. A destructive and
  modifying lifetime on the same detached payload is rejected. Frame- and
  runtime-backed `inout` scopes may cross throwing same-image calls and close
  symmetrically on both continuations. Nonthrowing compiler-only `inout` calls
  also use verified temporary address storage and reject overlapping
  projections; their throwing form remains unsupported because it requires
  reconstructed writeback on both continuations. Declaration-summary spellings
  such as `T?`, `T!`, `[T]`, `[K: V]`, and redundant grouping parentheses
  normalize recursively to the same typed representation, including in
  patch-local stored fields.
- Direct Optional force unwrap and `unsafelyUnwrapped` are supported for
  represented payloads and a nil unwrap retains its dedicated verified trap
  reason. A payload-free runtime
  `nil` obtains `T` from its verified static context, including nested tuples,
  collection builders, mutation/sort/split states, Dictionary keys and values,
  and VM equality.
- Source-level irrecoverable failures emitted by the captured frontend are
  explicit verified control flow. This covers `precondition`,
  `preconditionFailure`, `fatalError`, active `assert`/`assertionFailure`, and
  the error edge of `try!`. Current frontend variants with static diagnostics
  use the existing trap terminator; dynamic String and represented Error
  details, including bounded identities for concrete `throws(Failure)` errors,
  share one
  `source_failure` terminator. Message autoclosures retain
  their source evaluation timing, source locations come from the HLBC source
  map, and no Swift runtime failure symbol is exposed as a NativeImport.
- Array value semantics and equality, single-element append, `+`, `+=`,
  `append(contentsOf:)`, element and contents insertion, `replaceSubrange`,
  positional/first/last/range removal (including counted edge removal),
  `removeAll(keepingCapacity:)`, `swapAt`, `reserveCapacity`, `first`/`last`,
  `firstIndex(of:)`/`lastIndex(of:)`, `min`/`max`, `elementsEqual`,
  `starts(with:)`, `lexicographicallyPrecedes`, `startIndex`/`endIndex`,
  `distance(from:to:)`, index movement and limited offsets, the mutating
  `formIndex(after:)`/`formIndex(before:)`/offset family, `indices`, `popLast`,
  iteration, checked subscript access, and value-returning updates.
  Element append, `append(contentsOf:)`, and `+=` also apply to normalized
  ArraySlice destinations. Contents sources may be any supported finite
  represented Sequence with matching canonical source-level Element identity
  and physical shape, including managed Array/ArraySlice/Set/Dictionary
  storage, String/Substring Character sequences, and supported concrete
  progressions. Remaining
  structural edits accept represented copyable element types and matching
  Array-backed sources. They share verified scalar append, half-open range
  replacement, and swap primitives, so bounds checks, overflow behavior,
  ownership, and allocation-before-copy charging do not depend on a particular
  element or SDK type. Capacity-changing hints and the empty
  `Dictionary(minimumCapacity:)`/`Set(minimumCapacity:)` constructors are
  supported; all retain Swift's nonnegative precondition even though physical
  reserve size is not observable through represented APIs. Reading
  `Array.capacity` is intentionally rejected because physical VM storage
  capacity is not Swift Array semantics. `randomElement()` is likewise rejected
  until randomness and its observable policy are represented explicitly.
  Generic indirect results may initialize either a complete element or one
  tuple field in raw Array-literal construction storage through the same typed
  compiler-address sink used by ordinary stores.
  Dictionary construction, equality, lookup, subscript assignment,
  lazy `subscript(_:default:)` lookup and scoped mutation,
  `updateValue(_:forKey:)`, `removeValue(forKey:)`,
  `removeAll(keepingCapacity:)`, `keys`/`values` sequence materialization,
  `init(minimumCapacity:)`, `init(uniqueKeysWithValues:)`,
  `init(_:uniquingKeysWith:)`, both Dictionary-
  and represented-Sequence forms of `merging`/`merge`,
  `init(grouping:by:)`, `reserveCapacity`, and iteration are supported for
  eligible key and value types. Grouping accepts represented managed
  Array/Set/Dictionary sources and normalized Array-backed adapters. It uses a
  fused Array-valued accumulator append rather than repeatedly copying a whole
  bucket. Combining callbacks run only for duplicate keys; first-key identity,
  insertion order, source traversal order, and `rethrows` behavior are
  preserved. A throwing mutating `merge` retains successful prefix mutations,
  while value-returning construction discards its partial result.
  Frontend-generated `_arrayForceCast` and `_dictionaryUpCast` calls are
  accepted only when the original types differ by tuple labels and their
  complete recursively normalized source and destination VM types are also
  identical, covering label erasure in direct and nested
  containers. Casts that actually change an element, key, value, or reference
  type remain rejected. Insertion,
  replacement, and removal share
  one typed Optional-update primitive that returns both the previous value and
  the updated Dictionary; key/value views share one typed projection primitive.
  Those update and projection paths precharge work and output storage before
  copying.
  Default lookup calls its autoclosure only on a missing key. Its `_modify`
  path and Array element `_modify` share scoped frame storage and perform
  writeback on both `end_apply` and `abort_apply`, covering nested and throwing
  inout mutation without collection-API-specific bytecode.
  Array append accepts represented copyable elements, including frozen imported
  reference values. Represented Array-backed integer-index collections also
  support `reverse()` and `removeAll(where:)` while retaining a view's logical
  base; predicate removal is available for any represented copyable element.
  Equality is defined recursively
  for Bool, fixed-width integers, floating-point values, String, and supported
  Optional, Array, Dictionary, and Set values. Dictionary and Set comparison is
  order-independent, collection equality preserves Swift's shared-storage fast
  path, and Float/Double preserve Swift NaN and signed-zero behavior.
  Natural ordering remains limited to scalar integer, floating-point, and
  String elements that the VM can compare without executing a user witness.
  Nonmutating `sorted()` accepts any represented managed Collection or
  supported finite progression with such an element, while mutating `sort()`
  accepts represented Array-backed mutable collections with integer indices.
  Comparator-driven `sorted(by:)` accepts represented
  copyable Array, Set, and Dictionary elements plus supported finite
  progressions because the callback runs through the ordinary verified closure
  ABI; mutating `sort(by:)` uses the same Array-backed integer-index boundary.
  Set supports empty, `minimumCapacity`, and literal construction, plus
  construction from Array, Set, and supported finite Sequences;
  `count`, `isEmpty`, `first`, `contains`, `insert`, `update`, `remove`,
  `popFirst`, `removeFirst`, `removeAll`, the capacity hint, iteration, the
  union/intersection/subtraction/symmetric-difference families, and the common
  equality/subset/superset/disjoint relations. Set order is deliberately not
  observable through equality; HLVM keeps deterministic iteration within one
  value only so execution and diagnostics remain reproducible. Dictionary keys
  and Set elements use the same recursively VM-defined value family as their
  Hashable domain. User-defined `Hashable` or equality witnesses remain
  fail-closed because downloaded code cannot invoke arbitrary hashing or
  equality. Generic `Array()` and `Dictionary()` construction is supported for
  represented element/key/value types. Array, Dictionary, and Set share direct
  `count`, exact Collection `underestimatedCount`, `isEmpty`, and `first`
  queries; Array additionally supports `last`
  through its represented bidirectional storage, and normalized Array-backed
  views use the same queries. String has direct `count`/`isEmpty` and enters the
  same finite Sequence cursor as a verified Character Array for element-based
  traversal, including `first`/`last`, transforms, relations, and adapters.
  String, Substring, Array, and normalized Array-backed views also share typed
  Element/Sequence append, edge/count removal, `popLast`, and clearing;
  capacity hints are retained only to the extent observable through supported
  APIs. Concrete `+=` metatypes, canonical source-level Element identity
  (including tuple labels and distinctions erased by HLBC), physical shape,
  and linear ownership are checked before mutation.
  String finalizes normalized Character sources back to text, while
  Array-backed storage remains direct.
  Fully concrete `map`, `flatMap`,
  `compactMap`, `reduce`, `reduce(into:_:)`, `forEach`, `first(where:)`,
  `contains(where:)`, `allSatisfy`, `count(where:)`, and comparator-driven
  `min(by:)`/`max(by:)` share verified closure traversal across represented
  String, Array, Dictionary, and Set values. Dictionary elements use their native
  `(key: Key, value: Value)` tuple shape. Container-preserving `filter` is
  supported for String and all three stored containers, and Dictionary
  additionally supports `mapValues` and `compactMapValues`; their specialized
  key/value callback ABI is projected from the same tuple traversal. Natural
  `min()`/`max()`, equality
  `contains(_:)`, and `elementsEqual`/`starts(with:)`/
  `lexicographicallyPrecedes` also accept represented managed Collections and
  supported finite progressions when the required VM-defined Comparable or
  Equatable semantics exist; the two relation operands may use different
  source kinds when their element shapes match. Managed Collection and
  progression consumers stream the shared cursor without an intermediate
  Array; String performs one validated Character-Array materialization before
  entering that same cursor.
  Reverse `last(where:)` accepts String and Array-backed sources. String and
  Array-backed sources support Collection `prefix(while:)`/`drop(while:)`;
  direct Sequence `prefix(while:)` also accepts represented finite
  specializations, including supported progressions. Array-backed integer-index
  sources preserve their logical base for `firstIndex(where:)`/
  `lastIndex(where:)`, mutating sort, `reverse()`, `removeAll(where:)`, and
  `partition(by:)`. Producing
  variants use one linear invocation-local element buffer followed by a typed
  String, Array, Dictionary, or Set finalizer instead of repeated copy-on-write edits.
  The `last` searches invoke their predicates from the end; comparator selection
  preserves Swift's argument order and first-element tie behavior. Comparator
  sorting uses a bounded stable merge-state machine. Partition uses Swift's
  bidirectional low/high predicate order and in-place swap arrangement;
  `removeAll(where:)` visits the source in forward order, uses the same generic
  mutable snapshot for half-stable compaction, then removes one suffix.
  Mutating sort writes back only after every comparator succeeds. Partition and
  predicate removal instead write back swaps completed before a thrown
  predicate, while callback side effects already performed remain visible.
  Finite concrete integer `Range`/`ClosedRange` and supported numeric stride
  sources reuse the same forward traversal for `map`, `flatMap`, `filter`,
  `compactMap`, `reduce`, `reduce(into:_:)`, `forEach`, `first(where:)`,
  `contains(where:)`, `allSatisfy`, `count(where:)`, and comparator-driven
  `min(by:)`/`max(by:)`; producing transforms return Arrays. They also support
  equality `contains(_:)`, natural `min()`/`max()`, mixed-source Sequence
  relations, natural/comparator `sorted`, `Set(sequence)`, and generic Set
  algebra whose sequence operand is concrete and finite. Element-only
  consumers retain cursor short-circuiting or one-candidate streaming, while
  sorting and Set results materialize through the shared typed builder. Their
  callbacks retain the same throwing and mutable-capture behavior as managed
  Collections. Integer Range/ClosedRange `count`, `underestimatedCount`,
  `isEmpty`, `first`, and `last` are constant-time bound queries; count is exact
  across the full element width and traps when its cardinality exceeds
  `Int.max`. StrideTo/StrideThrough `underestimatedCount` follows the native
  exact Sequence witness through the same fuel-bounded cursor with constant
  auxiliary storage. `Zip2Sequence.underestimatedCount` recursively preserves
  source witness estimates, including zero for represented enumerated and
  flattened/joined sources rather than substituting the exact materialized
  tuple count. Represented Comparable Range bounds also support `isEmpty`,
  `overlaps`, `clamped(to:)`, and direct lower/upper-bound access without
  implying iteration. Empty ranges never overlap; clamping preserves the selected
  original bound on equality, including floating signed zero.
  Progression index results, opaque-index collection operations, and using a
  one-sided partial range as a potentially infinite Sequence source remain
  rejected until their direction, index identity, complexity, or termination
  can be represented exactly.
  Array-backed Collection and String `split` support both the
  `separator:maxSplits:omittingEmptySubsequences:` overload for recursively
  VM-defined Equatable elements and the throwing `whereSeparator:` overload
  for any represented copyable element. Both use one kind-checked linear range
  state: omitted empty segments do not consume `maxSplits`, predicate calls
  stop as soon as the limit is reached, a negative limit traps before any
  callback, and throwing edges destroy all transient ownership. Returned
  subsequences preserve element order. Array-backed integer-index sources also
  preserve each segment's logical lower bound; String subsequences use the
  represented `Substring` Character Array and do not retain `String.Index`.
  The lazy Sequence `drop(while:)` overload remains rejected: eagerly
  materializing it would change predicate side-effect timing.
  `enumerated()`, `Array(sequence)`, heterogeneous `zip`, and `reversed()`
  accept finite progression sources through the same typed builder used by the
  verified managed-Collection materialization path. Managed Array, Set, and
  Dictionary sources remain supported. String uses the same materialization
  boundary for `Array(sequence)`, `reversed`, count-based subsequences, split,
  transforms, and relations; nested represented Character sequences can be
  flattened and reconstructed as String. Array-backed adapters additionally support
  `reversed()`, `repeatElement`, `Array(repeating:count:)`, count-based
  `dropFirst`/`dropLast`/`prefix`/`suffix`, integer-index
  prefixes/suffixes, `Range<Int>`/`ClosedRange<Int>` and one-sided range
  slicing, `joined()`,
  `joined(separator:)`, iteration, and composed `Slice<Base>` when `Base` is
  already Array-backed. Half-open fixed-width-integer Range values also support
  count-based `dropFirst`/`dropLast`/`prefix`/`suffix` by moving and clamping a
  typed bound in constant time, including full-width Int/UInt extremes. This
  includes explicit `Slice(base:bounds:)`, concrete Slice
  boundaries/movement/indices, and read/write element subscripts. Repeated uses
  the same zero-based integer-index surface, including generic associated-index
  indirect results, subscript access, and mutating `formIndex` operations.
  `ArraySlice` and recursively Array-backed `Slice`
  values carry their logical base through nested views, bounds, movement,
  distance, indices, element/range subscripts, searches, predicate subsequences,
  split, sorting, and supported mutations. `Array(sequence)` intentionally
  resets the newly materialized Array to zero. Collections with opaque private
  indices remain fail-closed rather than being approximated as integer offsets.
  `Optional.map`/`flatMap`
  and concrete `Result.map`/`mapError`/`flatMap`/`flatMapError` whose payloads
  are valid patch-local values use one selected-case transform with explicit
  payload ownership; `Result.get()` projects success and failure onto verified
  normal and error edges. `Result(catching:)` invokes its synchronous throwing
  closure exactly once and constructs the same local enum from the verified
  normal/error continuations; it does not call the generic Swift implementation
  through NativeImport. Local nominal aggregates may contain managed `Error`
  existentials. Their concrete local payloads remain capability-gated and are
  depth- and fuel-checked when the existential is constructed and at VM
  boundaries. A local `Result` still cannot embed a native handle.
- Structured branches, loops, switches, calls, recursion, checked business
  error edges, and local payload-carrying Error values. Real-frontend coverage
  includes ternary, `if`, and `switch` expressions; multiple Optional bindings;
  `repeat-while`; `for where`; labeled `break`/`continue`; tuple and Optional
  pattern matching; `if case`, `guard case`, `for case`, `while let`, and
  `while case`; `fallthrough`; early returns; and `defer` on loop and return
  cleanup paths. Direct local functions, captured closure values, local
  functions passed as transforms, and concrete operator function references
  also use ordinary verified function and closure paths.
- `Range` and `ClosedRange` `for` loops over every supported fixed-width signed
  or unsigned integer, plus `stride(from:to:by:)` and
  `stride(from:through:by:)` over those integers, `Float`, `Double`, and
  64-bit `CGFloat`.
  `Range.contains` and `ClosedRange.contains` also accept supported integer,
  floating, and String bounds. `Range.overlaps`, `clamped(to:)`, and direct
  bound projection accept the same represented Comparable bound family.
  Lowering uses one typed, Optional-cursor HLBC
  progression operation rather than standard-library iterator ABI objects;
  the finite concrete Sequence operations listed above reuse that cursor
  instead of adding API-specific opcodes. Zero strides and invalid range bounds
  preserve Swift traps, and integer extrema terminate without sentinel
  collisions.
- `PartialRangeFrom`, `PartialRangeUpTo`, and `PartialRangeThrough`
  containment, including the `RangeExpression.~=` calls emitted for switch
  patterns, uses one typed comparison plan for represented integer, floating,
  String, and Character bounds. Dynamic unordered floating bounds retain
  Swift's constructor traps. Concrete Array subscripts with one-sided
  `Int` bounds reuse the existing suffix/prefix subsequence operations, while
  the full-range `[...]` marker is erased after a represented Array-backed or
  String/Substring source is normalized through the existing materialization
  boundary. These are compiler-only range values: no Swift generic collection
  ABI is serialized, no standard-library method becomes a NativeImport, and no
  source-API-specific opcode is added. The same range subscripts work for
  represented Array-backed integer-index views and retain their lower bound.
  Custom `Comparable` witnesses and private indices such as `String.Index`
  remain fail-closed.
- Newly introduced, non-exported file- or module-scope patch-local nonrecursive
  stored struct and enum values, concrete `Result`, field extraction, enum
  switch, instance/static computed getters and setters, and supported mutating
  helpers. Comma-separated enum cases, including mixed labeled and unlabeled
  associated values, are parsed at top level; duplicate or malformed case
  summaries fail closed. Nested declarations keep their namespace-qualified identity. These
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
- Synchronous patch-local closure values with copyable represented captures,
  including nonthrowing and throwing invocation paths. Concrete
  `throws(Failure)` functions and closures retain the exact
  Error-conforming patch-local nominal across nonescaping calls, escaping
  storage, aggregates, concrete generic forwarding, concretely specialized
  standard-library higher-order calls, and error continuations.
  The `typed-throws-1` capability gates this raw typed channel. A conversion to
  `throws(any Error)` must be represented by a concrete Swift reabstraction
  thunk; error-type covariance is not inferred by the VM. `throws(Never)` is
  normalized to nonthrowing, and an impossible `Never` normal continuation has
  no register payload. Mutable local values are promoted through one
  type-independent VM cell model, covering scalar,
  String, Optional, Array, Dictionary, Set, tuple, and patch-local struct storage,
  projected fields, nested captures, and the `{ var T }` boxes emitted for
  escaping Swift closures. Field-sensitive definite/possible initialization
  also covers branch initialization, conditional replacement, and cleanup
  without treating a maybe-initialized value as readable. This includes
  `@escaping` parameters on same-image helpers, returning a closure from one
  same-image function to its caller, and a closure capturing another closure.
  Closure values may appear in Optional, tuple, Array, Dictionary, patch-local
  struct/enum/class storage, mutable closure variables, and higher-order
  parameter/result signatures. Capture lists, recursive closure variables,
  local and bound method references, patch-local enum-case constructors,
  concrete `Optional.some`/`Result.success` constructors, patch-local struct
  initializers and static factories, multiple trailing closures, and escaping
  autoclosures all use this same value model. Contextually typed operator and
  overload references, unbound instance methods, synchronous `@MainActor`
  closure values, lazy/mutable/conditional closure locals, and frontend-folded
  pure file/static closure constants use the same callable graph. A recursive
  local helper may be both directly applied and converted to a closure without
  creating competing image identities or capture ABIs. Concrete closure ABIs
  preserve
  per-parameter owned/borrowed/inout conventions, including `@in_guaranteed`
  Optional and imported SDK reference values used by the supported higher-order
  operations, ordinary same-image inout closures on normal/throwing paths, and
  scoped frame-owned mutation used by `reduce(into:_:)`. A copyable linear
  capture, such as an imported reference, is copied into the managed closure
  context when it is formed. A borrowed target parameter reuses that stored
  value, while an owned target parameter receives a fresh, resource-charged
  copy on every invocation so the closure remains multi-shot. Inout captures
  remain rejected. Fully
  concrete direct/indirect-result reabstraction thunks are linked as image-local
  compiler-generated functions, using the closure-body role only when partially
  applied; direct-only closure and `defer` helpers retain their physical capture
  ABI as concrete specializations. They are never resolved through NativeImport.
  An unchanged eligible Swift callable or a representation-preserving declared
  NativeImport callable may also become a closure value without copying an
  archived implementation or creating an API-specific VM adapter. This covers
  capture-free free/global functions, a bound instance method whose native
  receiver is copied into the ordinary closure context, and an initializer
  whose compiler-only metatype is validated and erased. Unified
  `make_closure` freezes an image function, `EntryIndex`, or `NativeImportID`;
  the callable ABI must be complete and representation-preserving, so a
  call-site default-argument projection or direct-call-only adapter is rejected;
  invocation parameters are the target ABI prefix and `partial_apply` captures
  are its suffix. Exact ownership, result, callable effects, boundary-error,
  import declaration/policy, and creator-authority checks are shared. A
  referenced entry with any borrowed parameter requires the same
  `borrow-calls-1` declaration for direct, throwing, and closure-target calls.
  Normal and throwing calls route through the invocation's pinned generation.
  The same target can therefore enter a declared nonescaping or
  escaping NativeImport callback, and a retained callback continues to route to
  that pinned original entry after activation or rollback. Typed patch-local
  errors cannot be exposed through this Shell boundary.
  Concrete nominal metatypes carried by those Swift callables remain validated
  compiler facts at their physical parameter positions and are erased before
  direct or partial application enters HLBC. Custom value initializers may build
  a patch-local struct through field projections; the compiler reconstructs the
  aggregate only after every required field is initialized, using the same
  field-path storage and ownership model as tuple initialization.
  `withExtendedLifetime` is lowered as a type-generic synchronous closure
  scope: a represented copy of the lifetime anchor remains live across the
  no-argument body's normal or typed-error continuation, and is released on
  either exit. It does not invoke the standard library's generic runtime ABI.
  On-stack `partial_apply` and `withoutActuallyEscaping` use explicit dynamic
  scope identities. The Verifier proves that every normal and throwing CFG path
  closes the scope, and the VM rejects a scoped closure still reachable through
  explicit storage or a value with a later semantic use at scope end. Dead SSA
  aliases do not become false escapes. A lexical nonescaping closure may borrow a
  caller-owned `inout` address through the managed-cell capture ABI; the borrow
  becomes invalid with the address access, and both static verification and the
  VM require the closure to close first. An escaping capture of that address is
  rejected. Static scope provenance follows branch parameters and
  closure-bearing aggregates. Exporting an escaping callback also performs a
  budgeted, cycle-safe scan through nested closures, collections, mutable cells,
  local objects, and live local weak/unowned referents, so reference-backed
  storage cannot hide a lexical scope.
  Other closure values must remain inside the same pinned HLVM
  invocation;
  `escaping-closure-values-1` gates return and
  nested-capture semantics, while `mutable-captures-1` gates managed cells.
  Safe `weak` and checked `unowned` capture lists, plus captured weak local
  variables, use the same managed-capture ABI. The shared non-retaining handle
  accepts patch-local classes and frozen native reference identities: weak
  loads become `nil` after deallocation, while a dead checked-unowned load is a
  controlled VM trap. `non-owning-references-1` gates this storage and every
  instruction that creates or accesses it.
  Compiler-emitted fully concrete specializations are supported when no
  archetype, metadata, or witness dependency remains. Source generic helpers
  used at concrete same-image `apply`, `try_apply`, or `partial_apply` sites are
  also monomorphized from semantic SIL. Distinct argument lists receive
  deterministic image identities while call bindings retain the original
  Swift symbol; recursive, rethrowing, higher-order, and escaping-function-value
  forms use that same path. A fully concrete patch-local struct, enum, or class
  conformance may also resolve one exact complete witness record to a static
  image thunk. This covers getter/setter, static, mutating, throwing, inherited,
  default-implementation, and bound-method calls without serializing witness
  metadata. Unresolved arguments, packs, conditional conformances, and
  ambiguous witness evidence remain fail-closed.
- Closed immutable protocol existentials for complete, nonconditional
  current-module conformances. Supported source use includes local `any P`,
  protocol compositions and inherited requirements, struct and patch-local
  class conformers, `AnyObject` constraints, immutable opening and erasure,
  closed widening/narrowing, Array storage, bound methods, closure and direct
  function results, synchronous throwing requirements, concrete casts, and
  `as?`/`as!` between protocol existentials. The compiler keeps protocol
  identity out of HLBC and emits only exact represented-type sets and finite
  represented-type-to-function tables. The Verifier requires unique known
  types, concrete-specialization targets, a common ABI/effect set, and safe
  receiver ownership; tables and cast sets are bounded to 4,096 entries. HLVM
  performs exact matching and meters the full linear lookup. These values are
  image-local: a protocol existential Shell root is ineligible, and a call
  carrying a Swift protocol value across Shell or an ordinary NativeImport is
  rejected before bytecode is emitted. A proven Objective-C `!foreign`
  protocol erasure remains the existing frozen native `AnyObject` path.
  Conditional/retroactive/imported conformances, an open conformer universe,
  and mutable existential opening/writeback remain fail-closed.
- Exact NativeImport callable crossings under one generated, framework-neutral
  bridge profile. Typed AST supplies the source closure spelling; canonical SIL
  supplies the physical `@noescape`/escaping lifetime, Objective-C block
  reabstraction, ownership, and global-actor evidence. MainActor provenance is
  retained through frontend conversion/Optional wrappers and immutable inferred
  local aliases, while an explicit source function type—including intentional
  actor erasure—remains authoritative. The current profile
  accepts direct or Optional synchronous, nonthrowing callbacks. Callback
  parameters may recursively use the ordinary native bridge value family,
  including `Error` existentials (direct or Optional) represented as bounded
  opaque proxies, but cannot be `inout` or image-local values. One direct or
  Optional native-origin callable argument layer is also accepted when the
  generated Swift call proves it escaping. Its own signature is synchronous,
  nonthrowing, and closure-free, and uses callback bridge values, including
  bounded `Error` proxies; the VM keeps its native identity, exact ownership
  and MainActor requirements, resource accounting, and a non-Sendable overlap
  gate when invoking it.
  A NativeImport itself may return a direct or Optional native-origin callable
  with the same signature profile. Returned callables are escaping by
  construction. The generated Bridge must create their identity-bearing target
  and encode it before the synchronous import context closes, under that
  import's exact deadline and signed resource limits; an image-local closure
  cannot be substituted. Their parameters and result cannot contain a second
  callable layer, and callable containers remain excluded.
  Results may be `Void` or ordinary recursive bridge values with deterministic
  failure values: scalars, text, `Any`, Optional, empty collections, and
  recursively defaultable tuples. Direct native results are rejected because
  there is no framework-neutral instance to return on failure; Optional native
  results are admitted because `nil` is valid.
  Only a bounded textual dynamic-type name crosses; native payload, metadata,
  and semantic error identity do not. `Error` is rejected in Shell entries and
  ordinary NativeImport parameters/results, and as a callback result.
  Nonescaping callbacks are valid only during the importing call. A callback
  assigned through a native property setter is always treated as stored and
  therefore escaping, even though `@escaping` is not legal in a property type;
  actor isolation from the assigned expression remains part of the boundary.
  Escaping callbacks may be retained by that exact native parameter, outlive
  the originating VM invocation, and later re-enter the immutable image while
  retaining its generation lease. Callback execution is serialized across one
  Runtime Engine until general `Sendable` semantics exist: same-thread recursion
  is allowed, an active import cannot hop callback execution to another thread,
  and overlapping cross-thread callbacks fail closed. This common path covers
  native methods, initializers, completion arguments, and callback-property
  setters—for example UIKit animation/transition, `UIAction`/`UIAlertAction`,
  `UIViewController.present`, cell configuration,
  `DispatchQueue.async`/`asyncAfter`, `Operation`/`OperationQueue`, Timer,
  URLSession, NotificationCenter, `NSPredicate`, and `FileManager`
  enumeration. It is not a framework-specific list. If callback
  execution or result decoding fails, the wrapper returns its deterministic
  ABI value. An active importer retains the error and traps after the native
  frame returns; a detached escaping invocation reports Runtime telemetry.
  Source defaults omitted beside a callback are
  represented by a checked physical-to-logical projection and are supplied by
  the generated Swift invocation after SIL provenance and ownership validation.
  A representation-preserving `convert_closure` may only add MainActor to an
  otherwise ABI-identical closure. The Verifier rejects the reverse conversion,
  any ownership/result/effect change, and an escaping NativeImport that receives
  a converted lexical closure; the VM retains the logical restricted signature
  and copied capture context. Compiler-only `Optional.some` scope carriers are
  erased only when their sole semantic use is `destroy_not_escaped_closure`;
  other uses fail closed. Compiler-generated bound-method factories recover
  an erased nested MainActor result only from unanimous body-isolation evidence;
  source-written factories are not inferred or rewritten.
- Top-level non-suspending `async`, `async throws`, and `@MainActor async`
  entries. Exact generated Swift wrappers preserve their ABI while HLVM runs a
  body proven not to suspend.
- VM-owned `Any`, `is`, `as?`, and `as!`. A closed recursive logical descriptor
  distinguishes source types that deliberately share HLBC storage, including
  `Int`/`Int64`, `UInt`/`UInt64`, `Double`/`CGFloat`, String/Character,
  Substring/Array, and Array/ArraySlice. Recursive Optional, Array, Dictionary,
  Set, and tuple casts preserve those identities; ArraySlice and patch-local
  nominal values support exact dynamic identity. Key/element collisions created
  by recursive Dictionary or Set conversion retain Swift's terminating behavior
  as a controlled VM trap. The v1 descriptor admits at most 32 nested wrappers,
  64 tuple elements, and 256 UTF-8 bytes per tuple label. Swift existential
  metadata, native objects, and linear lifetimes never enter downloaded
  bytecode.
- Fully concrete default-argument generators. Production and development
  compilers link reachable `fA...` thunks and include them in transitive
  implementation fingerprints. This covers eligible callers in one complete
  module source set; cross-module public/package defaults, an ineligible caller,
  or a remaining generic ABI require a full build.
- Native Swift text rendering frozen into every new Shell: ordinary
  `Swift.print`, `Swift.debugPrint`, `String(describing:)`, and
  `String(reflecting:)`. Print operations preserve variadic
  separator/terminator semantics; the generic String initializers are lowered
  through a fixed `Any -> String` adapter after the compiler proves the source
  dynamic type is reconstructible. The shared codec supports recursive scalar,
  text, Optional, Array, Dictionary, and Set values, and every operation has a
  64 KiB output bound. No App catalog setup, generic metadata, witness table,
  new opcode, or contract version is required.
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
  functions and operators, simple imported C values, Selector, upcasts,
  Foundation value-overlay bridges, Objective-C protocol erasure, Swift
  `Any -> AnyObject` boxing, and validated String/Array Objective-C bridges.

### Synchronous closure capability matrix

This matrix is the reviewed v1 closure baseline. Native rows still require an
exact frozen or managed-Debug-generated NativeImport whose full callable
contract passes the checks above; the examples do not form an API allowlist.

| Area | Supported | Intentional boundary |
| --- | --- | --- |
| Formation and references | Closure literals and shorthand arguments; local/global functions; operators and overloads; local bound/unbound methods, including closed concrete and immutable closed-existential protocol witnesses; enum/Optional/Result cases; patch-local initializers/static factories; eligible Shell entries; representation-preserving NativeImport free/global functions, bound instance methods, and initializers | A direct-call-only default-argument projection cannot become a function value; unresolved, conditional, open-world, mutable-existential, or ambiguous witness dispatch remains rejected |
| Storage and higher order | Optional, tuple, Array, Dictionary value, concrete Result, patch-local struct/enum/class fields, mutable closure variables, and closure parameter/result positions; nested, recursive, and returned closures | Closure values do not enter Set keys/elements, VM-owned `Any`, Shell entries, or the general native boundary codec |
| Captures and ownership | Immutable snapshots, shared mutable cells, strong capture, safe `weak`, checked `unowned`, captured closures, copyable imported owners, and caller-owned `inout` borrowed by a verified lexical nonescaping closure | `unowned(unsafe)`, noncopyable captures, linear `inout` captures, and escaping capture of caller-owned `inout` are rejected |
| Invocation and errors | Synchronous nonthrowing/throwing calls, concrete typed throws, concrete rethrows specializations, normal/error inout cleanup, autoclosures, default generators, optional invocation, and `callAsFunction` | Async closure ABI, suspension, arbitrary runtime specialization, and general unwind cleanup are not implemented |
| Compiler-managed scopes | Direct-only `defer`, dynamically checked `withoutActuallyEscaping`, and type-generic synchronous `withExtendedLifetime`, including throwing and closure-valued results | `autoreleasepool`, `withUnsafe...`, and contiguous-storage scopes require their real native runtime or pointer lifetime semantics and are not approximated |
| Native callback parameters | Direct or Optional Swift closures and Objective-C blocks; nonescaping or escaping lifetime; synchronous nonthrowing parameters/results; MainActor provenance; checked defaults; bounded `Error` argument proxies; deterministic failure values | Throwing, async, or `inout` callback ABIs; C function pointers/context-pointer pairs; recursive or nonescaping nested callables; callable containers; results without a deterministic failure value |
| Native-origin callables | One direct or Optional escaping callable may arrive as an outer callback argument or NativeImport result and is invoked through the same typed closure path with identity, ownership, actor, deadline, and resource checks | A second callable layer, callable aggregates, or substituting an image-local closure for a native result is rejected |
| Common SDK use | UIKit animations/transitions/actions/presentation/configuration; `DispatchQueue.async`/`asyncAfter`; `DispatchGroup.notify`; Operation/OperationQueue; Timer; URLSession; NotificationCenter; `NSPredicate`; FileManager enumeration | Generic or throwing SDK closure declarations outside the exact profile, including generic `DispatchQueue.sync` closure overloads, require a normal build until a representation-erasing generated wrapper exists |
| Isolation and concurrency | Synchronous `@MainActor` closure values and callbacks; same-thread re-entry; escaping callbacks retain their original image/generation lease; callback execution is serialized | No general `Sendable` guarantee, overlapping cross-thread callback execution, custom global actors, actor-isolated `self`, or arbitrary executor hop |

### Rejected or intentionally incomplete

- Generic roots or any execution that still requires runtime generic metadata,
  runtime witness tables, unresolved/generic reabstraction, or dynamic
  specialization. Closed concrete and immutable closed-existential witness
  calls described above are compiler-resolved image calls and do not relax this
  runtime boundary.
  This includes opaque custom `Sequence` implementations whose iteration has
  not been normalized to a represented managed Collection; they are not
  redirected to the Swift standard library through NativeImport.
- True suspension: `await`, continuations, tasks, async callees, async closures,
  cancellation, and cross-suspension ownership or generation leases.
- Actor-isolated instance roots, custom global actors, and arbitrary executor
  hops. The limited `@MainActor async` leaf case above is distinct.
- A closure crossing a Shell Entry, or crossing NativeImport outside the exact
  callable profile above. Ordinary native values and the general boundary
  codec cannot contain closures; only an exact callback parameter or a direct
  or Optional native-origin callable result may use the typed handle boundary.
  Callback
  results without a framework-neutral failure value, throwing or async callback
  ABIs, `inout` callback parameters, recursive/nonescaping nested callable
  parameters or callable containers, and
  concurrent `Sendable` execution semantics remain unsupported.
  `unowned(unsafe)` is rejected because its dangling reference cannot be made
  safe, and weak/unowned stored properties are not yet a patch-local nominal
  layout feature. A caller-owned `inout` value may be captured only by the
  verified lexical nonescaping path above; an escaping capture remains
  fail-closed.
- `String.Index`, index-based String subscripting or mutation, UTF-8/UTF-16/
  Unicode-scalar views, locale-sensitive or Foundation text APIs, and
  Character properties not listed above. These remain fail-closed rather than
  being approximated through integer offsets or generic NativeImport. Also
  rejected are progression element types beyond the fixed-width integer and floating
  iteration surface above, exporting a Range/stride value across a Shell or
  NativeImport boundary, and function-local nominal type declarations. Move a
  non-exported patch-local struct or enum to file/module scope in an existing
  watched source file; no Shell rebuild is needed when the resulting
  declaration remains private to the HLBC image.
- User-defined `Hashable` semantics for Dictionary keys or Set elements. The
  VM-owned `Any` grammar admits only recursively VM-defined Hashable keys and
  elements, so no user witness executes implicitly. Its Swift Shell codec
  recursively materializes the supported scalar, text, Optional, Array,
  Dictionary, and Set family, but still rejects ArraySlice (whose nonzero
  public index base cannot be reconstructed through the type-erased boundary),
  tuple values, patch-local values, native objects, and closures. `Void` is
  likewise not erasable because HLVM represents it as absence of a value. Those
  failures do not weaken internal exact identity for ArraySlice, tuple, or
  patch-local values inside one verified image.
- Arbitrary new Swift metadata, a patch concrete class identity visible to
  native code, retroactive conformances, or changes to a Shell type's layout,
  superclass, or enum cases. The hosted Objective-C subclass above is a frozen
  superclass projection, not arbitrary Swift metadata generation.
- Swift protocol existential values at a Shell Entry or ordinary NativeImport
  boundary, conditional or imported conformers, and mutable existential
  opening/writeback. The supported immutable profile is closed over complete
  current-module image-local conformers and cannot safely be widened at those
  boundaries without introducing runtime Swift metadata. The separately
  proven Objective-C `!foreign` erasure is a frozen native `AnyObject` value,
  not an exception that exports this image-local representation.
- Generic or `inout` Shell entries, noncopyable roots, arbitrary borrowing and
  consuming ABI, typed-throws roots, general `rethrows` outside the concrete
  standard-library operations listed above, and general unwind cleanup.
- Closure scopes with additional native runtime semantics remain unsupported:
  `autoreleasepool` requires a real autorelease-pool boundary, while
  `withUnsafe...` and contiguous-storage callbacks expose pointer lifetimes.
  They are not approximated as `withExtendedLifetime` or as no-op closure calls.
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
| First use a public SDK member in a managed Debug body | Supported for a uniquely measured synchronous initializer, instance/static method, or readable/writable property when every boundary type is already representable in the frozen imported/Bridge surface and the declaration is valid at the Shell minimum OS. Closure-bearing methods are supported when every callback fits the exact synchronous, nonthrowing bridge-and-failure-value profile above; unfamiliar error bridges, async/generic callbacks or declarations, subscripts, and unrepresentable signatures require a full build |
| Add an ordinary top-level helper, private class instance method, or computed accessor in an existing source file | Supported when reachable from a changed root and its concrete signature/body fit HLBC; it remains private to that image |
| Ordinary direct recursion | Resolves to the function in the same immutable HLBC image |
| Deliberately call the previous generation from source | Not supported by HLBC; save/activate a restoring generation instead |
| Use a supported local closure or an already indexed same-image helper with an `@escaping` closure parameter | Lowered into the same image; closure return/capture is allowed only inside the pinned VM invocation |
| Use a fully static read-only KeyPath literal as a transform or direct projection | Stored patch-local struct/class fields, concrete getter chains—including an imported Objective-C property whose generated accessor resolves to an exact NativeImport—and static Optional chain/force/wrap components may compose into a typed zero-capture function; dynamic KeyPath values, captured components such as subscript indices, unproven components, and writable/reference-writable mutation are rejected because KeyPath objects are not HLBC runtime values |
| Use integer `Range`/`ClosedRange` iteration, numeric `stride`, or represented Range queries | `contains`, `overlaps`, `clamped(to:)`, bound projection, and the concrete iteration families above preserve verified Swift boundary, empty-range, signed-zero, direction, endpoint, zero-stride, and integer-extrema semantics. Progression values remain image-local and cannot cross Shell/NativeImport boundaries |
| Use `String`, `Character`, or `Substring` in supported text/Sequence APIs | Supported through validated grapheme and normalized Character-sequence representations, including Shell bridge round trips; `String.Index`, index-sensitive mutation, UTF views, and unlisted Character/Foundation APIs remain rejected |
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
