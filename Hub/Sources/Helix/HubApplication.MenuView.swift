#if os(macOS)
import AppKit
import SwiftUI

extension HubApplication {
struct MenuView: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Brand.Mark()
                    .frame(width: 40, height: 25)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helix").font(.headline)
                    Text("Hub service and project setup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            PairingCard(model: model, compact: true)
            if !model.projects.isEmpty {
                Picker("Pair for project", selection: Binding(
                    get: { model.selectedProjectID },
                    set: { model.selectProject(id: $0) }
                )) {
                    Text("Any registered build").tag(String?.none)
                    ForEach(model.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.menu)
            }
            Divider()
            HStack {
                Button("Open Helix", systemImage: "macwindow") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o")
                Button("Choose Project…", systemImage: "folder.badge.plus") {
                    model.chooseProject()
                }
            }
            .buttonStyle(.borderless)
            if let label = model.operationLabel {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Divider()
            HStack {
                Text(model.serviceState?.mode.rawValue.capitalized ?? "Starting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Helix") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
        .task { await model.run() }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
}
#endif
