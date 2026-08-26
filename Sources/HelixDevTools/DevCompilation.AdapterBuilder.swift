import Foundation
import HelixBuildTools
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface

extension DevCompilation {
/// A signed, cacheable development image containing only newly required Swift
/// Adapter bodies. Objective-C and C calls use their generic invokers and never
/// enter this compiler path.
public struct AdapterImage: Sendable {
    public var bytes: Data
    public var descriptor: MachO.Descriptor
    public var installName: String
    public var keys: [Core.NativeCall.Key]
    public var cacheSource: BuildCache.Source

    public init(
        bytes: Data,
        descriptor: MachO.Descriptor,
        installName: String,
        keys: [Core.NativeCall.Key],
        cacheSource: BuildCache.Source
    ) {
        self.bytes = bytes
        self.descriptor = descriptor
        self.installName = installName
        self.keys = keys.sorted()
        self.cacheSource = cacheSource
    }
}

public struct AdapterBuildRequest: Sendable {
    public var manifest: DevBuildManifest.Document
    public var compilerURL: URL
    public var outputDirectory: URL
    public var records: [InterfaceArchive.NativeImportRecord]
    public var bindings: [BridgeGeneration.NativeImportBinding]

    public init(
        manifest: DevBuildManifest.Document,
        compilerURL: URL,
        outputDirectory: URL,
        records: [InterfaceArchive.NativeImportRecord],
        bindings: [BridgeGeneration.NativeImportBinding]
    ) {
        self.manifest = manifest
        self.compilerURL = compilerURL
        self.outputDirectory = outputDirectory
        self.records = records.sorted {
            ($0.id ?? .init(rawValue: UInt32.max))
                < ($1.id ?? .init(rawValue: UInt32.max))
        }
        self.bindings = bindings.sorted { $0.id < $1.id }
    }
}

public struct AdapterBuilder<Runner: ProcessExecution.Running>: Sendable {
    public var runner: Runner
    public var cache: BuildCache.Store?

    public init(runner: Runner, cache: BuildCache.Store? = nil) {
        self.runner = runner
        self.cache = cache
    }

    public func build(
        _ request: DevCompilation.AdapterBuildRequest
    ) throws -> DevCompilation.AdapterImage {
        try request.manifest.validate()
        guard request.manifest.platform != .iOS else {
            throw DevCompilation.NativeCapabilityError.deviceAdapterUnqualified
        }
        guard request.compilerURL.isFileURL,
              request.compilerURL.path.hasPrefix("/"),
              request.outputDirectory.isFileURL,
              request.outputDirectory.path.hasPrefix("/"),
              !request.records.isEmpty,
              request.records.count == request.bindings.count,
              Set(request.records.map(\.key)).count == request.records.count,
              Set(request.bindings.map(\.key)).count == request.bindings.count,
              Set(request.bindings.map(\.id)).count == request.bindings.count,
              request.records.allSatisfy({
                  $0.id != nil
                      && $0.isEmittedToDevice
                      && $0.descriptor.target.backend == .swiftAdapter
              }),
              request.bindings.allSatisfy({
                  $0.strategy == .generatedSwiftAdapter
              })
        else {
            throw DevCompilation.NativeCapabilityError.invalidAdapterRequest
        }
        let bindingsByKey = Dictionary(
            uniqueKeysWithValues: request.bindings.map { ($0.key, $0) }
        )
        guard request.records.allSatisfy({ record in
                  guard let id = record.id,
                        let binding = bindingsByKey[record.key]
                  else { return false }
                  return binding.id == id
              })
        else {
            throw DevCompilation.NativeCapabilityError.invalidAdapterRequest
        }

        let sourceFiles = try BridgeGeneration.Generator()
            .generateDevelopmentAdapterFiles(
                applicationModuleName: request.manifest.moduleName,
                bindings: request.bindings,
                records: request.records
            )
        let key = try cacheKey(request: request, sourceFiles: sourceFiles)
        let installName = "@rpath/HLXDevAdapter-\(key.hex).dylib"
        let validate: (Data) throws -> MachO.Descriptor = { bytes in
            try validateImage(
                bytes,
                manifest: request.manifest,
                installName: installName
            )
        }
        let value: BuildCache.Value
        if let cache {
            value = try cache.value(
                namespace: .developmentAdapter,
                key: key,
                maximumBytes: 64 * 1_024 * 1_024,
                validate: { _ = try validate($0) },
                produce: {
                    try compile(
                        request: request,
                        sourceFiles: sourceFiles,
                        key: key,
                        installName: installName
                    )
                }
            )
        } else {
            let bytes = try compile(
                request: request,
                sourceFiles: sourceFiles,
                key: key,
                installName: installName
            )
            _ = try validate(bytes)
            value = .init(data: bytes, source: .bypassed)
        }
        let descriptor = try validate(value.data)
        return .init(
            bytes: value.data,
            descriptor: descriptor,
            installName: installName,
            keys: request.records.map(\.key),
            cacheSource: value.source
        )
    }

