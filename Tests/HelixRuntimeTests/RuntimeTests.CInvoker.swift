import CoreGraphics
import Foundation
import HelixBytecode
import HelixCore
import HelixRuntimeTestSupport
import Testing
@testable import HelixRuntime
@testable import HelixVM

extension RuntimeTests {
@Suite("Generic C invocation", .serialized)
struct CInvoker {
    @Test("One invoker handles scalar C functions")
    func scalarFunctions() throws {
        let fixture = try Fixture()
        let addition = try fixture.call(
            member: "HelixRuntimeTestCAdd64",
            function: unsafeBitCast(
                HelixRuntimeTestCAdd64
                    as @convention(c) (Int64, Int64) -> Int64,
                to: UnsafeRawPointer.self
            ),
            logicalParameters: ["Swift.Int64", "Swift.Int64"],
            logicalResult: "Swift.Int64",
            valueParameters: [.int64, .int64],
            valueResult: .int64,
            physicalParameters: [fixture.int64ABI, fixture.int64ABI],
            physicalResult: fixture.int64ABI
        )
        #expect(try fixture.invoke(
            addition,
            arguments: [fixture.integer(19), fixture.integer(23)]
        ) == .returned(fixture.integer(42)))

        let multiply = try fixture.call(
            member: "HelixRuntimeTestCMultiplyDouble",
            function: unsafeBitCast(
                HelixRuntimeTestCMultiplyDouble
                    as @convention(c) (Double, Double) -> Double,
                to: UnsafeRawPointer.self
            ),
            logicalParameters: ["Swift.Double", "Swift.Double"],
            logicalResult: "Swift.Double",
            valueParameters: [.float(bitWidth: 64), .float(bitWidth: 64)],
            valueResult: .float(bitWidth: 64),
            physicalParameters: [fixture.doubleABI, fixture.doubleABI],
            physicalResult: fixture.doubleABI
        )
        #expect(try fixture.invoke(
            multiply,
            arguments: [fixture.double(6), fixture.double(7)]
        ) == .returned(fixture.double(42)))
    }

    @Test("Common geometry structures cross the C ABI without an API adapter")
    func geometryStructures() throws {
        let fixture = try Fixture()
        let make = try fixture.call(
            member: "HelixRuntimeTestCMakeRect",
            function: unsafeBitCast(
                HelixRuntimeTestCMakeRect
                    as @convention(c) (Double, Double, Double, Double) -> CGRect,
                to: UnsafeRawPointer.self
            ),
            logicalParameters: Array(repeating: "Swift.Double", count: 4),
            logicalResult: fixture.rectName,
            valueParameters: Array(repeating: .float(bitWidth: 64), count: 4),
            valueResult: .native(fixture.rectID),
            physicalParameters: Array(repeating: fixture.doubleABI, count: 4),
            physicalResult: fixture.rectABI
        )
        guard case let .returned(.some(.native(rectValue))) = try fixture.invoke(
            make,
            arguments: [
                fixture.double(1), fixture.double(2),
                fixture.double(30), fixture.double(40),
            ]
        ), let rect = rectValue.value(as: CGRect.self) else {
            Issue.record("CGRect did not round-trip through native TypeOps")
            return
        }
        #expect(rect == CGRect(x: 1, y: 2, width: 30, height: 40))

        let contains = try fixture.call(
            member: "HelixRuntimeTestCRectContainsPoint",
            function: unsafeBitCast(
                HelixRuntimeTestCRectContainsPoint
                    as @convention(c) (CGRect, CGPoint) -> Bool,
                to: UnsafeRawPointer.self
            ),
            logicalParameters: [fixture.rectName, fixture.pointName],
            logicalResult: "Swift.Bool",
            valueParameters: [
                .native(fixture.rectID), .native(fixture.pointID),
            ],
            valueResult: .bool,
            physicalParameters: [fixture.rectABI, fixture.pointABI],
            physicalResult: fixture.boolABI
        )
        let point = try fixture.catalog.box(
            CGPoint(x: 10, y: 12),
            as: fixture.pointID
        )
        #expect(try fixture.invoke(
            contains,
            arguments: [.native(rectValue), .native(point)]
        ) == .returned(.bool(true)))

        let transform = CGAffineTransform(translationX: 5, y: -3)
        let transformValue = try fixture.catalog.box(
            transform,
            as: fixture.transformID
        )
        let apply = try fixture.call(
            member: "HelixRuntimeTestCApplyPointTransform",
            function: unsafeBitCast(
                HelixRuntimeTestCApplyPointTransform
                    as @convention(c) (CGPoint, CGAffineTransform) -> CGPoint,
                to: UnsafeRawPointer.self
            ),
            logicalParameters: [fixture.pointName, fixture.transformName],
            logicalResult: fixture.pointName,
            valueParameters: [
                .native(fixture.pointID), .native(fixture.transformID),
            ],
            valueResult: .native(fixture.pointID),
            physicalParameters: [fixture.pointABI, fixture.transformABI],
            physicalResult: fixture.pointABI
        )
        guard case let .returned(.some(.native(transformed))) = try fixture.invoke(
            apply,
            arguments: [.native(point), .native(transformValue)]
        ), let transformedPoint = transformed.value(as: CGPoint.self) else {
            Issue.record("CGPoint transform result did not decode")
            return
        }
        #expect(transformedPoint == CGPoint(x: 15, y: 9))
    }

    @Test("Catalog identity and the finite trampoline matrix fail closed")
    func validationFailures() throws {
        let fixture = try Fixture()
        let valid = try fixture.call(
            member: "HelixRuntimeTestCAdd64",
            function: unsafeBitCast(
                HelixRuntimeTestCAdd64
                    as @convention(c) (Int64, Int64) -> Int64,
                to: UnsafeRawPointer.self
            ),
            logicalParameters: ["Swift.Int64", "Swift.Int64"],
            logicalResult: "Swift.Int64",
            valueParameters: [.int64, .int64],
            valueResult: .int64,
            physicalParameters: [fixture.int64ABI, fixture.int64ABI],
            physicalResult: fixture.int64ABI,
            keyOverride: .init(rawValue: .sha256("wrong C key"))
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                valid,
                arguments: [fixture.integer(1), fixture.integer(2)]
            )
        }

        let mixed = try fixture.call(
            member: "HelixRuntimeTestCMultiplyDouble",
            function: unsafeBitCast(
                HelixRuntimeTestCMultiplyDouble
                    as @convention(c) (Double, Double) -> Double,
                to: UnsafeRawPointer.self
            ),
            logicalParameters: ["Swift.Double", "Swift.Int64"],
            logicalResult: "Swift.Double",
            valueParameters: [.float(bitWidth: 64), .int64],
            valueResult: .float(bitWidth: 64),
            physicalParameters: [fixture.doubleABI, fixture.int64ABI],
            physicalResult: fixture.doubleABI
        )
        #expect(throws: VM.RuntimeTrap.self) {
            _ = try fixture.invoke(
                mixed,
                arguments: [fixture.double(1), fixture.integer(2)]
            )
        }
    }
}
}

