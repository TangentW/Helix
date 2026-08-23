import HelixBytecode

extension CanonicalSIL {
/// Concrete standard-protocol requirements whose observable semantics are
/// already part of the verified value model. The compiler keeps the frontend
/// witness spelling as proof, but executes no Swift witness table at runtime.
enum StandardProtocolWitness: Equatable, Sendable {
    enum BinaryOperandOrder: Equatable, Sendable {
        case forward
        case receiverLast
    }

    enum UTF8LiteralKind: Equatable, Sendable {
        case string
        case extendedGraphemeCluster
    }

    enum IntegerStaticValue: Equatable, Sendable {
        case minimum
        case maximum
        case bitWidth
        case isSigned
    }

    case comparison(
        type: Bytecode.ValueType,
        predicate: Bytecode.ComparisonPredicate
    )
    case binary(
        type: Bytecode.ValueType,
        operation: Bytecode.BinaryOperation,
        operandOrder: BinaryOperandOrder
    )
    case shift(
        type: Bytecode.ValueType,
        rhs: Bytecode.ValueType?,
        operation: Bytecode.BinaryOperation
    )
    case integerStaticValue(
        type: Bytecode.ValueType,
        value: IntegerStaticValue
    )
    case integerUnary(
        source: Bytecode.ValueType,
        result: Bytecode.ValueType,
        operation: Bytecode.IntegerUnaryOperation
    )
    case integerSignum(type: Bytecode.ValueType)
    case integerIsMultiple(type: Bytecode.ValueType)
    case integerQuotientAndRemainder(type: Bytecode.ValueType)
    case integerReportingOverflow(
        type: Bytecode.ValueType,
        operation: Bytecode.BinaryOperation
    )
    case integerWrappingBinary(
        type: Bytecode.ValueType,
        operation: Bytecode.BinaryOperation
    )
    case integerFullWidthMultiply(
        type: Bytecode.ValueType,
        magnitude: Bytecode.ValueType
    )
    case mutatingBinary(
        type: Bytecode.ValueType,
        operation: Bytecode.BinaryOperation
    )
    case zero(type: Bytecode.ValueType)
    case negate(type: Bytecode.ValueType)
    case negateInPlace(type: Bytecode.ValueType)
    case magnitude(
        source: Bytecode.ValueType,
        result: Bytecode.ValueType
    )
    case distance(
        type: Bytecode.ValueType,
        stride: Bytecode.ValueType
    )
    case advanced(
        type: Bytecode.ValueType,
        stride: Bytecode.ValueType
    )
    case conversion(
        source: Bytecode.ValueType,
        result: Bytecode.ValueType
    )
    case compilerIntegerLiteral(type: Bytecode.ValueType)
    case compilerUTF8Literal(
        type: Bytecode.ValueType,
        kind: UTF8LiteralKind
    )
    case compilerUnicodeScalarLiteral(type: Bytecode.ValueType)
    case description(type: Bytecode.ValueType)
    case losslessStringInitializer(type: Bytecode.ValueType)

    struct Reference: Equatable, Sendable {
        var conformingType: String
        var requirement: String
        var functionType: String
        var witness: CanonicalSIL.StandardProtocolWitness
    }

