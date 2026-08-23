import HelixBytecode

extension CanonicalSIL {
/// Closed standard-protocol evidence for Swift value families whose semantics
/// Helix already represents directly. This is deliberately narrower than the
/// Swift standard library: a similar HLBC storage shape is not conformance.
enum StandardConformance {
    static func associatedTypes(
        concrete raw: String,
        protocolName rawProtocol: String,
        representedType: Bytecode.ValueType? = nil
    ) -> [String: String]? {
        let concrete = CanonicalSIL.SwiftTypeIdentity.normalized(raw)
        let protocolName = normalizedProtocolName(rawProtocol)
        if let representedType,
            let evidence = representedValueEvidence(
                concrete: concrete,
                representedType: representedType,
                protocolName: protocolName
            )
        {
            return evidence
        }
        guard let shape = collectionShape(of: concrete, depth: 0) else {
            return nil
        }
        switch protocolName {
        case "Sequence" where shape.isSequence:
            return sequenceAssociatedTypes(element: shape.element)
        case "Collection" where shape.isCollection:
            return collectionAssociatedTypes(element: shape.element)
        case "BidirectionalCollection" where shape.isBidirectional:
            return collectionAssociatedTypes(element: shape.element)
        case "RandomAccessCollection" where shape.isRandomAccess:
            return collectionAssociatedTypes(element: shape.element)
        case "MutableCollection" where shape.isMutable:
            return collectionAssociatedTypes(element: shape.element)
        case "RangeReplaceableCollection" where shape.isRangeReplaceable:
            return collectionAssociatedTypes(element: shape.element)
        default:
            return nil
        }
    }

    private static func representedValueEvidence(
        concrete: String,
        representedType: Bytecode.ValueType,
        protocolName: String
    ) -> [String: String]? {
        switch protocolName {
        case "Equatable"
        where representedType.isVMEquatable
            && isStandardEquatableIdentity(concrete),
            "Hashable"
        where representedType.isVMHashable
            && isStandardHashableIdentity(concrete),
            "Comparable"
        where representedType.isVMComparable
            && isStandardComparableIdentity(concrete):
            return [:]

        case "AdditiveArithmetic":
            return isStandardNumber(
                concrete: concrete,
                representedType: representedType
            ) ? [:] : nil

        case "Numeric":
            return numericEvidence(
                concrete: concrete,
                representedType: representedType
            )

        case "SignedNumeric":
            guard
                isStandardSignedNumber(
                    concrete: concrete,
                    representedType: representedType
                )
            else { return nil }
            return numericEvidence(
                concrete: concrete,
                representedType: representedType
            )

        case "BinaryInteger"
        where isStandardInteger(
            concrete: concrete,
            representedType: representedType
        ),
            "FixedWidthInteger"
        where isStandardInteger(
            concrete: concrete,
            representedType: representedType
        ):
            return integerEvidence(
                concrete: concrete,
                representedType: representedType
            )

        case "SignedInteger"
        where isStandardSignedInteger(
            concrete: concrete,
            representedType: representedType
        ),
            "UnsignedInteger"
        where isStandardUnsignedInteger(
            concrete: concrete,
            representedType: representedType
        ):
            return integerEvidence(
                concrete: concrete,
                representedType: representedType
            )

        case "FloatingPoint", "BinaryFloatingPoint":
            guard
                isStandardFloat(
                    concrete: concrete,
                    representedType: representedType
                ),
                let integerLiteral = integerLiteralType(
                    concrete: concrete,
                    representedType: representedType
                ), let floatLiteral = floatLiteralType(concrete: concrete)
            else { return nil }
            return [
                "Magnitude": canonicalFloatIdentity(concrete),
                "Exponent": "Int",
                "IntegerLiteralType": integerLiteral,
                "FloatLiteralType": floatLiteral,
                "Stride": canonicalFloatIdentity(concrete),
            ]

        case "Strideable":
            return strideEvidence(
                concrete: concrete,
                representedType: representedType
            )

        case "CustomStringConvertible":
            return isRepresentedScalarDescription(
                concrete: concrete,
                representedType: representedType
            ) ? [:] : nil

        case "LosslessStringConvertible":
            return isRepresentedLosslessTextScalar(
                concrete: concrete,
                representedType: representedType
            ) ? [:] : nil

        case "ExpressibleByBooleanLiteral"
        where concrete == "Bool" && representedType == .bool:
            return ["BooleanLiteralType": "Bool"]

        case "ExpressibleByIntegerLiteral":
            guard
                let literal = integerLiteralType(
                    concrete: concrete,
                    representedType: representedType
                )
            else { return nil }
            return ["IntegerLiteralType": literal]

        case "ExpressibleByFloatLiteral":
            guard
                isStandardFloat(
                    concrete: concrete,
                    representedType: representedType
                ), let literal = floatLiteralType(concrete: concrete)
            else { return nil }
            return ["FloatLiteralType": literal]

        case "ExpressibleByStringLiteral" where concrete == "String":
            return ["StringLiteralType": "String"]

        case "ExpressibleByExtendedGraphemeClusterLiteral"
        where concrete == "String" || concrete == "Character":
            return ["ExtendedGraphemeClusterLiteralType": concrete]

        case "ExpressibleByUnicodeScalarLiteral"
        where concrete == "String" || concrete == "Character":
            return ["UnicodeScalarLiteralType": concrete]

        case "_ExpressibleByBuiltinBooleanLiteral"
        where concrete == "Bool" && representedType == .bool,
            "_ExpressibleByBuiltinIntegerLiteral"
        where isStandardInteger(
            concrete: concrete,
            representedType: representedType
        ),
            "_ExpressibleByBuiltinFloatLiteral"
        where isStandardFloat(
            concrete: concrete,
            representedType: representedType
        ),
            "_ExpressibleByBuiltinStringLiteral"
        where concrete == "String",
            "_ExpressibleByBuiltinExtendedGraphemeClusterLiteral"
        where concrete == "String" || concrete == "Character",
            "_ExpressibleByBuiltinUnicodeScalarLiteral"
        where concrete == "String" || concrete == "Character":
            return [:]

        default:
            return nil
        }
    }

