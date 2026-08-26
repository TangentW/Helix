import Foundation

extension Core {
/// Stable, project-independent identity and ABI metadata for a native call.
public enum NativeCall {}
}

extension Core.NativeCall {
public struct Key: Core.DigestIdentity, Comparable {
    public let rawValue: Core.Digest

    public init(rawValue: Core.Digest) {
        self.rawValue = rawValue
    }

    public static func derive(
        descriptor: Core.NativeCall.Descriptor
    ) throws -> Self {
        let canonical = try descriptor.canonicalized()
        var hasher = Core.StableHasher(domain: "HLX.NativeCall.v1")
        hasher.append(try Core.CanonicalJSON.encode(canonical))
        return Self(rawValue: hasher.finalize())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Backend: String, Codable, Hashable, Sendable, CaseIterable {
    case objectiveCMessage
    case cFunction
    case swiftAdapter
    case builtin
}

public enum Dispatch: String, Codable, Hashable, Sendable, CaseIterable {
    case global
    case initializer
    case instance
    case `static`
}

public struct Target: Codable, Hashable, Sendable {
    public var backend: Core.NativeCall.Backend
    public var module: String
    public var owner: String?
    public var member: String
    /// Selector, C symbol, adapter identity, or builtin identity. Runtime code
    /// may resolve only this cataloged entry point, never caller-provided text.
    public var entryPoint: String
    public var dispatch: Core.NativeCall.Dispatch
    /// VM argument carrying `self` for instance dispatch. It is explicit so
    /// Objective-C call plans do not guess a receiver from parameter order.
    public var receiverArgumentIndex: UInt16?

    public init(
        backend: Core.NativeCall.Backend,
        module: String,
        owner: String? = nil,
        member: String,
        entryPoint: String,
        dispatch: Core.NativeCall.Dispatch,
        receiverArgumentIndex: UInt16? = nil
    ) {
        self.backend = backend
        self.module = module
        self.owner = owner
        self.member = member
        self.entryPoint = entryPoint
        self.dispatch = dispatch
        self.receiverArgumentIndex = receiverArgumentIndex
    }

    public var canonicalCallee: String {
        ([module] + (owner.map { [$0] } ?? []) + [member])
            .joined(separator: ".")
    }
}

public enum Ownership: String, Codable, Hashable, Sendable, CaseIterable {
    case owned
    case borrowed
    case consuming
    case inoutValue
}

public struct LogicalParameter: Codable, Hashable, Sendable {
    public var label: String?
    public var type: String
    public var ownership: Core.NativeCall.Ownership
    public var callbackLifetime: Core.NativeImportCallbackLifetime?
    public var isAutoclosure: Bool

    public init(
        label: String? = nil,
        type: String,
        ownership: Core.NativeCall.Ownership = .owned,
        callbackLifetime: Core.NativeImportCallbackLifetime? = nil,
        isAutoclosure: Bool = false
    ) {
        self.label = label
        self.type = type
        self.ownership = ownership
        self.callbackLifetime = callbackLifetime
        self.isAutoclosure = isAutoclosure
    }
}

public struct LogicalResult: Codable, Hashable, Sendable {
    public var type: String
    public var ownership: Core.NativeCall.Ownership

    public init(
        type: String,
        ownership: Core.NativeCall.Ownership = .owned
    ) {
        self.type = type
        self.ownership = ownership
    }
}

public struct LogicalSignature: Codable, Hashable, Sendable {
    public var parameters: [Core.NativeCall.LogicalParameter]
    public var result: Core.NativeCall.LogicalResult
    public var isThrowing: Bool
    public var isAsync: Bool
    public var isolation: String?

    public init(
        parameters: [Core.NativeCall.LogicalParameter],
        result: Core.NativeCall.LogicalResult,
        isThrowing: Bool = false,
        isAsync: Bool = false,
        isolation: String? = nil
    ) {
        self.parameters = parameters
        self.result = result
        self.isThrowing = isThrowing
        self.isAsync = isAsync
        self.isolation = isolation
    }

    public var lowered: Core.LoweredSignature {
        .init(
            parameters: parameters.map(\.type),
            result: result.type,
            isThrowing: isThrowing,
            isAsync: isAsync,
            isolation: isolation
        )
    }
}

public enum CallingConvention: String, Codable, Hashable, Sendable, CaseIterable {
    case objectiveC
    case c
    case swiftAdapter
    case builtin
}

public enum ABIValueKind: String, Codable, Hashable, Sendable, CaseIterable {
    case void
    /// A typed value crossing the VM-to-Swift adapter boundary.
    case bridgeValue
    case object
    case classObject
    case selector
    case block
    case boolean
    case signedInteger
    case unsignedInteger
    case floatingPoint
    case structure
    case pointer
}

/// Compiler-proven passing convention for one value in the underlying native
/// ABI. This is separate from `Ownership`: the latter controls a Helix bridge
/// slot, while this value preserves distinctions such as Swift's direct
/// guaranteed and indirect-in-guaranteed conventions.
public enum ABIConvention: String, Codable, Hashable, Sendable, CaseIterable {
    case direct
    case directOwned
    case directGuaranteed
    case directUnowned
    case autoreleased
    case indirectIn
    case indirectInGuaranteed
    case indirectInout
    case indirectInoutAliasable
    case indirectOut
}

public struct ABIType: Codable, Hashable, Sendable {
    public var kind: Core.NativeCall.ABIValueKind
    public var canonicalName: String?
    public var size: UInt16?
    public var alignment: UInt16?
    /// Canonical Objective-C type encoding or C ABI spelling when applicable.
    public var encoding: String?
    public var isNullable: Bool

    public init(
        kind: Core.NativeCall.ABIValueKind,
        canonicalName: String? = nil,
        size: UInt16? = nil,
        alignment: UInt16? = nil,
        encoding: String? = nil,
        isNullable: Bool = false
    ) {
        self.kind = kind
        self.canonicalName = canonicalName
        self.size = size
        self.alignment = alignment
        self.encoding = encoding
        self.isNullable = isNullable
    }

    public static let void = Self(kind: .void)

    public static func bridgeValue(_ canonicalType: String) -> Self {
        Self(kind: .bridgeValue, canonicalName: canonicalType)
    }
}

public enum ArgumentSourceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case argument
    case defaultGenerator
    case optionalNone
    case errorOut
}

public struct ArgumentSource: Codable, Hashable, Sendable {
    public var kind: Core.NativeCall.ArgumentSourceKind
    public var logicalArgumentIndex: UInt16?
    public var generatorSymbol: String?

    public init(
        kind: Core.NativeCall.ArgumentSourceKind,
        logicalArgumentIndex: UInt16? = nil,
        generatorSymbol: String? = nil
    ) {
        self.kind = kind
        self.logicalArgumentIndex = logicalArgumentIndex
        self.generatorSymbol = generatorSymbol
    }

    public static func argument(_ index: UInt16) -> Self {
        .init(kind: .argument, logicalArgumentIndex: index)
    }

    public static func defaultGenerator(_ symbol: String) -> Self {
        .init(kind: .defaultGenerator, generatorSymbol: symbol)
    }

