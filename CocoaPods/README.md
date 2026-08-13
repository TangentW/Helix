# CocoaPods integration

Helix exposes only the two aggregate runtimes that an iOS App needs. Compiler,
Hub, CLI, release tooling, and other macOS-only modules are intentionally not
packaged as Pods.

| App target | Pod | Swift module |
| --- | --- | --- |
| Release / Hot Patch | `HelixAppRuntime` | `HelixAppRuntime` |
| Debug / Live Reload | `HelixDevAppRuntime` | `HelixDevAppRuntime` |

Never install both Pods into one App target. A project supporting both
workflows uses separate App targets, matching the SwiftPM product boundary.

## Direct Git installation

The repository URL is already declared by both podspecs. Once the repository
exists remotely, a Podfile can consume either runtime directly:

```ruby
target 'HotPatchApp' do
  pod 'HelixAppRuntime',
      :git => 'https://github.com/TangentW/Helix.git',
      :branch => 'main'
end

target 'LiveReloadApp' do
  pod 'HelixDevAppRuntime',
      :git => 'https://github.com/TangentW/Helix.git',
      :branch => 'main'
end
```

Pin a release tag or commit instead of a moving branch in a production project.
No public CocoaPods trunk publication is required. A private Specs repository
may host the same podspecs later without changing their runtime source graph.

Application code imports the aggregate Pod module:

```swift
import HelixAppRuntime       // Hot Patch App target
// or
import HelixDevAppRuntime    // Live Reload App target
```

The Hub-generated hidden Bridge detects this module shape automatically. It
continues to import leaf modules when the App uses SwiftPM, so handwritten App
and Feature code never references generated Bridge source.

## Direct source compilation

CocoaPods subspecs share one Swift module and therefore cannot reproduce
Helix's SwiftPM leaf-module graph. Each App-facing podspec instead names the
exact Runtime directories that belong to its aggregate and compiles those
files directly from `Sources/`, the same source of truth used by SwiftPM.

Imports between SwiftPM leaf modules are guarded by a compiler module-
availability check:

```swift
#if canImport(HelixCore)
import HelixCore
#endif
```

SwiftPM therefore keeps its explicit module graph. CocoaPods omits only those
same-module imports while compiling the unmodified declarations into the
aggregate module. There is no prepare command, copied source tree, generated
manifest, or special handling for a local `:path` dependency.

## Local validation

```bash
pod lib lint HelixAppRuntime.podspec --platforms=ios
pod lib lint HelixDevAppRuntime.podspec --platforms=ios
```

Each lint builds the full iOS runtime plus an external consumer test target.
The tests also prove that CocoaPods exposes only the aggregate module rather
than accidentally leaking SwiftPM leaf modules.
