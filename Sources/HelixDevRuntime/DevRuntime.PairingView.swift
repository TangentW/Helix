#if canImport(Network) && canImport(Security) && canImport(UIKit) && canImport(SwiftUI)
import HelixDevProtocol
import SwiftUI

extension DevRuntime {
/// Drop-in debug page for observing and manually activating a development session.
///
/// Present this view from an App's existing debug menu. An Xcode-launched App
/// only displays its automatic connection state. A test App opened directly
/// displays code entry while keeping Bonjour discovery and all network traffic
/// disabled until the developer taps Connect.
///
/// ```swift
/// NavigationLink("Helix") {
///     DevRuntime.PairingView(session: developmentSession)
/// }
/// ```
@MainActor
public struct PairingView: View {
    private let session: DevRuntime.ApplicationSession
    @ObservedObject private var status: DevStatus.Store
    @State private var code = ""
    @State private var submissionError: String?
    @State private var isSubmitting = false

    /// Creates a status and pairing page for a process-lifetime session.
    public init(session: DevRuntime.ApplicationSession) {
        self.session = session
        _status = ObservedObject(wrappedValue: session.environment.status)
    }

    public var body: some View {
        Form {
            Section("Session") {
                Label(status.snapshot.headline, systemImage: statusSymbol)
                    .foregroundColor(statusColor)
                if let detail = status.snapshot.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section("Activation") {
                switch session.launchMode {
                case .automaticXcode:
                    Text("Xcode launched this process. Helix uses the build-scoped invitation automatically.")
                case .manual where status.connectionState == .authenticated:
                    Text("This test App is paired for the current process. No code is stored for a later launch.")
                case .manual where isConnectionInProgress:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Discovering and authenticating Helix on the local network…")
                    }
                case .manual:
                    pairingForm
                }
            }
        }
        .navigationTitle("Helix")
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the four-character code shown by Helix on your Mac.")
                .font(.subheadline)
            TextField("AB2C", text: pairingCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .keyboardType(.asciiCapable)
                .submitLabel(.join)
                .onSubmit(connect)
                .accessibilityIdentifier("helix.pairing.code")
            Text("Codes ignore letter case and omit ambiguous characters.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let submissionError {
                Text(submissionError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("helix.pairing.error")
            }
            Button(action: connect) {
                if isSubmitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
            .accessibilityIdentifier("helix.pairing.connect")
        }
    }

    private var pairingCode: Binding<String> {
        Binding(
            get: { code },
            set: { value in
                code = String(
                    value.uppercased().filter {
                        Pairing.Code.alphabet.contains($0)
                    }.prefix(Pairing.Code.characterCount)
                )
                submissionError = nil
            }
        )
    }

    private var canSubmit: Bool {
        code.count == Pairing.Code.characterCount && !isSubmitting
    }

    private var isConnectionInProgress: Bool {
        status.connectionState == .connecting || status.connectionState == .retrying
    }

    private var statusSymbol: String {
        switch status.snapshot.tone {
        case .neutral: "circle"
        case .progress: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch status.snapshot.tone {
        case .neutral: .secondary
        case .progress: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private func connect() {
        guard canSubmit else { return }
        isSubmitting = true
        submissionError = nil
        let submittedCode = code
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await session.connect(pairingCode: submittedCode)
            } catch {
                submissionError = String(describing: error)
            }
        }
    }
}
}
#endif