    public static let optionalNone = Self(kind: .optionalNone)
    public static let errorOut = Self(kind: .errorOut)
}

public struct ABIParameter: Codable, Hashable, Sendable {
    public var type: Core.NativeCall.ABIType
    /// Ownership of the value supplied by the stable Helix adapter boundary.
    public var ownership: Core.NativeCall.Ownership
    public var convention: Core.NativeCall.ABIConvention
    public var source: Core.NativeCall.ArgumentSource

    public init(
        type: Core.NativeCall.ABIType,
        ownership: Core.NativeCall.Ownership = .owned,
        convention: Core.NativeCall.ABIConvention = .direct,
        source: Core.NativeCall.ArgumentSource
    ) {
        self.type = type
        self.ownership = ownership
        self.convention = convention
        self.source = source
    }
}

public enum ErrorConvention: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case swiftThrows
    case nsErrorOut
}

/// Ownership family frozen from the imported Objective-C declaration.
/// Runtime must not infer this from a caller-controlled selector string.
public enum ObjectiveCMethodFamily: String, Codable, Hashable, Sendable,
    CaseIterable
{
    case none
    case initializer
    case new
    case copy
    case mutableCopy
    case alloc
}

/// Sentinel that determines whether a supported `NSError **` call failed.
/// More conventions can be added only when the importer proves their complete
/// Clang-to-Swift error mapping.
public enum ObjectiveCErrorFailure: String, Codable, Hashable, Sendable,
    CaseIterable
{
    case falseBoolean
}

public enum ObjectiveCPropertyAccessor: String, Codable, Hashable, Sendable,
    CaseIterable
{
    case getter
    case setter
}

/// A compiler-observed Objective-C property declaration. The exact accessor
/// selector is stored separately in `Target`; this value preserves declaration
/// identity without requiring optional property metadata at runtime.
public struct ObjectiveCProperty: Codable, Hashable, Sendable {
    public var name: String
    public var accessor: Core.NativeCall.ObjectiveCPropertyAccessor

    public init(
        name: String,
        accessor: Core.NativeCall.ObjectiveCPropertyAccessor
    ) {
        self.name = name
        self.accessor = accessor
    }
}

/// Objective-C facts that are not recoverable from the Swift-facing name.
public struct ObjectiveCMetadata: Codable, Hashable, Sendable {
    /// Cataloged declaration class accepted by `NSClassFromString`. This can
    /// differ from both the Swift overlay owner and the class that receives a
    /// class message or is allocated for an inherited initializer.
    public var runtimeClassName: String
    /// Exact Objective-C class that receives a class message or is allocated
    /// for an initializer. Instance calls obtain their target from the verified
    /// receiver value and keep this nil.
    public var dispatchClassName: String?
    public var methodFamily: Core.NativeCall.ObjectiveCMethodFamily
    /// Runtime class at which an explicit lexical `super` lookup starts.
    /// Ordinary calls keep this nil and retain Objective-C dynamic dispatch.
    public var lexicalSuperclassName: String?
    public var errorFailure: Core.NativeCall.ObjectiveCErrorFailure?
    public var property: Core.NativeCall.ObjectiveCProperty?

    public init(
        runtimeClassName: String,
        dispatchClassName: String? = nil,
        methodFamily: Core.NativeCall.ObjectiveCMethodFamily = .none,
        lexicalSuperclassName: String? = nil,
        errorFailure: Core.NativeCall.ObjectiveCErrorFailure? = nil,
        property: Core.NativeCall.ObjectiveCProperty? = nil
    ) {
        self.runtimeClassName = runtimeClassName
        self.dispatchClassName = dispatchClassName
        self.methodFamily = methodFamily
        self.lexicalSuperclassName = lexicalSuperclassName
        self.errorFailure = errorFailure
        self.property = property
    }
}

public struct PhysicalSignature: Codable, Hashable, Sendable {
    public var callingConvention: Core.NativeCall.CallingConvention
    public var parameters: [Core.NativeCall.ABIParameter]
    public var result: Core.NativeCall.ABIType
    public var resultConvention: Core.NativeCall.ABIConvention
    public var errorConvention: Core.NativeCall.ErrorConvention

    public init(
        callingConvention: Core.NativeCall.CallingConvention,
        parameters: [Core.NativeCall.ABIParameter],
        result: Core.NativeCall.ABIType,
        resultConvention: Core.NativeCall.ABIConvention = .direct,
        errorConvention: Core.NativeCall.ErrorConvention = .none
    ) {
        self.callingConvention = callingConvention
        self.parameters = parameters
        self.result = result
        self.resultConvention = resultConvention
        self.errorConvention = errorConvention
    }
}

public struct Availability: Codable, Hashable, Sendable, Comparable {
    public var platform: String
    public var introduced: Core.SemanticVersion?
    public var deprecated: Core.SemanticVersion?
    public var obsoleted: Core.SemanticVersion?
    public var isUnavailable: Bool

    public init(
        platform: String,
        introduced: Core.SemanticVersion? = nil,
        deprecated: Core.SemanticVersion? = nil,
        obsoleted: Core.SemanticVersion? = nil,
        isUnavailable: Bool = false
    ) {
        self.platform = platform
        self.introduced = introduced
        self.deprecated = deprecated
        self.obsoleted = obsoleted
        self.isUnavailable = isUnavailable
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.platform < rhs.platform
    }
}

public struct Descriptor: Codable, Hashable, Sendable {
    public var target: Core.NativeCall.Target
    public var logicalSignature: Core.NativeCall.LogicalSignature
    public var physicalSignature: Core.NativeCall.PhysicalSignature
    public var objectiveC: Core.NativeCall.ObjectiveCMetadata?
    public var effects: Core.Effects
    public var availability: [Core.NativeCall.Availability]

    public init(
        target: Core.NativeCall.Target,
        logicalSignature: Core.NativeCall.LogicalSignature,
        physicalSignature: Core.NativeCall.PhysicalSignature,
        objectiveC: Core.NativeCall.ObjectiveCMetadata? = nil,
        effects: Core.Effects,
        availability: [Core.NativeCall.Availability] = []
    ) throws {
        self.target = target
        self.logicalSignature = logicalSignature
        self.physicalSignature = physicalSignature
        self.objectiveC = objectiveC
        self.effects = effects
        self.availability = availability
        self = try canonicalized()
    }

