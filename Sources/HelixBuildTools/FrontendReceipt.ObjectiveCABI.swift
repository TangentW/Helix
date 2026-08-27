import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

extension FrontendReceipt {
/// Compiler evidence and target-specific classification for the reusable
/// Objective-C invocation boundary.
enum ObjectiveCABI {}
}

extension FrontendReceipt.ObjectiveCABI {
struct Parameter: Codable, Hashable, Sendable {
    var swiftABIType: String
    var source: Core.NativeCall.ArgumentSource
}

struct Evidence: Codable, Hashable, Sendable {
    /// Exact declaring module. A Clang USR proves the runtime class and
    /// selector, while Catalog lookup proves which imported module declares it.
    var moduleName: String?
    /// Exact Clang declaration identity used to resolve category methods and
    /// properties to their declaring module without class-name inference.
    var declarationUSR: String
    /// Declaration class that authorizes the selector and ABI.
    var runtimeClassName: String
    /// Exact class-message receiver or initializer allocation class. Instance
    /// calls obtain their target from the verified logical receiver.
    var dispatchClassName: String? = nil
    var selector: String
    /// Methods carry their selector in the Clang USR. Property accessors are
    /// exact only after a compiler-generated `#selector` probe resolves the
    /// property's possibly custom getter or setter.
    var selectorIsExact: Bool = true
    var lexicalSuperclassName: String?
    var methodFamily: Core.NativeCall.ObjectiveCMethodFamily
    var property: Core.NativeCall.ObjectiveCProperty?
    var parameters: [Parameter]
    var resultSwiftABIType: String
    var resultConvention: Core.NativeCall.ABIConvention
    var errorConvention: Core.NativeCall.ErrorConvention
    var errorFailure: Core.NativeCall.ObjectiveCErrorFailure?
}

struct MethodIdentity: Hashable, Sendable {
    var runtimeClassName: String
    var selector: String
    var isClassMethod: Bool
}

struct PropertyIdentity: Hashable, Sendable {
    var runtimeClassName: String
    var name: String
    var isClassProperty: Bool
}

struct PropertySelector: Hashable, Sendable {
    var declarationUSR: String
    var accessor: Core.NativeCall.ObjectiveCPropertyAccessor
    var selector: String
}

static func propertySelectors(
    in root: FrontendReceipt.TypedAST.Object
) -> Set<PropertySelector> {
    var result = Set<PropertySelector>()

    func visit(_ value: Any) {
        if let object = value as? FrontendReceipt.TypedAST.Object {
            if object["_kind"] as? String == "objc_selector_expr",
               let rawAccessor = object["kind"] as? String,
               let accessor = Core.NativeCall.ObjectiveCPropertyAccessor(
                    rawValue: rawAccessor
               ),
               let methodDeclaration = object["decl"] as?
                    FrontendReceipt.TypedAST.Object,
               let methodUSR = methodDeclaration["decl_usr"] as? String,
               let method = methodIdentity(usr: methodUSR),
               let subexpression = object["sub_expr"] as?
                    FrontendReceipt.TypedAST.Object,
               let propertyUSR = propertyUSR(in: subexpression),
               let property = propertyIdentity(usr: propertyUSR),
               property.runtimeClassName == method.runtimeClassName,
               property.isClassProperty == method.isClassMethod,
               method.selector.filter({ $0 == ":" }).count
                    == (accessor == .setter ? 1 : 0) {
                result.insert(.init(
                    declarationUSR: propertyUSR,
                    accessor: accessor,
                    selector: method.selector
                ))
            }
            for child in object.values { visit(child) }
        } else if let values = value as? [Any] {
            for child in values { visit(child) }
        }
    }

    visit(root)
    return result
}

static func methodIdentity(usr: String) -> MethodIdentity? {
    let prefix = "c:objc(cs)"
    guard usr.hasPrefix(prefix) else { return nil }
    let bodyStart = usr.index(usr.startIndex, offsetBy: prefix.count)
    let body = usr[bodyStart...]
    let candidates = ["(im)", "(cm)"].compactMap { marker in
        body.range(of: marker).map { (marker, $0) }
    }
    guard candidates.count == 1, let candidate = candidates.first else {
        return nil
    }
    let owner = String(body[..<candidate.1.lowerBound])
    let selector = String(body[candidate.1.upperBound...])
    guard !owner.isEmpty, !selector.isEmpty else { return nil }
    return .init(
        runtimeClassName: owner,
        selector: selector,
        isClassMethod: candidate.0 == "(cm)"
    )
}

static func propertyIdentity(usr: String) -> PropertyIdentity? {
    let prefix = "c:objc(cs)"
    guard usr.hasPrefix(prefix),
          let marker = usr.range(of: "(py)") ?? usr.range(of: "(cpy)")
    else { return nil }
    let ownerStart = usr.index(usr.startIndex, offsetBy: prefix.count)
    let owner = String(usr[ownerStart..<marker.lowerBound])
    let name = String(usr[marker.upperBound...])
    guard !owner.isEmpty, !name.isEmpty else { return nil }
    return .init(
        runtimeClassName: owner,
        name: name,
        isClassProperty: usr[marker.lowerBound...].hasPrefix("(cpy)")
    )
}

static func moduleName(
    ownerType: String,
    importedModules: [String]
) -> String? {
    let modules = Array(Set(importedModules)).sorted()
    let components = ownerType.split(separator: ".").map(String.init)
    if components.count > 1, let qualifier = components.first,
       modules.contains(qualifier) {
        return qualifier
    }
    return nil
}

static func methodFamily(
    selector: String,
    dispatch: Core.NativeCall.Dispatch,
    resultSwiftABIType: String? = nil
) -> Core.NativeCall.ObjectiveCMethodFamily {
    if dispatch == .initializer { return .initializer }
    guard let inferred = namedMethodFamily(selector: selector),
          inferred != .initializer
    else { return .none }
    guard let resultSwiftABIType else { return inferred }
    let rawResult = resultSwiftABIType.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let result = strippingOwnership(rawResult)
    let (physical, _) = unwrapOptional(result)
    return isObjectiveCObjectSpelling(physical)
            && rawResult.contains("@owned ")
        ? inferred : .none
}

static func resultConvention(
    swiftABIType: String,
    methodFamily: Core.NativeCall.ObjectiveCMethodFamily
) -> Core.NativeCall.ABIConvention {
    if methodFamily != .none { return .directOwned }
    let value = swiftABIType.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.contains("@autoreleased ") { return .autoreleased }
    if value.contains("@owned ") { return .directOwned }
    if value.contains("@unowned ") { return .directUnowned }
    return .direct
}

static func defaultPropertySelector(
    name: String,
    accessor: Core.NativeCall.ObjectiveCPropertyAccessor,
    importedBaseName: String
) -> String? {
    switch accessor {
    case .getter:
        let booleanPropertyName: String? = if importedBaseName.hasPrefix("is"),
                                              importedBaseName.count > 2 {
            String(importedBaseName.dropFirst(2).prefix(1)).lowercased()
                + String(importedBaseName.dropFirst(3))
        } else {
            nil
        }
        guard importedBaseName == name || booleanPropertyName == name else {
            return nil
        }
        return importedBaseName
    case .setter:
        guard let first = name.first else { return nil }
        return "set\(String(first).uppercased())\(name.dropFirst()):"
    }
}

/// Supplies only an arity-correct placeholder until a compiler `#selector`
/// probe proves the accessor. A custom getter need not resemble either the
/// Objective-C property name or its imported Swift spelling, so failure to
/// derive a conventional name must not discard the property evidence.
static func propertySelectorProbeSeed(
    name: String,
    accessor: Core.NativeCall.ObjectiveCPropertyAccessor,
    importedBaseName: String
) -> String? {
    if let conventional = defaultPropertySelector(
        name: name,
        accessor: accessor,
        importedBaseName: importedBaseName
    ) {
        return conventional
    }
    return accessor == .getter && !name.isEmpty ? name : nil
}

static func physicalSignature(
    evidence: Evidence,
    logicalParameterTypes: [Bytecode.ValueType],
    logicalResultType: Bytecode.ValueType,
    nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind],
    targetTriple: String
) -> Core.NativeCall.PhysicalSignature? {
    guard evidence.moduleName?.isEmpty == false,
          evidence.selectorIsExact,
          isSupported64BitAppleTarget(targetTriple),
          evidence.parameters.count <= 256
    else { return nil }
    var parameters: [Core.NativeCall.ABIParameter] = []
    parameters.reserveCapacity(evidence.parameters.count)
    for parameter in evidence.parameters {
        let logicalType: Bytecode.ValueType?
        switch parameter.source.kind {
        case .argument:
            guard let index = parameter.source.logicalArgumentIndex,
                  logicalParameterTypes.indices.contains(Int(index))
            else { return nil }
            logicalType = logicalParameterTypes[Int(index)]
        case .optionalNone:
            logicalType = nil
        case .errorOut:
            guard evidence.errorConvention == .nsErrorOut else { return nil }
            parameters.append(.init(
                type: .init(
                    kind: .pointer,
                    canonicalName: "Foundation.NSErrorPointer",
                    encoding: "^@",
                    isNullable: true
                ),
                convention: .indirectOut,
                source: .errorOut
            ))
            continue
        case .defaultGenerator:
            return nil
        }
        guard let type = abiType(
            swiftABIType: parameter.swiftABIType,
            logicalType: logicalType,
            nativeTypeKinds: nativeTypeKinds,
            targetTriple: targetTriple,
            allowsImplicitNil: parameter.source.kind == .optionalNone,
            allowsSwiftAnyErasure: true
        ) else { return nil }
        let ownership: Core.NativeCall.Ownership = if
            parameter.source.kind == .argument,
            let index = parameter.source.logicalArgumentIndex,
            logicalParameterTypes[Int(index)].directClosureShape != nil {
            parameter.swiftABIType.contains("@noescape") ? .borrowed : .owned
        } else {
            .owned
        }
        parameters.append(.init(
            type: type,
            ownership: ownership,
            convention: .direct,
            source: parameter.source
        ))
    }

    let result: Core.NativeCall.ABIType
    if evidence.errorConvention == .nsErrorOut,
       logicalResultType == .void {
        guard let physical = abiType(
            swiftABIType: evidence.resultSwiftABIType,
            logicalType: .bool,
            nativeTypeKinds: nativeTypeKinds,
            targetTriple: targetTriple,
            allowsImplicitNil: false,
            allowsSwiftAnyErasure: false
        ), physical.kind == .boolean else { return nil }
        result = physical
    } else if logicalResultType == .void {
        guard strippingOwnership(evidence.resultSwiftABIType) == "()" else {
            return nil
        }
        result = .void
    } else {
        guard let physical = abiType(
            swiftABIType: evidence.resultSwiftABIType,
            logicalType: logicalResultType,
            nativeTypeKinds: nativeTypeKinds,
            targetTriple: targetTriple,
            allowsImplicitNil: false,
            allowsSwiftAnyErasure: false
        ), physical.kind != .block else { return nil }
        // Native Blocks returned by Objective-C require a VM-backed callable
        // wrapper with independent lifetime and invocation metadata. Until that
        // boundary exists, retain the exact Swift Adapter instead of exposing a
        // descriptor the generic invoker cannot execute.
        result = physical
    }
    if result.kind == .object,
       let namedFamily = namedMethodFamily(selector: evidence.selector),
       evidence.methodFamily != namedFamily {
        // Ownership attributes can explicitly cancel a selector-derived ARC
        // family. The SIL result convention is authoritative; preserve the
        // exact Swift adapter instead of pretending that result is +1.
        return nil
    }
    return .init(
        callingConvention: .objectiveC,
        parameters: parameters,
        result: result,
        resultConvention: evidence.resultConvention,
        errorConvention: evidence.errorConvention
    )
}