    private func cacheKey(
        request: DevCompilation.AdapterBuildRequest,
        sourceFiles: [String: String]
    ) throws -> Core.Digest {
        let semanticArguments = try XcodeIntegration.CompilerArguments
            .semanticArguments(from: request.manifest.frontendArguments)
        var hasher = Core.StableHasher(domain: "HLX.DevelopmentAdapter.v1")
        hasher.append(request.manifest.swiftCompilerFingerprint)
        hasher.append(request.manifest.xcodeBuild)
        hasher.append(request.manifest.sdkBuild)
        hasher.append(request.manifest.targetTriple)
        hasher.append(request.manifest.minimumOS.description)
        hasher.append(request.manifest.dependencyGraphHash)
        hasher.append(request.manifest.moduleName)
        hasher.append(request.manifest.platform.rawValue)
        hasher.append(request.manifest.architecture)
        hasher.append(UInt64(semanticArguments.count))
        for argument in semanticArguments { hasher.append(argument) }
        let linkArguments = preservedLinkArguments(request.manifest.linkArguments)
        hasher.append(UInt64(linkArguments.count))
        for argument in linkArguments { hasher.append(argument) }
        hasher.append(UInt64(sourceFiles.count))
        for path in sourceFiles.keys.sorted() {
            hasher.append(path)
            hasher.append(Data(sourceFiles[path, default: ""].utf8))
        }
        hasher.append(UInt64(request.records.count))
        for record in request.records {
            hasher.append(record.key.rawValue)
            hasher.append(try Core.CanonicalJSON.encode(record.descriptor))
            hasher.append(try Core.CanonicalJSON.encode(record.parameterTypes))
            hasher.append(try Core.CanonicalJSON.encode(record.resultType))
            hasher.append(try Core.CanonicalJSON.encode(record.contract))
        }
        return hasher.finalize()
    }

