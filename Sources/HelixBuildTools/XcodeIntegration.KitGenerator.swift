import Foundation
import HelixCore

extension XcodeIntegration {
public struct ProfileContract: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 2

    public var schemaVersion: UInt16
    public var profileID: String
    public var workflow: XcodeIntegration.Workflow
    public var runtimePackageProduct: String
    public var featureModuleName: String
    public var commonConfiguration: String
    public var featureConfiguration: String
    public var applicationConfiguration: String
    public var bridgePhaseScript: String

    public init(
        profile: XcodeIntegration.Profile,
        feature: XcodeIntegration.Feature
    ) {
        schemaVersion = Self.currentSchemaVersion
        profileID = profile.id
        workflow = profile.workflow
        runtimePackageProduct = profile.runtimePackageProduct
        featureModuleName = feature.moduleName
        let root = "Profiles/\(profile.id)"
        commonConfiguration = "\(root)/Profile.xcconfig"
        featureConfiguration = "\(root)/Feature.xcconfig"
        applicationConfiguration = "\(root)/Application.xcconfig"
        bridgePhaseScript = "\(root)/bridge.sh"
    }
}

public struct KitArtifact: Codable, Hashable, Sendable {
    public var path: String
    public var byteCount: UInt64
    public var sha256: Core.Digest
    public var permissions: UInt16

    public init(path: String, data: Data, permissions: UInt16 = 0o644) {
        self.path = path
        byteCount = UInt64(data.count)
        sha256 = .sha256(data)
        self.permissions = permissions
    }
}

public struct KitManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 3

    public var schemaVersion: UInt16
    public var hostPlanSHA256: Core.Digest
    public var profiles: [XcodeIntegration.ProfileContract]
    public var artifacts: [XcodeIntegration.KitArtifact]
}

public struct KitOutput: Sendable {
    public var manifest: XcodeIntegration.KitManifest
    public var artifacts: [String: Data]
    public var executablePaths: Set<String>
}

/// Produces deterministic files that are checked by Xcode build phases. The
/// generated scripts contain no build logic; they dispatch to the versioned
/// `helix xcode phase` API so projects do not accumulate private shell code.
public struct KitGenerator: Sendable {
    public init() {}

    public func generate(
        plan: XcodeIntegration.HostPlan
    ) throws -> XcodeIntegration.KitOutput {
        try plan.validate()
        let planBytes = try XcodeIntegration.HostPlanCodec.encode(plan)
        var artifacts: [String: Data] = [:]
        try insert(planBytes, at: "HostPlan.json", into: &artifacts)
        try insert(
            Data(renderSharedConfiguration(plan: plan).utf8),
            at: "Shared/Helix.xcconfig",
            into: &artifacts
        )
        try insert(
            Data(renderPhaseDispatcher().utf8),
            at: "Scripts/helix-phase.sh",
            into: &artifacts
        )

        var contracts: [XcodeIntegration.ProfileContract] = []
        for profile in plan.profiles {
            let feature = try plan.feature(id: profile.featureID)
            let contract = XcodeIntegration.ProfileContract(
                profile: profile,
                feature: feature
            )
            contracts.append(contract)
            try generate(
                profile: profile,
                feature: feature,
                plan: plan,
                contract: contract,
                into: &artifacts
            )
        }
        let guide = renderGuide(plan: plan, contracts: contracts)
        try insert(Data(guide.utf8), at: "Integration.md", into: &artifacts)

        let executablePaths = Set(artifacts.keys.filter { $0.hasSuffix(".sh") })
        let records = artifacts.map {
            XcodeIntegration.KitArtifact(
                path: $0.key,
                data: $0.value,
                permissions: executablePaths.contains($0.key) ? 0o755 : 0o644
            )
        }.sorted { $0.path < $1.path }
        let manifest = XcodeIntegration.KitManifest(
            schemaVersion: XcodeIntegration.KitManifest.currentSchemaVersion,
            hostPlanSHA256: .sha256(planBytes),
            profiles: contracts.sorted { $0.profileID < $1.profileID },
            artifacts: records
        )
        try insert(
            try Core.CanonicalJSON.encode(manifest),
            at: "IntegrationManifest.json",
            into: &artifacts
        )
        return .init(
            manifest: manifest,
            artifacts: artifacts,
            executablePaths: executablePaths
        )
    }

