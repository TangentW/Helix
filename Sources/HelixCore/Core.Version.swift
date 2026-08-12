import Foundation

extension Core {
public struct SemanticVersion: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: UInt16
    public var minor: UInt16
    public var patch: UInt16

    public init(_ major: UInt16, _ minor: UInt16 = 0, _ patch: UInt16 = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(parsing value: String) throws {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (1...3).contains(components.count),
              components.allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
              })
        else {
            throw Core.Error.malformedData("invalid semantic version \(value)")
        }
        let values = try components.map { component -> UInt16 in
            guard let value = UInt16(component) else {
                throw Core.Error.malformedData("semantic version component is out of range")
            }
            return value
        }
        self.init(
            values[0],
            values.count > 1 ? values[1] : 0,
            values.count > 2 ? values[2] : 0
        )
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public struct Compatibility: Codable, Hashable, Sendable {
    public var runtime: Core.SemanticVersion
    public var bytecode: Core.SemanticVersion
    public var interfaceArchive: Core.SemanticVersion
    public var compilerFingerprint: String

    public init(
        runtime: Core.SemanticVersion,
        bytecode: Core.SemanticVersion,
        interfaceArchive: Core.SemanticVersion,
        compilerFingerprint: String
    ) {
        self.runtime = runtime
        self.bytecode = bytecode
        self.interfaceArchive = interfaceArchive
        self.compilerFingerprint = compilerFingerprint
    }

    public func isCompatible(with required: Self) -> Bool {
        runtime.major == required.runtime.major
            && runtime >= required.runtime
            && bytecode.major == required.bytecode.major
            && bytecode >= required.bytecode
            && interfaceArchive.major == required.interfaceArchive.major
            && compilerFingerprint == required.compilerFingerprint
    }
}

public struct ReleaseIdentity: Codable, Hashable, Sendable {
    public var bundleID: String
    public var buildNumber: String
    public var shellNamespaceID: Core.ShellNamespaceID
    public var machOUUIDs: [UUID]
    public var swiftCompilerFingerprint: String
    public var shellInterfaceHash: Core.Digest

    public init(
        bundleID: String,
        buildNumber: String,
        shellNamespaceID: Core.ShellNamespaceID,
        machOUUIDs: [UUID],
        swiftCompilerFingerprint: String,
        shellInterfaceHash: Core.Digest
    ) {
        self.bundleID = bundleID
        self.buildNumber = buildNumber
        self.shellNamespaceID = shellNamespaceID
        self.machOUUIDs = machOUUIDs
        self.swiftCompilerFingerprint = swiftCompilerFingerprint
        self.shellInterfaceHash = shellInterfaceHash
    }
}

public enum Versions {
    public static let runtime = Core.SemanticVersion(0, 1, 0)
    public static let bytecode = Core.SemanticVersion(1, 11, 0)
    public static let interfaceArchive = Core.SemanticVersion(2, 6, 0)
    public static let package = Core.SemanticVersion(1, 0, 0)
}
}
