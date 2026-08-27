import Foundation
import HelixBytecode
import HelixCore

extension CanonicalSIL {
/// Proves where Clang Importer representation glue may remain in the logical
/// HLBC type system. The plan is consumer-rooted: a physical Objective-C value
/// keeps its source-level Swift type only when an exact NativeImport descriptor
/// supplies that type and the value traces to compiler-emitted bridge glue.
enum ForeignRepresentation {}
}

extension CanonicalSIL.ForeignRepresentation {
    /// Swift emits these Foundation bridges around imported Objective-C APIs.
    /// HLBC calls a Swift-typed NativeImport instead, so lowering preserves the
    /// logical value while validating the exact compiler bridge signature.
    enum ObjectiveCBridgeIntrinsic: Equatable {
        enum CollectionKind: Equatable {
            case array
            case dictionary
            case set
        }

        case stringToObjectiveC
        case stringFromObjectiveC
        case arrayToObjectiveC
        case arrayFromObjectiveC
        case dictionaryToObjectiveC
        case dictionaryFromObjectiveC
        case setToObjectiveC
        case setFromObjectiveC
        case nativeValueToObjectiveC

        init?(mangledName: String, loweredType: String) {
            switch mangledName {
            case "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF":
                self = .stringToObjectiveC
            case "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ":
                self = .stringFromObjectiveC
            case "$sSa10FoundationE19_bridgeToObjectiveCSo7NSArrayCyF":
                self = .arrayToObjectiveC
            case "$sSa10FoundationE36_unconditionallyBridgeFromObjectiveCySayxGSo7NSArrayCSgFZ":
                self = .arrayFromObjectiveC
            case "$sSD10FoundationE19_bridgeToObjectiveCSo12NSDictionaryCyF":
                self = .dictionaryToObjectiveC
            case "$sSD10FoundationE36_unconditionallyBridgeFromObjectiveCySDyxq_GSo12NSDictionaryCSgFZ":
                self = .dictionaryFromObjectiveC
            case "$sSh10FoundationE19_bridgeToObjectiveCSo5NSSetCyF":
                self = .setToObjectiveC
            case "$sSh10FoundationE36_unconditionallyBridgeFromObjectiveCyShyxGSo5NSSetCSgFZ":
                self = .setFromObjectiveC
            default:
                guard mangledName.hasPrefix("$s10Foundation"),
                      mangledName.contains("19_bridgeToObjectiveC")
                else { return nil }
                self = .nativeValueToObjectiveC
            }
            guard accepts(loweredType: loweredType) else { return nil }
        }

        func accepts(loweredType: String) -> Bool {
            let normalized = loweredType
                .replacingOccurrences(of: "Swift.", with: "")
                .filter { !$0.isWhitespace }
            return switch self {
            case .stringToObjectiveC:
                normalized
                    == "@convention(method)(@guaranteedString)->@ownedNSString"
            case .stringFromObjectiveC:
                normalized
                    == "@convention(method)(@guaranteedOptional<NSString>,@thinString.Type)->@ownedString"
            case .arrayToObjectiveC:
                normalized.hasPrefix("@convention(method)<τ_0_0>")
                    && normalized.hasSuffix("(@guaranteedArray<τ_0_0>)->@ownedNSArray")
            case .arrayFromObjectiveC:
                normalized.hasPrefix("@convention(method)<τ_0_0>")
                    && normalized.hasSuffix(
                        "(@guaranteedOptional<NSArray>,@thinArray<τ_0_0>.Type)->@ownedArray<τ_0_0>"
                    )
            case .dictionaryToObjectiveC:
                normalized.hasPrefix(
                    "@convention(method)<τ_0_0,τ_0_1whereτ_0_0:Hashable>"
                ) && normalized.hasSuffix(
                    "(@guaranteedDictionary<τ_0_0,τ_0_1>)->@ownedNSDictionary"
                )
            case .dictionaryFromObjectiveC:
                normalized.hasPrefix(
                    "@convention(method)<τ_0_0,τ_0_1whereτ_0_0:Hashable>"
                ) && normalized.hasSuffix(
                    "(@guaranteedOptional<NSDictionary>,@thinDictionary<τ_0_0,τ_0_1>.Type)->@ownedDictionary<τ_0_0,τ_0_1>"
                )
            case .setToObjectiveC:
                normalized.hasPrefix(
                    "@convention(method)<τ_0_0whereτ_0_0:Hashable>"
                ) && normalized.hasSuffix(
                    "(@guaranteedSet<τ_0_0>)->@ownedNSSet"
                )
            case .setFromObjectiveC:
                normalized.hasPrefix(
                    "@convention(method)<τ_0_0whereτ_0_0:Hashable>"
                ) && normalized.hasSuffix(
                    "(@guaranteedOptional<NSSet>,@thinSet<τ_0_0>.Type)->@ownedSet<τ_0_0>"
                )
            case .nativeValueToObjectiveC:
                Self.acceptsNativeValueToObjectiveC(normalized)
            }
        }

