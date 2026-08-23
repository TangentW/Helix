import Foundation
import HelixBytecode
import HelixCore
import HelixInterface

public enum ReleaseCompiler {}

extension ReleaseCompiler {
    public struct ToolchainIdentity: Codable, Hashable, Sendable {
        public var fingerprint: String
        public var versionOutput: String
        public var targetInfo: String
        public var compilerBinaryHash: Core.Digest

        public init(
            fingerprint: String,
            versionOutput: String,
            targetInfo: String,
            compilerBinaryHash: Core.Digest
        ) {
            self.fingerprint = fingerprint
            self.versionOutput = versionOutput
            self.targetInfo = targetInfo
            self.compilerBinaryHash = compilerBinaryHash
        }
    }

    public struct BuildRequest: Sendable {
        public var archive: InterfaceArchive.Archive
        public var sourceFiles: [URL]
        public var selectedFunctionKeys: Set<Core.FunctionKey>?
        public var compilerURL: URL
        public var enforceToolchainFingerprint: Bool
        public var requestedResources: Core.ResourceLimits

        public init(
            archive: InterfaceArchive.Archive,
            sourceFiles: [URL],
            selectedFunctionKeys: Set<Core.FunctionKey>? = nil,
            compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
            enforceToolchainFingerprint: Bool = true,
            requestedResources: Core.ResourceLimits = .init()
        ) {
            self.archive = archive
            self.sourceFiles = sourceFiles
            self.selectedFunctionKeys = selectedFunctionKeys
            self.compilerURL = compilerURL
            self.enforceToolchainFingerprint = enforceToolchainFingerprint
            self.requestedResources = requestedResources
        }
    }

    public struct BuildResult: Sendable {
        public var module: Bytecode.Module
        public var bytecode: Data
        public var disassembly: String
        public var changedFunctions: [InterfaceArchive.FunctionRecord]
        public var bodyFingerprints: [Core.FunctionKey: Core.Digest]
        public var toolchain: ToolchainIdentity
    }

    public enum DriverError: Error, Equatable, Sendable, CustomStringConvertible {
        case emptySourceSet
        case sourceDoesNotExist(String)
        case sourceSetMismatch(String)
        case mixedModules
        case unknownFunction(Core.FunctionKey)
        case functionMissingFromSIL(Core.FunctionKey)
        case changedIneligibleFunction(Core.FunctionKey, reason: String)
        case loweredSignatureChanged(Core.FunctionKey, reason: String)
        case noSemanticChanges
        case generatedFunctionUnsupported(String, reason: String)
        case toolchainMismatch(expected: String, actual: String)
        case compilerIdentityFailed(String)

        public var description: String {
            switch self {
            case .emptySourceSet: "Patch Driver requires the complete Swift source set for one module"
            case let .sourceDoesNotExist(path): "Patch Driver source does not exist: \(path)"
            case let .sourceSetMismatch(reason): "Patch Driver source set mismatch: \(reason)"
            case .mixedModules: "selected HLXI functions belong to more than one Swift module"
            case let .unknownFunction(key): "selected function \(key) is absent from HLXI"
            case let .functionMissingFromSIL(key): "frozen function \(key) is missing from current canonical SIL"
            case let .changedIneligibleFunction(key, reason):
                "changed function \(key) requires a full build: \(reason)"
            case let .loweredSignatureChanged(key, reason):
                "function \(key) changed its lowered Swift/SIL signature: \(reason)"
            case .noSemanticChanges: "no selected function body differs from the HLXI baseline"
            case let .generatedFunctionUnsupported(symbol, reason):
                "image-local function \(symbol) is outside the current HLBC profile: \(reason)"
            case let .toolchainMismatch(expected, actual):
                "exact Swift toolchain mismatch; HLXI requires \(expected), current compiler is \(actual)"
            case let .compilerIdentityFailed(reason): "cannot fingerprint Swift compiler: \(reason)"
            }
        }
    }
}

extension ReleaseCompiler {
    public struct Driver: Sendable {
        private struct TargetInfoDocument: Decodable {
            struct Target: Decodable {
                var swiftRuntimeCompatibilityVersion: String?
            }

            struct Paths: Decodable {
                var runtimeResourcePath: String
            }

            var compilerVersion: String?
            var swiftCompilerTag: String?
            var target: Target?
            var paths: Paths
        }

        public init() {}

        public func toolchainIdentity(
            compilerURL: URL = URL(fileURLWithPath: "/usr/bin/swiftc"),
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) throws -> ToolchainIdentity {
            let requestedURL = compilerURL.resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: requestedURL.path) else {
                throw DriverError.compilerIdentityFailed(
                    "compiler is not executable at \(requestedURL.path)"
                )
            }
            let identityEnvironment = toolchainIdentityEnvironment(environment)
            let requested = SwiftFrontend.Driver(
                compilerURL: requestedURL,
                environment: identityEnvironment
            )
            let requestedTarget = try requested.run(arguments: ["-print-target-info"])
            guard requestedTarget.terminationStatus == 0 else {
                throw DriverError.compilerIdentityFailed(requestedTarget.standardError)
            }
            let canonicalURL = canonicalFrontendURL(
                targetInfo: requestedTarget.standardOutput,
                fallback: requestedURL
            )
            let frontend = SwiftFrontend.Driver(
                compilerURL: canonicalURL,
                environment: identityEnvironment
            )
            let version = try frontend.run(arguments: ["-version"])
            guard version.terminationStatus == 0 else {
                throw DriverError.compilerIdentityFailed(version.standardError)
            }
            let target = try frontend.run(arguments: ["-print-target-info"])
            guard target.terminationStatus == 0 else {
                throw DriverError.compilerIdentityFailed(target.standardError)
            }
            guard let targetData = target.standardOutput.data(using: .utf8),
                  let targetDocument = try? JSONDecoder().decode(
                      TargetInfoDocument.self,
                      from: targetData
                  ),
                  let compilerVersion = targetDocument.compilerVersion,
                  !compilerVersion.isEmpty
            else {
                throw DriverError.compilerIdentityFailed(
                    "Swift frontend returned malformed target information"
                )
            }
            let binary: Data
            do {
                binary = try Data(contentsOf: canonicalURL, options: .mappedIfSafe)
            } catch {
                throw DriverError.compilerIdentityFailed(String(describing: error))
            }
            let binaryHash = Core.Digest.sha256(binary)
            var hasher = Core.StableHasher(domain: "HLX.SwiftToolchain.v1")
            hasher.append(compilerVersion)
            hasher.append(targetDocument.swiftCompilerTag ?? "")
            hasher.append(
                targetDocument.target?.swiftRuntimeCompatibilityVersion ?? ""
            )
            hasher.append(binaryHash)
            return .init(
                fingerprint: "sha256:\(hasher.finalize().hex)",
                versionOutput: (version.standardOutput + version.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                targetInfo: target.standardOutput,
                compilerBinaryHash: binaryHash
            )
        }