    private func generate(
        profile: XcodeIntegration.Profile,
        feature: XcodeIntegration.Feature,
        plan: XcodeIntegration.HostPlan,
        contract: XcodeIntegration.ProfileContract,
        into artifacts: inout [String: Data]
    ) throws {
        let root = "Profiles/\(profile.id)"
        try insert(
            try Core.CanonicalJSON.encode(contract),
            at: "\(root)/ProfileContract.json",
            into: &artifacts
        )
        try insert(
            Data(renderProfileConfiguration(profile: profile, plan: plan).utf8),
            at: contract.commonConfiguration,
            into: &artifacts
        )
        try insert(
            Data(renderFeatureConfiguration(feature: feature).utf8),
            at: contract.featureConfiguration,
            into: &artifacts
        )
        try insert(
            Data(renderApplicationConfiguration().utf8),
            at: contract.applicationConfiguration,
            into: &artifacts
        )
        for phase in phaseNames(for: profile) {
            try insert(
                Data(renderPhaseWrapper(phase: phase).utf8),
                at: "\(root)/\(phase).sh",
                into: &artifacts
            )
        }
    }

    private func renderSharedConfiguration(plan: XcodeIntegration.HostPlan) -> String {
        """
        // Generated by Helix. Do not edit.
        HELIX_INTEGRATION_ROOT = $(SRCROOT)/\(plan.integrationRoot)
        HELIX_HOST_PLAN = $(HELIX_INTEGRATION_ROOT)/HostPlan.json
        HELIX_BUILD_ROOT = $(BUILD_DIR)/HelixGenerated

        """
    }

    private func renderProfileConfiguration(
        profile: XcodeIntegration.Profile,
        plan: XcodeIntegration.HostPlan
    ) -> String {
        let activitySetting = profile.workflow == .liveReload
            ? "EMIT_FRONTEND_COMMAND_LINES = YES\n"
            : ""
        let patchSettings: String
        if let patch = profile.patch {
            patchSettings = """
            HELIX_PATCH_RECIPE = $(SRCROOT)/\(patch.recipePath)
            HELIX_PATCH_CERTIFICATE = $(SRCROOT)/\(patch.signingCertificatePath)
            HELIX_PATCH_TRUSTED_ROOT = $(SRCROOT)/\(patch.trustedRootPath)
            HELIX_PATCH_PRIVATE_KEY = $(SRCROOT)/\(patch.privateKeyPath)
            HELIX_PATCH_OUTPUT_ROOT = $(SRCROOT)/\(patch.outputRoot)
            \(patch.simulatorInboxPath.map {
                "HELIX_PATCH_SIMULATOR_INBOX = \($0)"
            } ?? "")

            """
        } else {
            patchSettings = ""
        }
        return """
        // Generated by Helix. Do not edit.
        #include "../../Shared/Helix.xcconfig"
        HELIX_PROFILE_ID = \(profile.id)
        HELIX_WORKFLOW = \(profile.workflow.rawValue)
        HELIX_RUNTIME_PRODUCT = \(profile.runtimePackageProduct)
        HELIX_PROFILE_OUTPUT_DIR = $(HELIX_BUILD_ROOT)/\(profile.id)
        HELIX_SHELL_OUTPUT_DIR = $(HELIX_PROFILE_OUTPUT_DIR)/Shell
        HELIX_FINAL_ARCHIVE = $(HELIX_PROFILE_OUTPUT_DIR)/Shell.final.hlxi
        HELIX_BRIDGE_OBJECT = $(HELIX_PROFILE_OUTPUT_DIR)/Bridge/HelixBridge.o
        HELIX_DEV_CONFIGURATION = $(HELIX_PROFILE_OUTPUT_DIR)/HelixDev.json
        HELIX_DEV_SESSION_STATE = $(HELIX_PROFILE_OUTPUT_DIR)/Session.json
        HELIX_LLDB_INIT_FILE = $(HELIX_PROFILE_OUTPUT_DIR)/Helix.lldbinit
        HELIX_ACTIVITY_LOG_DIR = $(BUILD_DIR)/../../Logs/Build
        \(activitySetting)
        \(patchSettings)
        """.trimmingCharacters(in: .newlines) + "\n"
    }

