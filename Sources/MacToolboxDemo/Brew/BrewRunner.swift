import Darwin
import Foundation
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct BrewCommandResult {
    let output: String
    let error: String
    let status: Int32
    let timedOut: Bool
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}

enum BrewRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 60
    ) async throws -> BrewCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutTask = Task.detached(priority: .userInitiated) {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .userInitiated) {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }

        let timedOut = LockedFlag()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: BrewError.commandFailed("无法启动 brew：\(error.localizedDescription)"))
                return
            }

            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard ProcessTree.isAlive(pid) else { return }
                timedOut.set()
                ProcessTree.killTree(pid: pid, signal: SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if ProcessTree.isAlive(pid) {
                        ProcessTree.killTree(pid: pid, signal: SIGKILL)
                    }
                }
            }
        }

        let outputData = await stdoutTask.value
        let errorData = await stderrTask.value
        return BrewCommandResult(
            output: String(data: outputData, encoding: .utf8) ?? "",
            error: String(data: errorData, encoding: .utf8) ?? "",
            status: status,
            timedOut: timedOut.value
        )
    }

    static func findBrew() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/home/linuxbrew/.linuxbrew/bin/brew"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/brew"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
    }
}
