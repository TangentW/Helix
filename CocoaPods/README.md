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

## Source preparation

CocoaPods subspecs share one Swift module and therefore cannot model Helix's
SwiftPM leaf-module graph. Each App-facing podspec runs
`CocoaPods/Scripts/prepare_runtime_sources.rb` after a Git checkout and before
CocoaPods collects source paths. The script deterministically copies only the
selected runtime graph into `CocoaPods/Generated`, removes imports that became
same-module references, and emits a SHA-256 manifest. Generated files are
ignored by Git and are managed inside the dependency sandbox; they never gain
membership in the application's own Xcode project.

CocoaPods does not execute a podspec `prepare_command` for a local `:path`
dependency. Contributors using that mode must prepare the selected product
before `pod install`:

```bash
ruby CocoaPods/Scripts/prepare_runtime_sources.rb HelixAppRuntime
# or
ruby CocoaPods/Scripts/prepare_runtime_sources.rb HelixDevAppRuntime
```

Direct Git and private-spec installations execute the command normally.

## Local validation

```bash
ruby -c CocoaPods/Scripts/prepare_runtime_sources.rb
ruby CocoaPods/Scripts/prepare_runtime_sources.rb HelixAppRuntime
ruby CocoaPods/Scripts/prepare_runtime_sources.rb HelixDevAppRuntime
pod lib lint HelixAppRuntime.podspec --platforms=ios
pod lib lint HelixDevAppRuntime.podspec --platforms=ios
```

Each lint builds the full iOS runtime plus an external consumer test target.
The tests also prove that CocoaPods exposes only the aggregate module rather
than accidentally leaking SwiftPM leaf modules.
