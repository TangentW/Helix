import Darwin
import Dispatch
import Foundation
import HelixCLIKit

enum Main {
final class OutputWriter: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ output: CLI.Output) {
        lock.lock()
        defer { lock.unlock() }
        switch output {
        case let .standardOutput(text):
            FileHandle.standardOutput.write(Data(text.utf8))
        case let .standardError(text):
            FileHandle.standardError.write(Data(text.utf8))
        }
    }
}

final class TaskCancellation<Success: Sendable>: Sendable {
    private let task: Task<Success, Never>

    init(_ task: Task<Success, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}
}

let writer = Main.OutputWriter()
let task = Task {
    await CLI.Application().runAsync(
        Array(CommandLine.arguments.dropFirst()),
        outputHandler: writer.write
    )
}
let cancellation = Main.TaskCancellation(task)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalQueue = DispatchQueue(label: "dev.helix.cli-signals")
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
interruptSource.setEventHandler(handler: { @Sendable in cancellation.cancel() })
terminateSource.setEventHandler(handler: { @Sendable in cancellation.cancel() })
interruptSource.resume()
terminateSource.resume()

let result = await task.value
interruptSource.cancel()
terminateSource.cancel()
if !result.standardOutput.isEmpty {
    FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
}
if !result.standardError.isEmpty {
    FileHandle.standardError.write(Data(result.standardError.utf8))
}
exit(result.exitCode)
