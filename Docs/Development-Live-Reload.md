# Development Live Reload

[简体中文](Development-Live-Reload.zh-CN.md)

Helix Live Reload shortens the edit–run loop for an already running Debug App.
After the one-time Xcode integration and Dev Shell build, saving the body of an
eligible Swift declaration can compile a new generation, transfer it to the
Simulator, activate it in the same process, and refresh the affected UI.

This is a development feature. It is isolated from production packages, keys,
storage, and lifecycle.

The App does not compile or import generated Swift. The Feature target keeps
its original sources; an App build phase compiles Helix's generated Bridge into
a validated object under DerivedData and links it into the executable. A stable
C provider symbol lets `DevRuntime.ApplicationSession` discover the Build
Contract, Shell interface, Runtime factory, and Bridge installer automatically.

## Xcode Run session handoff

The shared Live Reload Scheme starts one authenticated daemon in its Run
pre-action and writes a mode-`0600` custom LLDB init containing the
single-session launch material. The init first configures
`target.env-vars` as the fast path for LLDB-owned launches. It also starts a
bounded LLDB Python installer because Xcode can source the init before the
real App target exists and discard state attached to its temporary target.

The installer waits for a running real target in which the exported
`helix_dev_runtime_handoff_probe` symbol has resolved. It briefly stops that
process, runs one LLDB command-interpreter expression that injects every
environment value, and resumes the process in a `finally` path. The expression
short-circuits on failure and writes `HLX_DEV_HANDOFF_READY=sessionID` last, so
Runtime never consumes a partially injected credential set. This direct
handoff avoids mutating `SBBreakpoint` options from a background Python thread;
Xcode 26 testing showed that a breakpoint could be created while its command,
one-shot, and auto-continue properties were silently lost.

When its initial environment is empty, `DevRuntime.ApplicationSession` polls
the C entry point explicitly for up to twenty seconds, five seconds longer than
the installer deadline. The probe proves that the Dev Runtime image is loaded
and gives the App a bounded point at which to observe the completed handoff; it
is not used as an injection breakpoint.

The probe is not a dispatch hook and has no production role. A tiny C shim
target owns the symbol and Runtime calls its imported declaration, preventing
Swift optimization from bypassing the address LLDB observes. The Release
aggregate does not link
`HelixDevRuntime`. The generated `live-stop.sh` remains the eager cleanup path,
but Xcode may skip a Launch post-action after an explicit Stop. A supervised
daemon therefore waits five seconds for a genuine reconnect after its
authenticated App disconnects, then stops itself and removes `Session.json`,
`Helix.lldbinit`, and the private bootstrap. Keep the `ApplicationSession`
strongly owned for the App lifetime and do not disable
`debuggerHandoffEnabled` for the generated Xcode workflow.

## Save-to-screen sequence

```mermaid
sequenceDiagram
    participant E as "Editor"
    participant M as "Source monitor"
    participant C as "Dev compiler"
    participant D as "Authenticated daemon"
    participant A as "Debug App"
    participant U as "UI reload coordinator"

    E->>M: "Save an existing Swift file"
    M->>M: "Debounce and capture a stable snapshot"
    M->>C: "Monotonic sourceRevision"
    C->>C: "Exact module type-check and body-only diff"
    C->>C: "Build one Native or HLBC generation"
    C->>D: "Offer, hash, metadata, payload"
    D->>A: "Authenticated chunked transfer"
    A->>A: "Verify and activate code"
    A->>U: "Changed roots and reload hints"
    U-->>E: "Refreshed or manual-refresh-required status"
```

The monitor watches only source files frozen into the Dev Build Manifest.
Editor safe-save renames and in-place writes are debounced, and the snapshotter
requires two matching inode, size, modification-time, and content-hash reads.
Every transaction has a monotonically increasing `sourceRevision`; a slower old
compile or transfer cannot overwrite a newer accepted save.

Compilation failure, signature failure, load failure, or UI refresh failure
does not discard the last successful code generation. Code activation and UI
refresh are reported separately.

