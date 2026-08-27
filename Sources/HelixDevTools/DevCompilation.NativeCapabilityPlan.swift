import HelixBuildTools
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixDevProtocol
import HelixInterface

extension DevCompilation {
/// Deterministic development-only promotion of cataloged NativeImports.
///
/// The linked Shell keeps its immutable compact IDs and interface hash. Every
/// non-emitted candidate receives a session-local ID after that frozen prefix,
/// allowing the compiler to lower a first use without generating executable
/// code until the resulting HLBC proves that the call is reachable.
public struct NativeCapabilityPlan: Sendable {
    public private(set) var developmentImports: [
        InterfaceArchive.NativeImportRecord
    ]
    public private(set) var developmentTypes: [InterfaceArchive.TypeRecord]
    public let baselineKeys: Set<Core.NativeCall.Key>
    public let baselineTypeIDs: Set<Core.TypeID>

    public var allKeys: Set<Core.NativeCall.Key> {
        Set(recordsByKey.keys).union(activeImportIDsByKey.keys)
    }

    public var allTypeIDs: Set<Core.TypeID> {
        Set(typesByID.keys).union(activeDevelopmentTypeIDs)
    }

    private var nextImportID: UInt64
    private var recordsByKey: [
        Core.NativeCall.Key: InterfaceArchive.NativeImportRecord
    ]
    private var bindingsByKey: [
        Core.NativeCall.Key: ShellBuildReceipt.NativeImportBinding
    ]
    private var typesByID: [Core.TypeID: InterfaceArchive.TypeRecord]
    private var typeBindingsByID: [
        Core.TypeID: ShellBuildReceipt.NativeTypeBinding
    ]
    private var baselineImportOverlayKeys: Set<Core.NativeCall.Key>
    private var baselineTypeOverlayIDs: Set<Core.TypeID>
    private let activeImportIDsByKey: [
        Core.NativeCall.Key: Core.NativeImportID
    ]
    private let activeDevelopmentTypeIDs: Set<Core.TypeID>
    private let expectedMetadata: InterfaceArchive.ReleaseMetadata
    private let compatibility: Core.Compatibility

