# Getting Started

[简体中文](Getting-Started.zh-CN.md)

The default Helix integration is three steps: open Helix, select an Xcode
project, and click **Enable Helix**. An ordinary iOS App does not need a second
target, a pre-created shared scheme, a Helix import, startup code, a maintained
source list, an API allowlist, or a manual “freeze” operation.

During a normal Xcode build, Helix captures facts already proven by the Swift
compiler and generates its Bridge under DerivedData. Those exact facts prevent
an update from being applied to the wrong executable. They are an automatically
generated build identity, not project configuration the developer maintains.

## Requirements

- macOS 14 or newer;
- iOS 15 or newer;
- Xcode with a Swift 6 toolchain;
- an iOS App target that already builds and runs in Xcode.

A single-target App works directly. Existing framework targets may also be
selected, but extracting a Feature framework is not an integration prerequisite.

## Enable Helix

Build and open Helix from this repository:

```bash
Hub/Scripts/build-app.sh release
open Hub/.build/Helix.app
```

Then:

1. Select an `.xcodeproj`, `.xcworkspace`, or a directory containing one.
2. Keep the Hot Patch and Live Reload workflows the project needs.
3. Review the App target, source target, scheme, and configurations detected by
   Helix.
4. Click **Enable Helix**.

For an ordinary single-target App, the App is also the source module, Live
Reload selects Debug, and Hot Patch selects Release. If no shared scheme exists,
Helix creates a runnable and archivable one. The mapping controls are available
for unusual projects, not as mandatory setup.

## What Helix installs

All edits are committed as one recoverable transaction. A failure cannot leave
half an integration in the project.

| Area | Automatic behavior |
| --- | --- |
| Package | Reuse an existing Helix Swift package, or add the canonical package reference |
| App product | Link the unified `HelixAppIntegration` product to the App target |
| Debug support | Make dynamic `HelixDevSupport` available to the App target, then link and embed it only for the Live Reload configuration |
| Swift compile | Capture the real successful compile through a transparent compiler proxy; one empty Hub-owned trigger per same App/source target refreshes incremental Runs and is excluded from the application Shell source set |
| Bridge | Generate and compile `HelixBridge.o` plus the automatic bootstrap object under DerivedData; generated Bridge Swift never enters the project |
| Build settings | Preserve the original Base Configuration through a configuration-scoped wrapper, then append Helix settings |
| Scheme | Create or update Run registration and Release audit actions |
| Local network | After existing App embed/copy phases, idempotently augment the processed Live Reload plist before signing; keep the source plist, Xcode plist settings, and Release output unchanged |
| Hot Patch | Generate the Patch action, starter recipe, runtime resources, and optional local development signing material |

Helix does not edit business Swift files. Application code does not import or
initialize a Runtime, and developers do not maintain source membership,
Native API lists, hosts, ports, pairing secrets, LLDB scripts, or shell `PATH`
settings for Helix.

## Change or remove the integration

Nothing selected during onboarding is locked. Reopen the project in Helix at
any time, change its App target, source target, scheme, or configuration, and
click **Apply Changes**. Hub restores no-longer-used Base Configuration
references by their original PBX identity, removes old compiler triggers,
products, phases, Patch targets, and scheme actions, then applies the current
mapping idempotently. Existing scheme Run/Archive configurations and all
non-Helix actions remain untouched.

The generated Host Plan is the single source of truth for both target and
module identity. Hub does not keep a second editable target map in its project
registry, so reopening or reapplying a project cannot revive a stale mapping.
The owner-only registry retains the last applied plan only as an automatic
removal snapshot, so **Remove Helix** still works if generated files were
deleted; that snapshot is never used by builds or as reconfiguration input.

Turn off either workflow to remove only that workflow. Turn off both and click
**Remove Helix** to restore the project automatically. Application source,
business configuration, patch recipes, and signing material are preserved.
Hub deletes files recorded in its generated-file ownership manifest and leaves
unknown files untouched, including files someone placed in the integration
directory independently.
The same transactional rollback and symlink/path checks used during setup also
cover reconfiguration and removal.

## Automatic runtime startup

There is one long-lived production-facing product: `HelixAppIntegration`. The
hidden bootstrap object generated for a profile selects the runtime:

- a Live Reload configuration calls the development entry in
  `HelixDevSupport`;
- a Hot Patch configuration calls the production entry in
  `HelixAppIntegration`.

