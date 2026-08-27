import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
#endif

public enum InterfaceArchive {}

extension InterfaceArchive {
public struct Patchability: Codable, Hashable, Sendable {
    public var isEligible: Bool
    public var reasonCode: String?
    public var explanation: String?

    public init(isEligible: Bool, reasonCode: String? = nil, explanation: String? = nil) {
        self.isEligible = isEligible
        self.reasonCode = reasonCode
        self.explanation = explanation
    }

    public static let eligible = Self(isEligible: true)

    public static func rejected(_ reasonCode: String, explanation: String) -> Self {
        Self(isEligible: false, reasonCode: reasonCode, explanation: explanation)
    }
}

public struct SourceRecord: Codable, Hashable, Sendable {
    public var logicalPath: String
    public var contentHash: Core.Digest
    public var transformHash: Core.Digest?

    public init(logicalPath: String, contentHash: Core.Digest, transformHash: Core.Digest? = nil) {
        self.logicalPath = logicalPath
        self.contentHash = contentHash
        self.transformHash = transformHash
    }
}

public struct FunctionRecord: Codable, Hashable, Sendable {
    public var key: Core.FunctionKey
    public var entryIndex: Core.EntryIndex?
    public var moduleName: String
    public var sourceFileLogicalID: String
    public var canonicalDeclaration: String
    public var mangledName: String
    public var role: Core.FunctionRole
    public var loweredSignature: Core.LoweredSignature
    public var parameterTypes: [Bytecode.ValueType]
    public var parameterConventions: [Bytecode.ParameterConvention]
    public var resultType: Bytecode.ValueType
    public var effects: Core.Effects
    public var interfaceFingerprint: Core.Digest
    public var bodyFingerprint: Core.Digest
    public var patchability: InterfaceArchive.Patchability
    public var fallbackAllowed: Bool
    public var bridgeSymbol: String?

    public init(
        key: Core.FunctionKey,
        entryIndex: Core.EntryIndex?,
        moduleName: String,
        sourceFileLogicalID: String,
        canonicalDeclaration: String,
        mangledName: String,
        role: Core.FunctionRole,
        loweredSignature: Core.LoweredSignature,
        parameterTypes: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention]? = nil,
        resultType: Bytecode.ValueType,
        effects: Core.Effects,
        interfaceFingerprint: Core.Digest,
        bodyFingerprint: Core.Digest,
        patchability: InterfaceArchive.Patchability,
        fallbackAllowed: Bool = false,
        bridgeSymbol: String? = nil
    ) {
        self.key = key
        self.entryIndex = entryIndex
        self.moduleName = moduleName
        self.sourceFileLogicalID = sourceFileLogicalID
        self.canonicalDeclaration = canonicalDeclaration
        self.mangledName = mangledName
        self.role = role
        self.loweredSignature = loweredSignature
        self.parameterTypes = parameterTypes
        self.parameterConventions = parameterConventions
            ?? Array(repeating: .owned, count: parameterTypes.count)
        self.resultType = resultType
        self.effects = effects
        self.interfaceFingerprint = interfaceFingerprint
        self.bodyFingerprint = bodyFingerprint
        self.patchability = patchability
        self.fallbackAllowed = fallbackAllowed
        self.bridgeSymbol = bridgeSymbol
    }
}

public enum NativeImportABIAdapter: String, Codable, Hashable, Sendable {
    /// The generated invoker has the same value signature as canonical SIL.
    case direct
    /// Canonical SIL mutates its final value receiver through an address and
    /// returns Void; the VM adapter accepts/returns that receiver as values.
    case mutatingValueReceiver
}

public struct NativeImportRecord: Codable, Hashable, Sendable {
    public var id: Core.NativeImportID?
    public var key: Core.NativeCall.Key
    public var descriptor: Core.NativeCall.Descriptor
    /// Exact canonical-SIL symbols accepted for this typed native import.
    /// These stay server-side and never become runtime symbol lookup authority.
    public var silMangledNames: [String]
    public var parameterTypes: [Bytecode.ValueType]
    public var parameterProjection: InterfaceArchive.NativeImportParameterProjection
    public var resultType: Bytecode.ValueType
    public var contract: Core.NativeImportContract {
        didSet {
            descriptor.replaceCallbackLifetimes(contract.callbacks)
        }
    }
    public var capability: Core.Capability
    public var isEmittedToDevice: Bool
    public var abiAdapter: InterfaceArchive.NativeImportABIAdapter

    public init(
        id: Core.NativeImportID?,
        key: Core.NativeCall.Key,
        descriptor: Core.NativeCall.Descriptor,
        silMangledNames: [String],
        parameterTypes: [Bytecode.ValueType],
        parameterProjection: InterfaceArchive.NativeImportParameterProjection? = nil,
        resultType: Bytecode.ValueType,
        contract: Core.NativeImportContract,
        capability: Core.Capability = .nativeImportsV1,
        isEmittedToDevice: Bool,
        abiAdapter: InterfaceArchive.NativeImportABIAdapter = .direct
    ) {
        self.id = id
        self.key = key
        self.descriptor = descriptor
        self.silMangledNames = silMangledNames.sorted()
        self.parameterTypes = parameterTypes
        self.parameterProjection = parameterProjection
            ?? .identity(parameterCount: parameterTypes.count)
        self.resultType = resultType
        self.contract = contract
        self.capability = capability
        self.isEmittedToDevice = isEmittedToDevice
        self.abiAdapter = abiAdapter
    }