        func preserves(logicalType: Bytecode.ValueType) -> Bool {
            switch self {
            case .stringToObjectiveC, .stringFromObjectiveC:
                logicalType == .string
            case .arrayToObjectiveC, .arrayFromObjectiveC:
                if case .array = logicalType { true } else { false }
            case .dictionaryToObjectiveC, .dictionaryFromObjectiveC:
                if case .dictionary = logicalType { true } else { false }
            case .setToObjectiveC, .setFromObjectiveC:
                if case .set = logicalType { true } else { false }
            case .nativeValueToObjectiveC:
                if case .native = logicalType { true } else { false }
            }
        }

        var collectionKind: CollectionKind? {
            switch self {
            case .arrayToObjectiveC, .arrayFromObjectiveC:
                .array
            case .dictionaryToObjectiveC, .dictionaryFromObjectiveC:
                .dictionary
            case .setToObjectiveC, .setFromObjectiveC:
                .set
            case .stringToObjectiveC, .stringFromObjectiveC,
                 .nativeValueToObjectiveC:
                nil
            }
        }

        var isCollectionBridgeFromObjectiveC: Bool {
            switch self {
            case .arrayFromObjectiveC, .dictionaryFromObjectiveC,
                 .setFromObjectiveC:
                true
            case .stringToObjectiveC, .stringFromObjectiveC,
                 .arrayToObjectiveC, .dictionaryToObjectiveC,
                 .setToObjectiveC, .nativeValueToObjectiveC:
                false
            }
        }

        private static func acceptsNativeValueToObjectiveC(
            _ normalized: String
        ) -> Bool {
            guard normalized.utf8.count <= 8_192 else { return false }
            let convention = "@convention(method)"
            let ownershipPrefixes = [
                "(@in_guaranteed", "(@guaranteed",
            ]
            guard let ownership = ownershipPrefixes.compactMap({ prefix in
                normalized.range(of: prefix).map { (prefix, $0) }
            }).min(by: { $0.1.lowerBound < $1.1.lowerBound })
            else { return false }
            let functionPrefix = normalized[..<ownership.1.lowerBound]
            guard functionPrefix == convention
                    || functionPrefix.hasPrefix(convention + "<")
                        && functionPrefix.hasSuffix(">")
                        && hasBalancedAngles(
                            functionPrefix.dropFirst(convention.count)
                        )
            else { return false }
            let separator = ")->@owned"
            guard let separatorRange = normalized.range(
                of: separator,
                options: .backwards
            ),
                  separatorRange.upperBound < normalized.endIndex
            else { return false }
            let sourceStart = ownership.1.upperBound
            let source = normalized[sourceStart..<separatorRange.lowerBound]
            let target = normalized[separatorRange.upperBound...]
            return isNominalTypeSpelling(source)
                && isNominalTypeSpelling(target)
        }

