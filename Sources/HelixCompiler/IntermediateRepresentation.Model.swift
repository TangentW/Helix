import Foundation
import HelixBytecode
import HelixCore

public enum IntermediateRepresentation {}

extension IntermediateRepresentation {
public typealias ValueType = Bytecode.ValueType
public typealias Register = Bytecode.Register
public typealias Instruction = Bytecode.Instruction

public struct Block: Hashable, Sendable {
    public var id: Bytecode.BlockID
    public var parameters: [IntermediateRepresentation.Register]
    public var instructions: [IntermediateRepresentation.Instruction]

    public init(id: Bytecode.BlockID, parameters: [IntermediateRepresentation.Register], instructions: [IntermediateRepresentation.Instruction]) {
        self.id = id
        self.parameters = parameters
        self.instructions = instructions
    }
}

public struct Function: Hashable, Sendable {
    public var name: String
    public var kind: Bytecode.FunctionKind
    public var parameterRegisters: [IntermediateRepresentation.Register]
    public var parameterConventions: [Bytecode.ParameterConvention]
    public var resultType: IntermediateRepresentation.ValueType
    public var registerTypes: [IntermediateRepresentation.ValueType]
    public var stackSlotTypes: [IntermediateRepresentation.ValueType]
    public var effects: Core.Effects
    public var entryBlock: Bytecode.BlockID
    public var blocks: [IntermediateRepresentation.Block]
    public var sourceLocation: Core.SourceLocation?

    public init(
        name: String,
        kind: Bytecode.FunctionKind = .ordinary,
        parameterRegisters: [IntermediateRepresentation.Register],
        parameterConventions: [Bytecode.ParameterConvention]? = nil,
        resultType: IntermediateRepresentation.ValueType,
        registerTypes: [IntermediateRepresentation.ValueType],
        entryBlock: Bytecode.BlockID,
        blocks: [IntermediateRepresentation.Block],
        stackSlotTypes: [IntermediateRepresentation.ValueType] = [],
        effects: Core.Effects = .init(),
        sourceLocation: Core.SourceLocation? = nil
    ) {
        self.name = name
        self.kind = kind
        self.parameterRegisters = parameterRegisters
        self.parameterConventions = parameterConventions ?? parameterRegisters.map { register in
            guard registerTypes.indices.contains(Int(register.rawValue)),
                  case .address = registerTypes[Int(register.rawValue)]
            else { return .owned }
            return .inout
        }
        self.resultType = resultType
        self.registerTypes = registerTypes
        self.stackSlotTypes = stackSlotTypes
        self.effects = effects
        self.entryBlock = entryBlock
        self.blocks = blocks
        self.sourceLocation = sourceLocation
    }
}

public enum ToBytecode {
    public static func lower(_ function: IntermediateRepresentation.Function, id: Bytecode.FunctionID) -> Bytecode.Function {
        Bytecode.Function(
            id: id,
            name: function.name,
            kind: function.kind,
            parameterRegisters: function.parameterRegisters,
            parameterConventions: function.parameterConventions,
            resultType: function.resultType,
            registerTypes: function.registerTypes,
            entryBlock: function.entryBlock,
            blocks: function.blocks.map {
                Bytecode.Block(id: $0.id, parameters: $0.parameters, instructions: $0.instructions)
            },
            stackSlotTypes: function.stackSlotTypes,
            effects: function.effects,
            sourceLocation: function.sourceLocation
        )
    }
}
}
