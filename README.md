<p align="center">
  <img src="Assets/Brand/Helix.Header.svg" alt="HELIX" width="680"><br>
  <strong>Hot patching and live reload for Swift — that’s dark magic.</strong>
</p>

<p align="center"><strong>English</strong> | <a href="README.zh-CN.md">简体中文</a></p>

Helix brings hot patching and live reload to Swift. Edit the code and hit save —
the running App updates instantly. When an issue reaches production, build the
fix into a patch and deploy it directly to production.

HLBC and HLVM make the magic happen: Swift becomes verified bytecode and runs
inside the virtual machine. One powerful VM core drives both live reload and
production hot patching.

> **Status:** Helix is under active development and testing as we expand
> coverage across more projects and use cases.

![Helix system architecture](Assets/Helix.Architecture.svg)

## Start here

| Goal | Guide |
| --- | --- |
| Run the checked-in UIKit Demo and see production Hot Patch and development Live Reload work end to end | [UIKit Demo](Demo/README.md) |
| Add the correct App runtime, Xcode integration, and project configuration to an existing App | [Getting Started](Docs/Getting-Started.md) |
| See which Swift code changes Helix supports today and which changes still require a normal rebuild | [Capabilities and Limits](Docs/Capabilities-and-Limits.md) |
| Understand how Swift compilation, HLBC, HLVM, activation, and workflow isolation fit together | [Architecture](Docs/Architecture.md) |
| Prepare a Release Shell, build and sign a `.hlxp` patch, then install, activate, and roll it back | [Production Hot Patching](Docs/Production-Hot-Patching.md) |
| Trace a saved Swift change through compilation, authenticated delivery, runtime activation, and UIKit/SwiftUI refresh | [Development Live Reload](Docs/Development-Live-Reload.md) |
| Add the aggregate App runtime products to a project with CocoaPods | [CocoaPods integration](CocoaPods/README.md) |
| Use the Helix Mac assistant to discover a project, configure both workflows, and manage development sessions | [Helix Hub](Hub/README.md) |

## App modules

Helix provides a separate App-facing product for each workflow. Link only one
to each App target. To use both workflows in one project, configure separate
Release and Debug App targets.

| Use case | Module to import | What it provides |
| --- | --- | --- |
| Production Hot Patch (Release) | `HelixAppRuntime` | Verifies and runs HLBC patches; manages installation, activation, recovery, revocation, and rollback |
| Live Reload (Debug) | `HelixDevAppRuntime` | Receives and verifies development updates; reports diagnostics and refreshes UIKit or SwiftUI, with changes limited to the current Debug process |

The compiler, Helix Hub, and CLI run on the Mac. Do not link these build-side
tools into an iOS Release App.

## Requirements

- macOS 14 or newer for build-side tools and the Helix application.
- iOS 15 or newer for App runtime targets.
- Xcode with a Swift 6 toolchain for compiler-backed integration and fixtures.
- A normal signed Xcode build before Live Reload or Release Shell finalization.

The package manifest uses Swift tools 6.1. Patch and Live Reload artifacts remain
bound to the compiler, SDK, sources, settings, and binary identity captured for
their target Shell.

## License

Helix is licensed under the [Apache License 2.0](LICENSE).