    private static func numericEvidence(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> [String: String]? {
        guard
            isStandardNumber(
                concrete: concrete,
                representedType: representedType
            ),
            var evidence = magnitudeEvidence(
                concrete: concrete,
                representedType: representedType
            ),
            let literal = integerLiteralType(
                concrete: concrete,
                representedType: representedType
            )
        else { return nil }
        evidence["IntegerLiteralType"] = literal
        return evidence
    }

    private static func integerEvidence(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> [String: String]? {
        guard
            var evidence = numericEvidence(
                concrete: concrete,
                representedType: representedType
            )
        else { return nil }
        evidence["Stride"] = "Int"
        return evidence
    }

    private static func strideEvidence(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> [String: String]? {
        if isStandardInteger(
            concrete: concrete,
            representedType: representedType
        ) {
            return ["Stride": "Int"]
        }
        guard
            isStandardFloat(
                concrete: concrete,
                representedType: representedType
            )
        else { return nil }
        return ["Stride": canonicalFloatIdentity(concrete)]
    }

    private static func magnitudeEvidence(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> [String: String]? {
        switch representedType {
        case .integer(let bitWidth, let signed):
            return [
                "Magnitude": signed
                    ? unsignedIntegerName(
                        for: concrete,
                        bitWidth: bitWidth
                    )
                    : concrete
            ]
        case .float:
            return ["Magnitude": canonicalFloatIdentity(concrete)]
        default:
            return nil
        }
    }

    private static func unsignedIntegerName(
        for concrete: String,
        bitWidth: UInt16
    ) -> String {
        if concrete == "Int" { return "UInt" }
        switch bitWidth {
        case 8: return "UInt8"
        case 16: return "UInt16"
        case 32: return "UInt32"
        default: return "UInt64"
        }
    }

    private static func integerLiteralType(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> String? {
        if isStandardInteger(
            concrete: concrete,
            representedType: representedType
        ) {
            return concrete
        }
        guard
            isStandardFloat(
                concrete: concrete,
                representedType: representedType
            )
        else { return nil }
        return isCGFloatIdentity(concrete) ? "Int" : "Int64"
    }

    private static func floatLiteralType(concrete: String) -> String? {
        switch concrete {
        case "Float", "Float32": return "Float"
        case "Double", "Float64": return "Double"
        case "CGFloat", "CoreFoundation.CGFloat", "CoreGraphics.CGFloat":
            return "Double"
        default: return nil
        }
    }

    private static func canonicalFloatIdentity(_ concrete: String) -> String {
        switch concrete {
        case "Float32": "Float"
        case "Float64": "Double"
        default: concrete
        }
    }

    private static func isStandardNumber(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> Bool {
        isStandardInteger(
            concrete: concrete,
            representedType: representedType
        )
            || isStandardFloat(
                concrete: concrete,
                representedType: representedType
            )
    }

    private static func isStandardSignedNumber(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> Bool {
        isStandardSignedInteger(
            concrete: concrete,
            representedType: representedType
        )
            || isStandardFloat(
                concrete: concrete,
                representedType: representedType
            )
    }

    private static func isStandardInteger(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> Bool {
        guard case .integer = representedType else { return false }
        return integerIdentities.contains(concrete)
    }

    private static func isStandardSignedInteger(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> Bool {
        guard case .integer(_, true) = representedType else { return false }
        return signedIntegerIdentities.contains(concrete)
    }

    private static func isStandardUnsignedInteger(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> Bool {
        guard case .integer(_, false) = representedType else { return false }
        return unsignedIntegerIdentities.contains(concrete)
    }

    private static func isStandardFloat(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> Bool {
        guard case .float = representedType else { return false }
        return floatIdentities.contains(concrete)
    }

    private static func isCGFloatIdentity(_ concrete: String) -> Bool {
        ["CGFloat", "CoreFoundation.CGFloat", "CoreGraphics.CGFloat"]
            .contains(concrete)
    }

    private static func isStandardEquatableIdentity(_ concrete: String) -> Bool {
        isStandardScalarIdentity(concrete)
            || hasGenericRoot(
                concrete,
                in: [
                    "Optional", "Array", "ArraySlice", "Dictionary", "Set",
                ])
    }

    private static func isStandardHashableIdentity(_ concrete: String) -> Bool {
        isStandardEquatableIdentity(concrete)
    }

    private static func isStandardComparableIdentity(_ concrete: String) -> Bool {
        isStandardScalarIdentity(concrete) && concrete != "Bool"
    }

    private static func isStandardScalarIdentity(_ concrete: String) -> Bool {
        integerIdentities.contains(concrete)
            || floatIdentities.contains(concrete)
            || ["Bool", "String", "Character"].contains(concrete)
    }

    private static func hasGenericRoot(
        _ concrete: String,
        in roots: Set<String>
    ) -> Bool {
        guard let open = concrete.firstIndex(of: "<") else { return false }
        return roots.contains(String(concrete[..<open]))
    }

    private static let signedIntegerIdentities: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
    ]
    private static let unsignedIntegerIdentities: Set<String> = [
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    ]
    private static let integerIdentities =
        signedIntegerIdentities
        .union(unsignedIntegerIdentities)
    private static let floatIdentities: Set<String> = [
        "Float", "Float32", "Double", "Float64", "CGFloat",
        "CoreFoundation.CGFloat", "CoreGraphics.CGFloat",
    ]

    private static func isRepresentedScalarDescription(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> Bool {
        switch representedType {
        case .bool:
            concrete == "Bool"
        case .integer:
            integerIdentities.contains(concrete)
        case .float:
            floatIdentities.contains(concrete)
        case .string:
            concrete == "String" || concrete == "Character"
        default:
            false
        }
    }

    private static func isRepresentedLosslessTextScalar(
        concrete: String,
        representedType: Bytecode.ValueType
    ) -> Bool {
        switch representedType {
        case .bool:
            concrete == "Bool"
        case .integer:
            integerIdentities.contains(concrete)
        case .float:
            floatIdentities.contains(concrete)
        case .string:
            concrete == "String"
        default:
            false
        }
    }

    private struct CollectionShape {
        var element: String
        var isSequence = true
        var isCollection = false
        var isBidirectional = false
        var isRandomAccess = false
        var isMutable = false
        var isRangeReplaceable = false

        static func sequence(element: String) -> Self {
            .init(element: element)
        }

        static func collection(
            element: String,
            bidirectional: Bool = false,
            randomAccess: Bool = false,
            mutable: Bool = false,
            rangeReplaceable: Bool = false
        ) -> Self {
            .init(
                element: element,
                isCollection: true,
                isBidirectional: bidirectional || randomAccess,
                isRandomAccess: randomAccess,
                isMutable: mutable,
                isRangeReplaceable: rangeReplaceable
            )
        }
    }

    private static let maximumWrapperDepth = 16

    private static func collectionShape(
        of concrete: String,
        depth: Int
    ) -> CollectionShape? {
        guard depth <= maximumWrapperDepth,
              let element = CanonicalSIL.SwiftTypeIdentity
                .representedSequenceElement(of: concrete)
        else { return nil }

        switch concrete {
        case "String", "Substring":
            return .collection(
                element: element,
                bidirectional: true,
                rangeReplaceable: true
            )
        default:
            break
        }

        if concrete.hasSuffix(".Keys") || concrete.hasSuffix(".Values") {
            return .collection(element: element)
        }
        guard let generic = CanonicalSIL.SwiftTypeIdentity.genericType(
            concrete
        ) else {
            return .sequence(element: element)
        }
        switch generic.name {
        case "Array", "ArraySlice":
            guard generic.arguments.count == 1 else { return nil }
            return .collection(
                element: element,
                randomAccess: true,
                mutable: true,
                rangeReplaceable: true
            )
        case "Dictionary", "Set":
            return .collection(element: element)
        case "Repeated":
            guard generic.arguments.count == 1 else { return nil }
            return .collection(element: element, randomAccess: true)
        case "Slice":
            guard generic.arguments.count == 1,
                  let base = collectionShape(
                    of: generic.arguments[0],
                    depth: depth + 1
                  ), base.isCollection
            else { return nil }
            return .collection(
                element: element,
                bidirectional: base.isBidirectional,
                randomAccess: base.isRandomAccess,
                mutable: base.isMutable,
                rangeReplaceable: base.isRangeReplaceable
            )
        case "ReversedCollection":
            guard generic.arguments.count == 1,
                  let base = collectionShape(
                    of: generic.arguments[0],
                    depth: depth + 1
                  ), base.isBidirectional
            else { return nil }
            return .collection(
                element: element,
                bidirectional: true,
                randomAccess: base.isRandomAccess
            )
        case "EnumeratedSequence":
            guard generic.arguments.count == 1,
                  let base = collectionShape(
                    of: generic.arguments[0],
                    depth: depth + 1
                  )
            else { return nil }
            guard base.isCollection else {
                return .sequence(element: element)
            }
            return .collection(
                element: element,
                bidirectional: base.isBidirectional,
                randomAccess: base.isRandomAccess
            )
        case "Zip2Sequence":
            guard generic.arguments.count == 2,
                  collectionShape(
                    of: generic.arguments[0],
                    depth: depth + 1
                  ) != nil, collectionShape(
                    of: generic.arguments[1],
                    depth: depth + 1
                  ) != nil
            else { return nil }
            return .sequence(element: element)
        case "Range", "ClosedRange":
            guard generic.arguments.count == 1,
                  isRepresentedInteger(generic.arguments[0])
            else { return .sequence(element: element) }
            return .collection(element: element, randomAccess: true)
        case "StrideTo", "StrideThrough", "FlattenSequence",
             "JoinedSequence":
            return .sequence(element: element)
        default:
            return .sequence(element: element)
        }
    }

    private static func sequenceAssociatedTypes(
        element: String
    ) -> [String: String] {
        ["Element": element]
    }

    private static func collectionAssociatedTypes(
        element: String
    ) -> [String: String] {
        sequenceAssociatedTypes(element: element)
    }

    private static func normalizedProtocolName(_ raw: String) -> String {
        let compact = raw.filter { !$0.isWhitespace }
        return compact.hasPrefix("Swift.")
            ? String(compact.dropFirst("Swift.".count)) : compact
    }

    private static func isRepresentedInteger(_ raw: String) -> Bool {
        switch CanonicalSIL.SwiftTypeIdentity.normalized(raw) {
        case "Int", "Int8", "Int16", "Int32", "Int64",
             "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return true
        default:
            return false
        }
    }
}
}
