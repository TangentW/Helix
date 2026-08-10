import HelixCore
import HelixDevProtocol
import HelixDevRuntime
import HelixLiveReloadAPI
import SwiftUI

enum LiveReloadHost {}

extension LiveReloadHost {
@MainActor
final class Model: ObservableObject {
    @Published private(set) var tapCount = 0

    let pulse = LiveReload.Pulse()
    let nominalTypeID = LiveReload.NominalTypeID.derive(
        module: "LiveReloadHost",
        canonicalName: "LiveReloadHost.Content"
    )
    let environment: DevRuntime.LiveReloadEnvironment

    private var nextGenerationID: UInt64 = 1

    init() {
        environment = .init(
            pulse: pulse,
            overlayConfiguration: .init(startsExpanded: false)
        )
    }

    func start() {
        environment.startOverlay()
    }

    func recordUnderlyingTap() {
        tapCount += 1
    }

    func activateNextGeneration() async {
        let generationID = nextGenerationID
        nextGenerationID += 1
        let sourceRevision = generationID
        let context = LiveReload.Context(
            generationID: generationID,
            sourceRevision: sourceRevision,
            changedFunctions: [
                Core.FunctionKey(
                    rawValue: .sha256("LiveReloadHost.Content.render.\(generationID)")
                ),
            ],
            backend: .hlbc,
            reason: .sourceSaved
        )
        let reloadStatus = await environment.activationReloadHandler()(
            context,
            [
                DevProtocol.ReloadHint(
                    nominalTypeID: nominalTypeID,
                    policy: .invalidate,
                    invalidationHints: .layout
                ),
            ]
        )
        environment.status.record(
            .init(
                sourceRevision: .init(rawValue: sourceRevision),
                generationID: .init(rawValue: generationID),
                codeStatus: .codeActive,
                reloadStatus: reloadStatus
            )
        )
    }
}

struct Content: View {
    @ObservedObject var model: LiveReloadHost.Model
    @ObservedObject var pulse: LiveReload.Pulse

    var body: some View {
        VStack(spacing: 20) {
            Text("Helix Live Reload Host")
                .font(.title2.bold())
            Text("Boundary sequence: \(pulse.refreshSequence(for: model.nominalTypeID))")
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("host.boundary-sequence")
            Text("Underlying taps: \(model.tapCount)")
                .accessibilityIdentifier("host.underlying-count")
            Button("Apply generation") {
                Task { await model.activateNextGeneration() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("host.apply-generation")
            Button("Tap underlying content") {
                model.recordUnderlyingTap()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("host.underlying-button")
        }
        .padding(24)
    }
}
}

@main
@MainActor
struct LiveReloadHostApplication: App {
    @StateObject private var model = LiveReloadHost.Model()

    var body: some Scene {
        WindowGroup {
            LiveReloadHost.Content(model: model, pulse: model.pulse)
                .liveReloadBoundary(
                    for: model.nominalTypeID,
                    mode: .invalidateBody,
                    pulse: model.pulse
                )
                .task { model.start() }
        }
    }
}
