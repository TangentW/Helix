import HelixBytecode

extension CanonicalSIL {
/// Tracks explicit SIL retain owners as path-sensitive compiler state.
///
/// One retained register may reach mutually exclusive successors and must be
/// consumed independently on each path. Swift's textual block order is not
/// execution order, so incoming states are recorded on CFG edges and checked
/// again when a late predecessor is lowered.
struct RetainFlow {
    typealias State = [String: [Bytecode.Register]]

    var current: State = [:]
    private var incoming: [Bytecode.BlockID: State] = [:]
    private var activated: [Bytecode.BlockID: State] = [:]
    private var terminal: [Bytecode.BlockID: State] = [:]
    private(set) var conflict: String?

    mutating func activate(_ block: Bytecode.BlockID) {
        let state = incoming[block] ?? [:]
        if let previous = activated[block], previous != state {
            recordConflict(
                "retained owner state changes while lowering \(block)"
            )
        }
        activated[block] = state
        current = state
    }

    mutating func recordExit(
        _ instruction: Bytecode.Instruction,
        from block: Bytecode.BlockID
    ) {
        recordExit(instruction, from: block, state: current)
    }

    mutating func recordSyntheticBlock(
        id: Bytecode.BlockID,
        instructions: [Bytecode.Instruction]
    ) {
        // Synthetic HLBC may clean up VM values, but it never creates or
        // consumes an explicit SIL retain token; that path state is forwarded
        // unchanged to its successors.
        let state = incoming[id] ?? [:]
        if let previous = activated[id], previous != state {
            recordConflict(
                "retained owner state changes while lowering synthetic \(id)"
            )
        }
        activated[id] = state
        if let terminator = instructions.last, terminator.isTerminator {
            recordExit(terminator, from: id, state: state)
        }
    }

    var incompleteTerminalTokens: [String] {
        terminal.values.flatMap { state in
            state.flatMap { token, values in
                Array(repeating: token, count: values.count)
            }
        }.sorted()
    }

    private mutating func recordExit(
        _ instruction: Bytecode.Instruction,
        from block: Bytecode.BlockID,
        state: State
    ) {
        for successor in Set(instruction.successorBlocks) {
            record(state, entering: successor, from: block)
        }
        switch instruction {
        case .returnValue, .throwError:
            if !state.isEmpty { terminal[block] = state }
        default:
            break
        }
    }

    private mutating func record(
        _ state: State,
        entering target: Bytecode.BlockID,
        from source: Bytecode.BlockID
    ) {
        if let previous = incoming[target], previous != state {
            recordConflict(
                "retained owners reach \(target) with inconsistent states from \(source)"
            )
            return
        }
        incoming[target] = state
        if let previous = activated[target], previous != state {
            recordConflict(
                "late predecessor \(source) changes retained owners in \(target)"
            )
        }
    }

    private mutating func recordConflict(_ reason: String) {
        if conflict == nil { conflict = reason }
    }
}
}