    public init(
        archive: InterfaceArchive.Archive,
        receipt: ShellBuildReceipt.Document,
        activeDevelopmentImports: [
            DevProtocol.ActiveDevelopmentNativeImport
        ] = [],
        activeDevelopmentTypeIDs: Set<Core.TypeID> = []
    ) throws {
        try archive.validate()
        try receipt.validate()
        var expectedReceiptMetadata = archive.metadata
        expectedReceiptMetadata.machOUUIDs = []
        // Receipts are canonicalized by stable Key, while HLXI places linked
        // imports in compact-ID order before dormant candidates. Their order
        // intentionally differs; identity is the exact unique record set.
        guard receipt.metadata == expectedReceiptMetadata,
              receipt.compatibility == archive.compatibility,
              receipt.capabilities == archive.capabilities,
              Dictionary(uniqueKeysWithValues: receipt.sources.map {
                  ($0.logicalPath, $0.contentHash)
              }) == Dictionary(uniqueKeysWithValues: archive.sources.map {
                  ($0.logicalPath, $0.contentHash)
              }),
              Set(receipt.nativeImportCandidates) == Set(archive.nativeImports),
              receipt.nativeTypes == archive.nativeTypes,
              receipt.frozenValueTypes == archive.frozenValueTypes
        else {
            throw DevCompilation.NativeCapabilityError.receiptMismatch
        }
        let receiptBindings = Dictionary(
            uniqueKeysWithValues: receipt.nativeImportBindings.map {
                ($0.key, $0)
            }
        )
        guard Set(receiptBindings.keys) == Set(archive.nativeImports.map(\.key))
        else { throw DevCompilation.NativeCapabilityError.receiptMismatch }

        let baseline = archive.nativeImports.filter(\.isEmittedToDevice)
        let baselineIDs = baseline.compactMap(\.id)
        guard baselineIDs.count == baseline.count,
              baselineIDs.sorted().enumerated().allSatisfy({ offset, id in
                  UInt32(exactly: offset) == id.rawValue
              })
        else { throw DevCompilation.NativeCapabilityError.receiptMismatch }

        let dormant = archive.nativeImports
            .filter { !$0.isEmittedToDevice }
            .sorted { $0.key < $1.key }
        var promoted: [InterfaceArchive.NativeImportRecord] = []
        promoted.reserveCapacity(dormant.count)
        for (offset, candidate) in dormant.enumerated() {
            let raw = baseline.count.addingReportingOverflow(offset)
            guard !raw.overflow, let id = UInt32(exactly: raw.partialValue) else {
                throw DevCompilation.NativeCapabilityError.tooManyImports
            }
            var record = candidate
            record.id = .init(rawValue: id)
            record.isEmittedToDevice = true
            promoted.append(record)
        }

        let baselineTypes = archive.nativeTypes.filter(\.isEmittedToDevice)
        let baselineTypeIDs = Set(baselineTypes.map(\.id))
        let promotedTypeIDs = promoted.reduce(into: Set<Core.TypeID>()) {
            result, record in
            record.parameterTypes.forEach {
                result.formUnion($0.referencedNativeTypeIDs)
            }
            result.formUnion(record.resultType.referencedNativeTypeIDs)
        }.subtracting(baselineTypeIDs)
        var archivedTypesByID = Dictionary(
            uniqueKeysWithValues: archive.nativeTypes.map { ($0.id, $0) }
        )
        let promotedTypes = try promotedTypeIDs.sorted {
            $0.rawValue < $1.rawValue
        }.map { id -> InterfaceArchive.TypeRecord in
            guard var record = archivedTypesByID.removeValue(forKey: id) else {
                throw DevCompilation.NativeCapabilityError.receiptMismatch
            }
            record.isEmittedToDevice = true
            return record
        }
        guard Set(activeDevelopmentImports.map(\.key)).count
                == activeDevelopmentImports.count,
              Set(activeDevelopmentImports.map(\.id)).count
                == activeDevelopmentImports.count,
              activeDevelopmentTypeIDs.isDisjoint(with: baselineTypeIDs)
        else { throw DevCompilation.NativeCapabilityError.receiptMismatch }
        let activeImportsByKey = Dictionary(
            uniqueKeysWithValues: activeDevelopmentImports.map {
                ($0.key, $0.id)
            }
        )

        let knownImports = baseline + promoted
        let knownIDs = Set(knownImports.compactMap(\.id))
        let firstDynamicID = UInt64(knownImports.count)
        for active in activeDevelopmentImports {
            guard !baseline.contains(where: { $0.key == active.key }) else {
                throw DevCompilation.NativeCapabilityError.receiptMismatch
            }
            if let known = knownImports.first(where: { $0.key == active.key }) {
                guard known.id == active.id else {
                    throw DevCompilation.NativeCapabilityError.receiptMismatch
                }
            } else {
                guard UInt64(active.id.rawValue) >= firstDynamicID,
                      !knownIDs.contains(active.id)
                else {
                    throw DevCompilation.NativeCapabilityError.receiptMismatch
                }
            }
        }
        let nextID = activeDevelopmentImports.reduce(firstDynamicID) {
            max($0, UInt64($1.id.rawValue) + 1)
        }

        developmentImports = []
        developmentTypes = []
        baselineKeys = Set(baseline.map(\.key))
        self.baselineTypeIDs = baselineTypeIDs
        nextImportID = nextID
        recordsByKey = Dictionary(
            uniqueKeysWithValues: knownImports.map { ($0.key, $0) }
        )
        bindingsByKey = receiptBindings
        typesByID = Dictionary(
            uniqueKeysWithValues: (baselineTypes + promotedTypes).map {
                ($0.id, $0)
            }
        )
        typeBindingsByID = try Self.typeBindings(
            receipt.nativeTypeBindings,
            records: receipt.nativeTypes
        )
        baselineImportOverlayKeys = []
        baselineTypeOverlayIDs = []
        activeImportIDsByKey = activeImportsByKey
        self.activeDevelopmentTypeIDs = activeDevelopmentTypeIDs
        expectedMetadata = expectedReceiptMetadata
        compatibility = archive.compatibility
        refreshDevelopmentSurface()
    }

