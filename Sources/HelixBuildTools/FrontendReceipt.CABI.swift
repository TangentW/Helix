import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

extension FrontendReceipt {
/// Compiler evidence and target-specific classification for reusable C AOT
/// trampolines. This classifies ABI shapes, never an API allowlist.
enum CABI {}
}

extension FrontendReceipt.CABI {
struct Parameter: Codable, Hashable, Sendable {
    var swiftABIType: String
    var source: Core.NativeCall.ArgumentSource
}

struct Evidence: Codable, Hashable, Sendable {
    var moduleName: String?
    var declarationUSR: String
    var symbol: String
    var parameters: [Parameter]
    var resultSwiftABIType: String
    var isVariadic: Bool
}

static func functionSymbol(usr: String) -> String? {
    let prefix = "c:@F@"
    guard usr.hasPrefix(prefix) else { return nil }
    let suffix = usr.dropFirst(prefix.count)
    let symbol = String(suffix.prefix { $0 != "#" && $0 != "@" })
    guard !symbol.isEmpty, symbol.utf8.count <= 1_024,
          let first = symbol.utf8.first,
          (first == 0x5f || first >= 0x41 && first <= 0x5a
              || first >= 0x61 && first <= 0x7a),
          symbol.utf8.dropFirst().allSatisfy({
              $0 == 0x5f || $0 >= 0x41 && $0 <= 0x5a
                  || $0 >= 0x61 && $0 <= 0x7a
                  || $0 >= 0x30 && $0 <= 0x39
          })
    else { return nil }
    return symbol
}

static func evidence(
    usr: String,
    dispatch: NativeImportDiscovery.Dispatch,
    physicalParameterSwiftTypes: [String],
    physicalResultSwiftType: String,
    projection: InterfaceArchive.NativeImportParameterProjection,
    loweredType: String
) -> Evidence? {
    guard dispatch == .globalFunction,
          let symbol = functionSymbol(usr: usr),
          projection.defaultArguments.isEmpty,
          projection.physicalParameterCount
            == UInt16(exactly: physicalParameterSwiftTypes.count),
          projection.logicalParameterIndices
            == physicalParameterSwiftTypes.indices.compactMap({
                UInt16(exactly: $0)
            }),
          !loweredType.contains("CVarArg"),
          !loweredType.contains("..."),
          !physicalResultSwiftType.isEmpty
    else { return nil }
    return .init(
        moduleName: nil,
        declarationUSR: usr,
        symbol: symbol,
        parameters: physicalParameterSwiftTypes.enumerated().map {
            .init(swiftABIType: $0.element, source: .argument(UInt16($0.offset)))
        },
        resultSwiftABIType: physicalResultSwiftType,
        isVariadic: false
    )
}

static func physicalSignature(
    evidence: Evidence,
    logicalParameterTypes: [Bytecode.ValueType],
    logicalResultType: Bytecode.ValueType,
    nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind],
    targetTriple: String
) -> Core.NativeCall.PhysicalSignature? {
    guard evidence.moduleName?.isEmpty == false,
          !evidence.isVariadic,
          FrontendReceipt.ObjectiveCABI.supports64BitAppleTarget(
              targetTriple
          ),
          evidence.parameters.count == logicalParameterTypes.count,
          evidence.parameters.count <= 6
    else { return nil }
    var parameters: [Core.NativeCall.ABIParameter] = []
    for (index, parameter) in evidence.parameters.enumerated() {
        guard parameter.source == .argument(UInt16(index)),
              let type = abiType(
                  swiftABIType: parameter.swiftABIType,
                  logicalType: logicalParameterTypes[index],
                  nativeTypeKinds: nativeTypeKinds,
                  targetTriple: targetTriple
              )
        else { return nil }
        parameters.append(.init(type: type, source: parameter.source))
    }
    let result: Core.NativeCall.ABIType
    if logicalResultType == .void {
        guard isVoid(evidence.resultSwiftABIType) else { return nil }
        result = .void
    } else {
        guard let type = abiType(
            swiftABIType: evidence.resultSwiftABIType,
            logicalType: logicalResultType,
            nativeTypeKinds: nativeTypeKinds,
            targetTriple: targetTriple
        ) else { return nil }
        result = type
    }
    let signature = Core.NativeCall.PhysicalSignature(
        callingConvention: .c,
        parameters: parameters,
        result: result
    )
    return supportsTrampoline(signature) ? signature : nil
}

static func supportsTrampoline(
    _ signature: Core.NativeCall.PhysicalSignature
) -> Bool {
    let arguments = signature.parameters.compactMap(\.type.encoding)
    guard arguments.count == signature.parameters.count,
          let result = signature.result.encoding ?? (
              signature.result.kind == .void ? "v" : nil
          ),
          arguments.count <= 6
    else { return false }
    if arguments.isEmpty, result == "v" { return true }
    let scalars = ["B", "c", "C", "s", "S", "i", "I", "q", "Q", "f", "d"]
    if arguments.count <= 4,
       scalars.contains(where: { encoding in
           arguments.allSatisfy { $0 == encoding }
               && (result == encoding || result == "v")
       }) {
        return true
    }
    let point = "{CGPoint=dd}"
    let size = "{CGSize=dd}"
    let vector = "{CGVector=dd}"
    let rect = "{CGRect={CGPoint=dd}{CGSize=dd}}"
    let transform = "{CGAffineTransform=dddddd}"
    if arguments == ["d", "d"], [point, size, vector].contains(result) {
        return true
    }
    if arguments == ["d", "d", "d", "d"], result == rect { return true }
    if arguments == Array(repeating: "d", count: 6), result == transform {
        return true
    }
    if arguments.count == 1, result == "d",
       [point, size, vector, rect].contains(arguments[0]) {
        return true
    }
    if arguments == [rect, point] || arguments == [rect, rect] {
        return result == "B"
            || (arguments == [rect, rect] && result == rect)
    }
    if arguments.count == 2, arguments[1] == transform,
       [(point, point), (size, size), (rect, rect)].contains(where: {
           arguments[0] == $0.0 && result == $0.1
       }) {
        return true
    }
    return arguments == [transform, transform] && result == transform
}
}

private extension FrontendReceipt.CABI {
static func abiType(
    swiftABIType: String,
    logicalType: Bytecode.ValueType,
    nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind],
    targetTriple: String
) -> Core.NativeCall.ABIType? {
    if let scalar = FrontendReceipt.ObjectiveCABI.scalarType(
        swiftABIType: swiftABIType,
        targetTriple: targetTriple
    ) {
        switch (scalar.kind, logicalType) {
        case (.boolean, .bool):
            return scalar
        case let (.signedInteger, .integer(width, signed)),
             let (.unsignedInteger, .integer(width, signed)):
            return width == scalar.size! * 8
                    && signed == (scalar.kind == .signedInteger)
                ? scalar : nil
        case let (.floatingPoint, .float(width)):
            return width == scalar.size! * 8 ? scalar : nil
        default:
            return nil
        }
    }
    guard let structure = FrontendReceipt.ObjectiveCABI.structureType(
        swiftABIType: swiftABIType,
        targetTriple: targetTriple
    ), case let .native(id) = logicalType,
       nativeTypeKinds[id].map({ $0 != .reference }) == true
    else { return nil }
    return structure
}

static func isVoid(_ raw: String) -> Bool {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var changed = true
    while changed {
        changed = false
        for prefix in ["$", "@out ", "@owned ", "@unowned "]
        where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            changed = true
            break
        }
    }
    return value == "()" || value == "Void" || value == "Swift.Void"
}
}