The decision comes from the concrete Helix profile, not from a configuration
being named `Debug`, a particular compilation define, or a branch in business
code. Development code lives in a separate dynamic framework and is explicitly
forbidden by the Release bundle audit. The production product does not depend
on development transport, dynamic loading, or debug UI.

Application code therefore needs none of the following:

```swift
// No Helix import.
// No ApplicationSession owner.
// No AppDelegate or SceneDelegate start call.
```

Public status APIs remain available to advanced diagnostics, but ordinary
integration does not depend on them.

## First Live Reload

1. Keep Helix running in the menu bar.
2. Select the configured scheme in Xcode and Run normally.
3. Open the screen to test.
4. Change an existing Swift implementation and save; do not Build again.
5. Inspect compile, transfer, activation, and UI-refresh status in Helix.

An App launched by Xcode discovers the single `_helix._tcp` service, verifies
the Host Identity pin compiled into its build, and redeems a one-time invitation.
There is no custom LLDB script, launch environment, host, or port. Opening the
same development build directly still asks for the four-character
user-presence code; pinned TLS and the exact registered App build identity are
required in addition to that code.

Common UIKit controller/view layout, drawing, and configuration callbacks find
live instances and apply safe invalidation automatically. Presentation,
dismissal, common Foundation/UIKit calls, synchronous closures, and native
callbacks use compiler-proven general Bridge generation rather than Demo/API
special cases. An explicit reload hook or factory is needed only when business
initialization must be replayed or a screen must be reconstructed.

## First Hot Patch

1. Build or Archive the configured Release configuration normally.
2. Helix automatically records that product’s compiler, SDK, source interface,
   Bridge, and executable identity, then audits the final App bundle.
3. Change a supported implementation.
4. Build the Patch scheme generated by Helix to produce a verified and signed
   `.hlxp`.
5. Deliver it through the product’s distribution channel. The App Runtime
   verifies, installs, activates, health-checks, and can roll it back.

The local development identity and starter recipe generated by Hub make the
complete flow quick to test. A production trust root, signing service,
approval, rollout, and compliance policy are real security decisions and
cannot be guessed by tooling. They are not ordinary Live Reload or initial
project configuration.

## A build identity is not a user-managed freeze

Each normal Xcode build automatically captures:

- the Swift compiler, SDK, target triple, and semantic compiler arguments;
- the source membership Xcode actually compiled;
- replaceable declarations, signatures, isolation, ownership, and body anchors;
- native types and API adapters proven from typed AST, canonical SIL, and the
  SDK symbol graph;
- the final executable UUID, bundle, and signing-related identity.

Developers do not edit these records or extend an allowlist when using another
common API. On save, Helix re-type-checks in the same compiler context and
generates the concrete NativeImport adapters it can prove. A function-signature,
stored-layout, inheritance, conformance, source-membership, dependency, or
build-setting change needs one ordinary Xcode Build so Helix can recapture the
new executable. That follows actual Swift binary/layout changes; it is not a
separate Helix configuration workflow.

HLBC is still not arbitrary Swift execution on a device. Unproven ABI,
runtime metadata, unrestricted pointers, uncontrolled concurrency, or attempts
to bypass package signing and sandboxing are rejected. These are iOS, Swift
ABI, and patch-security boundaries, not optional usability gates. See
[Capabilities and Limits](Capabilities-and-Limits.md) for current language and
API coverage.

## Optional diagnostics

Normal use requires no CLI command. For project diagnostics:

```bash
swift run helix xcode doctor \
  --plan .helix/xcode/HostPlan.json \
  --profile live \
  --static
```

| Symptom | Action |
| --- | --- |
| App settings or source structure just changed | Build/Run normally once; Helix recaptures automatically |
| A save fails to compile | Use the source location and concrete unsupported shape shown by Helix; the last successful generation remains active |
| Code activates but the screen does not change | The instance may not be visible, or that lifecycle needs an explicit idempotent hook/factory |
| Release audit finds development code | Check for manually linked or embedded `HelixDevSupport`; the generated path never includes it in Release |
| An external tool overwrote a scheme or generated file | Use **Apply Changes** in Helix; Hub owns the generated directory |

The local protocol, schema, ABI, and product versions remain unified at 1.
This is a pre-release project and does not retain compatibility layers for
obsolete integration designs.

Continue with [Architecture](Architecture.md),
[Development Live Reload](Development-Live-Reload.md), and
[Production Hot Patching](Production-Hot-Patching.md).
