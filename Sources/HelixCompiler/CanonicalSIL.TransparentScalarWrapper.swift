import HelixBytecode

extension CanonicalSIL {
enum TransparentScalarWrapper {
    struct Descriptor: Equatable, Sendable {
        var valueType: Bytecode.ValueType
        var fieldNames: Set<String>
    }

    static func descriptor(
        for rawType: String,
        resolve: (String) throws -> Bytecode.ValueType
    ) throws -> Descriptor? {
        let type = rawType.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "$" })
        let identity = String(type)
        let fieldNames: Set<String>
        switch identity {
        case "Int", "Swift.Int",
             "Int8", "Swift.Int8",
             "Int16", "Swift.Int16",
             "Int32", "Swift.Int32",
             "Int64", "Swift.Int64",
             "UInt", "Swift.UInt",
             "UInt8", "Swift.UInt8",
             "UInt16", "Swift.UInt16",
             "UInt32", "Swift.UInt32",
             "UInt64", "Swift.UInt64",
             "Bool", "Swift.Bool",
             "Float", "Swift.Float",
             "Double", "Swift.Double":
            fieldNames = ["_value"]
        case "CGFloat", "CoreFoundation.CGFloat", "CoreGraphics.CGFloat":
            // Swift toolchains have used both spellings for CGFloat's single
            // stored scalar while keeping the same transparent representation.
            fieldNames = ["native", "_value"]
        default:
            return nil
        }

        let valueType = try resolve(identity)
        switch valueType {
        case .bool, .integer, .float:
            return .init(valueType: valueType, fieldNames: fieldNames)
        default:
            throw CanonicalSIL.LoweringError.malformedSIL(
                "transparent scalar wrapper has a non-scalar representation"
            )
        }
    }
}
}
