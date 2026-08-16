import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension Bytecode {
public struct FunctionID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { String(rawValue) }
}

public struct BlockID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "bb\(rawValue)" }
}

public struct Register: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "%\(rawValue)" }
}

public struct StackSlot: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "$\(rawValue)" }
}

public enum ParameterConvention: String, Codable, Hashable, Sendable {
    case owned
    case borrowed
    case `inout`
}

public enum AccessKind: String, Codable, Hashable, Sendable {
    case read
    case modify
}

public struct ClosureSignature: Codable, Hashable, Sendable, CustomStringConvertible {
    public var parameters: [Bytecode.ValueType]
    /// Invocation ownership is part of a closure's callable ABI. In
    /// particular, generic Swift callbacks commonly borrow nontrivial values;
    /// treating every dynamic call as consuming would either reject those
    /// callbacks or force type-specific copies in each higher-order lowering.
    public var parameterConventions: [Bytecode.ParameterConvention]
    public var result: Bytecode.ValueType
    public var effects: Core.Effects

    public init(
        parameters: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention],
        result: Bytecode.ValueType,
        effects: Core.Effects = .init()
    ) {
        self.parameters = parameters
        self.parameterConventions = parameterConventions
        self.result = result
        self.effects = effects
    }

    public var description: String {
        guard parameterConventions.count == parameters.count else {
            return "<invalid closure signature: \(parameters.count) parameters, "
                + "\(parameterConventions.count) conventions>"
        }
        let arguments = zip(parameters, parameterConventions).map {
            parameter, convention in
            let prefix = switch convention {
            case .owned: ""
            case .borrowed: "@borrowed "
            case .inout: "@inout "
            }
            return prefix + parameter.description
        }.joined(separator: ", ")
        return "(\(arguments)) -> \(result)"
    }
}

public enum FunctionKind: String, Codable, Hashable, Sendable {
    case ordinary
    case closureBody
    case concreteSpecialization
}

public indirect enum ValueType: Codable, Hashable, Sendable, CustomStringConvertible {
    case void
    case never
    case bool
    case integer(bitWidth: UInt16, signed: Bool)
    case float(bitWidth: UInt16)
    case string
    case any
    case array(Bytecode.ValueType)
    case dictionary(key: Bytecode.ValueType, value: Bytecode.ValueType)
    case set(Bytecode.ValueType)
    case native(Core.TypeID)
    case local(Bytecode.LocalTypeKey)
    case error
    case address(Bytecode.ValueType)
    case mutableCell(Bytecode.ValueType)
    case arrayBuilder(Bytecode.ValueType)
    case closure(Bytecode.ClosureSignature)
    case tuple([Bytecode.ValueType])
    case optional(Bytecode.ValueType)

    public static let int64: Self = .integer(bitWidth: 64, signed: true)

    public var isTrivial: Bool {
        switch self {
        case .void, .never, .bool, .integer, .float:
            true
        case let .tuple(elements):
            elements.allSatisfy(\.isTrivial)
        case let .optional(wrapped):
            wrapped.isTrivial
        case .string, .any, .array, .dictionary, .set, .native, .local, .error,
             .address, .mutableCell, .arrayBuilder, .closure:
            false
        }
    }

    /// Native values and invocation-local builders need explicit linear
    /// lifetime proof. Other Swift-managed values release with their register.
    public var requiresLinearOwnership: Bool {
        switch self {
        case .native:
            true
        case let .tuple(elements):
            elements.contains(where: \.requiresLinearOwnership)
        case let .optional(wrapped):
            wrapped.requiresLinearOwnership
        case let .array(element):
            element.requiresLinearOwnership
        case let .dictionary(key, value):
            key.requiresLinearOwnership || value.requiresLinearOwnership
        case let .set(element):
            element.requiresLinearOwnership
        case .arrayBuilder:
            true
        case .void, .never, .bool, .integer, .float, .string, .any, .local,
             .error, .address, .mutableCell, .closure:
            false
        }
    }

    public var description: String {
        switch self {
        case .void: "Void"
        case .never: "Never"
        case .bool: "Bool"
        case let .integer(width, signed): "\(signed ? "Int" : "UInt")\(width)"
        case let .float(width): "Float\(width)"
        case .string: "String"
        case .any: "Any"
        case let .array(element): "Array<\(element)>"
        case let .dictionary(key, value): "Dictionary<\(key), \(value)>"
        case let .set(element): "Set<\(element)>"
        case let .native(type): "Native<\(type)>"
        case let .local(key): key.description
        case .error: "any Error"
        case let .address(pointee): "@address<\(pointee)>"
        case let .mutableCell(pointee): "@mutableCell<\(pointee)>"
        case let .arrayBuilder(element): "@arrayBuilder<\(element)>"
        case let .closure(signature): "@closure\(signature)"
        case let .tuple(elements): "(\(elements.map(\.description).joined(separator: ", ")))"
        case let .optional(wrapped): "Optional<\(wrapped)>"
        }
    }
}

public enum BinaryOperation: String, Codable, Hashable, Sendable {
    case add
    case subtract
    case multiply
    case divide
    case remainder
    case bitAnd
    case bitOr
    case bitXor
    case shiftLeft
    case shiftRight
}

public enum FloatBinaryOperation: String, Codable, Hashable, Sendable {
    case add
    case subtract
    case multiply
    case divide
    case remainder
    case truncatingRemainder
    case minimum
    case maximum
    case minimumMagnitude
    case maximumMagnitude
}

