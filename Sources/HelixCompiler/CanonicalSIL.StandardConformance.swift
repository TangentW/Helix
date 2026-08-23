extension CanonicalSIL {
/// Closed standard-protocol evidence for Swift value families whose semantics
/// Helix already represents directly. This is deliberately narrower than the
/// Swift standard library: a similar HLBC storage shape is not conformance.
enum StandardConformance {
    static func associatedTypes(
        concrete raw: String,
        protocolName rawProtocol: String
    ) -> [String: String]? {
        let concrete = CanonicalSIL.SwiftTypeIdentity.normalized(raw)
        guard let shape = collectionShape(of: concrete, depth: 0) else {
            return nil
        }
        let protocolName = normalizedProtocolName(rawProtocol)
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
