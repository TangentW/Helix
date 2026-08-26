import Foundation
import HelixCore
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Objective-C declaration reference mapping")
struct DeclarationReferences {
    @Test("Member reads, multiline writes, and methods retain exact Clang identity")
    func mapsFrontendReferenceFormsWithoutGuessing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-declaration-references-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let sourceText = """
        label.textAlignment
            = .center
        label.setText("x")
        object.layer.opacity = 1
        """
        let source = Data(sourceText.utf8)
        try source.write(to: sourceURL)

        func offset(_ token: String) throws -> Int {
            try #require(source.range(of: Data(token.utf8))).lowerBound
        }
        let label = try offset("label.textAlignment")
        let textAlignment = try offset("textAlignment")
        let center = try offset(".center")
        let setText = try offset("setText")
        let object = try offset("object.layer.opacity")
        let layer = try offset("layer")
        let opacity = try offset("opacity")
        let one = try offset("1")
        let textAlignmentUSR = "c:objc(cs)UILabel(py)textAlignment"
        let setTextUSR = "c:objc(cs)UILabel(im)setText:"
        let layerUSR = "c:objc(cs)UIView(py)layer"
        let opacityUSR = "c:objc(cs)CALayer(py)opacity"

        let textAlignmentReference: SwiftFrontend.TypedAST.Object = [
            "_kind": "member_ref_expr",
            "range": ["start": label, "end": textAlignment],
            "decl": ["decl_usr": textAlignmentUSR],
        ]
        let nestedDestination: SwiftFrontend.TypedAST.Object = [
            "_kind": "member_ref_expr",
            "range": ["start": object, "end": opacity],
            "decl": ["decl_usr": opacityUSR],
            "base": [
                "_kind": "member_ref_expr",
                "range": ["start": object, "end": layer],
                "decl": ["decl_usr": layerUSR],
            ] as SwiftFrontend.TypedAST.Object,
        ]
        let document: SwiftFrontend.TypedAST.Object = [
            "_kind": "source_file",
            "filename": sourceURL.path,
            "items": [
                [
                    "_kind": "assign_expr",
                    "dest": textAlignmentReference,
                    "src": [
                        "_kind": "dot_syntax_call_expr",
                        "range": ["start": center, "end": center + 1],
                    ] as SwiftFrontend.TypedAST.Object,
                ] as SwiftFrontend.TypedAST.Object,
                [
                    "_kind": "declref_expr",
                    "range": ["start": setText, "end": setText],
                    "decl": ["decl_usr": setTextUSR],
                ] as SwiftFrontend.TypedAST.Object,
                [
                    "_kind": "assign_expr",
                    "dest": nestedDestination,
                    "src": [
                        "_kind": "integer_literal_expr",
                        "range": ["start": one, "end": one],
                    ] as SwiftFrontend.TypedAST.Object,
                ] as SwiftFrontend.TypedAST.Object,
            ],
        ]
        let references = try CanonicalSIL.DeclarationReferenceMap(
            documents: [document],
            sourceFiles: [sourceURL]
        )

        #expect(references.usr(at: .init(
            file: sourceURL.path,
            line: 1,
            column: 7
        )) == textAlignmentUSR)
        #expect(references.usr(at: .init(
            file: sourceURL.path,
            line: 2,
            column: 5
        )) == textAlignmentUSR)
        #expect(references.usr(at: .init(
            file: sourceURL.path,
            line: 3,
            column: 7
        )) == setTextUSR)
        #expect(references.usr(at: .init(
            file: sourceURL.path,
            line: 4,
            column: 22
        )) == opacityUSR)
        #expect(references.usr(at: .init(
            file: sourceURL.path,
            line: 1,
            column: 1
        )) == nil)
        #expect(references.usr(at: .init(
            file: sourceURL.path,
            line: 2,
            column: 7
        )) == nil)
    }

    @Test("Conflicting frontend declarations remain unresolved")
    func rejectsAmbiguousReferenceEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-ambiguous-references-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data("object.call()".utf8).write(to: sourceURL)
        let document: SwiftFrontend.TypedAST.Object = [
            "_kind": "source_file",
            "filename": sourceURL.path,
            "items": ([
                "c:objc(cs)Fixture(im)first",
                "c:objc(cs)Fixture(im)second",
            ].map { usr in
                [
                    "_kind": "declref_expr",
                    "range": ["start": 7, "end": 7],
                    "decl": ["decl_usr": usr],
                ] as SwiftFrontend.TypedAST.Object
            }) + [[
                "_kind": "assign_expr",
                "dest": [
                    "_kind": "member_ref_expr",
                    "range": ["start": 0, "end": 0],
                    "decl": ["decl_usr": "c:objc(cs)Fixture(im)first"],
                ] as SwiftFrontend.TypedAST.Object,
                "src": [
                    "_kind": "integer_literal_expr",
                    "range": ["start": 12, "end": 12],
                ] as SwiftFrontend.TypedAST.Object,
            ] as SwiftFrontend.TypedAST.Object],
        ]
        let references = try CanonicalSIL.DeclarationReferenceMap(
            documents: [document],
            sourceFiles: [sourceURL]
        )

        #expect(references.usr(at: .init(
            file: sourceURL.path,
            line: 1,
            column: 8
        )) == nil)
    }

    @Test("Exact declaration identity wins over a raw foreign-call binding")
    func resolvesQualifiedBindingBeforeRawFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-qualified-foreign-call-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        try Data("object.call()".utf8).write(to: sourceURL)
        let declarationUSR = "c:objc(cs)Fixture(im)call"
        let references = try CanonicalSIL.DeclarationReferenceMap(
            documents: [[
                "_kind": "source_file",
                "filename": sourceURL.path,
                "items": [[
                    "_kind": "declref_expr",
                    "range": ["start": 7, "end": 7],
                    "decl": ["decl_usr": declarationUSR],
                ] as SwiftFrontend.TypedAST.Object],
            ]],
            sourceFiles: [sourceURL]
        )
        let rawSymbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
            reference: "#Fixture.call!foreign",
            loweredType: "@convention(objc_method) (Fixture) -> ()"
        )
        let qualifiedSymbol = CanonicalSIL.NativeBridgeSymbols
            .declarationQualifiedForeignCall(
                symbol: rawSymbol,
                declarationUSR: declarationUSR
            )
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: rawSymbol,
                parameterTypes: [],
                resultType: .void,
                target: .function(.init(rawValue: 1))
            ),
            .init(
                mangledName: qualifiedSymbol,
                parameterTypes: [],
                resultType: .void,
                target: .function(.init(rawValue: 2))
            ),
        ]).includingDeclarationReferences(references)

        #expect(calls.resolvedForeignSymbol(
            rawSymbol,
            at: .init(file: sourceURL.path, line: 1, column: 8)
        ) == qualifiedSymbol)
        #expect(calls.resolvedForeignSymbol(
            rawSymbol,
            at: .init(file: sourceURL.path, line: 1, column: 1)
        ) == rawSymbol)
    }
}
}