        /// Toolchain identity must not depend on the target currently selected
        /// by an Xcode Scheme action. The SDK and deployment target are frozen
        /// separately in HLXI; leaking them into `swiftc -version` can add
        /// context-only warnings and split one compiler into two fingerprints.
        private func toolchainIdentityEnvironment(
            _ environment: [String: String]
        ) -> [String: String] {
            var result = environment
            for name in [
                "SDKROOT",
                "MACOSX_DEPLOYMENT_TARGET",
                "IPHONEOS_DEPLOYMENT_TARGET",
                "TVOS_DEPLOYMENT_TARGET",
                "WATCHOS_DEPLOYMENT_TARGET",
                "XROS_DEPLOYMENT_TARGET",
                "DRIVERKIT_DEPLOYMENT_TARGET",
            ] {
                result.removeValue(forKey: name)
            }
            return result
        }

        /// `/usr/bin/swiftc` is an Apple tool-selection proxy whose own bytes
        /// describe macOS, not the selected Swift toolchain. Target info exposes
        /// the runtime resource root, which lets both the proxy and Xcode's
        /// direct `swiftc` converge on the same `swift-frontend` identity.
        private func canonicalFrontendURL(targetInfo: String, fallback: URL) -> URL {
            guard let data = targetInfo.data(using: .utf8),
                  let document = try? JSONDecoder().decode(
                      TargetInfoDocument.self,
                      from: data
                  )
            else { return fallback }
            let runtime = URL(fileURLWithPath: document.paths.runtimeResourcePath)
            let candidate = runtime
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("bin/swift-frontend")
                .resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
                return fallback
            }
            return candidate
        }

