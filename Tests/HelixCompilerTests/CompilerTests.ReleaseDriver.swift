import Foundation
import HelixBytecode
import HelixCore
import HelixInterface
import HelixVerifier
import HelixVM
import Testing
@testable import HelixCompiler

extension CompilerTests {
@Suite("ReleaseCompiler.Driver")
struct ReleaseDriver {
    private enum HelperExposure {
        case shellEntry
        case nativeImport
    }

    private struct IncrementInvoker: VM.NativeInvoker {
        let id: Core.NativeImportID
        let key: Core.NativeImportKey
        let effects: Core.Effects
        let contract: Core.NativeImportContract
        let parameterTypes: [Bytecode.ValueType] = [.int64]
        let resultType: Bytecode.ValueType = .int64

        func invoke(
            arguments: [VM.Value],
            context: VM.NativeInvocationContext
        ) -> VM.NativeInvocationResult {
            guard arguments.count == 1,
                  case let .integer(value) = arguments[0],
                  let result = try? VM.Integer(
                      signed: value.signedValue + 10,
                      bitWidth: 64,
                      isSigned: true
                  )
            else { return .businessError("invalid fixture argument") }
            return .returned(.integer(result))
        }
    }

    #if os(macOS)
    @Test("The system Swift proxy and selected Xcode frontend share one fingerprint")
    func canonicalizesSwiftProxy() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swiftc"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let driver = ReleaseCompiler.Driver()

        let proxy = try driver.toolchainIdentity(
            compilerURL: URL(fileURLWithPath: "/usr/bin/swiftc")
        )
        let selected = try driver.toolchainIdentity(
            compilerURL: URL(fileURLWithPath: path)
        )
        var targetEnvironment = ProcessInfo.processInfo.environment
        targetEnvironment["SDKROOT"] = "/nonexistent/SelectedSDK.sdk"
        targetEnvironment["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
        let fromXcodeTarget = try driver.toolchainIdentity(
            compilerURL: URL(fileURLWithPath: path),
            environment: targetEnvironment
        )

        #expect(process.terminationStatus == 0)
        #expect(proxy.fingerprint == selected.fingerprint)
        #expect(selected.fingerprint == fromXcodeTarget.fingerprint)
        #expect(proxy.compilerBinaryHash == selected.compilerBinaryHash)
    }
    #endif

