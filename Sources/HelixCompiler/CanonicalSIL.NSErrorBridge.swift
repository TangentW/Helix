import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
/// A fail-closed description of Clang Importer's `NSError **` thunk around a
/// Swift-throwing Objective-C method. The physical pointer and sentinel values
/// are compiler details; HLBC consumes the frozen logical throwing ABI.
struct NSErrorBridgePlan: Sendable {
    struct Call: Sendable {
        var binding: CanonicalSIL.DirectCallBinding
        var argumentTokens: [String]
        var normalTarget: Bytecode.BlockID
        var errorTarget: Bytecode.BlockID
    }

    var callsByLine: [Int: Call] = [:]
    var skippedLines = Set<Int>()
    var replacementLines: [Int: String] = [:]

    static func analyze(
        body: String,
        function: CanonicalSIL.Function,
        directCalls: CanonicalSIL.DirectCallTable
    ) throws -> Self {
        let lines = body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map {
            CanonicalSIL.DebugMetadata.strippingComment(from: String($0))
                .trimmingCharacters(in: .whitespaces)
        }
        var blockHeaders: [UInt32: Int] = [:]
        for (index, line) in lines.enumerated() {
            guard let captures = captures(
                line,
                pattern: #"^bb([0-9]+)(?:\(.*\))?:$"#
            ), let number = UInt32(captures[0]) else { continue }
            guard blockHeaders.updateValue(index, forKey: number) == nil else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError bridge function contains a duplicate block identifier"
                )
            }
        }
        var result = Self()

        for (referenceLine, line) in lines.enumerated() {
            guard !result.skippedLines.contains(referenceLine),
                  let reference = captures(
                      line,
                      pattern: #"^(%[0-9]+) = ((?:objc|objc_super|class)_method) .*, (#[^\s:]+) : .*, \$(.+)$"#
                  ),
                  reference[2].hasSuffix("!foreign"),
                  reference[3].contains("AutoreleasingUnsafeMutablePointer<Optional<NSError>>"),
                  reference[3].contains("-> ObjCBool")
            else { continue }
            let rawSymbol = CanonicalSIL.NativeBridgeSymbols.foreignCall(
                reference: reference[2],
                loweredType: reference[3],
                dispatch: reference[1] == "objc_super_method"
                    ? .superclass : .ordinary
            )
            let symbol = directCalls.resolvedForeignSymbol(
                rawSymbol,
                at: function.sourceLocation(atBodyLine: referenceLine + 1)
            )
            guard let binding = directCalls.binding(for: symbol),
                  binding.effects.mayThrow,
                  !binding.effects.isAsync,
                  binding.resultType == .void,
                  case let .nativeImport(requirement) = binding.target,
                  requirement.contract.kind == .instanceMethod,
                  binding.abiAdapter == .direct,
                  !binding.parameterTypes.isEmpty
            else { continue }

            let blockEnd = nextBlock(after: referenceLine, in: lines) ?? lines.count
            let applyPattern = #"^(%[0-9]+) = apply "#
                + NSRegularExpression.escapedPattern(for: reference[0])
                + #"\((.*)\) : \$(.+)$"#
            let applications = ((referenceLine + 1)..<blockEnd).compactMap {
                index -> (Int, [String])? in
                guard let call = captures(lines[index], pattern: applyPattern),
                      call[2] == reference[3]
                else { return nil }
                return (index, [call[0], call[1]])
            }
            guard applications.count == 1, let application = applications.first else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError bridge has no unique Objective-C apply"
                )
            }
            let physicalArguments = valueTokens(in: application.1[1])
            let logicalCount = binding.parameterTypes.count
            guard physicalArguments.count == logicalCount + 1 else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError bridge has an unexpected hidden-parameter count"
                )
            }
            let logicalArguments = Array(physicalArguments.prefix(logicalCount - 1))
                + [physicalArguments.last!]
            let hiddenArgument = physicalArguments[logicalCount - 1]

            guard let branch = sentinelBranch(
                callResult: application.1[0],
                after: application.0,
                before: blockEnd,
                lines: lines
            ),
                  let normalHeader = blockHeaders[branch.normal],
                  let errorHeader = blockHeaders[branch.error],
                  lines[normalHeader] == "bb\(branch.normal):",
                  lines[errorHeader] == "bb\(branch.error):"
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError bridge has an unsupported success/error branch"
                )
            }
            let errorEnd = nextBlock(after: errorHeader, in: lines) ?? lines.count
            guard let conversion = convertedError(
                after: errorHeader,
                before: errorEnd,
                lines: lines
            ) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError bridge has no canonical Error conversion"
                )
            }

            var skipped = Set([referenceLine])
            var scaffoldTokens = try dependencySlice(
                rootedAt: hiddenArgument,
                before: application.0,
                lines: lines,
                skippedLines: &skipped
            )
            scaffoldTokens.insert(hiddenArgument)
            var discoveredScaffold = true
            while discoveredScaffold {
                discoveredScaffold = false
                for index in 0..<application.0 where index != referenceLine {
                    let operands = Set(valueTokens(in: lines[index]))
                    guard !operands.isDisjoint(with: scaffoldTokens),
                          isScaffoldInstruction(lines[index])
                    else { continue }
                    skipped.insert(index)
                    let related = operands.union(definitionTokens(in: lines[index]))
                    let previousCount = scaffoldTokens.count
                    scaffoldTokens.formUnion(related)
                    discoveredScaffold = discoveredScaffold
                        || scaffoldTokens.count != previousCount
                }
            }
            var physicalRegionTokens = scaffoldTokens
            physicalRegionTokens.formUnion(physicalArguments)
            physicalRegionTokens.insert(application.1[0])
            if application.0 + 1 <= branch.line {
                for index in (application.0 + 1)...branch.line {
                    if branch.structuralLines.contains(index) {
                        skipped.insert(index)
                        continue
                    }
                    if lines[index].isEmpty {
                        skipped.insert(index)
                        continue
                    }
                    let definitions = definitionTokens(in: lines[index])
                    let uses = Set(valueTokens(in: lines[index])).subtracting(definitions)
                    guard isScaffoldCleanup(lines[index]),
                          !uses.isEmpty,
                          uses.isSubset(of: physicalRegionTokens)
                    else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "NSError bridge post-call region contains an unexpected instruction"
                        )
                    }
                    if !uses.isDisjoint(with: scaffoldTokens) {
                        scaffoldTokens.formUnion(definitions)
                    }
                    physicalRegionTokens.formUnion(definitions)
                    skipped.insert(index)
                }
            }

            for index in (errorHeader + 1)...conversion.line {
                let instruction = lines[index]
                if instruction.isEmpty {
                    skipped.insert(index)
                    continue
                }
                if index == conversion.referenceLine || index == conversion.line {
                    skipped.insert(index)
                    continue
                }
                let definitions = definitionTokens(in: instruction)
                let uses = Set(valueTokens(in: instruction)).subtracting(definitions)
                guard isScaffoldInstruction(instruction),
                      !uses.isEmpty,
                      uses.isSubset(of: scaffoldTokens) else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "NSError bridge conversion contains an unexpected instruction"
                    )
                }
                scaffoldTokens.formUnion(definitions)
                skipped.insert(index)
            }
            let conversionUses = Set(
                valueTokens(in: lines[conversion.line])
            ).subtracting(
                definitionTokens(in: lines[conversion.line])
            ).subtracting([conversion.converterToken])
            guard !conversionUses.isEmpty,
                  conversionUses.isSubset(of: scaffoldTokens)
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError conversion does not consume only compiler error state"
                )
            }
            scaffoldTokens.remove(conversion.errorToken)

            for header in [normalHeader, errorHeader] {
                let end = nextBlock(after: header, in: lines) ?? lines.count
                guard header + 1 < end else { continue }
                for index in (header + 1)..<end {
                    let definitions = definitionTokens(in: lines[index])
                    let uses = Set(valueTokens(in: lines[index]))
                        .subtracting(definitions)
                    if index > conversion.line,
                       captures(
                           lines[index],
                           pattern: #"^%[0-9]+ = builtin \"willThrow\"\((%[0-9]+)\) : \$\(\)$"#
                       ) == [conversion.errorToken] {
                        skipped.insert(index)
                        continue
                    }
                    if !uses.isDisjoint(with: scaffoldTokens),
                       isScaffoldCleanup(lines[index]),
                       uses.isSubset(of: scaffoldTokens) {
                        skipped.insert(index)
                        scaffoldTokens.formUnion(definitions)
                    }
                }
            }

            for (index, instruction) in lines.enumerated()
            where index != application.0
                && index != errorHeader
                && !skipped.contains(index)
                && !Set(valueTokens(in: instruction)).isDisjoint(with: scaffoldTokens) {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError bridge compiler state escapes its logical call boundary"
                )
            }

            guard result.callsByLine[application.0] == nil,
                  result.replacementLines[errorHeader] == nil,
                  result.skippedLines.isDisjoint(with: skipped)
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError bridge regions overlap"
                )
            }
            result.callsByLine[application.0] = .init(
                binding: binding,
                argumentTokens: logicalArguments,
                normalTarget: .init(rawValue: branch.normal),
                errorTarget: .init(rawValue: branch.error)
            )
            result.replacementLines[errorHeader] = "bb\(branch.error)("
                + "\(conversion.errorToken) : @owned $any Error):"
            result.skippedLines.formUnion(skipped)
        }
        return result
    }

    private static func sentinelBranch(
        callResult: String,
        after start: Int,
        before end: Int,
        lines: [String]
    ) -> (
        line: Int,
        normal: UInt32,
        error: UInt32,
        structuralLines: Set<Int>
    )? {
        var current = callResult
        var extractionIndex = 0
        var structuralLines = Set<Int>()
        let expectedFields = ["ObjCBool", "Bool"]
        for index in (start + 1)..<end {
            if let extraction = captures(
                lines[index],
                pattern: #"^(%[0-9]+) = struct_extract "#
                    + NSRegularExpression.escapedPattern(for: current)
                    + #", #(ObjCBool|Bool)\._value$"#
            ) {
                guard extractionIndex < expectedFields.count,
                      extraction[1] == expectedFields[extractionIndex]
                else { return nil }
                current = extraction[0]
                extractionIndex += 1
                structuralLines.insert(index)
                continue
            }
            if let branch = captures(
                lines[index],
                pattern: #"^cond_br "#
                    + NSRegularExpression.escapedPattern(for: current)
                    + #", bb([0-9]+), bb([0-9]+)$"#
            ), extractionIndex == expectedFields.count,
               let normal = UInt32(branch[0]), let error = UInt32(branch[1]),
               normal != error {
                structuralLines.insert(index)
                return (index, normal, error, structuralLines)
            }
        }
        return nil
    }

    private static func convertedError(
        after start: Int,
        before end: Int,
        lines: [String]
    ) -> (
        referenceLine: Int,
        line: Int,
        converterToken: String,
        errorToken: String
    )? {
        var converter: (line: Int, token: String)?
        for index in (start + 1)..<end {
            if lines[index].contains("convertNSErrorToError"),
               let reference = captures(
                   lines[index],
                   pattern: #"^(%[0-9]+) = (?:dynamic_)?function_ref @[^\s:]+ : \$.+$"#
               ) {
                guard converter == nil else { return nil }
                converter = (index, reference[0])
                continue
            }
            guard let converter,
                  let call = captures(
                      lines[index],
                      pattern: #"^(%[0-9]+) = apply "#
                        + NSRegularExpression.escapedPattern(for: converter.token)
                        + #"\(.*\) : \$.+$"#
                  )
            else { continue }
            return (converter.line, index, converter.token, call[0])
        }
        return nil
    }

    private static func dependencySlice(
        rootedAt root: String,
        before end: Int,
        lines: [String],
        skippedLines: inout Set<Int>
    ) throws -> Set<String> {
        var definitions: [String: Int] = [:]
        for index in 0..<end {
            for token in definitionTokens(in: lines[index]) {
                definitions[token] = index
            }
        }
        var tokens = Set([root])
        var pending = [root]
        while let token = pending.popLast(), let line = definitions[token] {
            guard isScaffoldInstruction(lines[line]) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "NSError bridge hidden argument has an unsupported producer"
                )
            }
            skippedLines.insert(line)
            let defined = definitionTokens(in: lines[line])
            for operand in valueTokens(in: lines[line]) where !defined.contains(operand) {
                if tokens.insert(operand).inserted { pending.append(operand) }
            }
        }
        return tokens
    }

    private static func isScaffoldInstruction(_ line: String) -> Bool {
        let instruction = instructionBody(line)
        return [
            "alloc_stack ", "inject_enum_addr ", "enum $Optional<",
            "struct $AutoreleasingUnsafeMutablePointer", "address_to_pointer ",
            "ref_to_unmanaged ", "unmanaged_to_ref ", "mark_dependence ",
            "load ", "store ", "assign ", "copy_value ", "begin_borrow ",
            "end_borrow ", "retain_value ", "release_value ", "strong_release ",
            "destroy_value ", "dealloc_stack ",
        ].contains { instruction.hasPrefix($0) }
    }

    private static func isScaffoldCleanup(_ line: String) -> Bool {
        let instruction = instructionBody(line)
        return [
            "load ", "store ", "assign ", "mark_dependence ",
            "retain_value ", "release_value ", "strong_release ", "destroy_value ",
            "dealloc_stack ", "ref_to_unmanaged ", "unmanaged_to_ref ",
        ].contains { instruction.hasPrefix($0) }
    }

    private static func instructionBody(_ line: String) -> Substring {
        guard let assignment = line.range(of: " = ") else { return line[...] }
        return line[assignment.upperBound...]
    }

    private static func nextBlock(after index: Int, in lines: [String]) -> Int? {
        guard index + 1 < lines.count else { return nil }
        return ((index + 1)..<lines.count).first {
            captures(lines[$0], pattern: #"^bb[0-9]+(?:\(.*\))?:$"#) != nil
        }
    }

    private static func definitionTokens(in line: String) -> Set<String> {
        guard let assignment = line.range(of: " = ") else { return [] }
        return Set(valueTokens(in: String(line[..<assignment.lowerBound])))
    }

    private static func valueTokens(in text: String) -> [String] {
        let bytes = Array(text.utf8)
        var result: [String] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "%"),
                  index + 1 < bytes.count,
                  isASCIIDigit(bytes[index + 1])
            else {
                index += 1
                continue
            }
            var end = index + 2
            while end < bytes.count, isASCIIDigit(bytes[end]) { end += 1 }
            result.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end
        }
        return result
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func captures(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ), match.range.location == 0,
              match.range.length == text.utf16.count
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
}
