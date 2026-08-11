import Foundation
import HelixBytecode
import HelixCore

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
    /// `nil` decodes historical archives whose parameters were all owned.
    public var parameterConventions: [Bytecode.ParameterConvention]?
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
        self.resultType = resultType
        self.effects = effects
        self.interfaceFingerprint = interfaceFingerprint
        self.bodyFingerprint = bodyFingerprint
        self.patchability = patchability
        self.fallbackAllowed = fallbackAllowed
        self.bridgeSymbol = bridgeSymbol
    }
}

public struct NativeImportRecord: Codable, Hashable, Sendable {
    public var id: Core.NativeImportID?
    public var key: Core.NativeImportKey
    public var canonicalCallee: String
    /// Exact canonical-SIL symbols accepted for this typed native import.
    /// These stay server-side and never become runtime symbol lookup authority.
    public var silMangledNames: [String]
    public var parameterTypes: [Bytecode.ValueType]
    public var resultType: Bytecode.ValueType
    public var signature: Core.LoweredSignature
    public var effects: Core.Effects
    public var contract: Core.NativeImportContract
    public var capability: Core.Capability
    public var isEmittedToDevice: Bool

    public init(
        id: Core.NativeImportID?,
        key: Core.NativeImportKey,
        canonicalCallee: String,
        silMangledNames: [String],
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        signature: Core.LoweredSignature,
        effects: Core.Effects,
        contract: Core.NativeImportContract,
        capability: Core.Capability = .nativeImportsV2,
        isEmittedToDevice: Bool
    ) {
        self.id = id
        self.key = key
        self.canonicalCallee = canonicalCallee
        self.silMangledNames = silMangledNames.sorted()
        self.parameterTypes = parameterTypes
        self.resultType = resultType
        self.signature = signature
        self.effects = effects
        self.contract = contract
        self.capability = capability
        self.isEmittedToDevice = isEmittedToDevice
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
    public var kind: InterfaceArchive.TypeKind
    public var layoutFingerprint: Core.Digest
    public var isCopyable: Bool
    public var requiresMainActor: Bool
    public var isEmittedToDevice: Bool
    public var estimatedSize: UInt64

    public init(
        id: Core.TypeID,
        canonicalName: String,
        kind: InterfaceArchive.TypeKind,
        layoutFingerprint: Core.Digest,
        isCopyable: Bool,
        requiresMainActor: Bool = false,
        isEmittedToDevice: Bool,
        estimatedSize: UInt64
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.kind = kind
        self.layoutFingerprint = layoutFingerprint
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
    public static let currentSchemaVersion: UInt16 = 3

    public var schemaVersion: UInt16
    public var metadata: InterfaceArchive.ReleaseMetadata
    public var compatibility: Core.Compatibility
    public var shellInterfaceHash: Core.Digest
    public var capabilities: [Core.Capability]
    public var sources: [InterfaceArchive.SourceRecord]
    public var functions: [InterfaceArchive.FunctionRecord]
    public var nativeImports: [InterfaceArchive.NativeImportRecord]
    public var nativeTypes: [InterfaceArchive.TypeRecord]
    public var bridgeRegistrationCount: UInt32

    public static func make(
        metadata: InterfaceArchive.ReleaseMetadata,
        compatibility: Core.Compatibility,
        capabilities: Set<Core.Capability>,
        sources: [InterfaceArchive.SourceRecord],
        functions: [InterfaceArchive.FunctionRecord],
        nativeImports: [InterfaceArchive.NativeImportRecord] = [],
        nativeTypes: [InterfaceArchive.TypeRecord] = [],
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
        return value
    }

    public func computeShellInterfaceHash() throws -> Core.Digest {
        // HLXI 2.4 adds async ABI/effect authority to the device projection.
        // Preserve the v2 domain for older archives so their recorded Shell
        // identity remains verifiable after a Runtime upgrade.
        let domain = compatibility.interfaceArchive >= .init(2, 4, 0)
            ? "HLXI.DeviceProjection.v3"
            : "HLXI.DeviceProjection.v2"
        var hasher = Core.StableHasher(domain: domain)
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
                ?? Array(repeating: .owned, count: function.parameterTypes.count)
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
        guard eligible.allSatisfy({
            !($0.parameterConventions ?? []).contains(.inout)
        }) else {
            throw InterfaceArchive.Error.invalidArchive(
                "Shell entry signatures cannot contain inout parameters"
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
              }),
              Set(nativeImports.flatMap(\.silMangledNames)).count
                  == nativeImports.reduce(0, { $0 + $1.silMangledNames.count })
        else {
            throw InterfaceArchive.Error.invalidArchive("native import allocation is inconsistent")
        }
        for item in nativeImports {
            guard item.signature.isThrowing == item.effects.mayThrow,
                  item.signature.isAsync == item.effects.isAsync
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import lowered signature and effects disagree"
                )
            }
            let expected = try Core.NativeImportKey.derive(
                namespace: metadata.shellNamespaceID,
                canonicalCallee: item.canonicalCallee,
                signature: item.signature,
                effects: item.effects,
                contract: item.contract
            )
            guard expected == item.key else {
                throw InterfaceArchive.Error.invalidArchive("native import key derivation mismatch")
            }
            if item.isEmittedToDevice, !capabilities.contains(item.capability) {
                throw InterfaceArchive.Error.invalidArchive("emitted native import capability is absent")
            }
            do {
                try item.contract.validate(effects: item.effects)
            } catch {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import contract is invalid: \(error)"
                )
            }
            guard item.capability == .nativeImportsV2 else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import does not use the v2 contract capability"
                )
            }
        }
        if !emittedImports.isEmpty, !capabilities.contains(.nativeImportsV2) {
            throw InterfaceArchive.Error.invalidArchive("native import capability is absent")
        }
        guard Set(nativeTypes.map(\.id)).count == nativeTypes.count else {
            throw InterfaceArchive.Error.invalidArchive("native type identities are not unique")
        }
        for type in nativeTypes {
            guard !type.canonicalName.isEmpty,
                  Core.TypeID.derive(
                namespace: metadata.shellNamespaceID,
                canonicalType: type.canonicalName
            ) == type.id else {
                throw InterfaceArchive.Error.invalidArchive("native type key derivation mismatch")
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
        var usesHLBC11DeviceType = false
        var usesThrowingDeviceEffect = false
        var usesDictionaryDeviceType = false
        func validateDeviceType(_ type: Bytecode.ValueType) throws {
            switch type {
            case .string:
                usesHLBC11DeviceType = true
                guard capabilities.contains(.stringsV1) else {
                    throw InterfaceArchive.Error.invalidArchive("String capability is absent")
                }
            case let .native(id):
                guard capabilities.contains(.nativeTypesV1), emittedTypeIDs.contains(id) else {
                    throw InterfaceArchive.Error.invalidArchive("device signature references an un-emitted native type")
                }
            case let .array(element):
                usesHLBC11DeviceType = true
                guard capabilities.contains(.collectionsV1) else {
                    throw InterfaceArchive.Error.invalidArchive("Array capability is absent")
                }
                try validateDeviceType(element)
            case let .dictionary(key, value):
                usesDictionaryDeviceType = true
                guard capabilities.contains(.collectionsV1) else {
                    throw InterfaceArchive.Error.invalidArchive("Dictionary capability is absent")
                }
                switch key {
                case .bool, .integer, .string:
                    break
                default:
                    throw InterfaceArchive.Error.invalidArchive(
                        "Dictionary key must be Bool, integer, or String"
                    )
                }
                try validateDeviceType(key)
                try validateDeviceType(value)
            case let .tuple(elements):
                for element in elements { try validateDeviceType(element) }
            case let .optional(wrapped):
                try validateDeviceType(wrapped)
            case .float:
                usesHLBC11DeviceType = true
            case .local, .error, .address, .closure:
                throw InterfaceArchive.Error.invalidArchive(
                    "patch-local nominal, Error, address, and closure values cannot appear in a Shell signature"
                )
            case .void, .never, .bool, .integer:
                break
            }
        }
        func validateDeviceEffects(_ effects: Core.Effects) throws {
            if effects.mayThrow {
                usesThrowingDeviceEffect = true
                guard capabilities.contains(.untypedThrowsV1) else {
                    throw InterfaceArchive.Error.invalidArchive("untyped throws capability is absent")
                }
            }
            if effects.requiresMainActor, !capabilities.contains(.mainActorSyncV1) {
                throw InterfaceArchive.Error.invalidArchive("MainActor capability is absent")
            }
            if effects.isAsync, !capabilities.contains(.asyncLeafEntriesV1) {
                throw InterfaceArchive.Error.invalidArchive("async leaf-entry capability is absent")
            }
        }
        func usesMainActorType(_ type: Bytecode.ValueType) -> Bool {
            switch type {
            case let .native(id): mainActorTypeIDs.contains(id)
            case let .array(element), let .optional(element):
                usesMainActorType(element)
            case let .dictionary(key, value):
                usesMainActorType(key) || usesMainActorType(value)
            case let .tuple(elements):
                elements.contains(where: usesMainActorType)
            case let .closure(signature):
                (signature.parameters + [signature.result]).contains(where: usesMainActorType)
            case .void, .never, .bool, .integer, .float, .string, .local, .error,
                 .address:
                false
            }
        }
        for function in eligible {
            for type in function.parameterTypes + [function.resultType] {
                try validateDeviceType(type)
            }
            guard function.effects.requiresMainActor
                    || !(function.parameterTypes + [function.resultType]).contains(
                        where: usesMainActorType
                    )
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "a function moves a MainActor native type off actor"
                )
            }
            try validateDeviceEffects(function.effects)
        }
        for item in emittedImports {
            for type in item.parameterTypes + [item.resultType] {
                try validateDeviceType(type)
            }
            guard item.effects.requiresMainActor
                    || !(item.parameterTypes + [item.resultType]).contains(
                        where: usesMainActorType
                    )
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "a native import moves a MainActor native type off actor"
                )
            }
            try validateDeviceEffects(item.effects)
        }
        if !emittedImports.isEmpty {
            let requiredBytecode = Core.SemanticVersion(1, 4, 0)
            let requiredArchive = Core.SemanticVersion(2, 2, 0)
            guard compatibility.bytecode.major == requiredBytecode.major,
                  compatibility.bytecode >= requiredBytecode,
                  compatibility.interfaceArchive.major == requiredArchive.major,
                  compatibility.interfaceArchive >= requiredArchive
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "native import v2 contracts require HLBC 1.4 and HLXI 2.2 compatibility"
                )
            }
        }
        if usesHLBC11DeviceType {
            let requiredBytecode = Core.SemanticVersion(1, 1, 0)
            guard compatibility.bytecode.major == requiredBytecode.major,
                  compatibility.bytecode >= requiredBytecode
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "Float, String, and Array device types require HLBC 1.1 compatibility"
                )
            }
        }
        if usesThrowingDeviceEffect {
            let requiredBytecode = Core.SemanticVersion(1, 2, 0)
            guard compatibility.bytecode.major == requiredBytecode.major,
                  compatibility.bytecode >= requiredBytecode
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "throwing device effects require HLBC 1.2 compatibility"
                )
            }
        }
        if usesDictionaryDeviceType {
            let requiredBytecode = Core.SemanticVersion(1, 3, 0)
            guard compatibility.bytecode.major == requiredBytecode.major,
                  compatibility.bytecode >= requiredBytecode
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "Dictionary device types require HLBC 1.3 compatibility"
                )
            }
            let requiredArchive = Core.SemanticVersion(2, 1, 0)
            guard compatibility.interfaceArchive.major == requiredArchive.major,
                  compatibility.interfaceArchive >= requiredArchive
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "Dictionary device types require HLXI 2.1 compatibility"
                )
            }
        }
        if capabilities.contains(.localNominalsV1)
            || capabilities.contains(.structuredErrorsV1) {
            let requiredBytecode = Core.SemanticVersion(1, 6, 0)
            guard compatibility.bytecode.major == requiredBytecode.major,
                  compatibility.bytecode >= requiredBytecode
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "local nominal and structured Error capabilities require HLBC 1.6 compatibility"
                )
            }
        }
        if capabilities.contains(.addressValuesV1)
            || capabilities.contains(.borrowCallsV1) {
            let requiredBytecode = Core.SemanticVersion(1, 7, 0)
            guard compatibility.bytecode.major == requiredBytecode.major,
                  compatibility.bytecode >= requiredBytecode
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "address and borrowed-call capabilities require HLBC 1.7 compatibility"
                )
            }
        }
        if capabilities.contains(.closureValuesV1)
            || capabilities.contains(.escapingClosureValuesV1)
            || capabilities.contains(.compilerSpecializationsV1) {
            let requiredBytecode = Core.SemanticVersion(1, 8, 0)
            let requiredArchive = Core.SemanticVersion(2, 3, 0)
            guard compatibility.bytecode.major == requiredBytecode.major,
                  compatibility.bytecode >= requiredBytecode,
                  compatibility.interfaceArchive.major == requiredArchive.major,
                  compatibility.interfaceArchive >= requiredArchive
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "closure and compiler-specialization capabilities require HLBC 1.8 and HLXI 2.3 compatibility"
                )
            }
        }
        if capabilities.contains(.asyncLeafEntriesV1) {
            let requiredBytecode = Core.SemanticVersion(1, 9, 0)
            let requiredArchive = Core.SemanticVersion(2, 4, 0)
            guard compatibility.bytecode.major == requiredBytecode.major,
                  compatibility.bytecode >= requiredBytecode,
                  compatibility.interfaceArchive.major == requiredArchive.major,
                  compatibility.interfaceArchive >= requiredArchive
            else {
                throw InterfaceArchive.Error.invalidArchive(
                    "async leaf entries require HLBC 1.9 and HLXI 2.4 compatibility"
                )
            }
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
                    parameterTypes: item.parameterTypes,
                    resultType: item.resultType,
                    signature: item.signature,
                    effects: item.effects,
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
                    isCopyable: type.isCopyable,
                    requiresMainActor: type.requiresMainActor,
                    estimatedSize: type.estimatedSize
                )
            }.sorted { $0.id.rawValue < $1.id.rawValue }
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
}

private struct DeviceProjection: Codable {
    var compatibility: Core.Compatibility
    var capabilities: [Core.Capability]
    var entries: [InterfaceArchive.DeviceEntry]
    var imports: [InterfaceArchive.DeviceImport]
    var types: [InterfaceArchive.DeviceType]
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
    var key: Core.NativeImportKey
    var parameterTypes: [Bytecode.ValueType]
    var resultType: Bytecode.ValueType
    var signature: Core.LoweredSignature
    var effects: Core.Effects
    var contract: Core.NativeImportContract
    var capability: Core.Capability
}

private struct DeviceType: Codable {
    var id: Core.TypeID
    var canonicalName: String
    var kind: InterfaceArchive.TypeKind
    var layoutFingerprint: Core.Digest
    var isCopyable: Bool
    var requiresMainActor: Bool
    var estimatedSize: UInt64
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
