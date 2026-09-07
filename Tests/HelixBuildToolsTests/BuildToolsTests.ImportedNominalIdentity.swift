import HelixCore
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Imported nominal identity normalization")
struct ImportedNominalIdentityTests {
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
}
}
