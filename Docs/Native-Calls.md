# Native call identity and catalog

This document records the implemented version 1 baseline for describing and
authorizing calls from HLBC into code already installed with an application.
The stable identity, catalog, archive, bytecode, verifier, generic Objective-C
message invoker, restricted C invoker, and reusable Swift Adapter Packs
described here are implemented. Catalog-backed on-demand development adapters
are also implemented for authenticated Simulator and macOS Live Reload; signed
Release capability projection, package binding, and device-side validation are
implemented as the production `NativeCapability.Manifest` path.

## Two IDs with different jobs

`NativeCall.Key` is the stable identity of an API call. It is SHA-256 derived
from the canonical `NativeCall.Descriptor` under the
`HLX.NativeCall.v1` hash domain. It does not include a project namespace,
Shell build number, compact table position, execution deadline, or policy.
The same canonical descriptor therefore has the same key wherever it is
cataloged.

`NativeImportID` is only a compact, zero-based slot in one Shell or HLBC image.
It keeps bytecode and runtime tables small. A patch cannot use that slot as
authority: every import also carries its stable key, complete descriptor,
contract, and required capability.

## What a descriptor proves

A canonical descriptor records:

- backend, module, owner, member, entry point, dispatch kind, and an explicit
  instance receiver argument;
- logical Swift parameter/result spellings, labels, ownership, callback
  lifetime, autoclosure, throws, async, and isolation;
- physical calling convention, ABI value kinds, native encodings and layouts,
  Swift direct/guaranteed/indirect conventions, default-argument sources, and
  error convention;
- the Objective-C runtime class, method family, lexical superclass, property
  accessor identity, and supported `NSError **` failure convention when the
  backend is Objective-C;
- effects and per-platform availability.

The stable adapter boundary's ownership is separate from the compiler-proven
native ABI convention. For example, a Bridge value can be owned by Helix while
the underlying Swift call receives it as `@in_guaranteed`. Compiler ownership
markers are removed from the canonical type spelling and retained in the ABI
convention field, so distinct machine call shapes cannot collapse to one key.

Descriptor canonicalization bounds text and collection sizes, normalizes Swift
spellings, checks balanced type delimiters, validates layouts and encodings,
requires exact receiver and argument projection, and keeps callback lifetime
authority complete. An Optional-none default may target only a nullable or
Swift Optional ABI slot. Objective-C and C descriptors cannot masquerade as a
typed Swift adapter.

`NativeImportContract` remains separate from identity. It controls execution
policy such as deadline, main-thread permission, access class, and callback
authority. Changing only a deadline does not rename the API. Every trust
boundary nevertheless validates the descriptor and contract together.

## Native API Catalog

`NativeAPICatalog.Document` is an automatically maintained, canonical JSON
snapshot for one module and toolchain environment. Its cache identity includes:

- provenance, Xcode product build, SDK product build, and compiler fingerprint;
- target triple, minimum deployment, and Swift language mode;
- module content, module search paths, and dependency graph hashes;
- catalog rules version, which remains version 1.

Each entry stores the stable key and descriptor, policy contract, Swift lookup
names, compiler symbols, support or rejection reason, and one executable
binding strategy. A supported binding must import its target module. Generic
invoker bindings cannot smuggle in a per-API adapter identifier; Swift and
builtin bindings require one.

The codec rejects oversized or noncanonical JSON. The immutable Registry
rejects one cache identity naming two snapshots and rejects two catalogs that
disagree about an existing key. Identical snapshots load idempotently. Lookup
is available by stable key, Swift spelling, compiler symbol, and native entry
point; every result resolves back to the same descriptor.

`NativeAPICatalog.Builder` now produces that snapshot from a real imported
module rather than from project Type IDs. It extracts the module's public
Symbol Graph, nominates concrete public class/struct/enum members and public
global functions, and asks the captured Swift frontend to compile every
candidate. The exact Typed AST and SIL evidence is projected through the same
native-import classifier used by application builds. Objective-C and C entries
therefore bind to their generic invokers, while concrete Swift entries receive
a deterministic Adapter ID derived from the stable call key. Signature-only
native types are retained in an opaque compiler projection so later project
binding does not lose a type that was absent from the owner list.

Independent 256-candidate probe batches run with at most four workers and are
merged in original batch order. Recursive failure isolation remains local to
one batch, metrics are combined after all workers join, and the earliest batch
error is reported deterministically. A shared generic SIL implementation does
not collapse distinct logical APIs: Catalog projection treats the exact owner,
USR, and signature as the identity evidence. Conversely, a Swift protocol
default or synthesized operation owned by another module is not published in
the current module's Catalog. Objective-C or C module disagreement remains a
hard evidence error.

