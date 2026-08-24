import HelixInterface

extension CanonicalSIL {
/// Contextual restrictions on lowering source-class storage projections.
/// Most functions use unrestricted getter/setter NativeImports. Lexical
/// contexts with stronger Swift storage semantics can forbid only the exact
/// setter identities that would otherwise change behavior.
public struct NativePropertyAccessPolicy: Hashable, Sendable {
    public var forbiddenSetterSymbols: Set<String>

    public init(forbiddenSetterSymbols: Set<String> = []) {
        self.forbiddenSetterSymbols = forbiddenSetterSymbols
    }

    public static let unrestricted = Self()

    /// A direct assignment to an observed class property's own storage is
    /// nonrecursive in Swift. Replacing that projection with the ordinary
    /// setter NativeImport would re-enter the observer, so only that exact
    /// root/setter pair is denied. Calls from nested helpers keep their
    /// ordinary setter behavior.
    package static func forRoot(
        _ record: InterfaceArchive.FunctionRecord
    ) -> Self {
        guard [.willSet, .didSet].contains(record.role),
              record.parameterTypes.count
                == record.loweredSignature.parameters.count + 1,
              case .native = record.parameterTypes.last,
              record.parameterConventions.count == record.parameterTypes.count
        else { return .unrestricted }
        let components = record.canonicalDeclaration.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count >= 3,
              components.last == Substring(record.role.rawValue)
        else { return .unrestricted }
        let property = String(components[components.count - 2])
        let owner = components.dropLast(2).joined(separator: ".")
        guard !owner.isEmpty, !property.isEmpty else { return .unrestricted }
        let ownerTypes = Set([owner, "\(record.moduleName).\(owner)"])
        return .init(forbiddenSetterSymbols: Set(ownerTypes.map {
            CanonicalSIL.NativePropertySymbol.setter(
                ownerType: $0,
                property: property
            )
        }))
    }

    package func permitsSetter(_ symbol: String) -> Bool {
        !forbiddenSetterSymbols.contains(symbol)
    }
}
}