    /// Builds the descriptor for today's exact typed Swift adapter boundary.
    /// SIL aliases and factory type names deliberately stay outside this value.
    public static func swiftAdapter(
        canonicalCallee: String,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        argumentLabels: [String] = [],
        physicalParameterTypes: [String]? = nil,
        physicalResultType: String? = nil,
        physicalArgumentSources: [Core.NativeCall.ArgumentSource]? = nil,
        receiverArgumentIndex: UInt16? = nil,
        backend: Core.NativeCall.Backend = .swiftAdapter,
        availability: [Core.NativeCall.Availability] = []
    ) throws -> Self {
        let parsedTarget = try target(
            canonicalCallee: canonicalCallee,
            backend: backend,
            kind: contract.kind,
            signature: signature,
            receiverArgumentIndex: receiverArgumentIndex
        )
        // Keep construction total for untrusted or partially assembled
        // contracts. `validated(contract:)` reports duplicate callback slots
        // through the normal fail-closed validation path.
        let callbackByIndex = Self.callbackLifetimes(contract.callbacks)
        let labels: [String?] = signature.parameters.indices.map { index in
            guard argumentLabels.indices.contains(index) else { return nil }
            let value = argumentLabels[index]
            return value == "_" || value.isEmpty ? nil : value
        }
        let logicalParameters = signature.parameters.enumerated().map { index, type in
            Core.NativeCall.LogicalParameter(
                label: labels[index],
                type: type,
                ownership: ownership(from: type),
                callbackLifetime: callbackByIndex[index],
                isAutoclosure: type.contains("@autoclosure")
            )
        }
        let physicalTypes = physicalParameterTypes ?? signature.parameters
        let sources = physicalArgumentSources ?? physicalTypes.indices.compactMap {
            UInt16(exactly: $0).map(Core.NativeCall.ArgumentSource.argument)
        }
        guard physicalTypes.count == sources.count else {
            throw Core.NativeCall.DescriptorError.invalid(
                "physical Swift adapter types and argument sources disagree"
            )
        }
        let convention: Core.NativeCall.CallingConvention = switch backend {
        case .swiftAdapter: .swiftAdapter
        case .builtin: .builtin
        case .objectiveCMessage, .cFunction:
            throw Core.NativeCall.DescriptorError.invalid(
                "typed Swift adapter construction requires a Swift or builtin backend"
            )
        }
        let physicalParameters = try physicalTypes.map(
            Self.parseSwiftABIValue
        )
        let rawPhysicalResult = physicalResultType ?? signature.result
        let physicalResult = try Self.parseSwiftABIValue(rawPhysicalResult)
        return try Self(
            target: parsedTarget,
            logicalSignature: .init(
                parameters: logicalParameters,
                result: .init(type: signature.result),
                isThrowing: signature.isThrowing,
                isAsync: signature.isAsync,
                isolation: signature.isolation
            ),
            physicalSignature: .init(
                callingConvention: convention,
                parameters: zip(physicalParameters, sources).map { value, source in
                    let ownership: Core.NativeCall.Ownership = if
                        source.kind == .argument,
                        let logicalIndex = source.logicalArgumentIndex,
                        callbackByIndex[Int(logicalIndex)] == .nonescaping
                    {
                        .borrowed
                    } else if source.kind == .argument,
                              let logicalIndex = source.logicalArgumentIndex,
                              logicalParameters.indices.contains(Int(logicalIndex))
                    {
                        logicalParameters[Int(logicalIndex)].ownership
                    } else {
                        .owned
                    }
                    return .init(
                        type: .bridgeValue(value.type),
                        ownership: ownership,
                        convention: value.convention,
                        source: source
                    )
                },
                result: isVoid(signature.result)
                    ? .void : .bridgeValue(physicalResult.type),
                resultConvention: isVoid(signature.result)
                    ? .direct : physicalResult.convention,
                errorConvention: signature.isThrowing ? .swiftThrows : .none
            ),
            effects: effects,
            availability: availability
        ).validated(contract: contract)
    }

    /// Builds a catalog entry for the reusable Objective-C message invoker.
    /// The caller supplies compiler-proven physical ABI metadata; this helper
    /// derives only the stable logical metadata shared with Swift adapters.
    public static func objectiveCMessage(
        module: String,
        owner: String,
        member: String,
        selector: String,
        dispatch: Core.NativeCall.Dispatch,
        receiverArgumentIndex: UInt16?,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        argumentLabels: [String] = [],
        physicalSignature: Core.NativeCall.PhysicalSignature,
        metadata: Core.NativeCall.ObjectiveCMetadata,
        availability: [Core.NativeCall.Availability] = []
    ) throws -> Self {
        let callbackByIndex = Self.callbackLifetimes(contract.callbacks)
        let labels: [String?] = signature.parameters.indices.map { index in
            guard argumentLabels.indices.contains(index) else { return nil }
            let value = argumentLabels[index]
            return value == "_" || value.isEmpty ? nil : value
        }
        let logicalParameters = signature.parameters.enumerated().map {
            index, type in
            Core.NativeCall.LogicalParameter(
                label: labels[index],
                type: type,
                ownership: ownership(from: type),
                callbackLifetime: callbackByIndex[index],
                isAutoclosure: type.contains("@autoclosure")
            )
        }
        return try Self(
            target: .init(
                backend: .objectiveCMessage,
                module: module,
                owner: owner,
                member: member,
                entryPoint: selector,
                dispatch: dispatch,
                receiverArgumentIndex: receiverArgumentIndex
            ),
            logicalSignature: .init(
                parameters: logicalParameters,
                result: .init(type: signature.result),
                isThrowing: signature.isThrowing,
                isAsync: signature.isAsync,
                isolation: signature.isolation
            ),
            physicalSignature: physicalSignature,
            objectiveC: metadata,
            effects: effects,
            availability: availability
        ).validated(contract: contract)
    }

    /// Builds a catalog entry for the reusable C invoker. The physical
    /// signature must come from compiler-observed C ABI evidence; this helper
    /// does not infer C layouts from the source-facing Swift spelling.
    public static func cFunction(
        module: String,
        member: String,
        symbol: String,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        argumentLabels: [String] = [],
        physicalSignature: Core.NativeCall.PhysicalSignature,
        availability: [Core.NativeCall.Availability] = []
    ) throws -> Self {
        let labels: [String?] = signature.parameters.indices.map { index in
            guard argumentLabels.indices.contains(index) else { return nil }
            let value = argumentLabels[index]
            return value == "_" || value.isEmpty ? nil : value
        }
        let logicalParameters = signature.parameters.enumerated().map {
            index, type in
            Core.NativeCall.LogicalParameter(
                label: labels[index],
                type: type,
                ownership: ownership(from: type),
                callbackLifetime: contract.callbacks.first(where: {
                    Int($0.parameterIndex) == index
                })?.lifetime,
                isAutoclosure: type.contains("@autoclosure")
            )
        }
        return try Self(
            target: .init(
                backend: .cFunction,
                module: module,
                member: member,
                entryPoint: symbol,
                dispatch: .global
            ),
            logicalSignature: .init(
                parameters: logicalParameters,
                result: .init(type: signature.result),
                isThrowing: signature.isThrowing,
                isAsync: signature.isAsync,
                isolation: signature.isolation
            ),
            physicalSignature: physicalSignature,
            effects: effects,
            availability: availability
        ).validated(contract: contract)
    }

    public var canonicalCallee: String { target.canonicalCallee }
    public var loweredSignature: Core.LoweredSignature { logicalSignature.lowered }

