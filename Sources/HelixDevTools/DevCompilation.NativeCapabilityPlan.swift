import HelixBuildTools
import HelixBytecode
import HelixCompiler
import HelixCore
import HelixInterface

extension DevCompilation {
/// Deterministic development-only promotion of cataloged NativeImports.
///
/// The linked Shell keeps its immutable compact IDs and interface hash. Every
/// non-emitted candidate receives a session-local ID after that frozen prefix,
/// allowing the compiler to lower a first use without generating executable
/// code until the resulting HLBC proves that the call is reachable.
public struct NativeCapabilityPlan: Sendable {
    public let developmentImports: [InterfaceArchive.NativeImportRecord]
    public let baselineKeys: Set<Core.NativeCall.Key>

    private let recordsByKey: [
        Core.NativeCall.Key: InterfaceArchive.NativeImportRecord
    ]
    private let bindingsByKey: [
        Core.NativeCall.Key: ShellBuildReceipt.NativeImportBinding
    ]

    public init(
        archive: InterfaceArchive.Archive,
        receipt: ShellBuildReceipt.Document
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

        developmentImports = promoted
        baselineKeys = Set(baseline.map(\.key))
        recordsByKey = Dictionary(
            uniqueKeysWithValues: (baseline + promoted).map { ($0.key, $0) }
        )
        bindingsByKey = receiptBindings
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
}

public enum NativeCapabilityError: Swift.Error, Equatable, Sendable,
    CustomStringConvertible
{
    case receiptMismatch
    case tooManyImports
    case compilerResultMismatch(Core.NativeCall.Key)
    case missingBinding(String)
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
