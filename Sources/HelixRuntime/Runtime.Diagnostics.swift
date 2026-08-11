import HelixCore
import HelixVM

extension Runtime {
/// A Runtime trap enriched with the active generation and logical Swift source.
public struct TrapDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public var generationID: Runtime.GenerationID
    public var entry: Core.EntryIndex
    public var trap: VM.RuntimeTrap
    public var programCounter: VM.ProgramCounter?
    public var functionName: String?
    public var sourceLocation: Core.SourceLocation?

    public init(
        generationID: Runtime.GenerationID,
        entry: Core.EntryIndex,
        trap: VM.RuntimeTrap,
        programCounter: VM.ProgramCounter?,
        functionName: String?,
        sourceLocation: Core.SourceLocation?
    ) {
        self.generationID = generationID
        self.entry = entry
        self.trap = trap
        self.programCounter = programCounter
        self.functionName = functionName
        self.sourceLocation = sourceLocation
    }

    public var description: String {
        let location = sourceLocation.map { " at \($0)" }
            ?? programCounter.map { " at \($0)" }
            ?? ""
        let function = functionName.map { " in \($0)" } ?? ""
        return "generation \(generationID), entry \(entry)\(function)\(location): \(trap)"
    }
}
}

extension Runtime.Observing {
    /// Receives source-enriched trap telemetry. Existing observers remain
    /// source-compatible through this default implementation.
    public func didTrap(diagnostic: Runtime.TrapDiagnostic) {}
}
