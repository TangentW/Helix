# Helix Xcode integration

This directory is generated from `HostPlan.json`. Regenerate it with
`helix xcode generate`; do not edit individual files.

The following target and Scheme edits are one-time project setup. After
setup, developers use Xcode Run, Build, Archive, and the shared Patch
scheme; no Helix command needs to be typed during ordinary work.

## `hot` (`hotPatch`)

- Link `HelixAppRuntime` and the Feature framework into the App.
- Use `Profiles/hot/Feature.xcconfig` as the Feature target base configuration.
  Keep the Feature's ordinary Swift files in its Sources phase; never add Helix
  DerivedData output to the project.
- Use `Profiles/hot/Application.xcconfig` as the App target base configuration.
- Add one Run Script phase before the App's Sources phase:
  `/bin/sh "$(HELIX_INTEGRATION_ROOT)/Profiles/hot/bridge.sh"`.
  Declare `$(HELIX_BRIDGE_OBJECT)` as its output. The script compiles the generated
  Bridge privately in DerivedData before the App links.
- Run `Profiles/hot/prepare.sh` as the first Scheme Build
  pre-action, with build settings supplied by the Feature target.
- Run `Profiles/hot/audit.sh` as the last Scheme Build
  post-action, with build settings supplied by the App target. Audit performs
  finalization itself and writes the immutable Release baseline used by Patch.
- `finalize.sh` is available only for a deliberately separate finalization
  workflow; do not run it immediately before `audit.sh`.
- Create Aggregate Target `HelixPatchAction`, use
  `Profiles/hot/Profile.xcconfig` as its base configuration, and run
  `Profiles/hot/patch.sh` in its only Run Script phase.
  Set `SUPPORTED_PLATFORMS` to `iphoneos iphonesimulator`; the selected
  destination must match the SDK of the audited Release baseline.
- Share Scheme `Helix Build Patch` with only that Aggregate Target.
  Building this scheme compiles, signs, and optionally stages a patch; it
  does not rebuild or reinstall the App.

## `live` (`liveReload`)

- Link `HelixDevAppRuntime` and the Feature framework into the App.
- Use `Profiles/live/Feature.xcconfig` as the Feature target base configuration.
  Keep the Feature's ordinary Swift files in its Sources phase; never add Helix
  DerivedData output to the project.
- Use `Profiles/live/Application.xcconfig` as the App target base configuration.
- Add one Run Script phase before the App's Sources phase:
  `/bin/sh "$(HELIX_INTEGRATION_ROOT)/Profiles/live/bridge.sh"`.
  Declare `$(HELIX_BRIDGE_OBJECT)` as its output. The script compiles the generated
  Bridge privately in DerivedData before the App links.
- Run `Profiles/live/prepare.sh` as the first Scheme Build
  pre-action, with build settings supplied by the Feature target.
- Run `Profiles/live/live-start.sh` as a Scheme Run
  pre-action, with build settings supplied by the App target. At that point the
  Feature target's transparent compiler proxy has atomically captured the exact
  successful `swiftc` invocation and the debugger has not launched the App yet.
  The transparent external-driver proxy is scoped to the Feature target;
  the App, packages, and unrelated targets retain Xcode's default driver mode.
- Set the Run action's custom LLDB init file to
  `$(HELIX_LLDB_INIT_FILE)` so the authenticated one-run credential reaches the
  App process without entering the checked-in scheme. The generated init uses
  `target.env-vars` for LLDB-owned launches and a bounded installer that briefly
  stops the running real target, atomically injects the complete environment,
  then resumes it. Keep the App-owned `DevRuntime.ApplicationSession` alive so
  its exported C probe can complete a late handoff.
- Run `Profiles/live/live-stop.sh` as the matching Scheme Run
  post-action. This is the eager stop path; a supervised daemon also exits after
  the authenticated App remains disconnected for five seconds and removes its
  private handoff files, because Xcode may skip Launch post-actions after an
  explicit Stop. Do not start the session from a Build post-action.

The application target must link exactly the runtime product recorded
above. Release and Dev runtime products must never be linked together.

Project: `HelixDemo.xcodeproj`
