import Darwin
import HelixBytecode
import HelixCRuntimeSupport
import HelixCore
import HelixInterface
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("C ABI classification")
struct CABI {
    @Test("Only exact global Clang function USRs become C symbols")
    func functionUSRs() {
        #expect(
            FrontendReceipt.CABI.functionSymbol(
                usr: "c:@F@CACurrentMediaTime"
            ) == "CACurrentMediaTime"
        )
        #expect(
            FrontendReceipt.CABI.functionSymbol(
                usr: "c:@F@CGRectMake#I"
            ) == "CGRectMake"
        )
        #expect(FrontendReceipt.CABI.functionSymbol(usr: "c:@M@notFunction") == nil)
        #expect(FrontendReceipt.CABI.functionSymbol(usr: "c:@F@bad-name") == nil)
        #expect(FrontendReceipt.CABI.functionSymbol(usr: "c:@F@9bad") == nil)
    }

    @Test("Compiler evidence classifies reusable scalar and geometry shapes")
    func supportedShapes() {
        let scalar = FrontendReceipt.CABI.Evidence(
            moduleName: "QuartzCore",
            declarationUSR: "c:@F@CACurrentMediaTime",
            symbol: "CACurrentMediaTime",
            parameters: [],
            resultSwiftABIType: "Double",
            isVariadic: false
        )
        let scalarSignature = FrontendReceipt.CABI.physicalSignature(
            evidence: scalar,
            logicalParameterTypes: [],
            logicalResultType: .float(bitWidth: 64),
            nativeTypeKinds: [:],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(scalarSignature?.callingConvention == .c)
        #expect(scalarSignature?.parameters.isEmpty == true)
        #expect(scalarSignature?.result.encoding == "d")

        let rectID = Core.TypeID(rawValue: .sha256("CABI.CGRect"))
        let rect = FrontendReceipt.CABI.Evidence(
            moduleName: "CoreGraphics",
            declarationUSR: "c:@F@CGRectMake",
            symbol: "CGRectMake",
            parameters: (0..<4).map {
                .init(swiftABIType: "CGFloat", source: .argument(UInt16($0)))
            },
            resultSwiftABIType: "CGRect",
            isVariadic: false
        )
        let rectSignature = FrontendReceipt.CABI.physicalSignature(
            evidence: rect,
            logicalParameterTypes: Array(
                repeating: .float(bitWidth: 64),
                count: 4
            ),
            logicalResultType: .native(rectID),
            nativeTypeKinds: [rectID: .value],
            targetTriple: "arm64-apple-ios15.0-simulator"
        )
        #expect(rectSignature?.parameters.map(\.type.encoding) == [
            "d", "d", "d", "d",
        ])
        #expect(
            rectSignature?.result.encoding
                == "{CGRect={CGPoint=dd}{CGSize=dd}}"
        )
    }

    @Test("Unsupported targets, variadics, and uncataloged structures fall back")
    func unsupportedShapes() {
        let insetID = Core.TypeID(rawValue: .sha256("CABI.UIEdgeInsets"))
        let inset = FrontendReceipt.CABI.Evidence(
            moduleName: "UIKit",
            declarationUSR: "c:@F@UIEdgeInsetsMake",
            symbol: "UIEdgeInsetsMake",
            parameters: (0..<4).map {
                .init(swiftABIType: "CGFloat", source: .argument(UInt16($0)))
            },
            resultSwiftABIType: "UIEdgeInsets",
            isVariadic: false
        )
        #expect(FrontendReceipt.CABI.physicalSignature(
            evidence: inset,
            logicalParameterTypes: Array(
                repeating: .float(bitWidth: 64),
                count: 4
            ),
            logicalResultType: .native(insetID),
            nativeTypeKinds: [insetID: .value],
            targetTriple: "arm64-apple-ios15.0-simulator"
        ) == nil)

        var variadic = inset
        variadic.isVariadic = true
        #expect(FrontendReceipt.CABI.physicalSignature(
            evidence: variadic,
            logicalParameterTypes: Array(
                repeating: .float(bitWidth: 64),
                count: 4
            ),
            logicalResultType: .native(insetID),
            nativeTypeKinds: [insetID: .value],
            targetTriple: "arm64-apple-ios15.0-simulator"
        ) == nil)

        #expect(FrontendReceipt.CABI.physicalSignature(
            evidence: inset,
            logicalParameterTypes: Array(
                repeating: .float(bitWidth: 64),
                count: 4
            ),
            logicalResultType: .native(insetID),
            nativeTypeKinds: [insetID: .value],
            targetTriple: "wasm32-unknown-none"
        ) == nil)
    }

    @Test("Build-time and Runtime C ABI matrices agree")
    func trampolineMatrixParity() {
        let scalars = ["B", "c", "C", "s", "S", "i", "I", "q", "Q", "f", "d"]
        var supported: [([String], String)] = [([], "v")]
        for scalar in scalars {
            for count in 0...4 {
                let arguments = Array(repeating: scalar, count: count)
                supported.append((arguments, scalar))
                if count > 0 { supported.append((arguments, "v")) }
            }
        }
        let point = "{CGPoint=dd}"
        let size = "{CGSize=dd}"
        let vector = "{CGVector=dd}"
        let rect = "{CGRect={CGPoint=dd}{CGSize=dd}}"
        let transform = "{CGAffineTransform=dddddd}"
        supported += [
            (["d", "d"], point), (["d", "d"], size),
            (["d", "d"], vector),
            (Array(repeating: "d", count: 4), rect),
            (Array(repeating: "d", count: 6), transform),
            ([point], "d"), ([size], "d"), ([vector], "d"),
            ([rect], "d"), ([rect, point], "B"), ([rect, rect], "B"),
            ([rect, rect], rect), ([point, transform], point),
            ([size, transform], size), ([rect, transform], rect),
            ([transform, transform], transform),
        ]
        for shape in supported {
            #expect(buildSupports(shape.0, result: shape.1))
            #expect(runtimeSupports(shape.0, result: shape.1))
        }

        let unsupported: [([String], String)] = [
            (["q", "d"], "d"),
            (Array(repeating: "q", count: 5), "q"),
            (["^v"], "v"),
            (["d", "d", "d", "d"], "{UIEdgeInsets=dddd}"),
            ([rect, point], rect),
        ]
        for shape in unsupported {
            #expect(!buildSupports(shape.0, result: shape.1))
            #expect(!runtimeSupports(shape.0, result: shape.1))
        }
    }
}
}

