import Foundation

extension Verification {
public struct StructuralLimits: Hashable, Sendable {
    public var maximumFunctions: Int
    public var maximumBlocksPerFunction: Int
    public var maximumInstructionsPerFunction: Int
    public var maximumTotalInstructions: Int
    public var maximumEntries: Int
    public var maximumImports: Int
    public var maximumSourceMapEntries: Int
    public var maximumIdentifierUTF8Bytes: Int
    public var maximumSourcePathUTF8Bytes: Int
    public var maximumCapabilities: Int
    public var maximumLocalTypes: Int
    public var maximumLocalTypeMembers: Int
    public var maximumTotalLocalTypeMembers: Int
    public var maximumLocalTypeNestingDepth: Int

    public init(
        maximumFunctions: Int = 16_384,
        maximumBlocksPerFunction: Int = 65_536,
        maximumInstructionsPerFunction: Int = 1_000_000,
        maximumTotalInstructions: Int = 2_000_000,
        maximumEntries: Int = 65_536,
        maximumImports: Int = 65_536,
        maximumSourceMapEntries: Int = 2_000_000,
        maximumIdentifierUTF8Bytes: Int = 1_024,
        maximumSourcePathUTF8Bytes: Int = 4_096,
        maximumCapabilities: Int = 64,
        maximumLocalTypes: Int = 4_096,
        maximumLocalTypeMembers: Int = 1_024,
        maximumTotalLocalTypeMembers: Int = 65_536,
        maximumLocalTypeNestingDepth: Int = 32
    ) {
        precondition(maximumFunctions > 0)
        precondition(maximumBlocksPerFunction > 0)
        precondition(maximumInstructionsPerFunction > 0)
        precondition(maximumTotalInstructions > 0)
        precondition(maximumEntries > 0)
        precondition(maximumImports > 0)
        precondition(maximumSourceMapEntries > 0)
        precondition(maximumIdentifierUTF8Bytes > 0)
        precondition(maximumSourcePathUTF8Bytes > 0)
        precondition(maximumCapabilities > 0)
        precondition(maximumLocalTypes > 0)
        precondition(maximumLocalTypeMembers > 0)
        precondition(maximumTotalLocalTypeMembers > 0)
        precondition(maximumLocalTypeNestingDepth > 0)
        self.maximumFunctions = maximumFunctions
        self.maximumBlocksPerFunction = maximumBlocksPerFunction
        self.maximumInstructionsPerFunction = maximumInstructionsPerFunction
        self.maximumTotalInstructions = maximumTotalInstructions
        self.maximumEntries = maximumEntries
        self.maximumImports = maximumImports
        self.maximumSourceMapEntries = maximumSourceMapEntries
        self.maximumIdentifierUTF8Bytes = maximumIdentifierUTF8Bytes
        self.maximumSourcePathUTF8Bytes = maximumSourcePathUTF8Bytes
        self.maximumCapabilities = maximumCapabilities
        self.maximumLocalTypes = maximumLocalTypes
        self.maximumLocalTypeMembers = maximumLocalTypeMembers
        self.maximumTotalLocalTypeMembers = maximumTotalLocalTypeMembers
        self.maximumLocalTypeNestingDepth = maximumLocalTypeNestingDepth
    }
}
}
