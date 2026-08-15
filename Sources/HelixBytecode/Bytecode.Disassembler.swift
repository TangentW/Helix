import Foundation
#if canImport(HelixCore)
import HelixCore
#endif

extension Bytecode {
public enum Disassembler {
    public static func disassemble(_ module: Bytecode.Module) -> String {
        var lines: [String] = []
        let sourceLocations = sourceLocationIndex(module.sourceMap)
        lines.append("hlbc_module \(quoted(module.name))")
        lines.append("shell \(module.shellInterfaceHash.hex)")
        if !module.capabilities.isEmpty {
            lines.append("capabilities \(module.capabilities.sorted().map(\.rawValue).joined(separator: ", "))")
        }
        for definition in module.localTypes.sorted(by: { $0.key < $1.key }) {
            switch definition.kind {
            case let .structure(fields):
                let body = fields.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
                lines.append("local_struct \(definition.key) { \(body) }")
            case let .enumeration(cases):
                let body = cases.map { item in
                    item.payloadType.map { "\(item.name)(\($0))" } ?? item.name
                }.joined(separator: ", ")
                let error = definition.conformsToError ? " : Error" : ""
                lines.append("local_enum \(definition.key)\(error) { \(body) }")
            case let .class(fields, hostedSuperclass, methods):
                let body = fields.map { "\($0.name): \($0.type)" }
                    .joined(separator: ", ")
                let superclass = hostedSuperclass.map {
                    " : Native<\($0.typeID)>"
                } ?? ""
                lines.append("local_class \(definition.key)\(superclass) { \(body) }")
                for method in methods {
                    lines.append(
                        "  hosted_method \(quoted(method.selector)) "
                            + "@\(method.functionID) [\(method.abi.rawValue)]"
                    )
                }
            }
        }
        for function in module.functions.sorted(by: { $0.id < $1.id }) {
            let parameters = zip(
                function.parameterRegisters,
                function.parameterConventions
            ).map { register, convention in
                let prefix = convention == .owned ? "" : "@\(convention.rawValue) "
                return "\(register): \(prefix)\(function.type(of: register)?.description ?? "<invalid>")"
            }.joined(separator: ", ")
            lines.append("")
            let throwing = function.effects.mayThrow ? " throws" : ""
            let kind = function.kind == .ordinary ? "" : " @\(function.kind.rawValue)"
            let declarationLocation = function.sourceLocation.map { " @ \($0)" } ?? ""
            lines.append("func\(kind) @\(function.id)(\(parameters))\(throwing) -> \(function.resultType) { // \(function.name)\(declarationLocation)")
            for (offset, type) in function.stackSlotTypes.enumerated() {
                lines.append("  stack $\(offset): \(type)")
            }
            for block in function.blocks {
                let blockParameters = block.parameters.map { register in
                    "\(register): \(function.type(of: register)?.description ?? "<invalid>")"
                }.joined(separator: ", ")
                lines.append("  \(block.id)(\(blockParameters)):")
                for (offset, instruction) in block.instructions.enumerated() {
                    let coordinate = UInt32(exactly: offset).map {
                        SourceCoordinate(
                            functionID: function.id,
                            blockID: block.id,
                            instructionOffset: $0
                        )
                    }
                    let location = coordinate.flatMap { sourceLocations[$0] }
                    let suffix = location.map { " // \($0)" } ?? ""
                    lines.append("    \(format(instruction))\(suffix)")
                }
            }
            lines.append("}")
        }
        return lines.joined(separator: "\n")
    }

    private struct SourceCoordinate: Hashable {
        var functionID: Bytecode.FunctionID
        var blockID: Bytecode.BlockID
        var instructionOffset: UInt32
    }

    private static func sourceLocationIndex(
        _ entries: [Bytecode.SourceMapEntry]
    ) -> [SourceCoordinate: Core.SourceLocation] {
        entries.reduce(into: [:]) { result, entry in
            let coordinate = SourceCoordinate(
                functionID: entry.functionID,
                blockID: entry.blockID,
                instructionOffset: entry.instructionOffset
            )
            result[coordinate] = result[coordinate] ?? entry.location
        }
    }