private extension BuildToolsTests.CABI {
    func buildSupports(_ arguments: [String], result: String) -> Bool {
        FrontendReceipt.CABI.supportsTrampoline(.init(
            callingConvention: .c,
            parameters: arguments.enumerated().map {
                .init(type: abiType($0.element), source: .argument(UInt16($0.offset)))
            },
            result: result == "v" ? .void : abiType(result)
        ))
    }

    func runtimeSupports(_ arguments: [String], result: String) -> Bool {
        let storage = arguments.map { strdup($0) }
        defer { for pointer in storage { free(pointer) } }
        guard storage.allSatisfy({ $0 != nil }) else { return false }
        let pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        return result.withCString { resultPointer in
            pointers.withUnsafeBufferPointer { argumentsPointer in
                helix_runtime_c_signature_is_supported(
                    argumentsPointer.baseAddress,
                    argumentsPointer.count,
                    resultPointer
                )
            }
        }
    }

    func abiType(_ encoding: String) -> Core.NativeCall.ABIType {
        let shape: (Core.NativeCall.ABIValueKind, UInt16, UInt16) = switch encoding {
        case "B": (.boolean, 1, 1)
        case "c", "C": (
            encoding == "c" ? .signedInteger : .unsignedInteger,
            1,
            1
        )
        case "s", "S": (
            encoding == "s" ? .signedInteger : .unsignedInteger,
            2,
            2
        )
        case "i", "I": (
            encoding == "i" ? .signedInteger : .unsignedInteger,
            4,
            4
        )
        case "q", "Q": (
            encoding == "q" ? .signedInteger : .unsignedInteger,
            8,
            8
        )
        case "f": (.floatingPoint, 4, 4)
        case "d": (.floatingPoint, 8, 8)
        case "{CGPoint=dd}", "{CGSize=dd}", "{CGVector=dd}":
            (.structure, 16, 8)
        case "{CGRect={CGPoint=dd}{CGSize=dd}}": (.structure, 32, 8)
        case "{CGAffineTransform=dddddd}": (.structure, 48, 8)
        default: (.pointer, 8, 8)
        }
        return .init(
            kind: shape.0,
            canonicalName: "Fixture",
            size: shape.1,
            alignment: shape.2,
            encoding: encoding
        )
    }
}
