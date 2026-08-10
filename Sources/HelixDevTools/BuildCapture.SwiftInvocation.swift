import Foundation
import HelixCore

extension BuildCapture {
/// Binary NUL-delimited record written by the Xcode Swift compiler proxy.
public enum SwiftInvocationRecord {
    public static let maximumByteCount = 8 * 1_024 * 1_024
    public static let maximumArgumentCount = 65_536

    public static func decode(_ data: Data) throws -> BuildCapture.CapturedFrontendJob {
        guard !data.isEmpty, data.count <= maximumByteCount, data.last == 0 else {
            throw BuildCapture.Error.malformedCommand(
                "Swift invocation record is empty, oversized, or unterminated"
            )
        }
        var fields: [Data] = []
        var fieldStart = data.startIndex
        for index in data.indices where data[index] == 0 {
            fields.append(Data(data[fieldStart..<index]))
            fieldStart = data.index(after: index)
        }
        guard fieldStart == data.endIndex,
              fields.count >= 2,
              fields.count - 2 <= maximumArgumentCount,
              let marker = String(data: fields[0], encoding: .utf8),
              marker == Core.CompilerCapture.recordMarker,
              let executable = String(data: fields[1], encoding: .utf8),
              executable.hasPrefix("/"),
              !executable.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw BuildCapture.Error.malformedCommand(
                "Swift invocation record has an invalid header or compiler"
            )
        }
        let arguments = try fields.dropFirst(2).map { field -> String in
            guard let value = String(data: field, encoding: .utf8) else {
                throw BuildCapture.Error.malformedCommand(
                    "Swift invocation record contains non-UTF-8 arguments"
                )
            }
            return value
        }
        return .init(
            executable: executable,
            arguments: arguments,
            sourceLine: "Helix Xcode Swift compiler capture"
        )
    }
}

public struct SwiftInvocationReader: Sendable {
    public init() {}

    public func readFrontendJob(at url: URL) throws -> BuildCapture.CapturedFrontendJob {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let byteCount = (attributes[.size] as? NSNumber)?.uint64Value,
              byteCount <= UInt64(BuildCapture.SwiftInvocationRecord.maximumByteCount)
        else {
            throw BuildCapture.Error.noFrontendCommand
        }
        do {
            return try BuildCapture.SwiftInvocationRecord.decode(
                Data(contentsOf: url, options: .mappedIfSafe)
            )
        } catch let error as BuildCapture.Error {
            throw error
        } catch {
            throw BuildCapture.Error.malformedCommand(String(describing: error))
        }
    }
}
}
