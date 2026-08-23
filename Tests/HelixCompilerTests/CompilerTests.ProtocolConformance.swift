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

    @Test("Malformed conformance evidence fails closed")
    func rejectsMalformedEvidence() throws {
        let duplicateRecord = """
        sil_witness_table Value: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @first
        }
        sil_witness_table Value: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @second
        }
        """
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.ProtocolConformance.Environment(
                text: duplicateRecord
            )
        }

        let ambiguousConditionalRecords = """
        sil_witness_table <Element where Element : Equatable> Box<Element>: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @first
        }
        sil_witness_table <Element where Element : Hashable> Box<Element>: Feature module Fixture {
          method #Feature.value: <Self where Self : Feature> (Self) -> () -> Int : @second
        }
        """
        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.ProtocolConformance.Environment(
                text: ambiguousConditionalRecords
            )
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
        let sourceURL = directory.appendingPathComponent("Protocol.swift")
        try Data((source + "\n").utf8).write(to: sourceURL)
        return try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: "HelixProtocolConformanceFixture",
            optimization: "-Onone",
            additionalArguments: ["-parse-as-library"],
            purpose: .semanticLowering
        )
    }
}
}