        private static func isNominalTypeSpelling(
            _ value: Substring
        ) -> Bool {
            !value.isEmpty
                && hasBalancedAngles(value)
                && value.allSatisfy {
                    $0 == "_" || $0 == "." || $0 == "," || $0 == ":"
                        || $0 == "&" || $0 == "?" || $0 == "<" || $0 == ">"
                        || $0.isLetter || $0.isNumber
                }
        }

        private static func hasBalancedAngles(
            _ value: Substring
        ) -> Bool {
            var depth = 0
            for character in value {
                if character == "<" {
                    depth += 1
                } else if character == ">" {
                    depth -= 1
                    if depth < 0 { return false }
                }
            }
            return depth == 0
        }
    }

    struct Plan: Sendable {
        static let empty = Self(logicalTypes: [:])

        var logicalTypes: [String: Bytecode.ValueType]

        func logicalType(for value: String) -> Bytecode.ValueType? {
            logicalTypes[value]
        }

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
            var blockParameters: [UInt32: [String]] = [:]
            var incomingValues: [String: [String]] = [:]
            var enumDefinitions: [
                String: (wrappedSpelling: String, payload: String?)
            ] = [:]
            var passthroughDefinitions: [String: String] = [:]
            var anyObjectBridgeReferences = Set<String>()
            var anyObjectBridgeResults = Set<String>()
            var anyObjectErasureResults = Set<String>()
            var objectiveCBridgeReferences: [
                String: ObjectiveCBridgeIntrinsic
            ] = [:]
            var objectiveCBridgeResults: [
                String: ObjectiveCBridgeIntrinsic
            ] = [:]
            var foreignReferences: [
                String: [CanonicalSIL.DirectCallBinding]
            ] = [:]
            var seedCandidates: [
                String: Set<Bytecode.ValueType>
            ] = [:]