    /// Replaces compiler-observed logical signature metadata while retaining
    /// target and ABI routing. The next trust boundary must still call
    /// `validate`; this operation is primarily useful while assembling records.
    public mutating func replaceLogicalSignature(
        _ signature: Core.LoweredSignature,
        callbacks: [Core.NativeImportCallback]
    ) {
        let lifetimes = Self.callbackLifetimes(callbacks)
        logicalSignature.parameters = signature.parameters.enumerated().map {
            index, type in
            let previous = logicalSignature.parameters.indices.contains(index)
                ? logicalSignature.parameters[index] : nil
            return .init(
                label: previous?.label,
                type: type,
                ownership: Self.ownership(from: type),
                callbackLifetime: lifetimes[index],
                isAutoclosure: previous?.isAutoclosure ?? false
            )
        }
        logicalSignature.result.type = signature.result
        logicalSignature.isThrowing = signature.isThrowing
        logicalSignature.isAsync = signature.isAsync
        logicalSignature.isolation = signature.isolation
        for index in physicalSignature.parameters.indices {
            guard physicalSignature.parameters[index].type.kind == .bridgeValue,
                  let logicalIndex = physicalSignature.parameters[index]
                    .source.logicalArgumentIndex,
                  signature.parameters.indices.contains(Int(logicalIndex))
            else { continue }
            physicalSignature.parameters[index].type = .bridgeValue(
                signature.parameters[Int(logicalIndex)]
            )
        }
        if physicalSignature.result.kind == .bridgeValue || Self.isVoid(
            signature.result
        ) {
            physicalSignature.result = Self.isVoid(signature.result)
                ? .void : .bridgeValue(signature.result)
            physicalSignature.resultConvention = .direct
        }
        physicalSignature.errorConvention = signature.isThrowing
            ? .swiftThrows : .none
        if let canonical = try? canonicalized() { self = canonical }
    }

    /// Updates policy-owned callback authority without rewriting the
    /// compiler-observed physical call shape. Duplicate or out-of-range facts
    /// remain invalid and are rejected by `validated(contract:)`.
    public mutating func replaceCallbackLifetimes(
        _ callbacks: [Core.NativeImportCallback]
    ) {
        let lifetimes = Self.callbackLifetimes(callbacks)
        for index in logicalSignature.parameters.indices {
            logicalSignature.parameters[index].callbackLifetime = lifetimes[index]
        }
    }

    public func canonicalized() throws -> Self {
        var result = self
        result.target.module = try Self.normalizeIdentifierPath(
            target.module,
            label: "native module"
        )
        result.target.owner = try target.owner.map(Self.normalizeSwiftType)
        result.target.member = try Self.normalizeBoundText(
            target.member,
            label: "native member"
        )
        result.target.entryPoint = try Self.normalizeBoundText(
            target.entryPoint,
            label: "native entry point"
        )
        result.logicalSignature.parameters = try logicalSignature.parameters.map {
            var parameter = $0
            parameter.label = try parameter.label.map {
                try Self.normalizeArgumentLabel($0)
            }
            parameter.type = try Self.normalizeSwiftType(parameter.type)
            return parameter
        }
        result.logicalSignature.result.type = try Self.normalizeSwiftType(
            logicalSignature.result.type
        )
        result.logicalSignature.isolation = try logicalSignature.isolation.map {
            let normalized = try Self.normalizeSwiftType($0)
            return normalized == "Swift.MainActor" ? "MainActor" : normalized
        }
        result.physicalSignature.parameters = try physicalSignature.parameters.map {
            var parameter = $0
            parameter.type = try Self.normalizeABIType(parameter.type)
            parameter.source.generatorSymbol = try parameter.source.generatorSymbol.map {
                try Self.normalizeSymbol($0)
            }
            return parameter
        }
        result.physicalSignature.result = try Self.normalizeABIType(
            physicalSignature.result
        )
        result.objectiveC = try objectiveC.map { metadata in
            var value = metadata
            value.runtimeClassName = try Self.normalizeIdentifierPath(
                metadata.runtimeClassName,
                label: "Objective-C runtime class"
            )
            value.dispatchClassName = try metadata.dispatchClassName.map {
                try Self.normalizeIdentifierPath(
                    $0,
                    label: "Objective-C dispatch class"
                )
            }
            value.lexicalSuperclassName = try metadata.lexicalSuperclassName.map {
                try Self.normalizeIdentifierPath(
                    $0,
                    label: "Objective-C lexical superclass"
                )
            }
            value.property = try metadata.property.map { property in
                var property = property
                property.name = try Self.normalizeBoundText(
                    property.name,
                    label: "Objective-C property"
                )
                return property
            }
            return value
        }
        result.availability = try availability.map { item in
            var value = item
            value.platform = try Self.normalizePlatform(item.platform)
            return value
        }.sorted()
        try result.validateCanonical()
        return result
    }

