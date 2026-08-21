import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift scalar text conversion semantics")
struct ScalarTextConversionSemanticsMatrix {
    @Test("Frontend ABI variants converge on one scalar text classifier")
    func classifiesFrontendEntryPoints() {
        typealias Intrinsic = CanonicalSIL.ScalarTextIntrinsic
        let cases: [(String, Intrinsic)] = [
            (
                "$ss17FixedWidthIntegerPsEyxSgSScfC",
                .parse(
                    .init(
                        target: .genericInteger,
                        source: .ownedString,
                        radix: .decimal,
                        hasIndirectResult: true
                    )
                )
            ),
            (
                "$ss17FixedWidthIntegerPsE_5radixxSgqd___SitcSyRd__lufC",
                .parse(
                    .init(
                        target: .genericInteger,
                        source: .stringProtocolAddress,
                        radix: .argument,
                        hasIndirectResult: true
                    )
                )
            ),
            (
                "$sSfySfSgxcSyRzlufC",
                .parse(
                    .init(
                        target: .fixed(.float(bitWidth: 32)),
                        source: .stringProtocolAddress,
                        radix: .none,
                        hasIndirectResult: false
                    )
                )
            ),
            (
                "$sSdySdSgSscfC",
                .parse(
                    .init(
                        target: .fixed(.float(bitWidth: 64)),
                        source: .ownedSubstring,
                        radix: .none,
                        hasIndirectResult: false
                    )
                )
            ),
            (
                "$sSbySbSgSScfC",
                .parse(
                    .init(
                        target: .fixed(.bool),
                        source: .ownedString,
                        radix: .none,
                        hasIndirectResult: false
                    )
                )
            ),
            (
                "$sSS_5radix9uppercaseSSx_SiSbtcSzRzlufC",
                .integerToString
            ),
            (
                "$ss17FixedWidthIntegerPsE_5radixxSgqd___SitcSyRd__lufcfA0_",
                .defaultIntegerRadix
            ),
            (
                "$sSS_5radix9uppercaseSSx_SiSbtcSzRzlufcfA1_",
                .defaultUppercase
            ),
        ]

        for (symbol, expected) in cases {
            #expect(CanonicalSIL.ScalarTextIntrinsic(mangledName: symbol) == expected)
            #expect(
                CanonicalSIL.SwiftCoreIntrinsic(mangledName: symbol)
                    == .scalarText(expected)
            )
        }
    }

    @Test("Integer String and Substring initializers preserve width, sign, and radix")
    func parsesIntegerFamilies() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func parseIntegerFamilies(
                _ decimal: String,
                _ digits: Substring,
                _ radix: Int
            ) -> (Int8?, UInt8?, Int32?, UInt64?, Int?, UInt8?, Int?, Int?) {
                (
                    Int8(decimal),
                    UInt8(decimal),
                    Int32(decimal),
                    UInt64(decimal),
                    Int(digits),
                    UInt8(digits, radix: radix),
                    Int(digits, radix: radix),
                    Int(decimal, radix: radix)
                )
            }
            """,
            functionName: "parseIntegerFamilies",
            moduleName: "HelixIntegerTextParsing"
        )

        #expect(
            invoke(
                fixture,
                arguments: [
                    .string("-128"), characters("ff"), try signed(16),
                ]
            ) == .returned(.tuple([
                .optional(try signed(-128, width: 8)),
                .optional(nil),
                .optional(try signed(-128, width: 32)),
                .optional(nil),
                .optional(nil),
                .optional(try unsigned(255, width: 8)),
                .optional(try signed(255)),
                .optional(try signed(-296)),
            ]))
        )
        #expect(
            invoke(
                fixture,
                arguments: [
                    .string("256"), characters("100"), try signed(16),
                ]
            ) == .returned(.tuple([
                .optional(nil),
                .optional(nil),
                .optional(try signed(256, width: 32)),
                .optional(try unsigned(256)),
                .optional(try signed(100)),
                .optional(nil),
                .optional(try signed(256)),
                .optional(try signed(598)),
            ]))
        )
        #expect(
            invoke(
                fixture,
                arguments: [
                    .string(" 1"), characters("0x10"), try signed(16),
                ]
            ) == .returned(.tuple(Array(repeating: .optional(nil), count: 8)))
        )

        let disassembly = Bytecode.Disassembler.disassemble(fixture.image.module)
        #expect(disassembly.contains("scalar_from_string"))
        #expect(disassembly.contains("string_join.character"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Floating and Bool parsing retain special values and strict spelling")
    func parsesFloatingAndBooleanFamilies() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func parseFloatingAndBooleanFamilies(
                _ text: String,
                _ segment: Substring,
                _ flag: String
            ) -> (UInt32?, UInt64?, UInt32?, UInt64?, Bool?) {
                (
                    Float(text)?.bitPattern,
                    Double(text)?.bitPattern,
                    Float(segment)?.bitPattern,
                    Double(segment)?.bitPattern,
                    Bool(flag)
                )
            }
            """,
            functionName: "parseFloatingAndBooleanFamilies",
            moduleName: "HelixFloatingTextParsing"
        )

        for (text, segment, flag) in [
            ("0x1p2", "-0.0", "true"),
            ("infinity", "NaN", "True"),
            (" 1", "1 ", "false"),
        ] {
            let expected = VM.Value.tuple([
                .optional(try Float(text).map { try unsigned(UInt64($0.bitPattern), width: 32) }),
                .optional(try Double(text).map { try unsigned($0.bitPattern) }),
                .optional(try Float(segment[...]).map {
                    try unsigned(UInt64($0.bitPattern), width: 32)
                }),
                .optional(try Double(segment[...]).map {
                    try unsigned($0.bitPattern)
                }),
                .optional(Bool(flag).map(VM.Value.bool)),
            ])
            #expect(
                invoke(
                    fixture,
                    arguments: [
                        .string(text), characters(segment), .string(flag),
                    ]
                ) == .returned(expected)
            )
        }

        let disassembly = Bytecode.Disassembler.disassemble(fixture.image.module)
        #expect(disassembly.contains("scalar_from_string"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("BinaryInteger formatting shares one verified radix primitive")
    func formatsIntegerFamilies() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            public func formatIntegerFamilies(
                _ signed: Int8,
                _ unsigned: UInt64,
                _ radix: Int,
                _ uppercase: Bool
            ) -> (String, String, String) {
                (
                    String(signed, radix: radix, uppercase: uppercase),
                    String(unsigned, radix: radix),
                    String(signed)
                )
            }
            """,
            functionName: "formatIntegerFamilies",
            moduleName: "HelixIntegerTextFormatting"
        )

        for (signedInput, unsignedInput, radix, uppercase) in [
            (Int8(-127), UInt64.max, 16, true),
            (Int8.min, UInt64(255), 2, false),
            (Int8.max, UInt64(35), 36, true),
        ] {
            #expect(
                invoke(
                    fixture,
                    arguments: [
                        try signed(Int64(signedInput), width: 8),
                        try unsigned(unsignedInput),
                        try signed(Int64(radix)),
                        .bool(uppercase),
                    ]
                ) == .returned(.tuple([
                    .string(
                        String(
                            signedInput,
                            radix: radix,
                            uppercase: uppercase
                        )
                    ),
                    .string(String(unsignedInput, radix: radix)),
                    .string(String(signedInput)),
                ]))
            )
        }

        let disassembly = Bytecode.Disassembler.disassemble(fixture.image.module)
        #expect(disassembly.contains("integer_to_string"))
        #expect(disassembly.contains("stringify"))
        #expect(!disassembly.contains("native_apply"))
    }

    @Test("Invalid runtime radices preserve Swift's precondition as a VM trap")
    func invalidRadicesTrap() throws {
        let parsing = try FrontendExecutionHarness.compile(
            source: """
            public func parseRadix(_ text: String, _ radix: Int) -> Int? {
                Int(text, radix: radix)
            }
            """,
            functionName: "parseRadix",
            moduleName: "HelixInvalidParseRadix"
        )
        let formatting = try FrontendExecutionHarness.compile(
            source: """
            public func formatRadix(_ value: Int, _ radix: Int) -> String {
                String(value, radix: radix)
            }
            """,
            functionName: "formatRadix",
            moduleName: "HelixInvalidFormatRadix"
        )

        for radix in [1, 37] {
            let trap = VM.ExecutionResult.trapped(
                .explicit("Radix not in range 2...36")
            )
            #expect(
                invoke(
                    parsing,
                    arguments: [.string("1"), try signed(Int64(radix))]
                ) == trap
            )
            #expect(
                invoke(
                    formatting,
                    arguments: [try signed(1), try signed(Int64(radix))]
                ) == trap
            )
        }
    }

    private func invoke(
        _ fixture: FrontendExecutionHarness.Fixture,
        arguments: [VM.Value]
    ) -> VM.ExecutionResult {
        VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: arguments
        )
    }

    private func signed(
        _ value: Int64,
        width: UInt16 = 64
    ) throws -> VM.Value {
        .integer(
            try VM.Integer(
                signed: value,
                bitWidth: width,
                isSigned: true
            )
        )
    }

    private func unsigned(
        _ value: UInt64,
        width: UInt16 = 64
    ) throws -> VM.Value {
        .integer(
            try VM.Integer(
                rawBits: value,
                bitWidth: width,
                isSigned: false
            )
        )
    }

    private func characters(_ value: String) -> VM.Value {
        .array(value.map { .string(String($0)) }, elementType: .string)
    }
}
}