## How the native replacement is compiled

The first Debug build captures the real Swift frontend job, SDK, target,
module/source set, link inputs, and signing identity. `helix dev prepare`
replays that job in isolated outputs and compiles fresh capability probes for
implicit dynamic declarations, private source-file import, canonical SIL, and
replacement chaining. It does not merely recognize flag names, and it does not
run a two-generation dylib experiment on every App launch.

For an accepted body-only change, Helix:

1. Re-type-checks the complete module context and compares interface and
   transitive implementation fingerprints.
2. Uses the Reload Index to locate existing replacement roots.
3. Extracts only those function bodies.
4. Asks the exact compiler for a typed AST, identifies the declaration and its
   self references by USR, and edits only the compiler-reported UTF-8 identifier
   ranges.
5. Generates `@_dynamicReplacement` declarations, compiles them through normal
   SILGen, IRGen, and LLVM, then links and signs a uniquely named dylib.
6. Generates a matching dSYM and Swift module and validates the DWARF UUID.

This is controlled source reconstruction backed by typed-AST identity and SIL
checks; it is not LLVM instrumentation, raw symbol rebinding, or implemented
SIL function cloning.

The private source-file import lets a replacement body resolve private,
internal, and public declarations that were already available in the original
module. It does not grant access to a framework the App never linked.

## Recursion and previous generations

Swift gives a call to the replaced declaration inside a dynamic replacement a
special “previous implementation” meaning. Copying an ordinary recursive body
unchanged would therefore recurse into the old generation. Helix corrects this
by rebinding exact self references to the current replacement identity.

Normal Swift remains normal recursion:

```swift
func factorial(_ value: Int) -> Int {
    value < 2 ? 1 : value * factorial(value - 1)
}
```

The recursive edge above stays in the current generation. A deliberate call to
the previous generation must be explicit:

```swift
func adjustedPrice(_ input: Int) -> Int {
    LiveReload.previous {
        adjustedPrice(input)
    } + 1
}
```

`LiveReload.previous` is a compiler marker, not a general runtime dispatcher.
The current marker accepts one expression, may be `async throws`, and cannot be
nested inside another user closure. Untransformed execution traps rather than
silently calling the wrong implementation.

Static SIL tests distinguish current-generation `function_ref` edges from
explicit `prev_dynamic_function_ref` edges. A macOS runtime E2E has loaded two
generations for global, instance, static, class, and concrete-generic recursion
and verified that explicit previous from generation two reaches generation one.

## Generations, transfer, and image lifetime

Helix builds a separate immutable image for each successful native transaction.
It does not maintain one dylib and append saved Swift files to it. A native live
artifact consists of an offer manifest plus the dylib bytes; it is transferred
over the authenticated Dev Session and written to a bounded temporary file in
the App before hash, Mach-O, architecture, dependency, session, and generation
checks.

The App calls `dlopen` with local, immediate binding. Successfully loaded images
remain mapped until process exit because active frames, closures, metadata, or
replacement descriptors may still refer to them. Helix does not call `dlclose`.
Default runtime limits are:

- 64 MiB for one native payload and 16 MiB for one HLBC live payload;
- a warning after 50 native images;
- a hard stop at 80 native images or 256 MiB of accumulated native image bytes.

Reaching a hard limit requests an App restart. Restarting returns to the Dev
Shell baseline because live generations are not production-persisted.

## Backend selection

Simulator Native Dynamic Replacement is the validated primary route. The
development router may choose HLBC when Native is unavailable, but only if one
HLBC transaction can cover every changed root. A function with an active
generation keeps its backend affinity until restart, so one atomic transaction
cannot mix Native and HLBC implementations.

There is no implemented `-interposable` fallback. If neither backend can safely
compile the transaction, Helix reports that a full build is required.

Native loading on a physical development iPhone is present as an experimental
path: it uses the captured device target and expanded signing identity, but it
must remain disabled until the exact Xcode, iOS, architecture, Team ID, signing,
and library-validation matrix is qualified. Simulator success is not device
qualification.