    static func resolve(
        _ reference: CanonicalSIL.ProtocolConformance.StaticDispatch
            .WitnessReference,
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) -> Reference? {
        let concrete = CanonicalSIL.SwiftTypeIdentity.normalized(
            reference.conformingType
        )
        guard let type = try? typeEnvironment.resolve(concrete) else {
            return nil
        }
        let requirement = normalizedRequirement(reference.requirement)
        let protocolName = String(
            requirement.prefix { $0 != "." }
        )
        guard
            let associatedTypes =
                typeEnvironment
                .standardConformanceAssociatedTypes(
                    concrete: concrete,
                    protocolName: protocolName
                )
        else {
            return nil
        }

        let witness: Self?
        switch requirement {
        case "Equatable.\"==\"":
            witness =
                type.isVMEquatable
                ? .comparison(type: type, predicate: .equal) : nil
        case "Comparable.\"<\"":
            witness =
                type.isVMComparable
                ? .comparison(type: type, predicate: .lessThan) : nil
        case "Comparable.\"<=\"":
            witness =
                type.isVMComparable
                ? .comparison(type: type, predicate: .lessThanOrEqual) : nil
        case "Comparable.\">\"":
            witness =
                type.isVMComparable
                ? .comparison(type: type, predicate: .greaterThan) : nil
        case "Comparable.\">=\"":
            witness =
                type.isVMComparable
                ? .comparison(type: type, predicate: .greaterThanOrEqual) : nil
        case "AdditiveArithmetic.\"+\"":
            witness = representedBinary(type: type, operation: .add)
        case "AdditiveArithmetic.\"-\"":
            witness = representedBinary(type: type, operation: .subtract)
        case "AdditiveArithmetic.\"+=\"":
            witness = representedMutatingBinary(type: type, operation: .add)
        case "AdditiveArithmetic.\"-=\"":
            witness = representedMutatingBinary(
                type: type,
                operation: .subtract
            )
        case "AdditiveArithmetic.zero!getter":
            witness = isRepresentedNumber(type) ? .zero(type: type) : nil
        case "Numeric.\"*\"":
            witness = representedBinary(type: type, operation: .multiply)
        case "Numeric.\"*=\"":
            witness = representedMutatingBinary(
                type: type,
                operation: .multiply
            )
        case "Numeric.magnitude!getter":
            witness = magnitude(type: type)
        case "SignedNumeric.\"-\"":
            witness =
                isRepresentedSignedNumber(type)
                ? .negate(type: type) : nil
        case "SignedNumeric.negate":
            witness =
                isRepresentedSignedNumber(type)
                ? .negateInPlace(type: type) : nil
        case "BinaryInteger.\"/\"":
            witness = representedIntegerBinary(type: type, operation: .divide)
        case "BinaryInteger.\"%\"":
            witness = representedIntegerBinary(
                type: type,
                operation: .remainder
            )
        case "BinaryInteger.\"&\"":
            witness = representedIntegerBinary(type: type, operation: .bitAnd)
        case "BinaryInteger.\"|\"":
            witness = representedIntegerBinary(type: type, operation: .bitOr)
        case "BinaryInteger.\"^\"":
            witness = representedIntegerBinary(type: type, operation: .bitXor)
        case "BinaryInteger.\"<<\"":
            witness =
                isRepresentedInteger(type)
                ? .shift(type: type, rhs: nil, operation: .shiftLeft) : nil
        case "BinaryInteger.\">>\"":
            witness =
                isRepresentedInteger(type)
                ? .shift(type: type, rhs: nil, operation: .shiftRight) : nil
        case "FixedWidthInteger.min!getter":
            witness = fixedWidthStaticValue(
                type: type,
                value: .minimum
            )
        case "FixedWidthInteger.max!getter":
            witness = fixedWidthStaticValue(
                type: type,
                value: .maximum
            )
        case "FixedWidthInteger.bitWidth!getter":
            witness = fixedWidthStaticValue(
                type: type,
                value: .bitWidth
            )
        case "BinaryInteger.isSigned!getter":
            witness = fixedWidthStaticValue(
                type: type,
                value: .isSigned
            )
        case "FixedWidthInteger.nonzeroBitCount!getter":
            witness = representedIntegerUnary(
                type: type,
                result: .int64,
                operation: .nonzeroBitCount
            )
        case "FixedWidthInteger.leadingZeroBitCount!getter":
            witness = representedIntegerUnary(
                type: type,
                result: .int64,
                operation: .leadingZeroBitCount
            )
        case "BinaryInteger.trailingZeroBitCount!getter":
            witness = representedIntegerUnary(
                type: type,
                result: .int64,
                operation: .trailingZeroBitCount
            )
        case "FixedWidthInteger.byteSwapped!getter":
            witness = representedIntegerUnary(
                type: type,
                result: type,
                operation: .byteSwapped
            )
        case "BinaryInteger.signum":
            witness = isRepresentedInteger(type)
                ? .integerSignum(type: type) : nil
        case "BinaryInteger.isMultiple":
            witness = isRepresentedInteger(type)
                ? .integerIsMultiple(type: type) : nil
        case "BinaryInteger.quotientAndRemainder":
            witness = isRepresentedInteger(type)
                ? .integerQuotientAndRemainder(type: type) : nil
        case "FixedWidthInteger.addingReportingOverflow":
            witness = representedIntegerReportingOverflow(
                type: type,
                operation: .add
            )
        case "FixedWidthInteger.subtractingReportingOverflow":
            witness = representedIntegerReportingOverflow(
                type: type,
                operation: .subtract
            )
        case "FixedWidthInteger.multipliedReportingOverflow":
            witness = representedIntegerReportingOverflow(
                type: type,
                operation: .multiply
            )
        case "FixedWidthInteger.dividedReportingOverflow":
            witness = representedIntegerReportingOverflow(
                type: type,
                operation: .divide
            )
        case "FixedWidthInteger.remainderReportingOverflow":
            witness = representedIntegerReportingOverflow(
                type: type,
                operation: .remainder
            )
        case "FixedWidthInteger.\"&*\"":
            witness = isRepresentedInteger(type)
                ? .integerWrappingBinary(
                    type: type,
                    operation: .multiply
                ) : nil
        case "FixedWidthInteger.multipliedFullWidth":
            witness = magnitudeType(for: type).map {
                .integerFullWidthMultiply(
                    type: type,
                    magnitude: $0
                )
            }
        case "FloatingPoint.\"/\"":
            witness =
                isRepresentedFloat(type)
                ? .binary(
                    type: type,
                    operation: .divide,
                    operandOrder: .forward
                ) : nil
        case "FloatingPoint.remainder":
            witness =
                isRepresentedFloat(type)
                ? .binary(
                    type: type,
                    operation: .remainder,
                    operandOrder: .receiverLast
                ) : nil
        case "Strideable.distance":
            witness = associatedValueType(
                "Stride",
                in: associatedTypes,
                typeEnvironment: typeEnvironment
            ).map { .distance(type: type, stride: $0) }
        case "Strideable.advanced":
            witness = associatedValueType(
                "Stride",
                in: associatedTypes,
                typeEnvironment: typeEnvironment
            ).map { .advanced(type: type, stride: $0) }
        case "_ExpressibleByBuiltinIntegerLiteral.init!allocator":
            witness =
                isRepresentedInteger(type)
                ? .compilerIntegerLiteral(type: type) : nil
        case "_ExpressibleByBuiltinBooleanLiteral.init!allocator":
            witness =
                type == .bool
                ? .conversion(source: .bool, result: .bool) : nil
        case "_ExpressibleByBuiltinFloatLiteral.init!allocator":
            witness =
                isRepresentedFloat(type)
                ? .conversion(
                    source: .float(bitWidth: 64),
                    result: type
                ) : nil
        case "_ExpressibleByBuiltinStringLiteral.init!allocator":
            witness =
                concrete == "String"
                ? .compilerUTF8Literal(type: type, kind: .string) : nil
        case "_ExpressibleByBuiltinExtendedGraphemeClusterLiteral.init!allocator":
            witness =
                (concrete == "String" || concrete == "Character")
                ? .compilerUTF8Literal(
                    type: type,
                    kind: .extendedGraphemeCluster
                ) : nil
        case "_ExpressibleByBuiltinUnicodeScalarLiteral.init!allocator":
            witness =
                (concrete == "String" || concrete == "Character")
                ? .compilerUnicodeScalarLiteral(type: type) : nil
        case "ExpressibleByIntegerLiteral.init!allocator":
            witness = literalConversion(
                associatedType: "IntegerLiteralType",
                associatedTypes: associatedTypes,
                result: type,
                typeEnvironment: typeEnvironment
            )
        case "ExpressibleByBooleanLiteral.init!allocator":
            witness = literalConversion(
                associatedType: "BooleanLiteralType",
                associatedTypes: associatedTypes,
                result: type,
                typeEnvironment: typeEnvironment
            )
        case "ExpressibleByFloatLiteral.init!allocator":
            witness = literalConversion(
                associatedType: "FloatLiteralType",
                associatedTypes: associatedTypes,
                result: type,
                typeEnvironment: typeEnvironment
            )
        case "ExpressibleByStringLiteral.init!allocator":
            witness = literalConversion(
                associatedType: "StringLiteralType",
                associatedTypes: associatedTypes,
                result: type,
                typeEnvironment: typeEnvironment
            )
        case "ExpressibleByExtendedGraphemeClusterLiteral.init!allocator":
            witness = literalConversion(
                associatedType: "ExtendedGraphemeClusterLiteralType",
                associatedTypes: associatedTypes,
                result: type,
                typeEnvironment: typeEnvironment
            )
        case "ExpressibleByUnicodeScalarLiteral.init!allocator":
            witness = literalConversion(
                associatedType: "UnicodeScalarLiteralType",
                associatedTypes: associatedTypes,
                result: type,
                typeEnvironment: typeEnvironment
            )
        case "CustomStringConvertible.description!getter":
            witness =
                isRepresentedDescription(type: type, concrete: concrete)
                ? .description(type: type) : nil
        case "LosslessStringConvertible.init!allocator":
            witness =
                isRepresentedLosslessStringInitializer(
                    type: type,
                    concrete: concrete
                ) ? .losslessStringInitializer(type: type) : nil
        default:
            witness = nil
        }
        guard let witness else { return nil }
        return .init(
            conformingType: concrete,
            requirement: requirement,
            functionType: reference.functionType,
            witness: witness
        )
    }

