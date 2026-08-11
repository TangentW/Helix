import Foundation
import HelixCore

extension Bytecode {
private struct WireMetadata: Codable {
    var name: String
    var compatibility: Core.Compatibility
    var capabilities: [Core.Capability]
    var requestedResources: Core.ResourceLimits
    var localTypes: [Bytecode.LocalTypeDefinition]?
}

private struct WireImports: Codable {
    var entries: [Bytecode.EntryPoint]
    var imports: [Bytecode.ImportRequirement]
}

private struct WireBlockLayout: Codable {
    var id: Bytecode.BlockID
    var parameters: [Bytecode.Register]
    var instructionStart: UInt32
    var instructionCount: UInt32
}

private struct WireFunctionLayout: Codable {
    var id: Bytecode.FunctionID
    var name: String
    var kind: Bytecode.FunctionKind?
    var parameterRegisters: [Bytecode.Register]
    var parameterConventions: [Bytecode.ParameterConvention]?
    var resultTypeIndex: UInt32
    var registerTypeIndices: [UInt32]
    var stackSlotTypeIndices: [UInt32]
    var effects: Core.Effects
    var entryBlock: Bytecode.BlockID
    var blocks: [Bytecode.WireBlockLayout]
    var sourceLocation: Core.SourceLocation?
}

public enum Encoder {
    public static func encode(_ module: Bytecode.Module) throws -> Data {
        try encode(module, formatMinor: Bytecode.Format.minorVersion)
    }

    static func encode(
        _ module: Bytecode.Module,
        formatMinor: UInt16
    ) throws -> Data {
        guard formatMinor <= Bytecode.Format.minorVersion else {
            throw Bytecode.CodecError.unsupportedFormat(
                major: Bytecode.Format.majorVersion,
                minor: formatMinor
            )
        }
        let declaredBytecode = module.compatibility.bytecode
        guard declaredBytecode.major == Bytecode.Format.majorVersion,
              declaredBytecode.minor >= formatMinor
        else {
            throw Bytecode.CodecError.invalidHeader(
                "HLBC format 1.\(formatMinor) exceeds declared bytecode compatibility \(declaredBytecode)"
            )
        }
        try validateInstructionAvailability(in: module, formatMinor: formatMinor)
        try validateFloatingPointConstants(in: module)
        let wire = try makeWireSections(module, formatMinor: formatMinor)
        let sortedSections = wire.sorted { $0.key < $1.key }
        guard sortedSections.count <= Int(UInt32.max) else {
            throw Bytecode.CodecError.invalidHeader("section count does not fit UInt32")
        }

        let tableSize = try checkedMultiply(sortedSections.count, Bytecode.SectionEntry.byteCount)
        let payloadStart = try checkedAdd(Bytecode.Header.byteCount, tableSize)
        var nextOffset = payloadStart
        var entries: [Bytecode.SectionEntry] = []
        entries.reserveCapacity(sortedSections.count)

        for (kind, payload) in sortedSections {
            let offset = nextOffset
            nextOffset = try checkedAdd(nextOffset, payload.count)
            entries.append(
                Bytecode.SectionEntry(
                    kind: kind,
                    flags: 0,
                    offset: UInt64(offset),
                    compressedSize: UInt64(payload.count),
                    uncompressedSize: UInt64(payload.count),
                    sha256: .sha256(payload)
                )
            )
        }

        let zeroHash = try Core.Digest(bytes: repeatElement(UInt8(0), count: Core.Digest.byteCount))
        var writer = Bytecode.BinaryWriter()
        writer.append(bytes: Bytecode.Format.magic)
        writer.append(Bytecode.Format.majorVersion)
        writer.append(formatMinor)
        writer.append(module.compatibility.runtime.major)
        writer.append(UInt16(0))
        writer.append(module.shellInterfaceHash.data)
        writer.append(zeroHash.data)
        writer.append(UInt32(entries.count))
        writer.append(UInt64(Bytecode.Header.byteCount))

        for entry in entries {
            writer.append(entry.kind.rawValue)
            writer.append(entry.flags)
            writer.append(entry.offset)
            writer.append(entry.compressedSize)
            writer.append(entry.uncompressedSize)
            writer.append(entry.sha256.data)
        }
        for (_, payload) in sortedSections {
            writer.append(payload)
        }

        guard writer.data.count == nextOffset else {
            throw Bytecode.CodecError.invalidHeader("encoder offset accounting mismatch")
        }
        let imageHash = Core.Digest.sha256(writer.data)
        writer.data.replaceSubrange(Bytecode.Header.imageHashRange, with: imageHash.data)
        return writer.data
    }

