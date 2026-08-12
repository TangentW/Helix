import Foundation

public enum ReleaseLeakage {}

extension ReleaseLeakage {
public struct BinaryImage: Hashable, Sendable {
    public var name: String
    public var bytes: Data

    public init(name: String, bytes: Data) {
        self.name = name
        self.bytes = bytes
    }
}

public struct PropertyList: Hashable, Sendable {
    public var name: String
    public var bytes: Data

    public init(name: String, bytes: Data) {
        self.name = name
        self.bytes = bytes
    }
}

public struct Finding: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Hashable, Sendable {
        case critical
        case warning
    }

    public var severity: Severity
    public var code: String
    public var detail: String

    public init(severity: Severity, code: String, detail: String) {
        self.severity = severity
        self.code = code
        self.detail = detail
    }
}

public struct Report: Codable, Hashable, Sendable {
    public var findings: [ReleaseLeakage.Finding]
    public var passed: Bool {
        !findings.contains { $0.severity == .critical }
    }

    public init(findings: [ReleaseLeakage.Finding]) {
        self.findings = findings
    }

    private enum CodingKeys: String, CodingKey {
        case findings
        case passed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        findings = try container.decode([ReleaseLeakage.Finding].self, forKey: .findings)
        if let encodedPassed = try container.decodeIfPresent(Bool.self, forKey: .passed),
           encodedPassed != passed
        {
            throw DecodingError.dataCorruptedError(
                forKey: .passed,
                in: container,
                debugDescription: "release leakage result contradicts its findings"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(findings, forKey: .findings)
        try container.encode(passed, forKey: .passed)
    }
}

public struct Scanner: Sendable {
    public var forbiddenBinaryMarkers: [String]
    public var forbiddenImageNameFragments: [String]
    public var allowedBusinessBonjourServices: Set<String>

    public init(
        forbiddenBinaryMarkers: [String] = [
            "HelixDevRuntime",
            "HelixDevProtocol",
            "HelixDevTools",
            "HelixLiveReloadAPI",
            "DevActivation.Controller",
            "DevProtocol.LiveArtifact",
            "HLX_DEV_",
            "_helix-live._tcp",
        ],
        forbiddenImageNameFragments: [String] = [
            "HelixDevAppRuntime",
            "HelixDevRuntime",
            "HelixDevProtocol",
            "HelixDevTools",
            "HelixLiveReloadAPI",
        ],
        allowedBusinessBonjourServices: Set<String> = []
    ) {
        self.forbiddenBinaryMarkers = forbiddenBinaryMarkers
        self.forbiddenImageNameFragments = forbiddenImageNameFragments
        self.allowedBusinessBonjourServices = allowedBusinessBonjourServices
    }

    public func scan(
        executable: Data,
        infoPlist: Data?,
        loadedImageNames: [String]
    ) -> ReleaseLeakage.Report {
        scan(
            binaryImages: [.init(name: "main executable", bytes: executable)],
            propertyLists: infoPlist.map { [.init(name: "Info.plist", bytes: $0)] } ?? [],
            loadedImageNames: loadedImageNames
        )
    }

    public func scan(
        binaryImages: [ReleaseLeakage.BinaryImage],
        propertyLists: [ReleaseLeakage.PropertyList],
        loadedImageNames: [String] = []
    ) -> ReleaseLeakage.Report {
        var findings: [ReleaseLeakage.Finding] = []
        for image in binaryImages {
            for marker in forbiddenBinaryMarkers
            where image.bytes.range(of: Data(marker.utf8)) != nil {
                findings.append(
                    .init(
                        severity: .critical,
                        code: "HLXREL001",
                        detail: "\(image.name) contains forbidden Dev marker \(marker)"
                    )
                )
            }
        }
        let imageNames = binaryImages.map(\.name) + loadedImageNames
        for imageName in imageNames {
            for fragment in forbiddenImageNameFragments where imageName.contains(fragment) {
                findings.append(
                    .init(
                        severity: .critical,
                        code: "HLXREL002",
                        detail: "release image links \(imageName)"
                    )
                )
                break
            }
        }
        for propertyList in propertyLists {
            scan(propertyList, findings: &findings)
        }
        return .init(findings: findings)
    }