    public var canonicalCallee: String { descriptor.canonicalCallee }
    public var signature: Core.LoweredSignature {
        get { descriptor.loweredSignature }
        set {
            descriptor.replaceLogicalSignature(
                newValue,
                callbacks: contract.callbacks
            )
        }
    }
    public var effects: Core.Effects {
        get { descriptor.effects }
        set { descriptor.effects = newValue }
    }
}

public enum TypeKind: String, Codable, Hashable, Sendable {
    case value
    case reference
    case enumeration
}

public struct TypeRecord: Codable, Hashable, Sendable {
    public var id: Core.TypeID
    public var canonicalName: String
    /// Compiler-proven Swift/SIL spellings for the same native identity.
    /// These are patch-compiler metadata and are intentionally excluded from
    /// the device projection.
    public var swiftTypeAliases: [String]
    public var kind: InterfaceArchive.TypeKind
    public var layoutFingerprint: Core.Digest
    /// Exact Objective-C runtime class identity for data-driven reference
    /// TypeOps. Nil means the Shell must provide a statically typed factory.
    public var objectiveCRuntimeName: String?
    public var isCopyable: Bool
    public var requiresMainActor: Bool
    public var isEmittedToDevice: Bool
    public var estimatedSize: UInt64

    public init(
        id: Core.TypeID,
        canonicalName: String,
        swiftTypeAliases: [String] = [],
        kind: InterfaceArchive.TypeKind,
        layoutFingerprint: Core.Digest,
        objectiveCRuntimeName: String? = nil,
        isCopyable: Bool,
        requiresMainActor: Bool = false,
        isEmittedToDevice: Bool,
        estimatedSize: UInt64
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.swiftTypeAliases = swiftTypeAliases
        self.kind = kind
        self.layoutFingerprint = layoutFingerprint
        self.objectiveCRuntimeName = objectiveCRuntimeName
        self.isCopyable = isCopyable
        self.requiresMainActor = requiresMainActor
        self.isEmittedToDevice = isEmittedToDevice
        self.estimatedSize = estimatedSize
    }
}

/// The semantic Swift frontend inputs that must be replayed for a patch build.
/// Source paths, output actions, and the compiler executable are supplied by the
/// Patch Driver and therefore cannot be overridden by the archive.
public struct FrontendInvocation: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var moduleName: String
    public var targetTriple: String
    public var sdkName: String
    public var sdkBuild: String
    public var optimization: String
    public var semanticArguments: [String]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        moduleName: String,
        targetTriple: String,
        sdkName: String,
        sdkBuild: String,
        optimization: String = "-O",
        semanticArguments: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.moduleName = moduleName
        self.targetTriple = targetTriple
        self.sdkName = sdkName
        self.sdkBuild = sdkBuild
        self.optimization = optimization
        self.semanticArguments = semanticArguments
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw InterfaceArchive.Error.invalidArchive("unsupported frontend invocation schema")
        }
        guard Self.isSwiftIdentifier(moduleName), !targetTriple.isEmpty,
              sdkName == "iphoneos" || sdkName == "iphonesimulator",
              !sdkBuild.isEmpty,
              ["-Onone", "-O", "-Osize"].contains(optimization)
        else {
            throw InterfaceArchive.Error.invalidArchive("frontend invocation identity is invalid")
        }
        let simulatorTarget = targetTriple.lowercased().contains("simulator")
        guard targetTriple.lowercased().contains("-apple-ios"),
              simulatorTarget == (sdkName == "iphonesimulator")
        else {
            throw InterfaceArchive.Error.invalidArchive("frontend target and SDK platform disagree")
        }
        guard semanticArguments.count <= 4_096,
              semanticArguments.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576
        else {
            throw InterfaceArchive.Error.invalidArchive("frontend semantic arguments exceed limits")
        }
        let reserved = Set([
            "-o", "-c", "-emit-sil", "-emit-silgen", "-emit-ir", "-emit-bc",
            "-emit-object", "-emit-executable", "-emit-library", "-module-name",
            "-target", "-sdk", "-primary-file", "-filelist", "-output-file-map",
            "-Onone", "-O", "-Osize", "-Ounchecked",
        ])
        for argument in semanticArguments {
            let lowered = argument.lowercased()
            guard !argument.isEmpty,
                  !argument.hasPrefix("@"),
                  !argument.hasSuffix(".swift"),
                  !reserved.contains(argument),
                  !argument.hasPrefix("-emit-"),
                  !lowered.contains("plugin"),
                  lowered != "-load",
                  lowered != "-xclang",
                  lowered != "-xllvm",
                  !lowered.contains("load-library"),
                  !argument.unicodeScalars.contains(where: { $0.value == 0 })
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "unsafe or reserved frontend argument \(argument)"
                )
            }
        }
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }
}

public struct ReleaseMetadata: Codable, Hashable, Sendable {
    public var bundleID: String
    public var buildNumber: String
    public var shellNamespaceID: Core.ShellNamespaceID
    public var machOUUIDs: [UUID]
    public var targetTriple: String
    public var minimumOS: Core.SemanticVersion
    public var xcodeBuild: String
    public var sdkBuild: String
    public var frontendInvocation: InterfaceArchive.FrontendInvocation
    public var transformPipelineHash: Core.Digest
    public var sourceBaselineHash: Core.Digest