        public func build(_ request: BuildRequest) throws -> BuildResult {
            try request.archive.validate()
            guard !request.sourceFiles.isEmpty else { throw DriverError.emptySourceSet }
            for source in request.sourceFiles {
                guard source.pathExtension == "swift",
                      FileManager.default.fileExists(atPath: source.path)
                else {
                    throw DriverError.sourceDoesNotExist(source.path)
                }
            }
            let orderedSourceFiles = try orderedCompleteSourceSet(
                request.sourceFiles,
                archive: request.archive
            )
            let toolchain = try toolchainIdentity(compilerURL: request.compilerURL)
            if request.enforceToolchainFingerprint,
               request.archive.compatibility.compilerFingerprint != toolchain.fingerprint {
                throw DriverError.toolchainMismatch(
                    expected: request.archive.compatibility.compilerFingerprint,
                    actual: toolchain.fingerprint
                )
            }

            let allByKey = Dictionary(
                uniqueKeysWithValues: request.archive.functions.map { ($0.key, $0) }
            )
            let selected: [InterfaceArchive.FunctionRecord]
            if let keys = request.selectedFunctionKeys {
                selected = try keys.map { key in
                    guard let record = allByKey[key] else { throw DriverError.unknownFunction(key) }
                    return record
                }
            } else {
                selected = request.archive.functions
            }
            let modules = Set(selected.map(\.moduleName))
            guard modules.count == 1, let moduleName = modules.first else {
                throw DriverError.mixedModules
            }
            let canonicalSIL = try SwiftFrontend.Driver(compilerURL: request.compilerURL)
                .emitCanonicalSIL(
                    sourceFiles: orderedSourceFiles,
                    invocation: request.archive.metadata.frontendInvocation
                )
            let silFile = try CanonicalSIL.File(text: canonicalSIL)
            let frozenNativeTypeRecords = request.archive.nativeTypes
                .filter(\.isEmittedToDevice)
            let frozenNativeTypes = Dictionary(
                uniqueKeysWithValues: frozenNativeTypeRecords.map {
                    ($0.canonicalName, $0.id)
                }
            )
            let frozenNativeTypeKinds = Dictionary(
                uniqueKeysWithValues: frozenNativeTypeRecords.map { ($0.id, $0.kind) }
            )
            let mainActorNativeTypes = Set(
                frozenNativeTypeRecords.filter(\.requiresMainActor).map(\.id)
            )
            let silTypeEnvironment = try silFile.typeEnvironment.includingNativeTypes(
                frozenNativeTypes,
                kinds: frozenNativeTypeKinds,
                requiresMainActor: mainActorNativeTypes
            )
            let archivedSymbols = Set(request.archive.functions.map(\.mangledName))

            var directlyChanged: [(
                record: InterfaceArchive.FunctionRecord,
                function: CanonicalSIL.Function,
                fingerprint: Core.Digest
            )] = []
            for record in selected.sorted(by: recordOrder) {
                guard let silFunction = silFile.function(mangledName: record.mangledName) else {
                    throw DriverError.functionMissingFromSIL(record.key)
                }
                let fingerprint = ReleaseCompiler.ImplementationFingerprint.compute(
                    root: silFunction,
                    in: silFile,
                    archivedSymbols: archivedSymbols
                )
                guard fingerprint != record.bodyFingerprint else { continue }
                guard record.patchability.isEligible
                        || isLocalArchivedHelper(record)
                        || isGenericSpecializationSource(record)
                else {
                    throw DriverError.changedIneligibleFunction(
                        record.key,
                        reason: record.patchability.explanation ?? "HLXI marks this declaration ineligible"
                    )
                }
                directlyChanged.append((record, silFunction, fingerprint))
            }
            guard !directlyChanged.isEmpty else { throw DriverError.noSemanticChanges }

            let recordsBySymbol = Dictionary(
                uniqueKeysWithValues: request.archive.functions.map { ($0.mangledName, $0) }
            )
            let specializationSources = request.archive.functions.filter {
                isLocalArchivedHelper($0) || isGenericSpecializationSource($0)
            }.sorted { left, right in
                left.mangledName.count > right.mangledName.count
            }
            let callGraph = Dictionary(uniqueKeysWithValues: request.archive.functions.map {
                record -> (Core.FunctionKey, Set<Core.FunctionKey>) in
                let references = silFile.function(mangledName: record.mangledName)
                    .map {
                        ReleaseCompiler.ImplementationFingerprint
                            .referencedSymbols(in: $0.body)
                    } ?? []
                return (
                    record.key,
                    Set(references.compactMap { symbol in
                        if let exact = recordsBySymbol[symbol] { return exact.key }
                        return specializationSources.first {
                            symbol.hasPrefix($0.mangledName)
                                && ReleaseCompiler.ImplementationFingerprint
                                    .isCompilerGeneratedSymbol(symbol)
                        }?.key
                    })
                )
            })
            var reverseGraph: [Core.FunctionKey: Set<Core.FunctionKey>] = [:]
            for (caller, callees) in callGraph {
                for callee in callees { reverseGraph[callee, default: []].insert(caller) }
            }

            var rootKeys = Set(directlyChanged.compactMap {
                $0.record.patchability.isEligible ? $0.record.key : nil
            })
            let changedHelpers = Set(directlyChanged.compactMap {
                $0.record.patchability.isEligible ? nil : $0.record.key
            })
            var reverseWorklist = Array(changedHelpers)
            var reverseVisited = changedHelpers
            while let callee = reverseWorklist.popLast() {
                for caller in reverseGraph[callee, default: []]
                where reverseVisited.insert(caller).inserted {
                    if allByKey[caller]?.patchability.isEligible == true {
                        rootKeys.insert(caller)
                    } else {
                        reverseWorklist.append(caller)
                    }
                }
            }
            guard !rootKeys.isEmpty else {
                guard let helper = directlyChanged.first(where: {
                    !$0.record.patchability.isEligible
                }) else {
                    throw DriverError.sourceSetMismatch(
                        "changed eligible functions produced no patch root"
                    )
                }
                throw DriverError.changedIneligibleFunction(
                    helper.record.key,
                    reason: "changed local helper or generic specialization source has no patchable caller to route into HLBC"
                )
            }

            var compilationKeys = rootKeys
            var forwardWorklist = Array(rootKeys)
            while let caller = forwardWorklist.popLast() {
                for callee in callGraph[caller, default: []] {
                    guard let record = allByKey[callee],
                          isLocalArchivedHelper(record),
                          compilationKeys.insert(callee).inserted
                    else { continue }
                    forwardWorklist.append(callee)
                }
            }
            let unroutedHelper = directlyChanged.first { item in
                guard !item.record.patchability.isEligible else { return false }
                if isLocalArchivedHelper(item.record) {
                    return !compilationKeys.contains(item.record.key)
                }
                return !hasPatchableReversePath(
                    from: item.record.key,
                    reverseGraph: reverseGraph,
                    records: allByKey
                )
            }
            if let helper = unroutedHelper {
                throw DriverError.changedIneligibleFunction(
                    helper.record.key,
                    reason: "changed local helper or generic specialization source is not reachable from a patchable caller"
                )
            }
            let changedFingerprintByKey = Dictionary(uniqueKeysWithValues: directlyChanged.map {
                ($0.record.key, $0.fingerprint)
            })
            let changedSIL = try compilationKeys.compactMap { key -> (
                record: InterfaceArchive.FunctionRecord,
                function: CanonicalSIL.Function,
                fingerprint: Core.Digest
            )? in
                guard let record = allByKey[key] else { return nil }
                guard let function = silFile.function(mangledName: record.mangledName) else {
                    throw DriverError.functionMissingFromSIL(record.key)
                }
                return (
                    record,
                    function,
                    changedFingerprintByKey[key]
                        ?? ReleaseCompiler.ImplementationFingerprint.compute(
                            root: function,
                            in: silFile,
                            archivedSymbols: archivedSymbols
                        )
                )
            }.sorted { recordOrder($0.record, $1.record) }

            // The exact optimized SIL remains the source of change identity
            // and the preferred lowering input. A separate toolchain-pinned
            // semantic pass is always available: mandatory transforms can
            // inline imported default generators even at -Onone, while patch
            // call-variant selection requires their source-level provenance.
            let loweringSIL = try SwiftFrontend.Driver(
                compilerURL: request.compilerURL
            ).emitCanonicalSIL(
                sourceFiles: orderedSourceFiles,
                invocation: request.archive.metadata.frontendInvocation,
                purpose: .semanticLowering
            )
            let loweringSILFile = try CanonicalSIL.File(text: loweringSIL)
            let hasDistinctSemanticFallback = loweringSIL != canonicalSIL
            let loweringTypeEnvironment = try loweringSILFile.typeEnvironment
                .includingNativeTypes(
                    frozenNativeTypes,
                    kinds: frozenNativeTypeKinds,
                    requiresMainActor: mainActorNativeTypes
                )

            var localFunctionIDs: [Core.FunctionKey: Bytecode.FunctionID] = [:]
            for (offset, item) in changedSIL.enumerated() {
                guard let rawValue = UInt32(exactly: offset) else {
                    throw DriverError.sourceSetMismatch("too many changed functions for HLBC")
                }
                localFunctionIDs[item.record.key] = .init(rawValue: rawValue)
            }
            let compilationSymbols = Set(changedSIL.map(\.record.mangledName))
            var fallbackImageExecutionEffectEnvelope = Core.Effects()
            var rootExecutionEffects: [String: Core.Effects] = [:]
            for item in changedSIL {
                rootExecutionEffects[item.record.mangledName] = item.record.effects
                fallbackImageExecutionEffectEnvelope.mayAllocate =
                    fallbackImageExecutionEffectEnvelope.mayAllocate
                        || item.record.effects.mayAllocate
                fallbackImageExecutionEffectEnvelope.hasExternalSideEffects =
                    fallbackImageExecutionEffectEnvelope.hasExternalSideEffects
                        || item.record.effects.hasExternalSideEffects
            }
            let optimizedImageFunctions = try discoverImageFunctions(
                in: silFile,
                startingAt: compilationSymbols,
                archive: request.archive,
                moduleName: moduleName,
                typeEnvironment: silTypeEnvironment,
                rootExecutionEffects: rootExecutionEffects
            )
            let semanticImageFunctions = try discoverImageFunctions(
                in: loweringSILFile,
                startingAt: compilationSymbols,
                archive: request.archive,
                moduleName: moduleName,
                typeEnvironment: loweringTypeEnvironment,
                rootExecutionEffects: rootExecutionEffects
            )
            let imageSymbols = Set(optimizedImageFunctions.keys)
                .union(semanticImageFunctions.keys)
                .sorted()
            let imageLocalSymbols = Set(imageSymbols)
            var imageFunctions: [ImageFunction] = []
            var imageBindings: [CanonicalSIL.DirectCallBinding] = []
            for (offset, symbol) in imageSymbols.enumerated() {
                let rawID = changedSIL.count.addingReportingOverflow(offset)
                guard !rawID.overflow, let id = UInt32(exactly: rawID.partialValue) else {
                    throw DriverError.sourceSetMismatch(
                        "too many archived and image-local functions for HLBC"
                    )
                }
                let optimized = optimizedImageFunctions[symbol]
                let semantic = semanticImageFunctions[symbol]
                let selected = optimized ?? semantic
                guard let selected else {
                    throw DriverError.generatedFunctionUnsupported(
                        symbol,
                        reason: "discovery produced no SIL body"
                    )
                }
                if let optimized, let semantic, optimized.kind != semantic.kind {
                    throw DriverError.generatedFunctionUnsupported(
                        symbol,
                        reason: "optimized and semantic SIL disagree on function role"
                    )
                }
                if let optimized, let semantic,
                   optimized.abiAdapter != semantic.abiAdapter {
                    throw DriverError.generatedFunctionUnsupported(
                        symbol,
                        reason: "optimized and semantic SIL disagree on its physical ABI adapter"
                    )
                }
                if let optimized, let semantic,
                   optimized.bindingSymbol != semantic.bindingSymbol {
                    throw DriverError.generatedFunctionUnsupported(
                        symbol,
                        reason: "optimized and semantic SIL disagree on its bound Swift symbol"
                    )
                }
                if let optimized, let semantic,
                   optimized.genericSpecialization
                    != semantic.genericSpecialization {
                    throw DriverError.generatedFunctionUnsupported(
                        symbol,
                        reason: "optimized and semantic SIL disagree on its generic specialization"
                    )
                }
                let executionEffectEnvelope = mergeExecutionEffectEnvelopes(
                    optimized?.executionEffectEnvelope,
                    semantic?.executionEffectEnvelope
                ) ?? fallbackImageExecutionEffectEnvelope
                let optimizedSignature = try optimized.map {
                    try generatedSignature(
                        of: $0.function,
                        environment: silTypeEnvironment,
                        file: silFile,
                        symbol: symbol,
                        kind: $0.kind,
                        executionEffectEnvelope: executionEffectEnvelope
                    )
                }
                let semanticSignature = try semantic.map {
                    try generatedSignature(
                        of: $0.function,
                        environment: loweringTypeEnvironment,
                        file: loweringSILFile,
                        symbol: symbol,
                        kind: $0.kind,
                        executionEffectEnvelope: executionEffectEnvelope
                    )
                }
                if let optimizedSignature, let semanticSignature,
                   optimizedSignature != semanticSignature {
                    throw DriverError.generatedFunctionUnsupported(
                        symbol,
                        reason: "optimized and semantic SIL disagree on its concrete signature"
                    )
                }
                guard let signature = optimizedSignature ?? semanticSignature else {
                    throw DriverError.generatedFunctionUnsupported(
                        symbol,
                        reason: "no concrete signature is available"
                    )
                }
                let functionID = Bytecode.FunctionID(rawValue: id)
                imageFunctions.append(
                    .init(
                        symbol: symbol,
                        id: functionID,
                        kind: selected.kind,
                        signature: signature,
                        optimized: optimized?.function,
                        semantic: semantic?.function
                    )
                )
                imageBindings.append(
                    .init(
                        mangledName: selected.bindingSymbol ?? symbol,
                        parameterTypes: signature.parameters,
                        parameterConventions: signature.parameterConventions,
                        resultType: signature.result,
                        effects: signature.effects,
                        target: .function(functionID),
                        abiAdapter: selected.abiAdapter,
                        genericSpecialization: selected.genericSpecialization
                    )
                )
            }
            let hostedMethods = try mergeHostedMethods(
                optimized: silTypeEnvironment.hostedMethodCandidates(in: silFile)
                    .filter { !archivedSymbols.contains($0.symbol) },
                semantic: loweringTypeEnvironment.hostedMethodCandidates(
                    in: loweringSILFile
                ).filter { !archivedSymbols.contains($0.symbol) },
                imageFunctions: imageFunctions
            )
            let directCalls = try PatchCompiler.DirectCalls.make(
                archive: request.archive,
                localFunctionIDs: localFunctionIDs,
                additionalBindings: imageBindings
            )
            var changed: [(
                record: InterfaceArchive.FunctionRecord,
                function: IntermediateRepresentation.Function,
                fingerprint: Core.Digest
            )] = []
            for item in changedSIL {
                guard let loweringFunction = loweringSILFile.function(
                    mangledName: item.record.mangledName
                ) else {
                    throw DriverError.functionMissingFromSIL(item.record.key)
                }
                if rootKeys.contains(item.record.key),
                   CanonicalSIL.ProtocolExistential.Identity
                    .containsProtocolExistential(
                       in: loweringFunction.loweredType
                   ) {
                    throw DriverError.loweredSignatureChanged(
                        item.record.key,
                        reason: "protocol existential values are image-local and cannot cross a Shell entry"
                    )
                }
                let lowered = try lowerProductionFunction(
                    optimized: item.function,
                    semantic: loweringFunction,
                    optimizedTypeEnvironment: silTypeEnvironment,
                    semanticTypeEnvironment: loweringTypeEnvironment,
                    optimizedFile: silFile,
                    semanticFile: loweringSILFile,
                    displayName: item.record.canonicalDeclaration,
                    directCalls: directCalls,
                    expectedEffects: item.record.effects,
                    hasDistinctSemanticFallback: hasDistinctSemanticFallback
                )
                let actualParameters = lowered.parameterRegisters.compactMap { register in
                    lowered.registerTypes.indices.contains(Int(register.rawValue))
                        ? lowered.registerTypes[Int(register.rawValue)]
                        : nil
                }
                let conventions = item.record.parameterConventions
                let expectedParameters = zip(item.record.parameterTypes, conventions).map {
                    type, convention in convention == .inout ? .address(type) : type
                }
                guard actualParameters.count == lowered.parameterRegisters.count,
                      actualParameters == expectedParameters,
                      lowered.parameterConventions == conventions,
                      lowered.resultType == item.record.resultType
                else {
                    let details = [
                        "declaration=\(item.record.canonicalDeclaration)",
                        "parameters expected=\(expectedParameters) actual=\(actualParameters)",
                        "conventions expected=\(conventions) actual=\(lowered.parameterConventions)",
                        "result expected=\(item.record.resultType) actual=\(lowered.resultType)",
                    ].joined(separator: "; ")
                    throw DriverError.loweredSignatureChanged(
                        item.record.key,
                        reason: details
                    )
                }
                changed.append(
                    (
                        item.record,
                        lowered,
                        ReleaseCompiler.ImplementationFingerprint.compute(
                            root: item.function,
                            in: silFile,
                            archivedSymbols: archivedSymbols,
                            imageLocalSymbols: imageLocalSymbols
                        )
                    )
                )
            }

            var imageLowered: [(
                id: Bytecode.FunctionID,
                function: IntermediateRepresentation.Function
            )] = []
            for item in imageFunctions {
                let lowered: IntermediateRepresentation.Function
                do {
                    if let optimized = item.optimized {
                        do {
                            lowered = try CanonicalSIL.Lowerer(
                                typeEnvironment: silTypeEnvironment,
                                file: silFile
                            ).lower(
                                optimized,
                                displayName: item.symbol,
                                kind: item.kind,
                                directCalls: directCalls,
                                expectedEffects: item.signature.effects,
                                expectedResultType: item.signature.result
                            )
                        } catch let error as CanonicalSIL.LoweringError {
                            guard let semantic = item.semantic,
                                  permitsSemanticFallback(error)
                            else { throw error }
                            lowered = try CanonicalSIL.Lowerer(
                                typeEnvironment: loweringTypeEnvironment,
                                file: loweringSILFile
                            ).lower(
                                semantic,
                                displayName: item.symbol,
                                kind: item.kind,
                                directCalls: directCalls,
                                expectedEffects: item.signature.effects,
                                expectedResultType: item.signature.result
                            )
                        }
                    } else if let semantic = item.semantic {
                        lowered = try CanonicalSIL.Lowerer(
                            typeEnvironment: loweringTypeEnvironment,
                            file: loweringSILFile
                        ).lower(
                            semantic,
                            displayName: item.symbol,
                            kind: item.kind,
                            directCalls: directCalls,
                            expectedEffects: item.signature.effects,
                            expectedResultType: item.signature.result
                        )
                    } else {
                        throw DriverError.generatedFunctionUnsupported(
                            item.symbol,
                            reason: "no lowering body is available"
                        )
                    }
                } catch let error as DriverError {
                    throw error
                } catch {
                    throw DriverError.generatedFunctionUnsupported(
                        item.symbol,
                        reason: String(describing: error)
                    )
                }
                let parameterTypes = lowered.parameterRegisters.compactMap { register in
                    lowered.registerTypes.indices.contains(Int(register.rawValue))
                        ? lowered.registerTypes[Int(register.rawValue)]
                        : nil
                }
                guard parameterTypes.count == lowered.parameterRegisters.count,
                      parameterTypes == item.signature.parameters,
                      lowered.parameterConventions
                        == item.signature.parameterConventions,
                      lowered.resultType == item.signature.result,
                      lowered.effects == item.signature.effects
                else {
                    throw DriverError.generatedFunctionUnsupported(
                        item.symbol,
                        reason: "lowering changed its discovered concrete signature"
                    )
                }
                imageLowered.append((item.id, lowered))
            }

            var entries: [Bytecode.EntryPoint] = []
            var fingerprints: [Core.FunctionKey: Core.Digest] = [:]
            var loweredByID: [(
                id: Bytecode.FunctionID,
                function: IntermediateRepresentation.Function
            )] = []
            for item in changed {
                guard let functionID = localFunctionIDs[item.record.key] else {
                    throw DriverError.sourceSetMismatch(
                        "local function ID allocation is incomplete"
                    )
                }
                loweredByID.append((functionID, item.function))
                guard rootKeys.contains(item.record.key) else { continue }
                guard let entry = item.record.entryIndex else {
                    throw DriverError.changedIneligibleFunction(
                        item.record.key,
                        reason: "patch root has no allocated entry"
                    )
                }
                entries.append(
                    .init(
                        entryIndex: entry,
                        functionKey: item.record.key,
                        functionID: functionID
                    )
                )
                fingerprints[item.record.key] = item.fingerprint
            }
            loweredByID.append(contentsOf: imageLowered)
            let reachableIDs = reachableFunctions(
                roots: Set(entries.map(\.functionID)).union(
                    hostedMethods.values.flatMap { $0.map(\.functionID) }
                ),
                functions: loweredByID
            )
            let logicalPaths = request.archive.sources.map(\.logicalPath)
            let reachable = loweredByID.filter { reachableIDs.contains($0.id) }
                .map { item in
                    (
                        id: item.id,
                        function: IntermediateRepresentation.SourceMapping
                            .retainingLogicalPaths(
                                item.function,
                                logicalPaths: logicalPaths
                            )
                    )
                }
                .sorted { $0.id < $1.id }
            let reachableIR = reachable.map(\.function)
            let imports = try directCalls.importRequirements(
                referencedBy: reachableIR
            )
            let entryParameterConventions = try directCalls
                .entryParameterConventions(referencedBy: reachableIR)
            let localTypes = try mergedLocalTypeDefinitions(
                optimized: silTypeEnvironment,
                semantic: loweringTypeEnvironment,
                referencedBy: reachableIR,
                hostedMethods: hostedMethods
            )
            let capabilities = CompilerCapabilities.infer(
                for: reachableIR,
                imports: imports,
                entryParameterConventions: entryParameterConventions,
                localTypes: localTypes
            )
            let functions = reachable.map {
                IntermediateRepresentation.ToBytecode.lower($0.function, id: $0.id)
            }
            let sourceMap = reachable.flatMap {
                IntermediateRepresentation.ToBytecode.sourceMap($0.function, id: $0.id)
            }
            let module = Bytecode.Module(
                name: "HelixPatch_\(moduleName)",
                shellInterfaceHash: request.archive.shellInterfaceHash,
                compatibility: request.archive.compatibility,
                capabilities: capabilities,
                requestedResources: request.requestedResources,
                localTypes: localTypes,
                functions: functions,
                entries: entries,
                imports: imports,
                sourceMap: sourceMap
            )
            let bytes = try Bytecode.Encoder.encode(module)
            return .init(
                module: module,
                bytecode: bytes,
                disassembly: Bytecode.Disassembler.disassemble(module),
                changedFunctions: changed.filter { rootKeys.contains($0.record.key) }.map(\.record),
                bodyFingerprints: fingerprints,
                toolchain: toolchain
            )
        }

