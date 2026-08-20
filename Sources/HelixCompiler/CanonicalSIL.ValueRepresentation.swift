import HelixBytecode

extension CanonicalSIL {
/// Distinguishes an absent function result from Swift's materialized `()`
/// value. HLBC uses the empty tuple for the latter, which lets zero-sized
/// values participate in aggregates without inventing API-specific sentinels.
enum ValueRepresentation {
    static let unit = Bytecode.ValueType.tuple([])

    static func storable(
        _ type: Bytecode.ValueType
    ) -> Bytecode.ValueType {
        switch type {
        case .void:
            unit
        case let .array(element):
            .array(storable(element))
        case let .dictionary(key, value):
            .dictionary(key: storable(key), value: storable(value))
        case let .set(element):
            .set(storable(element))
        case let .optional(wrapped):
            .optional(storable(wrapped))
        case let .tuple(elements):
            .tuple(elements.map(storable))
        case let .address(pointee):
            .address(storable(pointee))
        case let .mutableCell(pointee):
            .mutableCell(storable(pointee))
        case let .arrayBuilder(element):
            .arrayBuilder(storable(element))
        case let .arraySortState(element):
            .arraySortState(storable(element))
        case let .closure(signature):
            .closure(
                .init(
                    parameters: signature.parameters.map(storable),
                    parameterConventions: signature.parameterConventions,
                    result: signature.result,
                    effects: signature.effects
                )
            )
        case .never, .bool, .integer, .float, .string, .any, .native,
             .local, .error:
            type
        }
    }

}
}
