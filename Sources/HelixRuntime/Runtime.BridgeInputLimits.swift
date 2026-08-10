import Foundation
import HelixCore

extension Runtime {
/// Host-side limits applied while a generated Shell bridge materializes
/// Swift values as VM values. These limits exist before the VM invocation
/// budget and therefore cap temporary bridge allocations as well.
public struct BridgeInputLimits: Hashable, Sendable {
    public var maximumEstimatedVMBytes: UInt64
    public var maximumEstimatedNativeBytes: UInt64
    public var maximumValueNodes: UInt64
    public var maximumNestingDepth: UInt32
    public var maximumContainerElements: UInt64

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

public enum BridgeInputError: Error, Equatable, Sendable, CustomStringConvertible {
    case encoderAlreadyFinished
    case invalidContainerCount
    case containerElementLimitExceeded(actual: UInt64, maximum: UInt64)
    case valueNodeLimitExceeded(maximum: UInt64)
    case nestingDepthLimitExceeded(maximum: UInt32)
    case estimatedVMByteLimitExceeded(maximum: UInt64)
    case estimatedNativeByteLimitExceeded(maximum: UInt64)
    case encodedTypeMismatch(expected: String, actual: String)
    case untrackedEncodedValue

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
        case .untrackedEncodedValue:
            "Bridge input contains a value not produced by its scoped encoder"
        }
    }
}
}
