# Native call identity and catalog

This document records the implemented version 1 baseline for describing and
authorizing calls from HLBC into code already installed with an application.
It is intentionally narrower than the eventual execution backends: the stable
identity, catalog, archive, bytecode, verifier, and runtime contracts described
here are implemented; generic Objective-C/C invokers and reusable Swift Adapter
Packs are introduced in later stages.

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

## Current execution boundary

At this stage, existing generated exact-signature Swift NativeImport factories
remain the executable backend for imported framework and application calls.
The new descriptor and key replace their former project-derived identity and
are already used by archive, bytecode, verifier, Bridge generation, runtime,
and patch build contracts. The Catalog is the shared resolution model, but it
does not yet make an unseen Objective-C, C, or pure-Swift call executable by
itself. The later invoker and Adapter Pack stages must install a matching
binding before such a call can run.

All product, protocol, catalog, archive, and bytecode versions remain 1.
