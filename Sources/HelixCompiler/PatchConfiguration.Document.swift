import Foundation
import HelixCore

public enum PatchConfiguration {}

extension PatchConfiguration {
public enum EntrypointVisibility: String, Codable, Hashable, Sendable {
    case publicOnly = "public"
    case publicAndInternal = "public-and-internal"
    case all

    public func allows(accessLevel: String) -> Bool {
        switch self {
        case .publicOnly:
            accessLevel == "public" || accessLevel == "open"
        case .publicAndInternal:
            ["public", "open", "internal", "package"].contains(accessLevel)
        case .all:
            !accessLevel.isEmpty
        }
    }
}

public enum NativeImportCandidateIndex: String, Codable, Hashable, Sendable {
    case explicitCatalog = "explicit-catalog"
    case sourceAndCatalog = "source-and-catalog"
}

public enum NativeImportEmission: String, Codable, Hashable, Sendable {
    case allowlisted
    case scoped
}

public enum NativeImportSourceProfile: String, Codable, Hashable, Sendable {
    case boundedPure = "bounded-pure"
    case boundedRead = "bounded-read"
    case boundedReadWrite = "bounded-read-write"
}

public struct NativeImportSourceScope: Codable, Hashable, Sendable {
    public var include: [String]
    public var exclude: [String]
    public var declarations: [String]
    public var visibility: PatchConfiguration.EntrypointVisibility
    public var profile: PatchConfiguration.NativeImportSourceProfile?
    public var maximumDurationMicroseconds: UInt32
    public var allowsMainThread: Bool

    public init(
        include: [String],
        exclude: [String] = [],
        declarations: [String] = ["*"],
        visibility: PatchConfiguration.EntrypointVisibility = .publicOnly,
        profile: PatchConfiguration.NativeImportSourceProfile? = nil,
        maximumDurationMicroseconds: UInt32 = 2_000,
        allowsMainThread: Bool = true
    ) {
        self.include = include
        self.exclude = exclude
        self.declarations = declarations
        self.visibility = visibility
        self.profile = profile
        self.maximumDurationMicroseconds = maximumDurationMicroseconds
        self.allowsMainThread = allowsMainThread
    }

    public func includes(
        logicalPath: String,
        canonicalCallee: String,
        accessLevel: String
    ) -> Bool {
        include.contains { Glob($0).matches(logicalPath) }
            && !exclude.contains { Glob($0).matches(logicalPath) }
            && declarations.contains { Glob($0).matches(canonicalCallee) }
            && visibility.allows(accessLevel: accessLevel)
    }

    fileprivate func validate(moduleName: String) throws {
        guard !include.isEmpty,
              include.allSatisfy({ !$0.isEmpty }),
              exclude.allSatisfy({ !$0.isEmpty }),
              !declarations.isEmpty,
              declarations.allSatisfy({ !$0.isEmpty }),
              profile != nil,
              (1...2_000).contains(maximumDurationMicroseconds)
        else {
            throw PatchConfiguration.Error.invalid(
                "module \(moduleName) sourceScope needs nonempty patterns, an explicit bounded profile, and a 1...2000 us deadline"
            )
        }
    }
}

public struct NativeImports: Codable, Hashable, Sendable {
    public var candidateIndex: PatchConfiguration.NativeImportCandidateIndex?
    public var emit: PatchConfiguration.NativeImportEmission?
    public var allow: [String]
    public var sourceScope: PatchConfiguration.NativeImportSourceScope?

    public init(
        candidateIndex: PatchConfiguration.NativeImportCandidateIndex? = nil,
        emit: PatchConfiguration.NativeImportEmission? = nil,
        allow: [String] = [],
        sourceScope: PatchConfiguration.NativeImportSourceScope? = nil
    ) {
        self.candidateIndex = candidateIndex
        self.emit = emit
        self.allow = allow
        self.sourceScope = sourceScope
    }

    fileprivate func validate(moduleName: String) throws {
        let configured = candidateIndex != nil || emit != nil || !allow.isEmpty
            || sourceScope != nil
        guard configured else { return }
        switch (candidateIndex, emit) {
        case (.explicitCatalog?, .allowlisted?):
            guard sourceScope == nil else {
                throw PatchConfiguration.Error.invalid(
                    "module \(moduleName) cannot attach a sourceScope to explicit-catalog"
                )
            }
        case (.sourceAndCatalog?, .scoped?):
            guard let sourceScope else {
                throw PatchConfiguration.Error.invalid(
                    "module \(moduleName) source-and-catalog discovery requires sourceScope"
                )
            }
            try sourceScope.validate(moduleName: moduleName)
        default:
            throw PatchConfiguration.Error.invalid(
                "module \(moduleName) has an incomplete or incompatible NativeImport mode"
            )
        }
        guard allow.allSatisfy({ !$0.isEmpty }), Set(allow).count == allow.count else {
            throw PatchConfiguration.Error.invalid(
                "module \(moduleName) NativeImport allowlist contains an empty or duplicate entry"
            )
        }
    }
}

public struct Module: Codable, Hashable, Sendable {
    public var include: [String]
    public var exclude: [String]
    public var entrypoints: PatchConfiguration.EntrypointVisibility
    public var nativeImports: PatchConfiguration.NativeImports