public enum FloatUnaryOperation: String, Codable, Hashable, Sendable {
    case negate
    case absolute
    case squareRoot
    case ulp
    case nextUp
    case binade
    case significand
    case roundDown
    case roundUp
    case roundTowardZero
    case roundAwayFromZero
    case roundToNearestOrAwayFromZero
    case roundToNearestOrEven
}

public enum FloatPredicateOperation: String, Codable, Hashable, Sendable {
    case isFinite
    case isInfinite
    case isNaN
    case isSignalingNaN
    case isNormal
    case isSubnormal
    case isZero
    case isSignMinus
    case isCanonical
}

public enum FloatBinaryPredicateOperation: String, Codable, Hashable, Sendable {
    case isTotallyOrderedBelowOrEqual
}

public enum FloatTernaryOperation: String, Codable, Hashable, Sendable {
    /// Computes `multiplicand * multiplier + addend` with one rounding step.
    case fusedMultiplyAdd
}

public enum FloatIntegerPropertyOperation: String, Codable, Hashable, Sendable {
    case exponent
    case exponentBitPattern
    case significandBitPattern
    case significandWidth
}

public enum IntegerUnaryOperation: String, Codable, Hashable, Sendable {
    case magnitude
    case nonzeroBitCount
    case leadingZeroBitCount
    case trailingZeroBitCount
    case byteSwapped
    case bigEndian
    case littleEndian
    case signum
}

public enum IntegerConversionOperation: String, Codable, Hashable, Sendable {
    case truncate
    case signExtend
    case zeroExtend
    case reinterpret
    case clamp
}

public enum FloatingConversionOperation: String, Codable, Hashable, Sendable {
    case truncate
    case extend
    case signedIntegerToFloat
    case unsignedIntegerToFloat
}

public enum StringPredicateOperation: String, Codable, Hashable, Sendable {
    case hasPrefix
    case hasSuffix
    case contains
}

public enum StringTransformOperation: String, Codable, Hashable, Sendable {
    case uppercase
    case lowercase
}

public enum ArrayBoundaryOperation: String, Codable, Hashable, Sendable {
    case first
    case last
}

public enum ArraySearchOperation: String, Codable, Hashable, Sendable {
    case firstIndex
    case lastIndex
}

public enum ArrayExtremumOperation: String, Codable, Hashable, Sendable {
    case minimum
    case maximum
}

public enum ArrayRelationOperation: String, Codable, Hashable, Sendable {
    /// Element-by-element equality without Array's shared-storage fast path.
    case elementsEqual
    case startsWith
    case lexicographicallyPrecedes
}

public enum ArrayAdapterOperation: String, Codable, Hashable, Sendable {
    case reversed
    case enumerated
}

public enum ArraySubsequenceOperation: String, Codable, Hashable, Sendable {
    case dropFirst
    case dropLast
    case prefix
    case suffix
    case prefixUpTo
    case prefixThrough
    case suffixFrom
}

public enum SetAlgebraOperation: String, Codable, Hashable, Sendable {
    case union
    case intersection
    case subtracting
    case symmetricDifference
}

public enum SetRelationOperation: String, Codable, Hashable, Sendable {
    case equal
    case subset
    case strictSubset
    case superset
    case strictSuperset
    case disjoint
}

public enum BooleanBinaryOperation: String, Codable, Hashable, Sendable {
    case and
    case or
    case xor
}

public enum ComparisonPredicate: String, Codable, Hashable, Sendable {
    case equal
    case notEqual
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}

public enum StackStoreMode: String, Codable, Hashable, Sendable {
    case initialize
    case assign
    /// Stores a complete value whether the destination is currently
    /// initialized or not. This models Swift's conditional-initialization
    /// cleanup without exposing unchecked memory operations.
    case replace
}

public enum StackLoadMode: String, Codable, Hashable, Sendable {
    case copy
    case take
}

public enum TrapReason: Codable, Hashable, Sendable, CustomStringConvertible {
    case integerOverflow
    case divisionByZero
    case quotaExceeded
    case explicit(String)

    public var description: String {
        switch self {
        case .integerOverflow: "integer overflow"
        case .divisionByZero: "division by zero"
        case .quotaExceeded: "execution quota exceeded"
        case let .explicit(message): message
        }
    }
}

