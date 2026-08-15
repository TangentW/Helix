import HelixBytecode

extension CanonicalSIL {
/// Type-independent descriptions of scalar standard-library operations that
/// survive into SIL either as calls or as mandatory-inlined builtins.
enum ScalarIntrinsic: Equatable {
    enum StaticValue: Equatable {
        case minimum
        case maximum
        case bitWidth
        case isSigned
        case nan
        case signalingNaN
        case infinity
        case pi
        case greatestFiniteMagnitude
        case leastNormalMagnitude
        case leastNonzeroMagnitude
        case ulpOfOne
        case zero
        case radix

        enum Literal: Equatable {
            case integer(type: Bytecode.ValueType, bitPattern: UInt64)
            case floating(type: Bytecode.ValueType, bitPattern: UInt64)
            case boolean(Bool)
        }

        func literal(for receiver: Bytecode.ValueType) -> Literal? {
            switch (self, receiver) {
            case let (.minimum, .integer(width, signed)):
                return .integer(
                    type: receiver,
                    bitPattern: signed ? UInt64(1) << (width - 1) : 0
                )
            case let (.maximum, .integer(width, signed)):
                let mask = Self.integerMask(width: width)
                return .integer(
                    type: receiver,
                    bitPattern: signed ? mask >> 1 : mask
                )
            case let (.bitWidth, .integer(width, _)):
                return .integer(type: .int64, bitPattern: UInt64(width))
            case let (.isSigned, .integer(_, signed)):
                return .boolean(signed)
            case (.zero, .integer):
                return .integer(type: receiver, bitPattern: 0)
            case (.zero, .float):
                return .floating(type: receiver, bitPattern: 0)
            case (.radix, .float):
                return .integer(type: .int64, bitPattern: 2)
            case let (property, .float(width)):
                return Self.floatingLiteral(property, width: width).map {
                    .floating(type: receiver, bitPattern: $0)
                }
            default:
                return nil
            }
        }

        private static func integerMask(width: UInt16) -> UInt64 {
            width == 64 ? UInt64.max : (UInt64(1) << width) - 1
        }

        private static func floatingLiteral(
            _ property: StaticValue,
            width: UInt16
        ) -> UInt64? {
            switch width {
            case 32:
                let value: Float
                switch property {
                case .nan: value = .nan
                case .signalingNaN: value = .signalingNaN
                case .infinity: value = .infinity
                case .pi: value = .pi
                case .greatestFiniteMagnitude: value = .greatestFiniteMagnitude
                case .leastNormalMagnitude: value = .leastNormalMagnitude
                case .leastNonzeroMagnitude: value = .leastNonzeroMagnitude
                case .ulpOfOne: value = .ulpOfOne
                default: return nil
                }
                return UInt64(value.bitPattern)
            case 64:
                let value: Double
                switch property {
                case .nan: value = .nan
                case .signalingNaN: value = .signalingNaN
                case .infinity: value = .infinity
                case .pi: value = .pi
                case .greatestFiniteMagnitude: value = .greatestFiniteMagnitude
                case .leastNormalMagnitude: value = .leastNormalMagnitude
                case .leastNonzeroMagnitude: value = .leastNonzeroMagnitude
                case .ulpOfOne: value = .ulpOfOne
                default: return nil
                }
                return value.bitPattern
            default:
                return nil
            }
        }
    }

    case staticValue(StaticValue)
    case floatingUnary(Bytecode.FloatUnaryOperation)
    case floatingPredicate(Bytecode.FloatPredicateOperation)
    case floatingSign
    case floatingRoundDefault
    case floatingRoundRule
    case floatingRoundSlowPath
    case integerUnary(Bytecode.IntegerUnaryOperation)
    case integerIsMultiple
    case integerQuotientAndRemainder
    case integerReportingOverflow(Bytecode.BinaryOperation)