The complete validated document and compiler projection are cached together
under the module identity. Absolute project and DerivedData locations in Swift
and Clang module-loading flags are replaced by ordered placeholders; the
identity's module-content, semantic search-space, and dependency-graph digests
remain authoritative. Consequently two projects using byte-identical module
inputs can reuse one Catalog even when their physical search roots differ.
Every read still validates canonical encoding and bounds, reconstructs all
entries from the compiler projection, and requires exact equality with the
stored document. Project-local Type IDs never enter a descriptor or stable
key.

This whole-module producer deliberately does not invent an ABI for open
generics, protocol existentials, type aliases whose representation is unknown,
async declarations, or declarations rejected by the exact probe. Concrete
generic specializations observed by an application remain available through
the existing source-rooted compiler path. Catalog-first Prepare consumption
and automatic identity discovery are separate integration stages; until those
are connected, Release capability publication continues to use the
build-proven imported-type boundary described below.

## Trust-boundary flow

The release archive stores the complete descriptor and contract. Its device
projection keeps the same authority but omits build-only compiler symbols.
HLBC import requirements repeat the key, descriptor, contract, and capability.
The Shell interface and runtime registry retain both the compact slot and
stable key.

Before execution, validation requires all of the following:

1. the compact slot exists in the installed Shell;
2. the patch key is allowed by runtime policy;
3. patch and Shell descriptors, contracts, and capabilities are exactly equal;
4. deriving the key again from the descriptor produces the stored key;
5. logical types, effects, callback lifetimes, and the physical projection are
   internally consistent.

Duplicate compact slots and duplicate stable keys are rejected. Diagnostics
carry the stable key and, when the bytecode source map has one, the original
Swift file, line, and column. Runtime logs no longer need a build-local integer
to identify which API failed.

## Release Native Capability Manifest

Release Prepare uses the managed production calling-surface policy. It promotes
every compiler-qualified Catalog candidate inside the imported-native-type
boundary proved by that successful App build; the project does not maintain an
API allowlist. Baseline-used and newly published candidates therefore share one
canonical schema-1 `NativeCapability.Manifest`, with dense compact IDs and the
exact key, descriptor, contract, and required capability for every entry.

The boundary is intentionally evidence-based. It includes members of imported
native types and concrete generic specializations already proved by the App
frontend when their complete Bridge types and ABI are representable. It is not
a wildcard over every declaration in every linked framework, and it does not
invent new boundary types, open generic specializations, arbitrary selectors,
C symbols, or Swift ABI calls. A patch may first-use any entry published in the
released Manifest. If no exact entry exists, Patch Compiler reports that a
normal App release is required.

The generated Bridge reconstructs the same Manifest from its code-signed Shell
table, while Prepare also emits canonical `NativeCapabilities.json` for audit.
The table itself is embedded as a deterministic schema-1 `ShellDocument`, not
as thousands of Swift initializer expressions. Its bounded Base64 chunks are
decoded canonically and validated once by a lock-protected loader; concurrent
Runtime, provider, and manifest factories reuse the same immutable Shell or the
same deterministic failure. This keeps descriptor growth in data and avoids
making Swift parsing and constraint solving scale with the number of entries.
Release finalization compares that file with the finalized archive and pins its
SHA-256 in the release baseline. Every signed patch target repeats the Manifest
hash alongside the Shell interface hash and Mach-O UUID, so changing any entry
or Release identity invalidates target verification.

Before a production Runtime is installed, Helix requires the Manifest, Shell,
and immutable synchronous/asynchronous registries to have exactly the same
inventory and entry data. Objective-C entries then re-resolve the declared
class, selector, dispatch target, arity, and complete runtime type encodings on
the current device. C has no equivalent runtime signature metadata, so its
preflight instead verifies the compiler-bound address, configured finite
trampoline shape, availability, and policy; it never accepts a patch-provided
pointer or signature. Successful device ABI evidence pins one Manifest hash per
Runtime Engine and is reused thereafter; a different hash is rejected,
structural equality is checked on every entry path, and failures are never
cached.

## Generic Objective-C execution

A compiler-proven Objective-C declaration whose logical and physical types fit
the supported ABI matrix is bound directly to one `Runtime.ObjectiveCInvoker`.
Bridge generation emits structured descriptor data rather than a Swift wrapper
for each selector. The common matrix currently includes Objective-C objects and
nullable objects, exact-width integers and floating-point values, `Bool`, common
CoreGraphics/UIKit structures, properties, instance/class methods,
initializers, supported `NSError **` imports, and a reusable set of synchronous
Objective-C Block shapes. Swift overlays whose value representation cannot be
proved equivalent still use an exact generated Swift adapter.