    public init(
        include: [String],
        exclude: [String] = [],
        entrypoints: PatchConfiguration.EntrypointVisibility = .publicAndInternal,
        nativeImports: PatchConfiguration.NativeImports = .init()
    ) {
        self.include = include
        self.exclude = exclude
        self.entrypoints = entrypoints
        self.nativeImports = nativeImports
    }

    public func includes(logicalPath: String) -> Bool {
        include.contains { Glob($0).matches(logicalPath) }
            && !exclude.contains { Glob($0).matches(logicalPath) }
    }
}

public struct Document: Codable, Hashable, Sendable {
    public static let currentSchema: UInt32 = 1

    public var schema: UInt32
    public var modules: [String: PatchConfiguration.Module]
    public var language: [String: String]

    public init(
        schema: UInt32 = Self.currentSchema,
        modules: [String: PatchConfiguration.Module],
        language: [String: String] = [:]
    ) {
        self.schema = schema
        self.modules = modules
        self.language = language
    }

    public static func parse(yaml: String) throws -> Self {
        try Parser().parse(yaml)
    }

    public func validate() throws {
        guard schema == Self.currentSchema else {
            throw PatchConfiguration.Error.unsupportedSchema(schema)
        }
        guard !modules.isEmpty else {
            throw PatchConfiguration.Error.invalid("configuration contains no Swift modules")
        }
        for (name, module) in modules {
            guard !module.include.isEmpty,
                  module.include.allSatisfy({ !$0.isEmpty }),
                  module.exclude.allSatisfy({ !$0.isEmpty })
            else {
                throw PatchConfiguration.Error.missingInclude(name)
            }
            try module.nativeImports.validate(moduleName: name)
        }
    }
}

public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case syntax(line: Int, message: String)
    case unsupportedSchema(UInt32)
    case duplicateModule(String)
    case missingInclude(String)
    case unknownKey(line: Int, key: String)
    case invalid(String)

    public var description: String {
        switch self {
        case let .syntax(line, message): "HelixPatchable.yml:\(line): \(message)"
        case let .unsupportedSchema(schema): "unsupported HelixPatchable schema \(schema)"
        case let .duplicateModule(module): "duplicate module \(module)"
        case let .missingInclude(module): "module \(module) has no include patterns"
        case let .unknownKey(line, key): "HelixPatchable.yml:\(line): unknown key \(key)"
        case let .invalid(reason): "invalid HelixPatchable configuration: \(reason)"
        }
    }
}

private struct Parser {
    private struct ModuleBuilder {
        var include: [String] = []
        var exclude: [String] = []
        var entrypoints: PatchConfiguration.EntrypointVisibility = .publicAndInternal
        var nativeImports = PatchConfiguration.NativeImports()
    }

