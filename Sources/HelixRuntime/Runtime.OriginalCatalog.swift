import Foundation
#if canImport(HelixCore)
import HelixBytecode
import HelixCore
import HelixVM
#endif

extension Runtime {
/// Original App implementation and ABI shape for one instrumented entry point.
public struct OriginalEntry: Sendable {
    /// Stable entry index assigned by the generated Shell interface.
    public var index: Core.EntryIndex
    /// VM parameter types accepted by the original adapter.
    public var parameterTypes: [Bytecode.ValueType]
    /// Frozen ownership convention for every logical parameter.
    public var parameterConventions: [Bytecode.ParameterConvention]
    /// VM result type returned by the original adapter.
    public var resultType: Bytecode.ValueType
    /// Frozen execution effects of the original implementation.
    public var effects: Core.Effects
    /// Whether safe pre-side-effect patch failures may fall back to this implementation.
    public var fallbackAllowed: Bool
    /// Generated adapter that invokes original App code from VM values.
    public var invoke: @Sendable ([VM.Value]) -> VM.EntryInvocationResult

    /// Creates one generated original implementation entry.
    public init(
        index: Core.EntryIndex,
        parameterTypes: [Bytecode.ValueType],
        parameterConventions: [Bytecode.ParameterConvention]? = nil,
        resultType: Bytecode.ValueType,
        effects: Core.Effects = .init(),
        fallbackAllowed: Bool = false,
        invoke: @escaping @Sendable ([VM.Value]) -> VM.EntryInvocationResult
    ) {
        self.index = index
        self.parameterTypes = parameterTypes
        self.parameterConventions = parameterConventions
            ?? Array(repeating: .owned, count: parameterTypes.count)
        self.resultType = resultType
        self.effects = effects
        self.fallbackAllowed = fallbackAllowed
        self.invoke = invoke
    }
}

/// Immutable table of generated original implementation adapters.
public struct OriginalCatalog: Sendable {
    private let entries: [Core.EntryIndex: Runtime.OriginalEntry]

    /// Creates a catalog and rejects duplicate entry indices.
    public init(_ entries: [Runtime.OriginalEntry]) throws {
        var table: [Core.EntryIndex: Runtime.OriginalEntry] = [:]
        for entry in entries {
            guard entry.parameterConventions.count == entry.parameterTypes.count,
                  entry.parameterConventions.filter({ $0 == .inout }).count <= 1,
                  !(entry.effects.isAsync
                    && entry.parameterConventions.contains(.inout))
            else {
                throw Runtime.ActivationError.invalidGeneration(
                    "original entry \(entry.index) has an invalid writeback signature"
                )
            }
            guard table.updateValue(entry, forKey: entry.index) == nil else {
                throw Runtime.ActivationError.invalidGeneration("duplicate original entry \(entry.index)")
            }
        }
        self.entries = table
    }

    /// Returns the original implementation registered for an entry index.
    public subscript(index: Core.EntryIndex) -> Runtime.OriginalEntry? { entries[index] }
    /// Number of instrumented original implementations.
    public var count: Int { entries.count }
    /// Registered entry indices in deterministic ascending order.
    public var indices: [Core.EntryIndex] { entries.keys.sorted() }
}
}