    public func validated(
        contract: Core.NativeImportContract
    ) throws -> Self {
        let canonical = try canonicalized()
        try contract.validate(effects: canonical.effects)
        guard canonical.target.dispatch == Self.dispatch(for: contract.kind) else {
            throw Core.NativeCall.DescriptorError.invalid(
                "native dispatch disagrees with its invocation contract"
            )
        }
        let callbackByIndex = Dictionary(
            uniqueKeysWithValues: contract.callbacks.map {
                (Int($0.parameterIndex), $0.lifetime)
            }
        )
        guard callbackByIndex.count == contract.callbacks.count,
              callbackByIndex.keys.allSatisfy(
                  canonical.logicalSignature.parameters.indices.contains
              ),
              canonical.logicalSignature.parameters.enumerated().allSatisfy({
                  callbackByIndex[$0.offset] == $0.element.callbackLifetime
              })
        else {
            throw Core.NativeCall.DescriptorError.invalid(
                "logical callback lifetimes disagree with the invocation contract"
            )
        }
        for parameter in canonical.logicalSignature.parameters {
            let isCallable = Self.isCallableType(parameter.type)
            guard isCallable == (parameter.callbackLifetime != nil),
                  !parameter.isAutoclosure || isCallable
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "logical callable parameters require an exact callback lifetime"
                )
            }
        }
        return canonical
    }

    public func validate(contract: Core.NativeImportContract) throws {
        guard try validated(contract: contract) == self else {
            throw Core.NativeCall.DescriptorError.invalid(
                "native call descriptor is not canonical"
            )
        }
    }

    private func validateCanonical() throws {
        guard logicalSignature.parameters.count <= 256,
              physicalSignature.parameters.count <= 256,
              logicalSignature.isThrowing == effects.mayThrow,
              logicalSignature.isAsync == effects.isAsync,
              (logicalSignature.isolation == "MainActor")
                == effects.requiresMainActor,
              availability.count <= 64,
              availability == availability.sorted(),
              Set(availability.map(\.platform)).count == availability.count
        else {
            throw Core.NativeCall.DescriptorError.invalid(
                "logical signature, effects, isolation, or availability disagree"
            )
        }
        switch target.dispatch {
        case .global:
            guard target.owner == nil,
                  target.receiverArgumentIndex == nil
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "global native calls cannot have an owner or receiver"
                )
            }
        case .initializer, .static:
            guard target.owner != nil,
                  target.receiverArgumentIndex == nil
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "initializer and static native calls require an owner and no receiver"
                )
            }
        case .instance:
            guard target.owner != nil else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "instance native calls require an owner"
                )
            }
        }
        if let receiver = target.receiverArgumentIndex {
            guard target.dispatch == .instance,
                  Int(receiver) < logicalSignature.parameters.count
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "native receiver argument is invalid"
                )
            }
        } else if target.dispatch == .instance {
            throw Core.NativeCall.DescriptorError.invalid(
                "instance native calls require an explicit receiver argument"
            )
        }
        let expectedConvention: Core.NativeCall.CallingConvention = switch target.backend {
        case .objectiveCMessage: .objectiveC
        case .cFunction: .c
        case .swiftAdapter: .swiftAdapter
        case .builtin: .builtin
        }
        guard physicalSignature.callingConvention == expectedConvention else {
            throw Core.NativeCall.DescriptorError.invalid(
                "native backend and physical calling convention disagree"
            )
        }
        try validateErrorConvention()
        try Self.validateABIType(physicalSignature.result, allowingVoid: true)
        guard physicalSignature.result.kind != .void
                || physicalSignature.resultConvention == .direct
        else {
            throw Core.NativeCall.DescriptorError.invalid(
                "Void cannot carry a native ABI value convention"
            )
        }
        var usedArguments = Set<UInt16>()
        for parameter in physicalSignature.parameters {
            try Self.validateABIType(parameter.type, allowingVoid: false)
            switch parameter.source.kind {
            case .argument:
                guard let index = parameter.source.logicalArgumentIndex,
                      parameter.source.generatorSymbol == nil,
                      Int(index) < logicalSignature.parameters.count,
                      usedArguments.insert(index).inserted
                else {
                    throw Core.NativeCall.DescriptorError.invalid(
                        "native physical argument projection is invalid"
                    )
                }
            case .defaultGenerator:
                guard parameter.source.logicalArgumentIndex == nil,
                      parameter.source.generatorSymbol != nil
                else {
                    throw Core.NativeCall.DescriptorError.invalid(
                        "native default generator projection is invalid"
                    )
                }
            case .optionalNone:
                guard parameter.source.logicalArgumentIndex == nil,
                      parameter.source.generatorSymbol == nil,
                      parameter.type.isNullable
                        || parameter.type.kind == .bridgeValue
                            && parameter.type.canonicalName.map(
                                Self.isOptionalSwiftType
                            ) == true
                else {
                    throw Core.NativeCall.DescriptorError.invalid(
                        "native optional-none projection requires a nullable ABI type"
                    )
                }
            case .errorOut:
                guard parameter.source.logicalArgumentIndex == nil,
                      parameter.source.generatorSymbol == nil,
                      parameter.type.kind == .pointer,
                      parameter.type.encoding == "^@"
                else {
                    throw Core.NativeCall.DescriptorError.invalid(
                        "NSError-out projection requires one encoded object pointer"
                    )
                }
            }
        }
        let receiver = target.receiverArgumentIndex
        let expectedArguments = Set(logicalSignature.parameters.indices.compactMap {
            UInt16(exactly: $0)
        })
        let requiredArguments = target.backend == .objectiveCMessage
            ? expectedArguments.subtracting(receiver.map { [$0] } ?? [])
            : expectedArguments
        guard usedArguments == requiredArguments else {
            throw Core.NativeCall.DescriptorError.invalid(
                "native physical signature does not project every logical argument"
            )
        }
        try validateBackendABI()
        for item in availability {
            guard item.introduced.map({ introduced in
                item.deprecated.map { introduced <= $0 } ?? true
            }) ?? true,
            item.deprecated.map({ deprecated in
                item.obsoleted.map { deprecated <= $0 } ?? true
            }) ?? true
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "native availability versions are not monotonic"
                )
            }
        }
    }

    private func validateErrorConvention() throws {
        let expected: Core.NativeCall.ErrorConvention = switch target.backend {
        case .swiftAdapter, .builtin:
            logicalSignature.isThrowing ? .swiftThrows : .none
        case .objectiveCMessage:
            logicalSignature.isThrowing ? .nsErrorOut : .none
        case .cFunction:
            // C error-result shapes need an explicit convention rather than
            // borrowing Swift or NSError semantics.
            .none
        }
        guard physicalSignature.errorConvention == expected,
              target.backend != .cFunction || !logicalSignature.isThrowing
        else {
            throw Core.NativeCall.DescriptorError.invalid(
                "native error convention disagrees with its backend"
            )
        }
        let errorOutCount = physicalSignature.parameters.filter {
            $0.source.kind == .errorOut
        }.count
        switch physicalSignature.errorConvention {
        case .nsErrorOut:
            guard errorOutCount == 1,
                  objectiveC?.errorFailure != nil
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "Objective-C throws requires one NSError-out slot and failure sentinel"
                )
            }
        case .none, .swiftThrows:
            guard errorOutCount == 0,
                  objectiveC?.errorFailure == nil
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "NSError-out metadata is present on a non-NSError call"
                )
            }
        }
    }

    private func validateBackendABI() throws {
        let physicalTypes = physicalSignature.parameters.map(\.type)
            + [physicalSignature.result]
        switch target.backend {
        case .swiftAdapter, .builtin:
            guard objectiveC == nil,
                  physicalSignature.parameters.allSatisfy({
                      $0.type.kind == .bridgeValue
                  }),
                  physicalSignature.result.kind == (
                      Self.isVoid(logicalSignature.result.type)
                          ? .void : .bridgeValue
                  )
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "Swift adapters require exact BridgeValue ABI slots"
                )
            }
        case .objectiveCMessage:
            guard target.dispatch != .global,
                  let objectiveC,
                  physicalTypes.allSatisfy({ $0.kind != .bridgeValue }),
                  physicalTypes.allSatisfy({
                      $0.kind == .void || $0.encoding != nil
                  }),
                  physicalTypes.allSatisfy(Self.objectiveCEncodingMatchesKind),
                  Self.isObjectiveCSelector(target.entryPoint),
                  target.entryPoint.filter({ $0 == ":" }).count
                    == physicalSignature.parameters.count,
                  objectiveC.lexicalSuperclassName == nil
                    || target.dispatch == .instance,
                  (target.dispatch == .instance)
                    == (objectiveC.dispatchClassName == nil),
                  objectiveC.property.map({ property in
                      target.dispatch != .initializer
                          && target.entryPoint.filter({ $0 == ":" }).count
                              == (property.accessor == .setter ? 1 : 0)
                          && (property.accessor == .getter
                              || objectiveC.methodFamily == .none)
                  }) ?? true,
                  Self.objectiveCMethodFamilyIsValid(
                      objectiveC.methodFamily,
                      target: target,
                      result: physicalSignature.result,
                      resultConvention: physicalSignature.resultConvention
                  )
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "Objective-C call \(target.canonicalCallee) ["
                        + "\(target.entryPoint)] requires a consistent encoded native ABI "
                        + "(dispatch: \(target.dispatch.rawValue), family: "
                        + "\(objectiveC?.methodFamily.rawValue ?? "missing"), result: "
                        + "\(physicalSignature.result.kind.rawValue)/"
                        + "\(physicalSignature.resultConvention.rawValue), arguments: "
                        + "\(physicalSignature.parameters.count))"
                )
            }
        case .cFunction:
            guard objectiveC == nil,
                  target.dispatch == .global,
                  Self.isCSymbol(target.entryPoint),
                  !logicalSignature.isAsync,
                  !logicalSignature.isThrowing,
                  physicalSignature.resultConvention == .direct,
                  physicalSignature.errorConvention == .none,
                  physicalSignature.parameters.allSatisfy({
                      $0.convention == .direct
                          && $0.source.kind == .argument
                  }),
                  physicalSignature.parameters.enumerated().allSatisfy({
                      $0.element.source.logicalArgumentIndex
                          == UInt16(exactly: $0.offset)
                  }),
                  physicalTypes.allSatisfy(Self.cABITypeIsSupported),
                  physicalTypes.allSatisfy({ $0.kind != .bridgeValue }),
                  physicalTypes.allSatisfy({
                      $0.kind == .void || $0.encoding != nil
                  }),
                  physicalTypes.allSatisfy(Self.encodedNativeTypeMatchesKind)
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "C calls require a synchronous global symbol and an exact supported native ABI"
                )
            }
        }
    }
}

