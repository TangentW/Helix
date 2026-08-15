import Foundation
#if canImport(HelixCore)
import HelixBytecode
#endif

extension VM {
/// Runtime shape shared by frame-owned addresses and heap-promoted mutable
/// cells. Aggregate fields may be initialized independently before the root
/// value becomes readable.
indirect enum StorageShape: Sendable {
    case leaf
    case tuple([VM.StorageShape])
    case structure(Bytecode.LocalTypeKey, [VM.StorageShape])

    var nodeCount: Int? {
        let children: [VM.StorageShape]
        switch self {
        case .leaf:
            return 1
        case let .tuple(elements):
            children = elements
        case let .structure(_, fields):
            children = fields
        }
        var result = 1
        for child in children {
            guard let count = child.nodeCount else { return nil }
            let addition = result.addingReportingOverflow(count)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }
}
}
