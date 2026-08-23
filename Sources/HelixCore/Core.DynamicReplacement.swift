import Foundation

extension Core {
/// Typed Swift declaration metadata shared by Release Bridge generation and
/// Native Dynamic Replacement. Swift replaces properties and subscripts at
/// declaration granularity, even though Helix tracks each accessor as its own
/// executable entry.
public enum DynamicReplacement {}
}

extension Core.DynamicReplacement {
public enum DeclarationKind: String, Codable, Hashable, Sendable {
    case function
    case property
    case subscriptDeclaration
    case propertyObservers
}

public enum MemberRole: String, Codable, Hashable, Sendable, CaseIterable {
    case functionBody
    case getter
    case setter
    case willSet
    case didSet

    public var order: Int {
        switch self {
        case .functionBody: 0
        case .getter: 1
        case .setter: 2
        case .willSet: 3
        case .didSet: 4
        }
    }
}

public struct Member: Codable, Hashable, Sendable {
    public var role: Core.DynamicReplacement.MemberRole
    /// Empty only for a function body. Accessors retain source-level modifiers
    /// such as `mutating get` and custom observer parameter names.
    public var header: String
    /// A complete accessor body used when another member of the same Swift
    /// declaration is replaced. It must call the previous implementation.
    public var fallbackBody: String

    public init(
        role: Core.DynamicReplacement.MemberRole,
        header: String = "",
        fallbackBody: String
    ) {
        self.role = role
        self.header = header
        self.fallbackBody = fallbackBody
    }
}

public struct Declaration: Codable, Hashable, Sendable {
    /// The typed frontend's declaration USR. It groups accessor function keys
    /// without relying on source spelling or byte offsets.
    public var identity: String
    public var kind: Core.DynamicReplacement.DeclarationKind
    public var originalReference: String
    public var replacementHeader: String
    public var members: [Core.DynamicReplacement.Member]
    public var enclosingPrefix: String
    public var enclosingSuffix: String

    public init(
        identity: String,
        kind: Core.DynamicReplacement.DeclarationKind,
        originalReference: String,
        replacementHeader: String,
        members: [Core.DynamicReplacement.Member],
        enclosingPrefix: String = "",
        enclosingSuffix: String = ""
    ) {
        self.identity = identity
        self.kind = kind
        self.originalReference = originalReference
        self.replacementHeader = replacementHeader
        self.members = members.sorted { $0.role.order < $1.role.order }
        self.enclosingPrefix = enclosingPrefix
        self.enclosingSuffix = enclosingSuffix
    }

    public func member(
        _ role: Core.DynamicReplacement.MemberRole
    ) -> Core.DynamicReplacement.Member? {
        members.first { $0.role == role }
    }

    /// This validates the closed declaration grammar needed by generators. It
    /// deliberately does not attempt to parse arbitrary Swift source.
    public var isWellFormed: Bool {
        let strings = [
            identity, originalReference, replacementHeader,
            enclosingPrefix, enclosingSuffix,
        ] + members.flatMap { [$0.header, $0.fallbackBody] }
        guard identity.hasPrefix("s:"),
              !originalReference.isEmpty,
              !replacementHeader.isEmpty,
              strings.allSatisfy(Self.isBoundText),
              enclosingPrefix.isEmpty == enclosingSuffix.isEmpty,
              !members.isEmpty,
              members.allSatisfy({ !$0.fallbackBody.isEmpty }),
              members == members.sorted(by: { $0.role.order < $1.role.order }),
              Set(members.map(\.role)).count == members.count
        else { return false }

        let roles = Set(members.map(\.role))
        switch kind {
        case .function:
            return roles == [.functionBody]
                && members[0].header.isEmpty
                && replacementHeader.range(
                    of: #"\bfunc\s+"#,
                    options: .regularExpression
                ) != nil
        case .property:
            return roles.contains(.getter)
                && roles.isSubset(of: [.getter, .setter])
                && members.allSatisfy({ !$0.header.isEmpty })
                && replacementHeader.range(
                    of: #"\bvar\s+"#,
                    options: .regularExpression
                ) != nil
        case .subscriptDeclaration:
            return roles.contains(.getter)
                && roles.isSubset(of: [.getter, .setter])
                && members.allSatisfy({ !$0.header.isEmpty })
                && replacementHeader.range(
                    of: #"\bsubscript\s*\("#,
                    options: .regularExpression
                ) != nil
        case .propertyObservers:
            return roles.isSubset(of: [.willSet, .didSet])
                && members.allSatisfy({ !$0.header.isEmpty })
                && replacementHeader.range(
                    of: #"\bvar\s+"#,
                    options: .regularExpression
                ) != nil
        }
    }

    private static func isBoundText(_ value: String) -> Bool {
        value.utf8.count <= 64 * 1_024
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}
}
