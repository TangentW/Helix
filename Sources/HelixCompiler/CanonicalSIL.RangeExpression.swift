import HelixBytecode

extension CanonicalSIL {
/// Compiler semantics shared by concrete Swift `RangeExpression` values.
///
/// One-sided range wrappers and the inaccessible full-range marker are
/// frontend-only values. Lowering retains their proven semantic shape while
/// keeping Swift generic metadata and witness tables out of HLBC.
enum RangeExpression {
    static let patternMatchMangledName = "$sSXsE2teoiySbx_5BoundQztFZ"
    static let unboundedCollectionSubscriptMangledName =
        "$sSlsEy11SubSequenceQzys15UnboundedRange_OXEcig"
    static let unboundedMutableCollectionSubscriptMangledName =
        "$sSMsEy11SubSequenceQzys15UnboundedRange_OXEcig"

    enum ComparisonOperand: Equatable, Sendable {
        case bound
        case candidate
    }

    struct Comparison: Equatable, Sendable {
        var predicate: Bytecode.ComparisonPredicate
        var lhs: ComparisonOperand
        var rhs: ComparisonOperand
    }

    enum PartialBoundary: Equatable, Sendable {
        case from
        case upTo
        case through

        var ownerTypeName: String {
            switch self {
            case .from: "PartialRangeFrom"
            case .upTo: "PartialRangeUpTo"
            case .through: "PartialRangeThrough"
            }
        }

        var storedFieldName: String {
            switch self {
            case .from: "lowerBound"
            case .upTo, .through: "upperBound"
            }
        }

        var subsequenceOperation: Bytecode.ArraySubsequenceOperation {
            switch self {
            case .from: .suffixFrom
            case .upTo: .prefixUpTo
            case .through: .prefixThrough
            }
        }

        var containmentComparison: Comparison {
            switch self {
            case .from:
                .init(
                    predicate: .lessThanOrEqual,
                    lhs: .bound,
                    rhs: .candidate
                )
            case .upTo:
                .init(
                    predicate: .lessThan,
                    lhs: .candidate,
                    rhs: .bound
                )
            case .through:
                .init(
                    predicate: .lessThanOrEqual,
                    lhs: .candidate,
                    rhs: .bound
                )
            }
        }
    }

    static func matchesPartialStoredField(
        owner rawOwner: String,
        field: String,
        shape: PartialShape
    ) -> Bool {
        let owner = CanonicalSIL.SwiftTypeIdentity.normalized(rawOwner)
        return owner == shape.boundary.ownerTypeName
            && field == shape.boundary.storedFieldName
    }

    struct PartialShape: Equatable, Sendable {
        var boundary: PartialBoundary
        var boundIdentity: String
        var boundType: Bytecode.ValueType
    }

    struct PartialValue: Equatable, Sendable {
        var shape: PartialShape
        var bound: Bytecode.Register
    }

    static func parsePartial(
        _ raw: String,
        resolve: (String) throws -> Bytecode.ValueType
    ) throws -> PartialShape? {
        let spelling = CanonicalSIL.SwiftTypeIdentity.normalized(raw)
        let families: [(prefix: String, boundary: PartialBoundary)] = [
            ("PartialRangeFrom<", .from),
            ("PartialRangeUpTo<", .upTo),
            ("PartialRangeThrough<", .through),
        ]
        guard let family = families.first(where: {
            spelling.hasPrefix($0.prefix) && spelling.hasSuffix(">")
        }) else {
            return nil
        }
        let boundSpelling = String(
            spelling.dropFirst(family.prefix.count).dropLast()
        )
        let boundType = try resolve(boundSpelling)
        guard boundType.isVMComparable else {
            throw CanonicalSIL.LoweringError.unsupportedType(spelling)
        }
        return .init(
            boundary: family.boundary,
            boundIdentity: CanonicalSIL.SwiftTypeIdentity.normalized(
                boundSpelling
            ),
            boundType: boundType
        )
    }

    static func isUnboundedMarkerFunctionType(_ raw: String) -> Bool {
        compact(raw) == "@convention(thin)(UnboundedRange_)->()"
    }

    static func isUnboundedMarkerClosureType(_ raw: String) -> Bool {
        compact(raw)
            == "@noescape@callee_guaranteed(UnboundedRange_)->()"
    }

    private static func compact(_ raw: String) -> String {
        let spelling = raw.first == "$" ? String(raw.dropFirst()) : raw
        return spelling.filter { !$0.isWhitespace }
    }
}
}
