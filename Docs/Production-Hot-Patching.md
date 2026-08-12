# Production Hot Patching

[简体中文](Production-Hot-Patching.zh-CN.md)

Helix production patches are signed, build-specific HLBC programs. Engineers
write normal Swift, but a released App executes only verified bytecode through
the runtime that was shipped inside that App. There is no on-device compiler,
JIT, downloaded Swift source, or downloaded native dylib in this path.

## What must exist before an incident

Hot patching is prepared during the normal Release build. It cannot be added to
an arbitrary binary after it has shipped.

The Release pipeline must:

1. Freeze a Shell namespace, App identity, compiler, SDK, target, source set,
   and semantic compiler arguments.
2. Index declarations with the exact Swift frontend and decide which existing
   roots are patchable.
3. Generate Derived Sources containing permanent dynamic replacement bridges,
   exact Swift entry wrappers, and allowed native invokers. Handwritten source
   files are not rewritten.
4. Build and sign the App with `HelixAppRuntime`.
5. Finalize an HLXI archive with the linked Mach-O UUID and preserve the exact
   release source baseline and toolchain artifacts for future patch builds.

The App contains compact route, type, and native-import tables. Sensitive build
facts such as complete private source context stay in the server-side archive.

## From a Swift edit to HLBC

During an incident, an engineer checks out the exact released baseline and
changes an existing eligible implementation. The patch builder uses the full
module source set—not an isolated parser—to retain normal Swift name lookup,
overload resolution, private visibility, conditional compilation, generics,
and synthesized declarations.

```mermaid
flowchart LR
    E["Edited Swift body"] --> T["Exact module type-check"]
    A["Finalized HLXI + release baseline"] --> T
    T --> D["Interface and transitive body diff"]
    D --> S["Canonical OSSA SIL"]
    S --> L["HLIR lowering"]
    L --> B["HLBC 1.10 encoder"]
    B --> V["Independent verifier"]
    V --> P["Signed .hlxp"]
```

The build fails before packaging when it sees an interface, layout, isolation,
source-membership, toolchain, SDK, unsupported SIL, or unapproved native-call
change. Helix does not weaken these checks to make a patch build succeed.

HLBC is a versioned, typed register bytecode, not serialized SIL. It replaces
compiler-private pointers and numbering with stable IDs, explicit ownership,
effects, capabilities, and bounded operations. The independent verifier
reconstructs control flow, register types, ownership, access scopes, call
signatures, capability requirements, and resource constraints without trusting
the patch compiler.

## Calling existing Swift from a patch

A patch cannot call arbitrary code merely because a Swift declaration exists
in the App. Calls cross one of these frozen boundaries:

- another function included in the same HLBC image;
- an eligible Shell entry identified by `FunctionKey` and `EntryIndex`;
- an allowlisted `NativeImportID` backed by a generated, exact-signature Swift
  factory in the installed App.

Native imports may be listed explicitly or discovered at build time from a
file, module, or project scope. Project scope expands into individual canonical
descriptors and generated invokers; it is never a wildcard interpreted on the
device. Adding a call in a patch works only when the released Shell already
contains the matching capability and its effects are allowed by policy.

This design avoids relying on unstable Swift symbol lookup, metadata guessing,
or an unrestricted `dlsym` API. It also means that expanding the callable
native surface normally requires a new App release.

## Package trust and installation

A `.hlxp` contains a canonical manifest and one or more hashed payload records.
The implemented release builder currently accepts only `internalHLBC` and
`enterpriseHLBC`. It rejects `appStoreHLBC` and `controlledNative`.

The client chain includes:

- an Ed25519 root/leaf certificate model and package signature verification;
- bounded, sequential download with incremental SHA-256 validation;
- target checks for bundle/build, Shell interface, Mach-O UUID, architecture,
  OS range, policy, signer, time, and rollout rules;
- a canonical, immutable verified package store;
- monotonic campaign revisions and anti-rollback state;
- a nonce-based activation write-ahead log;
- immutable Runtime generations, active health proof, Crash Guard, last-known-
  good recovery, revocation, and rollback to previous packages or originals.

```mermaid
sequenceDiagram
    participant C as "Download or local mock"
    participant P as "Patch verifier and store"
    participant R as "Runtime Engine"
    participant B as "Generated Swift bridge"
    participant V as "HLVM"

    C->>P: "Signed .hlxp bytes"
    P->>P: "Verify trust, target, policy, hash, HLBC and anti-rollback"
    P->>R: "Prepare immutable generation under WAL"
    R->>R: "Atomically publish all routes"
    B->>R: "Pin route snapshot"
    alt no patch route
        B->>B: "Call previous/original Swift body"
    else patched route
        B->>V: "Encode arguments and invoke verified entry"
        V-->>B: "Typed result or declared business error"
    end
```