static func structureType(
    swiftABIType raw: String,
    targetTriple: String
) -> Core.NativeCall.ABIType? {
    guard isSupported64BitAppleTarget(targetTriple) else { return nil }
    let stripped = strippingOwnership(raw)
    let (physical, optional) = unwrapOptional(stripped)
    guard !optional, let structure = structure(named: physical) else {
        return nil
    }
    return .init(
        kind: .structure,
        canonicalName: canonicalPhysicalName(physical),
        size: structure.size,
        alignment: structure.alignment,
        encoding: structure.encoding
    )
}

static func scalarType(
    swiftABIType raw: String,
    targetTriple: String
) -> Core.NativeCall.ABIType? {
    let stripped = strippingOwnership(raw)
    let (physical, optional) = unwrapOptional(stripped)
    guard !optional, let scalar = scalar(
        named: physical,
        targetTriple: targetTriple
    ) else { return nil }
    return .init(
        kind: scalar.kind,
        canonicalName: canonicalPhysicalName(physical),
        size: scalar.size,
        alignment: scalar.alignment,
        encoding: scalar.encoding
    )
}

static func supports64BitAppleTarget(_ target: String) -> Bool {
    isSupported64BitAppleTarget(target)
}
}

private extension FrontendReceipt.ObjectiveCABI {
    static func namedMethodFamily(
        selector: String
    ) -> Core.NativeCall.ObjectiveCMethodFamily? {
        func belongs(to prefix: String) -> Bool {
            let normalized = selector.drop(while: { $0 == "_" })
            guard normalized.hasPrefix(prefix) else { return false }
            let suffix = normalized.dropFirst(prefix.count)
            guard let first = suffix.first else { return true }
            return !first.isLowercase
        }
        if belongs(to: "alloc") { return .alloc }
        if belongs(to: "init") { return .initializer }
        if belongs(to: "new") { return .new }
        if belongs(to: "mutableCopy") { return .mutableCopy }
        if belongs(to: "copy") { return .copy }
        return nil
    }

