import Foundation
import HelixBytecode
import HelixCore
import HelixVerifier
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("File-based business corpus")
struct BusinessCorpus {
    @Test("Checkout pricing compiles, verifies, and executes")
    func checkout() throws {
        let fixture = try compile(
            file: "Checkout.swift",
            functionName: "checkoutTotal",
            signature: .init(
                parameters: [
                    "Swift.Array<Swift.Int>",
                    "Swift.Array<Swift.Int>",
                    "Swift.Optional<Swift.Int>",
                ],
                result: "Swift.Int"
            ),
            parameterTypes: [
                .array(.int64),
                .array(.int64),
                .optional(.int64),
            ],
            resultType: .int64
        )

        #expect(invoke(fixture, arguments: [
            try integers([1_200, 500]),
            try integers([2, 3]),
            .optional(try integer(400)),
        ]) == .returned(try integer(3_500)))
        #expect(invoke(fixture, arguments: [
            try integers([100]),
            try integers([]),
            .optional(nil),
        ]) == .returned(try integer(-1)))
        #expect(invoke(fixture, arguments: [
            try integers([100]),
            try integers([2]),
            .optional(try integer(200)),
        ]) == .returned(try integer(0)))
        #expect(invoke(fixture, arguments: [
            try integers([]),
            try integers([]),
            .optional(nil),
        ]) == .returned(try integer(0)))
        #expect(invoke(fixture, arguments: [
            try integers([100]),
            try integers([2]),
            .optional(try integer(-5)),
        ]) == .returned(try integer(200)))
    }

    @Test("Form validation compiles, verifies, and executes")
    func formValidation() throws {
        let fields = VM.Value.dictionary(
            [
                .init(key: .string("name"), value: .string("Ada")),
                .init(key: .string("email"), value: .string("ada@example.com")),
            ],
            keyType: .string,
            valueType: .string
        )
        let fixture = try compile(
            file: "FormValidation.swift",
            functionName: "formMessage",
            signature: .init(
                parameters: ["Swift.Dictionary<Swift.String, Swift.String>"],
                result: "Swift.String"
            ),
            parameterTypes: [.dictionary(key: .string, value: .string)],
            resultType: .string
        )
        #expect(invoke(fixture, arguments: [fields]) == .returned(.string("Ada:2")))
        #expect(
            invoke(fixture, arguments: [stringDictionary([:])])
                == .returned(.string("Missing name"))
        )
        #expect(
            invoke(fixture, arguments: [stringDictionary(["name": "Ada"])])
                == .returned(.string("Missing email"))
        )
        #expect(invoke(fixture, arguments: [
            stringDictionary(["name": "Ada", "email": "invalid"]),
        ]) == .returned(.string("Invalid email")))
    }

    @Test("Feed scoring compiles, verifies, and executes")
    func feedMetrics() throws {
        let events = VM.Value.array(
            [
                .string("unread:message"),
                .string("read:notice"),
                .string("unread:mention"),
            ],
            elementType: .string
        )
        let weights = VM.Value.dictionary(
            [
                .init(key: .string("unread:message"), value: try integer(3)),
            ],
            keyType: .string,
            valueType: .int64
        )
        let fixture = try compile(
            file: "FeedMetrics.swift",
            functionName: "unreadScore",
            signature: .init(
                parameters: [
                    "Swift.Array<Swift.String>",
                    "Swift.Dictionary<Swift.String, Swift.Int>",
                ],
                result: "Swift.Int"
            ),
            parameterTypes: [
                .array(.string),
                .dictionary(key: .string, value: .int64),
            ],
            resultType: .int64
        )
        #expect(invoke(fixture, arguments: [events, weights]) == .returned(try integer(4)))
        #expect(invoke(fixture, arguments: [
            VM.Value.array([], elementType: .string),
            weights,
        ]) == .returned(try integer(0)))
        #expect(invoke(fixture, arguments: [
            VM.Value.array([.string("read:notice")], elementType: .string),
            weights,
        ]) == .returned(try integer(0)))
    }

    @Test("Order state flow compiles, verifies, and executes")
    func orderWorkflow() throws {
        let fixture = try compile(
            file: "OrderWorkflow.swift",
            functionName: "orderDecision",
            signature: .init(
                parameters: ["Swift.Int", "Swift.Optional<Swift.Int>"],
                result: "Swift.String"
            ),
            parameterTypes: [.int64, .optional(.int64)],
            resultType: .string
        )
        #expect(invoke(fixture, arguments: [
            try integer(0),
            .optional(try integer(200)),
        ]) == .returned(.string("accepted:200")))
        #expect(invoke(fixture, arguments: [
            try integer(1),
            .optional(nil),
        ]) == .returned(.string("retry:2")))
        #expect(invoke(fixture, arguments: [
            try integer(3),
            .optional(nil),
        ]) == .returned(.string("blocked")))
    }

    private struct CompiledFixture {
        var image: Verification.Image
        var entry: Core.EntryIndex
    }

    private func compile(
        file: String,
        functionName: String,
        signature: Core.LoweredSignature,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType
    ) throws -> CompiledFixture {
        let sourceURL = fixtureDirectory.appendingPathComponent(file)
        let logicalPath = "BusinessCorpus/\(file)"
        let moduleName = "HelixBusinessCorpus_\(functionName)"
        let canonicalSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            moduleName: moduleName,
            purpose: .semanticLowering
        )
        let silFile = try CanonicalSIL.File(text: canonicalSIL)
        let matches = silFile.functions.filter { $0.mangledName.contains(functionName) }
        guard let shortestNameLength = matches.map(\.mangledName.count).min() else {
            throw CanonicalSIL.LoweringError.functionSelection(
                "expected one root SIL function containing \(functionName), found \(matches.count) candidates"
            )
        }
        let roots = matches.filter { $0.mangledName.count == shortestNameLength }
        guard roots.count == 1, let function = roots.first else {
            throw CanonicalSIL.LoweringError.functionSelection(
                "expected one root SIL function containing \(functionName), found \(matches.count) candidates"
            )
        }
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.business-corpus",
            buildNumber: "1",
            seed: file
        )
        let key = try Core.FunctionKey.derive(
            namespace: namespace,
            module: moduleName,
            sourceFileLogicalID: logicalPath,
            canonicalDeclaration: "func \(functionName)",
            loweredSignature: signature,
            role: .function
        )
        let shellHash = Core.Digest.sha256("helix-business-corpus-\(file)")
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "swift-business-corpus"
        )
        let entry = Core.EntryIndex(rawValue: 0)
        let compiled = try PatchCompiler.Driver().compile(
            .init(
                canonicalSIL: canonicalSIL,
                mangledName: function.mangledName,
                displayName: functionName,
                functionKey: key,
                entryIndex: entry,
                shellInterfaceHash: shellHash,
                compatibility: compatibility,
                sourceFileLogicalID: logicalPath
            )
        )
        #expect(!compiled.module.sourceMap.isEmpty)
        #expect(
            compiled.module.sourceMap.allSatisfy {
                $0.location.file == logicalPath
            }
        )
        let compiledEntry = try #require(compiled.module.entries.first)
        let compiledRoot = try #require(
            compiled.module.functions.first {
                $0.id == compiledEntry.functionID
            }
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: compiled.module.capabilities,
            entries: [
                .init(
                    index: entry,
                    key: key,
                    parameterTypes: parameterTypes,
                    parameterConventions: compiledRoot.parameterConventions,
                    resultType: resultType
                ),
            ]
        )
        let image = try Verification.Engine().verify(
            bytes: compiled.bytecode,
            shell: shell,
            policy: .init(acceptedCapabilities: compiled.module.capabilities)
        )
        return .init(image: image, entry: entry)
    }

    private func invoke(
        _ fixture: CompiledFixture,
        arguments: [VM.Value]
    ) -> VM.ExecutionResult {
        VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: arguments
        )
    }

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BusinessCorpus", isDirectory: true)
    }

    private func integers(_ values: [Int64]) throws -> VM.Value {
        .array(try values.map(integer), elementType: .int64)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try VM.Integer(signed: value, bitWidth: 64, isSigned: true))
    }

    private func stringDictionary(_ values: [String: String]) -> VM.Value {
        .dictionary(
            values.map { .init(key: .string($0.key), value: .string($0.value)) },
            keyType: .string,
            valueType: .string
        )
    }
}
}
