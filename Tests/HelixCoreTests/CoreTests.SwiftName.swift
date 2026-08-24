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

    @Test("Compiler-normalized keywords render as safe source identifiers")
    func rendersEscapedIdentifiers() {
        #expect(Core.SwiftName.escapedIdentifier("value") == "value")
        #expect(Core.SwiftName.escapedIdentifier("default") == "`default`")
        #expect(Core.SwiftName.escapedIdentifier("in") == "`in`")
        #expect(Core.SwiftName.escapedIdentifier("set") == "`set`")
        #expect(Core.SwiftName.escapedIdentifier("1value") == nil)
        #expect(Core.SwiftName.escapedIdentifier("value.other") == nil)
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