A server control plane is not required to test this client chain. The checked-
in Hot Patch demo can copy a generated package into the Simulator App's inbox
as a mock download; the App still follows the normal verification, store, WAL,
activation, health, and rollback path.

## Generation behavior

Activation never updates routes one function at a time. Helix builds a complete
immutable generation, validates every route and capability, then publishes one
snapshot. An outer bridge call pins that snapshot for the complete synchronous
or asynchronous call chain, including permitted native re-entry. Concurrent
activation therefore affects later calls without changing the generation seen
halfway through an existing call.

Inherited routes are materialized into the published snapshot. The registry
keeps the active snapshot and, by default, its direct rollback predecessor;
older snapshots are compacted unless an in-flight lease still needs them. Such
a lease is self-contained, so compaction never redirects or invalidates the
running call. Registry count and unique-artifact byte ceilings are checked
before publication, and a capacity failure leaves both active routing and the
generation-ID high-water mark unchanged. Compaction never makes an old ID
available to ordinary activation. Verified durable recovery is the narrow
exception: it may rehydrate the exact historical package/ID after routing has
returned to originals, while the high-water mark remains unchanged and all
later activations must still exceed it. Reinstalling the exact package that is
already active is also idempotent: Helix re-verifies current trust, target,
policy, expiry, revocation, and anti-rollback state, then returns the existing
lease without creating a WAL record or advancing the generation high-water mark.

If no patch is active, the permanent Bridge invokes the original Swift body.
The no-patch fast path does not construct a VM call frame; it still pays the
cost of the dynamic entry and generation lookup, which remains part of the
device performance qualification.

## Current language boundary

The current wire versions are HLBC 1.10 and HLXI 2.5. The implemented subset
includes common integer and floating-point operations and conversions, Bool,
String operations and interpolation, one-grapheme Character literals for the
bounded String predicate path, tuple/Optional including address projection,
Array and Dictionary value semantics, VM-owned `Any` and common dynamic casts,
half-open `Range<Int>` loops, structured
control flow, file- or module-scope patch-local struct/enum and concrete
`Result` values, payload-carrying local errors, scoped patch-local
`inout`/`mutating` helpers, synchronous patch-local closures including
same-image `@escaping` return/capture flows, fully concrete compiler
specializations and default-argument generators, an automatically frozen
`Swift.print` NativeImport, and top-level non-suspending `async`, `async throws`,
and `@MainActor async` entries.

It is not arbitrary Swift. Generic roots, runtime metadata/witness dispatch,
new native classes, function-local nominal declarations, stored-layout changes,
closure persistence or native/Shell boundary crossing, throwing/async closures,
true `await`/continuations, actor-isolated `self`, custom global actors,
unrestricted pointers, reflection-based field access, and unregistered native
APIs are rejected. See
[Capabilities and Limits](Capabilities-and-Limits.md) for the practical matrix.

HLBC carries a verifier-checked source map from function/block/instruction
coordinates to logical Swift locations. Production packaging removes build-host
absolute paths. If execution traps, HLVM reports the exact program counter and
Runtime enriches it with the pinned generation, Shell entry, function, and
logical file/line/column; this is diagnostic mapping, not an interactive
breakpoint or expression-evaluation debugger.

## Building a package

The exact inputs depend on the generated Release integration, but the build
surface is:

```bash
swift run helix patch build \
  --archive Build/Shell.hlxi \
  --config Config/Release.json \
  --certificate Config/LeafCertificate.json \
  --private-key Secrets/LeafPrivateKey.json \
  --trusted-root Config/TrustedRoot.json \
  --output Build/Patch.hlxp \
  Sources/Feature/A.swift Sources/Feature/B.swift
```

The source list must represent the complete module required by the frozen
archive. Production signing can be provided by an injected signing service so
the builder does not need direct access to a long-lived private key.

For Xcode integration, the Patch Aggregate Target must support both `iphoneos`
and `iphonesimulator`. Select the same destination family used to build and
audit the frozen Release Shell: a device archive produces an iOS/arm64 package,
while a Simulator baseline produces an iOS Simulator package. The action never
converts one platform's baseline into the other.

## Distribution status

The repository implements the production client and package-building mechanics,
not an authorization to bypass platform policy. The App Store channel is
explicitly `policyBlocked`. A real deployment still needs a documented target
distribution, legal and security approval, device and business-corpus
qualification, operational control-plane design, and an emergency disable
process. Technical success in the Simulator does not close those gates.