    @Test("A saved Swift edit is detected, compiled, verified, and executed")
    func buildsChangedSwiftSourceAndRejectsChangedIneligibleCode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        public func transform(_ x: Int) -> Int { x + 1 }
        public func locked(_ x: Int) -> Int { x + 2 }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let driver = ReleaseCompiler.Driver()
        let toolchain = try driver.toolchainIdentity()
        #expect(toolchain.fingerprint.hasPrefix("sha256:"))
        #expect(toolchain.compilerBinaryHash.hex.count == 64)

        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: toolchain.fingerprint
        )
        let eligible = try #require(
            archive.functions.first(where: { $0.canonicalDeclaration.contains("transform") })
        )
        let entry = try #require(eligible.entryIndex)

        let changed = """
        public func transform(_ x: Int) -> Int { x + 27 }
        public func locked(_ x: Int) -> Int { x + 2 }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.toolchain.fingerprint == toolchain.fingerprint)
        #expect(result.changedFunctions.map(\.key) == [eligible.key])
        #expect(result.module.entries.map(\.entryIndex) == [entry])
        #expect(result.module.functions.first?.effects == eligible.effects)
        #expect(result.disassembly.contains("checked_add"))

        let shell = try Verification.ShellInterface(archive: archive)
        let image = try Verification.Engine().verify(bytes: result.bytecode, shell: shell, policy: .init())
        let input = try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
        #expect(
            VM.Interpreter().invoke(entry: entry, image: image, arguments: [.integer(input)])
                == .returned(.integer(try VM.Integer(signed: 30, bitWidth: 64, isSigned: true)))
        )

        #expect(archive.capabilities.contains(.stringsV1))
        #expect(archive.capabilities.contains(.collectionsV1))
        let localVMValues = """
        public func transform(_ x: Int) -> Int {
            let text = String(repeating: "🧬", count: 2)
            let values = [x, text.count]
            return values[0] + values[1]
        }
        public func locked(_ x: Int) -> Int { x + 2 }
        """
        try Data(localVMValues.utf8).write(to: sourceURL)
        let localVMResult = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        #expect(localVMResult.module.capabilities.contains(.stringsV1))
        #expect(localVMResult.module.capabilities.contains(.collectionsV1))
        let localVMImage = try Verification.Engine().verify(
            bytes: localVMResult.bytecode,
            shell: shell,
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: localVMImage,
                arguments: [.integer(input)]
            ) == .returned(
                .integer(try VM.Integer(signed: 5, bitWidth: 64, isSigned: true))
            )
        )

        let changedRejectedOnly = """
        public func transform(_ x: Int) -> Int { x + 1 }
        public func locked(_ x: Int) -> Int { x + 99 }
        """
        try Data(changedRejectedOnly.utf8).write(to: sourceURL)
        let rejected = try #require(
            archive.functions.first(where: { $0.canonicalDeclaration.contains("locked") })
        )
        #expect(throws: ReleaseCompiler.DriverError.self) {
            _ = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
        }
        do {
            _ = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
            Issue.record("expected the changed ineligible function to be rejected")
        } catch let error as ReleaseCompiler.DriverError {
            guard case let .changedIneligibleFunction(key, reason) = error else {
                Issue.record("unexpected driver error: \(error)")
                return
            }
            #expect(key == rejected.key)
            #expect(reason.contains("fixture policy"))
        }
    }

    @Test("A changed Swift function calls an unchanged Shell entry")
    func lowersCallsToUnchangedEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-entry-call-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
        @inline(never) public func transform(_ x: Int) -> Int { helper(x) }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint
        )
        let helper = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("helper") }
        )
        let transform = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("transform") }
        )
        let helperEntry = try #require(helper.entryIndex)
        let transformEntry = try #require(transform.entryIndex)

        try Data(
            """
            @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
            @inline(never) public func transform(_ x: Int) -> Int { helper(x) + 3 }
            """.utf8
        ).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(result.disassembly.contains("entry_apply #\(helperEntry.rawValue)"))
        #expect(!result.disassembly.contains("hlbc_apply"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let interpreter = VM.Interpreter(entryInvocation: { entry, arguments, _ in
            guard entry == helperEntry,
                  arguments.count == 1,
                  case let .integer(value) = arguments[0]
            else { return .trapped(.unknownEntry(entry)) }
            return .returned(
                .integer(try! VM.Integer(signed: value.signedValue + 1, bitWidth: 64, isSigned: true))
            )
        })
        #expect(
            interpreter.invoke(
                entry: transformEntry,
                image: image,
                arguments: [.integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true))]
            ) == .returned(.integer(try VM.Integer(signed: 8, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("An unchanged Shell function can be used as a Swift closure value")
    func lowersUnchangedEntryClosureValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-entry-closure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
        @inline(never) public func transform(_ x: Int) -> Int { helper(x) }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            optimization: "-Onone"
        )
        let helper = try #require(
            archive.functions.first {
                $0.canonicalDeclaration.contains("helper")
            }
        )
        let transform = try #require(
            archive.functions.first {
                $0.canonicalDeclaration.contains("transform")
            }
        )
        let helperEntry = try #require(helper.entryIndex)
        let transformEntry = try #require(transform.entryIndex)

        try Data(
            """
            @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
            @inline(never) private func invoke(
                _ value: Int,
                operation: (Int) -> Int
            ) -> Int {
                operation(value)
            }
            @inline(never) public func transform(_ x: Int) -> Int {
                let operation: (Int) -> Int = helper
                return invoke(x, operation: operation) + 3
            }
            """.utf8
        ).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(
            result.disassembly.contains(
                "make_closure.invocation entry #\(helperEntry.rawValue)"
            )
        )
        #expect(result.disassembly.contains("closure_apply"))
        #expect(result.disassembly.contains("hlbc_apply"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let interpreter = VM.Interpreter(
            entryInvocation: { entry, arguments, _ in
                guard entry == helperEntry,
                      arguments.count == 1,
                      case let .integer(value) = arguments[0]
                else { return .trapped(.unknownEntry(entry)) }
                return .returned(
                    .integer(
                        try! VM.Integer(
                            signed: value.signedValue + 1,
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            }
        )
        #expect(
            interpreter.invoke(
                entry: transformEntry,
                image: image,
                arguments: [
                    .integer(
                        try VM.Integer(
                            signed: 4,
                            bitWidth: 64,
                            isSigned: true
                        )
                    ),
                ]
            ) == .returned(
                .integer(
                    try VM.Integer(
                        signed: 8,
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            )
        )
    }

    @Test("Changing a default value links its compiler-generated thunk into the patch")
    func linksChangedDefaultArgumentGenerator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never) public func helper(_ value: Int = 2) -> Int { value }
        @inline(never) public func transform(_ value: Int) -> Int { value + helper() }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            optimization: "-Onone"
        )
        let helper = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("helper") }
        )
        let transform = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("transform") }
        )
        let helperEntry = try #require(helper.entryIndex)
        let transformEntry = try #require(transform.entryIndex)

        try Data(
            """
            @inline(never) public func helper(_ value: Int = 5) -> Int { value }
            @inline(never) public func transform(_ value: Int) -> Int { value + helper() }
            """.utf8
        ).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(result.module.functions.contains {
            $0.kind == .concreteSpecialization && $0.name.contains("fA")
        })
        #expect(result.disassembly.contains("entry_apply #\(helperEntry.rawValue)"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let interpreter = VM.Interpreter(entryInvocation: { entry, arguments, _ in
            guard entry == helperEntry, arguments.count == 1 else {
                return .trapped(.unknownEntry(entry))
            }
            return .returned(arguments[0])
        })
        #expect(
            interpreter.invoke(
                entry: transformEntry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 8, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Changed Swift callees are linked inside one atomic HLBC image")
    func lowersCallsToLocalPatchFunctions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-local-call-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
        @inline(never) public func transform(_ x: Int) -> Int { helper(x) }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint
        )
        let transform = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("transform") }
        )
        let transformEntry = try #require(transform.entryIndex)

        try Data(
            """
            @inline(never) public func helper(_ x: Int) -> Int { x + 2 }
            @inline(never) public func transform(_ x: Int) -> Int { helper(x) + 3 }
            """.utf8
        ).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.count == 2)
        #expect(result.module.functions.count == 2)
        #expect(result.disassembly.contains("hlbc_apply"))
        #expect(!result.disassembly.contains("entry_apply"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: transformEntry,
                image: image,
                arguments: [.integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true))]
            ) == .returned(.integer(try VM.Integer(signed: 9, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("New private functions form a closed image-local call graph")
    func linksNewPatchLocalFunctions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-new-local-functions-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "@inline(never) public func transform(_ x: Int) -> Int { x }\n"
        try Data(baseline.utf8).write(to: sourceURL)

        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            optimization: "-Onone"
        )
        let transform = try #require(archive.functions.first)
        let entry = try #require(transform.entryIndex)

        let changed = """
        @inline(never)
        private func sumDown(_ value: Int) -> Int {
            if value <= 0 { return 0 }
            return value + sumDown(value - 1)
        }

        @inline(never)
        private func check(_ value: Int) -> Int {
            sumDown(value) + 4
        }

        @inline(never)
        public func transform(_ x: Int) -> Int { check(x) }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(result.module.functions.count == 3)
        #expect(result.module.functions.filter { $0.kind == .ordinary }.count == 3)
        #expect(result.disassembly.components(separatedBy: "hlbc_apply").count - 1 == 3)

        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 14, bitWidth: 64, isSigned: true))
            )
        )

        try Data(
            changed.replacingOccurrences(
                of: "sumDown(value) + 4",
                with: "sumDown(value) + 5"
            ).utf8
        )
            .write(to: sourceURL)
        let later = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
        #expect(later.bytecode != result.bytecode)
        #expect(later.bodyFingerprints[transform.key] != result.bodyFingerprints[transform.key])
    }

    @Test("Static KeyPaths keep the release image runtime-free and typed")
    func buildsStaticKeyPathProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-static-keypath-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        public func transform(_ value: String) -> Int { value.count }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(
                parameters: ["Swift.String"],
                result: "Swift.Int"
            ),
            transformParameterTypes: [.string],
            transformParameterConventions: [.owned],
            transformCanonicalDeclaration: "func transform(_: String) -> Int",
            transformFormalType: "(Swift.String) -> Swift.Int",
            transformLoweredSILType:
                "@convention(thin) (@guaranteed String) -> Int",
            optimization: "-Onone",
            additionalCapabilities: [
                .collectionsV1,
                .closureValuesV1,
                .localNominalsV1,
            ]
        )
        let record = try #require(archive.functions.first)
        let entry = try #require(record.entryIndex)
        let changed = """
        private struct Item { let text: String }
        @inline(never)
        public func transform(_ value: String) -> Int {
            [Item(text: value)].map(\\.text.count)[0]
        }
        """
        try Data(changed.utf8).write(to: sourceURL)

        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        let closures = result.module.functions.flatMap(\.blocks)
            .flatMap(\.instructions).compactMap {
                instruction -> [Bytecode.Register]? in
                guard case let .makeClosure(_, _, captures, _) = instruction else {
                    return nil
                }
                return captures
            }
        #expect(result.changedFunctions.map(\.key) == [record.key])
        #expect(!closures.isEmpty)
        #expect(closures.allSatisfy { $0.isEmpty })
        #expect(result.module.functions.contains { function in
            function.kind == .closureBody
                && function.blocks.flatMap(\.instructions).contains {
                    if case .stringCount = $0 { return true }
                    return false
                }
        })

        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [.string("Helix")]
            ) == .returned(
                .integer(
                    try VM.Integer(
                        signed: 5,
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            )
        )
    }

    @Test("New private methods and computed getters receive frozen native self")
    func linksNewPrivateInstanceMethod() throws {
        final class NativeScreen: @unchecked Sendable {}

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-new-private-method-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        public final class Screen {
            @inline(never) public func transform(_ x: Int) -> Int { x }
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.release-driver",
            buildNumber: "1",
            seed: "fixture"
        )
        let canonicalType = "ReleaseDriverFixture.Screen"
        let typeID = Core.TypeID.derive(namespace: namespace, canonicalType: canonicalType)
        let layout = Core.Digest.sha256("ReleaseDriverFixture.Screen.layout.v1")
        let nativeType = InterfaceArchive.TypeRecord(
            id: typeID,
            canonicalName: canonicalType,
            kind: .reference,
            layoutFingerprint: layout,
            isCopyable: true,
            isEmittedToDevice: true,
            estimatedSize: 8
        )

        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(
                parameters: ["Swift.Int", canonicalType],
                result: "Swift.Int"
            ),
            transformParameterTypes: [.int64, .native(typeID)],
            transformParameterConventions: [.owned, .borrowed],
            transformCanonicalDeclaration: "Screen.func transform(_: Int) -> Int",
            transformFormalType: "(Screen) -> (Swift.Int) -> Swift.Int",
            transformLoweredSILType:
                "@convention(method) (Int, @guaranteed Screen) -> Int",
            optimization: "-Onone",
            nativeTypes: [nativeType]
        )
        let transform = try #require(archive.functions.first)
        let entry = try #require(transform.entryIndex)

        let changed = """
        private var offset: Int {
            @inline(never) get { 2 }
        }

        public final class Screen {
            private var multiplier: Int { 3 }

            @inline(never)
            private func check(_ value: Int) -> Int { value * multiplier }

            @inline(never)
            public func transform(_ x: Int) -> Int { check(x) + offset }
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(result.module.functions.count == 4)
        #expect(result.disassembly.components(separatedBy: "hlbc_apply").count - 1 == 3)

        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let operations = VM.NativeTypeOperations.reference(
            id: typeID,
            canonicalName: canonicalType,
            layoutFingerprint: layout,
            estimatedSize: 8,
            estimatedByteCount: { (_: NativeScreen) in 8 }
        )
        let boxed = try operations.box(NativeScreen())
        #expect(
            VM.Interpreter(
                nativeTypeCatalog: try VM.NativeTypeCatalog([operations])
            ).invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                    .native(boxed),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 14, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("New struct, enum, and computed accessors remain image-local VM values")
    func linksNewPatchLocalNominalsAndAccessors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-new-local-nominals-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "@inline(never) public func transform(_ x: Int) -> Int { x }\n"
        try Data(baseline.utf8).write(to: sourceURL)

        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            optimization: "-Onone"
        )
        let transform = try #require(archive.functions.first)
        let entry = try #require(transform.entryIndex)

        let changed = """
        private enum Feature {}

        private extension Feature {
            struct Counter {
                var raw: Int

                static var base: Int {
                    @inline(never) get { 3 }
                }

                var adjusted: Int {
                    @inline(never) get { raw * 2 }
                    @inline(never) set { raw = newValue + 1 }
                }
            }

            enum Outcome {
                case value(Counter)
                case empty
            }
        }

        @inline(never)
        private func evaluate(_ input: Int) -> Int {
            var counter = Feature.Counter(raw: input)
            counter.adjusted = input + Feature.Counter.base
            let outcome: Feature.Outcome = input >= 0 ? .value(counter) : .empty
            switch outcome {
            case let .value(value): return value.adjusted
            case .empty: return -1
            }
        }

        @inline(never)
        public func transform(_ x: Int) -> Int { evaluate(x) }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(result.module.localTypes.map(\.key.rawValue) == [
            "Feature.Counter", "Feature.Outcome",
        ])
        #expect(result.disassembly.contains("make_struct"))
        #expect(result.disassembly.contains("make_enum"))
        #expect(result.disassembly.contains("switch_enum"))
        #expect(result.disassembly.components(separatedBy: "hlbc_apply").count - 1 >= 3)

        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        for (input, expected) in [(4, 16), (-1, -1)] {
            #expect(
                VM.Interpreter().invoke(
                    entry: entry,
                    image: image,
                    arguments: [
                        .integer(
                            try VM.Integer(
                                signed: Int64(input),
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                    ]
                ) == .returned(
                    .integer(
                        try VM.Integer(
                            signed: Int64(expected),
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            )
        }
    }

    @Test("New final classes preserve reference identity and mutable storage inside HLVM")
    func linksNewPatchLocalClasses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-new-local-classes-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "@inline(never) public func transform(_ x: Int) -> Int { x }\n"
        try Data(baseline.utf8).write(to: sourceURL)

        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            optimization: "-Onone"
        )
        let transform = try #require(archive.functions.first)
        let entry = try #require(transform.entryIndex)

        try Data(
            """
            private final class CounterBox {
                var raw: Int

                init(_ raw: Int) {
                    self.raw = raw
                }

                @inline(never)
                func increment() {
                    raw += 1
                }

                var doubled: Int {
                    @inline(never) get { raw * 2 }
                }
            }

            @inline(never)
            public func transform(_ x: Int) -> Int {
                let box = CounterBox(x)
                let alias = box
                alias.increment()
                return box.doubled
            }
            """.utf8
        ).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(result.module.localTypes.count == 1)
        let definition = try #require(result.module.localTypes.first)
        #expect(definition.key.rawValue == "CounterBox")
        guard case let .class(fields, hostedSuperclass, hostedMethods) = definition.kind else {
            Issue.record("expected one patch-local class definition")
            return
        }
        #expect(fields == [.init(name: "raw", type: .int64)])
        #expect(hostedSuperclass == nil)
        #expect(hostedMethods.isEmpty)
        #expect(result.module.capabilities.contains(.localClassesV1))
        #expect(result.disassembly.contains("allocate_object"))
        #expect(result.disassembly.contains("project_object_addr"))

        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let outcome = VM.Interpreter().invoke(
            entry: entry,
            image: image,
            arguments: [
                .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
            ]
        )
        #expect(
            outcome == .returned(
                .integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Production driver links a hosted UIViewController class")
    func linksHostedUIViewControllerClass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-hosted-uiviewcontroller-release-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        import UIKit

        @MainActor
        @inline(never)
        public func transform() -> UIViewController {
            fatalError("baseline")
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.release-driver",
            buildNumber: "1",
            seed: "fixture"
        )
        let controllerType = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "UIKit.UIViewController"
        )
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(
                parameters: [],
                result: "UIKit.UIViewController",
                isolation: "MainActor"
            ),
            transformParameterTypes: [],
            transformResultType: .native(controllerType),
            transformCanonicalDeclaration:
                "@MainActor func transform() -> UIViewController",
            transformFormalType: "() -> UIKit.UIViewController",
            transformLoweredSILType:
                "@convention(thin) () -> @owned UIViewController",
            transformEffects: .init(
                mayAllocate: true,
                requiresMainActor: true
            ),
            optimization: "-Onone",
            nativeTypes: [
                .init(
                    id: controllerType,
                    canonicalName: "UIKit.UIViewController",
                    kind: .reference,
                    layoutFingerprint: .sha256("UIViewController-layout"),
                    isCopyable: true,
                    requiresMainActor: true,
                    isEmittedToDevice: true,
                    estimatedSize: 8
                ),
            ]
        )
        let transform = try #require(archive.functions.first)

        let changed = """
        import UIKit

        final class EmergencyController: UIViewController {
            override func viewDidLoad() {
                super.viewDidLoad()
            }
        }

        @MainActor
        @inline(never)
        public func transform() -> UIViewController {
            EmergencyController()
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        let definition = try #require(
            result.module.localTypes.first {
                $0.key.rawValue == "EmergencyController"
            }
        )
        guard case let .class(fields, superclass, methods) = definition.kind else {
            Issue.record("expected a hosted UIViewController definition")
            return
        }
        #expect(fields.isEmpty)
        #expect(superclass?.typeID == controllerType)
        #expect(methods.map(\.selector) == ["viewDidLoad"])
        #expect(methods.allSatisfy { method in
            result.module.functions.first { $0.id == method.functionID }?
                .effects.requiresMainActor == true
        })
        #expect(result.module.capabilities.contains(.hostedObjectiveCClassesV1))
        #expect(result.disassembly.contains("project_hosted_object"))

        _ = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(
                acceptedCapabilities: Set(archive.capabilities),
                allowMainActorSynchronousEntries: true
            )
        )
    }

    @Test("An allowlisted Swift callee becomes a typed native import")
    func lowersCallsToNativeImports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-native-call-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
        @inline(never) public func transform(_ x: Int) -> Int { helper(x) }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperExposure: .nativeImport
        )
        let transform = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("transform") }
        )
        let transformEntry = try #require(transform.entryIndex)
        let nativeImport = try #require(archive.nativeImports.first)
        let importID = try #require(nativeImport.id)

        try Data(
            """
            @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
            @inline(never) public func transform(_ x: Int) -> Int { helper(x) + 3 }
            """.utf8
        ).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(result.module.imports.map(\.id) == [importID])
        #expect(result.disassembly.contains("native_apply #\(importID.rawValue)"))
        let policy = Core.RuntimePolicy(
            acceptedCapabilities: Set(archive.capabilities),
            allowedNativeImports: [importID]
        )
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: policy
        )
        let catalog = try VM.NativeCatalog([
            IncrementInvoker(
                id: importID,
                key: nativeImport.key,
                effects: nativeImport.effects,
                contract: nativeImport.contract
            ),
        ])
        #expect(
            VM.Interpreter(nativeCatalog: catalog).invoke(
                entry: transformEntry,
                image: image,
                arguments: [.integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true))]
            ) == .returned(.integer(try VM.Integer(signed: 17, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("An allowlisted Swift callee remains a NativeImport as a function value")
    func lowersNativeImportFunctionValuesEndToEnd() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-native-function-value-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
        @inline(never) public func transform(_ x: Int) -> Int {
            let operations: [(Int) -> Int] = [helper]
            return operations[0](x)
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperExposure: .nativeImport,
            optimization: "-Onone"
        )
        let transform = try #require(
            archive.functions.first {
                $0.canonicalDeclaration.contains("transform")
            }
        )
        let transformEntry = try #require(transform.entryIndex)
        let nativeImport = try #require(archive.nativeImports.first)
        let importID = try #require(nativeImport.id)

        try Data(
            """
            @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
            @inline(never) public func transform(_ x: Int) -> Int {
                let operations: [(Int) -> Int] = [helper]
                return operations[0](x) + 3
            }
            """.utf8
        ).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.changedFunctions.map(\.key) == [transform.key])
        #expect(result.module.imports.map(\.id) == [importID])
        #expect(
            result.module.functions.flatMap(\.blocks).flatMap(\.instructions)
                .contains {
                    if case let .makeClosure(
                        _,
                        .nativeImport(targetID),
                        captures,
                        lifetime
                    ) = $0 {
                        return targetID == importID
                            && captures.isEmpty
                            && lifetime == .invocation
                    }
                    return false
                }
        )
        #expect(result.disassembly.contains("closure_apply"))
        let policy = Core.RuntimePolicy(
            acceptedCapabilities: Set(archive.capabilities),
            allowedNativeImports: [importID]
        )
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: policy
        )
        let catalog = try VM.NativeCatalog([
            IncrementInvoker(
                id: importID,
                key: nativeImport.key,
                effects: nativeImport.effects,
                contract: nativeImport.contract
            ),
        ])
        #expect(
            VM.Interpreter(nativeCatalog: catalog).invoke(
                entry: transformEntry,
                image: image,
                arguments: [
                    .integer(
                        try VM.Integer(
                            signed: 4,
                            bitWidth: 64,
                            isSigned: true
                        )
                    ),
                ]
            ) == .returned(
                .integer(
                    try VM.Integer(
                        signed: 17,
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            )
        )
    }

    @Test("A cataloged but non-emitted callee fails with an allowlist diagnostic")
    func diagnosesNonEmittedNativeImport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-native-call-denied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
        @inline(never) public func transform(_ x: Int) -> Int { helper(x) }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperExposure: .nativeImport,
            emitHelperImport: false
        )
        #expect(archive.nativeImports.first?.isEmittedToDevice == false)

        try Data(
            """
            @inline(never) public func helper(_ x: Int) -> Int { x + 1 }
            @inline(never) public func transform(_ x: Int) -> Int { helper(x) + 2 }
            """.utf8
        ).write(to: sourceURL)
        do {
            _ = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
            Issue.record("non-emitted native import unexpectedly compiled")
        } catch let error as CanonicalSIL.LoweringError {
            guard case let .unavailableNativeImport(
                _, _, canonicalCallee, reason
            ) = error else {
                Issue.record("unexpected lowering diagnostic: \(error)")
                return
            }
            #expect(canonicalCallee == "ReleaseDriverFixture.helper(_:)")
            #expect(reason.contains("nativeImports.allow"))
            #expect(reason.contains("ship a new Shell"))
        }
    }

    @Test("The exact release toolchain contract is enforced before compilation")
    func enforcesToolchainFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-toolchain-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "public func transform(_ x: Int) -> Int { x + 1 }\n"
        try Data(baseline.utf8).write(to: sourceURL)
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: "sha256:not-the-current-toolchain"
        )
        try Data("public func transform(_ x: Int) -> Int { x + 8 }\n".utf8).write(to: sourceURL)

        do {
            _ = try ReleaseCompiler.Driver().build(
                .init(archive: archive, sourceFiles: [sourceURL])
            )
            Issue.record("expected exact toolchain identity enforcement")
        } catch let error as ReleaseCompiler.DriverError {
            guard case let .toolchainMismatch(expected, actual) = error else {
                Issue.record("unexpected driver error: \(error)")
                return
            }
            #expect(expected == "sha256:not-the-current-toolchain")
            #expect(actual.hasPrefix("sha256:"))
        }
    }

    @Test("Production change identity and semantic String lowering use separate pinned SIL passes")
    func buildsChangedStringSourceThroughSemanticSIL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-string-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "@inline(never) public func transform(_ value: String) -> String { value + \"!\" }\n"
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(
                parameters: ["Swift.String"],
                result: "Swift.String"
            ),
            transformParameterTypes: [.string],
            transformResultType: .string,
            transformCanonicalDeclaration: "func transform(_: String) -> String",
            transformFormalType: "(Swift.String) -> Swift.String",
            transformLoweredSILType: "@convention(thin) (@guaranteed String) -> @owned String"
        )
        let record = try #require(archive.functions.first)
        let entry = try #require(record.entryIndex)

        try Data(
            "@inline(never) public func transform(_ value: String) -> String { value + \"?\" }\n".utf8
        ).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [record.key])
        #expect(result.module.capabilities.contains(.stringsV1))
        #expect(result.disassembly.contains("const_string"))
        #expect(result.disassembly.contains("string_concat"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [.string("Helix")]
            ) == .returned(.string("Helix?"))
        )

        try Data(
            """
            @inline(never)
            public func transform(_ value: String) -> String {
                "\\(value):\\(value.count)"
            }
            """.utf8
        ).write(to: sourceURL)
        let interpolationResult = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        #expect(interpolationResult.disassembly.contains("stringify"))
        let interpolationImage = try Verification.Engine().verify(
            bytes: interpolationResult.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: interpolationImage,
                arguments: [.string("Helix")]
            ) == .returned(.string("Helix:5"))
        )

        try Data(
            """
            @inline(never)
            public func transform(_ value: String) -> String {
                value.hasPrefix("Hel") && value.hasSuffix("lix") ? "matched" : "missing"
            }
            """.utf8
        ).write(to: sourceURL)
        let predicateResult = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        #expect(predicateResult.disassembly.contains("string_hasPrefix"))
        #expect(predicateResult.disassembly.contains("string_hasSuffix"))
        let predicateImage = try Verification.Engine().verify(
            bytes: predicateResult.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: predicateImage,
                arguments: [.string("Helix")]
            ) == .returned(.string("matched"))
        )

        #expect(archive.capabilities.contains(.collectionsV1))
        try Data(
            """
            @inline(never)
            public func transform(_ value: String) -> String {
                String(value.reversed())
            }
            """.utf8
        ).write(to: sourceURL)
        let sequenceResult = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        #expect(sequenceResult.module.capabilities.contains(.collectionsV1))
        #expect(sequenceResult.disassembly.contains("string_characters"))
        #expect(sequenceResult.disassembly.contains("string_join.character"))
        let sequenceImage = try Verification.Engine().verify(
            bytes: sequenceResult.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: sequenceImage,
                arguments: [.string("A🧬é")]
            ) == .returned(.string("é🧬A"))
        )
    }

    @Test("Production Array edits lower through semantic SIL without loading native code")
    func buildsChangedArraySourceThroughSemanticSIL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-array-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "@inline(never) public func transform(_ values: [Int]) -> Int { values.count }\n"
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let arrayType = Bytecode.ValueType.array(.int64)
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(
                parameters: ["Swift.Array<Swift.Int>"],
                result: "Swift.Int"
            ),
            transformParameterTypes: [arrayType],
            transformResultType: .int64,
            transformCanonicalDeclaration: "func transform(_: [Int]) -> Int",
            transformFormalType: "(Swift.Array<Swift.Int>) -> Swift.Int",
            transformLoweredSILType: "@convention(thin) (@guaranteed Array<Int>) -> Int"
        )
        let record = try #require(archive.functions.first)
        let entry = try #require(record.entryIndex)

        try Data(
            "@inline(never) public func transform(_ values: [Int]) -> Int { values[1] }\n".utf8
        ).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.module.capabilities.contains(.collectionsV1))
        #expect(result.disassembly.contains("array_get"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let values = try [2, 5, 9].map {
            VM.Value.integer(
                try VM.Integer(signed: Int64($0), bitWidth: 64, isSigned: true)
            )
        }
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [.array(values, elementType: .int64)]
            ) == .returned(values[1])
        )

        try Data(
            """
            @inline(never)
            public func transform(_ values: [Int]) -> Int {
                var updated = values
                updated[1] = 42
                return updated[1]
            }
            """.utf8
        ).write(to: sourceURL)
        let updateResult = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        #expect(updateResult.disassembly.contains("array_update"))
        let updateImage = try Verification.Engine().verify(
            bytes: updateResult.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: updateImage,
                arguments: [.array(values, elementType: .int64)]
            ) == .returned(
                .integer(try VM.Integer(signed: 42, bitWidth: 64, isSigned: true))
            )
        )

        try Data(
            """
            @inline(never)
            public func transform(_ values: [Int]) -> Int {
                var total = 0
                for value in values { total += value }
                return total
            }
            """.utf8
        ).write(to: sourceURL)
        let iterationResult = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        #expect(iterationResult.disassembly.contains("collection_next_forward"))
        let iterationImage = try Verification.Engine().verify(
            bytes: iterationResult.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: iterationImage,
                arguments: [.array(values, elementType: .int64)]
            ) == .returned(
                .integer(try VM.Integer(signed: 16, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Production Dictionary edits lower through semantic SIL and verified iteration")
    func buildsChangedDictionarySourceThroughSemanticSIL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-dictionary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        public func transform(_ values: [String: Int]) -> Int { values.count }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let dictionaryType = Bytecode.ValueType.dictionary(key: .string, value: .int64)
        let dictionarySignature = "Swift.Dictionary<Swift.String, Swift.Int>"
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(
                parameters: [dictionarySignature],
                result: "Swift.Int"
            ),
            transformParameterTypes: [dictionaryType],
            transformResultType: .int64,
            transformCanonicalDeclaration: "func transform(_: [String: Int]) -> Int",
            transformFormalType: "(\(dictionarySignature)) -> Swift.Int",
            transformLoweredSILType: "@convention(thin) (@guaranteed Dictionary<String, Int>) -> Int"
        )
        let record = try #require(archive.functions.first)
        let entry = try #require(record.entryIndex)

        let changed = """
        @inline(never)
        public func transform(_ values: [String: Int]) -> Int {
            var total = 0
            for (key, value) in values {
                total += key.count + value
            }
            return total
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [record.key])
        #expect(result.module.capabilities.contains(.collectionsV1))
        #expect(result.module.capabilities.contains(.stringsV1))
        #expect(result.disassembly.contains("collection_next_forward"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let two = VM.Value.integer(
            try VM.Integer(signed: 2, bitWidth: 64, isSigned: true)
        )
        let five = VM.Value.integer(
            try VM.Integer(signed: 5, bitWidth: 64, isSigned: true)
        )
        let values = VM.Value.dictionary(
            [
                .init(key: .string("a"), value: two),
                .init(key: .string("beta"), value: five),
            ],
            keyType: .string,
            valueType: .int64
        )
        #expect(
            VM.Interpreter().invoke(entry: entry, image: image, arguments: [values])
                == .returned(
                    .integer(try VM.Integer(signed: 12, bitWidth: 64, isSigned: true))
                )
        )
    }

    @Test("Production SIL scalarizes local structs, enums, and nonescaping closures")
    func lowersCompileTimeOnlySwiftAggregatesFromProductionSIL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-scalars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "@inline(never) public func transform(_ x: Int) -> Int { x + 1 }\n"
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint
        )
        let record = try #require(archive.functions.first)
        let entry = try #require(record.entryIndex)

        let changed = """
        @inline(never)
        public func transform(_ x: Int) -> Int {
            struct Point {
                let x: Int
                let y: Int
            }
            enum Mode {
                case add
                case subtract
            }
            let offset = 4
            let adjust: (Int) -> Int = { input in input + offset }
            let point = Point(x: x, y: adjust(x))
            let mode: Mode = x >= 0 ? .add : .subtract
            switch mode {
            case .add:
                return point.x + point.y
            case .subtract:
                return point.x - point.y
            }
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))

        #expect(result.changedFunctions.map(\.key) == [record.key])
        #expect(result.disassembly.contains("cond_br"))
        #expect(result.disassembly.contains("checked_add"))
        #expect(result.disassembly.contains("checked_sub"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let positive = try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
        let negative = try VM.Integer(signed: -3, bitWidth: 64, isSigned: true)
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [.integer(positive)]
            ) == .returned(.integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true)))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [.integer(negative)]
            ) == .returned(.integer(try VM.Integer(signed: -4, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("Production do-catch and try? lower to explicit error edges")
    func lowersSwiftErrorHandlingToEntryTryApply() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-try-apply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        public enum FixtureError: Error { case failed }
        @inline(never)
        public func helper(_ shouldFail: Bool) throws -> Int {
            if shouldFail { throw FixtureError.failed }
            return 7
        }
        @inline(never)
        public func transform(_ shouldFail: Bool) -> Int { shouldFail ? 1 : 2 }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(parameters: ["Swift.Bool"], result: "Swift.Int"),
            transformParameterTypes: [.bool],
            transformResultType: .int64,
            transformCanonicalDeclaration: "func transform(_: Bool) -> Int",
            transformFormalType: "(Swift.Bool) -> Swift.Int",
            transformLoweredSILType: "@convention(thin) (Bool) -> Int",
            helperSignature: .init(
                parameters: ["Swift.Bool"],
                result: "Swift.Int",
                isThrowing: true
            ),
            helperParameterTypes: [.bool],
            helperEffects: .init(mayThrow: true, mayAllocate: true)
        )
        let transform = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("transform") }
        )
        let helper = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("helper") }
        )
        let transformEntry = try #require(transform.entryIndex)
        let helperEntry = try #require(helper.entryIndex)

        func verifyAndRun(_ source: String, failureValue: Int64) throws {
            try Data(source.utf8).write(to: sourceURL)
            let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
            #expect(result.changedFunctions.map(\.key) == [transform.key])
            #expect(result.module.capabilities.contains(.untypedThrowsV1))
            #expect(result.disassembly.contains("entry_try_apply #\(helperEntry.rawValue)"))
            let image = try Verification.Engine().verify(
                bytes: result.bytecode,
                shell: Verification.ShellInterface(archive: archive),
                policy: .init(acceptedCapabilities: Set(archive.capabilities))
            )
            let interpreter = VM.Interpreter(entryInvocation: { entry, arguments, _ in
                guard entry == helperEntry,
                      arguments.count == 1,
                      case let .bool(shouldFail) = arguments[0]
                else { return .trapped(.unknownEntry(entry)) }
                if shouldFail { return .businessError("FixtureError.failed") }
                return .returned(
                    .integer(try! VM.Integer(signed: 7, bitWidth: 64, isSigned: true))
                )
            })
            #expect(
                interpreter.invoke(
                    entry: transformEntry,
                    image: image,
                    arguments: [.bool(false)]
                ) == .returned(.integer(try VM.Integer(signed: 7, bitWidth: 64, isSigned: true)))
            )
            #expect(
                interpreter.invoke(
                    entry: transformEntry,
                    image: image,
                    arguments: [.bool(true)]
                ) == .returned(
                    .integer(try VM.Integer(signed: failureValue, bitWidth: 64, isSigned: true))
                )
            )
        }

        try verifyAndRun(
            """
            public enum FixtureError: Error { case failed }
            @inline(never)
            public func helper(_ shouldFail: Bool) throws -> Int {
                if shouldFail { throw FixtureError.failed }
                return 7
            }
            @inline(never)
            public func transform(_ shouldFail: Bool) -> Int {
                do {
                    return try helper(shouldFail)
                } catch {
                    return -1
                }
            }
            """,
            failureValue: -1
        )
        try verifyAndRun(
            """
            public enum FixtureError: Error { case failed }
            @inline(never)
            public func helper(_ shouldFail: Bool) throws -> Int {
                if shouldFail { throw FixtureError.failed }
                return 7
            }
            @inline(never)
            public func transform(_ shouldFail: Bool) -> Int {
                (try? helper(shouldFail)) ?? -2
            }
            """,
            failureValue: -2
        )

        let localSource = """
        public enum FixtureError: Error { case failed }
        @inline(never)
        public func helper(_ shouldFail: Bool) throws -> Int {
            if shouldFail { throw FixtureError.failed }
            return 9
        }
        @inline(never)
        public func transform(_ shouldFail: Bool) -> Int {
            do {
                return try helper(shouldFail)
            } catch {
                return -3
            }
        }
        """
        try Data(localSource.utf8).write(to: sourceURL)
        let localResult = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
        #expect(Set(localResult.changedFunctions.map(\.key)) == [transform.key, helper.key])
        #expect(localResult.disassembly.contains("try_apply @"))
        #expect(!localResult.disassembly.contains("entry_try_apply"))
        let localImage = try Verification.Engine().verify(
            bytes: localResult.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: transformEntry,
                image: localImage,
                arguments: [.bool(false)]
            ) == .returned(.integer(try VM.Integer(signed: 9, bitWidth: 64, isSigned: true)))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: transformEntry,
                image: localImage,
                arguments: [.bool(true)]
            ) == .returned(.integer(try VM.Integer(signed: -3, bitWidth: 64, isSigned: true)))
        )
    }

    @Test("Production release compilation carries associated Error payloads")
    func buildsTypedAssociatedErrorPatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-release-typed-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        public enum DetailedError: Error {
            case invalid(code: Int, message: String)
            case unavailable
        }
        @inline(never)
        public func helper(_ value: Int) throws -> Int { value + 1 }
        @inline(never)
        public func transform(_ value: Int) -> Int { value }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int",
                isThrowing: true
            ),
            helperEffects: .init(mayThrow: true, mayAllocate: true)
        )
        let transform = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("transform") }
        )
        let transformEntry = try #require(transform.entryIndex)

        let changed = """
        public enum DetailedError: Error {
            case invalid(code: Int, message: String)
            case unavailable
        }
        @inline(never)
        public func helper(_ value: Int) throws -> Int {
            guard value >= 0 else {
                throw DetailedError.invalid(code: value, message: "negative")
            }
            guard value != 13 else { throw DetailedError.unavailable }
            return value + 1
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            do {
                return try helper(value)
            } catch let DetailedError.invalid(code, message) {
                return code + message.count
            } catch DetailedError.unavailable {
                return -1
            } catch {
                return -2
            }
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )

        #expect(archive.capabilities.contains(.localNominalsV1))
        #expect(archive.capabilities.contains(.structuredErrorsV1))
        #expect(result.module.capabilities.contains(.localNominalsV1))
        #expect(result.module.capabilities.contains(.structuredErrorsV1))
        #expect(!result.module.capabilities.contains(.untypedThrowsV1))
        #expect(result.module.localTypes.map(\.key.rawValue) == ["DetailedError"])
        #expect(result.disassembly.contains("make_error"))
        #expect(result.disassembly.contains("cast_error"))
        for (input, expected) in [(4, 5), (-3, 5), (13, -1)] {
            #expect(
                VM.Interpreter().invoke(
                    entry: transformEntry,
                    image: image,
                    arguments: [
                        .integer(
                            try VM.Integer(
                                signed: Int64(input),
                                bitWidth: 64,
                                isSigned: true
                            )
                        ),
                    ]
                ) == .returned(
                    .integer(
                        try VM.Integer(
                            signed: Int64(expected),
                            bitWidth: 64,
                            isSigned: true
                        )
                    )
                )
            )
        }
    }

    @Test("A changed inout helper pulls its unchanged patchable caller into one image")
    func buildsPatchLocalInoutDependencyClosure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-inout-helper-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        public func helper(_ value: inout Int, by amount: Int) {
            value += amount
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            var result = value
            helper(&result, by: 2)
            return result
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["inout Swift.Int", "Swift.Int"],
                result: "Swift.Void"
            ),
            helperParameterTypes: [.int64, .int64],
            helperParameterConventions: [.inout, .owned],
            helperResultType: .void,
            helperEffects: .init(),
            helperHasInOut: true
        )
        let transform = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("transform") }
        )
        let helper = try #require(
            archive.functions.first { $0.canonicalDeclaration.contains("helper") }
        )
        let entry = try #require(transform.entryIndex)

        #expect(transform.patchability.isEligible)
        #expect(!helper.patchability.isEligible)
        #expect(helper.patchability.reasonCode == "HLXIDX006")
        #expect(helper.entryIndex == nil)
        #expect(helper.parameterConventions == [.inout, .owned])
        #expect(archive.capabilities.contains(.addressValuesV1))

        let changed = """
        @inline(never)
        public func helper(_ value: inout Int, by amount: Int) {
            value += amount + 4
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            var result = value
            helper(&result, by: 2)
            return result
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.module.functions.count == 2)
        #expect(result.module.entries.count == 1)
        #expect(result.module.capabilities.contains(.addressValuesV1))
        #expect(result.disassembly.contains("stack_address"))
        #expect(result.disassembly.contains("begin_access.modify"))
        #expect(result.disassembly.contains("store_address.assign"))
        #expect(result.disassembly.contains("hlbc_apply @"))
        let localHelper = try #require(
            result.module.functions.first { $0.parameterConventions.contains(.inout) }
        )
        #expect(!result.module.entries.contains { $0.functionID == localHelper.id })

        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(
                        try VM.Integer(signed: 3, bitWidth: 64, isSigned: true)
                    ),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 9, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Production Onone patches link local closure helpers and closure bodies")
    func buildsFirstClassClosurePatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-closure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        func helper(_ value: Int, _ transform: (Int) -> Int) -> Int {
            transform(transform(value))
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            let offset = 1
            return helper(value) { $0 + offset }
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let closureType = Bytecode.ValueType.closure(
            .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: .int64
            )
        )
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["Swift.Int", "(Swift.Int) -> Swift.Int"],
                result: "Swift.Int"
            ),
            helperParameterTypes: [.int64, closureType],
            helperEffects: .init(),
            helperCanonicalDeclaration:
                "func helper(_: Int, _: (Int) -> Int) -> Int",
            helperFormalType: "(Swift.Int, (Swift.Int) -> Swift.Int) -> Swift.Int",
            optimization: "-Onone"
        )
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let helper = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("helper")
        })
        let entry = try #require(root.entryIndex)
        #expect(helper.patchability.reasonCode == "HLXIDX022")

        let changed = """
        @inline(never)
        func helper(_ value: Int, _ transform: (Int) -> Int) -> Int {
            transform(transform(value))
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            var offset = 3
            return helper(value) {
                offset += 1
                return $0 + offset
            }
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.module.functions.count == 3)
        #expect(result.module.functions.contains { $0.kind == .closureBody })
        #expect(result.module.capabilities.contains(.closureValuesV1))
        #expect(result.module.capabilities.contains(.mutableCapturesV1))
        #expect(archive.capabilities.contains(.mutableCapturesV1))
        #expect(result.disassembly.contains("make_closure"))
        #expect(result.disassembly.contains("make_mutable_cell"))
        #expect(result.disassembly.contains("closure_apply"))
        #expect(!result.module.entries.contains { entryPoint in
            result.module.functions.first(where: {
                $0.id == entryPoint.functionID
            })?.kind == .closureBody
        })

        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 13, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Production patches link nominal constructors used as closures")
    func buildsNominalConstructorClosurePatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-constructor-closure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        private enum Choice { case value(Int) }
        private struct Point {
            let x: Int
            init(_ value: Int) { self.x = value + 1 }
        }
        public func transform(_ value: Int) -> Int {
            let wrap: (Int) -> Choice = Choice.value
            let make: (Int) -> Point = Point.init
            switch wrap(make(value).x) {
            case let .value(result): return result + 1
            }
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            optimization: "-Onone"
        )
        let root = try #require(archive.functions.first)
        let entry = try #require(root.entryIndex)

        let changed = baseline.replacingOccurrences(
            of: "return result + 1",
            with: "return result + 3"
        )
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.module.functions.contains { $0.kind == .closureBody })
        #expect(result.disassembly.contains("make_closure"))
        #expect(result.module.localTypes.count == 2)
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(
                        try VM.Integer(
                            signed: 4,
                            bitWidth: 64,
                            isSigned: true
                        )
                    ),
                ]
            ) == .returned(
                .integer(
                    try VM.Integer(signed: 8, bitWidth: 64, isSigned: true)
                )
            )
        )
    }

    @Test("Production sync escaping closures can return and capture VM closures")
    func buildsEscapingClosurePatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-escaping-closure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        func helper(
            _ transform: @escaping (Int) -> Int,
            offset: Int
        ) -> (Int) -> Int {
            { input in transform(input) + offset }
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            let escaped = helper({ $0 * 2 }, offset: 1)
            return escaped(value)
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let closureType = Bytecode.ValueType.closure(
            .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: .int64
            )
        )
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["(Swift.Int) -> Swift.Int", "Swift.Int"],
                result: "(Swift.Int) -> Swift.Int"
            ),
            helperParameterTypes: [closureType, .int64],
            helperResultType: closureType,
            helperEffects: .init(),
            helperCanonicalDeclaration:
                "func helper(_: @escaping (Int) -> Int, offset: Int) -> (Int) -> Int",
            helperFormalType:
                "(@escaping (Swift.Int) -> Swift.Int, Swift.Int) -> (Swift.Int) -> Swift.Int",
            optimization: "-Onone"
        )
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let helper = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("helper")
        })
        let entry = try #require(root.entryIndex)
        #expect(helper.patchability.reasonCode == "HLXIDX022")
        #expect(archive.capabilities.contains(.escapingClosureValuesV1))

        let changed = """
        @inline(never)
        func helper(
            _ transform: @escaping (Int) -> Int,
            offset: Int
        ) -> (Int) -> Int {
            { input in transform(input) + offset }
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            let escaped = helper({ $0 * 2 }, offset: 3)
            return escaped(value)
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.module.capabilities.contains(.closureValuesV1))
        #expect(result.module.capabilities.contains(.escapingClosureValuesV1))
        #expect(result.module.functions.contains { function in
            function.resultType == closureType
        })
        #expect(result.module.functions.contains { function in
            function.kind == .closureBody
                && function.parameterRegisters.contains { register in
                    function.type(of: register) == closureType
                }
        })

        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 11, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Production closures preserve borrowed nontrivial Swift values")
    func buildsBorrowedStringClosurePatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-string-closure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        func helper(_ value: String, _ transform: (String) -> String) -> String {
            transform(value) + value
        }
        @inline(never)
        public func transform(_ value: String) -> String {
            let suffix = "?"
            return helper(value) { $0 + suffix }
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let closureType = Bytecode.ValueType.closure(
            .init(
                parameters: [.string],
                parameterConventions: [.owned],
                result: .string
            )
        )
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(
                parameters: ["Swift.String"],
                result: "Swift.String"
            ),
            transformParameterTypes: [.string],
            transformResultType: .string,
            transformCanonicalDeclaration: "func transform(_: String) -> String",
            transformFormalType: "(Swift.String) -> Swift.String",
            transformLoweredSILType:
                "@convention(thin) (@guaranteed String) -> @owned String",
            helperSignature: .init(
                parameters: ["Swift.String", "(Swift.String) -> Swift.String"],
                result: "Swift.String"
            ),
            helperParameterTypes: [.string, closureType],
            helperResultType: .string,
            helperEffects: .init(mayAllocate: true),
            helperCanonicalDeclaration:
                "func helper(_: String, _: (String) -> String) -> String",
            helperFormalType:
                "(Swift.String, (Swift.String) -> Swift.String) -> Swift.String",
            optimization: "-Onone"
        )
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let entry = try #require(root.entryIndex)
        let changed = """
        @inline(never)
        func helper(_ value: String, _ transform: (String) -> String) -> String {
            transform(value) + value
        }
        @inline(never)
        public func transform(_ value: String) -> String {
            let suffix = "!"
            return helper(value) { $0 + suffix }
        }
        """
        try Data(changed.utf8).write(to: sourceURL)

        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )

        // Swift-managed values stay copyable in VM registers, so the frontend
        // deliberately normalizes SIL @guaranteed to the owned HLBC value ABI.
        #expect(!result.module.capabilities.contains(.borrowCallsV1))
        #expect(result.module.capabilities.contains(.closureValuesV1))
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [.string("A")]
            ) == .returned(.string("A!A"))
        )
    }

    @Test("A closure-body-only edit is detected through its implementation fingerprint")
    func detectsClosureBodyOnlyChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-closure-fingerprint-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        func helper(_ value: Int, _ transform: (Int) -> Int) -> Int {
            transform(transform(value))
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value) { $0 + 1 }
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let closureType = Bytecode.ValueType.closure(
            .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: .int64
            )
        )
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["Swift.Int", "(Swift.Int) -> Swift.Int"],
                result: "Swift.Int"
            ),
            helperParameterTypes: [.int64, closureType],
            helperEffects: .init(),
            helperCanonicalDeclaration:
                "func helper(_: Int, _: (Int) -> Int) -> Int",
            helperFormalType: "(Swift.Int, (Swift.Int) -> Swift.Int) -> Swift.Int",
            optimization: "-Onone"
        )
        let baselineSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: archive.metadata.frontendInvocation
        )
        let baselineFile = try CanonicalSIL.File(text: baselineSIL)
        let baselineRoot = try #require(baselineFile.functions.first {
            $0.mangledName.contains("transformy")
                && !$0.mangledName.contains("fU")
        })
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let entry = try #require(root.entryIndex)

        let changed = """
        @inline(never)
        func helper(_ value: Int, _ transform: (Int) -> Int) -> Int {
            transform(transform(value))
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value) { $0 + 3 }
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let changedSIL = try SwiftFrontend.Driver().emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: archive.metadata.frontendInvocation
        )
        let changedFile = try CanonicalSIL.File(text: changedSIL)
        let changedRoot = try #require(changedFile.functions.first {
            $0.mangledName == baselineRoot.mangledName
        })
        #expect(
            ReleaseCompiler.BodyFingerprint.compute(baselineRoot.body)
                == ReleaseCompiler.BodyFingerprint.compute(changedRoot.body)
        )

        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )

        #expect(result.changedFunctions.map(\.key) == [root.key])
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Optimized closure fusion is linked as a concrete specialization")
    func buildsOptimizedFusedClosureSpecialization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-fused-closure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        func helper(_ value: Int, _ transform: (Int) -> Int) -> Int {
            transform(transform(value))
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value) { $0 + 1 }
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let closureType = Bytecode.ValueType.closure(
            .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: .int64
            )
        )
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["Swift.Int", "(Swift.Int) -> Swift.Int"],
                result: "Swift.Int"
            ),
            helperParameterTypes: [.int64, closureType],
            helperEffects: .init(),
            helperCanonicalDeclaration:
                "func helper(_: Int, _: (Int) -> Int) -> Int",
            helperFormalType: "(Swift.Int, (Swift.Int) -> Swift.Int) -> Swift.Int"
        )
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let entry = try #require(root.entryIndex)
        let changed = """
        @inline(never)
        func helper(_ value: Int, _ transform: (Int) -> Int) -> Int {
            transform(transform(value))
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value) { $0 + 3 }
        }
        """
        try Data(changed.utf8).write(to: sourceURL)

        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        #expect(result.module.functions.contains {
            $0.kind == .concreteSpecialization
        })
        #expect(result.module.capabilities.contains(.compilerSpecializationsV1))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Production patches route changed generic helpers through concrete specializations")
    func buildsConcreteGenericSpecializationPatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-generic-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        func helper<T>(_ value: T, _ fallback: T, enabled: Bool) -> T {
            enabled ? value : fallback
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value + 1, value + 2, enabled: true)
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["T", "T", "Swift.Bool"],
                result: "T"
            ),
            helperParameterTypes: [.int64, .int64, .bool],
            helperEffects: .init(),
            helperIsGeneric: true,
            helperCanonicalDeclaration:
                "func helper<T>(_: T, _: T, enabled: Bool) -> T",
            helperFormalType: "<T>(T, T, Swift.Bool) -> T"
        )
        let helper = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("helper")
        })
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let entry = try #require(root.entryIndex)
        #expect(helper.patchability.reasonCode == "HLXIDX007")

        let changed = """
        @inline(never)
        func helper<T>(_ value: T, _ fallback: T, enabled: Bool) -> T {
            enabled ? fallback : value
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value + 1, value + 2, enabled: true)
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.changedFunctions.map(\.key) == [root.key])
        #expect(result.module.functions.count == 2)
        #expect(result.module.functions.contains {
            $0.kind == .concreteSpecialization
        })
        #expect(result.module.capabilities.contains(.compilerSpecializationsV1))
        #expect(result.disassembly.contains("@concreteSpecialization"))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 6, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Generic closure helpers link through concrete specializations")
    func buildsGenericClosureSpecializationPatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-generic-closure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        @inline(never)
        func helper<T>(_ value: T, by transform: (T) -> T) -> T {
            transform(value)
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value, by: { $0 + 1 })
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let closureType = Bytecode.ValueType.closure(
            .init(
                parameters: [.int64],
                parameterConventions: [.owned],
                result: .int64
            )
        )
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["T", "(T) -> T"],
                result: "T"
            ),
            helperParameterTypes: [.int64, closureType],
            helperEffects: .init(),
            helperIsGeneric: true,
            helperCanonicalDeclaration:
                "func helper<T>(_: T, by: (T) -> T) -> T",
            helperFormalType: "<T>(T, (T) -> T) -> T"
        )
        let helper = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("helper")
        })
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let entry = try #require(root.entryIndex)
        #expect(helper.patchability.reasonCode == "HLXIDX007")

        let changed = """
        @inline(never)
        func helper<T>(_ value: T, by transform: (T) -> T) -> T {
            transform(value)
        }
        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value, by: { $0 + 3 })
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.changedFunctions.map(\.key) == [root.key])
        #expect(result.module.functions.contains {
            $0.kind == .concreteSpecialization
        })
        #expect(result.module.capabilities.contains(.compilerSpecializationsV1))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(
                        try VM.Integer(
                            signed: 4,
                            bitWidth: 64,
                            isSigned: true
                        )
                    ),
                ]
            ) == .returned(
                .integer(
                    try VM.Integer(
                        signed: 7,
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            )
        )
    }

    @Test("Production generic helpers resolve concrete protocol witnesses")
    func buildsConcreteProtocolSpecializationPatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-protocol-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        private protocol Adjusting {
            func adjusted(by amount: Int) -> Int
        }

        extension Int: Adjusting {
            func adjusted(by amount: Int) -> Int { self + amount }
        }

        @inline(never)
        private func helper<Value: Adjusting>(
            _ value: Value,
            by amount: Int
        ) -> Int {
            value.adjusted(by: amount)
        }

        @inline(never)
        public func transform(_ value: Int) -> Int {
            helper(value, by: 1)
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            helperSignature: .init(
                parameters: ["Value", "Swift.Int"],
                result: "Swift.Int"
            ),
            helperParameterTypes: [.int64, .int64],
            helperEffects: .init(),
            helperIsGeneric: true,
            helperCanonicalDeclaration:
                "func helper<Value>(_: Value, by: Int) -> Int",
            helperFormalType: "<Value where Value : Adjusting> "
                + "(Value, Swift.Int) -> Swift.Int"
        )
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let entry = try #require(root.entryIndex)
        let changed = baseline.replacingOccurrences(
            of: "helper(value, by: 1)",
            with: "helper(value, by: 4)"
        )
        try Data(changed.utf8).write(to: sourceURL)

        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.changedFunctions.map(\.key) == [root.key])
        #expect(result.module.functions.contains {
            $0.kind == .concreteSpecialization
        })
        #expect(result.module.capabilities.contains(.compilerSpecializationsV1))
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(try VM.Integer(signed: 6, bitWidth: 64, isSigned: true)),
                ]
            ) == .returned(
                .integer(try VM.Integer(signed: 10, bitWidth: 64, isSigned: true))
            )
        )
    }

    @Test("Production patches link closed local existential witness tables")
    func buildsProtocolExistentialPatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-existential-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        private protocol Valued {
            func value() -> Int
        }

        private struct Item: Valued {
            var amount: Int
            func value() -> Int { amount * 2 }
        }

        @inline(never)
        private func erase(_ amount: Int) -> any Valued {
            Item(amount: amount)
        }

        @inline(never)
        private func read(_ value: any Valued) -> Int {
            value.value()
        }

        public func transform(_ value: Int) -> Int {
            read(erase(value)) + 1
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            additionalCapabilities: [
                .anyValuesV1,
                .borrowCallsV1,
                .compilerSpecializationsV1,
                .localNominalsV1,
            ]
        )
        let root = try #require(archive.functions.first {
            $0.canonicalDeclaration.contains("transform")
        })
        let entry = try #require(root.entryIndex)
        let changed = baseline.replacingOccurrences(
            of: "read(erase(value)) + 1",
            with: "read(erase(value)) + 4"
        )
        try Data(changed.utf8).write(to: sourceURL)

        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )

        #expect(result.changedFunctions.map(\.key) == [root.key])
        #expect(result.disassembly.contains("existential_apply"))
        #expect(result.module.functions.contains {
            $0.kind == .concreteSpecialization
        })
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [
                    .integer(
                        try VM.Integer(
                            signed: 5,
                            bitWidth: 64,
                            isSigned: true
                        )
                    ),
                ]
            ) == .returned(
                .integer(
                    try VM.Integer(
                        signed: 14,
                        bitWidth: 64,
                        isSigned: true
                    )
                )
            )
        )
    }

    @Test("Production replay preserves async ABI and rejects a newly suspending body")
    func buildsAsyncLeafAndRejectsAwait() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "helix-release-async-leaf-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = """
        public func transform(_ value: Int) async -> Int {
            value + 1
        }
        """
        try Data(baseline.utf8).write(to: sourceURL)

        let driver = ReleaseCompiler.Driver()
        let effects = Core.Effects(mayAllocate: true, isAsync: true)
        let archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: driver.toolchainIdentity().fingerprint,
            transformSignature: .init(
                parameters: ["Swift.Int"],
                result: "Swift.Int",
                isAsync: true
            ),
            transformCanonicalDeclaration:
                "func transform(_: Int) async -> Int",
            transformFormalType: "(Swift.Int) async -> Swift.Int",
            transformLoweredSILType:
                "@convention(thin) @async (Int) -> Int",
            transformEffects: effects
        )
        let record = try #require(archive.functions.first)
        let entry = try #require(record.entryIndex)
        #expect(record.effects.isAsync)
        #expect(archive.capabilities.contains(.asyncLeafEntriesV1))

        let changed = """
        public func transform(_ value: Int) async -> Int {
            value + 9
        }
        """
        try Data(changed.utf8).write(to: sourceURL)
        let result = try driver.build(
            .init(archive: archive, sourceFiles: [sourceURL])
        )
        let image = try Verification.Engine().verify(
            bytes: result.bytecode,
            shell: Verification.ShellInterface(archive: archive),
            policy: .init(acceptedCapabilities: Set(archive.capabilities))
        )
        let input = try VM.Integer(signed: 4, bitWidth: 64, isSigned: true)
        #expect(
            VM.Interpreter().invoke(
                entry: entry,
                image: image,
                arguments: [.integer(input)],
                rootContext: .generatedAsyncBridge
            ) == .returned(
                .integer(try VM.Integer(signed: 13, bitWidth: 64, isSigned: true))
            )
        )

        let suspending = """
        public func transform(_ value: Int) async -> Int {
            await Task.yield()
            return value + 9
        }
        """
        try Data(suspending.utf8).write(to: sourceURL)
        do {
            _ = try driver.build(
                .init(archive: archive, sourceFiles: [sourceURL])
            )
            Issue.record("expected a newly suspending async body to be rejected")
        } catch let error as CanonicalSIL.LoweringError {
            #expect(error.description.contains("async leaf profile"))
            #expect(error.description.contains("can suspend"))
        }
    }

    @Test("The exact iOS SDK build is enforced before SIL replay")
    func enforcesSDKBuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-sdk-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Patch.swift")
        let baseline = "public func transform(_ x: Int) -> Int { x + 1 }\n"
        try Data(baseline.utf8).write(to: sourceURL)
        let driver = ReleaseCompiler.Driver()
        let toolchain = try driver.toolchainIdentity()
        var archive = try makeArchive(
            sourceURL: sourceURL,
            baselineSource: baseline,
            compilerFingerprint: toolchain.fingerprint
        )
        archive.metadata.sdkBuild = "SDK-BUILD-NOT-INSTALLED"
        archive.metadata.frontendInvocation.sdkBuild = "SDK-BUILD-NOT-INSTALLED"
        try Data("public func transform(_ x: Int) -> Int { x + 9 }\n".utf8).write(to: sourceURL)

        #expect(throws: SwiftFrontend.Error.self) {
            try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
        }
        do {
            _ = try driver.build(.init(archive: archive, sourceFiles: [sourceURL]))
            Issue.record("expected the frozen SDK build check to fail")
        } catch let error as SwiftFrontend.Error {
            guard case let .sdkBuildMismatch(expected, actual) = error else {
                Issue.record("unexpected frontend error: \(error)")
                return
            }
            #expect(expected == "SDK-BUILD-NOT-INSTALLED")
            #expect(!actual.isEmpty)
        }
    }

    private func makeArchive(
        sourceURL: URL,
        baselineSource: String,
        compilerFingerprint: String,
        transformSignature: Core.LoweredSignature = .init(
            parameters: ["Swift.Int"],
            result: "Swift.Int"
        ),
        transformParameterTypes: [Bytecode.ValueType] = [.int64],
        transformParameterConventions: [Bytecode.ParameterConvention]? = nil,
        transformResultType: Bytecode.ValueType = .int64,
        transformCanonicalDeclaration: String = "func transform(_: Int) -> Int",
        transformFormalType: String = "(Swift.Int) -> Swift.Int",
        transformLoweredSILType: String = "@convention(thin) (Int) -> Int",
        transformEffects: Core.Effects = .init(mayAllocate: true),
        helperSignature: Core.LoweredSignature? = nil,
        helperParameterTypes: [Bytecode.ValueType] = [.int64],
        helperParameterConventions: [Bytecode.ParameterConvention]? = nil,
        helperResultType: Bytecode.ValueType = .int64,
        helperEffects: Core.Effects? = nil,
        helperHasInOut: Bool = false,
        helperIsGeneric: Bool = false,
        helperCanonicalDeclaration: String = "func helper(_: Int) -> Int",
        helperFormalType: String? = nil,
        helperLoweredSILType: String? = nil,
        helperExposure: HelperExposure = .shellEntry,
        emitHelperImport: Bool = true,
        optimization: String = "-O",
        additionalCapabilities: Set<Core.Capability> = [],
        nativeTypes: [InterfaceArchive.TypeRecord] = []
    ) throws -> InterfaceArchive.Archive {
        let moduleName = "ReleaseDriverFixture"
        let frontend = SwiftFrontend.Driver()
        let sdk = try frontend.sdkIdentity(name: "iphoneos")
        let invocation = InterfaceArchive.FrontendInvocation(
            moduleName: moduleName,
            targetTriple: "arm64-apple-ios15.0",
            sdkName: sdk.name,
            sdkBuild: sdk.buildVersion,
            optimization: optimization
        )
        let sil = try frontend.emitCanonicalSIL(
            sourceFiles: [sourceURL],
            invocation: invocation
        )
        let parsed = try CanonicalSIL.File(text: sil)
        let transform = try #require(parsed.functions.first {
            $0.mangledName.contains("transform")
                && !$0.mangledName.contains("cfU")
                && !$0.mangledName.contains("fU")
                && !$0.mangledName.contains("_Tg")
                && !$0.mangledName.contains("Tf")
                && !ReleaseCompiler.ImplementationFingerprint
                    .isDefaultArgumentGenerator($0.mangledName)
        })
        let helperMatches = parsed.functions.filter {
            $0.mangledName.contains("helper")
                && !$0.mangledName.contains("cfU")
                && !$0.mangledName.contains("fU")
                && !$0.mangledName.contains("_Tg")
                && !$0.mangledName.contains("Tf")
                && !ReleaseCompiler.ImplementationFingerprint
                    .isDefaultArgumentGenerator($0.mangledName)
        }
        let helper = helperMatches.count == 1 ? helperMatches[0] : nil
        let lockedMatches = parsed.functions.filter { $0.mangledName.contains("locked") }
        let locked = lockedMatches.count == 1 ? lockedMatches[0] : nil
        var archivedSymbols: Set<String> = [transform.mangledName]
        if let helper { archivedSymbols.insert(helper.mangledName) }
        if let locked { archivedSymbols.insert(locked.mangledName) }

        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.release-driver",
            buildNumber: "1",
            seed: "fixture"
        )
        let metadata = InterfaceArchive.ReleaseMetadata(
            bundleID: "dev.helix.release-driver",
            buildNumber: "1",
            shellNamespaceID: namespace,
            machOUUIDs: [UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!],
            targetTriple: "arm64-apple-ios15.0",
            minimumOS: .init(15),
            xcodeBuild: "fixture",
            sdkBuild: sdk.buildVersion,
            frontendInvocation: invocation,
            transformPipelineHash: .sha256("release-driver-transform"),
            sourceBaselineHash: .sha256("replaced-by-indexer")
        )
        let helperCallee = "\(moduleName).helper(_:)"
        let configuration = PatchConfiguration.Document(
            modules: [
                moduleName: .init(
                    include: ["Patch.swift"],
                    nativeImports: helperExposure == .nativeImport && emitHelperImport
                        ? .init(
                            candidateIndex: .explicitCatalog,
                            emit: .allowlisted,
                            allow: [helperCallee]
                        )
                        : .init()
                ),
            ]
        )
        let signature = transformSignature
        let interface = ReleaseCompiler.DeclarationInterface(
            declarationKind: "function",
            baseName: "transform",
            argumentLabels: ["_"],
            accessLevel: "public",
            canonicalFormalType: transformFormalType,
            loweredSILType: transformLoweredSILType,
            effects: transformEffects
        )
        var declarations: [ReleaseCompiler.DeclarationCandidate] = [
            .init(
                moduleName: moduleName,
                sourceFileLogicalID: "Patch.swift",
                canonicalDeclaration: transformCanonicalDeclaration,
                mangledName: transform.mangledName,
                role: .function,
                loweredSignature: signature,
                parameterTypes: transformParameterTypes,
                parameterConventions: transformParameterConventions,
                resultType: transformResultType,
                interface: interface,
                canonicalSILBody: transform.body,
                implementationFingerprint:
                    ReleaseCompiler.ImplementationFingerprint.compute(
                        root: transform,
                        in: parsed,
                        archivedSymbols: archivedSymbols
                    ),
                effects: transformEffects,
                isAsync: transformEffects.isAsync
            ),
        ]
        if let helper {
            let resolvedHelperSignature = helperSignature ?? signature
            let resolvedHelperEffects = helperEffects ?? transformEffects
            var helperInterface = interface
            helperInterface.baseName = "helper"
            helperInterface.effects = resolvedHelperEffects
            helperInterface.canonicalFormalType = helperFormalType
                ?? helperInterface.canonicalFormalType
            helperInterface.loweredSILType = helperLoweredSILType
                ?? helper.loweredType
            if helperIsGeneric { helperInterface.genericSignature = "<T>" }
            declarations.append(
                .init(
                    moduleName: moduleName,
                    sourceFileLogicalID: "Patch.swift",
                    canonicalDeclaration: helperCanonicalDeclaration,
                    mangledName: helper.mangledName,
                    role: .function,
                    loweredSignature: resolvedHelperSignature,
                    parameterTypes: helperParameterTypes,
                    parameterConventions: helperParameterConventions,
                    resultType: helperResultType,
                    interface: helperInterface,
                    canonicalSILBody: helper.body,
                    implementationFingerprint:
                        ReleaseCompiler.ImplementationFingerprint.compute(
                            root: helper,
                            in: parsed,
                            archivedSymbols: archivedSymbols
                        ),
                    effects: resolvedHelperEffects,
                    isAsync: resolvedHelperEffects.isAsync,
                    hasInOut: helperHasInOut,
                    isGeneric: helperIsGeneric,
                    forcedPatchability: helperExposure == .nativeImport
                        ? .rejected(
                            "HLXIDX901",
                            explanation: "fixture exposes helper only as a typed native import"
                        )
                        : nil
                )
            )
        }
        if let locked {
            var lockedInterface = interface
            lockedInterface.baseName = "locked"
            declarations.append(
                .init(
                    moduleName: moduleName,
                    sourceFileLogicalID: "Patch.swift",
                    canonicalDeclaration: "func locked(_: Int) -> Int",
                    mangledName: locked.mangledName,
                    role: .function,
                    loweredSignature: signature,
                    parameterTypes: [.int64],
                    resultType: .int64,
                    interface: lockedInterface,
                    canonicalSILBody: locked.body,
                    implementationFingerprint:
                        ReleaseCompiler.ImplementationFingerprint.compute(
                            root: locked,
                            in: parsed,
                            archivedSymbols: archivedSymbols
                        ),
                    effects: transformEffects,
                    isAsync: transformEffects.isAsync,
                    forcedPatchability: .rejected(
                        "HLXIDX900",
                        explanation: "fixture policy rejects this declaration"
                    )
                )
            )
        }
        var nativeImports: [InterfaceArchive.NativeImportRecord] = []
        if let helper, helperExposure == .nativeImport {
            let resolvedHelperSignature = helperSignature ?? signature
            let resolvedHelperEffects = helperEffects ?? transformEffects
            let contract = Core.NativeImportContract.bounded(
                kind: .globalFunction,
                domain: .application,
                access: .pure,
                maximumDurationMicroseconds: 1_000,
                allowsMainThread: true
            )
            let key = try Core.NativeImportKey.derive(
                namespace: namespace,
                canonicalCallee: helperCallee,
                signature: resolvedHelperSignature,
                effects: resolvedHelperEffects,
                contract: contract
            )
            nativeImports.append(
                .init(
                    id: nil,
                    key: key,
                    canonicalCallee: helperCallee,
                    silMangledNames: [helper.mangledName],
                    parameterTypes: helperParameterTypes,
                    resultType: helperResultType,
                    signature: resolvedHelperSignature,
                    effects: resolvedHelperEffects,
                    contract: contract,
                    isEmittedToDevice: true
                )
            )
        }
        let report = try ReleaseCompiler.Indexer().index(
            .init(
                metadata: metadata,
                compatibility: .init(
                    runtime: Core.Versions.runtime,
                    bytecode: Core.Versions.bytecode,
                    interfaceArchive: Core.Versions.interfaceArchive,
                    compilerFingerprint: compilerFingerprint
                ),
                configuration: configuration,
                sources: [
                    .init(logicalPath: "Patch.swift", contentHash: .sha256(Data(baselineSource.utf8))),
                ],
                declarations: declarations,
                nativeImportCandidates: nativeImports,
                nativeTypes: nativeTypes,
                capabilities: additionalCapabilities
            )
        )
        return report.archive
    }
}
}