    private static func validateInstructionAvailability(
        in module: Bytecode.Module,
        formatMinor: UInt16
    ) throws {
        if formatMinor < 1 {
            guard !module.capabilities.contains(.stringsV1) else {
                throw Bytecode.CodecError.invalidHeader(
                    "strings-v1 requires HLBC format 1.1"
                )
            }
            guard !module.capabilities.contains(.collectionsV1) else {
                throw Bytecode.CodecError.invalidHeader(
                    "collections-v1 requires HLBC format 1.1"
                )
            }
            guard !module.functions.contains(where: { function in
                (function.registerTypes + function.stackSlotTypes + [function.resultType])
                    .contains(where: containsFloatOrString)
            }) else {
                throw Bytecode.CodecError.invalidHeader(
                    "Float and String value types require HLBC format 1.1"
                )
            }
            guard !module.functions.contains(where: { function in
                      (function.registerTypes + function.stackSlotTypes + [function.resultType])
                          .contains(where: containsArray)
                  })
            else {
                throw Bytecode.CodecError.invalidHeader(
                    "Array value types require HLBC format 1.1"
                )
            }
        }
        if formatMinor < 2 {
            guard !module.capabilities.contains(.untypedThrowsV1) else {
                throw Bytecode.CodecError.invalidHeader(
                    "untyped-throws-v1 requires HLBC format 1.2"
                )
            }
            guard !module.functions.contains(where: { $0.effects.mayThrow }) else {
                throw Bytecode.CodecError.invalidHeader(
                    "throwing function effects require HLBC format 1.2"
                )
            }
        }
        if formatMinor < 3 {
            guard !module.functions.contains(where: { function in
                (function.registerTypes + function.stackSlotTypes + [function.resultType])
                    .contains(where: containsDictionary)
            }) else {
                throw Bytecode.CodecError.invalidHeader(
                    "Dictionary value types require HLBC format 1.3"
                )
            }
        }
        if formatMinor < 4 {
            guard !module.capabilities.contains(.nativeImportsV2),
                  module.imports.allSatisfy({
                      $0.requiredCapability == .nativeImportsV1 && $0.contract == nil
                  })
            else {
                throw Bytecode.CodecError.invalidHeader(
                    "native import v2 contracts require HLBC format 1.4"
                )
            }
        } else {
            guard module.imports.allSatisfy({
                $0.requiredCapability == .nativeImportsV2 && $0.contract != nil
            }) else {
                throw Bytecode.CodecError.invalidHeader(
                    "HLBC 1.4 native imports require a v2 contract"
                )
            }
        }
        if formatMinor < 6 {
            guard module.localTypes.isEmpty,
                  !module.capabilities.contains(.localNominalsV1),
                  !module.capabilities.contains(.structuredErrorsV1)
            else {
                throw Bytecode.CodecError.invalidHeader(
                    "local nominal values and structured errors require HLBC format 1.6"
                )
            }
            guard !module.functions.contains(where: { function in
                (function.registerTypes + function.stackSlotTypes + [function.resultType])
                    .contains(where: containsLocalNominalOrError)
            }) else {
                throw Bytecode.CodecError.invalidHeader(
                    "local nominal and Error value types require HLBC format 1.6"
                )
            }
        }
        if formatMinor < 7 {
            guard !module.capabilities.contains(.addressValuesV1),
                  !module.capabilities.contains(.borrowCallsV1),
                  module.functions.allSatisfy({
                      $0.parameterConventions.allSatisfy { $0 == .owned }
                  })
            else {
                throw Bytecode.CodecError.invalidHeader(
                    "address values and borrowed calls require HLBC format 1.7"
                )
            }
            guard !module.functions.contains(where: { function in
                (function.registerTypes + function.stackSlotTypes + [function.resultType])
                    .contains(where: containsAddress)
            }) else {
                throw Bytecode.CodecError.invalidHeader(
                    "address value types require HLBC format 1.7"
                )
            }
        }
        if formatMinor < 8 {
            guard !module.capabilities.contains(.closureValuesV1),
                  !module.capabilities.contains(.escapingClosureValuesV1),
                  !module.capabilities.contains(.compilerSpecializationsV1),
                  module.functions.allSatisfy({ $0.kind == .ordinary })
            else {
                throw Bytecode.CodecError.invalidHeader(
                    "closure values and compiler specializations require HLBC format 1.8"
                )
            }
            guard !module.functions.contains(where: { function in
                (function.registerTypes + function.stackSlotTypes + [function.resultType])
                    .contains(where: containsClosure)
            }) else {
                throw Bytecode.CodecError.invalidHeader(
                    "closure value types require HLBC format 1.8"
                )
            }
        }
        if formatMinor < 9 {
            guard !module.capabilities.contains(.asyncLeafEntriesV1),
                  module.functions.allSatisfy({ !$0.effects.isAsync })
            else {
                throw Bytecode.CodecError.invalidHeader(
                    "non-suspending async entries require HLBC format 1.9"
                )
            }
        }
        for function in module.functions {
            for block in function.blocks {
                for instruction in block.instructions {
                    if formatMinor < 1 {
                        switch instruction {
                        case .constantFloat, .constantString,
                             .floatingBinary, .floatingUnary, .stringConcat,
                             .stringCount, .stringIsEmpty, .makeArray, .arrayCount,
                             .arrayIsEmpty, .arrayGet, .arrayFirst, .arrayContains:
                            throw Bytecode.CodecError.invalidHeader(
                                "this instruction requires HLBC format 1.1"
                            )
                        default:
                            break
                        }
                    }
                    if formatMinor < 2 {
                        switch instruction {
                        case .booleanBinary, .stringify, .arrayAppend, .arrayNext:
                            throw Bytecode.CodecError.invalidHeader(
                                "this instruction requires HLBC format 1.2"
                            )
                        case .tryApply, .entryTryApply, .nativeTryApply:
                            throw Bytecode.CodecError.invalidHeader(
                                "try_apply instructions require HLBC format 1.2"
                            )
                        case .throwError:
                            throw Bytecode.CodecError.invalidHeader(
                                "throw_error requires HLBC format 1.2"
                            )
                        default:
                            break
                        }
                    }
                    if formatMinor < 3 {
                        switch instruction {
                        case .makeDictionary, .dictionaryCount, .dictionaryIsEmpty,
                             .dictionaryGet, .dictionaryUpdate, .dictionaryNext:
                            throw Bytecode.CodecError.invalidHeader(
                                "Dictionary instructions require HLBC format 1.3"
                            )
                        default:
                            break
                        }
                    }
                    if formatMinor < 5 {
                        switch instruction {
                        case .integerConvert, .floatingConvert, .stringPredicate,
                             .arrayUpdate:
                            throw Bytecode.CodecError.invalidHeader(
                                "conversion, String predicate, and Array update instructions require HLBC format 1.5"
                            )
                        default:
                            break
                        }
                    }
                    if formatMinor < 6 {
                        switch instruction {
                        case .makeStruct, .structExtract, .makeEnum, .switchEnum,
                             .makeError, .castError:
                            throw Bytecode.CodecError.invalidHeader(
                                "local nominal and structured Error instructions require HLBC format 1.6"
                            )
                        default:
                            break
                        }
                    }
                    if formatMinor < 7 {
                        switch instruction {
                        case .stackAddress, .projectStructAddress, .beginAccess,
                             .endAccess, .loadAddress, .storeAddress:
                            throw Bytecode.CodecError.invalidHeader(
                                "address and access instructions require HLBC format 1.7"
                            )
                        default:
                            break
                        }
                    }
                    if formatMinor < 8 {
                        switch instruction {
                        case .makeClosure, .closureApply:
                            throw Bytecode.CodecError.invalidHeader(
                                "closure instructions require HLBC format 1.8"
                            )
                        default:
                            break
                        }
                    }
                }
            }
        }
    }