        private typealias DiscoveredImageFunction =
            CanonicalSIL.ImageFunctions.Discovered

        private struct ImageFunction {
            var symbol: String
            var id: Bytecode.FunctionID
            var kind: Bytecode.FunctionKind
            var signature: ImageSignature
            var optimized: CanonicalSIL.Function?
            var semantic: CanonicalSIL.Function?
        }

        private typealias ImageSignature = CanonicalSIL.ImageFunctions.Signature

        private func isLocalArchivedHelper(
            _ record: InterfaceArchive.FunctionRecord
        ) -> Bool {
            switch record.patchability.reasonCode {
            case "HLXIDX006":
                record.parameterConventions.contains(.inout)
            case "HLXIDX022":
                true
            default:
                false
            }
        }

        private func isGenericSpecializationSource(
            _ record: InterfaceArchive.FunctionRecord
        ) -> Bool {
            record.patchability.reasonCode == "HLXIDX007"
        }

        private func hasPatchableReversePath(
            from helper: Core.FunctionKey,
            reverseGraph: [Core.FunctionKey: Set<Core.FunctionKey>],
            records: [Core.FunctionKey: InterfaceArchive.FunctionRecord]
        ) -> Bool {
            var visited: Set<Core.FunctionKey> = [helper]
            var worklist = [helper]
            while let callee = worklist.popLast() {
                for caller in reverseGraph[callee, default: []]
                where visited.insert(caller).inserted {
                    if records[caller]?.patchability.isEligible == true { return true }
                    worklist.append(caller)
                }
            }
            return false
        }