At runtime the Bridge filters the already validated Shell document and creates
all Objective-C registrations through one data-driven construction site. It
does not repeat a `ResolvedNativeImport` or `ObjectiveCInvoker` expression per
selector. Explicit factories are now restricted to builtin or exact Swift
adapter backends, so an Objective-C or C descriptor cannot bypass its generic,
ABI-checked execution path.

The same rule now applies to imported Objective-C reference types. Compiler
evidence records the exact runtime class name in the native type row, and that
identity participates in the Shell hash. One Bridge helper turns all such rows
into checked TypeOps at startup; each box is accepted only when Objective-C
ancestry metadata says the object is an instance of that class. This removes
per-class generic Swift factories without treating a Clang enum/structure,
protocol existential, Swift value overlay, or project class as a dynamic
Objective-C reference.

Module provenance is not inferred from `UI`/`NS` prefixes or from the owning
class alone. Ordinary methods and properties resolve their exact Clang USR in
the imported module indexes, so a category can belong to a framework different
from its class. An inherited initializer instead uses the exact concrete class
module and allocates that Swift constructor result, not the superclass named by
the inherited `init` declaration. Ambiguous provenance keeps the Swift adapter.
For a custom Objective-C property accessor, a compiler `#selector` probe must
also recover the exact getter or setter; the source spelling is never guessed.

The descriptor keeps the declaration class separate from the class-message or
initializer dispatch class. For example, an inherited
`UIButton.setAnimationsEnabled` call is authorized and ABI-checked against its
`UIView` declaration but sends the class message to `UIButton`; an inherited
`UIViewController()` initializer resolves `init` on `NSObject` but allocates a
`UIViewController`. Both identities participate in the stable key. The
compiler admits this route only when the Typed AST mangling proves the concrete
source metatype or constructor result; otherwise it retains the Swift adapter.

Ordinary Objective-C dispatch and lexical `super` dispatch also have distinct
stable identities, for both methods and properties. The compiler associates
the Typed AST expression with one exact SIL instruction and records the
lexical superclass only for `super`. If that evidence is missing or ambiguous,
Helix fails closed or keeps the exact Swift adapter; it never silently turns a
`super` call into dynamic dispatch.

The Swift layer projects verified VM values and callback authority into ABI
slots. A small Objective-C shim then resolves the exact selector against the
cataloged declaration class (or the pinned lexical superclass), compares every
runtime type encoding and storage kind, verifies that the separately recorded
class dispatch target inherits from that declaration class, and invokes the
concrete receiver through `NSInvocation`. Ordinary Objective-C override dispatch is therefore
preserved, while a selector that exists only on an unexpected runtime subclass
cannot expand the cataloged authority. Receiver ancestry is read directly from
the Objective-C runtime rather than through overridable `isKindOfClass:`
messaging, and an ordinary dynamic override must retain the declaration's
complete ABI before it can be invoked. Property calls use the compiler-proven
accessor selector and deliberately do not require optional Objective-C property
metadata, which system frameworks may omit at runtime. The shim captures
Objective-C exceptions, handles initializer and retained/autoreleased method
families, and returns object results at one explicit ownership boundary. The
runtime also rechecks receiver class, platform availability, nilability,
structure encoding/size/alignment, deadline, MainActor entry, temporary
storage, and result length before decoding the result.

This removes per-method executable Bridge code for supported Objective-C calls;
it does not permit arbitrary selectors. Every executable call must still be an
exact compiler-proved descriptor. The linked Shell keeps used imports in its
compact baseline and the authenticated build receipt keeps unused managed-development
candidates. On first use, the development compiler deterministically assigns a
session-local slot after the linked prefix and the App constructs the same
generic invoker from that descriptor. The Shell interface hash does not change.
This growth is permitted only by the authenticated development transaction;
production still accepts only its published capability projection.

## Restricted C execution

Imported C functions no longer require one handwritten or generated executor
per symbol when compiler evidence proves a supported physical ABI. Discovery
records the declaration's Clang USR, owning module, exact C entry point,
logical Swift signature, calling convention, layouts, effects, and
availability. Generated Bridge code takes the address of that exact imported
declaration as an `@convention(c)` function and registers it with one
`Runtime.CInvoker`; the runtime never searches the process by a source string.

