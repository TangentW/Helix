#if os(macOS)
import SwiftUI

@main
struct HelixApplication: App {
    @StateObject private var model = HubApplication.Model()

    var body: some Scene {
        MenuBarExtra {
            HubApplication.MenuView(model: model)
        } label: {
            Image(
                nsImage: HubApplication.Brand.Mark.statusItemImage(
                    disconnected: !model.serviceIsRunning
                )
            )
            .renderingMode(.template)
            .accessibilityLabel(
                model.serviceIsRunning ? "Helix running" : "Helix offline"
            )
            // The label exists from process launch, even before either window
            // is opened, so the service cannot depend on lazy view creation.
            .task { await model.run() }
        }
        .menuBarExtraStyle(.window)

        Window("Helix", id: "main") {
            HubApplication.RootView(model: model)
        }
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)
    }
}
#else
@main
enum HelixApplication {
    static func main() {}
}
#endif