        private func discoverImageFunctions(
            in file: CanonicalSIL.File,
            startingAt archivedSymbols: Set<String>,
            archive: InterfaceArchive.Archive,
            moduleName: String,
            typeEnvironment: CanonicalSIL.TypeEnvironment,
            rootExecutionEffects: [String: Core.Effects]
        ) throws -> [String: DiscoveredImageFunction] {
            do {
                let existingSymbols = Set(archive.functions.map(\.mangledName))
                let hostedCandidates = try typeEnvironment.hostedMethodCandidates(
                    in: file
                ).filter { !existingSymbols.contains($0.symbol) }
                let hostedSymbols = Set(hostedCandidates.map(\.symbol))
                var discovered = try CanonicalSIL.ImageFunctions.discover(
                    in: file,
                    startingAt: archivedSymbols.union(hostedSymbols),
                    excluding: Set(archive.functions.map(\.mangledName)).union(
                        archive.nativeImports.flatMap { record in
                            record.parameterProjection.defaultArguments.compactMap {
                                argument in
                                argument.origin == .externalGenerator
                                    ? argument.generatorSymbol : nil
                            }
                        }
                    ),
                    environment: typeEnvironment,
                    executionEffectsByRoot: rootExecutionEffects,
                    kindForSymbol: { symbol in
                        generatedFunctionKind(
                            symbol,
                            archive: archive,
                            moduleName: moduleName,
                            typeEnvironment: typeEnvironment,
                            file: file
                        )
                    }
                )
                for candidate in hostedCandidates {
                    let executionEffectEnvelope = discovered[candidate.symbol]?
                        .executionEffectEnvelope
                    discovered[candidate.symbol] = .init(
                        function: candidate.function,
                        kind: .ordinary,
                        abiAdapter: .direct,
                        executionEffectEnvelope: executionEffectEnvelope
                    )
                }
                return discovered
            } catch let error as CanonicalSIL.ImageFunctions.DiscoveryError {
                switch error {
                case let .unsupported(symbol, reason):
                    throw DriverError.generatedFunctionUnsupported(symbol, reason: reason)
                }
            }
        }

