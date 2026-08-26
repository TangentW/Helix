import Foundation

extension NativeImportDiscovery {
enum SwiftAdapterPlacement: Hashable, Sendable {
    enum ApplicationReason: String, Hashable, Sendable {
        case noExternalSwiftDeclaration
        case applicationModuleDeclaration
        case compilerGeneratedOperation
        case referencesApplicationType
    }

    case application(ApplicationReason)
    case modulePack(String)

    var moduleName: String? {
        guard case let .modulePack(moduleName) = self else { return nil }
        return moduleName
    }
}

/// Classifies only executable pure-Swift adapters. Objective-C and C calls are
/// selected earlier by their compiler-proven ABI evidence and never enter a
/// Pack. A Pack is reusable only when its source references no application
/// nominal type or compiler-synthesized project operation.
struct SwiftAdapterClassifier: Sendable {
    func classify(
        declarationUSR: String?,
        hasCompilerOperation: Bool,
        adapterTypeSpellings: [String],
        applicationTypeNames: Set<String>,
        applicationModuleName: String
    ) -> NativeImportDiscovery.SwiftAdapterPlacement {
        guard let declarationUSR,
              let moduleName = Self.declarationModule(in: declarationUSR)
        else {
            return .application(.noExternalSwiftDeclaration)
        }
        guard moduleName != applicationModuleName else {
            return .application(.applicationModuleDeclaration)
        }
        guard !hasCompilerOperation else {
            return .application(.compilerGeneratedOperation)
        }
        guard !adapterTypeSpellings.contains(where: { spelling in
            applicationTypeNames.contains(where: {
                Self.typeSpelling(
                    spelling,
                    referencesNominal: $0,
                    applicationModuleName: applicationModuleName
                )
            })
        }) else {
            return .application(.referencesApplicationType)
        }
        return .modulePack(moduleName)
    }

    /// Keeps Pack imports deterministic and project-independent while
    /// retaining external modules named by the generated adapter's types.
    /// Unrelated imports from the application source must not perturb a shared
    /// Pack, and the declaration's owning module is always required.
    func requiredImports(
        primaryModule: String,
        typeSpellings: [String],
        candidateModules: [String]
    ) -> [String] {
        var result: Set<String> = [primaryModule]
        for module in candidateModules where Self.isModulePath(module) {
            guard typeSpellings.contains(where: {
                Self.typeSpelling($0, referencesModule: module)
            }) else { continue }
            result.insert(module)
        }
        return result.sorted()
    }

    static func declarationModule(in usr: String) -> String? {
        let bytes = Array(usr.utf8)
        guard bytes.starts(with: [0x73, 0x3a]) else { return nil }
        var cursor = 2
        var length = 0
        var hasDigit = false
        while cursor < bytes.count,
              bytes[cursor] >= 0x30,
              bytes[cursor] <= 0x39 {
            hasDigit = true
            let digit = Int(bytes[cursor] - 0x30)
            guard length <= (Int.max - digit) / 10 else { return nil }
            length = length * 10 + digit
            cursor += 1
        }
        guard hasDigit, length > 0, length < bytes.count - cursor,
              let module = String(
                  bytes: bytes[cursor..<(cursor + length)],
                  encoding: .utf8
              )
        else { return nil }
        return isSwiftIdentifier(module) ? module : nil
    }

    private static func typeSpelling(
        _ spelling: String,
        referencesNominal nominal: String,
        applicationModuleName: String
    ) -> Bool {
        let relative = nominal.hasPrefix(applicationModuleName + ".")
            ? String(nominal.dropFirst(applicationModuleName.count + 1))
            : nominal
        let tokens = typeTokens(in: spelling)
        return tokens.contains(nominal) || tokens.contains(relative)
    }

    private static func typeSpelling(
        _ spelling: String,
        referencesModule module: String
    ) -> Bool {
        typeTokens(in: spelling).contains {
            $0 == module || $0.hasPrefix(module + ".")
        }
    }

    private static func typeTokens(in spelling: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        for character in spelling {
            if character == "." || character == "_"
                || character.isLetter || character.isNumber {
                token.append(character)
            } else if !token.isEmpty {
                tokens.append(token)
                token.removeAll(keepingCapacity: true)
            }
        }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy {
            $0 == "_" || $0.isLetter || $0.isNumber
        }
    }

    private static func isModulePath(_ value: String) -> Bool {
        !value.isEmpty && value.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).allSatisfy { isSwiftIdentifier(String($0)) }
    }
}
}
