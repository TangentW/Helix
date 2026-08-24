import HelixCore

extension ShellBuildReceipt {
/// Identifies one exact source body that the Shell build replaces with a
/// permanent dispatch wrapper. The source baseline hash protects the whole
/// file; this local hash additionally binds the semantic edit to its braces.
public struct SourceBodyTransform: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case propertyObserver = "property-observer"
        case asynchronousFunction = "asynchronous-function"
    }

    public var kind: Kind
    public var openingBraceUTF8Offset: Int
    public var closingBraceUTF8Offset: Int
    public var expectedBodyHash: Core.Digest

    public init(
        kind: Kind,
        openingBraceUTF8Offset: Int,
        closingBraceUTF8Offset: Int,
        expectedBodyHash: Core.Digest
    ) {
        self.kind = kind
        self.openingBraceUTF8Offset = openingBraceUTF8Offset
        self.closingBraceUTF8Offset = closingBraceUTF8Offset
        self.expectedBodyHash = expectedBodyHash
    }
}
}