            for line in lines {
                guard let header = captures(
                    line,
                    expression: Expressions.blockHeader
                ), let block = UInt32(header[0])
                else { continue }
                blockParameters[block] = valueTokens(in: header[1])
            }
            for (lineIndex, line) in lines.enumerated() {
                if captures(
                    line,
                    expression: Expressions.blockHeader
                ) != nil { continue }
                if let branch = captures(
                    line,
                    expression: Expressions.branch
                ), let target = UInt32(branch[0]),
                   let parameters = blockParameters[target] {
                    let arguments = valueTokens(in: branch[1])
                    guard arguments.count == parameters.count else {
                        continue
                    }
                    for (parameter, argument) in zip(parameters, arguments) {
                        incomingValues[parameter, default: []].append(argument)
                    }
                    continue
                }
                if let branch = captures(
                    line,
                    expression: Expressions.conditionalBranch
                ), let trueTarget = UInt32(branch[0]),
                   let falseTarget = UInt32(branch[2]) {
                    for (target, rawArguments) in [
                        (trueTarget, branch[1]),
                        (falseTarget, branch[3]),
                    ] {
                        guard let parameters = blockParameters[target] else {
                            continue
                        }
                        let arguments = valueTokens(in: rawArguments)
                        guard arguments.count == parameters.count else {
                            continue
                        }
                        for (parameter, argument) in zip(
                            parameters,
                            arguments
                        ) {
                            incomingValues[parameter, default: []].append(
                                argument
                            )
                        }
                    }
                    continue
                }
                if let enumeration = captures(
                    line,
                    expression: Expressions.optionalEnumeration
                ) {
                    enumDefinitions[enumeration[0]] = (
                        wrappedSpelling: enumeration[1],
                        payload: enumeration[2] == "some"
                            ? enumeration[3] : nil
                    )
                    continue
                }
                if let passthrough = captures(
                    line,
                    expression: Expressions.passthrough
                ) {
                    passthroughDefinitions[passthrough[0]] = passthrough[1]
                    continue
                }
                if let erasure = captures(
                    line,
                    expression: Expressions.anyObjectErasure
                ) {
                    anyObjectErasureResults.insert(erasure[0])
                    continue
                }
                if let reference = captures(
                    line,
                    expression: Expressions.functionReference
                ) {
                    if CanonicalSIL.AnyObjectBridge.isReferenceInstruction(
                        line
                    ) {
                        anyObjectBridgeReferences.insert(reference[0])
                        continue
                    }
                    if let intrinsic = ObjectiveCBridgeIntrinsic(
                        mangledName: reference[1],
                        loweredType: reference[2]
                    ) {
                        objectiveCBridgeReferences[reference[0]] = intrinsic
                        continue
                    }
                }
                if let reference = captures(
                    line,
                    expression: Expressions.foreignMethodReference
                ), reference[2].hasSuffix("foreign"),
                   !reference[3].contains("@pseudogeneric"),
                   !reference[3].contains("τ_") {
                    let dispatch: CanonicalSIL.NativeBridgeSymbols
                        .ForeignDispatch = reference[1] == "objc_super_method"
                            ? .superclass : .ordinary
                    let rawSymbol = CanonicalSIL.NativeBridgeSymbols
                        .foreignCall(
                            reference: reference[2],
                            loweredType: reference[3],
                            dispatch: dispatch
                        )
                    let exactSymbol = directCalls.resolvedForeignSymbol(
                        rawSymbol,
                        at: function.sourceLocation(
                            atBodyLine: lineIndex + 1
                        )
                    )
                    let symbol = directCalls.hasBinding(for: reference[2])
                        ? reference[2] : exactSymbol
                    foreignReferences[reference[0]] = directCalls
                        .bindings(for: symbol)
                        .filter {
                            if case .nativeImport = $0.target { return true }
                            return false
                        }
                    continue
                }
                guard let application = captures(
                    line,
                    expression: Expressions.application
                ) else { continue }
                if anyObjectBridgeReferences.contains(application[1]) {
                    anyObjectBridgeResults.insert(application[0])
                    continue
                }
                if let intrinsic = objectiveCBridgeReferences[application[1]] {
                    objectiveCBridgeResults[application[0]] = intrinsic
                    continue
                }
                guard let bindings = foreignReferences[application[1]],
                      !bindings.isEmpty
                else { continue }
                let arguments = valueTokens(in: application[2])
                for binding in bindings
                where Int(binding.parameterProjection.physicalParameterCount)
                    == arguments.count {
                    for (logicalIndex, physicalIndex) in binding
                        .parameterProjection.logicalParameterIndices.enumerated() {
                        let physicalIndex = Int(physicalIndex)
                        guard arguments.indices.contains(physicalIndex),
                              binding.parameterTypes.indices.contains(logicalIndex),
                              isForeignBridgeType(
                                  binding.parameterTypes[logicalIndex]
                              )
                        else { continue }
                        seedCandidates[
                            arguments[physicalIndex],
                            default: []
                        ].insert(binding.parameterTypes[logicalIndex])
                    }
                }
            }