    /// Adds only native calls proven reachable in the current saved source.
    /// Catalog-only dormant entries remain outside the session until needed.
    @discardableResult
    public mutating func incorporate(
        _ receipt: ShellBuildReceipt.Document
    ) throws -> Bool {
        try receipt.validate()
        var discoveredMetadata = receipt.metadata
        // The resolver observes the saved source transaction, so its baseline
        // hash intentionally differs from the linked Shell. Every immutable
        // process, compiler, target, namespace, and transform field must still
        // match exactly.
        discoveredMetadata.sourceBaselineHash = expectedMetadata
            .sourceBaselineHash
        guard discoveredMetadata == expectedMetadata,
              receipt.compatibility == compatibility
        else { throw DevCompilation.NativeCapabilityError.receiptMismatch }
        let discoveredBindings = Dictionary(
            uniqueKeysWithValues: receipt.nativeImportBindings.map {
                ($0.key, $0)
            }
        )
        let discoveredTypeBindings = try Self.typeBindings(
            receipt.nativeTypeBindings,
            records: receipt.nativeTypes
        )
        let reachable = receipt.nativeImportCandidates.filter(
            \.isEmittedToDevice
        )
        var changed = false
        for discovered in reachable.sorted(by: { $0.key < $1.key }) {
            guard let binding = discoveredBindings[discovered.key] else {
                throw DevCompilation.NativeCapabilityError.missingBinding(
                    discovered.canonicalCallee
                )
            }
            if var existing = recordsByKey[discovered.key] {
                guard existing.descriptor == discovered.descriptor,
                      existing.parameterTypes == discovered.parameterTypes,
                      existing.parameterProjection
                        == discovered.parameterProjection,
                      existing.resultType == discovered.resultType,
                      existing.contract == discovered.contract,
                      existing.capability == discovered.capability,
                      existing.abiAdapter == discovered.abiAdapter,
                      bindingsByKey[discovered.key] == binding
                else {
                    throw DevCompilation.NativeCapabilityError
                        .compilerResultMismatch(discovered.key)
                }
                let symbols = Array(Set(
                    existing.silMangledNames + discovered.silMangledNames
                )).sorted()
                if symbols != existing.silMangledNames {
                    existing.silMangledNames = symbols
                    recordsByKey[existing.key] = existing
                    if baselineKeys.contains(existing.key) {
                        baselineImportOverlayKeys.insert(existing.key)
                    }
                    changed = true
                }
                continue
            }
            var record = discovered
            if let activeID = activeImportIDsByKey[record.key] {
                record.id = activeID
            } else {
                guard nextImportID <= UInt64(UInt32.max) else {
                    throw DevCompilation.NativeCapabilityError.tooManyImports
                }
                record.id = .init(rawValue: UInt32(nextImportID))
                nextImportID += 1
            }
            record.isEmittedToDevice = true
            recordsByKey[record.key] = record
            bindingsByKey[record.key] = binding
            changed = true
        }

        var referencedTypeIDs = reachable.reduce(into: Set<Core.TypeID>()) {
            result, record in
            record.parameterTypes.forEach {
                result.formUnion($0.referencedNativeTypeIDs)
            }
            result.formUnion(record.resultType.referencedNativeTypeIDs)
        }
        // Source analysis can prove a native type reachable without finding a
        // new call (for example `is`, `as?`, or a metatype expression). The
        // development receipt marks only source-reachable types, so include
        // that independent dependency surface in the same transaction.
        referencedTypeIDs.formUnion(
            receipt.nativeTypes.compactMap {
                $0.isEmittedToDevice ? $0.id : nil
            }
        )
        let discoveredTypes = Dictionary(
            uniqueKeysWithValues: receipt.nativeTypes.map { ($0.id, $0) }
        )
        for id in referencedTypeIDs.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            guard var discovered = discoveredTypes[id] else {
                throw DevCompilation.NativeCapabilityError.receiptMismatch
            }
            discovered.isEmittedToDevice = true
            if var existing = typesByID[id] {
                guard existing.canonicalName == discovered.canonicalName,
                      existing.kind == discovered.kind,
                      existing.layoutFingerprint
                        == discovered.layoutFingerprint,
                      existing.objectiveCRuntimeName
                        == discovered.objectiveCRuntimeName,
                      existing.isCopyable == discovered.isCopyable,
                      existing.requiresMainActor
                        == discovered.requiresMainActor,
                      existing.estimatedSize == discovered.estimatedSize
                else {
                    throw DevCompilation.NativeCapabilityError.receiptMismatch
                }
                let aliases = Array(Set(
                    existing.swiftTypeAliases
                        + discovered.swiftTypeAliases
                )).sorted()
                if aliases != existing.swiftTypeAliases {
                    existing.swiftTypeAliases = aliases
                    typesByID[id] = existing
                    if baselineTypeIDs.contains(id) {
                        baselineTypeOverlayIDs.insert(id)
                    }
                    changed = true
                }
                continue
            }
            guard let binding = discoveredTypeBindings[id] else {
                throw DevCompilation.NativeCapabilityError
                    .missingNativeTypeBinding(discovered.canonicalName)
            }
            typesByID[id] = discovered
            typeBindingsByID[id] = binding
            changed = true
        }
        refreshDevelopmentSurface()
        return changed
    }

