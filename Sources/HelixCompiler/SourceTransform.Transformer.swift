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

/// Replaces an exact UTF-8 source range while binding the operation to the
/// indexed bytes. A declaration-body replacement can restore the following
/// logical line from inside its final brace, where Swift permits line control.
public struct Replacement: Hashable, Sendable {
    public var utf8Range: Range<Int>
    public var expectedContentHash: Core.Digest
    public var replacement: String
    public var functionKeys: [Core.FunctionKey]
    public var restoresSourceLocationBeforeFinalBrace: Bool

    public init(
        utf8Range: Range<Int>,
        expectedContentHash: Core.Digest,
        replacement: String,
        functionKeys: [Core.FunctionKey],
        restoresSourceLocationBeforeFinalBrace: Bool = false
    ) {
        self.utf8Range = utf8Range
        self.expectedContentHash = expectedContentHash
        self.replacement = replacement
        self.functionKeys = functionKeys.sorted { $0.description < $1.description }
        self.restoresSourceLocationBeforeFinalBrace =
            restoresSourceLocationBeforeFinalBrace
    }

    public init(
        utf8Range: Range<Int>,
        expectedContentHash: Core.Digest,
        replacement: String,
        functionKey: Core.FunctionKey,
        restoresSourceLocationBeforeFinalBrace: Bool = false
    ) {
        self.init(
            utf8Range: utf8Range,
            expectedContentHash: expectedContentHash,
            replacement: replacement,
            functionKeys: [functionKey],
            restoresSourceLocationBeforeFinalBrace:
                restoresSourceLocationBeforeFinalBrace
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
        replacements: [SourceTransform.Replacement] = [],
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
        let sortedEdits = edits.sorted { $0.utf8Offset < $1.utf8Offset }
        let sortedReplacements = replacements.sorted {
            $0.utf8Range.lowerBound < $1.utf8Range.lowerBound
        }
        let allFunctionKeys = sortedEdits.flatMap(\.functionKeys)
            + sortedReplacements.flatMap(\.functionKeys)
        guard sortedEdits.allSatisfy({
                  !$0.functionKeys.isEmpty
                      && $0.functionKeys == $0.functionKeys.sorted(by: {
                          $0.description < $1.description
                      })
                      && Set($0.functionKeys).count == $0.functionKeys.count
              }), sortedReplacements.allSatisfy({
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
        guard sortedReplacements.allSatisfy({
            !$0.replacement.isEmpty
                && $0.replacement.utf8.count <= 16 * 1_024 * 1_024
                && !$0.replacement.unicodeScalars.contains(where: { $0.value == 0 })
                && (!$0.restoresSourceLocationBeforeFinalBrace
                    || $0.replacement.utf8.last == UInt8(ascii: "}"))
        }) else {
            throw SourceTransform.Error.invalidReplacementContent
        }
        var lastOffset = -1
        for edit in sortedEdits {
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
        var lastUpperBound = -1
        var editIndex = 0
        for replacement in sortedReplacements {
            let range = replacement.utf8Range
            guard range.lowerBound >= 0,
                  range.lowerBound < range.upperBound,
                  range.upperBound <= source.count,
                  range.lowerBound >= lastUpperBound
            else {
                throw SourceTransform.Error.invalidReplacementRange(range)
            }
            let content = source.subdata(in: range)
            guard Core.Digest.sha256(content) == replacement.expectedContentHash else {
                throw SourceTransform.Error.replacementMismatch(
                    replacement.functionKeys[0]
                )
            }
            while editIndex < sortedEdits.count,
                  sortedEdits[editIndex].utf8Offset < range.lowerBound {
                editIndex += 1
            }
            guard editIndex == sortedEdits.count
                    || sortedEdits[editIndex].utf8Offset > range.upperBound
            else {
                throw SourceTransform.Error.invalidReplacementRange(range)
            }
            lastUpperBound = range.upperBound
        }

        var transformed = source
        var continuationLineByOffset: [Int: Int] = [:]
        var scannedOffset = 0
        var logicalLine = 1
        for replacement in sortedReplacements {
            for byte in source[scannedOffset..<replacement.utf8Range.upperBound]
            where byte == UInt8(ascii: "\n") {
                logicalLine += 1
            }
            continuationLineByOffset[replacement.utf8Range.lowerBound] = logicalLine
            scannedOffset = replacement.utf8Range.upperBound
        }
        enum Operation {
            case insertion(SourceTransform.Edit)
            case replacement(SourceTransform.Replacement)

            var offset: Int {
                switch self {
                case let .insertion(edit): edit.utf8Offset
                case let .replacement(replacement): replacement.utf8Range.lowerBound
                }
            }
        }
        let operations = (
            sortedEdits.map(Operation.insertion)
                + sortedReplacements.map(Operation.replacement)
        ).sorted { $0.offset > $1.offset }
        for operation in operations {
            switch operation {
            case let .insertion(edit):
                transformed.insert(contentsOf: edit.insertion.utf8, at: edit.utf8Offset)
            case let .replacement(replacement):
                guard let logicalLine = continuationLineByOffset[
                    replacement.utf8Range.lowerBound
                ] else {
                    throw SourceTransform.Error.invalidReplacementRange(
                        replacement.utf8Range
                    )
                }
                let restore = "#sourceLocation(file: "
                    + String(reflecting: logicalPath)
                    + ", line: \(logicalLine))\n"
                let rendered: String
                if replacement.restoresSourceLocationBeforeFinalBrace {
                    rendered = String(replacement.replacement.dropLast())
                        + "\n" + restore + "}"
                } else {
                    rendered = replacement.replacement
                }
                transformed.replaceSubrange(
                    replacement.utf8Range,
                    with: Data(rendered.utf8)
                )
            }
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
    case invalidReplacementRange(Range<Int>)
    case invalidReplacementContent
    case declarationMismatch(Core.FunctionKey)
    case replacementMismatch(Core.FunctionKey)

    public var description: String {
        switch self {
        case .sourceChanged: "source bytes differ from the indexed baseline"
        case .invalidLogicalPath: "source logical path is absolute or traversing"
        case .invalidUTF8: "Swift source is not valid UTF-8"
        case .invalidSupplementalDeclarations:
            "supplemental Swift declarations are oversized or contain NUL"
        case .duplicateFunction: "a function has more than one transform edit"
        case let .invalidEditOffset(value): "invalid or duplicate UTF-8 edit offset \(value)"
        case let .invalidReplacementRange(range):
            "invalid or overlapping UTF-8 replacement range \(range)"
        case .invalidReplacementContent:
            "replacement Swift source is empty, oversized, malformed, or contains NUL"
        case let .declarationMismatch(key): "declaration bytes no longer match function \(key)"
        case let .replacementMismatch(key):
            "source body bytes no longer match function \(key)"
        }
    }
}
}
