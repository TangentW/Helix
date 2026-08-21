import HelixBytecode

extension CanonicalSIL {
/// Describes the physical Swift frontend shapes that converge on the scalar
/// text conversion primitives. Target width and signedness remain type-driven;
/// no concrete scalar specialization reaches HLBC as a distinct operation.
enum ScalarTextIntrinsic: Equatable {
    struct Parsing: Equatable {
        enum Target: Equatable {
            /// The first generic substitution identifies a FixedWidthInteger.
            case genericInteger
            /// The frontend entry point fixes the logical scalar target.
            case fixed(Bytecode.ValueType)
        }

        enum Source: Equatable {
            /// A concrete String is passed directly at +1 ownership.
            case ownedString
            /// A generic StringProtocol value is passed through an address.
            case stringProtocolAddress
            /// A concrete Substring specialization is passed directly at +1.
            case ownedSubstring
        }

        enum Radix: Equatable {
            /// Parsing has no radix parameter, as for Bool and floating point.
            case none
            /// The String-only integer initializer has an implicit radix of 10.
            case decimal
            /// A runtime Int radix follows the text argument.
            case argument
        }

        var target: Target
        var source: Source
        var radix: Radix
        var hasIndirectResult: Bool
    }

    case parse(Parsing)
    case integerToString
    case defaultIntegerRadix
    case defaultUppercase

    init?(mangledName: String) {
        switch mangledName {
        case "$ss17FixedWidthIntegerPsEyxSgSScfC":
            self = .parse(
                .init(
                    target: .genericInteger,
                    source: .ownedString,
                    radix: .decimal,
                    hasIndirectResult: true
                )
            )
        case "$ss17FixedWidthIntegerPsE_5radixxSgqd___SitcSyRd__lufC":
            self = .parse(
                .init(
                    target: .genericInteger,
                    source: .stringProtocolAddress,
                    radix: .argument,
                    hasIndirectResult: true
                )
            )
        case "$sSfySfSgxcSyRzlufC":
            self = .parse(
                .init(
                    target: .fixed(.float(bitWidth: 32)),
                    source: .stringProtocolAddress,
                    radix: .none,
                    hasIndirectResult: false
                )
            )
        case "$sSdySdSgxcSyRzlufC":
            self = .parse(
                .init(
                    target: .fixed(.float(bitWidth: 64)),
                    source: .stringProtocolAddress,
                    radix: .none,
                    hasIndirectResult: false
                )
            )
        case "$sSfySfSgSscfC":
            self = .parse(
                .init(
                    target: .fixed(.float(bitWidth: 32)),
                    source: .ownedSubstring,
                    radix: .none,
                    hasIndirectResult: false
                )
            )
        case "$sSdySdSgSscfC":
            self = .parse(
                .init(
                    target: .fixed(.float(bitWidth: 64)),
                    source: .ownedSubstring,
                    radix: .none,
                    hasIndirectResult: false
                )
            )
        case "$sSbySbSgSScfC":
            self = .parse(
                .init(
                    target: .fixed(.bool),
                    source: .ownedString,
                    radix: .none,
                    hasIndirectResult: false
                )
            )
        case "$sSS_5radix9uppercaseSSx_SiSbtcSzRzlufC":
            self = .integerToString
        case "$ss17FixedWidthIntegerPsE_5radixxSgqd___SitcSyRd__lufcfA0_":
            self = .defaultIntegerRadix
        case "$sSS_5radix9uppercaseSSx_SiSbtcSzRzlufcfA1_":
            self = .defaultUppercase
        default:
            return nil
        }
    }
}
}