        private func mergeExecutionEffectEnvelopes(
            _ left: Core.Effects?,
            _ right: Core.Effects?
        ) -> Core.Effects? {
            guard left != nil || right != nil else { return nil }
            return .init(
                mayAllocate: left?.mayAllocate == true || right?.mayAllocate == true,
                hasExternalSideEffects: left?.hasExternalSideEffects == true
                    || right?.hasExternalSideEffects == true
            )
        }

        private func generatedSignature(
            of function: CanonicalSIL.Function,
            environment: CanonicalSIL.TypeEnvironment,
            file: CanonicalSIL.File,
            symbol: String,
            kind: Bytecode.FunctionKind,
            executionEffectEnvelope: Core.Effects
        ) throws -> ImageSignature {
            do {
                return try CanonicalSIL.ImageFunctions.signature(
                    of: function,
                    environment: environment,
                    symbol: symbol,
                    kind: kind,
                    executionEffectEnvelope: executionEffectEnvelope,
                    file: file
                )
            } catch let error as CanonicalSIL.ImageFunctions.DiscoveryError {
                switch error {
                case let .unsupported(symbol, reason):
                    throw DriverError.generatedFunctionUnsupported(symbol, reason: reason)
                }
            }
        }

        private func generatedFunctionKind(
            _ symbol: String,
            archive: InterfaceArchive.Archive,
            moduleName: String,
            typeEnvironment: CanonicalSIL.TypeEnvironment,
            file: CanonicalSIL.File
        ) -> Bytecode.FunctionKind? {
            guard !typeEnvironment.isStructFactory(symbol),
                  !typeEnvironment.isHostedClassAllocator(symbol),
                  file.function(mangledName: symbol).map(
                    typeEnvironment.isOpaqueStructFactory
                  ) != true
            else { return nil }
            let isRooted = archive.functions.contains {
                symbol != $0.mangledName && symbol.hasPrefix($0.mangledName)
            }
            let isModuleLocal = file.isCurrentModuleDefinition(
                mangledName: symbol,
                moduleName: moduleName
            )
            if isModuleLocal, file.function(mangledName: symbol).map(
                CanonicalSIL.ProtocolConformance.StaticDispatch.isWitnessThunk
            ) == true {
                return .concreteSpecialization
            }
            if ReleaseCompiler.ImplementationFingerprint
                .isDefaultArgumentGenerator(symbol) {
                return .concreteSpecialization
            }
            if ReleaseCompiler.ImplementationFingerprint
                .isReabstractionThunk(symbol) {
                return .concreteSpecialization
            }
            // A closure used by a default expression is rooted in the default
            // argument helper rather than in an archived App declaration.
            if symbol.contains("fA"), symbol.contains("cfU") || symbol.contains("fU") {
                return .closureBody
            }
            if (isRooted || isModuleLocal),
               symbol.contains("_Tg") || symbol.contains("Tf") {
                return .concreteSpecialization
            }
            if (isRooted || isModuleLocal),
               symbol.contains("cfU") || symbol.contains("fU") {
                return .closureBody
            }
            return isModuleLocal ? .ordinary : nil
        }