    private func compile(
        request: DevCompilation.AdapterBuildRequest,
        sourceFiles: [String: String],
        key: Core.Digest,
        installName: String
    ) throws -> Data {
        let manager = FileManager.default
        try manager.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let buildDirectory = request.outputDirectory.appendingPathComponent(
            ".HLXDevAdapter-\(key.hex.prefix(16))-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(
            at: buildDirectory,
            withIntermediateDirectories: false
        )
        defer { try? manager.removeItem(at: buildDirectory) }

        let sourceURLs = try sourceFiles.keys.sorted().map { path -> URL in
            guard !path.hasPrefix("/"),
                  !path.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0.isEmpty || $0 == ".." })
            else {
                throw DevCompilation.NativeCapabilityError.invalidAdapterRequest
            }
            let url = buildDirectory.appendingPathComponent(path)
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(sourceFiles[path, default: ""].utf8).write(
                to: url,
                options: .atomic
            )
            return url
        }
        let objectURL = buildDirectory.appendingPathComponent("Adapter.o")
        let imageURL = buildDirectory.appendingPathComponent("Adapter.dylib")
        let moduleName = "HelixDevAdapter_\(key.hex.prefix(24))"
        let sdkPath = try capturedValue(
            after: "-sdk",
            in: request.manifest.frontendArguments
        )
        let plan = try XcodeIntegration.BridgeCompilationPlanner().plan(
            compilerPath: request.compilerURL.path,
            capturedArguments: request.manifest.frontendArguments,
            expectedCompilerPath: request.compilerURL.path,
            expectedCapturedModuleName: request.manifest.moduleName,
            expectedTargetTriple: request.manifest.targetTriple,
            expectedSDKPath: sdkPath,
            expectedOptimization: "-Onone",
            clangModuleMapURLs: [],
            generatedSourceURLs: sourceURLs,
            outputURL: objectURL,
            moduleName: moduleName
        )
        let compilation = try runner.run(
            executable: plan.compilerURL,
            arguments: plan.arguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: buildDirectory
        )
        guard compilation.status == 0 else {
            throw DevCompilation.NativeCapabilityError.adapterCompilationFailed(
                bounded(compilation.standardError, status: compilation.status)
            )
        }
        let linking = try runner.run(
            executable: request.compilerURL,
            arguments: [
                objectURL.path, "-emit-library",
                "-target", request.manifest.targetTriple,
                "-sdk", sdkPath,
                "-module-name", moduleName,
                "-runtime-compatibility-version", "none",
                "-disable-autolinking-runtime-compatibility",
                "-disable-autolinking-runtime-compatibility-concurrency",
                "-disable-autolinking-runtime-compatibility-dynamic-replacements",
                "-Xlinker", "-install_name", "-Xlinker", installName,
                "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
            ] + preservedLinkArguments(request.manifest.linkArguments) + [
                "-o", imageURL.path,
            ],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: buildDirectory
        )
        guard linking.status == 0 else {
            throw DevCompilation.NativeCapabilityError.adapterCompilationFailed(
                bounded(linking.standardError, status: linking.status)
            )
        }
        let signing = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force", "--sign", "-", "--timestamp=none", imageURL.path,
            ],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: buildDirectory
        )
        guard signing.status == 0 else {
            throw DevCompilation.NativeCapabilityError.adapterSigningFailed(
                bounded(signing.standardError, status: signing.status)
            )
        }
        let bytes = try Data(contentsOf: imageURL, options: .mappedIfSafe)
        _ = try validateImage(
            bytes,
            manifest: request.manifest,
            installName: installName
        )
        return bytes
    }

    private func validateImage(
        _ bytes: Data,
        manifest: DevBuildManifest.Document,
        installName: String
    ) throws -> MachO.Descriptor {
        let descriptor = try MachO.Inspector().inspect(bytes)
        guard descriptor.isCodeSigned, descriptor.uuid != nil else {
            throw DevCompilation.NativeCapabilityError.invalidAdapterImage(
                "signed Adapter is missing LC_CODE_SIGNATURE or LC_UUID"
            )
        }
        try MachO.Inspector().preflight(
            descriptor,
            expectedArchitecture: try architecture(manifest.architecture),
            expectedInstallName: installName,
            expectedPlatform: platform(manifest.platform),
            allowedDependencyPrefixes: [
                "/System/Library/", "/usr/lib/", "@rpath/",
                "@loader_path/", "@executable_path/",
            ]
        )
        return descriptor
    }

    private func capturedValue(
        after option: String,
        in arguments: [String]
    ) throws -> String {
        let indices = arguments.indices.filter { arguments[$0] == option }
        guard indices.count == 1,
              let index = indices.first,
              index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("/"),
              !arguments[index + 1].unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw DevCompilation.NativeCapabilityError.invalidAdapterRequest
        }
        return arguments[index + 1]
    }

    private func preservedLinkArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        let paired = Set([
            "-L", "-F", "-Fsystem", "-framework", "-weak_framework",
        ])
        while index < arguments.count {
            let argument = arguments[index]
            if paired.contains(argument), index + 1 < arguments.count {
                let value = arguments[index + 1]
                if !value.isEmpty,
                   value.utf8.count <= 64 * 1_024,
                   !value.unicodeScalars.contains(where: { $0.value == 0 }) {
                    result.append(contentsOf: [argument, value])
                }
                index += 2
                continue
            }
            if argument.hasPrefix("-l"), argument.count > 2,
               argument.utf8.count <= 1_024,
               !argument.unicodeScalars.contains(where: { $0.value == 0 }) {
                result.append(argument)
            }
            index += 1
        }
        return result
    }

    private func architecture(_ value: String) throws -> MachO.Architecture {
        switch value {
        case "arm64", "arm64e": .arm64
        case "x86_64": .x86_64
        default:
            throw DevCompilation.NativeCapabilityError.invalidAdapterRequest
        }
    }

    private func platform(_ value: DevProtocol.ApplePlatform) -> MachO.Platform {
        switch value {
        case .iOS: .iOS
        case .iOSSimulator: .iOSSimulator
        case .macOS: .macOS
        }
    }

    private func bounded(_ diagnostics: String, status: Int32) -> String {
        let value = diagnostics.isEmpty
            ? "Swift tool exited with status \(status)" : diagnostics
        return String(decoding: Data(value.utf8).prefix(512 * 1_024), as: UTF8.self)
    }
}

public typealias DefaultAdapterBuilder = DevCompilation.AdapterBuilder<
    ProcessExecution.Runner
>
}