private extension RuntimeTests.CInvoker {
    struct Call {
        var invoker: Runtime.CInvoker
        var effects: Core.Effects
        var contract: Core.NativeImportContract
    }

    struct Fixture {
        let pointID = Core.TypeID(rawValue: .sha256("CInvoker.CGPoint"))
        let rectID = Core.TypeID(rawValue: .sha256("CInvoker.CGRect"))
        let transformID = Core.TypeID(rawValue: .sha256("CInvoker.CGAffineTransform"))
        let pointName = "CoreGraphics.CGPoint"
        let rectName = "CoreGraphics.CGRect"
        let transformName = "CoreGraphics.CGAffineTransform"
        let catalog: VM.NativeTypeCatalog

        init() throws {
            catalog = try .init([
                .objectiveCStructure(
                    id: pointID,
                    canonicalName: pointName,
                    layoutFingerprint: .sha256("CInvoker.CGPoint.Layout"),
                    encoding: "{CGPoint=dd}",
                    clone: { (value: CGPoint) in value }
                ),
                .objectiveCStructure(
                    id: rectID,
                    canonicalName: rectName,
                    layoutFingerprint: .sha256("CInvoker.CGRect.Layout"),
                    encoding: "{CGRect={CGPoint=dd}{CGSize=dd}}",
                    clone: { (value: CGRect) in value }
                ),
                .objectiveCStructure(
                    id: transformID,
                    canonicalName: transformName,
                    layoutFingerprint: .sha256("CInvoker.Transform.Layout"),
                    encoding: "{CGAffineTransform=dddddd}",
                    clone: { (value: CGAffineTransform) in value }
                ),
            ])
        }

        var boolABI: Core.NativeCall.ABIType {
            .init(
                kind: .boolean,
                canonicalName: "Swift.Bool",
                size: 1,
                alignment: 1,
                encoding: "B"
            )
        }

