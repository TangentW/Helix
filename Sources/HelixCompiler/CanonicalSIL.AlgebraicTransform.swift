import HelixBytecode

extension CanonicalSIL {
enum AlgebraicTransform {
    enum Container: Equatable {
        case optional(wrapped: Bytecode.ValueType)
        case enumeration(key: Bytecode.LocalTypeKey)

        var type: Bytecode.ValueType {
            switch self {
            case let .optional(wrapped): .optional(wrapped)
            case let .enumeration(key): .local(key)
            }
        }
    }

    enum CaseTag: Equatable {
        case optionalSome
        case optionalNone
        case enumeration(UInt32)
    }

    struct Case: Equatable {
        var tag: CaseTag
        var payloadType: Bytecode.ValueType?
    }

    enum ClosureOutput: Equatable {
        /// The logical closure result becomes the payload of `outputCase`.
        case payload(
            logicalType: Bytecode.ValueType,
            storedType: Bytecode.ValueType,
            outputCase: Case
        )

        /// The closure already returns the complete output container.
        case container(Bytecode.ValueType)

        var logicalType: Bytecode.ValueType {
            switch self {
            case let .payload(logicalType, _, _): logicalType
            case let .container(type): type
            }
        }
    }

    /// A closure transform selects one payload case and structurally forwards
    /// the complementary case, keeping binary Optional and Result APIs on one
    /// ownership-checked lowering path.
    struct Plan: Equatable {
        var sourceToken: String
        var closureToken: String
        var resultDestination: String
        var errorDestination: String?
        var errorType: Bytecode.ValueType?
        var input: Container
        var output: Container
        var transformedInputCase: Case
        var passthroughInputCase: Case
        var passthroughOutputCase: Case
        var closureOutput: ClosureOutput
    }

    struct ProjectionPlan: Equatable {
        var sourceToken: String
        var resultDestination: String
        var errorDestination: String
        var input: Container
        var successCase: Case
        var failureCase: Case
    }
}
}
