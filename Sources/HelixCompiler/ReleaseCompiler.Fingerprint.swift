import Foundation
import HelixCore

extension ReleaseCompiler {
public struct DeclarationInterface: Codable, Hashable, Sendable {
    public var declarationKind: String
    public var baseName: String
    public var argumentLabels: [String]
    public var accessLevel: String
    public var canonicalFormalType: String
    public var loweredSILType: String
    public var genericSignature: String?
    public var effects: Core.Effects
    public var isolation: String?
    public var availability: [String]
    public var dispatchIdentity: String?

    public init(
        declarationKind: String,
        baseName: String,
        argumentLabels: [String] = [],
        accessLevel: String,
        canonicalFormalType: String,
        loweredSILType: String,
        genericSignature: String? = nil,
        effects: Core.Effects = .init(),
        isolation: String? = nil,
        availability: [String] = [],
        dispatchIdentity: String? = nil
    ) {
        self.declarationKind = declarationKind
        self.baseName = baseName
        self.argumentLabels = argumentLabels
        self.accessLevel = accessLevel
        self.canonicalFormalType = canonicalFormalType
        self.loweredSILType = loweredSILType
        self.genericSignature = genericSignature
        self.effects = effects
        self.isolation = isolation
        self.availability = availability
        self.dispatchIdentity = dispatchIdentity
    }

    public func fingerprint() throws -> Core.Digest {
        var hasher = Core.StableHasher(domain: "HLX.Interface.v1")
        hasher.append(try Core.CanonicalJSON.encode(self))
        return hasher.finalize()
    }
}

public enum Difference: Equatable, Sendable {
    case unchanged
    case bodyChanged(previous: Core.Digest, current: Core.Digest)
    case interfaceChanged(previous: Core.Digest, current: Core.Digest)
}

public struct FunctionSnapshot: Codable, Hashable, Sendable {
    public var key: Core.FunctionKey
    public var interface: ReleaseCompiler.DeclarationInterface
    public var interfaceFingerprint: Core.Digest
    public var bodyFingerprint: Core.Digest

    public init(key: Core.FunctionKey, interface: ReleaseCompiler.DeclarationInterface, canonicalSILBody: String) throws {
        self.key = key
        self.interface = interface
        interfaceFingerprint = try interface.fingerprint()
        bodyFingerprint = ReleaseCompiler.BodyFingerprint.compute(canonicalSILBody)
    }

    public func difference(from baseline: Self) -> ReleaseCompiler.Difference {
        guard interfaceFingerprint == baseline.interfaceFingerprint else {
            return .interfaceChanged(previous: baseline.interfaceFingerprint, current: interfaceFingerprint)
        }
        guard bodyFingerprint == baseline.bodyFingerprint else {
            return .bodyChanged(previous: baseline.bodyFingerprint, current: bodyFingerprint)
        }
        return .unchanged
    }
}

public enum BodyFingerprint {
    public static func compute(_ canonicalSILBody: String) -> Core.Digest {
        var valueMap: [String: String] = [:]
        var blockMap: [String: String] = [:]
        var normalized: [String] = []

        for rawLine in canonicalSILBody.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            line = CanonicalSIL.DebugMetadata.strippingMetadata(from: line)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("debug_value"), !line.hasPrefix("loc ") else { continue }
            line = rewriteTokens(in: line, pattern: #"%[0-9]+"#, map: &valueMap, prefix: "%v")
            line = rewriteTokens(in: line, pattern: #"bb[0-9]+"#, map: &blockMap, prefix: "bb")
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            normalized.append(line)
        }
        var hasher = Core.StableHasher(domain: "HLX.Body.v1")
        hasher.append(normalized.joined(separator: "\n"))
        return hasher.finalize()
    }

    private static func rewriteTokens(
        in input: String,
        pattern: String,
        map: inout [String: String],
        prefix: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        var replacements: [String] = []
        replacements.reserveCapacity(matches.count)
        // Assign canonical numbers in source order. Replacements are applied in
        // reverse only to keep the original ranges valid.
        for match in matches {
            guard let range = Range(match.range, in: input) else {
                replacements.append("")
                continue
            }
            let token = String(input[range])
            if let existing = map[token] {
                replacements.append(existing)
            } else {
                let replacement = "\(prefix)\(map.count)"
                map[token] = replacement
                replacements.append(replacement)
            }
        }
        var output = input
        for (match, replacement) in zip(matches, replacements).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }
}
}