    var parameterTypes: [Bytecode.ValueType] {
        switch self {
        case .comparison(let type, _), .binary(let type, _, _):
            [type, type]
        case .shift(let type, let rhs, _):
            [type, rhs ?? .never]
        case .integerStaticValue:
            []
        case .integerUnary(let source, _, _), .integerSignum(let source):
            [source]
        case .integerIsMultiple(let type),
            .integerQuotientAndRemainder(let type),
            .integerReportingOverflow(let type, _),
            .integerWrappingBinary(let type, _),
            .integerFullWidthMultiply(let type, _):
            [type, type]
        case .mutatingBinary(let type, _):
            [.address(type), type]
        case .zero:
            []
        case .negate(let type), .magnitude(let type, _),
            .description(let type):
            [type]
        case .distance(let type, _):
            [type, type]
        case .advanced(let type, let stride):
            [stride, type]
        case .conversion(let source, _):
            [source]
        case .compilerIntegerLiteral(let type):
            [type]
        case .compilerUTF8Literal:
            [.string, .integer(bitWidth: 64, signed: false), .bool]
        case .compilerUnicodeScalarLiteral:
            [.string]
        case .negateInPlace(let type):
            [.address(type)]
        case .losslessStringInitializer:
            [.string]
        }
    }

    var resultType: Bytecode.ValueType {
        switch self {
        case .comparison:
            .bool
        case .binary(let type, _, _), .shift(let type, _, _),
            .zero(let type), .negate(let type):
            type
        case .integerStaticValue(let type, let value):
            switch value {
            case .minimum, .maximum: type
            case .bitWidth: .int64
            case .isSigned: .bool
            }
        case .integerUnary(_, let result, _):
            result
        case .integerSignum(let type), .integerWrappingBinary(let type, _):
            type
        case .integerIsMultiple:
            .bool
        case .integerQuotientAndRemainder(let type):
            .tuple([type, type])
        case .integerReportingOverflow(let type, _):
            .tuple([type, .bool])
        case .integerFullWidthMultiply(let type, let magnitude):
            .tuple([type, magnitude])
        case .mutatingBinary, .negateInPlace:
            .void
        case .magnitude(_, let result):
            result
        case .distance(_, let stride):
            stride
        case .advanced(let type, _), .conversion(_, let type),
            .compilerIntegerLiteral(let type),
            .compilerUTF8Literal(let type, _),
            .compilerUnicodeScalarLiteral(let type):
            type
        case .description:
            .string
        case .losslessStringInitializer(let type):
            .optional(type)
        }
    }