            var logicalTypes: [String: Bytecode.ValueType] = [:]
            for seed in seedCandidates.keys.sorted() {
                guard let candidates = seedCandidates[seed],
                      candidates.count == 1
                else { continue }
                guard let expected = candidates.first else { continue }
                var proposed: [String: Bytecode.ValueType] = [:]
                var worklist: [(String, Bytecode.ValueType)] = [
                    (seed, expected),
                ]
                var terminalCount = 0
                var isValid = true
                while let (value, type) = worklist.popLast(), isValid {
                    if let existing = proposed[value] {
                        isValid = existing == type
                        continue
                    }
                    proposed[value] = type
                    if anyObjectBridgeResults.contains(value)
                        || anyObjectErasureResults.contains(value) {
                        isValid = type == .any
                        terminalCount += isValid ? 1 : 0
                        continue
                    }
                    if let intrinsic = objectiveCBridgeResults[value] {
                        isValid = intrinsic.preserves(logicalType: type)
                        terminalCount += isValid ? 1 : 0
                        continue
                    }
                    if let definition = enumDefinitions[value] {
                        guard case let .optional(wrapped) = type else {
                            isValid = false
                            continue
                        }
                        if let payload = definition.payload {
                            worklist.append((payload, wrapped))
                        } else {
                            terminalCount += 1
                        }
                        continue
                    }
                    if let source = passthroughDefinitions[value] {
                        worklist.append((source, type))
                        continue
                    }
                    if let incoming = incomingValues[value], !incoming.isEmpty {
                        worklist.append(contentsOf: incoming.map { ($0, type) })
                        continue
                    }
                    isValid = false
                }
                guard isValid, terminalCount > 0,
                      proposed.allSatisfy({ value, type in
                          logicalTypes[value].map { $0 == type } ?? true
                      })
                else { continue }
                logicalTypes.merge(proposed) { current, _ in current }
            }
            return .init(logicalTypes: logicalTypes)
        }

        private static func isForeignBridgeType(
            _ type: Bytecode.ValueType
        ) -> Bool {
            switch type {
            case .any, .string, .error, .array, .dictionary, .set, .native:
                return true
            case let .optional(wrapped):
                return isForeignBridgeType(wrapped)
            default:
                return false
            }
        }

        private static func valueTokens(in text: String) -> [String] {
            let bytes = Array(text.utf8)
            var result: [String] = []
            var index = 0
            while index < bytes.count {
                guard bytes[index] == 0x25,
                      index + 1 < bytes.count,
                      (0x30...0x39).contains(bytes[index + 1])
                else {
                    index += 1
                    continue
                }
                var end = index + 2
                while end < bytes.count,
                      (0x30...0x39).contains(bytes[end]) {
                    end += 1
                }
                result.append(
                    String(decoding: bytes[index..<end], as: UTF8.self)
                )
                index = end
            }
            return result
        }

        private static func captures(
            _ text: String,
            expression: NSRegularExpression
        ) -> [String]? {
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(
                      in: text,
                      range: fullRange
                  ), match.range == fullRange
            else { return nil }
            return (1..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text)
                else { return "" }
                return String(text[range])
            }
        }

        private enum Expressions {
            static let blockHeader = compile(
                #"^bb([0-9]+)(?:\((.*)\))?:$"#
            )
            static let branch = compile(
                #"^br bb([0-9]+)(?:\((.*)\))?$"#
            )
            static let conditionalBranch = compile(
                #"^cond_br %[0-9]+, bb([0-9]+)(?:\((.*?)\))?, bb([0-9]+)(?:\((.*?)\))?$"#
            )
            static let optionalEnumeration = compile(
                #"^(%[0-9]+) = enum \$Optional<(.+)>, #Optional\.(some|none)!enumelt(?:, (%[0-9]+))?$"#
            )
            static let passthrough = compile(
                #"^(%[0-9]+) = (?:copy_value|move_value|begin_borrow) (%[0-9]+)$"#
            )
            static let anyObjectErasure = compile(
                #"^(%[0-9]+) = init_existential_ref %[0-9]+ : \$.+ : \$.+, \$(?:Swift\.)?AnyObject$"#
            )
            static let functionReference = compile(
                #"^(%[0-9]+) = function_ref @([^\s]+) : \$(.+)$"#
            )
            static let foreignMethodReference = compile(
                #"^(%[0-9]+) = ((?:objc|objc_super|class)_method) .*, (#[^\s:]+) : .*, \$(.+)$"#
            )
            static let application = compile(
                #"^(%[0-9]+) = apply (%[0-9]+)(?:<.*>)?\((.*)\) : \$.+$"#
            )

            private static func compile(
                _ pattern: String
            ) -> NSRegularExpression {
                // These literals are compiler invariants and fail during
                // process initialization if an edit makes one invalid.
                try! NSRegularExpression(pattern: pattern)
            }
        }
    }
}
