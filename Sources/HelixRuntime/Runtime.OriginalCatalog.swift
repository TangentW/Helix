import Foundation
import HelixBytecode
import HelixCore
import HelixVM

extension Runtime {
public struct OriginalEntry: Sendable {
    public var index: Core.EntryIndex
    public var parameterTypes: [Bytecode.ValueType]
    public var resultType: Bytecode.ValueType
    public var fallbackAllowed: Bool
    public var invoke: @Sendable ([VM.Value]) -> VM.ExecutionResult

    public init(
        index: Core.EntryIndex,
        parameterTypes: [Bytecode.ValueType],
        resultType: Bytecode.ValueType,
        fallbackAllowed: Bool = false,
        invoke: @escaping @Sendable ([VM.Value]) -> VM.ExecutionResult
    ) {
        self.index = index
        self.parameterTypes = parameterTypes
        self.resultType = resultType
        self.fallbackAllowed = fallbackAllowed
        self.invoke = invoke
    }
}

public struct OriginalCatalog: Sendable {
    private let entries: [Core.EntryIndex: Runtime.OriginalEntry]

    public init(_ entries: [Runtime.OriginalEntry]) throws {
        var table: [Core.EntryIndex: Runtime.OriginalEntry] = [:]
        for entry in entries {
            guard table.updateValue(entry, forKey: entry.index) == nil else {
                throw Runtime.ActivationError.invalidGeneration("duplicate original entry \(entry.index)")
            }
        }
        self.entries = table
    }

    public subscript(index: Core.EntryIndex) -> Runtime.OriginalEntry? { entries[index] }
    public var count: Int { entries.count }
    public var indices: [Core.EntryIndex] { entries.keys.sorted() }
}
}
