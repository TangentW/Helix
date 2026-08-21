import HelixBytecode
import Testing
@testable import HelixVM

extension VMTests {
@Suite("HLVM scalar text semantics")
struct ScalarText {
    @Test("Integer parsing agrees with every represented FixedWidthInteger family")
    func integerParsingMatchesSwift() throws {
        struct Target {
            var type: Bytecode.ValueType
            var expectedBits: (String, Int) -> UInt64?
        }

        let targets: [Target] = [
            .init(type: .integer(bitWidth: 8, signed: true)) {
                Int8($0, radix: $1).map { UInt64(UInt8(bitPattern: $0)) }
            },
            .init(type: .integer(bitWidth: 16, signed: true)) {
                Int16($0, radix: $1).map { UInt64(UInt16(bitPattern: $0)) }
            },
            .init(type: .integer(bitWidth: 32, signed: true)) {
                Int32($0, radix: $1).map { UInt64(UInt32(bitPattern: $0)) }
            },
            .init(type: .integer(bitWidth: 64, signed: true)) {
                Int64($0, radix: $1).map(UInt64.init(bitPattern:))
            },
            .init(type: .integer(bitWidth: 8, signed: false)) {
                UInt8($0, radix: $1).map(UInt64.init)
            },
            .init(type: .integer(bitWidth: 16, signed: false)) {
                UInt16($0, radix: $1).map(UInt64.init)
            },
            .init(type: .integer(bitWidth: 32, signed: false)) {
                UInt32($0, radix: $1).map(UInt64.init)
            },
            .init(type: .integer(bitWidth: 64, signed: false)) {
                UInt64($0, radix: $1)
            },
        ]
        let texts = [
            "", " ", "+0", "-0", "127", "128", "-128", "-129",
            "255", "256", "7f", "FF", "0xff", "1_0",
            "18446744073709551615", "9223372036854775808",
            "-9223372036854775808",
        ]

        for target in targets {
            for radix in [2, 10, 16, 36] {
                for text in texts {
                    let parsed = try VM.ScalarText.parse(
                        text,
                        as: target.type,
                        radix: radix
                    )
                    let actualBits: UInt64? = if case let .integer(value)? = parsed {
                        value.rawBits
                    } else {
                        nil
                    }
                    #expect(actualBits == target.expectedBits(text, radix))
                    if let parsed {
                        #expect(parsed.type == target.type)
                    }
                }
            }
        }
    }

    @Test("Float, Double, and Bool parsing preserve native Swift semantics")
    func floatingAndBooleanParsingMatchesSwift() throws {
        let texts = [
            "", " ", "+1", "-0.0", ".5", "1e3", "1_000", "NaN",
            "inf", "infinity", "0x1p2", "1 ",
        ]
        for text in texts {
            let float = try VM.ScalarText.parse(
                text,
                as: .float(bitWidth: 32),
                radix: nil
            )
            let double = try VM.ScalarText.parse(
                text,
                as: .float(bitWidth: 64),
                radix: nil
            )
            let floatBits: UInt32? = if case let .float(value)? = float {
                UInt32(truncatingIfNeeded: value.bitPattern)
            } else {
                nil
            }
            let doubleBits: UInt64? = if case let .float(value)? = double {
                value.bitPattern
            } else {
                nil
            }
            #expect(floatBits == Float(text)?.bitPattern)
            #expect(doubleBits == Double(text)?.bitPattern)
        }

        for text in ["true", "false", "True", "FALSE", " true", "true ", "1", ""] {
            let parsed = try VM.ScalarText.parse(text, as: .bool, radix: nil)
            let actual: Bool? = if case let .bool(value)? = parsed {
                value
            } else {
                nil
            }
            #expect(actual == Bool(text))
        }
    }

    @Test("Integer formatting is width-generic and allocation bounds are sound")
    func integerFormattingMatchesSwift() throws {
        let values = try [
            VM.Integer(signed: -128, bitWidth: 8, isSigned: true),
            VM.Integer(signed: 127, bitWidth: 8, isSigned: true),
            VM.Integer(signed: .min, bitWidth: 64, isSigned: true),
            VM.Integer(rawBits: 255, bitWidth: 8, isSigned: false),
            VM.Integer(rawBits: .max, bitWidth: 64, isSigned: false),
        ]

        for value in values {
            for radix in [2, 8, 10, 16, 36] {
                for uppercase in [false, true] {
                    let actual = try VM.ScalarText.format(
                        value,
                        radix: radix,
                        uppercase: uppercase
                    )
                    let expected = value.isSigned
                        ? String(
                            value.signedValue,
                            radix: radix,
                            uppercase: uppercase
                        )
                        : String(
                            value.unsignedValue,
                            radix: radix,
                            uppercase: uppercase
                        )
                    #expect(actual == expected)
                    #expect(
                        UInt64(actual.utf8.count)
                            <= VM.ScalarText.maximumFormattedUTF8ByteCount(
                                for: value
                            )
                    )
                }
            }
        }
    }

    @Test("Invalid radices trap before entering native Swift preconditions")
    func invalidRadicesFailClosed() throws {
        let signed64 = try VM.Integer(
            signed: 1,
            bitWidth: 64,
            isSigned: true
        )
        for radix in [1, 37, Int.min, Int.max] {
            #expect(
                throws: VM.RuntimeTrap.explicit(
                    VM.ScalarText.invalidRadixMessage
                )
            ) {
                _ = try VM.ScalarText.parse(
                    "1",
                    as: .int64,
                    radix: radix
                )
            }
            #expect(
                throws: VM.RuntimeTrap.explicit(
                    VM.ScalarText.invalidRadixMessage
                )
            ) {
                _ = try VM.ScalarText.format(
                    signed64,
                    radix: radix,
                    uppercase: false
                )
            }
        }

        let unsigned64 = try VM.Integer(
            rawBits: 10,
            bitWidth: 64,
            isSigned: false
        )
        #expect(
            throws: VM.RuntimeTrap.explicit(
                VM.ScalarText.invalidRadixMessage
            )
        ) {
            _ = try VM.ScalarText.radix(from: unsigned64)
        }
    }
}
}
