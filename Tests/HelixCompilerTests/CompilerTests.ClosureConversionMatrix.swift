import HelixBytecode
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("Swift closure conversion matrix")
struct ClosureConversionMatrix {
    @Test("Function conversions inject Optional arguments and results")
    func lowersOptionalFunctionConversions() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private func increment(_ value: Int) -> Int { value + 1 }
            private func unwrap(_ value: Int?) -> Int { value ?? -10 }

            public func optionalFunctionConversions(_ value: Int) -> Int {
                let optionalResult: (Int) -> Int? = increment
                let requiredInput: (Int) -> Int = unwrap
                return optionalResult(value)! + requiredInput(value)
            }
            """,
            functionName: "optionalFunctionConversions",
            moduleName: "HelixOptionalFunctionConversionFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(9))
    }

    @Test("Function results erase to Any through a concrete Swift thunk")
    func lowersAnyResultFunctionConversion() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private func increment(_ value: Int) -> Int { value + 1 }

            public func anyResultFunctionConversion(_ value: Int) -> Int {
                let erased: (Int) -> Any = increment
                return erased(value) as! Int
            }
            """,
            functionName: "anyResultFunctionConversion",
            moduleName: "HelixAnyResultFunctionConversionFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(5))
    }

    @Test("Enum case constructors form ordinary closure values")
    func lowersEnumCaseConstructorReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Choice {
                case value(Int)
                case empty
            }

            public func enumCaseConstructorReference(_ value: Int) -> Int {
                let make: (Int) -> Choice = Choice.value
                switch make(value) {
                case let .value(result): return result + 1
                case .empty: return -1
                }
            }
            """,
            functionName: "enumCaseConstructorReference",
            moduleName: "HelixEnumCaseConstructorFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(5))
    }

    @Test("Enum case constructors preserve labeled and tuple payloads")
    func lowersEnumCaseConstructorPayloadShapes() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Choice {
                case labeled(left: Int, right: Int)
                case tuple((Int, Int))
            }

            public func enumCaseConstructorPayloadShapes(_ value: Int) -> Int {
                let labeled = Choice.labeled
                let tuple = Choice.tuple
                let first: Int
                switch labeled(value, value + 1) {
                case let .labeled(left, right): first = left + right
                case .tuple: first = -100
                }
                let second: Int
                switch tuple((value + 2, value + 3)) {
                case let .tuple(pair): second = pair.0 + pair.1
                case .labeled: second = -100
                }
                return first + second
            }
            """,
            functionName: "enumCaseConstructorPayloadShapes",
            moduleName: "HelixEnumCasePayloadFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(22))
    }

    @Test("Optional and Result case constructors specialize into closures")
    func lowersGenericEnumCaseConstructorReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private enum Failure: Error { case rejected }

            public func genericEnumCaseConstructorReferences(_ value: Int) -> Int {
                let optional: (Int) -> Int? = Optional.some
                let success: (Int) -> Result<Int, Failure> = Result.success
                let first = optional(value) ?? -100
                switch success(value + 1) {
                case let .success(second): return first + second
                case .failure: return -100
                }
            }
            """,
            functionName: "genericEnumCaseConstructorReferences",
            moduleName: "HelixGenericEnumCaseConstructorFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(9))
    }

    @Test("Custom initializers and static factories form closure values")
    func lowersNominalFactoryReferences() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Point {
                let x: Int
                let y: Int

                init(_ x: Int, _ y: Int) {
                    self.x = x + 1
                    self.y = y + 2
                }

                static func shifted(_ value: Int) -> Point {
                    Point(value + 3, value + 4)
                }
            }

            public func nominalFactoryReferences(_ value: Int) -> Int {
                let initialize: (Int, Int) -> Point = Point.init
                let make: (Int) -> Point = Point.shifted
                let first = initialize(value, value)
                let second = make(value)
                return first.x + first.y + second.x + second.y
            }
            """,
            functionName: "nominalFactoryReferences",
            moduleName: "HelixNominalFactoryReferenceFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(29))
    }

    @Test("Custom initializer build regions preserve managed field ownership")
    func lowersManagedInitializerBuildRegions() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Label {
                let prefix: String
                let decorated: String

                init(_ value: String) {
                    self.prefix = value + "a"
                    self.decorated = self.prefix + "b"
                }
            }

            public func managedInitializerBuildRegion(_ value: Int) -> Int {
                let make: (String) -> Label = Label.init
                let label = make("x")
                return value + label.prefix.count * 10 + label.decorated.count
            }
            """,
            functionName: "managedInitializerBuildRegion",
            moduleName: "HelixManagedInitializerBuildRegionFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(27))
    }

    @Test("Captured metatype identity mismatches fail closed")
    func rejectsMismatchedCapturedMetatypes() throws {
        for actualType in ["String", "Int64"] {
            let function = CanonicalSIL.Function(
                mangledName: "$s7Fixture8mismatchyS2iF",
                loweredType: "@convention(thin) (Int, @thin Int.Type) -> Int",
                body: """
                bb0(%0 : $Int, %1 : @closureCapture $@thin \(actualType).Type):
                  return %0
                """
            )

            #expect(throws: CanonicalSIL.LoweringError.self) {
                _ = try CanonicalSIL.Lowerer().lower(
                    function,
                    displayName: "mismatch"
                )
            }
        }
    }

    @Test("Partial applications validate erased metatype captures")
    func rejectsMismatchedPartialApplyMetatypes() throws {
        let symbol = "$s7Fixture4makeyS2i_SimtF"
        let calls = try CanonicalSIL.DirectCallTable([
            .init(
                mangledName: symbol,
                parameterTypes: [.int64],
                resultType: .int64,
                target: .function(.init(rawValue: 1))
            ),
        ])
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture3runyyF",
            loweredType: "@convention(thin) () -> ()",
            body: """
            bb0:
              %0 = function_ref @\(symbol) : $@convention(method) (Int, @thin Int.Type) -> Int
              %1 = metatype $@thin Int64.Type
              %2 = partial_apply [callee_guaranteed] %0(%1) : $@convention(method) (Int, @thin Int.Type) -> Int
              destroy_value %2
              %3 = tuple ()
              return %3
            """
        )

        #expect(throws: CanonicalSIL.LoweringError.self) {
            _ = try CanonicalSIL.Lowerer().lower(
                function,
                displayName: "partialApplyMetatypeMismatch",
                directCalls: calls
            )
        }
    }

    @Test("Compiler-only captured metatypes survive SIL borrow aliases")
    func lowersCapturedMetatypeBorrowAliases() throws {
        let function = CanonicalSIL.Function(
            mangledName: "$s7Fixture5aliasyS2iF",
            loweredType: "@convention(thin) (Int, @thin Swift.Int.Type) -> Int",
            body: """
            bb0(%0 : $Int, %1 : @closureCapture $@thin Int.Type):
              %2 = begin_borrow %1
              end_borrow %2
              return %0
            """
        )

        let lowered = try CanonicalSIL.Lowerer().lower(
            function,
            displayName: "alias"
        )
        let parameter = try #require(lowered.parameterRegisters.first)
        let expected: Bytecode.ValueType = .integer(bitWidth: 64, signed: true)
        #expect(lowered.parameterRegisters.count == 1)
        #expect(
            lowered.registerTypes[Int(parameter.rawValue)] == expected
        )
    }

    @Test("Outer function syntax ignores arrows in nested closure results")
    func parsesNestedFunctionResultsStructurally() throws {
        let type = "@convention(thin) (@thin Choice.Type) "
            + "-> @owned @callee_guaranteed (Int) -> Choice"
        let arrow = try #require(
            CanonicalSIL.FunctionTypeSyntax.outerArrow(in: type)
        )
        #expect(
            type[arrow.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                == "@owned @callee_guaranteed (Int) -> Choice"
        )

        #expect(
            CanonicalSIL.FunctionTypeSyntax.outerArrow(
                in: "@convention(thin) ((Int) -> String, [Int: String]) -> Bool"
            ) != nil
        )
        #expect(
            CanonicalSIL.FunctionTypeSyntax.outerArrow(
                in: "@convention(thin) ((Int) -> String] -> Bool"
            ) == nil
        )
    }

    @Test("callAsFunction supports direct and bound callable values")
    func lowersCallAsFunctionValues() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private struct Adder {
                let offset: Int

                func callAsFunction(_ value: Int) -> Int {
                    value + offset
                }
            }

            public func callableValue(_ value: Int) -> Int {
                let adder = Adder(offset: 3)
                let bound: (Int) -> Int = adder.callAsFunction
                return adder(value) + bound(value)
            }
            """,
            functionName: "callableValue",
            moduleName: "HelixCallableValueFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(14))
    }

    @Test("Closure typealiases preserve escaping storage and invocation")
    func lowersClosureTypealiases() throws {
        let fixture = try FrontendExecutionHarness.compile(
            source: """
            private typealias Transform<Input, Output> = (Input) -> Output

            @inline(never)
            private func store(
                _ transform: @escaping Transform<Int, Int>
            ) -> Transform<Int, Int> {
                transform
            }

            public func closureTypealias(_ value: Int) -> Int {
                let transform: Transform<Int, Int> = { $0 * 2 }
                return store(transform)(value)
            }
            """,
            functionName: "closureTypealias",
            moduleName: "HelixClosureTypealiasFixture"
        )

        #expect(try invoke(fixture, [integer(4)]) == integer(8))
    }

    private func invoke(
        _ fixture: FrontendExecutionHarness.Fixture,
        _ arguments: [VM.Value]
    ) throws -> VM.Value {
        let outcome = VM.Interpreter().invoke(
            entry: fixture.entry,
            image: fixture.image,
            arguments: arguments
        )
        guard case let .returned(value) = outcome else {
            Issue.record("expected returned value, got \(outcome)")
            return try integer(0)
        }
        return try #require(value)
    }

    private func integer(_ value: Int64) throws -> VM.Value {
        .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
    }
}
}