    var mutatesAddress: Bool {
        switch self {
        case .mutatingBinary, .negateInPlace:
            true
        default:
            false
        }
    }

    /// Most standard requirements have only the `Self` generic clause. Shift
    /// requirements add an independent `RHS: BinaryInteger`; concretize that
    /// clause from the exact apply before parsing or executing its ABI.
    func concretized(
        genericArguments: [String],
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) -> Self? {
        switch self {
        case .shift(let type, nil, let operation):
            guard genericArguments.count == 2,
                typeEnvironment.standardConformanceAssociatedTypes(
                    concrete: genericArguments[1],
                    protocolName: "BinaryInteger"
                ) != nil,
                let rhs = try? typeEnvironment.resolve(genericArguments[1]),
                Self.isRepresentedInteger(rhs)
            else { return nil }
            return .shift(type: type, rhs: rhs, operation: operation)
        case .shift:
            return nil
        default:
            return genericArguments.count == 1 ? self : nil
        }
    }

    /// Compiler literal payloads are not Swift values and never enter HLBC.
    /// The exact witness spelling is validated first; this normalized type is
    /// used only to describe their compiler-owned lowering representation.
    func normalizingCompilerLiteralABI(in functionType: String) -> String {
        switch self {
        case .compilerIntegerLiteral(let type):
            functionType.replacingOccurrences(
                of: "Builtin.IntLiteral",
                with: Self.scalarTypeSpelling(type)
            )
        case .compilerUTF8Literal:
            functionType
                .replacingOccurrences(of: "Builtin.RawPointer", with: "String")
                .replacingOccurrences(of: "Builtin.Word", with: "UInt64")
        case .compilerUnicodeScalarLiteral:
            functionType.replacingOccurrences(
                of: "Builtin.Int32",
                with: "String"
            )
        default:
            functionType
        }
    }

    private static func normalizedRequirement(_ raw: String) -> String {
        let compact = raw.filter { !$0.isWhitespace }
        return compact.hasPrefix("Swift.")
            ? String(compact.dropFirst("Swift.".count)) : compact
    }

