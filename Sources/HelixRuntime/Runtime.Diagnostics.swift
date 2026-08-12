import HelixBytecode
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

/// Trap raised by a lifecycle callback on an Objective-C hosted local class.
/// Hosted functions are image roots but not Shell entries, so their telemetry
/// carries the local type and selector instead of inventing an entry index.
public struct HostedTrapDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public var generationID: Runtime.GenerationID
    public var typeKey: Bytecode.LocalTypeKey
    public var selector: String
    public var trap: VM.RuntimeTrap
    public var programCounter: VM.ProgramCounter?
    public var functionName: String?
    public var sourceLocation: Core.SourceLocation?

    public init(
        generationID: Runtime.GenerationID,
        typeKey: Bytecode.LocalTypeKey,
        selector: String,
        trap: VM.RuntimeTrap,
        programCounter: VM.ProgramCounter?,
        functionName: String?,
        sourceLocation: Core.SourceLocation?
    ) {
        self.generationID = generationID
        self.typeKey = typeKey
        self.selector = selector
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
        return "generation \(generationID), hosted \(typeKey).\(selector)"
            + "\(function)\(location): \(trap)"
    }
}
}

extension Runtime.Observing {
    /// Receives source-enriched trap telemetry. Existing observers remain
    /// source-compatible through this default implementation.
    public func didTrap(diagnostic: Runtime.TrapDiagnostic) {}

    /// Receives source-enriched telemetry for a hosted Objective-C callback.
    public func didTrap(hostedDiagnostic: Runtime.HostedTrapDiagnostic) {}
}
