import Darwin
import Foundation

/// 用 Process + 管道把子进程输出按行切好，回调到主线程。
public final class StreamingProcess {
    public enum Stream {
        case stdout
        case stderr
    }

    public var onLine: ((Stream, String) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let bufferQueue = DispatchQueue(label: "com.chensinuo.mactoolbox.process-buffer")
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var didExit = false

    public init() {}

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    public func start(
        command: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]
    ) throws {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle, stream: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle, stream: .stderr)
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.flushRemaining()
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard !self.didExit else { return }
                self.didExit = true
                self.onExit?(finished.terminationStatus)
            }
        }

        try process.run()
    }

    public func sendLine(_ line: String) {
        guard process.isRunning else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func terminate(grace: TimeInterval = 2.0, force: Bool = false) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        guard process.isRunning || ProcessTree.isAlive(pid) else { return }

        if force {
            ProcessTree.killTree(pid: pid, signal: SIGKILL)
            return
        }

        ProcessTree.killTree(pid: pid, signal: SIGTERM)
        guard grace > 0 else {
            ProcessTree.killTree(pid: pid, signal: SIGKILL)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            guard let self, self.process.isRunning || ProcessTree.isAlive(pid) else { return }
            ProcessTree.killTree(pid: pid, signal: SIGKILL)
        }
    }

    private func consume(_ handle: FileHandle, stream: Stream) {
        let data = handle.availableData
        guard !data.isEmpty else { return }

        var lines: [String] = []
        bufferQueue.sync {
            switch stream {
            case .stdout:
                stdoutBuffer.append(data)
                lines = Self.extractLines(from: &stdoutBuffer)
            case .stderr:
                stderrBuffer.append(data)
                lines = Self.extractLines(from: &stderrBuffer)
            }
        }
        for line in lines {
            DispatchQueue.main.async { [weak self] in
                self?.onLine?(stream, line)
            }
        }
    }

    private func flushRemaining() {
        var lines: [(Stream, String)] = []
        bufferQueue.sync {
            let out = Self.extractLines(from: &stdoutBuffer)
            let err = Self.extractLines(from: &stderrBuffer)
            lines = out.map { (.stdout, $0) } + err.map { (.stderr, $0) }
        }
        for (stream, line) in lines {
            DispatchQueue.main.async { [weak self] in
                self?.onLine?(stream, line)
            }
        }
    }

    private static func extractLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }
}
