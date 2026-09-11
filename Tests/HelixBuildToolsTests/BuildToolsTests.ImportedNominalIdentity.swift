import Foundation
import HelixCore
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Imported nominal identity normalization")
struct ImportedNominalIdentityTests {
    @Test("Probe placeholder aliases remain ambiguous across distinct canonical authorities")
    func preservesAmbiguousProbeAliases() {
        let first = type("FirstRuntime", swift: "First.Nested", source: "First.swift")
        var second = type("SecondRuntime", swift: "Second.Nested", source: "Second.swift")
        var sharedFirst = first
        sharedFirst.aliases = ["Nested"]
        second.aliases = ["Nested"]
        let lookup = FrontendReceipt.ManagedNativeSurface.placeholderNativeTypes([sharedFirst, second])
        #expect(lookup["Nested"] == nil)
        #expect(lookup["FirstRuntime"] != lookup["SecondRuntime"])
        #expect(lookup == FrontendReceipt.ManagedNativeSurface.placeholderNativeTypes([second, sharedFirst]))
    }
    @Test("NS-prefixed Swift modules and unproven flat names remain independent identities")
    func preservesNSPrefixedModuleAuthority() throws {
        for names in [["NSWidgets.Item", "Widgets.Item"], ["NSUnproven", "Unproven"],
                      ["NSUnproven", "Unproven.Nested"]] {
            let uses = names.map { name -> FrontendReceipt.Adapter.ImportedNativeType in
                var value = FrontendReceipt.Adapter.ImportedNativeType(canonicalName: name,
                    swiftType: name, kind: .value, aliases: [], representation: .opaqueValue,
                    sourceFileLogicalID: "\(name).swift", importedModules: ["NSWidgets", "Widgets"], requiresMainActor: false)
                value.nativeModuleName = name.hasPrefix("NS") ? "NSWidgets" : "Widgets"
                return value
            }
            let merged = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
            #expect(merged.map(\.canonicalName) == names.sorted())
            #expect(merged.allSatisfy { $0.aliases.isEmpty })
            let references = uses.map { value in
                var reference = value
                reference.kind = .reference
                reference.representation = .reference
                return reference
            }
            let mergedReferences = try FrontendReceipt.Adapter().mergeImportedNativeTypes(
                discoveredTypes: references, operationTypes: [])
            #expect(mergedReferences.map(\.canonicalName) == names.sorted())
            #expect(mergedReferences.allSatisfy { $0.aliases.isEmpty })
        }
    }

