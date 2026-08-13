#if os(macOS)
import SwiftUI
import HelixHubCore

extension HubApplication {
struct PairingCard: View {
    @ObservedObject var model: Model
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack {
                StatusDot(active: model.serviceIsRunning)
                Text(model.serviceIsRunning ? "Helix is ready" : "Helix is offline")
                    .font(.headline)
                Spacer()
                Text("\(model.connectedAppCount) connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let code = model.pairingCode {
                HStack(alignment: .firstTextBaseline) {
                    Text(code)
                        .font(.system(size: compact ? 28 : 38, weight: .semibold, design: .monospaced))
                        .tracking(compact ? 4 : 7)
                        .accessibilityLabel("Pairing code \(code)")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Manual pairing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let expiry = model.pairingExpiresAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Self.remaining(expiry, at: context.date))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") {
                        model.copyPairingCode()
                    }
                    Button("New Code", systemImage: "arrow.clockwise") {
                        model.rotatePairingCode()
                    }
                    .disabled(model.isRotatingPairingCode)
                    Spacer()
                    if let scope = model.pairingScopeName {
                        Text(scope)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.borderless)
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Creating a secure four-character code…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(compact ? 12 : 16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private static func remaining(_ expiry: Date, at date: Date) -> String {
        let seconds = max(0, Int(ceil(expiry.timeIntervalSince(date))))
        return seconds == 0 ? "Refreshing…" : "Expires in \(seconds)s"
    }
}

struct StatusDot: View {
    var active: Bool

    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
            .shadow(color: (active ? Color.green : Color.orange).opacity(0.5), radius: 3)
            .accessibilityLabel(active ? "Running" : "Offline")
    }
}

struct CapabilityBadge: View {
    var capability: Hub.Capability

    var body: some View {
        Label(
            capability.displayName,
            systemImage: capability == .hotPatch ? "bandage.fill" : "bolt.fill"
        )
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.12), in: Capsule())
    }
}

struct RequirementCard: View {
    var requirement: Hub.Requirement

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(requirement.summary)
                    .font(.subheadline.weight(.semibold))
                Text(requirement.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        switch requirement.severity {
        case .information: "info.circle.fill"
        case .actionRequired: "exclamationmark.triangle.fill"
        case .blocking: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch requirement.severity {
        case .information: .blue
        case .actionRequired: .orange
        case .blocking: .red
        }
    }
}

struct ServiceLogRow: View {
    var entry: Hub.ServiceLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(entry.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(entry.date, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch entry.level {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .information: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
}
#endif