    private static func representedBinary(
        type: Bytecode.ValueType,
        operation: Bytecode.BinaryOperation
    ) -> Self? {
        isRepresentedNumber(type)
            ? .binary(
                type: type,
                operation: operation,
                operandOrder: .forward
            ) : nil
    }

    private static func representedMutatingBinary(
        type: Bytecode.ValueType,
        operation: Bytecode.BinaryOperation
    ) -> Self? {
        isRepresentedNumber(type)
            ? .mutatingBinary(type: type, operation: operation) : nil
    }

    private static func representedIntegerBinary(
        type: Bytecode.ValueType,
        operation: Bytecode.BinaryOperation
    ) -> Self? {
        guard case .integer = type else { return nil }
        return .binary(
            type: type,
            operation: operation,
            operandOrder: .forward
        )
    }

    private static func fixedWidthStaticValue(
        type: Bytecode.ValueType,
        value: IntegerStaticValue
    ) -> Self? {
        isRepresentedInteger(type)
            ? .integerStaticValue(type: type, value: value) : nil
    }

    private static func representedIntegerUnary(
        type: Bytecode.ValueType,
        result: Bytecode.ValueType,
        operation: Bytecode.IntegerUnaryOperation
    ) -> Self? {
        isRepresentedInteger(type)
            ? .integerUnary(
                source: type,
                result: result,
                operation: operation
            ) : nil
    }

    private static func representedIntegerReportingOverflow(
        type: Bytecode.ValueType,
        operation: Bytecode.BinaryOperation
    ) -> Self? {
        isRepresentedInteger(type)
            ? .integerReportingOverflow(type: type, operation: operation)
            : nil
    }

    private static func associatedValueType(
        _ name: String,
        in associatedTypes: [String: String],
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) -> Bytecode.ValueType? {
        guard let spelling = associatedTypes[name] else { return nil }
        return try? typeEnvironment.resolve(spelling)
    }

    private static func literalConversion(
        associatedType: String,
        associatedTypes: [String: String],
        result: Bytecode.ValueType,
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) -> Self? {
        guard
            let source = associatedValueType(
                associatedType,
                in: associatedTypes,
                typeEnvironment: typeEnvironment
            )
        else { return nil }
        switch (source, result) {
        case (let lhs, let rhs) where lhs == rhs:
            return .conversion(source: source, result: result)
        case (.integer(_, true), .float), (.float, .float):
            return .conversion(source: source, result: result)
        default:
            return nil
        }
    }

    private static func scalarTypeSpelling(
        _ type: Bytecode.ValueType
    ) -> String {
        switch type {
        case .bool: "Bool"
        case .integer(let bitWidth, let signed):
            "\(signed ? "Int" : "UInt")\(bitWidth)"
        case .float(let bitWidth):
            "Float\(bitWidth)"
        case .string: "String"
        default:
            // Resolution admits compiler literals only for represented scalar
            // standard types, so this spelling is unreachable in a valid plan.
            "Never"
        }
    }

    private static func magnitude(type: Bytecode.ValueType) -> Self? {
        magnitudeType(for: type).map {
            .magnitude(source: type, result: $0)
        }
    }

    private static func magnitudeType(
        for type: Bytecode.ValueType
    ) -> Bytecode.ValueType? {
        switch type {
        case .integer(let bitWidth, _):
            .integer(bitWidth: bitWidth, signed: false)
        case .float:
            type
        default:
            nil
        }
    }

    private static func isRepresentedNumber(
        _ type: Bytecode.ValueType
    ) -> Bool {
        switch type {
        case .integer, .float: true
        default: false
        }
    }

    private static func isRepresentedSignedNumber(
        _ type: Bytecode.ValueType
    ) -> Bool {
        switch type {
        case .integer(_, true), .float: true
        default: false
        }
    }

    private static func isRepresentedFloat(
        _ type: Bytecode.ValueType
    ) -> Bool {
        if case .float = type { return true }
        return false
    }

    private static func isRepresentedInteger(
        _ type: Bytecode.ValueType
    ) -> Bool {
        if case .integer = type { return true }
        return false
    }

    private static func isRepresentedDescription(
        type: Bytecode.ValueType,
        concrete: String
    ) -> Bool {
        switch type {
        case .bool, .integer, .float:
            true
        case .string:
            concrete == "String" || concrete == "Character"
        default:
            false
        }
    }

    private static func isRepresentedLosslessStringInitializer(
        type: Bytecode.ValueType,
        concrete: String
    ) -> Bool {
        switch type {
        case .bool, .integer, .float:
            true
        case .string:
            concrete == "String"
        default:
            false
        }
    }
}
}