    private func renderFeatureConfiguration(
        feature: XcodeIntegration.Feature
    ) -> String {
        return """
        // Generated by Helix. Do not edit.
        #include "Profile.xcconfig"
        PRODUCT_MODULE_NAME = \(feature.moduleName)
        LD_DYLIB_INSTALL_NAME = @rpath/$(EXECUTABLE_PATH)
        OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -enable-private-imports -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-dynamic-replacement-chaining
        HELIX_REAL_SWIFT_EXEC = $(TOOLCHAIN_DIR)/usr/bin/swiftc
        SWIFT_EXEC = $(HELIX_PROFILE_OUTPUT_DIR)/Compiler/Feature/\(XcodeIntegration.CompilerCapture.proxyFileName)
        SWIFT_USE_INTEGRATED_DRIVER = NO

        """.trimmingCharacters(in: .newlines) + "\n"
    }

    private func renderApplicationConfiguration() -> String {
        """
        // Generated by Helix. Do not edit.
        #include "Profile.xcconfig"
        OTHER_LDFLAGS = $(inherited) "$(HELIX_BRIDGE_OBJECT)" -Xlinker -u -Xlinker _hlx_bridge_provider_v1

        """
    }

    private func renderPhaseDispatcher() -> String {
        """
        #!/bin/sh
        set -eu

        phase="${1:?missing Helix Xcode phase}"
        : "${HELIX_HOST_PLAN:?HELIX_HOST_PLAN is not configured}"
        : "${HELIX_PROFILE_ID:?HELIX_PROFILE_ID is not configured}"

        # Scheme Build pre/post-actions are also invoked by `xcodebuild clean`
        # and some non-product actions. Those actions have no linked App to
        # finalize or audit and must not materialize a new Shell baseline.
        case "${ACTION:-}" in
            clean|analyze|installhdrs|installsrc)
                exit 0
                ;;
        esac

        if [ "${ENABLE_PREVIEWS:-NO}" = "YES" ]; then
            exit 0
        fi

        # Xcode exports these build-setting names, while Swift Driver reserves
        # the SWIFT_DEBUG_* environment namespace for its own diagnostics.
        unset SWIFT_DEBUG_INFORMATION_FORMAT SWIFT_DEBUG_INFORMATION_VERSION

        helix_executable="${HELIX_EXECUTABLE:-helix}"
        if ! command -v "$helix_executable" >/dev/null 2>&1; then
            echo "error: Helix executable not found: $helix_executable" >&2
            echo "error: configure HELIX_EXECUTABLE as a user-defined Xcode build setting" >&2
            exit 1
        fi

        exec "$helix_executable" xcode phase \
            --plan "$HELIX_HOST_PLAN" \
            --profile "$HELIX_PROFILE_ID" \
            --phase "$phase"

        """
    }

    private func renderPhaseWrapper(phase: String) -> String {
        """
        #!/bin/sh
        set -eu
        exec /bin/sh "${HELIX_INTEGRATION_ROOT:?}/Scripts/helix-phase.sh" \(phase)

        """
    }

