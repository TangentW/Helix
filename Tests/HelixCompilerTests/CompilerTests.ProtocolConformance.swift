import Foundation
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift protocol conformance inventory")
struct ProtocolConformanceTests {
    @Test("Real frontend witness tables retain exact concrete evidence")
    func inventoriesRealFrontendConformances() throws {
        let sil = try emitSIL(
            """
            public protocol Auditable<Item> {
                associatedtype Item: Equatable
                var item: Item { get set }
                mutating func normalize()
                func score() -> Int
            }

            public protocol Tagged {
                var tag: String { get }
            }

            public struct Model: Auditable, Tagged, Hashable {
                public var item: Int
                public var tag: String
                public mutating func normalize() { item = Swift.max(0, item) }
                public func score() -> Int { item }
            }

            public struct Box<Element: Equatable>: Equatable {
                public var value: Element
            }
            """
        )
        let environment = try CanonicalSIL.File(text: sil)
            .protocolConformances

        let auditable = try #require(environment.records.first {
            $0.conformingType == "Model" && $0.protocolName == "Auditable"
        })
        #expect(auditable.moduleName == "HelixProtocolConformanceFixture")
        #expect(auditable.genericClause == nil)
        #expect(auditable.associatedTypes["Item"] == "Int")
        #expect(auditable.associatedConformances["(Item: Equatable)"] != nil)
        #expect(auditable.witnesses(for: "Auditable.item!getter").first?.symbol != nil)
        #expect(auditable.witnesses(for: "Auditable.item!setter").first?.symbol != nil)
        #expect(auditable.witnesses(for: "Auditable.normalize").first?.symbol != nil)
        #expect(auditable.witnesses(for: "Auditable.score").first?.symbol != nil)
        #expect(auditable.isComplete)

        let hashable = try #require(environment.records.first {
            $0.conformingType == "Model" && $0.protocolName == "Hashable"
        })
        #expect(hashable.baseProtocols == ["Equatable"])

        let generic = try #require(environment.records.first {
            $0.conformingType == "Box<Element>"
                && $0.protocolName == "Equatable"
        })
        #expect(generic.genericClause == "<Element where Element : Equatable>")
        #expect(generic.witnesses(for: "Equatable.\"==\"").first?.symbol != nil)
        #expect(environment.records == environment.records.sorted {
            $0.orderKey < $1.orderKey
        })
    }

    @Test("Printed conformance collisions retain every occurrence without supplying dispatch identity")
    func retainsScopedCandidates() throws {
        let duplicateRecord = """
        sil_witness_table Value: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @first
        }
        sil_witness_table Value: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @second
        }
        """
        let duplicates = try CanonicalSIL.ProtocolConformance.Environment(text: duplicateRecord)
        #expect(duplicates.records.count == 2)
        #expect(duplicates.records.map(\.sourceLine) == [1, 4])
        #expect(duplicates.unambiguousRecords.isEmpty)
        #expect(duplicates.specializedRecords(conformingType: "Value").isEmpty)
        #expect(duplicates.isAmbiguousType("Fixture.Value"))
        #expect(duplicates.ambiguityEvidence(for: "Value").joined().contains("first"))
        #expect(duplicates.ambiguityEvidence(for: "Value").joined().contains("second"))
        #expect(duplicates.containsWitnessTarget("first", moduleName: "Fixture"))
        #expect(duplicates.containsWitnessTarget("second", moduleName: "Fixture"))
        #expect(!duplicates.containsWitnessTarget("first", moduleName: "Other"))

        let ambiguousConditionalRecords = """
        sil_witness_table <Element where Element : Equatable> Box<Element>: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @first
        }
        sil_witness_table <T where T : Hashable> Fixture.Box<T>: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @second
        }
        """
        let conditional = try CanonicalSIL.ProtocolConformance.Environment(text: ambiguousConditionalRecords)
        #expect(conditional.records.count == 2)
        #expect(conditional.specializedRecords(conformingType: "Box<Int>").isEmpty)
        #expect(conditional.isAmbiguousType("Fixture.Box<Int>"))
    }

    @Test("Malformed conformance evidence fails closed")
    func rejectsMalformedEvidence() throws {
        do {
            _ = try CanonicalSIL.ProtocolConformance.Environment(text: """
            sil_witness_table Value: Feature module Fixture {
              associated_type Item: Int
              associated_type Item: String
            }
            """)
            Issue.record("Duplicate associated type was accepted")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("SIL line 1: sil_witness_table Value: Feature module Fixture"))
            #expect(message.contains("SIL line 2: associated_type Item: Int"))
            #expect(message.contains("SIL line 3: associated_type Item: String"))
        }
        let missingTarget = """
        sil_witness_table Value: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int
        }
        """
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.ProtocolConformance.Environment(
                text: missingTarget
            )
        }
    }

    @Test("Incomplete and marker candidates cannot disappear before identity checks")
    func retainsIncompleteCandidates() throws {
        let file = try CanonicalSIL.File(text: """
        sil_stage canonical
        struct Local {
          @_hasStorage var value: Int { get set }
          struct Child {
          }
        }
        struct Safe {
          @_hasStorage var value: Int { get set }
        }
        sil_witness_table Local: Feature module Fixture {
          future_requirement #Feature.value: @future
        }
        sil_witness_table Local: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @value
        }
        sil_witness_table Local: Marker module Fixture {
        }
        sil_witness_table Empty: Marker module Fixture {
        }
        sil_witness_table Empty: Marker module Fixture {
        }
        sil_witness_table Safe: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @safe
        }
        sil_witness_table Local.Child: Feature module Fixture {
        }
        """)
        let environment = file.protocolConformances
        #expect(environment.records.count == 7)
        #expect(environment.unambiguousRecords.map(\.conformingType) == ["Safe"])
        #expect(environment.specializedRecords(conformingType: "Local", protocolName: "Marker").isEmpty)
        let caller = CanonicalSIL.Function(mangledName: "$s7Fixture6calleryyF",
            loweredType: "$@convention(thin) () -> ()", body: "")
        let resolver = try CanonicalSIL.ProtocolExistential.Resolver(file: file, function: caller)
        let identity = try #require(CanonicalSIL.ProtocolExistential.Identity(spelling: "any Feature"))
        #expect(try resolver.conformers(to: identity).map(\.spelling) == ["Safe"])
        #expect(throws: CanonicalSIL.LoweringError.self) { try file.typeEnvironment.resolve("Local") }
        #expect(throws: CanonicalSIL.LoweringError.self) { try file.typeEnvironment.resolve("Local.Child") }
        #expect(environment.isAmbiguousType("Fixture.Local<Int>.Child<Swift.String>"))
        #expect(try file.typeEnvironment.resolve("Safe") == .local(.init(rawValue: "Safe")))
        let clause = try CanonicalSIL.GenericSignature.standaloneClause("<T where T : Feature>")
        do {
            _ = try CanonicalSIL.GenericSignature.resolve(clause, bindings: ["T": "Local"],
                conformances: environment, typeEnvironment: file.typeEnvironment)
            Issue.record("Ambiguous conformance supplied a generic proof")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("ambiguous printed conformance identity"))
            #expect(message.contains("SIL line 10"))
            #expect(message.contains("future_requirement"))
            #expect(message.contains("value"))
        }
    }

    @Test("Real local conformers and fileprivate extension members do not block a module")
    func realScopedDeclarations() throws {
        let sil = try emitSIL(sources: ["""
        public protocol Feature { func value() -> Int }
        public enum Scope {}
        fileprivate extension Scope {
            class Nested { var storage = 1 }
            struct Box<T> { let value: T }
        }
        public func first() -> Int {
            struct Local: Feature { func value() -> Int { 1 } }
            return Local().value()
        }
        public struct Safe { public var value: Int }
        """, """
        fileprivate extension Scope {
            class Nested { var storage = "two" }
            struct Box<T> { let value: [T] }
        }
        public func second() -> Int {
            struct Local: Feature { func value() -> Int { 2 } }
            return Local().value()
        }
        """])
        let file = try CanonicalSIL.File(text: sil)
        let locals = file.protocolConformances.records.filter { $0.conformingType == "Local" }
        #expect(locals.count == 2)
        #expect(Set(locals.flatMap(\.witnesses).compactMap(\.symbol)).count == 2)
        #expect(file.protocolConformances.isAmbiguousType("Local"))
        #expect(throws: CanonicalSIL.LoweringError.self) { try file.typeEnvironment.resolve("Scope.Nested") }
        #expect(throws: CanonicalSIL.LoweringError.self) { try file.typeEnvironment.resolve("Scope.Box<Int>") }
        #expect(try file.typeEnvironment.resolve("Safe") == .local(.init(rawValue: "Safe")))
    }

    @Test("Unavailable optional requirements remain explicit")
    func preservesUnavailableRequirements() throws {
        let environment = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table [serialized] public Value: Feature module Fixture {
              method #Feature.optional: <Self where Self : Feature> (Self) -> () -> Int : nil
            }
            """
        )
        let record = try #require(environment.records.first)
        #expect(record.conformingType == "Value")
        #expect(record.protocolName == "Feature")
        #expect(record.witnesses(for: "Feature.optional").first?.symbol == nil)
    }

    @Test("Conditional conformance evidence remains structured")
    func preservesConditionalConformanceEvidence() throws {
        let environment = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table <Element where Element : Equatable> Box<Element>: Feature module Fixture {
              conditional_conformance (Element: Equatable): dependent
            }
            """
        )
        let record = try #require(environment.records.first)
        #expect(record.isComplete)
        #expect(record.conditionalConformances == [
            .init(requirement: "Element: Equatable", evidence: "dependent"),
        ])

        let inconsistent = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table <Element where Element : Equatable> Box<Element>: Feature module Fixture {
              conditional_conformance (Element: Hashable): dependent
            }
            """
        )
        #expect(inconsistent.records.first?.isComplete == false)
    }

    @Test("Overloaded requirements retain distinct lowered ABIs")
    func preservesOverloadedRequirements() throws {
        let environment = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table Value: Feature module Fixture {
              method #Feature.init!allocator: <Self where Self : Feature> (Self.Type) -> (Int) -> Self : @fromInt
              method #Feature.init!allocator: <Self where Self : Feature> (Self.Type) -> (String) -> Self : @fromString
            }
            """
        )
        let witnesses = try #require(environment.records.first)
            .witnesses(for: "Feature.init!allocator")
        #expect(witnesses.map(\.symbol) == ["fromInt", "fromString"])
        #expect(Set(witnesses.map(\.loweredType)).count == 2)
    }

    @Test("Textually indistinguishable requirements retain table order")
    func preservesTextuallyIndistinguishableRequirements() throws {
        let environment = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table Int: FixedWidthInteger module Swift {
              method #FixedWidthInteger.init!allocator: <Self where Self : FixedWidthInteger> (Self.Type) -> (Self) -> Self : @bigEndian
              method #FixedWidthInteger.init!allocator: <Self where Self : FixedWidthInteger> (Self.Type) -> (Self) -> Self : @littleEndian
            }
            """
        )
        let witnesses = try #require(environment.records.first)
            .witnesses(for: "FixedWidthInteger.init!allocator")
        try #require(witnesses.count == 2)
        #expect(witnesses.map(\.symbol) == ["bigEndian", "littleEndian"])
        #expect(witnesses[0].loweredType == witnesses[1].loweredType)
    }

    @Test("Unfamiliar evidence blocks only the selected conformance")
    func preservesUnfamiliarEvidence() throws {
        let environment = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table Value: Feature module Fixture {
              future_requirement #Feature.value: @future
            }
            """
        )
        let record = try #require(environment.records.first)
        #expect(!record.isComplete)
        #expect(record.unsupportedMembers == [
            "future_requirement #Feature.value: @future",
        ])
    }

    @Test("Imported declarations without witness targets are ignored")
    func ignoresImportedDeclarations() throws {
        let environment = try CanonicalSIL.ProtocolConformance.Environment(
            text: """
            sil_witness_table DispatchWorkItemFlags: SetAlgebra module Dispatch
            sil_witness_table Value: Feature module Fixture {
              method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @value
            }
            """
        )
        #expect(environment.records.map(\.conformingType) == ["Value"])

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.ProtocolConformance.Environment(
                text: "sil_witness_table Value: Feature"
            )
        }
    }

    private func emitSIL(_ source: String) throws -> String {
        try emitSIL(sources: [source])
    }

    private func emitSIL(sources: [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-protocol-conformance-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURLs = try sources.enumerated().map { index, source in
            let url = directory.appendingPathComponent("Protocol\(index).swift")
            try Data((source + "\n").utf8).write(to: url)
            return url
        }
        return try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: sourceURLs,
            moduleName: "HelixProtocolConformanceFixture",
            optimization: "-Onone",
            additionalArguments: ["-parse-as-library", "-g"],
            purpose: .semanticLowering
        )
    }
}
}