The development-only first-use path has a deliberately different binding
step: after the authenticated compiler selects an exact receipt candidate, the
App may resolve that candidate's fixed C entry point in the already linked
process and feed the address into the same finite `Runtime.CInvoker` matrix.
Patch bytes cannot provide a free-form symbol or ABI. Descriptor/key
rederivation, target/SDK identity, process linkage, and the runtime ABI checks
must all succeed. Release execution continues to use the address bound by the
published Bridge/capability table.

The implementation uses a finite ahead-of-time trampoline matrix rather than
`dlsym`, `libffi`, a descriptor-driven `unsafeBitCast`, or a user-supplied
pointer. Generated Bridge code performs one compile-time-typed erasure from the
exact imported `@convention(c)` function to its stored address; it does not use
that operation to invent a calling signature. The current matrix covers bounded
homogeneous scalar calls with up to four arguments and the explicitly validated
Apple geometry value shapes used by the Bridge. Each slot is checked for
calling convention, byte width, alignment, argument count, result shape,
availability, deadline, and MainActor entry before the trusted function pointer
is invoked. An unsupported mixed, variadic, pointer-bearing, indirect,
throwing, callback, or otherwise unfamiliar ABI remains on the exact Swift
adapter route or is rejected; it is never approximated.

The real UIKit Demo keeps a behavior-neutral `CACurrentMediaTime()` probe. It
therefore exercises the C descriptor, generated function address, common
runtime invoker, MainActor policy, result decoding, and final object link in an
ordinary Xcode build.

## Reusable Swift Adapter Packs

Calls that require Swift semantics—such as value overlays or an ABI outside the
generic invoker matrices—still need compiler-generated Swift. They are now
classified by the declaration's stable Swift USR and native module, grouped
into one deterministic Adapter Pack per module, and sorted by `NativeCallKey`.
The large application Bridge references stable C-ABI factories; each factory
returns a type-erased synchronous or suspending native adapter body while the
actual Swift call remains in the Pack's native module context.

Pack source and Pack object are separate content-addressed facts. Source
identity includes the compiler/SDK/target/deployment/transform environment,
module, exact ordered imported modules, and exact ordered keys. Object identity
additionally includes the toolchain binary, Xcode build, normalized compiler
invocation, complete
non-SDK compiler-input snapshot, module maps, and source hash. Cached objects
are bounded Mach-O files and are revalidated for architecture and platform on
every materialization; corrupt entries are quarantined and rebuilt. Packs are
compiled independently and relocatably linked with the stable application
Bridge, so adding or changing one Pack does not force all other module Packs to
recompile.

This is type erasure at a generated boundary, not generic invocation of the
private Swift runtime. Release execution still needs an exact descriptor and a
Pack entry published with the App; the common runtime cannot invent an
arbitrary Swift ABI from a name.

For authenticated Live Reload, unused receipt candidates remain data-only and
do not bloat the permanent Bridge. If newly compiled HLBC actually references
a missing Swift candidate, Hub renders only those exact Adapter bodies with the
captured compiler job, signs and Mach-O-validates one deterministic image, and
caches it by compiler, Xcode/SDK, target, deployment, dependency graph,
normalized compile/link inputs, generated source, descriptor, and contract.
Objective-C and C candidates never enter this compiler path.

The canonical `DevelopmentPayload` frames the HLBC, exact promoted imports,
Adapter image descriptors, hashes, and image bytes into one authenticated
transaction. The App rechecks compiler fingerprint, SDK build, target, Shell
hash, descriptor/key identity, image architecture/platform/install name/UUID,
code signature, dependency policy, and required exports. It builds a candidate
baseline-plus-session native table, verifies HLBC against that table, and only
then atomically activates a generation. A failure may leave an already mapped
image charged to the process budget, but it never publishes the import or
replaces active code. Each generation and every escaping callback lease pin an
immutable native-capability snapshot.

Overlapping saves can independently compile the same missing Adapter before
either activation completes. Publication is therefore idempotent for an exact
session-equivalent import: the second activation reuses the published invoker
and does not map or charge its redundant image. This is not a name-based
fallback; any identity, Descriptor, ABI, contract, or binding difference fails
closed, and mixed transactions still load every image required by genuinely new
imports before publication.

Simulator and macOS are the currently qualified on-demand Swift Adapter
targets. Physical iOS rejects this path and asks for an App rebuild until its
development signing/loading matrix is separately demonstrated. Raw HLBC is no
longer accepted by this development transport: even an adapter-free generation
uses the version-1 development envelope. Reconnect identity reports published
development keys and mapped Adapter inventory so Hub can reuse the session
Registry without recompiling an already active Adapter.

All product, protocol, catalog, archive, and bytecode versions remain 1.
