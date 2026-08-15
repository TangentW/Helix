import Foundation
import HelixBytecode

extension CanonicalSIL {
/// Performs field-sensitive definite/possible-initialization analysis for SIL
/// local storage independently of whether that storage remains frame-local or
/// is heap-promoted into an escaping closure context.
enum StorageInitialization {
    enum DeallocationMode: Equatable, Sendable {
        case none
        case destroy
        case destroyIfInitialized
    }

    struct Plan: Equatable, Sendable {
        var mutableCapturePointees: [String: Bytecode.ValueType]
        var storeModes: [Int: Bytecode.StackStoreMode]
        var conditionalDestroyLines: Set<Int>
        var runtimeStorageRoots: Set<String>
        var consumingApplicationArguments: [Int: Set<String>]
        var deallocationModes: [Int: DeallocationMode]

        static let empty = Self(
            mutableCapturePointees: [:],
            storeModes: [:],
            conditionalDestroyLines: [],
            runtimeStorageRoots: [],
            consumingApplicationArguments: [:],
            deallocationModes: [:]
        )

        func storeMode(
            at line: Int
        ) -> Bytecode.StackStoreMode {
            storeModes[line] ?? .assign
        }

        func consumesApplicationArgument(
            _ token: String,
            at line: Int
        ) -> Bool {
            consumingApplicationArguments[line]?.contains(token) == true
        }

        func deallocationMode(at line: Int) -> DeallocationMode {
            deallocationModes[line] ?? .none
        }
    }

    private struct AddressTarget: Equatable, Sendable {
        var root: String
        var path: [UInt32]
    }

    private enum InitializationAction: Equatable, Sendable {
        case allocate(root: String)
        case write(target: AddressTarget, line: Int)
        case take(target: AddressTarget, line: Int)
        case destroy(target: AddressTarget, line: Int)
        case deallocate(target: AddressTarget, line: Int)
    }

    private struct InitializationBlock: Equatable, Sendable {
        var id: UInt32
        var actions: [InitializationAction]
        var successors: Set<UInt32>
        var edgeActions: [UInt32: [InitializationAction]]
    }

    private struct InitializationEdge: Hashable, Sendable {
        var source: UInt32
        var target: UInt32
    }

    private struct ApplicationStorageEffects: Sendable {
        var takenArguments: [String]
        var initializedResults: [EdgeResult]

        struct EdgeResult: Sendable {
            var address: String
            var successor: UInt32?
        }
    }