    init?(mangledName: String) {
        switch mangledName {
        case "$sSZss17FixedWidthIntegerRzrlE3minxvgZ",
             "$sSUss17FixedWidthIntegerRzrlE3minxvgZ":
            self = .staticValue(.minimum)
        case "$sSZss17FixedWidthIntegerRzrlE3maxxvgZ",
             "$sSUss17FixedWidthIntegerRzrlE3maxxvgZ":
            self = .staticValue(.maximum)
        case "$sSZsE8isSignedSbvgZ", "$sSUsE8isSignedSbvgZ":
            self = .staticValue(.isSigned)
        case "$ss18AdditiveArithmeticPss27ExpressibleByIntegerLiteralRzrlE4zeroxvgZ":
            self = .staticValue(.zero)
        case "$sSBsE5radixSivgZ": self = .staticValue(.radix)

        case "$sSf3nanSfvgZ", "$sSd3nanSdvgZ": self = .staticValue(.nan)
        case "$sSf12signalingNaNSfvgZ", "$sSd12signalingNaNSdvgZ":
            self = .staticValue(.signalingNaN)
        case "$sSf8infinitySfvgZ", "$sSd8infinitySdvgZ":
            self = .staticValue(.infinity)
        case "$sSf2piSfvgZ", "$sSd2piSdvgZ": self = .staticValue(.pi)
        case "$sSf23greatestFiniteMagnitudeSfvgZ",
             "$sSd23greatestFiniteMagnitudeSdvgZ":
            self = .staticValue(.greatestFiniteMagnitude)
        case "$sSf20leastNormalMagnitudeSfvgZ", "$sSd20leastNormalMagnitudeSdvgZ":
            self = .staticValue(.leastNormalMagnitude)
        case "$sSf21leastNonzeroMagnitudeSfvgZ", "$sSd21leastNonzeroMagnitudeSdvgZ":
            self = .staticValue(.leastNonzeroMagnitude)
        case "$sSf8ulpOfOneSfvgZ", "$sSd8ulpOfOneSdvgZ":
            self = .staticValue(.ulpOfOne)

        case "$sSf9magnitudeSfvg", "$sSd9magnitudeSdvg":
            self = .floatingUnary(.absolute)
        case "$sSf3ulpSfvg", "$sSd3ulpSdvg": self = .floatingUnary(.ulp)
        case "$sSf6nextUpSfvg", "$sSd6nextUpSdvg": self = .floatingUnary(.nextUp)
        case "$sSf6binadeSfvg", "$sSd6binadeSdvg": self = .floatingUnary(.binade)
        case "$sSf11significandSfvg", "$sSd11significandSdvg":
            self = .floatingUnary(.significand)
        case "$sSFsE10squareRootxyF", "$sSo19_stdlib_squareRootfyS2fFTo",
             "$sSo18_stdlib_squareRootyS2dFTo":
            self = .floatingUnary(.squareRoot)
        case "$sSFsE7roundedxyF": self = .floatingRoundDefault
        case "$sSFsE7roundedyxs25FloatingPointRoundingRuleOF":
            self = .floatingRoundRule
        case "$sSf14_roundSlowPathyys25FloatingPointRoundingRuleOF",
             "$sSd14_roundSlowPathyys25FloatingPointRoundingRuleOF":
            self = .floatingRoundSlowPath

        case "$sSf8isFiniteSbvg", "$sSd8isFiniteSbvg":
            self = .floatingPredicate(.isFinite)
        case "$sSf10isInfiniteSbvg", "$sSd10isInfiniteSbvg":
            self = .floatingPredicate(.isInfinite)
        case "$sSf5isNaNSbvg", "$sSd5isNaNSbvg":
            self = .floatingPredicate(.isNaN)
        case "$sSf14isSignalingNaNSbvg", "$sSd14isSignalingNaNSbvg":
            self = .floatingPredicate(.isSignalingNaN)
        case "$sSf8isNormalSbvg", "$sSd8isNormalSbvg":
            self = .floatingPredicate(.isNormal)
        case "$sSf11isSubnormalSbvg", "$sSd11isSubnormalSbvg":
            self = .floatingPredicate(.isSubnormal)
        case "$sSf6isZeroSbvg", "$sSd6isZeroSbvg":
            self = .floatingPredicate(.isZero)
        case "$sSf4signs17FloatingPointSignOvg", "$sSd4signs17FloatingPointSignOvg":
            self = .floatingSign

        case "$sSzsE10isMultiple2ofSbx_tF",
             "$sSZss17FixedWidthIntegerRzrlE10isMultiple2ofSbx_tF",
             "$sSUss17FixedWidthIntegerRzrlE10isMultiple2ofSbx_tF":
            self = .integerIsMultiple
        case "$sSzsE20quotientAndRemainder10dividingByx0A0_x9remaindertx_tF":
            self = .integerQuotientAndRemainder
        default:
            guard Self.hasConcreteIntegerReceiver(mangledName) else { return nil }
            if mangledName.contains("8bitWidth") {
                self = .staticValue(.bitWidth)
            } else if mangledName.contains("9magnitude") {
                self = .integerUnary(.magnitude)
            } else if mangledName.contains("15nonzeroBitCount") {
                self = .integerUnary(.nonzeroBitCount)
            } else if mangledName.contains("19leadingZeroBitCount") {
                self = .integerUnary(.leadingZeroBitCount)
            } else if mangledName.contains("20trailingZeroBitCount") {
                self = .integerUnary(.trailingZeroBitCount)
            } else if mangledName.contains("11byteSwapped") {
                self = .integerUnary(.byteSwapped)
            } else if mangledName.contains("6signum") {
                self = .integerUnary(.signum)
            } else if mangledName.contains("23addingReportingOverflow") {
                self = .integerReportingOverflow(.add)
            } else if mangledName.contains("28subtractingReportingOverflow") {
                self = .integerReportingOverflow(.subtract)
            } else if mangledName.contains("27multipliedReportingOverflow") {
                self = .integerReportingOverflow(.multiply)
            } else if mangledName.contains("24dividedReportingOverflow") {
                self = .integerReportingOverflow(.divide)
            } else if mangledName.contains("26remainderReportingOverflow") {
                self = .integerReportingOverflow(.remainder)
            } else {
                return nil
            }
        }
    }

    private static func hasConcreteIntegerReceiver(_ mangledName: String) -> Bool {
        [
            "$sSi", "$sSu", "$ss4Int8V", "$ss5UInt8V", "$ss5Int16V",
            "$ss6UInt16V", "$ss5Int32V", "$ss6UInt32V", "$ss5Int64V",
            "$ss6UInt64V",
        ].contains { mangledName.hasPrefix($0) }
    }
}
}
