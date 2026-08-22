import Testing
@testable import HelixCore

extension CoreTests {
@Suite("Swift source name validation")
struct SwiftName {
    @Test("Escaped identifiers normalize without accepting injected syntax")
    func normalizesEscapedIdentifiers() {
        #expect(Core.SwiftName.normalizedIdentifier("value") == "value")
        #expect(Core.SwiftName.normalizedIdentifier("`default`") == "default")
        #expect(Core.SwiftName.normalizedIdentifier("``") == nil)
        #expect(Core.SwiftName.normalizedIdentifier("`1value`") == nil)
        #expect(Core.SwiftName.normalizedIdentifier("`value`.other") == nil)
        #expect(Core.SwiftName.normalizedIdentifier("`value\n`") == nil)
    }

    @Test("Operator validation accepts source operators but rejects delimiters")
    func validatesOperators() {
        for value in ["+", "...", "..<", "??", "<=>"] {
            #expect(Core.SwiftName.isOperator(value))
        }
        for value in ["", "+.", "//", "/*", "*/", "a+b"] {
            #expect(!Core.SwiftName.isOperator(value))
        }
    }
}
}
