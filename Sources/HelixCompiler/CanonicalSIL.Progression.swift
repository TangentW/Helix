import HelixBytecode

extension CanonicalSIL {
enum Progression {
    enum BoundedRangeBound: Equatable, Sendable {
        case lower
        case upper
    }

    enum Family: Equatable, Sendable {
        case range
        case closedRange
        case strideTo
        case strideThrough

        var boundary: Bytecode.ProgressionBoundary {
            switch self {
            case .range, .strideTo: .exclusive
            case .closedRange, .strideThrough: .inclusive
            }
        }

        var usesExplicitStride: Bool {
            switch self {
            case .range, .closedRange: false
            case .strideTo, .strideThrough: true
            }
        }
    }

    struct SequenceType: Equatable, Sendable {
        var family: Family
        var element: Bytecode.ValueType

        var stride: Bytecode.ValueType? {
            switch element {
            case .integer:
                .int64
            case .float:
                element
            default:
                nil
            }
        }

        var supportsIteration: Bool {
            switch (family, element) {
            case (.range, .integer), (.closedRange, .integer),
                 (.strideTo, .integer), (.strideTo, .float),
                 (.strideThrough, .integer), (.strideThrough, .float):
                true
            default:
                false
            }
        }
    }

    struct Value: Equatable, Sendable {
        var type: SequenceType
        var start: Bytecode.Register
        var end: Bytecode.Register
        var stride: Bytecode.Register?
    }

    struct IteratorState: Equatable, Sendable {
        var type: SequenceType
        var end: Bytecode.Register
        var stride: Bytecode.Register
        var cursorSlot: Bytecode.StackSlot
    }

    static func boundedRangeBound(
        owner rawOwner: String,
        field: String,
        type: SequenceType
    ) -> BoundedRangeBound? {
        let expectedOwner: String
        switch type.family {
        case .range:
            expectedOwner = "Range"
        case .closedRange:
            expectedOwner = "ClosedRange"
        case .strideTo, .strideThrough:
            return nil
        }
        guard CanonicalSIL.SwiftTypeIdentity.normalized(rawOwner)
                == expectedOwner
        else { return nil }
        switch field {
        case "lowerBound": return .lower
        case "upperBound": return .upper
        default: return nil
        }
    }

    static func sequenceType(
        _ raw: String,
        resolve: (String) throws -> Bytecode.ValueType
    ) throws -> SequenceType? {
        let type = normalize(raw)
        let familyAndElement: (Family, String)?
        if let element = genericArgument(type, name: "Range") {
            familyAndElement = (.range, element)
        } else if let element = genericArgument(type, name: "ClosedRange") {
            familyAndElement = (.closedRange, element)
        } else if let element = genericArgument(type, name: "StrideTo") {
            familyAndElement = (.strideTo, element)
        } else if let element = genericArgument(type, name: "StrideThrough") {
            familyAndElement = (.strideThrough, element)
        } else {
            return nil
        }
        guard let (family, elementSpelling) = familyAndElement else {
            return nil
        }
        let element = try resolve(elementSpelling)
        switch (family, element) {
        case (.range, .integer), (.range, .float), (.range, .string),
             (.closedRange, .integer), (.closedRange, .float),
             (.closedRange, .string), (.strideTo, .integer),
             (.strideTo, .float), (.strideThrough, .integer),
             (.strideThrough, .float):
            return .init(family: family, element: element)
        default:
            throw CanonicalSIL.LoweringError.unsupportedType(type)
        }
    }

    static func iteratorType(
        _ raw: String,
        resolve: (String) throws -> Bytecode.ValueType
    ) throws -> SequenceType? {
        let type = normalize(raw)
        if let collection = genericArgument(type, name: "IndexingIterator"),
           let sequence = try sequenceType(collection, resolve: resolve) {
            guard sequence.family == .range || sequence.family == .closedRange,
                  sequence.supportsIteration
            else {
                throw CanonicalSIL.LoweringError.unsupportedType(type)
            }
            return sequence
        }
        let familyAndElement: (Family, String)?
        if let element = genericArgument(type, name: "StrideToIterator") {
            familyAndElement = (.strideTo, element)
        } else if let element = genericArgument(type, name: "StrideThroughIterator") {
            familyAndElement = (.strideThrough, element)
        } else {
            return nil
        }
        guard let (family, elementSpelling) = familyAndElement else {
            return nil
        }
        let sequence = SequenceType(
            family: family,
            element: try resolve(elementSpelling)
        )
        guard sequence.supportsIteration else {
            throw CanonicalSIL.LoweringError.unsupportedType(type)
        }
        return sequence
    }

    private static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Swift.", with: "")
            .filter { !$0.isWhitespace }
    }

    private static func genericArgument(
        _ type: String,
        name: String
    ) -> String? {
        let prefix = name + "<"
        guard type.hasPrefix(prefix), type.hasSuffix(">") else {
            return nil
        }
        return String(type.dropFirst(prefix.count).dropLast())
    }
}
}