    private static func containsFloatOrString(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .float, .string:
            true
        case let .array(element):
            containsFloatOrString(element)
        case let .tuple(elements):
            elements.contains(where: containsFloatOrString)
        case let .optional(wrapped):
            containsFloatOrString(wrapped)
        case .dictionary:
            // Dictionary itself requires 1.3 and receives the more precise
            // diagnostic below, regardless of its nested key/value types.
            false
        case let .address(pointee):
            containsFloatOrString(pointee)
        case let .closure(signature):
            signature.parameters.contains(where: containsFloatOrString)
                || containsFloatOrString(signature.result)
        case .void, .never, .bool, .integer, .native, .local, .error:
            false
        }
    }

    private static func containsLocalNominalOrError(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .local, .error:
            true
        case let .array(element):
            containsLocalNominalOrError(element)
        case let .dictionary(key, value):
            containsLocalNominalOrError(key) || containsLocalNominalOrError(value)
        case let .tuple(elements):
            elements.contains(where: containsLocalNominalOrError)
        case let .optional(wrapped):
            containsLocalNominalOrError(wrapped)
        case let .address(pointee):
            containsLocalNominalOrError(pointee)
        case let .closure(signature):
            signature.parameters.contains(where: containsLocalNominalOrError)
                || containsLocalNominalOrError(signature.result)
        case .void, .never, .bool, .integer, .float, .string, .native:
            false
        }
    }

    private static func containsArray(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .array:
            true
        case let .dictionary(key, value):
            containsArray(key) || containsArray(value)
        case let .tuple(elements):
            elements.contains(where: containsArray)
        case let .optional(wrapped):
            containsArray(wrapped)
        case let .address(pointee):
            containsArray(pointee)
        case let .closure(signature):
            signature.parameters.contains(where: containsArray)
                || containsArray(signature.result)
        default:
            false
        }
    }

    private static func containsDictionary(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .dictionary:
            true
        case let .array(element):
            containsDictionary(element)
        case let .tuple(elements):
            elements.contains(where: containsDictionary)
        case let .optional(wrapped):
            containsDictionary(wrapped)
        case let .address(pointee):
            containsDictionary(pointee)
        case let .closure(signature):
            signature.parameters.contains(where: containsDictionary)
                || containsDictionary(signature.result)
        default:
            false
        }
    }

    private static func containsAddress(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .address:
            true
        case let .array(element), let .optional(element):
            containsAddress(element)
        case let .dictionary(key, value):
            containsAddress(key) || containsAddress(value)
        case let .tuple(elements):
            elements.contains(where: containsAddress)
        case let .closure(signature):
            signature.parameters.contains(where: containsAddress)
                || containsAddress(signature.result)
        default:
            false
        }
    }

    private static func containsClosure(_ type: Bytecode.ValueType) -> Bool {
        switch type {
        case .closure:
            true
        case let .array(element), let .optional(element), let .address(element):
            containsClosure(element)
        case let .dictionary(key, value):
            containsClosure(key) || containsClosure(value)
        case let .tuple(elements):
            elements.contains(where: containsClosure)
        default:
            false
        }
    }

    private static func validateFloatingPointConstants(in module: Bytecode.Module) throws {
        for function in module.functions {
            for block in function.blocks {
                for instruction in block.instructions {
                    guard case let .constantFloat(_, value) = instruction else { continue }
                    guard value.isFinite else {
                        throw Bytecode.CodecError.malformedSection(
                            kind: .code,
                            reason: "non-finite floating-point constants are not canonical JSON"
                        )
                    }
                }
            }
        }
    }

    private static func makeWireSections(
        _ module: Bytecode.Module,
        formatMinor: UInt16
    ) throws -> [Bytecode.SectionKind: Data] {
        var types: [Bytecode.ValueType] = []
        var typeIndices: [Bytecode.ValueType: UInt32] = [:]

        func intern(_ type: Bytecode.ValueType) throws -> UInt32 {
            if let existing = typeIndices[type] { return existing }
            guard let index = UInt32(exactly: types.count) else {
                throw Bytecode.CodecError.malformedFunctionLayout("type table exceeds UInt32")
            }
            types.append(type)
            typeIndices[type] = index
            return index
        }

        var code: [Bytecode.Instruction] = []
        var layouts: [Bytecode.WireFunctionLayout] = []
        for function in module.functions {
            let resultTypeIndex = try intern(function.resultType)
            let registerTypeIndices = try function.registerTypes.map(intern)
            let stackSlotTypeIndices = try function.stackSlotTypes.map(intern)
            var blockLayouts: [Bytecode.WireBlockLayout] = []
            for block in function.blocks {
                guard let start = UInt32(exactly: code.count),
                      let count = UInt32(exactly: block.instructions.count)
                else {
                    throw Bytecode.CodecError.malformedFunctionLayout("instruction table exceeds UInt32")
                }
                code.append(contentsOf: block.instructions)
                blockLayouts.append(
                    Bytecode.WireBlockLayout(
                        id: block.id,
                        parameters: block.parameters,
                        instructionStart: start,
                        instructionCount: count
                    )
                )
            }
            layouts.append(
                Bytecode.WireFunctionLayout(
                    id: function.id,
                    name: function.name,
                    kind: formatMinor >= 8 ? function.kind : nil,
                    parameterRegisters: function.parameterRegisters,
                    parameterConventions: formatMinor >= 7
                        ? function.parameterConventions
                        : nil,
                    resultTypeIndex: resultTypeIndex,
                    registerTypeIndices: registerTypeIndices,
                    stackSlotTypeIndices: stackSlotTypeIndices,
                    effects: function.effects,
                    entryBlock: function.entryBlock,
                    blocks: blockLayouts,
                    sourceLocation: function.sourceLocation
                )
            )
        }

        let metadata = Bytecode.WireMetadata(
            name: module.name,
            compatibility: module.compatibility,
            capabilities: module.capabilities.sorted(),
            requestedResources: module.requestedResources,
            localTypes: formatMinor >= 6 ? module.localTypes.sorted(by: { $0.key < $1.key }) : nil
        )
        let imports = Bytecode.WireImports(
            entries: module.entries.sorted { $0.entryIndex < $1.entryIndex },
            imports: module.imports.sorted { $0.id < $1.id }
        )
        let sourceMap = module.sourceMap.sorted {
            ($0.functionID, $0.blockID, $0.instructionOffset)
                < ($1.functionID, $1.blockID, $1.instructionOffset)
        }

        return [
            .types: try Core.CanonicalJSON.encode(types),
            .imports: try Core.CanonicalJSON.encode(imports),
            .functions: try Core.CanonicalJSON.encode(layouts),
            .code: try Core.CanonicalJSON.encode(code),
            .metadata: try Core.CanonicalJSON.encode(metadata),
            .debug: try Core.CanonicalJSON.encode(sourceMap),
        ]
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw Core.Error.arithmeticOverflow }
        return result.partialValue
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw Core.Error.arithmeticOverflow }
        return result.partialValue
    }
}