        var int64ABI: Core.NativeCall.ABIType {
            .init(
                kind: .signedInteger,
                canonicalName: "Swift.Int64",
                size: 8,
                alignment: 8,
                encoding: "q"
            )
        }

        var doubleABI: Core.NativeCall.ABIType {
            .init(
                kind: .floatingPoint,
                canonicalName: "Swift.Double",
                size: 8,
                alignment: 8,
                encoding: "d"
            )
        }

        var pointABI: Core.NativeCall.ABIType {
            structureABI(
                canonicalName: pointName,
                size: MemoryLayout<CGPoint>.size,
                alignment: MemoryLayout<CGPoint>.alignment,
                encoding: "{CGPoint=dd}"
            )
        }

        var rectABI: Core.NativeCall.ABIType {
            structureABI(
                canonicalName: rectName,
                size: MemoryLayout<CGRect>.size,
                alignment: MemoryLayout<CGRect>.alignment,
                encoding: "{CGRect={CGPoint=dd}{CGSize=dd}}"
            )
        }

        var transformABI: Core.NativeCall.ABIType {
            structureABI(
                canonicalName: transformName,
                size: MemoryLayout<CGAffineTransform>.size,
                alignment: MemoryLayout<CGAffineTransform>.alignment,
                encoding: "{CGAffineTransform=dddddd}"
            )
        }

        func structureABI(
            canonicalName: String,
            size: Int,
            alignment: Int,
            encoding: String
        ) -> Core.NativeCall.ABIType {
            .init(
                kind: .structure,
                canonicalName: canonicalName,
                size: UInt16(size),
                alignment: UInt16(alignment),
                encoding: encoding
            )
        }

        func integer(_ value: Int64) throws -> VM.Value {
            .integer(try .init(signed: value, bitWidth: 64, isSigned: true))
        }

        func double(_ value: Double) -> VM.Value {
            .float(.init(value))
        }

        func call(
            member: String,
            function: UnsafeRawPointer,
            logicalParameters: [String],
            logicalResult: String,
            valueParameters: [Bytecode.ValueType],
            valueResult: Bytecode.ValueType,
            physicalParameters: [Core.NativeCall.ABIType],
            physicalResult: Core.NativeCall.ABIType,
            keyOverride: Core.NativeCall.Key? = nil
        ) throws -> Call {
            let effects = Core.Effects()
            let contract = Core.NativeImportContract.bounded(
                kind: .globalFunction,
                domain: .application,
                access: .pure,
                maximumDurationMicroseconds: 2_000,
                allowsMainThread: true
            )
            let signature = Core.LoweredSignature(
                parameters: logicalParameters,
                result: logicalResult
            )
            let descriptor = try Core.NativeCall.Descriptor.cFunction(
                module: "HelixRuntimeTestSupport",
                member: member,
                symbol: member,
                signature: signature,
                effects: effects,
                contract: contract,
                argumentLabels: Array(repeating: "_", count: logicalParameters.count),
                physicalSignature: .init(
                    callingConvention: .c,
                    parameters: physicalParameters.enumerated().map {
                        .init(type: $0.element, source: .argument(UInt16($0.offset)))
                    },
                    result: physicalResult
                )
            )
            let derivedKey = try Core.NativeCall.Key.derive(
                descriptor: descriptor
            )
            let key = keyOverride ?? derivedKey
            return .init(
                invoker: .init(
                    id: .init(rawValue: 1),
                    key: key,
                    descriptor: descriptor,
                    function: function,
                    parameterTypes: valueParameters,
                    resultType: valueResult,
                    effects: effects,
                    contract: contract
                ),
                effects: effects,
                contract: contract
            )
        }

        func invoke(
            _ call: Call,
            arguments: [VM.Value]
        ) throws -> VM.NativeInvocationResult {
            let budget = VM.InvocationBudget(
                limits: .init(maxWallTimeMainThreadMilliseconds: 1_000),
                isMainThread: Thread.isMainThread,
                nowNanoseconds: { 0 }
            )
            let context = try budget.beginNativeInvocation(
                id: call.invoker.id,
                effects: call.effects,
                contract: call.contract,
                parameterTypes: call.invoker.parameterTypes,
                nativeTypeCatalog: catalog,
                isMainThread: Thread.isMainThread
            )
            do {
                let result = try call.invoker.invoke(
                    arguments: arguments,
                    context: context
                )
                try context.finish(requireCooperation: false)
                return result
            } catch {
                try? context.finish(requireCooperation: false)
                throw error
            }
        }
    }
}