    public init(
        bundleID: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        machOUUIDs: [UUID],
        targetTriple: String,
        minimumOS: Core.SemanticVersion,
        xcodeBuild: String,
        sdkBuild: String,
        frontendInvocation: InterfaceArchive.FrontendInvocation,
        transformPipelineHash: Core.Digest,
        sourceBaselineHash: Core.Digest
    ) {
        self.bundleID = bundleID
        self.buildNumber = buildNumber
        self.shellNamespaceID = shellNamespaceID
        self.machOUUIDs = machOUUIDs
        self.targetTriple = targetTriple
        self.minimumOS = minimumOS
        self.xcodeBuild = xcodeBuild
        self.sdkBuild = sdkBuild
        self.frontendInvocation = frontendInvocation
        self.transformPipelineHash = transformPipelineHash
        self.sourceBaselineHash = sourceBaselineHash
    }
}

public struct Archive: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var metadata: InterfaceArchive.ReleaseMetadata
    public var compatibility: Core.Compatibility
    public var shellInterfaceHash: Core.Digest
    public var capabilities: [Core.Capability]
    public var sources: [InterfaceArchive.SourceRecord]
    public var functions: [InterfaceArchive.FunctionRecord]
    public var nativeImports: [InterfaceArchive.NativeImportRecord]
    public var nativeTypes: [InterfaceArchive.TypeRecord]
    public var frozenValueTypes: [InterfaceArchive.FrozenValueTypeRecord]
    public var bridgeRegistrationCount: UInt32

    public static func make(
        metadata: InterfaceArchive.ReleaseMetadata,
        compatibility: Core.Compatibility,
        capabilities: Set<Core.Capability>,
        sources: [InterfaceArchive.SourceRecord],
        functions: [InterfaceArchive.FunctionRecord],
        nativeImports: [InterfaceArchive.NativeImportRecord] = [],
        nativeTypes: [InterfaceArchive.TypeRecord] = [],
        frozenValueTypes: [InterfaceArchive.FrozenValueTypeRecord] = [],
        bridgeRegistrationCount: UInt32
    ) throws -> Self {
        let zero = try Core.Digest(bytes: repeatElement(UInt8(0), count: Core.Digest.byteCount))
        var archive = Self(
            schemaVersion: currentSchemaVersion,
            metadata: metadata,
            compatibility: compatibility,
            shellInterfaceHash: zero,
            capabilities: capabilities.sorted(),
            sources: sources,
            functions: functions,
            nativeImports: nativeImports,
            nativeTypes: nativeTypes,
            frozenValueTypes: frozenValueTypes,
            bridgeRegistrationCount: bridgeRegistrationCount
        ).normalized()
        archive.shellInterfaceHash = try archive.computeShellInterfaceHash()
        try archive.validate()
        return archive
    }

    public func normalized() -> Self {
        var value = self
        value.metadata.machOUUIDs.sort { $0.uuidString < $1.uuidString }
        value.capabilities = Array(Set(value.capabilities)).sorted()
        value.sources.sort { $0.logicalPath < $1.logicalPath }
        value.functions.sort { $0.key.rawValue < $1.key.rawValue }
        value.nativeImports.sort {
            switch ($0.id, $1.id) {
            case let (.some(lhs), .some(rhs)): lhs < rhs
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): $0.key.rawValue < $1.key.rawValue
            }
        }
        for index in value.nativeImports.indices {
            value.nativeImports[index].silMangledNames = Array(
                Set(value.nativeImports[index].silMangledNames)
            ).sorted()
        }
        value.nativeTypes.sort { $0.id.rawValue < $1.id.rawValue }
        for index in value.nativeTypes.indices {
            let canonicalName = value.nativeTypes[index].canonicalName
            value.nativeTypes[index].swiftTypeAliases = Array(Set(
                value.nativeTypes[index].swiftTypeAliases.filter {
                    $0 != canonicalName
                }
            )).sorted()
        }
        value.frozenValueTypes.sort { $0.key < $1.key }
        return value
    }

    public func computeShellInterfaceHash() throws -> Core.Digest {
        var hasher = Core.StableHasher(domain: "HLXI.DeviceProjection.v1")
        hasher.append(try Core.CanonicalJSON.encode(deviceProjection()))
        return hasher.finalize()
    }

    public func archiveDigest() throws -> Core.Digest {
        var copy = normalized()
        copy.shellInterfaceHash = try copy.computeShellInterfaceHash()
        var hasher = Core.StableHasher(domain: "HLXI.Archive.v1")
        hasher.append(try Core.CanonicalJSON.encode(copy))
        return hasher.finalize()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw InterfaceArchive.Error.unsupportedSchema(schemaVersion)
        }
        guard compatibility.runtime == Core.Versions.runtime,
              compatibility.bytecode == Core.Versions.bytecode,
              compatibility.interfaceArchive == Core.Versions.interfaceArchive
        else {
            throw InterfaceArchive.Error.invalidArchive(
                "archive compatibility must match the current Helix 1.0 formats"
            )
        }
        guard !metadata.bundleID.isEmpty, !metadata.buildNumber.isEmpty,
              !metadata.targetTriple.isEmpty, !metadata.xcodeBuild.isEmpty,
              !metadata.sdkBuild.isEmpty, !compatibility.compilerFingerprint.isEmpty
        else {
            throw InterfaceArchive.Error.invalidArchive("release or toolchain identity is incomplete")
        }
        try metadata.frontendInvocation.validate()
        guard metadata.frontendInvocation.targetTriple == metadata.targetTriple,
              metadata.frontendInvocation.sdkBuild == metadata.sdkBuild,
              Set(functions.map(\.moduleName)) == [metadata.frontendInvocation.moduleName]
        else {
            throw InterfaceArchive.Error.invalidArchive(
                "frontend invocation does not describe the archived module, target, and SDK"
            )
        }
        guard capabilities.contains(.baselineV1) else {
            throw InterfaceArchive.Error.invalidArchive("baseline capability is missing")
        }
        guard Set(capabilities).count == capabilities.count else {
            throw InterfaceArchive.Error.invalidArchive("capabilities are not unique")
        }
        try validateFrozenValueTypes()
        guard shellInterfaceHash.constantTimeEquals(try computeShellInterfaceHash()) else {
            throw InterfaceArchive.Error.interfaceHashMismatch
        }
        guard Set(sources.map(\.logicalPath)).count == sources.count,
              sources.allSatisfy({ Self.isSafeLogicalPath($0.logicalPath) })
        else {
            throw InterfaceArchive.Error.invalidArchive("source paths are duplicate, absolute, or traversing")
        }
        guard Set(functions.map(\.key)).count == functions.count,
              Set(functions.map(\.mangledName)).count == functions.count
        else {
            throw InterfaceArchive.Error.invalidArchive("function identities are not unique")
        }
        let sourcePaths = Set(sources.map(\.logicalPath))
        for function in functions {
            guard sourcePaths.contains(function.sourceFileLogicalID) else {
                throw InterfaceArchive.Error.invalidArchive("function references an unknown source")
            }
            let expected = try Core.FunctionKey.derive(
                namespace: metadata.shellNamespaceID,
                module: function.moduleName,
                sourceFileLogicalID: function.sourceFileLogicalID,
                canonicalDeclaration: function.canonicalDeclaration,
                loweredSignature: function.loweredSignature,
                role: function.role
            )
            guard expected == function.key else {
                throw InterfaceArchive.Error.invalidArchive("function key derivation mismatch")
            }
            guard function.loweredSignature.isThrowing == function.effects.mayThrow,
                  function.loweredSignature.isAsync == function.effects.isAsync
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "function lowered signature and effects disagree"
                )
            }
            let conventions = function.parameterConventions
            guard conventions.count == function.parameterTypes.count else {
                throw InterfaceArchive.Error.invalidArchive(
                    "function parameter convention count is inconsistent"
                )
            }
            if conventions.contains(.inout),
               !capabilities.contains(.addressValuesV1) {
                throw InterfaceArchive.Error.invalidArchive(
                    "inout helper requires the address-values capability"
                )
            }
            if conventions.contains(.borrowed),
               !capabilities.contains(.borrowCallsV1) {
                throw InterfaceArchive.Error.invalidArchive(
                    "borrowed helper requires the borrow-calls capability"
                )
            }
        }
        let eligible = functions.filter(\.patchability.isEligible)
        guard eligible.allSatisfy({ function in
            function.parameterConventions.filter({ $0 == .inout }).count <= 1
                && !(function.effects.isAsync
                    && function.parameterConventions.contains(.inout))
        }) else {
            throw InterfaceArchive.Error.invalidArchive(
                "Shell entries support one synchronous inout writeback region"
            )
        }
        guard eligible.allSatisfy({ $0.entryIndex != nil }),
              functions.filter({ !$0.patchability.isEligible }).allSatisfy({ $0.entryIndex == nil }),
              Set(eligible.compactMap(\.entryIndex)).count == eligible.count,
              eligible.compactMap(\.entryIndex).sorted().enumerated().allSatisfy({ offset, entry in
                  UInt32(exactly: offset) == entry.rawValue
              }),
              eligible.allSatisfy({ $0.bridgeSymbol != nil }),
              Set(eligible.compactMap(\.bridgeSymbol)).count == eligible.count
        else {
            throw InterfaceArchive.Error.invalidArchive("entry allocation disagrees with patchability")
        }
        guard functions.filter({ !$0.patchability.isEligible }).allSatisfy({ !$0.fallbackAllowed }) else {
            throw InterfaceArchive.Error.invalidArchive("an ineligible function enables fallback")
        }
        let emittedImports = nativeImports.filter(\.isEmittedToDevice)
        guard emittedImports.allSatisfy({ $0.id != nil }),
              nativeImports.filter({ !$0.isEmittedToDevice }).allSatisfy({ $0.id == nil }),
              Set(emittedImports.compactMap(\.id)).count == emittedImports.count,
              emittedImports.compactMap(\.id).sorted().enumerated().allSatisfy({ offset, id in
                  UInt32(exactly: offset) == id.rawValue
              }),
              Set(nativeImports.map(\.key)).count == nativeImports.count,
              nativeImports.allSatisfy({ item in
                  !item.canonicalCallee.isEmpty
                      && !item.silMangledNames.isEmpty
                      && item.silMangledNames == Array(Set(item.silMangledNames)).sorted()
                      && item.silMangledNames.allSatisfy(Self.isValidSILSymbol)
              })
        else {
            throw InterfaceArchive.Error.invalidArchive("native import allocation is inconsistent")
        }
        let nativeVariantsBySymbol = Dictionary(grouping: nativeImports.flatMap { item in
            item.silMangledNames.map { ($0, item) }
        }, by: { $0.0 })
        for (symbol, pairs) in nativeVariantsBySymbol where pairs.count > 1 {
            let variants = pairs.map(\.1)
            guard let first = variants.first else { continue }
            var baseContract = first.contract
            baseContract.callbacks = []
            var parameterTypeByPhysicalIndex: [UInt16: Bytecode.ValueType] = [:]
            var defaultByPhysicalIndex: [
                UInt16: InterfaceArchive.NativeImportDefaultArgument
            ] = [:]
            var projections = Set<[UInt16]>()
            var callbackLifetimeByPhysicalIndex: [
                UInt16: Core.NativeImportCallbackLifetime
            ] = [:]
            for variant in variants {
                var variantBaseContract = variant.contract
                variantBaseContract.callbacks = []
                guard variant.parameterProjection.physicalParameterCount
                        == first.parameterProjection.physicalParameterCount,
                      variant.resultType == first.resultType,
                      variant.effects == first.effects,
                      variantBaseContract == baseContract,
                      variant.capability == first.capability,
                      variant.isEmittedToDevice == first.isEmittedToDevice,
                      variant.abiAdapter == first.abiAdapter,
                      projections.insert(
                          variant.parameterProjection.logicalParameterIndices
                      ).inserted
                else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "native import symbol \(symbol) has inconsistent physical variants"
                    )
                }
                for (physicalIndex, type) in zip(
                    variant.parameterProjection.logicalParameterIndices,
                    variant.parameterTypes
                ) {
                    if let existing = parameterTypeByPhysicalIndex[physicalIndex],
                       existing != type {
                        throw InterfaceArchive.Error.invalidArchive(
                            "native import symbol \(symbol) changes a physical parameter type"
                        )
                    }
                    parameterTypeByPhysicalIndex[physicalIndex] = type
                }
                for defaultArgument in variant.parameterProjection.defaultArguments {
                    let index = defaultArgument.physicalParameterIndex
                    if let existing = defaultByPhysicalIndex[index],
                       existing != defaultArgument {
                        throw InterfaceArchive.Error.invalidArchive(
                            "native import symbol \(symbol) changes default-argument provenance"
                        )
                    }
                    defaultByPhysicalIndex[index] = defaultArgument
                }
                for callback in variant.contract.callbacks {
                    let logicalIndex = Int(callback.parameterIndex)
                    guard variant.parameterProjection.logicalParameterIndices.indices
                        .contains(logicalIndex)
                    else {
                        throw InterfaceArchive.Error.invalidArchive(
                            "native import symbol \(symbol) has an invalid callback projection"
                        )
                    }
                    let physicalIndex = variant.parameterProjection
                        .logicalParameterIndices[logicalIndex]
                    if let existing = callbackLifetimeByPhysicalIndex[
                        physicalIndex
                    ], existing != callback.lifetime {
                        throw InterfaceArchive.Error.invalidArchive(
                            "native import symbol \(symbol) changes a physical callback lifetime"
                        )
                    }
                    callbackLifetimeByPhysicalIndex[physicalIndex] =
                        callback.lifetime
                }
            }
        }
        for item in nativeImports {
            let normalizedIsolation = item.signature.isolation.map {
                $0 == "Swift.MainActor" ? "MainActor" : $0
            }
            guard item.signature.parameters.count == item.parameterTypes.count,
                  !item.signature.result.isEmpty,
                  item.signature.isThrowing == item.effects.mayThrow,
                  item.signature.isAsync == item.effects.isAsync,
                  normalizedIsolation == nil || normalizedIsolation == "MainActor",
                  (normalizedIsolation == "MainActor")
                    == item.effects.requiresMainActor,
                  item.parameterProjection.isValid(
                      logicalParameterCount: item.parameterTypes.count
                  )
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import signature, effects, or physical parameter projection disagree"
                )
            }
            if item.isEmittedToDevice, !capabilities.contains(item.capability) {
                throw InterfaceArchive.Error.invalidArchive("emitted native import capability is absent")
            }
            do {
                try item.descriptor.validate(contract: item.contract)
                guard try Core.NativeCall.Key.derive(
                    descriptor: item.descriptor
                ) == item.key else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "native import key derivation mismatch"
                    )
                }
            } catch let error as InterfaceArchive.Error {
                throw error
            } catch {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import descriptor or contract is invalid: \(error)"
                )
            }
            guard item.capability == .nativeImportsV1 else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import does not use the current contract capability"
                )
            }
            let callbackByIndex = Dictionary(
                uniqueKeysWithValues: item.contract.callbacks.map {
                    (Int($0.parameterIndex), $0)
                }
            )
            guard callbackByIndex.count == item.contract.callbacks.count,
                  callbackByIndex.keys.allSatisfy(
                      item.parameterTypes.indices.contains
                  )
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import callback parameters are inconsistent"
                )
            }
            for (index, type) in item.parameterTypes.enumerated() {
                if let callback = callbackByIndex[index] {
                    guard capabilities.contains(.closureValuesV1),
                          callback.lifetime != .escaping
                            || capabilities.contains(.escapingClosureValuesV1),
                          let shape = type.directClosureShape,
                          shape.signature.isNativeBridgeCallback,
                          !shape.signature.parameters.contains(
                              where: \.containsClosureValue
                          ) || capabilities.contains(.escapingClosureValuesV1),
                          !(callback.lifetime == .nonescaping && shape.isOptional)
                    else {
                        throw InterfaceArchive.Error.invalidArchive(
                            "native import has an unsupported callback signature"
                        )
                    }
                } else if type.containsClosureValue {
                    throw InterfaceArchive.Error.invalidArchive(
                        "native import closure parameter has no callback lifetime contract"
                    )
                }
            }
            if item.abiAdapter == .mutatingValueReceiver {
                guard item.parameterTypes.count >= 1,
                      case let .native(receiver) = item.parameterTypes.last,
                      item.resultType == .native(receiver),
                      !item.effects.mayThrow,
                      !item.effects.isAsync
                else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "mutating value-receiver NativeImport has an invalid adapter signature"
                    )
                }
            }
        }
        if !emittedImports.isEmpty, !capabilities.contains(.nativeImportsV1) {
            throw InterfaceArchive.Error.invalidArchive("native import capability is absent")
        }
        guard !capabilities.contains(.hostedObjectiveCClassesV1)
                || capabilities.contains(.localClassesV1)
        else {
            throw InterfaceArchive.Error.invalidArchive(
                "hosted Objective-C classes require local class support"
            )
        }
        guard Set(nativeTypes.map(\.id)).count == nativeTypes.count else {
            throw InterfaceArchive.Error.invalidArchive("native type identities are not unique")
        }
        for type in nativeTypes {
            guard !type.canonicalName.isEmpty,
                  type.swiftTypeAliases.count <= 32,
                  type.swiftTypeAliases == Array(Set(
                      type.swiftTypeAliases
                  )).sorted(),
                  !type.swiftTypeAliases.contains(type.canonicalName),
                  type.swiftTypeAliases.allSatisfy(
                      Self.isValidNativeTypeAlias
                  ),
                  type.objectiveCRuntimeName.map(
                      Core.NativeCall.isCanonicalObjectiveCRuntimeClassName
                  ) ?? true,
                  type.objectiveCRuntimeName == nil || (
                      type.kind == .reference
                          && type.isCopyable
                          && type.estimatedSize > 0
                  ),
                  Core.TypeID.derive(
                      namespace: metadata.shellNamespaceID,
                      canonicalType: type.canonicalName
                  ) == type.id else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native type identity or alias metadata is invalid"
                )
            }
        }
        if nativeTypes.contains(where: \.isEmittedToDevice),
           !capabilities.contains(.nativeTypesV1) {
            throw InterfaceArchive.Error.invalidArchive("native type capability is absent")
        }
        let emittedTypeIDs = Set(nativeTypes.filter(\.isEmittedToDevice).map(\.id))
        let mainActorTypeIDs = Set(
            nativeTypes.filter { $0.isEmittedToDevice && $0.requiresMainActor }.map(\.id)
        )
        let frozenValueTypeKeys = Set(frozenValueTypes.map(\.key))
        func validateDeviceType(
            _ type: Bytecode.ValueType,
            allowingError: Bool = false,
            allowingFrozenValue: Bool = false,
            depth: Int = 0
        ) throws {
            guard depth <= 32 else {
                throw InterfaceArchive.Error.invalidArchive(
                    "device signature type nesting exceeds 32 levels"
                )
            }
            switch type {
            case .string:
                guard capabilities.contains(.stringsV1) else {
                    throw InterfaceArchive.Error.invalidArchive("String capability is absent")
                }
            case .any:
                guard capabilities.contains(.anyValuesV1) else {
                    throw InterfaceArchive.Error.invalidArchive("Any capability is absent")
                }
            case .error:
                guard allowingError,
                      capabilities.contains(.structuredErrorsV1)
                else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "Error is supported only in a NativeImport callback parameter with the required capability"
                    )
                }
            case let .native(id):
                guard capabilities.contains(.nativeTypesV1), emittedTypeIDs.contains(id) else {
                    throw InterfaceArchive.Error.invalidArchive("device signature references an un-emitted native type")
                }
            case let .array(element):
                guard capabilities.contains(.collectionsV1) else {
                    throw InterfaceArchive.Error.invalidArchive("Array capability is absent")
                }
                try validateDeviceType(
                    element,
                    allowingError: allowingError,
                    allowingFrozenValue: allowingFrozenValue,
                    depth: depth + 1
                )
            case let .dictionary(key, value):
                guard capabilities.contains(.collectionsV1) else {
                    throw InterfaceArchive.Error.invalidArchive("Dictionary capability is absent")
                }
                guard key.isVMHashable else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "Dictionary key lacks VM-defined Hashable semantics"
                    )
                }
                try validateDeviceType(
                    key,
                    allowingError: allowingError,
                    allowingFrozenValue: allowingFrozenValue,
                    depth: depth + 1
                )
                try validateDeviceType(
                    value,
                    allowingError: allowingError,
                    allowingFrozenValue: allowingFrozenValue,
                    depth: depth + 1
                )
            case let .set(element):
                guard capabilities.contains(.collectionsV1), element.isVMHashable else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "Set requires collection capability and a VM-defined Hashable element"
                    )
                }
                try validateDeviceType(
                    element,
                    allowingError: allowingError,
                    allowingFrozenValue: allowingFrozenValue,
                    depth: depth + 1
                )
            case let .tuple(elements):
                for element in elements {
                    try validateDeviceType(
                        element,
                        allowingError: allowingError,
                        allowingFrozenValue: allowingFrozenValue,
                        depth: depth + 1
                    )
                }
            case let .optional(wrapped):
                try validateDeviceType(
                    wrapped,
                    allowingError: allowingError,
                    allowingFrozenValue: allowingFrozenValue,
                    depth: depth + 1
                )
            case .float:
                break
            case let .local(key):
                guard allowingFrozenValue,
                      capabilities.contains(.localNominalsV1),
                      frozenValueTypeKeys.contains(key)
                else {
                    throw InterfaceArchive.Error.invalidArchive(
                        "device signature references a Shell value type absent from the index"
                    )
                }
            case .address, .mutableCell, .nonOwningReference, .arrayState,
                 .dictionaryState, .closure:
                throw InterfaceArchive.Error.invalidArchive(
                    "internal storage and closure values cannot appear in a Shell signature"
                )
            case .void, .never, .bool, .integer:
                break
            }
        }
        func validateDeviceEffects(_ effects: Core.Effects) throws {
            if effects.mayThrow {
                guard capabilities.contains(.untypedThrowsV1) else {
                    throw InterfaceArchive.Error.invalidArchive("untyped throws capability is absent")
                }
            }
            if effects.requiresMainActor, !capabilities.contains(.mainActorIsolationV1) {
                throw InterfaceArchive.Error.invalidArchive("MainActor capability is absent")
            }
            if effects.isAsync, !capabilities.contains(.sequentialAsyncV1) {
                throw InterfaceArchive.Error.invalidArchive(
                    "sequential async capability is absent"
                )
            }
        }
        func validateNativeCallable(
            _ signature: Bytecode.ClosureSignature
        ) throws {
            guard capabilities.contains(.closureValuesV1),
                  capabilities.contains(.escapingClosureValuesV1),
                  signature.isNativeBridgeCallable
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import has an unsupported native callable"
                )
            }
            for parameter in signature.parameters {
                try validateDeviceType(parameter, allowingError: true)
            }
            try validateDeviceType(signature.result, allowingError: true)
            try validateDeviceEffects(signature.effects)
        }
        func usesMainActorType(_ type: Bytecode.ValueType) -> Bool {
            switch type {
            case let .native(id): mainActorTypeIDs.contains(id)
            case let .array(element), let .optional(element), let .set(element):
                usesMainActorType(element)
            case let .dictionary(key, value):
                usesMainActorType(key) || usesMainActorType(value)
            case let .tuple(elements):
                elements.contains(where: usesMainActorType)
            case let .closure(signature):
                signature.componentTypes.contains(where: usesMainActorType)
            case let .mutableCell(pointee):
                usesMainActorType(pointee)
            case let .nonOwningReference(_, pointee):
                usesMainActorType(pointee)
            case let .arrayState(_, element):
                usesMainActorType(element)
            case let .dictionaryState(key, value):
                usesMainActorType(key) || usesMainActorType(value)
            case .void, .never, .bool, .integer, .float, .string, .any, .local,
                 .error, .address:
                false
            }
        }
        for function in eligible {
            for type in function.parameterTypes + [function.resultType] {
                try validateDeviceType(type, allowingFrozenValue: true)
            }
            guard function.effects.requiresMainActor
                    || !(function.parameterTypes + [function.resultType]).contains(
                        where: usesMainActorType
                    )
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "function \(function.canonicalDeclaration) moves a MainActor native type off actor"
                )
            }
            try validateDeviceEffects(function.effects)
        }
        for item in emittedImports {
            let callbackIndices = Set(item.contract.callbacks.map {
                Int($0.parameterIndex)
            })
            for (index, type) in item.parameterTypes.enumerated() {
                if callbackIndices.contains(index),
                   let shape = type.directClosureShape {
                    try validateDeviceEffects(shape.signature.effects)
                    for parameter in shape.signature.parameters {
                        if let callable = parameter.directClosureShape {
                            try validateNativeCallable(
                                callable.signature
                            )
                        } else {
                            try validateDeviceType(
                                parameter,
                                allowingError: true
                            )
                        }
                    }
                    try validateDeviceType(shape.signature.result)
                } else {
                    guard type.isOrdinaryNativeImportBridgeValue else {
                        throw InterfaceArchive.Error.invalidArchive(
                            "native import has an unsupported ordinary parameter"
                        )
                    }
                    try validateDeviceType(type)
                }
            }
            guard item.resultType.isNativeImportBridgeResult else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import has an unsupported result"
                )
            }
            if let callable = item.resultType.directClosureShape {
                try validateNativeCallable(callable.signature)
            } else {
                try validateDeviceType(item.resultType)
            }
            // NativeImport effects describe the exact imported declaration,
            // not the nominal isolation of its receiver or result. Swift SDKs
            // can explicitly expose `nonisolated` members on MainActor types;
            // the generated probe is the compiler-checked authority for that
            // call. Shell entry functions remain subject to the stronger
            // type-level isolation rule above.
            try validateDeviceEffects(item.effects)
        }
        guard UInt32(exactly: eligible.count) == bridgeRegistrationCount else {
            throw InterfaceArchive.Error.invalidArchive("bridge registration count does not equal eligible entries")
        }
    }

    private func deviceProjection() -> InterfaceArchive.DeviceProjection {
        InterfaceArchive.DeviceProjection(
            compatibility: compatibility,
            capabilities: capabilities.sorted(),
            entries: functions.compactMap { function in
                guard function.patchability.isEligible, let index = function.entryIndex else { return nil }
                return .init(
                    index: index,
                    key: function.key,
                    parameterTypes: function.parameterTypes,
                    resultType: function.resultType,
                    effects: function.effects,
                    fallbackAllowed: function.fallbackAllowed
                )
            }.sorted { $0.index < $1.index },
            imports: nativeImports.compactMap { item in
                guard item.isEmittedToDevice, let id = item.id else { return nil }
                return .init(
                    id: id,
                    key: item.key,
                    descriptor: item.descriptor,
                    parameterTypes: item.parameterTypes,
                    resultType: item.resultType,
                    contract: item.contract,
                    capability: item.capability
                )
            }.sorted { $0.id < $1.id },
            types: nativeTypes.filter(\.isEmittedToDevice).map { type in
                InterfaceArchive.DeviceType(
                    id: type.id,
                    canonicalName: type.canonicalName,
                    kind: type.kind,
                    layoutFingerprint: type.layoutFingerprint,
                    objectiveCRuntimeName: type.objectiveCRuntimeName,
                    isCopyable: type.isCopyable,
                    requiresMainActor: type.requiresMainActor,
                    estimatedSize: type.estimatedSize
                )
            }.sorted { $0.id.rawValue < $1.id.rawValue },
            frozenValueTypes: frozenValueTypes.map {
                InterfaceArchive.DeviceFrozenValueType(
                    definition: $0.definition,
                    layoutFingerprint: $0.layoutFingerprint,
                    isCopyable: $0.isCopyable
                )
            }.sorted { $0.definition.key < $1.definition.key }
        )
    }

    private static func isSafeLogicalPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..") && !components.contains("")
    }

    private static func isValidSILSymbol(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                byte > 0x20 && byte != 0x3a && byte != 0x40
            }
    }

    private static func isValidNativeTypeAlias(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 1_024
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.allSatisfy { $0 > 0x20 && $0 != 0x7f }
    }
}

