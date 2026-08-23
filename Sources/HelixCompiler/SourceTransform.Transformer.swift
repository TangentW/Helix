import Foundation
import HelixCore

public enum SourceTransform {}

extension SourceTransform {
/// Gives the generated physical file a distinct basename while the contents
/// retain the developer-facing logical path through `#sourceLocation`.
public static func transformedFilePath(for logicalPath: String) -> String {
    guard let separator = logicalPath.lastIndex(of: "/") else {
        return "HelixGenerated.\(logicalPath)"
    }
    let nameStart = logicalPath.index(after: separator)
    return String(logicalPath[...separator])
        + "HelixGenerated."
        + logicalPath[nameStart...]
}

public struct Edit: Codable, Hashable, Sendable {
    public var utf8Offset: Int
    public var expectedDeclarationPrefix: String
    public var insertion: String
    public var functionKeys: [Core.FunctionKey]

    public init(
        utf8Offset: Int,
        expectedDeclarationPrefix: String,
        insertion: String = "dynamic ",
        functionKeys: [Core.FunctionKey]
    ) {
        self.utf8Offset = utf8Offset
        self.expectedDeclarationPrefix = expectedDeclarationPrefix
        self.insertion = insertion
        self.functionKeys = functionKeys.sorted { $0.description < $1.description }
    }

    public init(
        utf8Offset: Int,
        expectedDeclarationPrefix: String,
        insertion: String = "dynamic ",
        functionKey: Core.FunctionKey
    ) {
        self.init(
            utf8Offset: utf8Offset,
            expectedDeclarationPrefix: expectedDeclarationPrefix,
            insertion: insertion,
            functionKeys: [functionKey]
        )
    }
}

public struct Result: Sendable {
    public var logicalPath: String
    public var contents: Data
    public var originalHash: Core.Digest
    public var transformedHash: Core.Digest
    public var appliedFunctionKeys: [Core.FunctionKey]
}

public struct Transformer: Sendable {
    public init() {}

    public func transform(
        source: Data,
        logicalPath: String,
        expectedSourceHash: Core.Digest,
        edits: [SourceTransform.Edit],
        supplementalDeclarations: String = ""
    ) throws -> SourceTransform.Result {
        guard Core.Digest.sha256(source) == expectedSourceHash else {
            throw SourceTransform.Error.sourceChanged
        }
        guard !logicalPath.isEmpty, !logicalPath.hasPrefix("/"),
              !logicalPath.split(separator: "/").contains("..")
        else {
            throw SourceTransform.Error.invalidLogicalPath
        }
        guard String(data: source, encoding: .utf8) != nil else {
            throw SourceTransform.Error.invalidUTF8
        }
        guard supplementalDeclarations.utf8.count <= 16 * 1_024 * 1_024,
              !supplementalDeclarations.unicodeScalars.contains(where: {
                  $0.value == 0
              })
        else {
            throw SourceTransform.Error.invalidSupplementalDeclarations
        }
        let sorted = edits.sorted { $0.utf8Offset < $1.utf8Offset }
        let allFunctionKeys = sorted.flatMap(\.functionKeys)
        guard sorted.allSatisfy({
                  !$0.functionKeys.isEmpty
                      && $0.functionKeys == $0.functionKeys.sorted(by: {
                          $0.description < $1.description
                      })
                      && Set($0.functionKeys).count == $0.functionKeys.count
              }),
              Set(allFunctionKeys).count == allFunctionKeys.count
        else {
            throw SourceTransform.Error.duplicateFunction
        }
        var lastOffset = -1
        for edit in sorted {
            guard edit.utf8Offset >= 0, edit.utf8Offset <= source.count,
                  edit.utf8Offset > lastOffset, !edit.insertion.isEmpty
            else {
                throw SourceTransform.Error.invalidEditOffset(edit.utf8Offset)
            }
            let prefix = Data(edit.expectedDeclarationPrefix.utf8)
            guard edit.utf8Offset <= source.count - min(prefix.count, source.count),
                  source[edit.utf8Offset...].starts(with: prefix)
            else {
                throw SourceTransform.Error.declarationMismatch(edit.functionKeys[0])
            }
            lastOffset = edit.utf8Offset
        }

        var transformed = source
        for edit in sorted.reversed() {
            transformed.insert(contentsOf: edit.insertion.utf8, at: edit.utf8Offset)
        }
        let prologue = Data("#sourceLocation(file: \(String(reflecting: logicalPath)), line: 1)\n".utf8)
        let epilogue = Data("\n#sourceLocation()\n".utf8)
        transformed.insert(contentsOf: prologue, at: 0)
        if !supplementalDeclarations.isEmpty {
            transformed.append(contentsOf: "\n".utf8)
            transformed.append(contentsOf: supplementalDeclarations.utf8)
            transformed.append(contentsOf: "\n".utf8)
        }
        transformed.append(epilogue)
        guard String(data: transformed, encoding: .utf8) != nil else {
            throw SourceTransform.Error.invalidUTF8
        }
        return .init(
            logicalPath: logicalPath,
            contents: transformed,
            originalHash: expectedSourceHash,
            transformedHash: .sha256(transformed),
            appliedFunctionKeys: allFunctionKeys
        )
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case sourceChanged
    case invalidLogicalPath
    case invalidUTF8
    case invalidSupplementalDeclarations
    case duplicateFunction
    case invalidEditOffset(Int)
    case declarationMismatch(Core.FunctionKey)

    public var description: String {
        switch self {
        case .sourceChanged: "source bytes differ from the indexed baseline"
        case .invalidLogicalPath: "source logical path is absolute or traversing"
        case .invalidUTF8: "Swift source is not valid UTF-8"
        case .invalidSupplementalDeclarations:
            "supplemental Swift declarations are oversized or contain NUL"
        case .duplicateFunction: "a function has more than one transform edit"
        case let .invalidEditOffset(value): "invalid or duplicate UTF-8 edit offset \(value)"
        case let .declarationMismatch(key): "declaration bytes no longer match function \(key)"
        }
    }
}
}