    private func phaseNames(for profile: XcodeIntegration.Profile) -> [String] {
        switch profile.workflow {
        case .hotPatch:
            profile.patch == nil
                ? ["prepare", "bridge", "finalize", "audit"]
                : ["prepare", "bridge", "finalize", "audit", "patch"]
        case .liveReload:
            ["prepare", "bridge", "finalize", "live-start", "live-stop"]
        }
    }

    private func renderGuide(
        plan: XcodeIntegration.HostPlan,
        contracts: [XcodeIntegration.ProfileContract]
    ) -> String {
        let orderedContracts = contracts.sorted { $0.profileID < $1.profileID }
        let profiles = zip(orderedContracts, plan.profiles).map { contract, profile in
            let common = """
            ## `\(contract.profileID)` (`\(profile.workflow.rawValue)`)

            - Link `\(contract.runtimePackageProduct)` and the Feature framework into the App.
            - Use `\(contract.featureConfiguration)` as the Feature target base configuration.
              Keep the Feature's ordinary Swift files in its Sources phase; never add Helix
              DerivedData output to the project.
            - Use `\(contract.applicationConfiguration)` as the App target base configuration.
            - Add one Run Script phase before the App's Sources phase:
              `/bin/sh "$(HELIX_INTEGRATION_ROOT)/Profiles/\(contract.profileID)/bridge.sh"`.
              Declare `$(HELIX_BRIDGE_OBJECT)` as its output. The script compiles the generated
              Bridge privately in DerivedData before the App links.
            - Run `Profiles/\(contract.profileID)/prepare.sh` as the first Scheme Build
              pre-action, with build settings supplied by the Feature target.
            """
            switch profile.workflow {
            case .hotPatch:
                let patchAction = profile.patch.map {
                    """
                    - Create Aggregate Target `\($0.actionTargetName)`, use
                      `\(contract.commonConfiguration)` as its base configuration, and run
                      `Profiles/\(contract.profileID)/patch.sh` in its only Run Script phase.
                      Set `SUPPORTED_PLATFORMS` to `iphoneos iphonesimulator`; the selected
                      destination must match the SDK of the audited Release baseline.
                    - Share Scheme `\($0.actionSchemeName)` with only that Aggregate Target.
                      Building this scheme compiles, signs, and optionally stages a patch; it
                      does not rebuild or reinstall the App.
                    """
                } ?? ""
                return common + """

                - Run `Profiles/\(contract.profileID)/audit.sh` as the last Scheme Build
                  post-action, with build settings supplied by the App target. Audit performs
                  finalization itself and writes the immutable Release baseline used by Patch.
                - `finalize.sh` is available only for a deliberately separate finalization
                  workflow; do not run it immediately before `audit.sh`.
                \(patchAction)
                """
            case .liveReload:
                return common + """

                - Run `Profiles/\(contract.profileID)/live-start.sh` as a Scheme Run
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
                - Run `Profiles/\(contract.profileID)/live-stop.sh` as the matching Scheme Run
                  post-action. This is the eager stop path; a supervised daemon also exits after
                  the authenticated App remains disconnected for five seconds and removes its
                  private handoff files, because Xcode may skip Launch post-actions after an
                  explicit Stop. Do not start the session from a Build post-action.
                """
            }
        }.joined(separator: "\n\n")
        return """
        # Helix Xcode integration

        This directory is generated from `HostPlan.json`. Regenerate it with
        `helix xcode generate`; do not edit individual files.

        The following target and Scheme edits are one-time project setup. After
        setup, developers use Xcode Run, Build, Archive, and the shared Patch
        scheme; no Helix command needs to be typed during ordinary work.

        \(profiles)

        The application target must link exactly the runtime product recorded
        above. Release and Dev runtime products must never be linked together.

        Project: `\(plan.projectPath)`
        """ + "\n"
    }

    private func insert(
        _ data: Data,
        at path: String,
        into artifacts: inout [String: Data]
    ) throws {
        guard artifacts.updateValue(data, forKey: path) == nil else {
            throw XcodeIntegration.Error.outputCollision(path)
        }
    }
}
}