public enum DescriptorError: Swift.Error, Equatable, Sendable,
    CustomStringConvertible
{
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(reason): "invalid native call descriptor: \(reason)"
        }
    }
}
}

private extension Core.NativeCall.Descriptor {
    static func isObjectiveCSelector(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              })
        else { return false }
        let colonCount = value.filter { $0 == ":" }.count
        if colonCount == 0 {
            return isSwiftIdentifier(Substring(value))
        }
        guard value.last == ":" else { return false }
        return value.dropLast().split(
            separator: ":",
            omittingEmptySubsequences: false
        ).allSatisfy(isSwiftIdentifier)
    }

    static func isCSymbol(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1_024,
              let first = value.utf8.first,
              (first == 0x5f || first >= 0x41 && first <= 0x5a
                  || first >= 0x61 && first <= 0x7a)
        else { return false }
        return value.utf8.dropFirst().allSatisfy {
            $0 == 0x5f || $0 >= 0x41 && $0 <= 0x5a
                || $0 >= 0x61 && $0 <= 0x7a
                || $0 >= 0x30 && $0 <= 0x39
        }
    }

    static func cABITypeIsSupported(
        _ type: Core.NativeCall.ABIType
    ) -> Bool {
        switch type.kind {
        case .void, .boolean, .signedInteger, .unsignedInteger,
             .floatingPoint, .structure:
            true
        case .bridgeValue, .object, .classObject, .selector, .block, .pointer:
            false
        }
    }

    static func objectiveCMethodFamilyIsValid(
        _ family: Core.NativeCall.ObjectiveCMethodFamily,
        target: Core.NativeCall.Target,
        result: Core.NativeCall.ABIType,
        resultConvention: Core.NativeCall.ABIConvention
    ) -> Bool {
        func belongs(to prefix: String) -> Bool {
            let selector = target.entryPoint.drop(while: { $0 == "_" })
            guard selector.hasPrefix(prefix) else { return false }
            let suffix = selector.dropFirst(prefix.count)
            guard let first = suffix.first else { return true }
            return !first.isLowercase
        }
        switch family {
        case .none:
            guard target.dispatch != .initializer else { return false }
            guard result.kind == .object else { return true }
            // A wrong non-owned convention on a family selector would make
            // Runtime add a retain to an already +1 result and leak it. Family
            // identity follows the selector independently of the convention
            // claimed by a catalog record.
            return !belongs(to: "alloc")
                && !belongs(to: "init")
                && !belongs(to: "new")
                && !belongs(to: "copy")
                && !belongs(to: "mutableCopy")
        case .alloc:
            return target.dispatch != .initializer
                && belongs(to: "alloc")
                && result.kind == .object
                && resultConvention == .directOwned
        case .initializer:
            return target.dispatch == .initializer
                && belongs(to: "init")
                && result.kind == .object
                && resultConvention == .directOwned
        case .new:
            return target.dispatch != .initializer
                && belongs(to: "new")
                && result.kind == .object
                && resultConvention == .directOwned
        case .copy:
            return target.dispatch != .initializer
                && belongs(to: "copy")
                && result.kind == .object
                && resultConvention == .directOwned
        case .mutableCopy:
            return target.dispatch != .initializer
                && belongs(to: "mutableCopy")
                && result.kind == .object
                && resultConvention == .directOwned
        }
    }

    /// Rejects catalog metadata that would make NSInvocation read a value with
    /// a layout different from the storage allocated by Runtime. Qualifiers do
    /// not change the ABI and are accepted, but the underlying encoding must
    /// agree with both the declared kind and scalar byte width.
    static func objectiveCEncodingMatchesKind(
        _ type: Core.NativeCall.ABIType
    ) -> Bool {
        encodedNativeTypeMatchesKind(type)
    }

    static func encodedNativeTypeMatchesKind(
        _ type: Core.NativeCall.ABIType
    ) -> Bool {
        guard type.kind != .void else { return type.encoding == nil }
        guard var encoding = type.encoding, !encoding.isEmpty else {
            return false
        }
        while let first = encoding.first, "rnNoORV".contains(first) {
            encoding.removeFirst()
        }
        guard let marker = encoding.first else { return false }
        switch type.kind {
        case .void, .bridgeValue:
            return false
        case .object:
            return marker == "@" && !encoding.hasPrefix("@?")
        case .classObject:
            return encoding == "#"
        case .selector:
            return encoding == ":"
        case .block:
            return encoding == "@?"
        case .boolean:
            return (encoding == "B" || encoding == "c") && type.size == 1
        case .signedInteger:
            return scalarEncoding(
                encoding,
                sizes: ["c": 1, "s": 2, "i": 4, "l": 8, "q": 8],
                declaredSize: type.size
            )
        case .unsignedInteger:
            return scalarEncoding(
                encoding,
                sizes: ["C": 1, "S": 2, "I": 4, "L": 8, "Q": 8],
                declaredSize: type.size
            )
        case .floatingPoint:
            return scalarEncoding(
                encoding,
                sizes: ["f": 4, "d": 8],
                declaredSize: type.size
            )
        case .structure:
            return marker == "{" && encoding.last == "}"
        case .pointer:
            return marker == "^" && encoding.count > 1
        }
    }

    static func scalarEncoding(
        _ encoding: String,
        sizes: [String: UInt16],
        declaredSize: UInt16?
    ) -> Bool {
        sizes[encoding] == declaredSize
    }

    static func target(
        canonicalCallee: String,
        backend: Core.NativeCall.Backend,
        kind: Core.NativeImportKind,
        signature: Core.LoweredSignature,
        receiverArgumentIndex explicitReceiver: UInt16?
    ) throws -> Core.NativeCall.Target {
        let canonical = try normalizeBoundText(
            canonicalCallee,
            label: "canonical native callee"
        )
        guard let firstDot = canonical.firstIndex(of: ".") else {
            throw Core.NativeCall.DescriptorError.invalid(
                "canonical native callee must begin with a module"
            )
        }
        let module = String(canonical[..<firstDot])
        let remainder = String(canonical[canonical.index(after: firstDot)...])
        let dispatch = dispatch(for: kind)
        let split = splitOwnerAndMember(
            remainder,
            kind: kind,
            dispatch: dispatch
        )
        let ownerCanonical = split.owner.map { "\(module).\($0)" }
        let normalizedOwner = try ownerCanonical.map(normalizeSwiftType)
        let normalizedRelativeOwner = try split.owner.map(normalizeSwiftType)
        let receiverIndex: UInt16?
        if dispatch == .instance {
            if let explicitReceiver {
                receiverIndex = explicitReceiver
            } else {
                let candidates: [UInt16] = signature.parameters.enumerated()
                    .compactMap { index, type in
                    let normalized = try? normalizeSwiftType(type)
                    guard normalized == normalizedOwner
                            || normalized == normalizedRelativeOwner
                    else { return nil }
                    return UInt16(exactly: index)
                }
                receiverIndex = candidates.only
            }
        } else {
            guard explicitReceiver == nil else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "non-instance native calls cannot name a receiver argument"
                )
            }
            receiverIndex = nil
        }
        guard dispatch != .instance || receiverIndex != nil else {
            throw Core.NativeCall.DescriptorError.invalid(
                "instance native call has no unambiguous receiver parameter"
            )
        }
        return .init(
            backend: backend,
            module: module,
            owner: split.owner,
            member: split.member,
            entryPoint: canonical,
            dispatch: dispatch,
            receiverArgumentIndex: receiverIndex
        )
    }

    static func splitOwnerAndMember(
        _ remainder: String,
        kind: Core.NativeImportKind,
        dispatch: Core.NativeCall.Dispatch
    ) -> (owner: String?, member: String) {
        guard dispatch != .global else { return (nil, remainder) }
        let parts = topLevelComponents(in: remainder)
        guard parts.count >= 2 else { return (nil, remainder) }
        let suffixCount: Int = switch kind {
        case .instanceGetter, .instanceSetter, .staticGetter, .staticSetter,
             .instanceSubscriptGetter, .instanceSubscriptSetter:
            2
        case .globalFunction, .initializer, .instanceMethod, .staticMethod,
             .serviceMethod:
            1
        }
        guard parts.count > suffixCount else { return (nil, remainder) }
        return (
            parts.dropLast(suffixCount).joined(separator: "."),
            parts.suffix(suffixCount).joined(separator: ".")
        )
    }

    /// Splits a qualified Swift spelling without treating dots in generic
    /// arguments, function parameters, or tuple types as owner separators.
    static func topLevelComponents(in value: String) -> [String] {
        var components: [String] = []
        var start = value.startIndex
        var stack: [Character] = []
        let closing: [Character: Character] = [
            ")": "(", "]": "[", "}": "{", ">": "<",
        ]
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            switch character {
            case "(", "[", "{", "<":
                stack.append(character)
            case ")", "]", "}", ">":
                if stack.last == closing[character] {
                    stack.removeLast()
                }
            case "." where stack.isEmpty:
                components.append(String(value[start..<index]))
                start = value.index(after: index)
            default:
                break
            }
            index = value.index(after: index)
        }
        components.append(String(value[start...]))
        return components
    }

    static func dispatch(
        for kind: Core.NativeImportKind
    ) -> Core.NativeCall.Dispatch {
        switch kind {
        case .globalFunction, .serviceMethod: .global
        case .initializer: .initializer
        case .instanceMethod, .instanceGetter, .instanceSetter,
             .instanceSubscriptGetter, .instanceSubscriptSetter: .instance
        case .staticMethod, .staticGetter, .staticSetter: .static
        }
    }

    static func ownership(from type: String) -> Core.NativeCall.Ownership {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("inout ") { return .inoutValue }
        if trimmed.hasPrefix("borrowing ") { return .borrowed }
        if trimmed.hasPrefix("consuming ") { return .consuming }
        return .owned
    }

    static func callbackLifetimes(
        _ callbacks: [Core.NativeImportCallback]
    ) -> [Int: Core.NativeImportCallbackLifetime] {
        var result: [Int: Core.NativeImportCallbackLifetime] = [:]
        for callback in callbacks {
            result[Int(callback.parameterIndex)] = callback.lifetime
        }
        return result
    }

    /// Separates the outer SIL value convention from the canonical Swift type.
    /// Nested attributes such as `@callee_guaranteed` remain part of a closure
    /// type; only the convention applying to this ABI slot is consumed here.
    static func parseSwiftABIValue(
        _ raw: String
    ) throws -> (type: String, convention: Core.NativeCall.ABIConvention) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("$") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let conventions: [(String, Core.NativeCall.ABIConvention)] = [
            ("@inout_aliasable ", .indirectInoutAliasable),
            ("@in_guaranteed ", .indirectInGuaranteed),
            ("@autoreleased ", .autoreleased),
            ("@guaranteed ", .directGuaranteed),
            ("@unowned ", .directUnowned),
            ("@owned ", .directOwned),
            ("@inout ", .indirectInout),
            ("@out ", .indirectOut),
            ("@in ", .indirectIn),
        ]
        let convention: Core.NativeCall.ABIConvention
        if let match = conventions.first(where: { value.hasPrefix($0.0) }) {
            value.removeFirst(match.0.count)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            convention = match.1
        } else {
            convention = .direct
        }
        if value.hasPrefix("$") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty else {
            throw Core.NativeCall.DescriptorError.invalid(
                "Swift ABI value has a convention but no type"
            )
        }
        return (value, convention)
    }

    static func isVoid(_ type: String) -> Bool {
        let normalized = try? normalizeSwiftType(type)
        return normalized == "Swift.Void" || normalized == "Void" || normalized == "()"
    }

    static func isCallableType(_ type: String) -> Bool {
        var value = type.trimmingCharacters(in: .whitespacesAndNewlines)
        while isOptionalSwiftType(value) {
            if value.hasSuffix("?") || value.hasSuffix("!") {
                value.removeLast()
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let open = value.firstIndex(of: "<"), value.hasSuffix(">") {
                value = String(value[value.index(after: open)..<value.index(
                    before: value.endIndex
                )]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                break
            }
        }
        while hasSingleGroupingParentheses(value) {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return containsTopLevelArrow(value)
    }

    static func isOptionalSwiftType(_ type: String) -> Bool {
        let value = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("?") || value.hasSuffix("!") { return true }
        guard let open = value.firstIndex(of: "<"), value.hasSuffix(">") else {
            return false
        }
        let wrapper = value[..<open].trimmingCharacters(in: .whitespaces)
        return wrapper == "Optional" || wrapper == "Swift.Optional"
    }

    static func normalizeABIType(
        _ type: Core.NativeCall.ABIType
    ) throws -> Core.NativeCall.ABIType {
        var result = type
        result.canonicalName = try type.canonicalName.map(normalizeSwiftType)
        result.encoding = try type.encoding.map {
            try normalizeBoundText($0, label: "native ABI encoding")
        }
        return result
    }

    static func validateABIType(
        _ type: Core.NativeCall.ABIType,
        allowingVoid: Bool
    ) throws {
        switch type.kind {
        case .void:
            guard allowingVoid,
                  type.canonicalName == nil,
                  type.size == nil,
                  type.alignment == nil,
                  type.encoding == nil,
                  !type.isNullable
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "Void has invalid physical ABI metadata"
                )
            }
        case .bridgeValue:
            guard let canonicalName = type.canonicalName else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "BridgeValue has no canonical physical type"
                )
            }
            let parsed = try parseSwiftABIValue(canonicalName)
            guard
                  type.size == nil,
                  type.alignment == nil,
                  type.encoding == nil,
                  !type.isNullable,
                  parsed.type == canonicalName,
                  parsed.convention == .direct
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "BridgeValue has invalid or embedded ABI convention metadata"
                )
            }
        case .object, .classObject, .selector, .block, .pointer:
            guard type.canonicalName != nil,
                  (type.size == nil) == (type.alignment == nil),
                  type.size.map({ size in
                      type.alignment.map {
                          isValidLayout(size: size, alignment: $0)
                      } ?? false
                  }) ?? true,
                  type.kind != .selector || !type.isNullable
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "pointer-like physical type has an invalid layout"
                )
            }
        case .boolean, .signedInteger, .unsignedInteger, .floatingPoint,
             .structure:
            guard let size = type.size, size > 0,
                  let alignment = type.alignment, alignment > 0,
                  isValidLayout(size: size, alignment: alignment),
                  type.canonicalName != nil,
                  !type.isNullable
            else {
                throw Core.NativeCall.DescriptorError.invalid(
                    "scalar or structure physical type has incomplete layout"
                )
            }
        }
    }

    static func isValidLayout(size: UInt16, alignment: UInt16) -> Bool {
        size > 0 && alignment > 0 && alignment <= size
            && alignment.nonzeroBitCount == 1
            && size.isMultiple(of: alignment)
    }

    static func normalizeSwiftType(_ value: String) throws -> String {
        let normalizedUnicode = value.precomposedStringWithCanonicalMapping
        let trimmed = normalizedUnicode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096,
              !trimmed.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              }),
              hasBalancedTypeDelimiters(trimmed)
        else {
            throw Core.NativeCall.DescriptorError.invalid(
                "Swift type spelling is empty, oversized, unbalanced, or contains control text"
            )
        }
        var output = ""
        var pendingSpace = false
        let punctuation = CharacterSet(charactersIn: "<>()[]{}.,:?!&=")
        let scalars = Array(trimmed.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = true
                index += 1
                continue
            }
            let isPunctuation = punctuation.contains(scalar)
                || scalar == "-" && index + 1 < scalars.count
                    && scalars[index + 1] == ">"
                || scalar == ">" && index > 0 && scalars[index - 1] == "-"
            let previousIsPunctuation = output.unicodeScalars.last.map {
                punctuation.contains($0) || $0 == "-" || $0 == ">"
            } ?? false
            if pendingSpace, !output.isEmpty, !isPunctuation,
               !previousIsPunctuation {
                output.append(" ")
            }
            output.unicodeScalars.append(scalar)
            pendingSpace = false
            index += 1
        }
        return output
    }

    static func hasSingleGroupingParentheses(_ value: String) -> Bool {
        guard value.first == "(", value.last == ")" else { return false }
        var depth = 0
        for index in value.indices {
            switch value[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0, index != value.index(before: value.endIndex) {
                    return false
                }
            default: break
            }
            if depth < 0 { return false }
        }
        guard depth == 0 else { return false }
        let body = value.dropFirst().dropLast()
        return !containsTopLevelComma(String(body))
    }

    static func containsTopLevelArrow(_ value: String) -> Bool {
        var stack: [Character] = []
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if character == "-", next < value.endIndex, value[next] == ">",
               stack.isEmpty {
                return true
            }
            updateDelimiterStack(character, previous: index == value.startIndex
                ? nil : value[value.index(before: index)], pairs: pairs, stack: &stack)
            index = next
        }
        return false
    }

    static func containsTopLevelComma(_ value: String) -> Bool {
        var stack: [Character] = []
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
        var previous: Character?
        for character in value {
            if character == ",", stack.isEmpty { return true }
            updateDelimiterStack(
                character,
                previous: previous,
                pairs: pairs,
                stack: &stack
            )
            previous = character
        }
        return false
    }

    static func hasBalancedTypeDelimiters(_ value: String) -> Bool {
        var stack: [Character] = []
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
        var previous: Character?
        for character in value {
            if let opening = pairs[character], character != ">" || previous != "-" {
                guard stack.last == opening else { return false }
                stack.removeLast()
            } else if ["(", "[", "{", "<"].contains(character) {
                stack.append(character)
            }
            previous = character
        }
        return stack.isEmpty
    }

    static func updateDelimiterStack(
        _ character: Character,
        previous: Character?,
        pairs: [Character: Character],
        stack: inout [Character]
    ) {
        if let opening = pairs[character], character != ">" || previous != "-" {
            if stack.last == opening { stack.removeLast() }
        } else if ["(", "[", "{", "<"].contains(character) {
            stack.append(character)
        }
    }

    static func normalizeIdentifierPath(
        _ value: String,
        label: String
    ) throws -> String {
        let normalized = try normalizeBoundText(value, label: label)
        let components = normalized.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty, components.allSatisfy(isSwiftIdentifier) else {
            throw Core.NativeCall.DescriptorError.invalid(
                "\(label) is not a canonical Swift identifier path"
            )
        }
        return normalized
    }

    static func normalizeArgumentLabel(_ value: String) throws -> String {
        let normalized = try normalizeBoundText(value, label: "argument label")
        guard isSwiftIdentifier(Substring(normalized)) else {
            throw Core.NativeCall.DescriptorError.invalid(
                "argument label is not a Swift identifier"
            )
        }
        return normalized
    }

    static func normalizePlatform(_ value: String) throws -> String {
        let normalized = try normalizeBoundText(value, label: "availability platform")
        let supported = [
            "iOS", "iOSApplicationExtension", "macOS",
            "macOSApplicationExtension", "macCatalyst",
            "macCatalystApplicationExtension", "tvOS",
            "tvOSApplicationExtension", "watchOS",
            "watchOSApplicationExtension", "visionOS",
            "visionOSApplicationExtension",
        ]
        guard supported.contains(normalized) else {
            throw Core.NativeCall.DescriptorError.invalid(
                "availability platform \(normalized) is unsupported"
            )
        }
        return normalized
    }

    static func normalizeSymbol(_ value: String) throws -> String {
        let normalized = try normalizeBoundText(value, label: "native symbol")
        guard normalized.utf8.allSatisfy({ $0 > 0x20 && $0 != 0x3a && $0 != 0x40 }) else {
            throw Core.NativeCall.DescriptorError.invalid(
                "native symbol contains unsafe bytes"
            )
        }
        return normalized
    }

    static func normalizeBoundText(_ value: String, label: String) throws -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 4_096,
              !normalized.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              })
        else {
            throw Core.NativeCall.DescriptorError.invalid(
                "\(label) is empty, oversized, or contains control text"
            )
        }
        return normalized
    }

    static func isSwiftIdentifier(_ value: Substring) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
