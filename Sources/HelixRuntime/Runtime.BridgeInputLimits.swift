import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension Runtime {
/// Host-side limits applied while a generated Shell bridge materializes
/// Swift values as VM values. These limits exist before the VM invocation
/// budget and therefore cap temporary bridge allocations as well.
public struct BridgeInputLimits: Hashable, Sendable {
    /// Maximum estimated bytes materialized as VM-owned values.
    public var maximumEstimatedVMBytes: UInt64
    /// Maximum estimated bytes retained by boxed native values.
    public var maximumEstimatedNativeBytes: UInt64
    /// Maximum scalar and container nodes in one encoded argument graph.
    public var maximumValueNodes: UInt64
    /// Maximum nesting depth of tuples, optionals, arrays, and dictionaries.
    public var maximumNestingDepth: UInt32
    /// Maximum child count reserved by any one container.
    public var maximumContainerElements: UInt64

    /// Creates bridge materialization limits.
    ///
    /// Limits are further reduced by the active generation's signed resource
    /// quotas before generated bridge code encodes arguments.
    public init(
        maximumEstimatedVMBytes: UInt64 = 8 * 1_024 * 1_024,
        maximumEstimatedNativeBytes: UInt64 = 8 * 1_024 * 1_024,
        maximumValueNodes: UInt64 = 262_144,
        maximumNestingDepth: UInt32 = 64,
        maximumContainerElements: UInt64 = 262_144
    ) {
        precondition(maximumValueNodes > 0)
        precondition(maximumNestingDepth > 0)
        precondition(maximumContainerElements > 0)
        self.maximumEstimatedVMBytes = maximumEstimatedVMBytes
        self.maximumEstimatedNativeBytes = maximumEstimatedNativeBytes
        self.maximumValueNodes = maximumValueNodes
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumContainerElements = maximumContainerElements
    }

    func constrained(by resources: Core.ResourceLimits) -> Self {
        Self(
            maximumEstimatedVMBytes: min(
                maximumEstimatedVMBytes,
                resources.maxVMHeapBytes
            ),
            maximumEstimatedNativeBytes: min(
                maximumEstimatedNativeBytes,
                resources.maxNativeOwnedBytes
            ),
            maximumValueNodes: min(
                maximumValueNodes,
                max(1, resources.instructionFuelPerEntry)
            ),
            maximumNestingDepth: maximumNestingDepth,
            maximumContainerElements: min(
                maximumContainerElements,
                max(1, resources.instructionFuelPerEntry)
            )
        )
    }
}

/// Fail-closed errors raised while generated bridges encode Swift arguments.
public enum BridgeInputError: Error, Equatable, Sendable, CustomStringConvertible {
    /// An encoder was reused after its argument graph was finalized.
    case encoderAlreadyFinished
    /// A declared container size is negative, overflowing, or differs from output.
    case invalidContainerCount
    /// One container exceeds its configured child count.
    case containerElementLimitExceeded(actual: UInt64, maximum: UInt64)
    /// The full argument graph exceeds its configured node count.
    case valueNodeLimitExceeded(maximum: UInt64)
    /// The argument graph exceeds its configured nesting depth.
    case nestingDepthLimitExceeded(maximum: UInt32)
    /// Estimated VM-owned storage exceeds its configured byte ceiling.
    case estimatedVMByteLimitExceeded(maximum: UInt64)
    /// Estimated boxed native storage exceeds its configured byte ceiling.
    case estimatedNativeByteLimitExceeded(maximum: UInt64)
    /// Generated code encoded an element with the wrong VM value type.
    case encodedTypeMismatch(expected: String, actual: String)
    /// A dynamic Swift value cannot be represented by the bounded Any bridge.
    case unsupportedAnyType(String)
    /// Final arguments contain a value not created by the scoped encoder.
    case untrackedEncodedValue

    /// Human-readable bridge input failure detail.
    public var description: String {
        switch self {
        case .encoderAlreadyFinished:
            "Bridge input encoder was used after finalization"
        case .invalidContainerCount:
            "Bridge input container count is invalid"
        case let .containerElementLimitExceeded(actual, maximum):
            "Bridge input container has \(actual) elements; maximum is \(maximum)"
        case let .valueNodeLimitExceeded(maximum):
            "Bridge input exceeds the \(maximum)-node limit"
        case let .nestingDepthLimitExceeded(maximum):
            "Bridge input exceeds the nesting-depth limit of \(maximum)"
        case let .estimatedVMByteLimitExceeded(maximum):
            "Bridge input exceeds the \(maximum)-byte VM-value limit"
        case let .estimatedNativeByteLimitExceeded(maximum):
            "Bridge input exceeds the \(maximum)-byte native-value limit"
        case let .encodedTypeMismatch(expected, actual):
            "Bridge input encoder expected \(expected), got \(actual)"
        case let .unsupportedAnyType(type):
            "Swift Any boundary does not support \(type)"
        case .untrackedEncodedValue:
            "Bridge input contains a value not produced by its scoped encoder"
        }
    }
}
}