public enum Decoder {
    public static func decode(
        _ bytes: Data,
        limits: Bytecode.DecodingLimits = .init()
    ) throws -> Bytecode.DecodedContainer {
        guard bytes.count <= limits.maximumFileBytes else {
            throw Bytecode.CodecError.fileTooLarge(actual: bytes.count, maximum: limits.maximumFileBytes)
        }
        var reader = Bytecode.BinaryReader(data: bytes)
        let magic = try reader.readData(count: Bytecode.Format.magic.count)
        guard Array(magic) == Bytecode.Format.magic else { throw Bytecode.CodecError.invalidMagic }

        let formatMajor = try reader.read(UInt16.self)
        let formatMinor = try reader.read(UInt16.self)
        guard formatMajor == Bytecode.Format.majorVersion, formatMinor <= Bytecode.Format.minorVersion else {
            throw Bytecode.CodecError.unsupportedFormat(major: formatMajor, minor: formatMinor)
        }
        let minimumRuntimeMajor = try reader.read(UInt16.self)
        let flags = try reader.read(UInt16.self)
        guard flags == 0 else { throw Bytecode.CodecError.invalidHeader("unsupported flags 0x\(String(flags, radix: 16))") }
        let shellHash = try Core.Digest(bytes: try reader.readData(count: Core.Digest.byteCount))
        let imageHash = try Core.Digest(bytes: try reader.readData(count: Core.Digest.byteCount))
        let sectionCountRaw = try reader.read(UInt32.self)
        let tableOffsetRaw = try reader.read(UInt64.self)
        guard let sectionCount = Int(exactly: sectionCountRaw), sectionCount <= limits.maximumSectionCount else {
            throw Bytecode.CodecError.tooManySections(actual: Int(sectionCountRaw), maximum: limits.maximumSectionCount)
        }
        guard tableOffsetRaw == UInt64(Bytecode.Header.byteCount) else {
            throw Bytecode.CodecError.invalidHeader("section table must immediately follow v1 header")
        }

        var zeroed = bytes
        zeroed.replaceSubrange(Bytecode.Header.imageHashRange, with: repeatElement(UInt8(0), count: Core.Digest.byteCount))
        guard Core.Digest.sha256(zeroed).constantTimeEquals(imageHash) else {
            throw Bytecode.CodecError.imageHashMismatch
        }

        var entries: [Bytecode.SectionEntry] = []
        var seenKinds = Set<Bytecode.SectionKind>()
        for _ in 0..<sectionCount {
            let rawKind = try reader.read(UInt32.self)
            guard let kind = Bytecode.SectionKind(rawValue: rawKind) else {
                throw Bytecode.CodecError.unknownSection(rawKind)
            }
            guard seenKinds.insert(kind).inserted else { throw Bytecode.CodecError.duplicateSection(kind) }
            let sectionFlags = try reader.read(UInt32.self)
            guard sectionFlags == 0 else {
                throw Bytecode.CodecError.unsupportedSectionFlags(kind: kind, flags: sectionFlags)
            }
            let offset = try reader.read(UInt64.self)
            let compressedSize = try reader.read(UInt64.self)
            let uncompressedSize = try reader.read(UInt64.self)
            let hash = try Core.Digest(bytes: try reader.readData(count: Core.Digest.byteCount))
            guard compressedSize == uncompressedSize else {
                throw Bytecode.CodecError.unsupportedSectionFlags(kind: kind, flags: sectionFlags)
            }
            entries.append(
                Bytecode.SectionEntry(
                    kind: kind,
                    flags: sectionFlags,
                    offset: offset,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    sha256: hash
                )
            )
        }

        let tableEnd = reader.offset
        let requiredKinds: [Bytecode.SectionKind] = [
            .types, .imports, .functions, .code, .metadata, .debug,
        ].sorted()
        guard entries.map(\.kind) == requiredKinds else {
            throw Bytecode.CodecError.invalidHeader(
                "v1 requires exactly these ordered sections: \(requiredKinds.map(\.description).joined(separator: ", "))"
            )
        }

        var ranges: [(kind: Bytecode.SectionKind, range: Range<Int>)] = []
        var sections: [Bytecode.SectionKind: Data] = [:]
        var expectedOffset = tableEnd
        for entry in entries {
            guard let offset = Int(exactly: entry.offset),
                  let size = Int(exactly: entry.compressedSize),
                  offset >= tableEnd,
                  size <= limits.maximumSectionBytes,
                  offset <= bytes.count,
                  size <= bytes.count - offset
            else {
                if let size = Int(exactly: entry.compressedSize), size > limits.maximumSectionBytes {
                    throw Bytecode.CodecError.sectionTooLarge(
                        kind: entry.kind,
                        actual: size,
                        maximum: limits.maximumSectionBytes
                    )
                }
                throw Bytecode.CodecError.invalidSectionRange(entry.kind)
            }
            guard offset == expectedOffset else {
                throw Bytecode.CodecError.invalidSectionRange(entry.kind)
            }
            let range = offset..<(offset + size)
            for prior in ranges where prior.range.overlaps(range) {
                throw Bytecode.CodecError.overlappingSections(prior.kind, entry.kind)
            }
            let payload = bytes.subdata(in: range)
            guard Core.Digest.sha256(payload).constantTimeEquals(entry.sha256) else {
                throw Bytecode.CodecError.sectionHashMismatch(entry.kind)
            }
            ranges.append((entry.kind, range))
            sections[entry.kind] = payload
            expectedOffset = range.upperBound
        }
        guard expectedOffset == bytes.count else {
            throw Bytecode.CodecError.invalidHeader("trailing bytes are not permitted")
        }

        let module = try decodeModule(shellHash: shellHash, sections: sections)
        let canonicalBytes: Data
        do {
            canonicalBytes = try Bytecode.Encoder.encode(
                module,
                formatMinor: formatMinor
            )
        } catch {
            throw Bytecode.CodecError.invalidHeader(
                "decoded v1 image cannot be canonically re-encoded: \(error)"
            )
        }
        guard canonicalBytes == bytes else {
            throw Bytecode.CodecError.invalidHeader("v1 image is not canonically encoded")
        }
        let header = Bytecode.Header(
            formatMajor: formatMajor,
            formatMinor: formatMinor,
            minimumRuntimeMajor: minimumRuntimeMajor,
            flags: flags,
            shellInterfaceHash: shellHash,
            imageHash: imageHash,
            sectionCount: sectionCountRaw,
            sectionTableOffset: tableOffsetRaw
        )
        return Bytecode.DecodedContainer(header: header, sections: sections, module: module)
    }

