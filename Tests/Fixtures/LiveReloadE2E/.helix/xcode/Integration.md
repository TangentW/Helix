# Helix Xcode integration

This directory is owned by Helix Hub and generated automatically. It is
an implementation record, not a setup checklist. Reapply integration
from Helix instead of editing these files.

## `live` (`liveReload`)

- App target: `LiveReloadE2EHost`
- Source target: `LiveReloadE2EHost`
- Scheme and configuration: `LiveReloadE2EHost` / `Debug`
- App product: `HelixAppIntegration` (linked automatically)

Hub owns the target wrapper, compiler capture, generated trigger, runtime
bootstrap, and Scheme action. Swift source membership is read from the successful
Xcode compile, so adding, moving, deleting, or generating a source needs no Helix
file list or policy update. Generated Bridge code remains in DerivedData.
Keep Helix open and use Xcode Run. The installed Scheme action registers the
finished App, while the automatic runtime discovers and authenticates the local
Hub. No LLDB file, launch variable, host address, pairing secret, runtime import,
or initialization call is required.

Project: `LiveReloadE2EHost.xcodeproj`
