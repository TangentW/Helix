import Foundation

extension InterfaceArchive {
/// Frozen evidence for a physical Swift argument that a generated native
/// invoker supplies at the source level. The origin is part of call selection:
/// a patch may erase a physical value only when canonical SIL proves the same
/// compiler-generated default form.
public struct NativeImportDefaultArgument: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Hashable, Sendable {
        case externalGenerator
        case optionalNone
    }

    public var physicalParameterIndex: UInt16
    public var origin: Origin
    public var generatorSymbol: String?

    public init(
        physicalParameterIndex: UInt16,
        origin: Origin,
        generatorSymbol: String? = nil
    ) {
        self.physicalParameterIndex = physicalParameterIndex
        self.origin = origin
        self.generatorSymbol = generatorSymbol
    }

    public static func externalGenerator(
        physicalParameterIndex: UInt16,
        symbol: String
    ) -> Self {
        .init(
            physicalParameterIndex: physicalParameterIndex,
            origin: .externalGenerator,
            generatorSymbol: symbol
        )
    }

    public static func optionalNone(
        physicalParameterIndex: UInt16
    ) -> Self {
        .init(
            physicalParameterIndex: physicalParameterIndex,
            origin: .optionalNone
        )
    }

    fileprivate var isValid: Bool {
        switch origin {
        case .externalGenerator:
            guard let generatorSymbol, !generatorSymbol.isEmpty else {
                return false
            }
            return generatorSymbol.utf8.allSatisfy { byte in
                byte > 0x20 && byte != 0x3a && byte != 0x40
            }
        case .optionalNone:
            return generatorSymbol == nil
        }
    }
}

/// Maps the value parameters exposed by a generated NativeImport onto the
/// canonical-SIL value parameters of the imported declaration. Swift always
/// applies a declaration's full SIL ABI, even when source arguments use
/// defaults; the generated Swift invoker intentionally exposes only the
/// source arguments represented by the frozen logical call variant.
public struct NativeImportParameterProjection: Codable, Hashable, Sendable {
    /// Absent means the shipped order-preserving v1 projection. Version 2
    /// additionally permits a bijective permutation of the selected slots.
    /// Older readers reject permutations under their v1 validation rules.
    public var argumentOrderVersion: UInt16?
    public var physicalParameterCount: UInt16
    public var logicalParameterIndices: [UInt16]
    public var defaultArguments: [InterfaceArchive.NativeImportDefaultArgument]

    public init(
        physicalParameterCount: UInt16,
        logicalParameterIndices: [UInt16],
        defaultArguments: [InterfaceArchive.NativeImportDefaultArgument] = []
    ) {
        self.physicalParameterCount = physicalParameterCount
        self.logicalParameterIndices = logicalParameterIndices
        argumentOrderVersion = logicalParameterIndices == logicalParameterIndices.sorted() ? nil : 2
        self.defaultArguments = defaultArguments.sorted {
            $0.physicalParameterIndex < $1.physicalParameterIndex
        }
    }

    public static func identity(parameterCount: Int) -> Self {
        guard let count = UInt16(exactly: parameterCount) else {
            // Archive validation rejects this deliberately invalid sentinel.
            return .init(physicalParameterCount: 0, logicalParameterIndices: [])
        }
        return .init(
            physicalParameterCount: count,
            logicalParameterIndices: (0..<count).map { $0 },
            defaultArguments: []
        )
    }

    public func isValid(logicalParameterCount: Int) -> Bool {
        let omitted = omittedPhysicalParameterIndices
        guard logicalParameterIndices.count == logicalParameterCount,
              Set(logicalParameterIndices).count == logicalParameterIndices.count,
              (argumentOrderVersion == nil && logicalParameterIndices == logicalParameterIndices.sorted()
                || argumentOrderVersion == 2),
              logicalParameterIndices.allSatisfy({ $0 < physicalParameterCount }),
              defaultArguments.map(\.physicalParameterIndex) == omitted,
              defaultArguments.allSatisfy(\.isValid)
        else { return false }
        return logicalParameterCount == 0 || physicalParameterCount > 0
    }

    public var omittedPhysicalParameterIndices: [UInt16] {
        let selected = Set(logicalParameterIndices)
        return (0..<physicalParameterCount).filter { !selected.contains($0) }
    }
}
}