    private static func decodeModule(
        shellHash: Core.Digest,
        sections: [Bytecode.SectionKind: Data]
    ) throws -> Bytecode.Module {
        let types: [Bytecode.ValueType] = try decodeRequired(.types, from: sections)
        let imports: Bytecode.WireImports = try decodeRequired(.imports, from: sections)
        let layouts: [Bytecode.WireFunctionLayout] = try decodeRequired(.functions, from: sections)
        let code: [Bytecode.Instruction] = try decodeRequired(.code, from: sections)
        let metadata: Bytecode.WireMetadata = try decodeRequired(.metadata, from: sections)
        let sourceMap: [Bytecode.SourceMapEntry] = try decodeRequired(.debug, from: sections)

        guard Set(metadata.capabilities).count == metadata.capabilities.count else {
            throw Bytecode.CodecError.malformedSection(
                kind: .metadata,
                reason: "capabilities must be unique"
            )
        }

        var claimedInstructionIndices = Set<Int>()
        var functions: [Bytecode.Function] = []
        for layout in layouts {
            guard let resultIndex = Int(exactly: layout.resultTypeIndex), types.indices.contains(resultIndex) else {
                throw Bytecode.CodecError.malformedFunctionLayout("invalid result type index for function \(layout.id)")
            }
            let registerTypes = try layout.registerTypeIndices.map { rawIndex -> Bytecode.ValueType in
                guard let index = Int(exactly: rawIndex), types.indices.contains(index) else {
                    throw Bytecode.CodecError.malformedFunctionLayout("invalid register type index for function \(layout.id)")
                }
                return types[index]
            }
            let stackSlotTypes = try layout.stackSlotTypeIndices.map { rawIndex -> Bytecode.ValueType in
                guard let index = Int(exactly: rawIndex), types.indices.contains(index) else {
                    throw Bytecode.CodecError.malformedFunctionLayout("invalid stack slot type index for function \(layout.id)")
                }
                return types[index]
            }
            var blocks: [Bytecode.Block] = []
            for block in layout.blocks {
                guard let start = Int(exactly: block.instructionStart),
                      let count = Int(exactly: block.instructionCount),
                      start <= code.count,
                      count <= code.count - start
                else {
                    throw Bytecode.CodecError.malformedFunctionLayout("invalid instruction range in \(layout.id).\(block.id)")
                }
                let range = start..<(start + count)
                for index in range where !claimedInstructionIndices.insert(index).inserted {
                    throw Bytecode.CodecError.malformedFunctionLayout("instruction \(index) is claimed more than once")
                }
                blocks.append(
                    Bytecode.Block(
                        id: block.id,
                        parameters: block.parameters,
                        instructions: Array(code[range])
                    )
                )
            }
            functions.append(
                Bytecode.Function(
                    id: layout.id,
                    name: layout.name,
                    kind: layout.kind ?? .ordinary,
                    parameterRegisters: layout.parameterRegisters,
                    parameterConventions: layout.parameterConventions,
                    resultType: types[resultIndex],
                    registerTypes: registerTypes,
                    entryBlock: layout.entryBlock,
                    blocks: blocks,
                    stackSlotTypes: stackSlotTypes,
                    effects: layout.effects,
                    sourceLocation: layout.sourceLocation
                )
            )
        }
        guard claimedInstructionIndices.count == code.count else {
            throw Bytecode.CodecError.malformedFunctionLayout("CODE contains unclaimed instructions")
        }

        return Bytecode.Module(
            name: metadata.name,
            shellInterfaceHash: shellHash,
            compatibility: metadata.compatibility,
            capabilities: Set(metadata.capabilities),
            requestedResources: metadata.requestedResources,
            localTypes: metadata.localTypes ?? [],
            functions: functions,
            entries: imports.entries,
            imports: imports.imports,
            sourceMap: sourceMap
        )
    }

    private static func decodeRequired<T: Decodable>(
        _ kind: Bytecode.SectionKind,
        from sections: [Bytecode.SectionKind: Data]
    ) throws -> T {
        guard let bytes = sections[kind] else { throw Bytecode.CodecError.missingSection(kind) }
        return try decode(T.self, bytes: bytes, kind: kind)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        bytes: Data,
        kind: Bytecode.SectionKind
    ) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: bytes)
        } catch {
            throw Bytecode.CodecError.malformedSection(kind: kind, reason: String(describing: error))
        }
    }
}
}