    /// Proves which SIL writes initialize type-resolvable local stack storage
    /// and separately identifies roots that escape through a mutable closure
    /// capture. The initialization dataflow is deliberately type-shaped:
    /// tuple and local-struct fields may be initialized independently on
    /// multiple branches, while later writes to the same projection assign.
    static func analyze(
        body: String,
        directCalls: CanonicalSIL.DirectCallTable,
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> Plan {
        let lines = body.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map {
            CanonicalSIL.DebugMetadata.strippingComment(from: String($0))
                .trimmingCharacters(in: .whitespaces)
        }
        var allocations = Set<String>()
        var storagePointees: [String: Bytecode.ValueType] = [:]
        var addressAliases: [String: String] = [:]
        var bindingByValue: [String: CanonicalSIL.DirectCallBinding] = [:]
        var pointees: [String: Bytecode.ValueType] = [:]

        func root(of token: String) -> String {
            var current = token
            var visited = Set<String>()
            while let next = addressAliases[current],
                  visited.insert(current).inserted {
                current = next
            }
            return current
        }

        for line in lines {
            guard !line.isEmpty else { continue }

            if line.contains(" = alloc_stack"),
               let value = silResultValue(in: line) {
                allocations.insert(value)
                if let rawType = stackAllocationType(in: line),
                   let type = try? typeEnvironment.resolve(rawType) {
                    storagePointees[value] = type
                }
                continue
            }
            if line.contains("function_ref @"),
               let value = silResultValue(in: line),
               let symbol = functionReferenceSymbol(in: line),
               let binding = directCalls.binding(for: symbol) {
                bindingByValue[value] = binding
                continue
            }
            for marker in [
                " = begin_borrow ",
                " = copy_value ",
                " = move_value ",
                " = mark_uninitialized ",
            ] {
                guard line.contains(marker),
                      let destination = silResultValue(in: line),
                      let source = silValue(after: marker, in: line)
                else { continue }
                if let binding = bindingByValue[source] {
                    bindingByValue[destination] = binding
                }
                if allocations.contains(root(of: source)) {
                    addressAliases[destination] = root(of: source)
                }
            }
            if line.contains(" = begin_access "),
               let destination = silResultValue(in: line),
               let source = silValue(after: " = begin_access ", in: line) {
                addressAliases[destination] = root(of: source)
                continue
            }
            guard let application = partialApply(in: line),
                  let binding = bindingByValue[application.callee]
            else { continue }
            guard application.captures.count <= binding.parameterTypes.count else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "partial_apply captures more values than its callee accepts"
                )
            }
            let captureTypes = binding.parameterTypes.suffix(
                application.captures.count
            )
            for (capture, type) in zip(application.captures, captureTypes) {
                guard case let .mutableCell(pointee) = type else { continue }
                let allocation = root(of: capture)
                guard allocations.contains(allocation) else { continue }
                if let existing = pointees[allocation], existing != pointee {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "one local storage is captured with inconsistent pointee types"
                    )
                }
                pointees[allocation] = pointee
            }
        }
        for (root, pointee) in pointees {
            if let storageType = storagePointees[root], storageType != pointee {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "planned local storage does not match its local storage type"
                )
            }
            storagePointees[root] = pointee
        }
        var applicationEffects: [Int: ApplicationStorageEffects] = [:]
        for (line, text) in lines.enumerated() {
            if let effects = try applicationStorageEffects(in: text) {
                applicationEffects[line] = effects
            }
        }
        let consumingApplicationArguments = applicationEffects.mapValues {
            Set($0.takenArguments)
        }.filter { !$0.value.isEmpty }
        guard !storagePointees.isEmpty else {
            var plan = Plan.empty
            plan.consumingApplicationArguments = consumingApplicationArguments
            return plan
        }

        let targets = try addressTargets(
            lines: lines,
            pointees: storagePointees,
            typeEnvironment: typeEnvironment
        )
        let blocks = try initializationBlocks(
            lines: lines,
            pointees: storagePointees,
            targets: targets,
            applicationEffects: applicationEffects
        )
        guard Set(blocks.map(\.id)).count == blocks.count else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "local-storage CFG contains duplicate basic-block identifiers"
            )
        }
        let classification = try classifyActions(
            blocks: blocks,
            pointees: storagePointees,
            typeEnvironment: typeEnvironment
        )
        return .init(
            mutableCapturePointees: pointees,
            storeModes: classification.storeModes,
            conditionalDestroyLines: classification.conditionalDestroyLines,
            runtimeStorageRoots: runtimeStorageRoots(
                in: blocks,
                pointees: storagePointees,
                conditionalDestroyLines: classification.conditionalDestroyLines,
                deallocationModes: classification.deallocationModes
            ),
            consumingApplicationArguments: consumingApplicationArguments,
            deallocationModes: classification.deallocationModes
        )
    }

    /// Compiler-only addresses can carry a single SSA value, but they cannot
    /// faithfully represent storage whose write/destroy lifetime spans basic
    /// blocks or repeats in a control-flow cycle. Promote those roots to typed
    /// VM stack storage so dynamic initialization remains verifier-checkable.
    private static func runtimeStorageRoots(
        in blocks: [InitializationBlock],
        pointees: [String: Bytecode.ValueType],
        conditionalDestroyLines: Set<Int>,
        deallocationModes: [Int: DeallocationMode]
    ) -> Set<String> {
        let cyclicBlocks = cyclicBlockIDs(in: blocks)
        var blocksByRoot: [String: Set<UInt32>] = [:]
        var conditionallyDeallocatedRoots = Set<String>()
        func record(
            _ actions: [InitializationAction],
            in blockID: UInt32
        ) {
            for action in actions {
                let target: AddressTarget
                switch action {
                case .allocate:
                    continue
                case let .deallocate(value, line):
                    // `dealloc_stack` releases storage, not its Swift value.
                    // It closes ownership only for VM-linear representations
                    // whose imported SIL value can itself be ABI-trivial.
                    guard pointees[value.root]?.requiresLinearOwnership == true,
                          let mode = deallocationModes[line],
                          mode != .none
                    else {
                        continue
                    }
                    if conditionalDestroyLines.contains(line) {
                        conditionallyDeallocatedRoots.insert(value.root)
                    }
                    target = value
                case let .write(value, _), let .take(value, _),
                     let .destroy(value, _):
                    target = value
                }
                blocksByRoot[target.root, default: []].insert(blockID)
            }
        }
        for block in blocks {
            record(block.actions, in: block.id)
            // A conditional SIL operation materializes its destination only
            // after entering the successful successor. Attribute that write
            // to the successor so compiler-address transport remains valid;
            // later uses in other blocks still trigger runtime promotion.
            for (successor, actions) in block.edgeActions {
                record(actions, in: successor)
            }
        }
        return Set(blocksByRoot.compactMap { root, blocks in
            blocks.count > 1
                || !blocks.isDisjoint(with: cyclicBlocks)
                || conditionallyDeallocatedRoots.contains(root)
                ? root
                : nil
        })
    }

    /// A strongly connected component is cyclic when it contains multiple
    /// blocks or its sole block has a self-edge. Tarjan's linear-time walk
    /// keeps this decision independent of block numbering and layout order.
    private static func cyclicBlockIDs(
        in blocks: [InitializationBlock]
    ) -> Set<UInt32> {
        struct WalkFrame {
            var blockID: UInt32
            var successors: [UInt32]
            var nextSuccessor: Int
            var parent: UInt32?
        }

        let blockByID = Dictionary(
            uniqueKeysWithValues: blocks.map { ($0.id, $0) }
        )
        var nextIndex = 0
        var indices: [UInt32: Int] = [:]
        var lowLinks: [UInt32: Int] = [:]
        var componentStack: [UInt32] = []
        var stacked = Set<UInt32>()
        var result = Set<UInt32>()

        func begin(_ blockID: UInt32, parent: UInt32?) -> WalkFrame {
            let index = nextIndex
            nextIndex += 1
            indices[blockID] = index
            lowLinks[blockID] = index
            componentStack.append(blockID)
            stacked.insert(blockID)
            return .init(
                blockID: blockID,
                successors: (blockByID[blockID]?.successors ?? [])
                    .filter { blockByID[$0] != nil }
                    .sorted(),
                nextSuccessor: 0,
                parent: parent
            )
        }

        for block in blocks where indices[block.id] == nil {
            var walk = [begin(block.id, parent: nil)]
            while !walk.isEmpty {
                let frameIndex = walk.index(before: walk.endIndex)
                let blockID = walk[frameIndex].blockID
                if walk[frameIndex].nextSuccessor
                    < walk[frameIndex].successors.count {
                    let successor = walk[frameIndex].successors[
                        walk[frameIndex].nextSuccessor
                    ]
                    walk[frameIndex].nextSuccessor += 1
                    if indices[successor] == nil {
                        walk.append(begin(successor, parent: blockID))
                    } else if stacked.contains(successor) {
                        lowLinks[blockID] = min(
                            lowLinks[blockID] ?? nextIndex,
                            indices[successor] ?? nextIndex
                        )
                    }
                    continue
                }

                let completed = walk.removeLast()
                if let parent = completed.parent {
                    lowLinks[parent] = min(
                        lowLinks[parent] ?? nextIndex,
                        lowLinks[completed.blockID] ?? nextIndex
                    )
                }
                guard lowLinks[completed.blockID]
                        == indices[completed.blockID]
                else { continue }
                var component: [UInt32] = []
                while let member = componentStack.popLast() {
                    stacked.remove(member)
                    component.append(member)
                    if member == completed.blockID { break }
                }
                if component.count > 1
                    || blockByID[completed.blockID]?.successors.contains(
                        completed.blockID
                    ) == true {
                    result.formUnion(component)
                }
            }
        }
        return result
    }

    private static func addressTargets(
        lines: [String],
        pointees: [String: Bytecode.ValueType],
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> [String: AddressTarget] {
        var result = Dictionary(
            uniqueKeysWithValues: pointees.keys.map {
                ($0, AddressTarget(root: $0, path: []))
            }
        )

        for line in lines where !line.isEmpty {
            guard let destination = silResultValue(in: line) else { continue }
            for marker in [
                " = begin_access ",
                " = begin_borrow ",
                " = copy_value ",
                " = move_value ",
                " = mark_uninitialized ",
                " = project_box ",
                " = init_existential_addr ",
                " = init_enum_data_addr ",
                " = unchecked_enum_data_addr ",
                " = unchecked_take_enum_data_addr ",
                " = open_existential_addr ",
            ] {
                guard line.contains(marker),
                      let source = silValue(after: marker, in: line),
                      let target = result[source]
                else { continue }
                result[destination] = target
                break
            }

            if line.contains(" = tuple_element_addr "),
               let source = silValue(
                after: " = tuple_element_addr ",
                in: line
               ), let parent = result[source],
               let index = fieldIndex(
                after: " = tuple_element_addr ",
                in: line
               ),
               let aggregate = pointees[parent.root],
               try childType(
                of: aggregate,
                at: parent.path + [index],
                typeEnvironment: typeEnvironment
               ) != nil {
                result[destination] = .init(
                    root: parent.root,
                    path: parent.path + [index]
                )
                continue
            }

            if line.contains(" = struct_element_addr "),
               let source = silValue(
                after: " = struct_element_addr ",
                in: line
               ), let parent = result[source],
               let field = structFieldName(in: line),
               let aggregate = pointees[parent.root],
               let parentType = try childType(
                of: aggregate,
                at: parent.path,
                typeEnvironment: typeEnvironment
               ) {
                if field == "_value", try childTypes(
                    of: parentType,
                    typeEnvironment: typeEnvironment
                ) == nil {
                    result[destination] = parent
                    continue
                }
                guard case let .local(key) = parentType,
                      let index = try typeEnvironment.structFields(for: key)
                        .firstIndex(where: { $0.name == field }),
                      let rawIndex = UInt32(exactly: index)
                else { continue }
                result[destination] = .init(
                    root: parent.root,
                    path: parent.path + [rawIndex]
                )
            }
        }
        return result
    }

    private static func initializationBlocks(
        lines: [String],
        pointees: [String: Bytecode.ValueType],
        targets: [String: AddressTarget],
        applicationEffects: [Int: ApplicationStorageEffects]
    ) throws -> [InitializationBlock] {
        var result: [InitializationBlock] = []
        var current: InitializationBlock?

        func finishCurrent() {
            if let current { result.append(current) }
            current = nil
        }

        for (lineIndex, line) in lines.enumerated() {
            if let block = blockNumber(in: line) {
                finishCurrent()
                current = .init(
                    id: block,
                    actions: [],
                    successors: [],
                    edgeActions: [:]
                )
                continue
            }
            guard current != nil else { continue }
            if line.contains(" = alloc_stack"),
               let allocation = silResultValue(in: line),
               pointees[allocation] != nil {
                current?.actions.append(.allocate(root: allocation))
            }
            if let source = takenAddress(in: line),
               let target = targets[source] {
                current?.actions.append(
                    .take(target: target, line: lineIndex)
                )
            }
            if let destination = writtenAddress(in: line),
               let target = targets[destination] {
                current?.actions.append(
                    .write(target: target, line: lineIndex)
                )
            }
            if let destination = destroyedAddress(in: line),
               let target = targets[destination] {
                current?.actions.append(
                    .destroy(target: target, line: lineIndex)
                )
            }
            if let destination = deallocatedAddress(in: line),
               let target = targets[destination] {
                current?.actions.append(
                    .deallocate(target: target, line: lineIndex)
                )
            }
            if let effects = applicationEffects[lineIndex] {
                for address in effects.takenArguments {
                    guard let target = targets[address] else { continue }
                    current?.actions.append(
                        .take(target: target, line: lineIndex)
                    )
                }
                for initialized in effects.initializedResults {
                    guard let target = targets[initialized.address] else {
                        continue
                    }
                    let action = InitializationAction.write(
                        target: target,
                        line: lineIndex
                    )
                    if let successor = initialized.successor {
                        current?.edgeActions[successor, default: []]
                            .append(action)
                    } else {
                        current?.actions.append(action)
                    }
                }
            }
            if line.hasPrefix("checked_cast_addr_br "),
               let branches = captures(
                line,
                pattern: #", bb([0-9]+), bb([0-9]+)$"#
               ), let success = UInt32(branches[0]) {
                let values = silValues(in: line)
                if values.count >= 2, let target = targets[values[1]] {
                    current?.edgeActions[success, default: []].append(
                        .write(target: target, line: lineIndex)
                    )
                }
                if line.hasPrefix("checked_cast_addr_br take_always "),
                   let source = values.first,
                   let target = targets[source] {
                    current?.actions.append(
                        .take(target: target, line: lineIndex)
                    )
                }
            }
            if line.hasPrefix("unconditional_checked_cast_addr "),
               let destination = silValues(in: line).last,
               let target = targets[destination] {
                current?.actions.append(
                    .write(target: target, line: lineIndex)
                )
            }
            current?.successors.formUnion(blockReferences(in: line))
        }
        finishCurrent()
        return result
    }

    private struct LeafState: Equatable, Sendable {
        var definitelyInitialized: Set<[UInt32]>
        var possiblyInitialized: Set<[UInt32]>
    }

    private static func classifyActions(
        blocks: [InitializationBlock],
        pointees: [String: Bytecode.ValueType],
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> (
        storeModes: [Int: Bytecode.StackStoreMode],
        conditionalDestroyLines: Set<Int>,
        deallocationModes: [Int: DeallocationMode]
    ) {
        guard let entry = blocks.first?.id else { return ([:], [], [:]) }
        let fullLeaves = try pointees.mapValues {
            try leafPaths(of: $0, typeEnvironment: typeEnvironment)
        }
        typealias State = [String: LeafState]
        let empty = Dictionary(
            uniqueKeysWithValues: pointees.keys.map {
                (
                    $0,
                    LeafState(
                        definitelyInitialized: [],
                        possiblyInitialized: []
                    )
                )
            }
        )
        let blockByID = Dictionary(
            uniqueKeysWithValues: blocks.map { ($0.id, $0) }
        )
        var predecessors: [UInt32: Set<UInt32>] = [:]
        for block in blocks {
            for successor in block.successors where blockByID[successor] != nil {
                predecessors[successor, default: []].insert(block.id)
            }
        }

        func leaves(
            for target: AddressTarget
        ) -> Set<[UInt32]> {
            Set((fullLeaves[target.root] ?? []).filter {
                $0.starts(with: target.path)
            })
        }

        func transfer(
            _ actions: [InitializationAction],
            from state: State
        ) -> State {
            var result = state
            for action in actions {
                switch action {
                case let .allocate(root):
                    result[root] = .init(
                        definitelyInitialized: [],
                        possiblyInitialized: []
                    )
                case let .write(target, _):
                    let targetLeaves = leaves(for: target)
                    result[target.root, default: .init(
                        definitelyInitialized: [],
                        possiblyInitialized: []
                    )].definitelyInitialized.formUnion(targetLeaves)
                    result[target.root, default: .init(
                        definitelyInitialized: [],
                        possiblyInitialized: []
                    )].possiblyInitialized.formUnion(targetLeaves)
                case let .take(target, _), let .destroy(target, _):
                    let targetLeaves = leaves(for: target)
                    result[target.root]?.definitelyInitialized
                        .subtract(targetLeaves)
                    result[target.root]?.possiblyInitialized
                        .subtract(targetLeaves)
                case let .deallocate(target, _):
                    let targetLeaves = leaves(for: target)
                    result[target.root]?.definitelyInitialized
                        .subtract(targetLeaves)
                    result[target.root]?.possiblyInitialized
                        .subtract(targetLeaves)
                }
            }
            return result
        }

        func merge(_ lhs: State, _ rhs: State) -> State {
            var result = lhs
            for root in pointees.keys {
                let left = lhs[root] ?? .init(
                    definitelyInitialized: [],
                    possiblyInitialized: []
                )
                let right = rhs[root] ?? .init(
                    definitelyInitialized: [],
                    possiblyInitialized: []
                )
                result[root] = .init(
                    definitelyInitialized: left.definitelyInitialized
                        .intersection(right.definitelyInitialized),
                    possiblyInitialized: left.possiblyInitialized
                        .union(right.possiblyInitialized)
                )
            }
            return result
        }

        var incoming: [UInt32: State] = [entry: empty]
        var outgoing: [InitializationEdge: State] = [:]
        var worklist = [entry]
        var queued: Set<UInt32> = [entry]
        while let blockID = worklist.popLast() {
            queued.remove(blockID)
            guard let block = blockByID[blockID],
                  let blockInput = incoming[blockID]
            else { continue }
            let blockOutput = transfer(block.actions, from: blockInput)
            for successor in block.successors where blockByID[successor] != nil {
                let edge = InitializationEdge(
                    source: blockID,
                    target: successor
                )
                let edgeOutput = transfer(
                    block.edgeActions[successor] ?? [],
                    from: blockOutput
                )
                guard outgoing[edge] != edgeOutput else { continue }
                outgoing[edge] = edgeOutput
                let edgeStates = (predecessors[successor] ?? []).compactMap {
                    outgoing[
                        InitializationEdge(source: $0, target: successor)
                    ]
                }
                guard var next = edgeStates.first else { continue }
                for state in edgeStates.dropFirst() {
                    next = merge(next, state)
                }
                guard incoming[successor] != next else { continue }
                incoming[successor] = next
                if queued.insert(successor).inserted {
                    worklist.append(successor)
                }
            }
        }

        var storeModes: [Int: Bytecode.StackStoreMode] = [:]
        var conditionalDestroyLines = Set<Int>()
        var deallocationModes: [Int: DeallocationMode] = [:]

        func classify(
            _ action: InitializationAction,
            state: inout State,
            recordsStoreMode: Bool = true
        ) throws {
            switch action {
            case let .allocate(root):
                state[root] = .init(
                    definitelyInitialized: [],
                    possiblyInitialized: []
                )
            case let .write(target, line):
                let targetLeaves = leaves(for: target)
                guard !targetLeaves.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local storage write has no valid aggregate field"
                    )
                }
                let current = state[target.root] ?? .init(
                    definitelyInitialized: [],
                    possiblyInitialized: []
                )
                let mode: Bytecode.StackStoreMode
                if targetLeaves.isSubset(
                    of: current.definitelyInitialized
                ) {
                    mode = .assign
                } else if targetLeaves.isDisjoint(
                    with: current.possiblyInitialized
                ) {
                    mode = .initialize
                } else {
                    mode = .replace
                }
                if recordsStoreMode {
                    guard storeModes.updateValue(mode, forKey: line) == nil else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "one SIL line writes multiple analyzed storage roots"
                        )
                    }
                }
                state[target.root, default: .init(
                    definitelyInitialized: [],
                    possiblyInitialized: []
                )].definitelyInitialized.formUnion(targetLeaves)
                state[target.root, default: .init(
                    definitelyInitialized: [],
                    possiblyInitialized: []
                )].possiblyInitialized.formUnion(targetLeaves)
            case let .take(target, _):
                let targetLeaves = leaves(for: target)
                guard !targetLeaves.isEmpty,
                      targetLeaves.isSubset(
                        of: state[target.root]?.definitelyInitialized ?? []
                      )
                else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local storage is taken before initialization"
                    )
                }
                state[target.root]?.definitelyInitialized
                    .subtract(targetLeaves)
                state[target.root]?.possiblyInitialized
                    .subtract(targetLeaves)
            case let .destroy(target, line):
                let targetLeaves = leaves(for: target)
                guard !targetLeaves.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local storage destroy has no valid aggregate field"
                    )
                }
                let current = state[target.root] ?? .init(
                    definitelyInitialized: [],
                    possiblyInitialized: []
                )
                if !targetLeaves.isSubset(
                    of: current.definitelyInitialized
                ) {
                    guard !targetLeaves.isDisjoint(
                        with: current.possiblyInitialized
                    ) else {
                        throw CanonicalSIL.LoweringError.malformedSIL(
                            "local storage is destroyed before initialization"
                        )
                    }
                    conditionalDestroyLines.insert(line)
                }
                state[target.root]?.definitelyInitialized
                    .subtract(targetLeaves)
                state[target.root]?.possiblyInitialized
                    .subtract(targetLeaves)
            case let .deallocate(target, line):
                let targetLeaves = leaves(for: target)
                guard !targetLeaves.isEmpty else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "local storage deallocation has no valid aggregate field"
                    )
                }
                let current = state[target.root] ?? .init(
                    definitelyInitialized: [],
                    possiblyInitialized: []
                )
                let mode: DeallocationMode
                if targetLeaves.isSubset(of: current.definitelyInitialized) {
                    mode = .destroy
                } else if targetLeaves.isDisjoint(
                    with: current.possiblyInitialized
                ) {
                    mode = .none
                } else {
                    mode = .destroyIfInitialized
                    conditionalDestroyLines.insert(line)
                }
                guard deallocationModes.updateValue(mode, forKey: line) == nil else {
                    throw CanonicalSIL.LoweringError.malformedSIL(
                        "one SIL line deallocates multiple analyzed storage roots"
                    )
                }
                state[target.root]?.definitelyInitialized
                    .subtract(targetLeaves)
                state[target.root]?.possiblyInitialized
                    .subtract(targetLeaves)
            }
        }

        for block in blocks {
            guard var state = incoming[block.id] else { continue }
            for action in block.actions {
                try classify(action, state: &state)
            }
            for successor in block.edgeActions.keys.sorted() {
                var edgeState = state
                for action in block.edgeActions[successor] ?? [] {
                    try classify(
                        action,
                        state: &edgeState,
                        recordsStoreMode: false
                    )
                }
            }
        }
        return (storeModes, conditionalDestroyLines, deallocationModes)
    }

    private static func childType(
        of root: Bytecode.ValueType,
        at path: [UInt32],
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> Bytecode.ValueType? {
        var current = root
        for field in path {
            guard let index = Int(exactly: field),
                  let children = try childTypes(
                    of: current,
                    typeEnvironment: typeEnvironment
                  ), children.indices.contains(index)
            else { return nil }
            current = children[index]
        }
        return current
    }

    private static func childTypes(
        of type: Bytecode.ValueType,
        typeEnvironment: CanonicalSIL.TypeEnvironment
    ) throws -> [Bytecode.ValueType]? {
        switch type {
        case let .tuple(elements):
            elements
        case let .local(key):
            switch try typeEnvironment.definition(for: key).kind {
            case let .structure(fields): fields.map(\.type)
            case .enumeration, .class: nil
            }
        default:
            nil
        }
    }

    private static func leafPaths(
        of type: Bytecode.ValueType,
        typeEnvironment: CanonicalSIL.TypeEnvironment,
        path: [UInt32] = [],
        depth: Int = 0,
        visiting: Set<Bytecode.LocalTypeKey> = []
    ) throws -> Set<[UInt32]> {
        guard depth <= 32 else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "local storage aggregate nesting exceeds 32 levels"
            )
        }
        let children: [Bytecode.ValueType]?
        var nextVisiting = visiting
        if case let .local(key) = type {
            guard !visiting.contains(key) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "local storage aggregate contains a recursive value type"
                )
            }
            switch try typeEnvironment.definition(for: key).kind {
            case let .structure(fields):
                nextVisiting.insert(key)
                children = fields.map(\.type)
            case .enumeration, .class:
                children = nil
            }
        } else {
            children = try childTypes(
                of: type,
                typeEnvironment: typeEnvironment
            )
        }
        guard let children, !children.isEmpty else { return [path] }

        var result = Set<[UInt32]>()
        for (index, child) in children.enumerated() {
            guard let field = UInt32(exactly: index) else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "local storage aggregate field count exceeds UInt32"
                )
            }
            result.formUnion(
                try leafPaths(
                    of: child,
                    typeEnvironment: typeEnvironment,
                    path: path + [field],
                    depth: depth + 1,
                    visiting: nextVisiting
                )
            )
        }
        return result
    }

    private static func writtenAddress(in line: String) -> String? {
        let writesAddress = line.hasPrefix("store ")
            || line.hasPrefix("assign ")
            || line.hasPrefix("copy_addr")
        if writesAddress { return silValues(in: line).last }
        if line.hasPrefix("inject_enum_addr ") {
            return silValues(in: line).first
        }
        return nil
    }

    /// Derives address lifetime effects from the physical SIL function type,
    /// rather than from a catalog of particular Swift APIs. `@in` arguments
    /// are consumed on both return paths, while an `@out` result initializes
    /// immediately for `apply` and only on the normal edge for `try_apply`.
    private static func applicationStorageEffects(
        in line: String
    ) throws -> ApplicationStorageEffects? {
        let argumentsText: String
        let functionType: String
        let normalSuccessor: UInt32?
        let errorSuccessor: UInt32?
        if let call = captures(
            line,
            pattern: #"^try_apply %[0-9]+(?:<.*>)?\((.*)\) : \$(.+), normal bb([0-9]+), error bb([0-9]+)$"#
        ) {
            argumentsText = call[0]
            functionType = call[1]
            guard let normal = UInt32(call[2]),
                  let error = UInt32(call[3])
            else {
                throw CanonicalSIL.LoweringError.malformedSIL(
                    "try_apply has an invalid successor"
                )
            }
            normalSuccessor = normal
            errorSuccessor = error
        } else if let call = captures(
            line,
            pattern: #"^(?:%[0-9]+ = )?apply %[0-9]+(?:<.*>)?\((.*)\) : \$(.+)$"#
        ) {
            argumentsText = call[0]
            functionType = call[1]
            normalSuccessor = nil
            errorSuccessor = nil
        } else {
            return nil
        }

        let specializedType = try CanonicalSIL.SubstitutedFunctionType
            .specialize(functionType)
        guard let shape = physicalFunctionShape(in: specializedType),
              let argumentComponents = splitTopLevelValidated(argumentsText)
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "apply has an invalid physical function type or argument list"
            )
        }
        let resultOffset = shape.indirectResultEdges.count
        guard argumentComponents.count
                == shape.parameterSpellings.count + resultOffset
        else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "apply argument count differs from its physical function type"
            )
        }
        let argumentTokens = argumentComponents.map {
            firstSILValue(in: $0[...])
        }
        guard argumentTokens.allSatisfy({ $0 != nil }) else {
            throw CanonicalSIL.LoweringError.malformedSIL(
                "apply contains a non-SSA physical argument"
            )
        }
        let tokens = argumentTokens.compactMap { $0 }
        let parameters = zip(
            shape.parameterSpellings,
            tokens.dropFirst(resultOffset)
        )
        let taken = parameters.compactMap { spelling, token in
            spelling.trimmingCharacters(in: .whitespaces)
                .hasPrefix("@in ") ? token : nil
        }
        let initializedResults = zip(
            shape.indirectResultEdges,
            tokens.prefix(resultOffset)
        ).map { edge, token in
            let successor: UInt32? = switch edge {
            case .normal: normalSuccessor
            case .error: errorSuccessor
            }
            return ApplicationStorageEffects.EdgeResult(
                address: token,
                successor: successor
            )
        }
        return .init(
            takenArguments: taken,
            initializedResults: initializedResults
        )
    }

    private enum IndirectResultEdge: Sendable {
        case normal
        case error
    }

    private static func physicalFunctionShape(
        in text: String
    ) -> (
        parameterSpellings: [String],
        indirectResultEdges: [IndirectResultEdge]
    )? {
        guard let arrow = outerFunctionArrow(in: text) else { return nil }
        let prefix = String(text[..<arrow.lowerBound])
        guard let close = prefix.lastIndex(of: ")"),
              let open = matchingOpeningParenthesis(for: close, in: prefix),
              let parameters = splitTopLevelValidated(
                String(prefix[prefix.index(after: open)..<close])
              )
        else { return nil }

        let rawResult = String(text[arrow.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        let resultComponents: [String]
        if rawResult.first == "(", rawResult.last == ")",
           let close = matchingClose(
            in: rawResult,
            after: rawResult.startIndex
           ),
           close == rawResult.index(before: rawResult.endIndex),
           let components = splitTopLevelValidated(
            String(
                rawResult[
                    rawResult.index(after: rawResult.startIndex)..<close
                ]
            )
           ) {
            resultComponents = components
        } else {
            resultComponents = [rawResult]
        }
        var indirectResultEdges: [IndirectResultEdge] = []
        if resultComponents.first?.trimmingCharacters(in: .whitespaces)
            .hasPrefix("@out ") == true {
            indirectResultEdges.append(.normal)
        }
        if resultComponents.contains(where: {
            $0.trimmingCharacters(in: .whitespaces)
                .hasPrefix("@error_indirect ")
        }) {
            indirectResultEdges.append(.error)
        }
        return (parameters, indirectResultEdges)
    }

    private static func outerFunctionArrow(
        in text: String
    ) -> Range<String.Index>? {
        var depths = (parenthesis: 0, angle: 0, square: 0)
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "(": depths.parenthesis += 1
            case ")": depths.parenthesis -= 1
            case "<": depths.angle += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { depths.angle -= 1 }
            case "[": depths.square += 1
            case "]": depths.square -= 1
            case "-" where depths == (0, 0, 0):
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == ">" {
                    return index..<text.index(after: next)
                }
            default:
                break
            }
            guard depths.parenthesis >= 0,
                  depths.angle >= 0,
                  depths.square >= 0
            else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    private static func matchingOpeningParenthesis(
        for close: String.Index,
        in text: String
    ) -> String.Index? {
        var depth = 0
        var index = close
        while true {
            switch text[index] {
            case ")": depth += 1
            case "(":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            guard depth >= 0, index > text.startIndex else { return nil }
            index = text.index(before: index)
        }
    }

    private static func splitTopLevelValidated(
        _ text: String
    ) -> [String]? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        var result: [String] = []
        var start = text.startIndex
        var depths = (parenthesis: 0, angle: 0, square: 0)
        for index in text.indices {
            switch text[index] {
            case "(": depths.parenthesis += 1
            case ")": depths.parenthesis -= 1
            case "<": depths.angle += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { depths.angle -= 1 }
            case "[": depths.square += 1
            case "]": depths.square -= 1
            case "," where depths == (0, 0, 0):
                result.append(
                    String(text[start..<index])
                        .trimmingCharacters(in: .whitespaces)
                )
                start = text.index(after: index)
            default:
                break
            }
            guard depths.parenthesis >= 0,
                  depths.angle >= 0,
                  depths.square >= 0
            else { return nil }
        }
        guard depths == (0, 0, 0) else { return nil }
        result.append(
            String(text[start...]).trimmingCharacters(in: .whitespaces)
        )
        return result
    }

    private static func takenAddress(in line: String) -> String? {
        if line.hasPrefix("copy_addr [take]") {
            return silValues(in: line).first
        }
        if line.contains(" = load [take] ") {
            return silValues(in: line).last
        }
        return nil
    }

    private static func destroyedAddress(in line: String) -> String? {
        guard line.hasPrefix("destroy_addr ") else { return nil }
        return silValues(in: line).first
    }

    private static func deallocatedAddress(in line: String) -> String? {
        guard line.hasPrefix("dealloc_stack ") else { return nil }
        return silValues(in: line).first
    }

    private static func fieldIndex(
        after marker: String,
        in line: String
    ) -> UInt32? {
        guard let markerRange = line.range(of: marker),
              let comma = line[markerRange.upperBound...].firstIndex(of: ",")
        else { return nil }
        let suffix = line[line.index(after: comma)...]
            .drop(while: \.isWhitespace)
        let digits = suffix.prefix(while: \.isNumber)
        return UInt32(digits)
    }

    private static func structFieldName(in line: String) -> String? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let token = line[line.index(after: hash)...]
            .prefix { !$0.isWhitespace && $0 != "," }
        return token.split(separator: ".").last.map(String.init)
    }

    private static func stackAllocationType(in line: String) -> String? {
        guard let marker = line.range(of: " = alloc_stack"),
              let dollar = line[marker.upperBound...].firstIndex(of: "$")
        else { return nil }
        let suffix = String(line[line.index(after: dollar)...])
        return splitTopLevel(suffix).first
    }

    private static func blockNumber(in line: String) -> UInt32? {
        guard line.hasPrefix("bb") else { return nil }
        let digits = line.dropFirst(2).prefix(while: \.isNumber)
        return UInt32(digits)
    }

    private static func blockReferences(in line: String) -> Set<UInt32> {
        let terminatorPrefixes = [
            "br ", "cond_br ", "switch_", "try_apply ",
            "checked_cast", "dynamic_method_br ", "yield ",
        ]
        guard terminatorPrefixes.contains(where: line.hasPrefix) else {
            return []
        }
        var result = Set<UInt32>()
        var index = line.startIndex
        while index < line.endIndex,
              let marker = line[index...].range(of: "bb") {
            let digitsStart = marker.upperBound
            let digits = line[digitsStart...].prefix(while: \.isNumber)
            if !digits.isEmpty, let value = UInt32(digits) {
                result.insert(value)
            }
            index = digits.isEmpty
                ? marker.upperBound
                : line.index(digitsStart, offsetBy: digits.count)
        }
        return result
    }

    private static func silValues(in text: String) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex,
              let percent = text[index...].firstIndex(of: "%") {
            let digitsStart = text.index(after: percent)
            let digits = text[digitsStart...].prefix(while: \.isNumber)
            if !digits.isEmpty {
                result.append("%" + digits)
                index = text.index(digitsStart, offsetBy: digits.count)
            } else {
                index = digitsStart
            }
        }
        return result
    }

    private static func functionReferenceSymbol(in line: String) -> String? {
        guard let marker = line.range(of: "function_ref @") else { return nil }
        let suffix = line[marker.upperBound...]
        let end = suffix.firstIndex { $0 == " " || $0 == ":" }
            ?? suffix.endIndex
        let symbol = String(suffix[..<end])
        return symbol.isEmpty ? nil : symbol
    }

    private static func silResultValue(in line: String) -> String? {
        guard let equals = line.range(of: " =") else { return nil }
        let value = line[..<equals.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        return value.first == "%" ? value : nil
    }

    private static func silValue(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return firstSILValue(in: line[range.upperBound...])
    }

    private static func firstSILValue(
        in text: Substring
    ) -> String? {
        guard let percent = text.firstIndex(of: "%") else { return nil }
        let tail = text[percent...]
        let end = tail.dropFirst().firstIndex { !$0.isNumber } ?? tail.endIndex
        let value = String(tail[..<end])
        return value.count > 1 ? value : nil
    }

    private static func captures(
        _ text: String,
        pattern: String
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              )
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text)
            else { return "" }
            return String(text[swiftRange])
        }
    }

    private static func partialApply(
        in line: String
    ) -> (callee: String, captures: [String])? {
        guard let marker = line.range(of: "partial_apply"),
              let callee = firstSILValue(in: line[marker.upperBound...]),
              let calleeRange = line.range(
                of: callee,
                range: marker.upperBound..<line.endIndex
              ),
              let open = line[calleeRange.upperBound...].firstIndex(of: "("),
              let close = matchingClose(in: line, after: open)
        else { return nil }
        let contents = String(line[line.index(after: open)..<close])
        let components = splitTopLevel(contents)
        let captures = components.compactMap { component in
            firstSILValue(in: component[...])
        }
        guard captures.count == components.count else { return nil }
        return (callee, captures)
    }

    private static func matchingClose(
        in text: String,
        after open: String.Index
    ) -> String.Index? {
        var depth = 0
        for index in text.indices where index >= open {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var result: [String] = []
        var start = text.startIndex
        var depths = (parenthesis: 0, angle: 0, square: 0)
        for index in text.indices {
            switch text[index] {
            case "(": depths.parenthesis += 1
            case ")": depths.parenthesis -= 1
            case "<": depths.angle += 1
            case ">":
                let previous = index > text.startIndex
                    ? text[text.index(before: index)]
                    : nil
                if previous != "-" { depths.angle -= 1 }
            case "[": depths.square += 1
            case "]": depths.square -= 1
            case "," where depths == (0, 0, 0):
                result.append(
                    String(text[start..<index])
                        .trimmingCharacters(in: .whitespaces)
                )
                start = text.index(after: index)
            default: break
            }
        }
        result.append(
            String(text[start...]).trimmingCharacters(in: .whitespaces)
        )
        return result
    }
}
}
