import Foundation

extension XcodeIntegration {
public struct BridgeCompilationPlan: Hashable, Sendable {
    public var compilerURL: URL
    public var arguments: [String]
    public var outputURL: URL

    public init(compilerURL: URL, arguments: [String], outputURL: URL) {
        self.compilerURL = compilerURL
        self.arguments = arguments
        self.outputURL = outputURL
    }
}

/// Derives a hermetic Bridge compilation from the Feature target's captured Swift
/// invocation while deliberately discarding its sources, outputs, and
/// incremental-driver state.
public struct BridgeCompilationPlanner: Sendable {
    public init() {}

    public func plan(
        compilerPath: String,
        capturedArguments: [String],
        expectedCompilerPath: String,
        expectedCapturedModuleName: String,
        expectedTargetTriple: String,
        expectedSDKPath: String,
        expectedOptimization: String,
        additionalModuleSearchArguments: [String] = [],
        clangModuleMapURLs: [URL],
        generatedSourceURLs: [URL],
        outputURL: URL,
        moduleName: String
    ) throws -> XcodeIntegration.BridgeCompilationPlan {
        let compilerURL = URL(fileURLWithPath: compilerPath).standardizedFileURL
        let expectedCompilerURL = URL(fileURLWithPath: expectedCompilerPath)
            .standardizedFileURL
        let expectedSDKURL = URL(fileURLWithPath: expectedSDKPath).standardizedFileURL
        guard compilerPath.hasPrefix("/"),
              ["swiftc", "swift-driver"].contains(compilerURL.lastPathComponent),
              !compilerPath.unicodeScalars.contains(where: { $0.value == 0 }),
              expectedCompilerPath.hasPrefix("/"),
              !expectedCompilerPath.unicodeScalars.contains(where: { $0.value == 0 }),
              compilerURL == expectedCompilerURL
        else {
            throw XcodeIntegration.BridgeCompilationError.invalidCompiler
        }
        guard isSwiftIdentifier(moduleName),
              isSwiftIdentifier(expectedCapturedModuleName),
              ["-Onone", "-O", "-Osize"].contains(expectedOptimization),
              expectedSDKPath.hasPrefix("/"),
              !expectedSDKPath.unicodeScalars.contains(where: { $0.value == 0 }),
              outputURL.isFileURL,
              outputURL.path.hasPrefix("/"),
              outputURL.pathExtension == "o",
              !outputURL.path.unicodeScalars.contains(where: { $0.value == 0 }),
              !generatedSourceURLs.isEmpty,
              generatedSourceURLs.count <= 4_096,
              clangModuleMapURLs.count <= 64,
              Set(clangModuleMapURLs.map(\.standardizedFileURL)).count
                == clangModuleMapURLs.count,
              clangModuleMapURLs.allSatisfy({
                  $0.isFileURL && $0.path.hasPrefix("/")
                      && $0.pathExtension == "modulemap"
                      && !$0.path.unicodeScalars.contains(where: { $0.value == 0 })
              }),
              Set(generatedSourceURLs.map(\.standardizedFileURL)).count
                == generatedSourceURLs.count,
              generatedSourceURLs.allSatisfy({
                  $0.isFileURL && $0.pathExtension == "swift"
                      && $0.path.hasPrefix("/")
                      && !$0.path.unicodeScalars.contains(where: { $0.value == 0 })
              })
        else {
            throw XcodeIntegration.BridgeCompilationError.invalidInput
        }
        let capturedModule = try value(after: "-module-name", in: capturedArguments)
        let target = try value(after: "-target", in: capturedArguments)
        let sdk = try value(after: "-sdk", in: capturedArguments)
        guard capturedModule == expectedCapturedModuleName,
              target == expectedTargetTriple,
              sdk.hasPrefix("/"), !sdk.unicodeScalars.contains(where: { $0.value == 0 }),
              URL(fileURLWithPath: sdk).standardizedFileURL == expectedSDKURL
        else {
            throw XcodeIntegration.BridgeCompilationError.captureMismatch
        }
        let optimization = capturedArguments.last(where: {
            ["-Onone", "-O", "-Osize"].contains($0)
        }) ?? "-Onone"
        guard optimization == expectedOptimization else {
            throw XcodeIntegration.BridgeCompilationError.captureMismatch
        }
        let additionalModuleSearchArguments = try validatedModuleSearchArguments(
            additionalModuleSearchArguments
        )
        let semanticArguments: [String]
        do {
            semanticArguments = try XcodeIntegration.CompilerArguments
                .semanticArguments(from: capturedArguments)
        } catch let error as XcodeIntegration.CompilerArgumentError {
            throw XcodeIntegration.BridgeCompilationError
                .invalidSemanticArguments(error.description)
        }
        var arguments = [
            "-emit-object", "-whole-module-optimization",
            optimization,
            "-target", target,
            "-sdk", sdk,
            "-module-name", moduleName,
            "-runtime-compatibility-version", "none",
            "-disable-autolinking-runtime-compatibility",
            "-disable-autolinking-runtime-compatibility-concurrency",
            "-disable-autolinking-runtime-compatibility-dynamic-replacements",
        ]
        arguments.append(contentsOf: semanticArguments)
        arguments.append(contentsOf: additionalModuleSearchArguments)
        for moduleMap in clangModuleMapURLs.map(\.standardizedFileURL).sorted(by: {
            $0.path < $1.path
        }) {
            arguments.append(contentsOf: [
                "-Xcc", "-fmodule-map-file=\(moduleMap.path)",
            ])
        }
        arguments.append(contentsOf: generatedSourceURLs.sorted {
            $0.path < $1.path
        }.map(\.path))
        arguments.append(contentsOf: ["-o", outputURL.path])
        return .init(
            compilerURL: compilerURL,
            arguments: arguments,
            outputURL: outputURL
        )
    }