    private static func format(_ instruction: Bytecode.Instruction) -> String {
        switch instruction {
        case let .constantInteger(result, value): "\(result) = const_int \(value)"
        case let .constantBool(result, value): "\(result) = const_bool \(value)"
        case let .constantFloat(result, value): "\(result) = const_float \(value)"
        case let .constantString(result, value): "\(result) = const_string \(quoted(value))"
        case let .copyValue(result, source): "\(result) = copy_value \(source)"
        case let .moveValue(result, source): "\(result) = move_value \(source)"
        case let .destroyValue(register): "destroy_value \(register)"
        case let .makeTuple(result, elements):
            "\(result) = make_tuple (\(elements.map(\.description).joined(separator: ", ")))"
        case let .unpackTuple(results, tuple):
            "(\(results.map(\.description).joined(separator: ", "))) = unpack_tuple \(tuple)"
        case let .makeStruct(result, fields):
            "\(result) = make_struct (\(fields.map(\.description).joined(separator: ", ")))"
        case let .structExtract(result, structure, fieldIndex):
            "\(result) = struct_extract \(structure), #\(fieldIndex)"
        case let .makeEnum(result, caseIndex, payload):
            "\(result) = make_enum #\(caseIndex)"
                + (payload.map { " \($0)" } ?? "")
        case let .switchEnum(enumeration, cases, defaultTarget):
            "switch_enum \(enumeration), "
                + cases.map { "#\($0.caseIndex): \($0.target)" }.joined(separator: ", ")
                + (defaultTarget.map { ", default: \($0)" } ?? "")
        case let .makeError(result, payload):
            "\(result) = make_error \(payload)"
        case let .castError(result, error, expectedType):
            "\(result) = cast_error \(error) to \(expectedType)"
        case let .eraseToAny(result, value):
            "\(result) = erase_to_any \(value)"
        case let .checkedCastAny(result, value):
            "\(result) = checked_cast_any \(value)"
        case let .forceCastAny(result, value):
            "\(result) = force_cast_any \(value)"
        case let .makeOptionalSome(result, value):
            "\(result) = optional_some \(value)"
        case let .makeOptionalNone(result):
            "\(result) = optional_none"
        case let .optionalIsSome(result, optional):
            "\(result) = optional_is_some \(optional)"
        case let .unwrapOptional(result, optional):
            "\(result) = optional_unwrap \(optional)"
        case let .switchOptional(optional, someTarget, noneTarget):
            "switch_optional \(optional), some: \(someTarget), none: \(noneTarget)"
        case let .storeStack(slot, source, mode):
            "store_stack.\(mode.rawValue) \(source), \(slot)"
        case let .loadStack(result, slot, mode):
            "\(result) = load_stack.\(mode.rawValue) \(slot)"
        case let .destroyStack(slot):
            "destroy_stack \(slot)"
        case let .destroyStackIfInitialized(slot):
            "destroy_stack_if_initialized \(slot)"
        case let .stackAddress(result, slot):
            "\(result) = stack_address \(slot)"
        case let .projectAggregateAddress(result, base, fieldIndex):
            "\(result) = project_aggregate_address \(base), #\(fieldIndex)"
        case let .makeMutableCell(result, initialValue):
            initialValue.map { "\(result) = make_mutable_cell \($0)" }
                ?? "\(result) = make_mutable_cell.uninitialized"
        case let .projectMutableCell(result, cell, fieldIndex):
            "\(result) = project_mutable_cell \(cell), #\(fieldIndex)"
        case let .loadMutableCell(result, cell):
            "\(result) = load_mutable_cell \(cell)"
        case let .storeMutableCell(cell, source, mode):
            "store_mutable_cell.\(mode.rawValue) \(source) to \(cell)"
        case let .allocateObject(result):
            "\(result) = allocate_object"
        case let .projectObjectAddress(result, object, fieldIndex):
            "\(result) = project_object_address \(object), #\(fieldIndex)"
        case let .projectHostedObject(result, object):
            "\(result) = project_hosted_object \(object)"
        case let .hostedSuperApply(object, methodIndex, arguments):
            "hosted_super_apply \(object), #\(methodIndex)(\(arguments.map(\.description).joined(separator: ", ")))"
        case let .beginAccess(result, address, kind):
            "\(result) = begin_access.\(kind.rawValue) \(address)"
        case let .endAccess(address):
            "end_access \(address)"
        case let .loadAddress(result, address, mode):
            "\(result) = load_address.\(mode.rawValue) \(address)"
        case let .storeAddress(address, source, mode):
            "store_address.\(mode.rawValue) \(source), \(address)"
        case let .checkedBinary(result, overflow, operation, lhs, rhs):
            "(\(result), \(overflow)) = checked_\(operation.rawValue) \(lhs), \(rhs)"
        case let .floatingBinary(result, operation, lhs, rhs):
            "\(result) = float_\(operation.rawValue) \(lhs), \(rhs)"
        case let .floatingUnary(result, operation, operand):
            "\(result) = float_\(operation.rawValue) \(operand)"
        case let .integerConvert(result, operation, value):
            "\(result) = integer_convert.\(operation.rawValue) \(value)"
        case let .floatingConvert(result, operation, value):
            "\(result) = floating_convert.\(operation.rawValue) \(value)"
        case let .booleanBinary(result, operation, lhs, rhs):
            "\(result) = bool_\(operation.rawValue) \(lhs), \(rhs)"
        case let .select(result, condition, trueValue, falseValue):
            "\(result) = select \(condition), \(trueValue), \(falseValue)"
        case let .stringConcat(result, lhs, rhs):
            "\(result) = string_concat \(lhs), \(rhs)"
        case let .stringCount(result, string):
            "\(result) = string_count \(string)"
        case let .stringIsEmpty(result, string):
            "\(result) = string_is_empty \(string)"
        case let .stringPredicate(result, operation, string, pattern):
            "\(result) = string_\(operation.rawValue) \(string), \(pattern)"
        case let .stringTransform(result, operation, string):
            "\(result) = string_\(operation.rawValue) \(string)"
        case let .stringify(result, value):
            "\(result) = stringify \(value)"
        case let .makeArray(result, elements):
            "\(result) = make_array [\(elements.map(\.description).joined(separator: ", "))]"
        case let .arrayCount(result, array):
            "\(result) = array_count \(array)"
        case let .arrayIsEmpty(result, array):
            "\(result) = array_is_empty \(array)"
        case let .arrayGet(result, array, index):
            "\(result) = array_get \(array)[\(index)]"
        case let .arrayBoundary(result, operation, array):
            "\(result) = array_\(operation.rawValue) \(array)"
        case let .arrayContains(result, array, value):
            "\(result) = array_contains \(array), \(value)"
        case let .arrayAppend(result, array, value):
            "\(result) = array_append \(array), \(value)"
        case let .makeArrayBuilder(result):
            "\(result) = make_array_builder"
        case let .arrayBuilderAppend(builder, value):
            "array_builder_append \(value) to \(builder)"
        case let .finishArrayBuilder(result, builder):
            "\(result) = finish_array_builder \(builder)"
        case let .arrayUpdate(result, array, index, value):
            "\(result) = array_update \(array)[\(index)] = \(value)"
        case let .arrayPopLast(elementResult, arrayResult, array):
            "(\(elementResult), \(arrayResult)) = array_pop_last \(array)"
        case let .arrayNext(result, array, indexSlot):
            "\(result) = array_next \(array), \(indexSlot)"
        case let .progressionNext(result, cursorSlot, end, stride, boundary):
            "\(result) = progression_next.\(boundary.rawValue) "
                + "\(cursorSlot), end: \(end), stride: \(stride)"
        case let .makeDictionary(result, pairs):
            "\(result) = make_dictionary \(pairs)"
        case let .dictionaryCount(result, dictionary):
            "\(result) = dictionary_count \(dictionary)"
        case let .dictionaryIsEmpty(result, dictionary):
            "\(result) = dictionary_is_empty \(dictionary)"
        case let .dictionaryGet(result, dictionary, key):
            "\(result) = dictionary_get \(dictionary)[\(key)]"
        case let .dictionaryUpdate(result, dictionary, key, value):
            "\(result) = dictionary_update \(dictionary)[\(key)] = \(value)"
        case let .dictionaryRemove(valueResult, dictionaryResult, dictionary, key):
            "(\(valueResult), \(dictionaryResult)) = dictionary_remove \(dictionary)[\(key)]"
        case let .dictionaryNext(result, dictionary, indexSlot):
            "\(result) = dictionary_next \(dictionary), \(indexSlot)"
        case let .makeSet(result, source):
            "\(result) = make_set \(source)"
        case let .setCount(result, set):
            "\(result) = set_count \(set)"
        case let .setIsEmpty(result, set):
            "\(result) = set_is_empty \(set)"
        case let .setContains(result, set, element):
            "\(result) = set_contains \(set), \(element)"
        case let .setInsert(inserted, member, updated, set, element):
            "(\(inserted), \(member), \(updated)) = set_insert \(element) into \(set)"
        case let .setUpdate(oldMember, updated, set, element):
            "(\(oldMember), \(updated)) = set_update \(element) in \(set)"
        case let .setRemove(removed, updated, set, element):
            "(\(removed), \(updated)) = set_remove \(element) from \(set)"
        case let .setPopFirst(element, updated, set):
            "(\(element), \(updated)) = set_pop_first \(set)"
        case let .setNext(result, set, indexSlot):
            "\(result) = set_next \(set), \(indexSlot)"
        case let .setAlgebra(result, operation, lhs, rhs):
            "\(result) = set_\(operation.rawValue) \(lhs), \(rhs)"
        case let .setRelation(result, operation, lhs, rhs):
            "\(result) = set_\(operation.rawValue) \(lhs), \(rhs)"
        case let .compare(result, predicate, lhs, rhs):
            "\(result) = compare \(predicate.rawValue) \(lhs), \(rhs)"
        case let .branch(target, arguments):
            "br \(target)(\(arguments.map(\.description).joined(separator: ", ")))"
        case let .conditionalBranch(condition, trueTarget, trueArguments, falseTarget, falseArguments):
            "cond_br \(condition), \(trueTarget)(\(trueArguments.map(\.description).joined(separator: ", "))), "
                + "\(falseTarget)(\(falseArguments.map(\.description).joined(separator: ", ")))"
        case let .apply(result, function, arguments):
            "\(assignment(result))hlbc_apply @\(function)(\(arguments.map(\.description).joined(separator: ", ")))"
        case let .entryApply(result, entry, arguments):
            "\(assignment(result))entry_apply #\(entry)(\(arguments.map(\.description).joined(separator: ", ")))"
        case let .nativeApply(result, importID, arguments):
            "\(assignment(result))native_apply #\(importID)(\(arguments.map(\.description).joined(separator: ", ")))"
        case let .makeClosure(result, function, captures):
            "\(result) = make_closure @\(function)"
                + " [\(captures.map(\.description).joined(separator: ", "))]"
        case let .closureApply(result, closure, arguments):
            "\(assignment(result))closure_apply \(closure)"
                + "(\(arguments.map(\.description).joined(separator: ", ")))"
        case let .closureTryApply(closure, arguments, normalTarget, errorTarget):
            "closure_try_apply \(closure)"
                + "(\(arguments.map(\.description).joined(separator: ", "))), "
                + "normal: \(normalTarget), error: \(errorTarget)"
        case let .tryApply(function, arguments, normalTarget, errorTarget):
            "try_apply @\(function)(\(arguments.map(\.description).joined(separator: ", "))), "
                + "normal: \(normalTarget), error: \(errorTarget)"
        case let .entryTryApply(entry, arguments, normalTarget, errorTarget):
            "entry_try_apply #\(entry)(\(arguments.map(\.description).joined(separator: ", "))), "
                + "normal: \(normalTarget), error: \(errorTarget)"
        case let .nativeTryApply(importID, arguments, normalTarget, errorTarget):
            "native_try_apply #\(importID)(\(arguments.map(\.description).joined(separator: ", "))), "
                + "normal: \(normalTarget), error: \(errorTarget)"
        case let .returnValue(value): value.map { "return \($0)" } ?? "return"
        case let .throwError(error): "throw_error \(error)"
        case let .trap(reason): "trap \(quoted(reason.description))"
        }
    }

    private static func assignment(_ result: Bytecode.Register?) -> String {
        result.map { "\($0) = " } ?? ""
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0a: result += "\\n"
            case 0x0c: result += "\\f"
            case 0x0d: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x00...0x1f:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
}