private struct DeviceProjection: Codable {
    var compatibility: Core.Compatibility
    var capabilities: [Core.Capability]
    var entries: [InterfaceArchive.DeviceEntry]
    var imports: [InterfaceArchive.DeviceImport]
    var types: [InterfaceArchive.DeviceType]
    var frozenValueTypes: [InterfaceArchive.DeviceFrozenValueType]
}

private struct DeviceEntry: Codable {
    var index: Core.EntryIndex
    var key: Core.FunctionKey
    var parameterTypes: [Bytecode.ValueType]
    var resultType: Bytecode.ValueType
    var effects: Core.Effects
    var fallbackAllowed: Bool
}

private struct DeviceImport: Codable {
    var id: Core.NativeImportID
    var key: Core.NativeCall.Key
    var descriptor: Core.NativeCall.Descriptor
    var parameterTypes: [Bytecode.ValueType]
    var resultType: Bytecode.ValueType
    var contract: Core.NativeImportContract
    var capability: Core.Capability
}

private struct DeviceType: Codable {
    var id: Core.TypeID
    var canonicalName: String
    var kind: InterfaceArchive.TypeKind
    var layoutFingerprint: Core.Digest
    var objectiveCRuntimeName: String?
    var isCopyable: Bool
    var requiresMainActor: Bool
    var estimatedSize: UInt64
}

