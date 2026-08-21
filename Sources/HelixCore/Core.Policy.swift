import Foundation

extension Core {
public struct Capability: RawRepresentable, Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }

    public static let baselineV1: Self = "hlbc-baseline-1"
    public static let stringsV1: Self = "swift-string-1"
    public static let collectionsV1: Self = "swift-collections-1"
    public static let nativeTypesV1: Self = "swift-native-types-1"
    public static let nativeImportsV1: Self = "native-import-1"
    public static let untypedThrowsV1: Self = "untyped-throws-1"
    public static let localNominalsV1: Self = "local-nominals-1"
    public static let structuredErrorsV1: Self = "structured-errors-1"
    public static let addressValuesV1: Self = "address-values-1"
    public static let borrowCallsV1: Self = "borrow-calls-1"
    public static let closureValuesV1: Self = "closure-values-1"
    public static let escapingClosureValuesV1: Self = "escaping-closure-values-1"
    public static let mutableCapturesV1: Self = "mutable-captures-1"
    public static let nonOwningReferencesV1: Self = "non-owning-references-1"
    public static let compilerSpecializationsV1: Self = "compiler-specializations-1"
    public static let mainActorSyncV1: Self = "main-actor-sync-1"
    public static let asyncLeafEntriesV1: Self = "async-leaf-entry-1"
    public static let anyValuesV1: Self = "swift-any-1"
    public static let localClassesV1: Self = "local-classes-1"
    public static let hostedObjectiveCClassesV1: Self = "hosted-objc-classes-1"
}

public struct ResourceLimits: Codable, Hashable, Sendable {
    public var instructionFuelPerEntry: UInt64
    public var maxCallDepth: UInt32
    public var maxFrameRegisters: UInt32
    public var maxVMHeapBytes: UInt64
    public var maxNativeOwnedBytes: UInt64
    public var maxNativeCallsPerEntry: UInt32
    public var maxWallTimeMainThreadMilliseconds: UInt32
    public var maxWallTimeBackgroundMilliseconds: UInt32
    public var maxSuspendedFrames: UInt32

    public init(
        instructionFuelPerEntry: UInt64 = 100_000,
        maxCallDepth: UInt32 = 64,
        maxFrameRegisters: UInt32 = 4_096,
        maxVMHeapBytes: UInt64 = 8 * 1_024 * 1_024,
        maxNativeOwnedBytes: UInt64 = 8 * 1_024 * 1_024,
        maxNativeCallsPerEntry: UInt32 = 1_024,
        maxWallTimeMainThreadMilliseconds: UInt32 = 16,
        maxWallTimeBackgroundMilliseconds: UInt32 = 1_000,
        maxSuspendedFrames: UInt32 = 0
    ) {
        self.instructionFuelPerEntry = instructionFuelPerEntry
        self.maxCallDepth = maxCallDepth
        self.maxFrameRegisters = maxFrameRegisters
        self.maxVMHeapBytes = maxVMHeapBytes
        self.maxNativeOwnedBytes = maxNativeOwnedBytes
        self.maxNativeCallsPerEntry = maxNativeCallsPerEntry
        self.maxWallTimeMainThreadMilliseconds = maxWallTimeMainThreadMilliseconds
        self.maxWallTimeBackgroundMilliseconds = maxWallTimeBackgroundMilliseconds
        self.maxSuspendedFrames = maxSuspendedFrames
    }

    public func constrained(by ceiling: Self) -> Self {
        Self(
            instructionFuelPerEntry: min(instructionFuelPerEntry, ceiling.instructionFuelPerEntry),
            maxCallDepth: min(maxCallDepth, ceiling.maxCallDepth),
            maxFrameRegisters: min(maxFrameRegisters, ceiling.maxFrameRegisters),
            maxVMHeapBytes: min(maxVMHeapBytes, ceiling.maxVMHeapBytes),
            maxNativeOwnedBytes: min(maxNativeOwnedBytes, ceiling.maxNativeOwnedBytes),
            maxNativeCallsPerEntry: min(maxNativeCallsPerEntry, ceiling.maxNativeCallsPerEntry),
            maxWallTimeMainThreadMilliseconds: min(maxWallTimeMainThreadMilliseconds, ceiling.maxWallTimeMainThreadMilliseconds),
            maxWallTimeBackgroundMilliseconds: min(maxWallTimeBackgroundMilliseconds, ceiling.maxWallTimeBackgroundMilliseconds),
            maxSuspendedFrames: min(maxSuspendedFrames, ceiling.maxSuspendedFrames)
        )
    }
}

public enum DistributionPolicy: String, Codable, Hashable, Sendable {
    case appStoreHLBC
    case enterpriseHLBC
    case internalHLBC
    case controlledNative
}

public struct RuntimePolicy: Codable, Hashable, Sendable {
    public var acceptedCapabilities: Set<Core.Capability>
    public var resourceCeiling: Core.ResourceLimits
    public var allowedNativeImports: Set<Core.NativeImportID>
    public var allowMainActorSynchronousEntries: Bool
    public var productionChannelEnabled: Bool

    public init(
        acceptedCapabilities: Set<Core.Capability> = [.baselineV1],
        resourceCeiling: Core.ResourceLimits = .init(),
        allowedNativeImports: Set<Core.NativeImportID> = [],
        allowMainActorSynchronousEntries: Bool = false,
        productionChannelEnabled: Bool = false
    ) {
        self.acceptedCapabilities = acceptedCapabilities
        self.resourceCeiling = resourceCeiling
        self.allowedNativeImports = allowedNativeImports
        self.allowMainActorSynchronousEntries = allowMainActorSynchronousEntries
        self.productionChannelEnabled = productionChannelEnabled
    }
}
}
