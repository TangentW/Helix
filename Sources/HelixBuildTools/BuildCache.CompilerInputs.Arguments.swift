import Foundation

extension BuildCache.CompilerInputs {
enum LocationKind: String {
    case searchRoot
    case explicitInput
    case bridgingHeaderInput
    case moduleMapInput
    case overlayInput
}

struct Location: Hashable {
    var kind: LocationKind
    var path: String
}

struct ParsedArguments {
    var values: [Location]
    var isComplete: Bool
    var hasBridgingHeader: Bool
}

static func parseArguments(
    _ input: [String],
    currentModuleName: String,
    workingDirectory: URL
) -> ParsedArguments {
    let arguments = unwrapForwardedArguments(input)
    let pairedSearch = Set([
        "-I", "-F", "-Fsystem", "-iquote", "-isystem", "-idirafter",
        "-iframework", "-iframeworkwithsysroot",
    ])
    let pairedInputs: [String: LocationKind] = [
        "-import-objc-header": .bridgingHeaderInput,
        "-include": .bridgingHeaderInput,
        "-imacros": .bridgingHeaderInput,
        "-include-pch": .explicitInput,
        "-explicit-swift-module-map-file": .explicitInput,
        "-fmodule-map-file": .moduleMapInput,
        "-fmodule-file": .explicitInput,
        "-vfsoverlay": .overlayInput,
        "-ivfsoverlay": .overlayInput,
    ]
    let pairedOutputs = Set([
        "-o", "-emit-module-path", "-emit-objc-header-path",
        "-serialize-diagnostics-path", "-emit-dependencies-path",
        "-emit-reference-dependencies-path", "-index-store-path",
        "-module-cache-path", "-sdk-module-cache-path",
    ])
    var result: [Location] = []
    var seen = Set<Location>()
    func append(_ location: Location) {
        if seen.insert(location).inserted { result.append(location) }
    }
    var complete = true
    var hasBridgingHeader = false
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if pairedSearch.contains(argument) {
            guard index + 1 < arguments.count else {
                complete = false
                break
            }
            if let path = absolutePath(arguments[index + 1], in: workingDirectory),
               !isToolchainOrSDKPath(path) {
                append(.init(kind: .searchRoot, path: path))
            }
            index += 2
            continue
        }
        if let kind = pairedInputs[argument] {
            guard index + 1 < arguments.count else {
                complete = false
                break
            }
            if let path = absolutePath(arguments[index + 1], in: workingDirectory),
               !isToolchainOrSDKPath(path),
               !belongsToCurrentModule(path, moduleName: currentModuleName) {
                append(.init(kind: kind, path: path))
                if kind == .bridgingHeaderInput {
                    hasBridgingHeader = true
                }
            }
            index += 2
            continue
        }
        if pairedOutputs.contains(argument) {
            index += min(2, arguments.count - index)
            continue
        }
        if let path = joinedSearchPath(argument),
           let absolute = absolutePath(path, in: workingDirectory),
           !isToolchainOrSDKPath(absolute) {
            append(.init(kind: .searchRoot, path: absolute))
        } else if let input = explicitInput(argument),
                  let absolute = absolutePath(input.path, in: workingDirectory),
                  !isToolchainOrSDKPath(absolute),
                  !belongsToCurrentModule(absolute, moduleName: currentModuleName) {
            append(.init(kind: input.kind, path: absolute))
        }
        index += 1
    }
    return .init(
        values: result,
        isComplete: complete,
        hasBridgingHeader: hasBridgingHeader
    )
}

static func isToolchainOrSDKPath(_ path: String) -> Bool {
    path.contains(".xctoolchain/")
        || path.contains(".platform/Developer/SDKs/")
        || path.contains("Xcode.app/Contents/Developer/Platforms/")
}

static func belongsToCurrentModule(
    _ path: String,
    moduleName: String
) -> Bool {
    guard !moduleName.isEmpty else { return false }
    return path.split(separator: "/").contains { component in
        component == Substring("\(moduleName).swiftmodule")
            || component == Substring("\(moduleName).swiftdoc")
            || component == Substring("\(moduleName).swiftinterface")
            || component == Substring("\(moduleName).private.swiftinterface")
    } || path.split(separator: "/").contains("HelixGenerated")
}

private static func unwrapForwardedArguments(_ arguments: [String]) -> [String] {
    var result: [String] = []
    var index = 0
    while index < arguments.count {
        if ["-Xcc", "-Xfrontend"].contains(arguments[index]),
           index + 1 < arguments.count {
            result.append(arguments[index + 1])
            index += 2
        } else {
            result.append(arguments[index])
            index += 1
        }
    }
    return result
}

private static func joinedSearchPath(_ argument: String) -> String? {
    for prefix in [
        "-iframeworkwithsysroot", "-Fsystem", "-iframework", "-idirafter",
        "-isystem", "-iquote", "-I", "-F",
    ] where argument.hasPrefix(prefix) {
        let value = String(argument.dropFirst(prefix.count))
        if value.hasPrefix("=") { return String(value.dropFirst()) }
        return value.isEmpty ? nil : value
    }
    return nil
}

private static func explicitInput(
    _ argument: String
) -> (kind: LocationKind, path: String)? {
    for (prefix, kind) in [
        ("-fmodule-map-file=", LocationKind.moduleMapInput),
        ("-ivfsoverlay=", LocationKind.overlayInput),
        ("-vfsoverlay=", LocationKind.overlayInput),
        ("-fmodule-file=", LocationKind.explicitInput),
    ] where argument.hasPrefix(prefix) {
        let value = String(argument.dropFirst(prefix.count))
        // Clang also permits `-fmodule-file=Module=/path/File.pcm`.
        return value.split(separator: "=").last.map { (kind, String($0)) }
    }
    return nil
}

private static func absolutePath(_ path: String, in directory: URL) -> String? {
    guard !path.isEmpty, path.utf8.count <= 1_048_576,
          !path.unicodeScalars.contains(where: { $0.value == 0 })
    else { return nil }
    return (path.hasPrefix("/")
        ? URL(fileURLWithPath: path)
        : directory.appendingPathComponent(path))
        .standardizedFileURL.path
}
}