## Why code activation does not automatically redraw a page

Replacing a function changes future calls. It does not make UIKit call
`viewDidLoad`, `loadView`, or a previously completed initializer again. Helix
therefore treats UI update as a second, explicit phase.

`ReloadIndex` records changed source/type identities and hints. UIKit target
discovery is automatic; application code does not maintain a `typeRegistry`.
For each action, the coordinator reconstructs the compiler's stable nominal ID
from `String(reflecting:)`/Objective-C runtime class names, walks the concrete
class's superclass chain, and compares those IDs with the changed type IDs.

The instance search starts from foreground-active or foreground-inactive
`UIWindowScene` windows. It traverses root, presented, navigation, tab, split,
and child controller graphs, filters to visible loaded controllers by default,
and de-duplicates object identities. It matches controllers first. Only types
still unmatched cause a scan of the loaded UIView trees, which avoids paying a
full view-walk cost for the common controller case. A base-class edit therefore
refreshes a displayed subclass instance without registration.

Actions for all matching levels of one inheritance chain are merged once per
instance. Conflicting recreation factories fail explicitly instead of applying
an arbitrary rule. The unified coordinator also distinguishes “no displayed
UIKit instance” from an active matching SwiftUI boundary and emits one useful
warning rather than duplicate UIKit/SwiftUI warnings.

The four policies are:

- `observeOnly`: activate code without forcing UI work;
- `invalidate`: request constraints, layout, display, or explicitly permitted
  data-source invalidation;
- `invokeHook`: call an idempotent `LiveReload.Reloadable` hook implemented by
  the page or view;
- `recreate`: build a replacement controller through a registered factory and
  restore explicitly captured route and UI state.

Layout and drawing callbacks normally infer `invalidate`, so changing a
displayed UIViewController or UIView requires neither registration nor an App
hook. Constraint, layout, and display invalidation operate on the same object,
preserving navigation position and in-memory state. Immediate layout is skipped
while a controller transition is active. Broad `UITableView`/
`UICollectionView.reloadData()` remains disabled by default; a page should use
an explicit hook when data ownership or side effects require application logic.
Initialization callbacks may infer `invokeHook` or `recreate` because Helix
never directly replays arbitrary lifecycle methods. Factory registration is
therefore an advanced reconstruction mechanism, not normal setup.

For SwiftUI, wrap an injection boundary:

```swift
struct ProfileScreen: View {
    var body: some View {
        content
            .liveReloadBoundary(mode: .invalidateBody)
    }
}
```

`LiveReload.Pulse.shared` advances after activation. `invalidateBody` preserves
the existing identity tree where possible; `recreateSubtree` changes the
boundary identity and intentionally resets local `@State`. Boundaries can be
filtered by `NominalTypeID` so an unrelated edit does not refresh every SwiftUI
screen.

## Supported edits

The current native workflow is designed for bodies of declarations already in
the Dev Shell. Calls to existing private members work because the patch is
compiled in the original source-file/module context. Local helpers, closures,
and local types written inside the changed body can be compiled by Swift.

The current generator does not automatically collect arbitrary new file-level
functions, types, extensions, or Swift files. It also rejects changes to stored
layout, signatures, generic constraints, isolation, superclass, conformance,
enum cases, source membership, build settings, macro/plugin inputs, linked
dependencies, assets, storyboards, and generated resources. Those changes need
a normal build and, where applicable, reinstall.

See [Capabilities and Limits](Capabilities-and-Limits.md) for the comparison
with production HLBC.

## Debug symbols and diagnostics

Each native generation has a UUID-matched dSYM, Swift module, and source map.
After the App confirms activation, the CLI prints `target symbols add`, Swift
module search-path, and source-map commands that can be pasted into the Xcode
LLDB console. Automatic LLDB attachment and symbol registration are not yet
implemented.

Compiler diagnostics retain logical source locations. The terminal and Debug
overlay report source revision, generation, backend, activation result, UI
refresh result, whether old code remains active, and the next action. A failed
save is not presented as a successful reload.
