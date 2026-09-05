import Foundation

extension SwiftFrontend.Driver {
    func emitSILFile(arguments: [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helix-sil-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Module.sil")
        // Driver jobs that generate a bridging PCH can redirect `-o -` SIL to
        // stderr. A dedicated output file keeps diagnostics out of the parser.
        let output = try run(arguments: arguments + ["-o", file.path])
        guard output.terminationStatus == 0 else {
            throw SwiftFrontend.Error.compilationFailed(status: output.terminationStatus,
                                                        diagnostics: output.standardError)
        }
        guard let bytes = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            throw SwiftFrontend.Error.compilationFailed(status: -1,
                diagnostics: "compiler succeeded without producing canonical SIL\n" + output.standardError)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SwiftFrontend.Error.invalidUTF8Output
        }
        guard text.hasPrefix("sil_stage canonical\n") else {
            throw SwiftFrontend.Error.compilationFailed(status: -1,
                diagnostics: "compiler output is not canonical SIL\n" + output.standardError)
        }
        return text
    }
}
