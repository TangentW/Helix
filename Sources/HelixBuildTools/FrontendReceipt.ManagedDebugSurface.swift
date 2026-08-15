import Foundation
import HelixCompiler
import HelixInterface

extension FrontendReceipt {
enum ManagedDebugSurface {}
}

extension FrontendReceipt.ManagedDebugSurface {
    private struct StaticGetterFamily {
        var ownerType: String
        var importedModule: String
        var members: [String]
    }

    /// Measures convenience APIs with the exact captured frontend instead of
    /// assuming a Swift or Objective-C ABI. The resulting operations still
    /// become individual, immutable NativeImports in the Debug Shell.
    static func importedOperations(
        for importedTypes: [FrontendReceipt.Adapter.ImportedNativeType],
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [FrontendReceipt.Adapter.ImportedOperation] {
        var operations: [FrontendReceipt.Adapter.ImportedOperation] = []
        for family in staticGetterFamilies {
            guard let nativeType = importedTypes.first(where: {
                nominalBaseName($0.canonicalName) == family.ownerType
                    && $0.importedModules.contains(family.importedModule)
            }) else { continue }
            operations += try probe(
                family,
                nativeType: nativeType,
                frontend: frontend,
                invocation: invocation
            )
        }
        return operations.sorted {
            ($0.ownerType, $0.baseName, $0.sourceFileLogicalID)
                < ($1.ownerType, $1.baseName, $1.sourceFileLogicalID)
        }
    }

    private static func probe(
        _ family: StaticGetterFamily,
        nativeType: FrontendReceipt.Adapter.ImportedNativeType,
        frontend: SwiftFrontend.Driver,
        invocation: InterfaceArchive.FrontendInvocation
    ) throws -> [FrontendReceipt.Adapter.ImportedOperation] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "helix-managed-debug-surface-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("ManagedDebugSurface.swift")
        let declarations = family.members.map { member in
            "@MainActor public func helixManagedDebug_\(family.ownerType)_\(member)() "
                + "-> \(family.ownerType) { \(family.ownerType).\(member) }"
        }
        let source = (["import \(family.importedModule)", ""] + declarations + [""])
            .joined(separator: "\n")
        try Data(source.utf8).write(to: sourceURL, options: .atomic)

        let canonicalSIL = try frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let file = try CanonicalSIL.File(text: canonicalSIL)
        let symbols = try measuredSymbols(
            in: file,
            ownerType: family.ownerType,
            members: family.members
        )
        return try family.members.map { member in
            guard let symbol = symbols[member] else {
                throw FrontendReceipt.Error.frontendFailed(
                    "managed Debug surface lost the measured "
                        + "\(family.ownerType).\(member) getter"
                )
            }
            return FrontendReceipt.Adapter.ImportedOperation(
                silReferences: [symbol],
                sourceFileLogicalID: nativeType.sourceFileLogicalID,
                importedModules: nativeType.importedModules,
                dispatch: .staticGetter,
                ownerType: nativeType.swiftType,
                baseName: member,
                argumentLabels: [],
                parameterSwiftTypes: [],
                resultSwiftType: nativeType.swiftType,
                requiresMainActor: true
            )
        }
    }

    private static func measuredSymbols(
        in file: CanonicalSIL.File,
        ownerType: String,
        members: [String]
    ) throws -> [String: String] {
        var measured: [String: String] = [:]
        for member in members {
            let references = Array(Set(file.functions.flatMap { function in
                FrontendReceipt.Adapter.foreignMemberReferences(
                    in: function.body,
                    ownerType: ownerType,
                    baseName: member,
                    marker: "getter"
                )
            })).sorted()
            guard references.count == 1, let symbol = references.first else {
                throw FrontendReceipt.Error.frontendFailed(
                    "managed Debug surface did not resolve one exact "
                        + "\(ownerType).\(member) getter ABI"
                )
            }
            measured[member] = symbol
        }
        return measured
    }

    private static func nominalBaseName(_ value: String) -> String {
        value.split(separator: ".").last.map(String.init) ?? value
    }

    private static let staticGetterFamilies = [
        StaticGetterFamily(
            ownerType: "UIColor",
            importedModule: "UIKit",
            members: [
                "black", "blue", "brown", "clear", "cyan", "darkGray", "darkText",
                "gray", "green", "label", "lightGray", "lightText", "link", "magenta",
                "opaqueSeparator", "orange", "placeholderText", "purple", "quaternaryLabel",
                "quaternarySystemFill", "red", "secondaryLabel", "secondarySystemBackground",
                "secondarySystemFill", "secondarySystemGroupedBackground", "separator",
                "systemBackground", "systemBlue", "systemBrown", "systemCyan", "systemFill",
                "systemGray", "systemGray2", "systemGray3", "systemGray4", "systemGray5",
                "systemGray6", "systemGreen", "systemGroupedBackground", "systemIndigo",
                "systemMint", "systemOrange", "systemPink", "systemPurple", "systemRed",
                "systemTeal", "systemYellow", "tertiaryLabel", "tertiarySystemBackground",
                "tertiarySystemFill", "tertiarySystemGroupedBackground", "tintColor", "white",
                "yellow",
            ]
        ),
    ]
}
