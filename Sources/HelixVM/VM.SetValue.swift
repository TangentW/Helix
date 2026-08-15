#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
public struct SetValue: Hashable, Sendable, CustomStringConvertible {
    private final class Storage: Sendable {
        let elements: [VM.Value]
        let elementType: Bytecode.ValueType

        init(elements: [VM.Value], elementType: Bytecode.ValueType) {
            self.elements = elements
            self.elementType = elementType
        }
    }

    private let storage: Storage

    public var elements: [VM.Value] { storage.elements }
    public var elementType: Bytecode.ValueType { storage.elementType }

    public init(elements: [VM.Value], elementType: Bytecode.ValueType) {
        guard elementType.isVMHashable else {
            storage = .init(elements: elements, elementType: elementType)
            return
        }
        var seen = Set<VM.HashableValue>()
        seen.reserveCapacity(elements.count)
        var unique: [VM.Value] = []
        unique.reserveCapacity(elements.count)
        for element in elements {
            guard element.matches(elementType) else {
                unique.append(element)
                continue
            }
            if seen.insert(.init(value: element)).inserted {
                unique.append(element)
            }
        }
        storage = .init(elements: unique, elementType: elementType)
    }

    init(uncheckedElements: [VM.Value], elementType: Bytecode.ValueType) {
        storage = .init(elements: uncheckedElements, elementType: elementType)
    }

    func sharesStorage(with other: Self) -> Bool {
        storage === other.storage
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.storage === rhs.storage { return true }
        guard lhs.elementType == rhs.elementType,
              lhs.elements.count == rhs.elements.count,
              lhs.elementType.isVMHashable,
              lhs.elements.allSatisfy({ $0.matches(lhs.elementType) }),
              rhs.elements.allSatisfy({ $0.matches(rhs.elementType) })
        else { return false }
        var rhsIndex = Set<VM.HashableValue>()
        rhsIndex.reserveCapacity(rhs.elements.count)
        for element in rhs.elements {
            rhsIndex.insert(.init(value: element))
        }
        return lhs.elements.allSatisfy {
            rhsIndex.contains(.init(value: $0))
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(elementType)
        hasher.combine(elements.count)
        var xor: UInt = 0
        var sum: UInt = 0
        for value in elements {
            guard elementType.isVMHashable, value.matches(elementType) else {
                hasher.combine(UInt8.max)
                continue
            }
            var elementHasher = Hasher()
            VM.HashableValue(value: value).hash(into: &elementHasher)
            let digest = UInt(bitPattern: elementHasher.finalize())
            xor ^= digest
            sum &+= digest
        }
        hasher.combine(xor)
        hasher.combine(sum)
    }

    public var description: String {
        "Set([\(elements.map(\.description).joined(separator: ", "))])"
    }
}
}