    static func propertyUSR(
        in object: FrontendReceipt.TypedAST.Object
    ) -> String? {
        if let declaration = object["decl"] as?
            FrontendReceipt.TypedAST.Object,
           let usr = declaration["decl_usr"] as? String,
           propertyIdentity(usr: usr) != nil {
            return usr
        }
        for child in object.values {
            if let nested = child as? FrontendReceipt.TypedAST.Object,
               let result = propertyUSR(in: nested) {
                return result
            }
            if let values = child as? [Any] {
                for value in values {
                    if let nested = value as? FrontendReceipt.TypedAST.Object,
                       let result = propertyUSR(in: nested) {
                        return result
                    }
                }
            }
        }
        return nil
    }

    struct Scalar {
        var kind: Core.NativeCall.ABIValueKind
        var size: UInt16
        var alignment: UInt16
        var encoding: String
    }

    struct Structure {
        var size: UInt16
        var alignment: UInt16
        var encoding: String
    }

    static func abiType(
        swiftABIType raw: String,
        logicalType: Bytecode.ValueType?,
        nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind],
        targetTriple: String,
        allowsImplicitNil: Bool,
        allowsSwiftAnyErasure: Bool
    ) -> Core.NativeCall.ABIType? {
        let stripped = strippingOwnership(raw)
        let (physical, physicalOptional) = unwrapOptional(stripped)
        if physical.contains("@convention(block)") {
            if logicalType == nil, allowsImplicitNil, physicalOptional {
                return .init(
                    kind: .block,
                    canonicalName: "ObjectiveC.Block",
                    encoding: "@?",
                    isNullable: true
                )
            }
            guard let shape = logicalType?.directClosureShape,
                  shape.isOptional == physicalOptional || allowsImplicitNil,
                  Bytecode.ObjectiveCBlockABI.supports(shape.signature)
            else { return nil }
            return .init(
                kind: .block,
                canonicalName: "ObjectiveC.Block",
                encoding: "@?",
                isNullable: physicalOptional || allowsImplicitNil
            )
        }
        if let scalar = scalar(
            named: physical,
            targetTriple: targetTriple
        ) {
            guard !physicalOptional,
                  scalarMatches(scalar, logicalType: logicalType)
            else { return nil }
            return .init(
                kind: scalar.kind,
                canonicalName: canonicalPhysicalName(physical),
                size: scalar.size,
                alignment: scalar.alignment,
                encoding: scalar.encoding
            )
        }
        if let structure = structure(named: physical) {
            guard !physicalOptional,
                  case let .native(id) = logicalType,
                  nativeTypeKinds[id].map({ $0 != .reference }) == true
            else { return nil }
            return .init(
                kind: .structure,
                canonicalName: canonicalPhysicalName(physical),
                size: structure.size,
                alignment: structure.alignment,
                encoding: structure.encoding
            )
        }
        guard objectMatches(
            logicalType,
            nativeTypeKinds: nativeTypeKinds,
            isNullable: physicalOptional || allowsImplicitNil,
            allowsSwiftAnyErasure: allowsSwiftAnyErasure
        ), isObjectiveCObjectSpelling(physical)
        else { return nil }
        return .init(
            kind: .object,
            canonicalName: canonicalPhysicalName(physical),
            encoding: "@",
            isNullable: physicalOptional || allowsImplicitNil
        )
    }

    static func scalar(
        named raw: String,
        targetTriple: String
    ) -> Scalar? {
        let name = leafName(raw)
        switch name {
        case "Bool", "ObjCBool", "BOOL":
            return .init(
                kind: .boolean,
                size: 1,
                alignment: 1,
                // Objective-C BOOL remains signed char only for Intel macOS
                // and Mac Catalyst. Apple Silicon and iOS-family simulator
                // targets use C99 bool even when their Swift spelling is Bool.
                encoding: targetTriple.hasPrefix("x86_64-")
                    && (targetTriple.contains("-macos")
                        || targetTriple.contains("-macabi")) ? "c" : "B"
            )
        case "Int", "Int64", "NSInteger", "CLong", "CLongLong":
            return .init(kind: .signedInteger, size: 8, alignment: 8, encoding: "q")
        case "UInt", "UInt64", "NSUInteger", "CUnsignedLong", "CUnsignedLongLong":
            return .init(kind: .unsignedInteger, size: 8, alignment: 8, encoding: "Q")
        case "Int32", "CInt":
            return .init(kind: .signedInteger, size: 4, alignment: 4, encoding: "i")
        case "UInt32", "CUnsignedInt":
            return .init(kind: .unsignedInteger, size: 4, alignment: 4, encoding: "I")
        case "Int16", "CShort":
            return .init(kind: .signedInteger, size: 2, alignment: 2, encoding: "s")
        case "UInt16", "CUnsignedShort", "UniChar":
            return .init(kind: .unsignedInteger, size: 2, alignment: 2, encoding: "S")
        case "Int8", "CChar":
            return .init(kind: .signedInteger, size: 1, alignment: 1, encoding: "c")
        case "UInt8", "CUnsignedChar":
            return .init(kind: .unsignedInteger, size: 1, alignment: 1, encoding: "C")
        case "Float", "CFloat":
            return .init(kind: .floatingPoint, size: 4, alignment: 4, encoding: "f")
        case "Double", "CGFloat", "CDouble":
            return .init(kind: .floatingPoint, size: 8, alignment: 8, encoding: "d")
        default:
            return nil
        }
    }

    static func structure(named raw: String) -> Structure? {
        switch leafName(raw) {
        case "CGPoint":
            .init(size: 16, alignment: 8, encoding: "{CGPoint=dd}")
        case "CGSize":
            .init(size: 16, alignment: 8, encoding: "{CGSize=dd}")
        case "CGVector":
            .init(size: 16, alignment: 8, encoding: "{CGVector=dd}")
        case "CGRect":
            .init(
                size: 32,
                alignment: 8,
                encoding: "{CGRect={CGPoint=dd}{CGSize=dd}}"
            )
        case "CGAffineTransform":
            .init(size: 48, alignment: 8, encoding: "{CGAffineTransform=dddddd}")
        case "UIEdgeInsets":
            .init(size: 32, alignment: 8, encoding: "{UIEdgeInsets=dddd}")
        case "NSDirectionalEdgeInsets":
            .init(size: 32, alignment: 8, encoding: "{NSDirectionalEdgeInsets=dddd}")
        case "UIOffset":
            .init(size: 16, alignment: 8, encoding: "{UIOffset=dd}")
        case "NSRange", "_NSRange":
            .init(size: 16, alignment: 8, encoding: "{_NSRange=QQ}")
        default:
            nil
        }
    }

    static func scalarMatches(
        _ scalar: Scalar,
        logicalType: Bytecode.ValueType?
    ) -> Bool {
        switch (scalar.kind, logicalType) {
        case (.boolean, .bool):
            true
        case let (.signedInteger, .integer(width, signed)),
             let (.unsignedInteger, .integer(width, signed)):
            width == scalar.size * 8
                && signed == (scalar.kind == .signedInteger)
        case let (.floatingPoint, .float(width)):
            width == scalar.size * 8
        default:
            false
        }
    }

    static func objectMatches(
        _ logicalType: Bytecode.ValueType?,
        nativeTypeKinds: [Core.TypeID: InterfaceArchive.TypeKind],
        isNullable: Bool,
        allowsSwiftAnyErasure: Bool
    ) -> Bool {
        guard let logicalType else { return isNullable }
        switch logicalType {
        case .string, .error:
            return !isNullable
        case .any:
            return allowsSwiftAnyErasure && !isNullable
        case let .native(id):
            return !isNullable && nativeTypeKinds[id] == .reference
        case let .optional(wrapped):
            return isNullable && objectMatches(
                wrapped,
                nativeTypeKinds: nativeTypeKinds,
                isNullable: false,
                allowsSwiftAnyErasure: allowsSwiftAnyErasure
            )
        default:
            return false
        }
    }

    static func isObjectiveCObjectSpelling(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != "()",
              !value.contains(" -> "),
              !value.hasPrefix("@convention(")
        else { return false }
        if value == "AnyObject" || value.hasPrefix("any ") { return true }
        let leaf = leafName(value)
        return leaf.first.map { $0.isUppercase } == true
            && scalar(named: value, targetTriple: "arm64-apple-ios15.0") == nil
            && structure(named: value) == nil
    }

    static func strippingOwnership(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for prefix in [
                "$", "@owned ", "@guaranteed ", "@unowned ",
                "@autoreleased ", "@in_guaranteed ", "@out ",
            ] where value.hasPrefix(prefix) {
                value.removeFirst(prefix.count)
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return value
    }

    static func unwrapOptional(_ raw: String) -> (String, Bool) {
        for prefix in ["Optional<", "Swift.Optional<"]
        where raw.hasPrefix(prefix) && raw.hasSuffix(">") {
            return (
                String(raw.dropFirst(prefix.count).dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                true
            )
        }
        return (raw, false)
    }

    static func canonicalPhysicalName(_ raw: String) -> String {
        let value = raw.replacingOccurrences(of: "__C.", with: "")
        // Preserve a compiler-proven Objective-C protocol existential. Its
        // machine encoding is still `@`, but treating it as unrestricted `id`
        // would lose the declaration's runtime conformance requirement.
        guard !value.hasPrefix("any "),
              let genericArguments = value.firstIndex(of: "<")
        else { return value }
        // Objective-C lightweight generics affect Swift's logical type only.
        // The message ABI and runtime class lookup are always erased to the
        // declaration class before crossing the generic invoker boundary.
        return String(value[..<genericArguments])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func leafName(_ raw: String) -> String {
        raw.split(separator: ".").last.map(String.init) ?? raw
    }

    static func isSupported64BitAppleTarget(_ target: String) -> Bool {
        target.contains("apple-")
            && (target.hasPrefix("arm64-")
                || target.hasPrefix("arm64e-")
                || target.hasPrefix("x86_64-"))
    }
}