private struct DeviceFrozenValueType: Codable {
    var definition: Bytecode.LocalTypeDefinition
    var layoutFingerprint: Core.Digest
    var isCopyable: Bool
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidMagic
    case unsupportedSchema(UInt16)
    case unsupportedFlags(UInt16)
    case fileTooLarge(actual: Int, maximum: Int)
    case truncated
    case trailingBytes
    case payloadHashMismatch
    case archiveHashMismatch
    case interfaceHashMismatch
    case nonCanonicalPayload
    case invalidArchive(String)
    case malformedPayload(String)

    public var description: String {
        switch self {
        case .invalidMagic: "invalid HLXI magic"
        case let .unsupportedSchema(value): "unsupported HLXI schema \(value)"
        case let .unsupportedFlags(value): "unsupported HLXI flags 0x\(String(value, radix: 16))"
        case let .fileTooLarge(actual, maximum): "HLXI is \(actual) bytes; maximum is \(maximum)"
        case .truncated: "HLXI container is truncated"
        case .trailingBytes: "HLXI container has trailing bytes"
        case .payloadHashMismatch: "HLXI payload hash mismatch"
        case .archiveHashMismatch: "HLXI archive hash mismatch"
        case .interfaceHashMismatch: "HLXI device interface hash mismatch"
        case .nonCanonicalPayload: "HLXI payload is not canonical JSON"
        case let .invalidArchive(reason): "invalid HLXI archive: \(reason)"
        case let .malformedPayload(reason): "malformed HLXI payload: \(reason)"
        }
    }
}
}