        private func reachableFunctions(
            roots: Set<Bytecode.FunctionID>,
            functions: [(id: Bytecode.FunctionID, function: IntermediateRepresentation.Function)]
        ) -> Set<Bytecode.FunctionID> {
            let byID = Dictionary(uniqueKeysWithValues: functions.map { ($0.id, $0.function) })
            var reachable = roots
            var worklist = Array(roots)
            while let id = worklist.popLast(), let function = byID[id] {
                for instruction in function.blocks.flatMap(\.instructions) {
                    let targets: [Bytecode.FunctionID] = switch instruction {
                    case let .apply(_, function, _),
                         let .tryApply(function, _, _, _),
                         let .makeClosure(_, .image(function), _, _):
                        [function]
                    case let .existentialApply(_, _, _, dispatch),
                         let .existentialTryApply(_, _, dispatch, _, _):
                        dispatch.targets.map(\.function)
                    default:
                        []
                    }
                    // Every finite witness target remains reachable even when
                    // one concrete type is absent from the patch's currently
                    // exercised source path.
                    for candidate in targets where byID[candidate] != nil {
                        if reachable.insert(candidate).inserted {
                            worklist.append(candidate)
                        }
                    }
                }
            }
            return reachable
        }

        private func mergedLocalTypeDefinitions(
            optimized: CanonicalSIL.TypeEnvironment,
            semantic: CanonicalSIL.TypeEnvironment,
            referencedBy functions: [IntermediateRepresentation.Function],
            hostedMethods: [Bytecode.LocalTypeKey: [Bytecode.HostedMethod]]
        ) throws -> [Bytecode.LocalTypeDefinition] {
            let candidates = try optimized.definitions(
                referencedBy: functions,
                hostedMethods: hostedMethods
            ) + semantic.definitions(
                referencedBy: functions,
                hostedMethods: hostedMethods
            )
            var byKey: [Bytecode.LocalTypeKey: Bytecode.LocalTypeDefinition] = [:]
            for candidate in candidates {
                if let existing = byKey[candidate.key], existing != candidate {
                    throw DriverError.sourceSetMismatch(
                        "optimized and semantic SIL disagree on local type \(candidate.key)"
                    )
                }
                byKey[candidate.key] = candidate
            }
            return byKey.values.sorted { $0.key < $1.key }
        }

