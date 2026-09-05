import Foundation
import HelixCore
import Testing
@testable import HelixBuildTools

extension BuildToolsTests {
@Suite("Swift compiler wrapper coexistence")
struct CompilerWrapperTests {
    @Test("A downstream launcher receives the exact compiler and arguments")
    func forwardsCompilerAndArguments() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let map = fixture.root.appendingPathComponent("Target/Objects-normal/arm64/Output Map.json")
        let arguments = ["-module-name", "Fixture", "-target", "arm64-apple-ios15.0", "-sdk", "/Fixture SDK",
                         "-output-file-map", map.path, "Source with spaces.swift", "literal\\value"]
        let output = try fixture.run(arguments, wrapper: fixture.wrapper.path)
        #expect(output.status == 0, "\(output.error)")
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("compiler.txt"), encoding: .utf8) == fixture.compiler.path)
        let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("arguments.bin"))
        #expect(bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } == arguments)
        let capture = try Data(contentsOf: fixture.root.appendingPathComponent("Target/Helix/FrontendInvocation.hlxswiftc"))
        let tokens = capture.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(tokens == [XcodeIntegration.CompilerCapture.recordMarker, fixture.compiler.path] + arguments)
        #expect(try fixture.run(["--version"], wrapper: fixture.wrapper.path, status: "7").status == 7)
    }

    @Test("Invalid wrapper and recursive compiler settings fail with actionable diagnostics")
    func rejectsInvalidAndRecursiveWrappers() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for wrapper in ["relative.sh", fixture.root.appendingPathComponent("Missing").path, fixture.proxy.path, fixture.compiler.path] {
            let output = try fixture.run(["--version"], wrapper: wrapper)
            #expect(output.status == 2)
            #expect(output.error.contains("HELIX_SWIFT_COMPILER_WRAPPER"))
        }
        try Data("#!/bin/sh\nexec \"$HELIX_TEST_PROXY\" --version\n".utf8).write(to: fixture.wrapper)
        let recursive = try fixture.run(["--version"], wrapper: fixture.wrapper.path)
        #expect(recursive.status == 2)
        #expect(recursive.error.contains("recursive Helix compiler invocation"))
        let selfCompiler = try fixture.run(["--version"], wrapper: "", realCompiler: fixture.proxy.path)
        #expect(selfCompiler.status == 2)
        #expect(selfCompiler.error.contains("points to the Helix proxy itself"))
    }

    private struct Fixture {
        var root: URL
        var proxy: URL
        var compiler: URL
        var wrapper: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("helix-wrapper-\(UUID().uuidString)")
            proxy = root.appendingPathComponent("Proxy/swiftc")
            compiler = root.appendingPathComponent("Toolchain/swiftc")
            wrapper = root.appendingPathComponent("Compiler Wrapper.sh")
            for directory in [proxy.deletingLastPathComponent(), compiler.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try XcodeIntegration.CompilerCapture.proxyScript().write(to: proxy)
            try Data("""
            #!/bin/sh
            printf '%s\\0' "$@" > "$HELIX_TEST_ROOT/arguments.bin"
            exit "${HELIX_TEST_STATUS:-0}"
            """.utf8).write(to: compiler)
            try Data("""
            #!/bin/sh
            compiler="$1"
            shift
            printf '%s' "$compiler" > "$HELIX_TEST_ROOT/compiler.txt"
            exec "$compiler" "$@"
            """.utf8).write(to: wrapper)
            for url in [proxy, compiler, wrapper] {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func run(_ arguments: [String], wrapper: String, status: String = "0", realCompiler: String? = nil) throws -> (status: Int32, error: String) {
            let process = Process()
            let errors = Pipe()
            process.executableURL = proxy
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["HELIX_COMPILER_PROXY_ACTIVE"] = nil
            environment["HELIX_REAL_SWIFT_EXEC"] = realCompiler ?? compiler.path
            environment["HELIX_SWIFT_COMPILER_WRAPPER"] = wrapper
            environment["HELIX_TEST_ROOT"] = root.path
            environment["HELIX_TEST_PROXY"] = proxy.path
            environment["HELIX_TEST_STATUS"] = status
            process.environment = environment
            process.standardError = errors
            try process.run()
            let error = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: error, as: UTF8.self))
        }
    }
}
}
