# Compiler identity and diagnostic evidence

[简体中文](Compiler-Identity.zh-CN.md)

A name printed by the compiler is a lookup hint until its authority and scope
are established. This inventory covers the source-to-receipt pipeline and its
SIL, Catalog, cache, and project-installation boundaries. It is a review baseline;
new compiler output and integration evidence can require narrower rules.

| Key family | Authority and disambiguation | Rejection and consumers |
| --- | --- | --- |
| Source membership | Canonical physical path identifies a compiler input within one invocation; logical path plus content hash identifies a source in the receipt | Request validation rejects duplicate logical paths and physical aliases; typed AST must cover exactly the requested files |
| Source nominal declaration | Compiler USR, with logical file scope for private declarations; qualified spelling is a scoped lookup | `SourceNominalIndex` resolves file-local names separately. Conflicting USRs and same-scope names report both declarations. Ambiguous printed private layouts cannot become frozen value layouts |
| Imported nominal | Established runtime/ABI identity precedes normalization of qualified/relative Swift spelling using proven module roots | `ImportedNominalIdentity` is shared by discovery, merge, aliases and bindings. Conflicting module, representation or isolation facts remain errors; proven flat Clang runtime spellings are not competing Swift overlays; normalization does not merge unrelated nested names |
| Imported operation and selector | Declaration USR/descriptor, signature, owner, dispatch, accessor and measured ABI; selector probes also include their imported-module context | A common implementation symbol does not equate API declarations. Candidate sets are deduplicated before disjoint probe batches; generated probe indices only identify members of that exact batch |
| SIL function | A concrete `sil @symbol : $type { ... }` definition establishes symbol identity within that SIL file | Repeated definitions reject with both SIL lines and types. The derived function index refreshes on public array mutation and excludes duplicates. Typed-AST resolution uses exact symbols first; colliding source locations require structural compiler symbol roles and closure discriminators. Unknown roles remain candidates; ambiguous functions are never selected by order |
| SIL debug scope | Numeric scope ID within one SIL document; an inherited scope keeps its own identity even when locations coincide | Duplicate IDs reject with both source records. `parent @name` supplies declaration location only for a concrete function definition. Debug-only names such as `__unknown_macro__` are not function identities; their locations remain available by scope ID |
| SIL witness-table occurrences | SIL document and record line retain each occurrence; witness targets retain exact compiler symbols and module | Equal printed type/protocol names can denote distinct local declarations. Preserve every record, quarantine colliding type lookups before conditional/completeness filters, and never select a conformance by order |
| SIL printed type and member aliases | Unique compiler-proven nominal/type aliases within the relevant module and source scope | `TypeEnvironment` excludes ambiguous private type summaries and fails when a required layout or dispatch cannot be proven; short names never grant a layout by themselves |
| SIL source-module map | Explicit compiler `#fileID` to path mapping | A path mapped to conflicting modules rejects with the path and both module values; debug coordinates are provenance, not persisted identity |
| Native Catalog and receipt keys | Validated versioned artifact identity, exact compiler/toolchain/SDK/target and canonical descriptor or TypeID | Snapshot/receipt validation precedes unique-key maps. Hash equality is useful only with the corresponding authenticated or validated record; runtime lookup by display name is not a fallback |
| Compiler facts and caches | Exact toolchain, invocation, source/dependency content and transform identity; checkpoints also bind physical paths | `CachedAdapter` validates request/source uniqueness before maps, then confirms inputs again. Checkpoint hits are reparsed. Changing frontend identity interpretation changes the transform hash so old module receipts cannot bypass the new checks |
| PBX objects and configurations | Object ID within the root `objects` dictionary; configuration name within its owning configuration list | Duplicate dictionary keys and repeated configuration names reject with their scope and object IDs. Nested `TargetAttributes` keys do not identify top-level target records |

These compiler-identity changes do not alter a shipped Shell/patch wire schema,
nominal ID, or public symbol spelling. They change the local transform identity and therefore
requires rebuilding affected cached Shell facts. Equal locations for the same
real function remain valid. A placeholder-looking name that actually has a SIL
function definition must still satisfy the function uniqueness rules.

