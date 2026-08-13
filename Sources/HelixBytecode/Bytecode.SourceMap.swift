#if canImport(HelixCore)
import HelixCore
#endif

extension Bytecode.Module {
    /// Returns the verified logical Swift location for one HLBC coordinate.
    public func sourceLocation(
        functionID: Bytecode.FunctionID,
        blockID: Bytecode.BlockID,
        instructionOffset: UInt32
    ) -> Core.SourceLocation? {
        sourceMap.first {
            $0.functionID == functionID
                && $0.blockID == blockID
                && $0.instructionOffset == instructionOffset
        }?.location
    }
}