    @Test("A flat NS alias requires the same exact Objective-C runtime on both sides")
    func mergesRuntimeProvenNSAlias() throws {
        let runtime = type("NSProgress", swift: "NSProgress", source: "Runtime.swift")
        var overlay = type("NSProgress", swift: "Progress", source: "Overlay.swift")
        overlay.canonicalName = "Progress"
        let adapter = FrontendReceipt.Adapter()
        let merged = try adapter.mergeImportedNativeTypes(discoveredTypes: [runtime, overlay], operationTypes: [])
        #expect(merged.count == 1)
        #expect(merged.first?.objectiveCRuntimeName == "NSProgress")
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: [overlay, runtime], operationTypes: []) == merged)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: merged, operationTypes: [runtime, overlay]) == merged)
        overlay.objectiveCRuntimeName = "DifferentProgress"
        let distinct = try adapter.mergeImportedNativeTypes(discoveredTypes: [runtime, overlay], operationTypes: [])
        #expect(distinct.count == 2)
        #expect(Set(distinct.compactMap(\.objectiveCRuntimeName)) == ["NSProgress", "DifferentProgress"])
    }

    @Test("Unbound archetypes cannot compete with nested Swift overlays or become aliases")
    func excludesArchetypeObservations() throws {
        let adapter = FrontendReceipt.Adapter()
        let spellings = ["τ_0_0.Element", "Swift.Optional<τ_1_2.Element>", "Self.Element", "Container<τ_0_0>",
                         "__C_Synthesized.related decl 'e' for UIGuidedAccessErrorCode"]
        for spelling in spellings {
            #expect(adapter.importedNativeNominal(in: spelling) == nil)
            #expect(adapter.importedNativeType(rawMangledType: "$sSo13RuntimeNestedCD", spelling: spelling,
                source: .init(logicalPath: "Generic.swift", url: URL(fileURLWithPath: "/tmp/Generic.swift"), contents: Data(), contentHash: .sha256(Data())),
                importedModules: ["Foundation"], requiresMainActor: false) == nil)
        }
        let uses = (["RuntimeNested", "Namespace.Nested"] + spellings).map {
            type("RuntimeNested", swift: $0, source: "Generic.swift")
        }
        let merged = try adapter.mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
        #expect(merged.count == 1 && merged.first?.swiftType == "Namespace.Nested")
        #expect(merged.first?.objectiveCRuntimeName == "RuntimeNested")
        #expect(merged.allSatisfy { !$0.aliases.contains { $0.contains("τ_") || $0.contains("Self") } })
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: uses.reversed(), operationTypes: []) == merged)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: merged, operationTypes: uses) == merged)
        #expect(FrontendReceipt.ImportedNominalIdentity.isConcreteSpelling("Namespace.myτ_0_0"))
        var conflicting = type("OtherRuntime", swift: "τ_0_0.Element", source: "Conflict.swift")
        conflicting.canonicalName = "RuntimeNested"
        #expect(throws: FrontendReceipt.Error.self) {
            try adapter.mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [conflicting])
        }
    }

    @Test("Only a unique declaring Catalog can refine an opaque Clang typedef layout")
    func refinesClangTypedefLayout() throws {
        let adapter = FrontendReceipt.Adapter()
        var fallback = FrontendReceipt.Adapter.ImportedNativeType(canonicalName: "CGColorSpaceRef",
            swiftType: "CGColorSpaceRef", kind: .value, aliases: ["__C.CGColorSpaceRef"], representation: .opaqueValue,
            representationEvidence: .clangTypealias, sourceFileLogicalID: "Use.swift",
            importedModules: ["CoreGraphics"], requiresMainActor: false)
        let authority = FrontendReceipt.Adapter.ImportedNativeType(canonicalName: "CoreGraphics.CGColorSpace",
            swiftType: "CoreGraphics.CGColorSpace", kind: .reference,
            aliases: ["CGColorSpace", "CGColorSpaceRef", "__C.CGColorSpaceRef"], representation: .reference,
            sourceFileLogicalID: "NativeAPICatalog/CoreGraphics.swift", importedModules: ["CoreGraphics"],
            nativeModuleName: "CoreGraphics", objectiveCModuleName: "CoreGraphics", requiresMainActor: false)
        let merged = try adapter.mergeImportedNativeTypes(discoveredTypes: [authority], operationTypes: [fallback])
        #expect(merged.count == 1 && merged[0].representation == .reference && merged[0].representationEvidence == .nominal)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: [fallback], operationTypes: [authority]) == merged)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: merged, operationTypes: [fallback]) == merged)
        fallback.representationEvidence = .nominal
        #expect(throws: FrontendReceipt.Error.self) {
            try adapter.mergeImportedNativeTypes(discoveredTypes: [authority], operationTypes: [fallback])
        }
        fallback.representationEvidence = .clangTypealias
        var conflict = authority
        conflict.kind = .value
        conflict.representation = .opaqueValue
        #expect(throws: FrontendReceipt.Error.self) {
            try adapter.mergeImportedNativeTypes(discoveredTypes: [authority, conflict], operationTypes: [fallback])
        }
    }

    @Test("Qualified and relative Progress uses normalize across every merge and alias consumer")
    func mergesProgressSpellings() throws {
        let uses = ["NSProgress", "Foundation.Progress", "Progress"].enumerated().map {
            type("NSProgress", swift: $0.element, source: "Sources/File\($0.offset).swift")
        }
        let adapter = FrontendReceipt.Adapter()
        let expected = try adapter.mergeImportedNativeTypes(discoveredTypes: [], operationTypes: uses)
        #expect(expected.count == 1)
        let progress = try #require(expected.first)
        #expect(progress.canonicalName == "NSProgress")
        #expect(progress.objectiveCRuntimeName == "NSProgress")
        #expect(progress.swiftType == "Foundation.Progress")
        #expect(Set(progress.aliases).isSuperset(of: ["NSProgress", "Progress"]))
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: uses.reversed(), operationTypes: []) == expected)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: expected, operationTypes: uses) == expected)
        let aliases = try adapter.makeImportedSwiftTypeAliases(expected)
        for spelling in ["NSProgress", "Progress", "Foundation.Progress"] {
            #expect(aliases[spelling] == "Foundation.Progress")
            #expect(FrontendReceipt.ImportedTypeIndex(types: expected).matching(spellings: [spelling]) == expected)
        }
        #expect(FrontendReceipt.SwiftTypeSpelling.replacingNominalAliases(
            in: "(Progress, [Foundation.Progress?]) -> NSProgress", aliases: aliases
        ) == "(Foundation.Progress, [Foundation.Progress?]) -> Foundation.Progress")
    }

    @Test("Nested scopes survive module qualification normalization")
    func preservesNestedScopes() throws {
        let uses = ["Namespace.Nested", "Foundation.Namespace.Nested"].map {
            type("RuntimeNested", swift: $0, source: "Sources/Nested.swift")
        }
        let adapter = FrontendReceipt.Adapter()
        let merged = try adapter.mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
        #expect(merged.count == 1)
        #expect(merged.first?.canonicalName == "Foundation.Namespace.Nested")
        #expect(merged.first?.aliases.contains("Namespace.Nested") == true)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: merged, operationTypes: []) == merged)
    }

    @Test("Measured declaring modules support qualifications through reexports")
    func acceptsProvenReexports() throws {
        let uses = ["Progress", "Foundation.Progress"].map { spelling in
            var use = type("NSProgress", swift: spelling, source: "Reexport.swift")
            use.importedModules = ["UIKit"]
            use.objectiveCModuleName = "Foundation"
            return use
        }
        let merged = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
        #expect(merged.first?.canonicalName == "NSProgress")
        #expect(merged.first?.swiftType == "Foundation.Progress")
    }

    @Test("Qualified flat Clang names are ABI evidence alongside a nested Swift overlay")
    func mergesFlatAndNestedObjectiveCNames() throws {
        let spellings = ["RuntimeNested", "Foundation.RuntimeNested", "__C.RuntimeNested",
                         "Namespace.Nested", "Foundation.Namespace.Nested"]
        let uses = spellings.enumerated().map {
            type("RuntimeNested", swift: $0.element, source: "File\($0.offset).swift")
        }
        let adapter = FrontendReceipt.Adapter()
        let merged = try adapter.mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
        let value = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(value.swiftType == "Foundation.Namespace.Nested")
        #expect(value.objectiveCRuntimeName == "RuntimeNested")
        #expect(Set(value.aliases + [value.swiftType]).isSuperset(of: spellings))
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: merged, operationTypes: uses) == merged)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: [], operationTypes: uses.reversed()) == merged)
        var unproven = uses
        for index in unproven.indices { unproven[index].objectiveCRuntimeName = nil }
        #expect(throws: FrontendReceipt.Error.self) {
            try adapter.mergeImportedNativeTypes(discoveredTypes: unproven, operationTypes: [])
        }
    }

    @Test("Repeated use sites do not duplicate conflict facts")
    func boundsRepeatedDiagnostics() {
        let uses = (0..<1_000).map {
            type("NSProgress", swift: $0.isMultiple(of: 2) ? "First.Progress" : "Second.Progress",
                 source: "Sources/File\($0).swift")
        }
        do {
            _ = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
            Issue.record("Expected conflicting modules")
        } catch {
            #expect(String(describing: error).split(separator: "\n").count == 3)
        }
    }

    @Test("Diagnostic examples do not change persisted compiler projections")
    func excludesDiagnosticLocationsFromArtifacts() throws {
        let original = type("NSProgress", swift: "Progress", source: "Sources/Progress.swift")
        var located = original
        located.sourceLocation = .init(file: "Sources/Progress.swift", line: 10, column: 3)
        #expect(try Core.CanonicalJSON.encode(located) == Core.CanonicalJSON.encode(original))
    }

    @Test("True module and scope conflicts report each spelling and its source", arguments: [
        ["First.Progress", "Second.Progress"],
        ["Foundation.Outer.Progress", "Progress"],
        ["Unimported.Progress", "Progress"],
    ])
    func rejectsUnprovenEquivalence(_ spellings: [String]) {
        let uses = spellings.enumerated().map { index, spelling in
            var use = type("NSProgress", swift: spelling, source: "Sources/File\(index).swift")
            use.importedModules = ["Foundation", "First", "Second"]
            use.sourceLocation = .init(file: use.sourceFileLogicalID, line: index + 10, column: 3)
            return use
        }
        do {
            _ = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
            Issue.record("Expected an identity conflict")
        } catch {
            let message = String(describing: error)
            for (index, spelling) in spellings.enumerated() {
                #expect(message.contains(spelling))
                #expect(message.contains("Sources/File\(index).swift:\(index + 10):3"))
            }
            #expect(message.contains("Foundation"))
            #expect(message.contains("NSProgress"))
        }
    }

    @Test("A common overlay spelling cannot collapse distinct Objective-C ABI identities")
    func retainsDistinctRuntimes() throws {
        let merged = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: [
            type("FirstRuntime", swift: "Progress", source: "A.swift"),
            type("SecondRuntime", swift: "Foundation.Progress", source: "B.swift"),
        ], operationTypes: [])
        #expect(Set(merged.map(\.canonicalName)) == ["FirstRuntime", "SecondRuntime"])
    }

    @Test("Conflicting runtime facts cannot disappear when normalizing canonical groups")
    func rejectsContradictoryRuntimes() {
        var first = type("FirstRuntime", swift: "First.Nested", source: "First.swift")
        var second = type("SecondRuntime", swift: "Second.Nested", source: "Second.swift")
        first.canonicalName = "SharedCanonical"
        second.canonicalName = "SharedCanonical"
        do {
            _ = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: [first, second], operationTypes: [])
            Issue.record("Conflicting runtime identities were normalized away")
        } catch {
            let message = String(describing: error)
            for fact in ["SharedCanonical", "FirstRuntime", "SecondRuntime", "First.swift", "Second.swift"] {
                #expect(message.contains(fact))
            }
        }
    }

    @Test("An erased Objective-C runtime class does not equate lightweight generic instantiations")
    func preservesObjectiveCGenericArguments() throws {
        let uses = ["NSLayoutXAxisAnchor", "NSLayoutYAxisAnchor"].map { argument in
            var use = type("NSLayoutAnchor", swift: "NSLayoutAnchor<\(argument)>", source: "Layout.swift")
            use.canonicalName = use.swiftType
            use.importedModules = ["UIKit"]
            return use
        }
        let merged = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
        #expect(Set(merged.map(\.canonicalName)) == Set(uses.map(\.canonicalName)))
        #expect(merged.count == 2)
    }

    @Test("Declaring module conflicts include the compiler provenance")
    func diagnosesDeclaringModules() {
        var first = type("NSProgress", swift: "Progress", source: "First.swift")
        first.objectiveCModuleName = "Foundation"
        var second = type("NSProgress", swift: "Foundation.Progress", source: "Second.swift")
        second.objectiveCModuleName = "AlternateFoundation"
        do {
            _ = try FrontendReceipt.Adapter().mergeImportedNativeTypes(discoveredTypes: [first], operationTypes: [second])
            Issue.record("Expected declaring module conflict")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("declaringModule=Foundation"))
            #expect(message.contains("declaringModule=AlternateFoundation"))
            #expect(message.contains("First.swift"))
            #expect(message.contains("Second.swift"))
        }
    }

    private func type(_ runtime: String, swift: String, source: String) -> FrontendReceipt.Adapter.ImportedNativeType {
        .init(canonicalName: runtime, swiftType: swift, kind: .reference,
              aliases: [], representation: .reference, sourceFileLogicalID: source,
              importedModules: ["Foundation"], objectiveCRuntimeName: runtime,
              requiresMainActor: false)
    }

    @Test("Large independent Catalog and Clang alias sets preserve identity and input-order invariance")
    func measuresAliasNormalization() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = try #require(Int(environment["HELIX_ALIAS_TYPE_COUNT"] ?? "128"))
        try #require((1...10_000).contains(count))
        var uses: [FrontendReceipt.Adapter.ImportedNativeType] = []
        for index in 0..<count {
            var authority = FrontendReceipt.Adapter.ImportedNativeType(canonicalName: "Type\(index)",
                swiftType: "Fixture.Type\(index)", kind: .value, aliases: ["Type\(index)", "Fixture.Type\(index)"],
                representation: .opaqueValue, sourceFileLogicalID: "Catalog.swift", importedModules: ["Fixture"], requiresMainActor: false)
            authority.nativeModuleName = "Fixture"
            var observed = authority
            observed.nativeModuleName = nil
            observed.swiftType = "Type\(index)"
            observed.aliases = []
            uses += [authority, observed,
                .init(canonicalName: "NSItem\(index)", swiftType: "NSItem\(index)", kind: .value,
                    aliases: [], representation: .opaqueValue, sourceFileLogicalID: "ABI.swift", importedModules: ["Fixture"], requiresMainActor: false),
                .init(canonicalName: "Item\(index)", swiftType: "Item\(index)", kind: .value,
                    aliases: ["__C.NSItem\(index)"], representation: .opaqueValue, sourceFileLogicalID: "Overlay.swift", importedModules: ["Fixture"], requiresMainActor: false)]
        }
        let adapter = FrontendReceipt.Adapter()
        var durations: [UInt64] = []
        var merged: [FrontendReceipt.Adapter.ImportedNativeType] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            merged = try adapter.mergeImportedNativeTypes(discoveredTypes: uses, operationTypes: [])
            durations.append((DispatchTime.now().uptimeNanoseconds - start) / 1_000)
        }
        #expect(merged.count == 2 * count)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: uses.reversed(), operationTypes: []) == merged)
        #expect(try adapter.mergeImportedNativeTypes(discoveredTypes: merged, operationTypes: uses) == merged)
        if let path = environment["HELIX_ALIAS_REPORT"] {
            try #require(path.hasPrefix("/"))
            let data = try JSONSerialization.data(withJSONObject: ["independentTypePairs": count, "observations": uses.count,
                "wallMicroseconds": durations, "outputHash": Core.Digest.sha256(try Core.CanonicalJSON.encode(merged)).hex], options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
}