    private func validatedModuleSearchArguments(
        _ arguments: [String]
    ) throws -> [String] {
        guard arguments.count <= 4_096 else {
            throw XcodeIntegration.BridgeCompilationError.invalidInput
        }
        var result: [String] = []
        var seen = Set<String>()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["-I", "-F", "-Fsystem"].contains(flag),
                  index + 1 < arguments.count
            else {
                throw XcodeIntegration.BridgeCompilationError.invalidInput
            }
            let path = arguments[index + 1]
            guard path.hasPrefix("/"),
                  path.utf8.count <= 64 * 1_024,
                  !path.contains("$"),
                  !path.unicodeScalars.contains(where: { $0.value == 0 })
            else {
                throw XcodeIntegration.BridgeCompilationError.invalidInput
            }
            let key = "\(flag)\u{0}\(path)"
            if seen.insert(key).inserted {
                result.append(contentsOf: [flag, path])
            }
            index += 2
        }
        return result
    }

    private func value(after option: String, in arguments: [String]) throws -> String {
        guard let index = arguments.lastIndex(of: option), index + 1 < arguments.count else {
            throw XcodeIntegration.BridgeCompilationError.malformedCapture(option)
        }
        let value = arguments[index + 1]
        guard !value.isEmpty, value.utf8.count <= 64 * 1_024,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw XcodeIntegration.BridgeCompilationError.malformedCapture(option)
        }
        return value
    }

    private func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }
}

public enum BridgeCompilationError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidCompiler
    case invalidInput
    case malformedCapture(String)
    case invalidSemanticArguments(String)
    case captureMismatch

    public var description: String {
        switch self {
        case .invalidCompiler: "captured Swift compiler path is invalid"
        case .invalidInput: "hidden Bridge compilation input is invalid"
        case let .malformedCapture(option):
            "captured Feature Swift invocation is missing or has an invalid \(option)"
        case let .invalidSemanticArguments(reason):
            "captured Feature Swift invocation has invalid semantic arguments: \(reason)"
        case .captureMismatch:
            "captured Feature Swift invocation does not match the active Helix profile"
        }
    }
}
}
