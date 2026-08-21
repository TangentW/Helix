import Foundation

extension CanonicalSIL {
/// Index semantics retained by represented Collection values.
enum CollectionIndex {
    /// Describes whether an Array-backed representation can reproduce the
    /// source Collection's public index identity.
    enum Model: Equatable, Sendable {
        /// Indices are physical zero-based integer offsets.
        case zeroBasedInteger
        /// Indices are integers whose logical start is retained by the value.
        case preservedBaseInteger
        /// The source uses an index identity that HLBC does not represent.
        case opaque
    }

    enum Operation: Equatable {
        case start
        case end
        case distance
        case indices
        case after
        case before
        case offsetBy
        case offsetByLimited
        case formAfter
        case formBefore
        case formOffsetBy
        case formOffsetByLimited

        var returnsIndexValue: Bool {
            switch self {
            case .start, .end, .after, .before, .offsetBy, .offsetByLimited:
                true
            case .distance, .indices, .formAfter, .formBefore,
                 .formOffsetBy, .formOffsetByLimited:
                false
            }
        }
    }

    /// Identifies how a stdlib entry point carries its Collection
    /// specialization. Concrete Array-family methods substitute Element;
    /// protocol-extension entry points substitute the complete Self type.
    enum Source: Equatable {
        /// A concrete zero-based Array-backed entry point substitutes only its
        /// Element. Array and Repeated currently share this physical ABI.
        case arrayElement
        case arraySliceElement
        /// A concrete `Slice<Base>` entry point substitutes `Base` rather than
        /// the complete slice type.
        case sliceBase
        case genericCollection

        var usesAssociatedIndexABI: Bool {
            switch self {
            case .arrayElement, .arraySliceElement:
                false
            case .sliceBase, .genericCollection:
                true
            }
        }
    }

    struct Intrinsic: Equatable {
        var operation: Operation
        var source: Source

        var returnsIndexIndirectly: Bool {
            operation.returnsIndexValue && source.usesAssociatedIndexABI
        }
    }

    static func model(for raw: String) -> Model {
        model(forNormalized: CanonicalSIL.SwiftTypeIdentity.normalized(raw))
    }

    private static func model(forNormalized type: String) -> Model {
        guard let generic = CanonicalSIL.SwiftTypeIdentity.genericType(type)
        else { return .opaque }

        switch generic.name {
        case "Array", "Repeated":
            return generic.arguments.count == 1 ? .zeroBasedInteger : .opaque
        case "ArraySlice":
            return generic.arguments.count == 1
                ? .preservedBaseInteger : .opaque
        case "Slice":
            guard generic.arguments.count == 1 else { return .opaque }
            switch model(forNormalized: generic.arguments[0]) {
            case .zeroBasedInteger, .preservedBaseInteger:
                return .preservedBaseInteger
            case .opaque:
                return .opaque
            }
        default:
            return .opaque
        }
    }
}
}