Fail-closed messages must include the observed competing values, their origin,
and a locatable example for each distinct fact already available at the decision
point. For example, a declaration-location conflict includes the function symbol,
both scope IDs and both file/line/column positions; a source nominal conflict
includes USR, qualified spelling, logical source, UTF-8 offset, kind and scope.
Keep this evidence in diagnostics rather than extending persisted identity with
debug-only details. Repository review rules enforce the same requirement.

The debug-only parent regression is a SIL grammar fixture based on reported
compiler output. The real system-framework integration test separately enables
`-g` and verifies that the replay emits debug scopes, alongside Objective-C bridging, C++ interoperability, standard-library macros and
explicit module compilation. That test exercises the configuration combination;
it does not establish the minimal Swift program that emits `__unknown_macro__`.
Replay preserves `-g`, `-gline-tables-only`, and `-gnone` in their captured order;
argument-selection tests cover those levels independently.

SIL declaration summaries inherit `private`/`fileprivate` extension access as a
default for immediate members; an explicit member modifier overrides that
default, while a private nominal owner still limits its children. Ambiguous
private layouts and their descendants remain unavailable. Witness tables retain
all same-spelled occurrences, including empty marker conformances. An ambiguous
conforming type and its descendants cannot supply a layout, static witness, generic proof, or
existential case through a printed-name lookup. Unrelated declarations remain
available; exact witness-symbol membership is indexed per module. This does not
claim support for lowering the ambiguous local types themselves.

Exact AST USR/SIL symbol matches remain the fast path. For source-coordinate
fallbacks, receipt analysis batches structural trees from the captured toolchain's
`swift-demangle --expand --tree-only`, including unique candidates. The `Static`
wrapper preserves the underlying getter/function role; addressors, witness and
reabstraction helpers, partial-apply forwarders, and Objective-C/C adapter
attributes cannot stand in for a Swift source declaration. Explicit closures and
autoclosures remain distinct, and only the closure entity's own discriminator
constrains its match. Unknown wrappers/roles and remaining same-role collisions
fail closed with every symbol, ABI, wrapper, role and location. Analysis gathers
fallback candidates before lookup so unique closures also use bounded batches;
exact USR matches require no symbol-tree subprocess.


Declaration discovery can be scoped by logical file and can exclude a proven
source declaration when a consumed AST/SIL mapping is ambiguous or absent.
The compiler USR plus logical file owns the entire accessor/closure group; no
candidate is guessed and partial body operations are rolled back. Global compiler,
source, type, ABI and Catalog checks remain mandatory. Live Reload defaults to
local exclusion; Hot Patch/headless default to strict, with explicit overrides.
The optional policy is bound to receipt/Prepare cache identities; all compiler
inputs, including files outside scope, retain whole-module invalidation authority.
Host Plan v2 carries the scope; v1 remains readable without new options. See
[large-project integration](Large-Project-Integration.md#declaration-scope-and-local-rejection)
for defaults, diagnostics, and migration boundaries.

A flat Objective-C runtime spelling, including its observed-module or `__C` /
`__ObjC` qualification, is an ABI spelling only with exact reference/runtime
evidence. It does not compete with an observed `NS_SWIFT_NAME` nested overlay.
Nongeneric normalized and raw observations regroup by that runtime authority; contradictory
runtime facts for one canonical identity still reject before normalization.
Objective-C lightweight generic instantiations retain their type arguments despite
runtime erasure. This does not equate arbitrary nested Swift spellings or distinct runtime classes.

SIL inspection reports component-specific evidence independently. Only validated
function definitions and debug scopes supply function-location facts for AST
mapping; malformed type summaries or conformance records cannot supply type or
operation facts. Conflicts in independent mappings are aggregated. These checks
share the normal parser's implementation and never create a partial File.
Diagnostic JSON separately migrates to schema 2 with optional `requestedStages`;
legacy absence means full receipt scope. Selected passes qualify only their
checks and dependencies, as specified in [the diagnosis guide](Large-Project-Integration.md#collect-independent-frontend-failures).

The compiler proxy now retains `FrontendAttempt.hlxswiftc` before compilation
for `helix xcode preflight` (default `inputs,typed-ast`). Only a successful compile
updates `FrontendInvocation.hlxswiftc` and invokes post-compile work. Input-only
preflight does not emit AST/SIL or scan the dependency cache. Typed checks still
require available compiler dependencies, and selected-check success does not
prove full receipt or runtime support. See [preflight](Large-Project-Integration.md#preflight-before-a-successful-build).