public enum Instruction: Codable, Hashable, Sendable {
    /// Materializes the low `ValueType.integer` bits exactly. Signedness is a
    /// property of the destination register, not of Swift's SIL literal node.
    case constantInteger(result: Bytecode.Register, bitPattern: UInt64)
    case constantBool(result: Bytecode.Register, value: Bool)
    /// Materializes an IEEE-754 binary32 or binary64 payload without routing
    /// it through JSON floating-point numbers or another floating width.
    case constantFloat(result: Bytecode.Register, bitPattern: UInt64)
    case constantString(result: Bytecode.Register, value: String)
    case copyValue(result: Bytecode.Register, source: Bytecode.Register)
    case moveValue(result: Bytecode.Register, source: Bytecode.Register)
    case destroyValue(Bytecode.Register)
    case makeTuple(result: Bytecode.Register, elements: [Bytecode.Register])
    case unpackTuple(results: [Bytecode.Register], tuple: Bytecode.Register)
    case makeStruct(result: Bytecode.Register, fields: [Bytecode.Register])
    case structExtract(
        result: Bytecode.Register,
        structure: Bytecode.Register,
        fieldIndex: UInt32
    )
    case makeEnum(
        result: Bytecode.Register,
        caseIndex: UInt32,
        payload: Bytecode.Register?
    )
    case switchEnum(
        enumeration: Bytecode.Register,
        cases: [Bytecode.EnumCaseTarget],
        defaultTarget: Bytecode.BlockID?
    )
    case makeError(result: Bytecode.Register, payload: Bytecode.Register)
    case castError(
        result: Bytecode.Register,
        error: Bytecode.Register,
        expectedType: Bytecode.LocalTypeKey
    )
    case eraseToAny(result: Bytecode.Register, value: Bytecode.Register)
    case checkedCastAny(result: Bytecode.Register, value: Bytecode.Register)
    case forceCastAny(result: Bytecode.Register, value: Bytecode.Register)
    case makeOptionalSome(result: Bytecode.Register, value: Bytecode.Register)
    case makeOptionalNone(result: Bytecode.Register)
    case optionalIsSome(result: Bytecode.Register, optional: Bytecode.Register)
    case unwrapOptional(result: Bytecode.Register, optional: Bytecode.Register)
    case switchOptional(
        optional: Bytecode.Register,
        someTarget: Bytecode.BlockID,
        noneTarget: Bytecode.BlockID
    )
    case storeStack(
        slot: Bytecode.StackSlot,
        source: Bytecode.Register,
        mode: Bytecode.StackStoreMode
    )
    case loadStack(
        result: Bytecode.Register,
        slot: Bytecode.StackSlot,
        mode: Bytecode.StackLoadMode
    )
    case destroyStack(Bytecode.StackSlot)
    case destroyStackIfInitialized(Bytecode.StackSlot)
    case stackAddress(result: Bytecode.Register, slot: Bytecode.StackSlot)
    case projectAggregateAddress(
        result: Bytecode.Register,
        base: Bytecode.Register,
        fieldIndex: UInt32
    )
    case makeMutableCell(
        result: Bytecode.Register,
        initialValue: Bytecode.Register?
    )
    case projectMutableCell(
        result: Bytecode.Register,
        cell: Bytecode.Register,
        fieldIndex: UInt32
    )
    case loadMutableCell(
        result: Bytecode.Register,
        cell: Bytecode.Register
    )
    case storeMutableCell(
        cell: Bytecode.Register,
        source: Bytecode.Register,
        mode: Bytecode.StackStoreMode
    )
    case allocateObject(result: Bytecode.Register)
    case projectObjectAddress(
        result: Bytecode.Register,
        object: Bytecode.Register,
        fieldIndex: UInt32
    )
    /// Projects the Objective-C host of a patch-local class as its frozen
    /// native superclass. The host is created by Runtime; HLVM never fabricates
    /// Swift class metadata.
    case projectHostedObject(
        result: Bytecode.Register,
        object: Bytecode.Register
    )
    /// Calls the exact superclass implementation for one bounded hosted method.
    /// `methodIndex` addresses the immutable descriptor on the local class.
    case hostedSuperApply(
        object: Bytecode.Register,
        methodIndex: UInt32,
        arguments: [Bytecode.Register]
    )
    case beginAccess(
        result: Bytecode.Register,
        address: Bytecode.Register,
        kind: Bytecode.AccessKind
    )
    case endAccess(Bytecode.Register)
    case loadAddress(
        result: Bytecode.Register,
        address: Bytecode.Register,
        mode: Bytecode.StackLoadMode
    )
    case storeAddress(
        address: Bytecode.Register,
        source: Bytecode.Register,
        mode: Bytecode.StackStoreMode
    )
    case checkedBinary(
        result: Bytecode.Register,
        overflow: Bytecode.Register,
        operation: Bytecode.BinaryOperation,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case floatingBinary(
        result: Bytecode.Register,
        operation: Bytecode.FloatBinaryOperation,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case floatingUnary(
        result: Bytecode.Register,
        operation: Bytecode.FloatUnaryOperation,
        operand: Bytecode.Register
    )
    case floatingPredicate(
        result: Bytecode.Register,
        operation: Bytecode.FloatPredicateOperation,
        operand: Bytecode.Register
    )
    case floatingBinaryPredicate(
        result: Bytecode.Register,
        operation: Bytecode.FloatBinaryPredicateOperation,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case floatingTernary(
        result: Bytecode.Register,
        operation: Bytecode.FloatTernaryOperation,
        multiplicand: Bytecode.Register,
        multiplier: Bytecode.Register,
        addend: Bytecode.Register
    )
    case floatingIntegerProperty(
        result: Bytecode.Register,
        operation: Bytecode.FloatIntegerPropertyOperation,
        operand: Bytecode.Register
    )
    case integerUnary(
        result: Bytecode.Register,
        operation: Bytecode.IntegerUnaryOperation,
        operand: Bytecode.Register
    )
    case integerFullWidthMultiply(
        high: Bytecode.Register,
        low: Bytecode.Register,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case integerFullWidthDivide(
        quotient: Bytecode.Register,
        remainder: Bytecode.Register,
        dividendHigh: Bytecode.Register,
        dividendLow: Bytecode.Register,
        divisor: Bytecode.Register
    )
    case scalarBitCast(
        result: Bytecode.Register,
        operand: Bytecode.Register
    )
    case integerConvert(
        result: Bytecode.Register,
        operation: Bytecode.IntegerConversionOperation,
        value: Bytecode.Register
    )
    case floatingConvert(
        result: Bytecode.Register,
        operation: Bytecode.FloatingConversionOperation,
        value: Bytecode.Register
    )
    case booleanBinary(
        result: Bytecode.Register,
        operation: Bytecode.BooleanBinaryOperation,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case select(
        result: Bytecode.Register,
        condition: Bytecode.Register,
        trueValue: Bytecode.Register,
        falseValue: Bytecode.Register
    )
    case stringConcat(
        result: Bytecode.Register,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case stringCount(result: Bytecode.Register, string: Bytecode.Register)
    case stringIsEmpty(result: Bytecode.Register, string: Bytecode.Register)
    case stringPredicate(
        result: Bytecode.Register,
        operation: Bytecode.StringPredicateOperation,
        string: Bytecode.Register,
        pattern: Bytecode.Register
    )
    case stringTransform(
        result: Bytecode.Register,
        operation: Bytecode.StringTransformOperation,
        string: Bytecode.Register
    )
    case stringify(result: Bytecode.Register, value: Bytecode.Register)
    case makeArray(result: Bytecode.Register, elements: [Bytecode.Register])
    case arrayCount(result: Bytecode.Register, array: Bytecode.Register)
    case arrayIsEmpty(result: Bytecode.Register, array: Bytecode.Register)
    case arrayGet(
        result: Bytecode.Register,
        array: Bytecode.Register,
        index: Bytecode.Register
    )
    case arrayBoundary(
        result: Bytecode.Register,
        operation: Bytecode.ArrayBoundaryOperation,
        array: Bytecode.Register
    )
    case arrayContains(
        result: Bytecode.Register,
        array: Bytecode.Register,
        value: Bytecode.Register
    )
    case arraySearch(
        result: Bytecode.Register,
        operation: Bytecode.ArraySearchOperation,
        array: Bytecode.Register,
        value: Bytecode.Register
    )
    case arrayExtremum(
        result: Bytecode.Register,
        operation: Bytecode.ArrayExtremumOperation,
        array: Bytecode.Register
    )
    case arrayRelation(
        result: Bytecode.Register,
        operation: Bytecode.ArrayRelationOperation,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case arrayAdapter(
        result: Bytecode.Register,
        operation: Bytecode.ArrayAdapterOperation,
        array: Bytecode.Register
    )
    case arrayRepeat(
        result: Bytecode.Register,
        value: Bytecode.Register,
        count: Bytecode.Register
    )
    case arraySubsequence(
        result: Bytecode.Register,
        operation: Bytecode.ArraySubsequenceOperation,
        array: Bytecode.Register,
        bound: Bytecode.Register
    )
    case arrayRangeSlice(
        result: Bytecode.Register,
        array: Bytecode.Register,
        lowerBound: Bytecode.Register,
        upperBound: Bytecode.Register
    )
    case arrayZip(
        result: Bytecode.Register,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case arrayJoined(
        result: Bytecode.Register,
        arrays: Bytecode.Register,
        separator: Bytecode.Register?
    )
    case arrayAppend(
        result: Bytecode.Register,
        array: Bytecode.Register,
        value: Bytecode.Register
    )
    case makeArrayBuilder(result: Bytecode.Register)
    case arrayBuilderAppend(
        builder: Bytecode.Register,
        value: Bytecode.Register
    )
    case finishArrayBuilder(
        result: Bytecode.Register,
        builder: Bytecode.Register
    )
    case arrayUpdate(
        result: Bytecode.Register,
        array: Bytecode.Register,
        index: Bytecode.Register,
        value: Bytecode.Register
    )
    case arrayPopLast(
        elementResult: Bytecode.Register,
        arrayResult: Bytecode.Register,
        array: Bytecode.Register
    )
    case arrayNext(
        result: Bytecode.Register,
        array: Bytecode.Register,
        indexSlot: Bytecode.StackSlot
    )
    /// Advances a compiler-lowered Range or Stride sequence. The cursor is an
    /// Optional<Element>: `nil` is the exhausted state, which also avoids a
    /// sentinel collision at integer minima and maxima.
    case progressionNext(
        result: Bytecode.Register,
        cursorSlot: Bytecode.StackSlot,
        end: Bytecode.Register,
        stride: Bytecode.Register,
        boundary: Bytecode.ProgressionBoundary
    )
    case makeDictionary(result: Bytecode.Register, pairs: Bytecode.Register)
    case dictionaryCount(result: Bytecode.Register, dictionary: Bytecode.Register)
    case dictionaryIsEmpty(result: Bytecode.Register, dictionary: Bytecode.Register)
    case dictionaryGet(
        result: Bytecode.Register,
        dictionary: Bytecode.Register,
        key: Bytecode.Register
    )
    case dictionaryUpdate(
        result: Bytecode.Register,
        dictionary: Bytecode.Register,
        key: Bytecode.Register,
        value: Bytecode.Register
    )
    case dictionaryRemove(
        valueResult: Bytecode.Register,
        dictionaryResult: Bytecode.Register,
        dictionary: Bytecode.Register,
        key: Bytecode.Register
    )
    case dictionaryNext(
        result: Bytecode.Register,
        dictionary: Bytecode.Register,
        indexSlot: Bytecode.StackSlot
    )
    /// Builds a Set from an Array or Set with the same element type. The VM
    /// removes duplicate Array elements while preserving a deterministic
    /// iteration order; that order is not part of Set equality.
    case makeSet(result: Bytecode.Register, source: Bytecode.Register)
    case setCount(result: Bytecode.Register, set: Bytecode.Register)
    case setIsEmpty(result: Bytecode.Register, set: Bytecode.Register)
    case setContains(
        result: Bytecode.Register,
        set: Bytecode.Register,
        element: Bytecode.Register
    )
    case setInsert(
        insertedResult: Bytecode.Register,
        memberResult: Bytecode.Register,
        setResult: Bytecode.Register,
        set: Bytecode.Register,
        element: Bytecode.Register
    )
    case setUpdate(
        oldMemberResult: Bytecode.Register,
        setResult: Bytecode.Register,
        set: Bytecode.Register,
        element: Bytecode.Register
    )
    case setRemove(
        removedResult: Bytecode.Register,
        setResult: Bytecode.Register,
        set: Bytecode.Register,
        element: Bytecode.Register
    )
    case setPopFirst(
        elementResult: Bytecode.Register,
        setResult: Bytecode.Register,
        set: Bytecode.Register
    )
    case setNext(
        result: Bytecode.Register,
        set: Bytecode.Register,
        indexSlot: Bytecode.StackSlot
    )
    case setAlgebra(
        result: Bytecode.Register,
        operation: Bytecode.SetAlgebraOperation,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case setRelation(
        result: Bytecode.Register,
        operation: Bytecode.SetRelationOperation,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case compare(
        result: Bytecode.Register,
        predicate: Bytecode.ComparisonPredicate,
        lhs: Bytecode.Register,
        rhs: Bytecode.Register
    )
    case branch(target: Bytecode.BlockID, arguments: [Bytecode.Register])
    case conditionalBranch(
        condition: Bytecode.Register,
        trueTarget: Bytecode.BlockID,
        trueArguments: [Bytecode.Register],
        falseTarget: Bytecode.BlockID,
        falseArguments: [Bytecode.Register]
    )
    case apply(
        result: Bytecode.Register?,
        function: Bytecode.FunctionID,
        arguments: [Bytecode.Register]
    )
    case entryApply(
        result: Bytecode.Register?,
        entry: Core.EntryIndex,
        arguments: [Bytecode.Register]
    )
    case nativeApply(
        result: Bytecode.Register?,
        importID: Core.NativeImportID,
        arguments: [Bytecode.Register]
    )
    case makeClosure(
        result: Bytecode.Register,
        function: Bytecode.FunctionID,
        captures: [Bytecode.Register]
    )
    case closureApply(
        result: Bytecode.Register?,
        closure: Bytecode.Register,
        arguments: [Bytecode.Register]
    )
    case closureTryApply(
        closure: Bytecode.Register,
        arguments: [Bytecode.Register],
        normalTarget: Bytecode.BlockID,
        errorTarget: Bytecode.BlockID
    )
    case tryApply(
        function: Bytecode.FunctionID,
        arguments: [Bytecode.Register],
        normalTarget: Bytecode.BlockID,
        errorTarget: Bytecode.BlockID
    )
    case entryTryApply(
        entry: Core.EntryIndex,
        arguments: [Bytecode.Register],
        normalTarget: Bytecode.BlockID,
        errorTarget: Bytecode.BlockID
    )
    case nativeTryApply(
        importID: Core.NativeImportID,
        arguments: [Bytecode.Register],
        normalTarget: Bytecode.BlockID,
        errorTarget: Bytecode.BlockID
    )
    case returnValue(Bytecode.Register?)
    case throwError(Bytecode.Register)
    case trap(Bytecode.TrapReason)

    public var resultRegisters: [Bytecode.Register] {
        switch self {
        case let .constantInteger(result, _),
             let .constantBool(result, _),
             let .constantFloat(result, _),
             let .constantString(result, _),
             let .copyValue(result, _),
             let .moveValue(result, _),
             let .makeTuple(result, _),
             let .makeStruct(result, _),
             let .structExtract(result, _, _),
             let .makeEnum(result, _, _),
             let .makeError(result, _),
             let .castError(result, _, _),
             let .eraseToAny(result, _),
             let .checkedCastAny(result, _),
             let .forceCastAny(result, _),
             let .makeOptionalSome(result, _),
             let .makeOptionalNone(result),
             let .optionalIsSome(result, _),
             let .unwrapOptional(result, _),
             let .loadStack(result, _, _),
             let .stackAddress(result, _),
             let .projectAggregateAddress(result, _, _),
             let .makeMutableCell(result, _),
             let .projectMutableCell(result, _, _),
             let .loadMutableCell(result, _),
             let .makeArrayBuilder(result),
             let .finishArrayBuilder(result, _),
             let .allocateObject(result),
             let .projectObjectAddress(result, _, _),
             let .projectHostedObject(result, _),
             let .beginAccess(result, _, _),
             let .loadAddress(result, _, _),
             let .floatingBinary(result, _, _, _),
             let .floatingUnary(result, _, _),
             let .floatingPredicate(result, _, _),
             let .floatingBinaryPredicate(result, _, _, _),
             let .floatingTernary(result, _, _, _, _),
             let .floatingIntegerProperty(result, _, _),
             let .integerUnary(result, _, _),
             let .scalarBitCast(result, _),
             let .integerConvert(result, _, _),
             let .floatingConvert(result, _, _),
             let .booleanBinary(result, _, _, _),
             let .select(result, _, _, _),
             let .stringConcat(result, _, _),
             let .stringCount(result, _),
             let .stringIsEmpty(result, _),
             let .stringPredicate(result, _, _, _),
             let .stringTransform(result, _, _),
             let .stringify(result, _),
             let .makeArray(result, _),
             let .arrayCount(result, _),
             let .arrayIsEmpty(result, _),
             let .arrayGet(result, _, _),
             let .arrayBoundary(result, _, _),
             let .arrayContains(result, _, _),
             let .arraySearch(result, _, _, _),
             let .arrayExtremum(result, _, _),
             let .arrayRelation(result, _, _, _),
             let .arrayAdapter(result, _, _),
             let .arrayRepeat(result, _, _),
             let .arraySubsequence(result, _, _, _),
             let .arrayRangeSlice(result, _, _, _),
             let .arrayZip(result, _, _),
             let .arrayJoined(result, _, _),
             let .arrayAppend(result, _, _),
             let .arrayUpdate(result, _, _, _),
             let .arrayNext(result, _, _),
             let .progressionNext(result, _, _, _, _),
             let .makeDictionary(result, _),
             let .dictionaryCount(result, _),
             let .dictionaryIsEmpty(result, _),
             let .dictionaryGet(result, _, _),
             let .dictionaryUpdate(result, _, _, _),
             let .dictionaryNext(result, _, _),
             let .makeSet(result, _),
             let .setCount(result, _),
             let .setIsEmpty(result, _),
             let .setContains(result, _, _),
             let .setNext(result, _, _),
             let .setAlgebra(result, _, _, _),
             let .setRelation(result, _, _, _),
             let .compare(result, _, _, _),
             let .makeClosure(result, _, _):
            [result]
        case let .unpackTuple(results, _):
            results
        case let .checkedBinary(result, overflow, _, _, _):
            [result, overflow]
        case let .integerFullWidthMultiply(high, low, _, _):
            [high, low]
        case let .integerFullWidthDivide(quotient, remainder, _, _, _):
            [quotient, remainder]
        case let .arrayPopLast(elementResult, arrayResult, _):
            [elementResult, arrayResult]
        case let .dictionaryRemove(valueResult, dictionaryResult, _, _):
            [valueResult, dictionaryResult]
        case let .setInsert(insertedResult, memberResult, setResult, _, _):
            [insertedResult, memberResult, setResult]
        case let .setUpdate(oldMemberResult, setResult, _, _):
            [oldMemberResult, setResult]
        case let .setRemove(removedResult, setResult, _, _):
            [removedResult, setResult]
        case let .setPopFirst(elementResult, setResult, _):
            [elementResult, setResult]
        case let .apply(result, _, _),
             let .entryApply(result, _, _),
             let .nativeApply(result, _, _),
             let .closureApply(result, _, _):
            result.map { [$0] } ?? []
        case .destroyValue, .switchEnum, .storeStack, .destroyStack,
             .destroyStackIfInitialized,
             .storeMutableCell, .arrayBuilderAppend,
             .hostedSuperApply, .endAccess,
             .storeAddress, .switchOptional, .branch,
             .conditionalBranch, .closureTryApply, .tryApply,
             .entryTryApply, .nativeTryApply,
             .returnValue, .throwError, .trap:
            []
        }
    }

    public var operandRegisters: [Bytecode.Register] {
        switch self {
        case .constantInteger, .constantBool, .constantFloat, .constantString,
             .makeOptionalNone, .loadStack, .destroyStack,
             .destroyStackIfInitialized, .stackAddress,
             .allocateObject, .trap:
            []
        case let .copyValue(_, source), let .moveValue(_, source), let .destroyValue(source):
            [source]
        case let .makeTuple(_, elements):
            elements
        case let .unpackTuple(_, tuple):
            [tuple]
        case let .makeStruct(_, fields):
            fields
        case let .structExtract(_, structure, _):
            [structure]
        case let .makeEnum(_, _, payload):
            payload.map { [$0] } ?? []
        case let .switchEnum(enumeration, _, _):
            [enumeration]
        case let .makeError(_, payload):
            [payload]
        case let .castError(_, error, _):
            [error]
        case let .eraseToAny(_, value),
             let .checkedCastAny(_, value),
             let .forceCastAny(_, value):
            [value]
        case let .makeOptionalSome(_, value):
            [value]
        case let .optionalIsSome(_, optional), let .unwrapOptional(_, optional):
            [optional]
        case let .switchOptional(optional, _, _):
            [optional]
        case let .storeStack(_, source, _):
            [source]
        case let .projectAggregateAddress(_, base, _):
            [base]
        case let .makeMutableCell(_, initialValue):
            initialValue.map { [$0] } ?? []
        case let .projectMutableCell(_, cell, _),
             let .loadMutableCell(_, cell):
            [cell]
        case let .storeMutableCell(cell, source, _):
            [cell, source]
        case let .projectObjectAddress(_, object, _):
            [object]
        case let .projectHostedObject(_, object):
            [object]
        case let .hostedSuperApply(object, _, arguments):
            [object] + arguments
        case let .beginAccess(_, address, _),
             let .endAccess(address),
             let .loadAddress(_, address, _):
            [address]
        case let .storeAddress(address, source, _):
            [address, source]
        case let .checkedBinary(_, _, _, lhs, rhs),
             let .floatingBinary(_, _, lhs, rhs),
             let .floatingBinaryPredicate(_, _, lhs, rhs),
             let .booleanBinary(_, _, lhs, rhs),
             let .compare(_, _, lhs, rhs):
            [lhs, rhs]
        case let .floatingTernary(_, _, multiplicand, multiplier, addend):
            [multiplicand, multiplier, addend]
        case let .integerFullWidthMultiply(_, _, lhs, rhs):
            [lhs, rhs]
        case let .integerFullWidthDivide(
            _, _, dividendHigh, dividendLow, divisor
        ):
            [dividendHigh, dividendLow, divisor]
        case let .select(_, condition, trueValue, falseValue):
            [condition, trueValue, falseValue]
        case let .floatingUnary(_, _, operand),
             let .floatingPredicate(_, _, operand),
             let .floatingIntegerProperty(_, _, operand),
             let .integerUnary(_, _, operand),
             let .scalarBitCast(_, operand),
             let .integerConvert(_, _, operand),
             let .floatingConvert(_, _, operand):
            [operand]
        case let .stringConcat(_, lhs, rhs):
            [lhs, rhs]
        case let .stringCount(_, string), let .stringIsEmpty(_, string):
            [string]
        case let .stringPredicate(_, _, string, pattern):
            [string, pattern]
        case let .stringTransform(_, _, string):
            [string]
        case let .stringify(_, value):
            [value]
        case let .makeArray(_, elements):
            elements
        case let .arrayCount(_, array), let .arrayIsEmpty(_, array),
             let .arrayBoundary(_, _, array):
            [array]
        case let .arrayGet(_, array, index):
            [array, index]
        case let .arrayContains(_, array, value):
            [array, value]
        case let .arraySearch(_, _, array, value):
            [array, value]
        case let .arrayExtremum(_, _, array):
            [array]
        case let .arrayRelation(_, _, lhs, rhs):
            [lhs, rhs]
        case let .arrayAdapter(_, _, array):
            [array]
        case let .arrayRepeat(_, value, count):
            [value, count]
        case let .arraySubsequence(_, _, array, bound):
            [array, bound]
        case let .arrayRangeSlice(_, array, lowerBound, upperBound):
            [array, lowerBound, upperBound]
        case let .arrayZip(_, lhs, rhs):
            [lhs, rhs]
        case let .arrayJoined(_, arrays, separator):
            [arrays] + (separator.map { [$0] } ?? [])
        case let .arrayAppend(_, array, value):
            [array, value]
        case .makeArrayBuilder:
            []
        case let .arrayBuilderAppend(builder, value):
            [builder, value]
        case let .finishArrayBuilder(_, builder):
            [builder]
        case let .arrayUpdate(_, array, index, value):
            [array, index, value]
        case let .arrayPopLast(_, _, array):
            [array]
        case let .arrayNext(_, array, _):
            [array]
        case let .progressionNext(_, _, end, stride, _):
            [end, stride]
        case let .makeDictionary(_, pairs):
            [pairs]
        case let .dictionaryCount(_, dictionary),
             let .dictionaryIsEmpty(_, dictionary),
             let .dictionaryNext(_, dictionary, _):
            [dictionary]
        case let .dictionaryGet(_, dictionary, key):
            [dictionary, key]
        case let .dictionaryUpdate(_, dictionary, key, value):
            [dictionary, key, value]
        case let .dictionaryRemove(_, _, dictionary, key):
            [dictionary, key]
        case let .makeSet(_, source):
            [source]
        case let .setCount(_, set),
             let .setIsEmpty(_, set),
             let .setNext(_, set, _):
            [set]
        case let .setContains(_, set, element),
             let .setInsert(_, _, _, set, element),
             let .setUpdate(_, _, set, element),
             let .setRemove(_, _, set, element):
            [set, element]
        case let .setPopFirst(_, _, set):
            [set]
        case let .setAlgebra(_, _, lhs, rhs),
             let .setRelation(_, _, lhs, rhs):
            [lhs, rhs]
        case let .branch(_, arguments):
            arguments
        case let .conditionalBranch(condition, _, trueArguments, _, falseArguments):
            [condition] + trueArguments + falseArguments
        case let .apply(_, _, arguments),
             let .entryApply(_, _, arguments),
             let .nativeApply(_, _, arguments):
            arguments
        case let .makeClosure(_, _, captures):
            captures
        case let .closureApply(_, closure, arguments):
            [closure] + arguments
        case let .closureTryApply(closure, arguments, _, _):
            [closure] + arguments
        case let .tryApply(_, arguments, _, _),
             let .entryTryApply(_, arguments, _, _),
             let .nativeTryApply(_, arguments, _, _):
            arguments
        case let .returnValue(value):
            value.map { [$0] } ?? []
        case let .throwError(error):
            [error]
        }
    }

    public var isTerminator: Bool {
        switch self {
        case .switchOptional, .switchEnum, .branch, .conditionalBranch,
             .closureTryApply, .tryApply, .entryTryApply, .nativeTryApply,
             .returnValue, .throwError, .trap:
            true
        default: false
        }
    }
}

public struct Block: Codable, Hashable, Sendable {
    public var id: Bytecode.BlockID
    public var parameters: [Bytecode.Register]
    public var instructions: [Bytecode.Instruction]

    public init(id: Bytecode.BlockID, parameters: [Bytecode.Register] = [], instructions: [Bytecode.Instruction]) {
        self.id = id
        self.parameters = parameters
        self.instructions = instructions
    }
}

public struct Function: Codable, Hashable, Sendable {
    public var id: Bytecode.FunctionID
    public var name: String
    public var kind: Bytecode.FunctionKind
    public var parameterRegisters: [Bytecode.Register]
    public var parameterConventions: [Bytecode.ParameterConvention]
    public var resultType: Bytecode.ValueType
    public var registerTypes: [Bytecode.ValueType]
    public var stackSlotTypes: [Bytecode.ValueType]
    public var effects: Core.Effects
    public var entryBlock: Bytecode.BlockID
    public var blocks: [Bytecode.Block]
    public var sourceLocation: Core.SourceLocation?

    public init(
        id: Bytecode.FunctionID,
        name: String,
        kind: Bytecode.FunctionKind = .ordinary,
        parameterRegisters: [Bytecode.Register],
        parameterConventions: [Bytecode.ParameterConvention]? = nil,
        resultType: Bytecode.ValueType,
        registerTypes: [Bytecode.ValueType],
        entryBlock: Bytecode.BlockID,
        blocks: [Bytecode.Block],
        stackSlotTypes: [Bytecode.ValueType] = [],
        effects: Core.Effects = .init(),
        sourceLocation: Core.SourceLocation? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parameterRegisters = parameterRegisters
        self.parameterConventions = parameterConventions ?? parameterRegisters.map { register in
            guard registerTypes.indices.contains(Int(register.rawValue)),
                  case .address = registerTypes[Int(register.rawValue)]
            else { return .owned }
            return .inout
        }
        self.resultType = resultType
        self.registerTypes = registerTypes
        self.stackSlotTypes = stackSlotTypes
        self.effects = effects
        self.entryBlock = entryBlock
        self.blocks = blocks
        self.sourceLocation = sourceLocation
    }

    public func type(of register: Bytecode.Register) -> Bytecode.ValueType? {
        guard let index = Int(exactly: register.rawValue), registerTypes.indices.contains(index) else { return nil }
        return registerTypes[index]
    }

    public func type(of slot: Bytecode.StackSlot) -> Bytecode.ValueType? {
        guard let index = Int(exactly: slot.rawValue), stackSlotTypes.indices.contains(index) else {
            return nil
        }
        return stackSlotTypes[index]
    }
}

public struct EntryPoint: Codable, Hashable, Sendable {
    public var entryIndex: Core.EntryIndex
    public var functionKey: Core.FunctionKey
    public var functionID: Bytecode.FunctionID

    public init(entryIndex: Core.EntryIndex, functionKey: Core.FunctionKey, functionID: Bytecode.FunctionID) {
        self.entryIndex = entryIndex
        self.functionKey = functionKey
        self.functionID = functionID
    }
}

public struct ImportRequirement: Codable, Hashable, Sendable {
    public var id: Core.NativeImportID
    public var key: Core.NativeImportKey
    public var signature: Core.LoweredSignature
    public var effects: Core.Effects
    public var contract: Core.NativeImportContract
    public var requiredCapability: Core.Capability

    public init(
        id: Core.NativeImportID,
        key: Core.NativeImportKey,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        requiredCapability: Core.Capability = .nativeImportsV1
    ) {
        self.id = id
        self.key = key
        self.signature = signature
        self.effects = effects
        self.contract = contract
        self.requiredCapability = requiredCapability
    }
}

public struct SourceMapEntry: Codable, Hashable, Sendable {
    public var functionID: Bytecode.FunctionID
    public var blockID: Bytecode.BlockID
    public var instructionOffset: UInt32
    public var location: Core.SourceLocation

    public init(
        functionID: Bytecode.FunctionID,
        blockID: Bytecode.BlockID,
        instructionOffset: UInt32,
        location: Core.SourceLocation
    ) {
        self.functionID = functionID
        self.blockID = blockID
        self.instructionOffset = instructionOffset
        self.location = location
    }
}

public struct Module: Codable, Hashable, Sendable {
    public var name: String
    public var shellInterfaceHash: Core.Digest
    public var compatibility: Core.Compatibility
    public var capabilities: Set<Core.Capability>
    public var requestedResources: Core.ResourceLimits
    public var localTypes: [Bytecode.LocalTypeDefinition]
    public var functions: [Bytecode.Function]
    public var entries: [Bytecode.EntryPoint]
    public var imports: [Bytecode.ImportRequirement]
    public var sourceMap: [Bytecode.SourceMapEntry]

    public init(
        name: String,
        shellInterfaceHash: Core.Digest,
        compatibility: Core.Compatibility,
        capabilities: Set<Core.Capability> = [.baselineV1],
        requestedResources: Core.ResourceLimits = .init(),
        localTypes: [Bytecode.LocalTypeDefinition] = [],
        functions: [Bytecode.Function],
        entries: [Bytecode.EntryPoint] = [],
        imports: [Bytecode.ImportRequirement] = [],
        sourceMap: [Bytecode.SourceMapEntry] = []
    ) {
        self.name = name
        self.shellInterfaceHash = shellInterfaceHash
        self.compatibility = compatibility
        self.capabilities = capabilities
        self.requestedResources = requestedResources
        self.localTypes = localTypes
        self.functions = functions
        self.entries = entries
        self.imports = imports
        self.sourceMap = sourceMap
    }
}
}