    func parse(_ yaml: String) throws -> PatchConfiguration.Document {
        var schema: UInt32?
        var modules: [String: ModuleBuilder] = [:]
        var language: [String: String] = [:]
        var section: String?
        var currentModule: String?
        var moduleList: String?
        var inNativeImports = false
        var nativeAllowList = false
        var inNativeSourceScope = false
        var nativeSourceList: String?

        for (zeroBasedLine, rawLine) in yaml.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = zeroBasedLine + 1
            let uncommented = stripComment(String(rawLine))
            if uncommented.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard !uncommented.contains("\t") else {
                throw PatchConfiguration.Error.syntax(line: lineNumber, message: "tabs are not allowed")
            }
            let indent = uncommented.prefix { $0 == " " }.count
            guard indent % 2 == 0 else {
                throw PatchConfiguration.Error.syntax(line: lineNumber, message: "indentation must use multiples of two spaces")
            }
            let content = uncommented.dropFirst(indent).trimmingCharacters(in: .whitespaces)

            if indent == 0 {
                currentModule = nil
                moduleList = nil
                inNativeImports = false
                nativeAllowList = false
                inNativeSourceScope = false
                nativeSourceList = nil
                if content.hasPrefix("schema:") {
                    guard let value = UInt32(value(afterColon: content)) else {
                        throw PatchConfiguration.Error.syntax(line: lineNumber, message: "schema must be an integer")
                    }
                    schema = value
                    section = nil
                } else if content == "modules:" {
                    section = "modules"
                } else if content == "language:" {
                    section = "language"
                } else {
                    throw PatchConfiguration.Error.unknownKey(line: lineNumber, key: key(of: content))
                }
                continue
            }

            if section == "language" {
                guard indent == 2, content.contains(":") else {
                    throw PatchConfiguration.Error.syntax(line: lineNumber, message: "invalid language rule")
                }
                language[key(of: content)] = unquote(value(afterColon: content))
                continue
            }

            guard section == "modules" else {
                throw PatchConfiguration.Error.syntax(line: lineNumber, message: "content is outside modules/language")
            }
            if indent == 2, content.hasSuffix(":"), !content.hasPrefix("-") {
                let module = String(content.dropLast()).trimmingCharacters(in: .whitespaces)
                guard !module.isEmpty else {
                    throw PatchConfiguration.Error.syntax(line: lineNumber, message: "empty module name")
                }
                guard modules[module] == nil else { throw PatchConfiguration.Error.duplicateModule(module) }
                modules[module] = ModuleBuilder()
                currentModule = module
                moduleList = nil
                inNativeImports = false
                nativeAllowList = false
                inNativeSourceScope = false
                nativeSourceList = nil
                continue
            }
            guard let module = currentModule, var builder = modules[module] else {
                throw PatchConfiguration.Error.syntax(line: lineNumber, message: "module property without a module")
            }

            if indent == 4 {
                moduleList = nil
                nativeAllowList = false
                inNativeSourceScope = false
                nativeSourceList = nil
                if content == "include:" || content == "exclude:" {
                    moduleList = String(content.dropLast())
                    inNativeImports = false
                } else if content == "nativeImports:" {
                    inNativeImports = true
                } else if content.hasPrefix("entrypoints:") {
                    guard let value = PatchConfiguration.EntrypointVisibility(rawValue: unquote(value(afterColon: content))) else {
                        throw PatchConfiguration.Error.syntax(line: lineNumber, message: "invalid entrypoints value")
                    }
                    builder.entrypoints = value
                    inNativeImports = false
                } else {
                    throw PatchConfiguration.Error.unknownKey(line: lineNumber, key: key(of: content))
                }
                modules[module] = builder
                continue
            }

            if indent == 6, content.hasPrefix("- "), let moduleList {
                let value = unquote(String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                if moduleList == "include" { builder.include.append(value) } else { builder.exclude.append(value) }
                modules[module] = builder
                continue
            }

            if inNativeImports, indent == 6 {
                if content == "allow:" {
                    nativeAllowList = true
                    inNativeSourceScope = false
                    nativeSourceList = nil
                } else if content == "sourceScope:" {
                    nativeAllowList = false
                    inNativeSourceScope = true
                    nativeSourceList = nil
                    if builder.nativeImports.sourceScope == nil {
                        builder.nativeImports.sourceScope = .init(include: [])
                    }
                } else if content.hasPrefix("candidateIndex:") {
                    guard let value = PatchConfiguration.NativeImportCandidateIndex(
                        rawValue: unquote(value(afterColon: content))
                    ) else {
                        throw PatchConfiguration.Error.syntax(
                            line: lineNumber,
                            message: "unsupported native import candidateIndex"
                        )
                    }
                    builder.nativeImports.candidateIndex = value
                } else if content.hasPrefix("emit:") {
                    guard let value = PatchConfiguration.NativeImportEmission(
                        rawValue: unquote(value(afterColon: content))
                    ) else {
                        throw PatchConfiguration.Error.syntax(
                            line: lineNumber,
                            message: "unsupported native import emit mode"
                        )
                    }
                    builder.nativeImports.emit = value
                } else {
                    throw PatchConfiguration.Error.unknownKey(line: lineNumber, key: key(of: content))
                }
                modules[module] = builder
                continue
            }

            if inNativeImports, nativeAllowList, indent == 8, content.hasPrefix("- ") {
                builder.nativeImports.allow.append(unquote(String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                modules[module] = builder
                continue
            }

            if inNativeImports, inNativeSourceScope, indent == 8 {
                guard var scope = builder.nativeImports.sourceScope else {
                    throw PatchConfiguration.Error.syntax(
                        line: lineNumber,
                        message: "sourceScope was not initialized"
                    )
                }
                nativeSourceList = nil
                if ["include:", "exclude:", "declarations:"].contains(content) {
                    nativeSourceList = String(content.dropLast())
                } else if content.hasPrefix("visibility:") {
                    guard let value = PatchConfiguration.EntrypointVisibility(
                        rawValue: unquote(value(afterColon: content))
                    ) else {
                        throw PatchConfiguration.Error.syntax(
                            line: lineNumber,
                            message: "invalid NativeImport source visibility"
                        )
                    }
                    scope.visibility = value
                } else if content.hasPrefix("profile:") {
                    guard let value = PatchConfiguration.NativeImportSourceProfile(
                        rawValue: unquote(value(afterColon: content))
                    ) else {
                        throw PatchConfiguration.Error.syntax(
                            line: lineNumber,
                            message: "invalid NativeImport source profile"
                        )
                    }
                    scope.profile = value
                } else if content.hasPrefix("maximumDurationMicroseconds:") {
                    guard let value = UInt32(value(afterColon: content)) else {
                        throw PatchConfiguration.Error.syntax(
                            line: lineNumber,
                            message: "NativeImport source deadline must be an integer"
                        )
                    }
                    scope.maximumDurationMicroseconds = value
                } else if content.hasPrefix("allowsMainThread:") {
                    guard let value = Bool(value(afterColon: content)) else {
                        throw PatchConfiguration.Error.syntax(
                            line: lineNumber,
                            message: "NativeImport allowsMainThread must be true or false"
                        )
                    }
                    scope.allowsMainThread = value
                } else {
                    throw PatchConfiguration.Error.unknownKey(
                        line: lineNumber,
                        key: key(of: content)
                    )
                }
                builder.nativeImports.sourceScope = scope
                modules[module] = builder
                continue
            }

            if inNativeImports, inNativeSourceScope, indent == 10,
               content.hasPrefix("- "), let nativeSourceList {
                guard var scope = builder.nativeImports.sourceScope else {
                    throw PatchConfiguration.Error.syntax(
                        line: lineNumber,
                        message: "sourceScope was not initialized"
                    )
                }
                let item = unquote(
                    String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                )
                switch nativeSourceList {
                case "include": scope.include.append(item)
                case "exclude": scope.exclude.append(item)
                case "declarations":
                    if scope.declarations == ["*"] { scope.declarations = [] }
                    scope.declarations.append(item)
                default:
                    throw PatchConfiguration.Error.syntax(
                        line: lineNumber,
                        message: "unsupported sourceScope list"
                    )
                }
                builder.nativeImports.sourceScope = scope
                modules[module] = builder
                continue
            }

            throw PatchConfiguration.Error.syntax(line: lineNumber, message: "unsupported configuration structure")
        }

        let resolvedSchema = schema ?? 0
        guard resolvedSchema == PatchConfiguration.Document.currentSchema else {
            throw PatchConfiguration.Error.unsupportedSchema(resolvedSchema)
        }
        var result: [String: PatchConfiguration.Module] = [:]
        for (name, builder) in modules {
            guard !builder.include.isEmpty else { throw PatchConfiguration.Error.missingInclude(name) }
            result[name] = .init(
                include: builder.include,
                exclude: builder.exclude,
                entrypoints: builder.entrypoints,
                nativeImports: builder.nativeImports
            )
        }
        let document = PatchConfiguration.Document(
            schema: resolvedSchema,
            modules: result,
            language: language
        )
        try document.validate()
        return document
    }

    private func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if character == "\"" || character == "'" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private func key(of content: String) -> String {
        String(content.split(separator: ":", maxSplits: 1).first ?? "")
    }

    private func value(afterColon content: String) -> String {
        guard let colon = content.firstIndex(of: ":") else { return "" }
        return String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else { return value }
        return String(value.dropFirst().dropLast())
    }
}

private struct Glob {
    let pattern: String
    init(_ pattern: String) { self.pattern = pattern }

    func matches(_ path: String) -> Bool {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterDoubleStar = pattern.index(after: next)
                    if afterDoubleStar < pattern.endIndex, pattern[afterDoubleStar] == "/" {
                        // "**/" means zero or more complete path components.
                        expression += "(?:.*/)?"
                        index = pattern.index(after: afterDoubleStar)
                    } else {
                        expression += ".*"
                        index = afterDoubleStar
                    }
                } else {
                    expression += "[^/]*"
                    index = next
                }
            } else if character == "?" {
                expression += "[^/]"
                index = pattern.index(after: index)
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
                index = pattern.index(after: index)
            }
        }
        expression += "$"
        return path.range(of: expression, options: .regularExpression) != nil
    }
}
}