        private func mergeHostedMethods(
            optimized: [CanonicalSIL.TypeEnvironment.HostedMethodCandidate],
            semantic: [CanonicalSIL.TypeEnvironment.HostedMethodCandidate],
            imageFunctions: [ImageFunction]
        ) throws -> [Bytecode.LocalTypeKey: [Bytecode.HostedMethod]] {
            let idBySymbol = Dictionary(
                uniqueKeysWithValues: imageFunctions.map { ($0.symbol, $0.id) }
            )
            func identities(
                _ values: [CanonicalSIL.TypeEnvironment.HostedMethodCandidate]
            ) -> [(Bytecode.LocalTypeKey, UInt32, String, Bytecode.HostedMethodABI, String)] {
                values.map {
                    ($0.typeKey, $0.methodIndex, $0.selector, $0.abi, $0.symbol)
                }.sorted {
                    ($0.0, $0.1, $0.2, $0.4) < ($1.0, $1.1, $1.2, $1.4)
                }
            }
            let optimizedIdentities = identities(optimized)
            let semanticIdentities = identities(semantic)
            guard optimizedIdentities.elementsEqual(
                semanticIdentities,
                by: { left, right in
                    left.0 == right.0 && left.1 == right.1
                        && left.2 == right.2 && left.3 == right.3
                        && left.4 == right.4
                }
            ) else {
                throw DriverError.sourceSetMismatch(
                    "optimized and semantic SIL disagree on hosted class methods"
                )
            }
            var result: [Bytecode.LocalTypeKey: [(
                index: UInt32,
                method: Bytecode.HostedMethod
            )]] = [:]
            for candidate in optimized {
                guard let id = idBySymbol[candidate.symbol] else {
                    throw DriverError.generatedFunctionUnsupported(
                        candidate.symbol,
                        reason: "hosted method was not assigned an image-local function ID"
                    )
                }
                result[candidate.typeKey, default: []].append(
                    (
                        candidate.methodIndex,
                        .init(
                            selector: candidate.selector,
                            functionID: id,
                            abi: candidate.abi
                        )
                    )
                )
            }
            return result.mapValues { values in
                values.sorted { $0.index < $1.index }.map(\.method)
            }
        }

        private func lowerProductionFunction(
            optimized: CanonicalSIL.Function,
            semantic: CanonicalSIL.Function,
            optimizedTypeEnvironment: CanonicalSIL.TypeEnvironment,
            semanticTypeEnvironment: CanonicalSIL.TypeEnvironment,
            optimizedFile: CanonicalSIL.File,
            semanticFile: CanonicalSIL.File,
            displayName: String,
            directCalls: CanonicalSIL.DirectCallTable,
            expectedEffects: Core.Effects,
            hasDistinctSemanticFallback: Bool
        ) throws -> IntermediateRepresentation.Function {
            do {
                return try CanonicalSIL.Lowerer(
                    typeEnvironment: optimizedTypeEnvironment,
                    file: optimizedFile
                ).lower(
                    optimized,
                    displayName: displayName,
                    directCalls: directCalls,
                    expectedEffects: expectedEffects
                )
            } catch let error as CanonicalSIL.LoweringError
                where hasDistinctSemanticFallback && permitsSemanticFallback(error) {
                return try CanonicalSIL.Lowerer(
                    typeEnvironment: semanticTypeEnvironment,
                    file: semanticFile
                ).lower(
                    semantic,
                    displayName: displayName,
                    directCalls: directCalls,
                    expectedEffects: expectedEffects
                )
            }
        }

        /// Only compiler-SIL shape failures may select the semantic fallback.
        /// Function selection and call-table failures describe frozen build
        /// inputs and must remain hard failures instead of being hidden by a
        /// second compilation pass.
        private func permitsSemanticFallback(_ error: CanonicalSIL.LoweringError) -> Bool {
            switch error {
            case .malformedSIL,
                 .unsupportedType,
                 .unsupportedInstruction,
                 .undefinedValue,
                 .unboundCallee,
                 .unavailableNativeImport,
                 .callSignatureMismatch:
                true
            case .functionSelection, .invalidCallTable:
                false
            }
        }

        private func recordOrder(_ lhs: InterfaceArchive.FunctionRecord, _ rhs: InterfaceArchive.FunctionRecord) -> Bool {
            switch (lhs.entryIndex, rhs.entryIndex) {
            case let (.some(left), .some(right)): left < right
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): lhs.key.rawValue < rhs.key.rawValue
            }
        }

        private func orderedCompleteSourceSet(
            _ sourceFiles: [URL],
            archive: InterfaceArchive.Archive
        ) throws -> [URL] {
            guard sourceFiles.count == archive.sources.count else {
                throw DriverError.sourceSetMismatch(
                    "expected \(archive.sources.count) files from HLXI, received \(sourceFiles.count)"
                )
            }
            let resolvedPaths = sourceFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            guard Set(resolvedPaths).count == resolvedPaths.count else {
                throw DriverError.sourceSetMismatch("the same physical source was supplied more than once")
            }

            let supplied = sourceFiles.map { ($0.standardizedFileURL.path, $0) }
            var ordered: [URL] = []
            for source in archive.sources.sorted(by: { $0.logicalPath < $1.logicalPath }) {
                let suffix = "/\(source.logicalPath)"
                let matches = supplied.filter { $0.0 == source.logicalPath || $0.0.hasSuffix(suffix) }
                guard matches.count == 1 else {
                    throw DriverError.sourceSetMismatch(
                        "logical source \(source.logicalPath) must map to exactly one input file"
                    )
                }
                ordered.append(matches[0].1)
            }
            return ordered
        }

    }
}