    public func record(
        for requirement: Bytecode.ImportRequirement
    ) throws -> InterfaceArchive.NativeImportRecord {
        guard let record = recordsByKey[requirement.key],
              record.id == requirement.id,
              record.descriptor == requirement.descriptor,
              record.contract == requirement.contract,
              record.capability == requirement.requiredCapability
        else {
            throw DevCompilation.NativeCapabilityError.compilerResultMismatch(
                requirement.key
            )
        }
        return record
    }

    public func binding(
        for record: InterfaceArchive.NativeImportRecord
    ) throws -> ShellBuildReceipt.NativeImportBinding {
        guard let binding = bindingsByKey[record.key] else {
            throw DevCompilation.NativeCapabilityError.missingBinding(
                record.canonicalCallee
            )
        }
        return binding
    }

    public func typeRecord(
        for id: Core.TypeID
    ) throws -> InterfaceArchive.TypeRecord {
        guard let record = typesByID[id] else {
            throw DevCompilation.NativeCapabilityError
                .missingNativeTypeBinding("\(id)")
        }
        return record
    }

    public func typeBinding(
        for record: InterfaceArchive.TypeRecord
    ) throws -> ShellBuildReceipt.NativeTypeBinding {
        guard let binding = typeBindingsByID[record.id] else {
            throw DevCompilation.NativeCapabilityError
                .missingNativeTypeBinding(record.canonicalName)
        }
        return binding
    }

    private mutating func refreshDevelopmentSurface() {
        developmentImports = recordsByKey.values.filter {
            !baselineKeys.contains($0.key)
                || baselineImportOverlayKeys.contains($0.key)
        }
            .sorted { ($0.id ?? .init(rawValue: .max))
                < ($1.id ?? .init(rawValue: .max)) }
        developmentTypes = typesByID.values.filter { record in
            !baselineTypeIDs.contains(record.id)
                || baselineTypeOverlayIDs.contains(record.id)
        }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func typeBindings(
        _ bindings: [ShellBuildReceipt.NativeTypeBinding],
        records: [InterfaceArchive.TypeRecord]
    ) throws -> [Core.TypeID: ShellBuildReceipt.NativeTypeBinding] {
        var result: [Core.TypeID: ShellBuildReceipt.NativeTypeBinding] = [:]
        for binding in bindings {
            let matches = records.filter {
                $0.canonicalName == binding.canonicalName
                    && $0.layoutFingerprint == binding.layoutFingerprint
                    && $0.requiresMainActor == binding.requiresMainActor
            }
            guard matches.count == 1, let record = matches.first,
                  result.updateValue(binding, forKey: record.id) == nil
            else { throw DevCompilation.NativeCapabilityError.receiptMismatch }
        }
        return result
    }

}

public enum NativeCapabilityError: Swift.Error, Equatable, Sendable,
    CustomStringConvertible
{
    case receiptMismatch
    case tooManyImports
    case compilerResultMismatch(Core.NativeCall.Key)
    case missingBinding(String)
    case missingNativeTypeBinding(String)
    case discoveryFailed(String)
    case unsupportedDevelopmentBinding(String)
    case invalidAdapterRequest
    case deviceAdapterUnqualified
    case adapterCompilationFailed(String)
    case adapterSigningFailed(String)
    case invalidAdapterImage(String)

    public var description: String {
        switch self {
        case .receiptMismatch:
            "Shell Build Receipt does not describe the finalized HLXI candidates"
        case .tooManyImports:
            "development NativeImport catalog exceeds the compact ID space"
        case let .compilerResultMismatch(key):
            "compiled HLBC requested a NativeImport that differs from its cataloged descriptor (\(key))"
        case let .missingBinding(callee):
            "cataloged native API \(callee) has no development binding"
        case let .missingNativeTypeBinding(type):
            "cataloged native type \(type) has no development TypeOps binding"
        case let .discoveryFailed(reason):
            "development native API discovery failed: \(reason)"
        case let .unsupportedDevelopmentBinding(callee):
            "\(callee) needs a development Adapter strategy that this toolchain cannot emit"
        case .invalidAdapterRequest:
            "development Swift Adapter inputs do not match the cataloged NativeImport records"
        case .deviceAdapterUnqualified:
            "on-demand Swift Adapter loading is not qualified for physical iOS devices; use Simulator or rebuild the App"
        case let .adapterCompilationFailed(reason):
            "development Swift Adapter compilation failed: \(reason)"
        case let .adapterSigningFailed(reason):
            "development Swift Adapter signing failed: \(reason)"
        case let .invalidAdapterImage(reason):
            "development Swift Adapter image is invalid: \(reason)"
        }
    }
}
}