    private func scan(
        _ propertyList: ReleaseLeakage.PropertyList,
        findings: inout [ReleaseLeakage.Finding]
    ) {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: propertyList.bytes,
                options: [],
                format: nil
            )
        } catch {
            findings.append(
                .init(
                    severity: .critical,
                    code: "HLXREL006",
                    detail: "cannot decode \(propertyList.name): \(error.localizedDescription)"
                )
            )
            return
        }
        guard let dictionary = object as? [String: Any] else {
            findings.append(
                .init(
                    severity: .critical,
                    code: "HLXREL006",
                    detail: "\(propertyList.name) is not a property-list dictionary"
                )
            )
            return
        }
        let services = dictionary["NSBonjourServices"] as? [String] ?? []
        for service in services {
            let normalized = service.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: ".")
            )
            if normalized == "_helix-live._tcp" {
                findings.append(
                    .init(
                        severity: .critical,
                        code: "HLXREL003",
                        detail: "\(propertyList.name) advertises Helix Dev Bonjour service"
                    )
                )
            } else if !allowedBusinessBonjourServices.contains(service) {
                findings.append(
                    .init(
                        severity: .warning,
                        code: "HLXREL004",
                        detail: "\(propertyList.name) has unreviewed business Bonjour service \(service)"
                    )
                )
            }
        }
        if let description = dictionary["NSLocalNetworkUsageDescription"] as? String,
           description.localizedCaseInsensitiveContains("helix")
        {
            findings.append(
                .init(
                    severity: .critical,
                    code: "HLXREL005",
                    detail: "\(propertyList.name) Local Network description references Helix"
                )
            )
        }
    }
}

public enum AuditError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidAppBundle(String)
    case symbolicLink(String)
    case artifactLimit(String)

    public var description: String {
        switch self {
        case let .invalidAppBundle(detail): "invalid release App bundle: \(detail)"
        case let .symbolicLink(path): "release App bundle contains a symbolic link: \(path)"
        case let .artifactLimit(detail): "release App audit limit exceeded: \(detail)"
        }
    }
}

public struct AppBundleAuditor: Sendable {
    public var scanner: ReleaseLeakage.Scanner
    public var maximumBinaryBytes: UInt64
    public var maximumPropertyListBytes: UInt64
    public var maximumArtifactCount: Int

    public init(
        scanner: ReleaseLeakage.Scanner = .init(),
        maximumBinaryBytes: UInt64 = 512 * 1_024 * 1_024,
        maximumPropertyListBytes: UInt64 = 4 * 1_024 * 1_024,
        maximumArtifactCount: Int = 4_096
    ) {
        self.scanner = scanner
        self.maximumBinaryBytes = maximumBinaryBytes
        self.maximumPropertyListBytes = maximumPropertyListBytes
        self.maximumArtifactCount = maximumArtifactCount
    }

    public func audit(appURL: URL) throws -> ReleaseLeakage.Report {
        let root = appURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard root.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ReleaseLeakage.AuditError.invalidAppBundle(root.path)
        }
        if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw ReleaseLeakage.AuditError.symbolicLink(root.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]
        ) else {
            throw ReleaseLeakage.AuditError.invalidAppBundle("cannot enumerate \(root.path)")
        }
        var entries: [(url: URL, name: String, size: Int?)] = []
        while let entry = enumerator.nextObject() as? URL {
            let depth = enumerator.level
            let components = entry.pathComponents.suffix(depth)
            guard depth > 0, components.count == depth else {
                throw ReleaseLeakage.AuditError.invalidAppBundle(
                    "cannot derive the path of \(entry.path)"
                )
            }
            let name = components.joined(separator: "/")
            let values = try entry.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw ReleaseLeakage.AuditError.symbolicLink(name)
            }
            if values.isRegularFile == true {
                entries.append((entry, name, values.fileSize))
            }
        }
        entries.sort { $0.name < $1.name }
        var images: [ReleaseLeakage.BinaryImage] = []
        var propertyLists: [ReleaseLeakage.PropertyList] = []
        for entry in entries {
            if entry.url.lastPathComponent == "Info.plist" {
                let bytes = try boundedRead(
                    entry.url,
                    byteCount: entry.size,
                    maximum: maximumPropertyListBytes
                )
                propertyLists.append(.init(name: entry.name, bytes: bytes))
            } else if try isMachO(entry.url) {
                let bytes = try boundedRead(
                    entry.url,
                    byteCount: entry.size,
                    maximum: maximumBinaryBytes
                )
                images.append(.init(name: entry.name, bytes: bytes))
            }
            if images.count + propertyLists.count > maximumArtifactCount {
                throw ReleaseLeakage.AuditError.artifactLimit(
                    "more than \(maximumArtifactCount) auditable artifacts"
                )
            }
        }
        guard !images.isEmpty else {
            throw ReleaseLeakage.AuditError.invalidAppBundle("no Mach-O image was found")
        }
        guard propertyLists.contains(where: { $0.name == "Info.plist" }) else {
            throw ReleaseLeakage.AuditError.invalidAppBundle("root Info.plist is missing")
        }
        return scanner.scan(binaryImages: images, propertyLists: propertyLists)
    }

    private func boundedRead(
        _ url: URL,
        byteCount: Int?,
        maximum: UInt64
    ) throws -> Data {
        guard let byteCount, byteCount >= 0, UInt64(byteCount) <= maximum else {
            throw ReleaseLeakage.AuditError.artifactLimit(url.path)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func isMachO(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 4) ?? Data()
        guard prefix.count == 4 else { return false }
        let magic = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        switch magic {
        case 0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe,
             0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca:
            return true
        default:
            return false
        }
    }

}
}
