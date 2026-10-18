import Darwin
import Foundation

/// 进程树操作：清理脚本/ffmpeg/whisper 这类多级子进程。
public enum ProcessTree {
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public static func commandLines() -> [(pid: Int32, command: String)] {
        if let output = run("/bin/ps", ["-axo", "pid=,command="]) {
            let parsed = parse(output)
            if !parsed.isEmpty { return parsed }
        }
        // 部分受限沙箱里 /bin/ps 被拒绝，但 pgrep 可用。
        if let output = run("/usr/bin/pgrep", ["-fl", "."]) {
            return parse(output)
        }
        return []
    }

    public static func command(for pid: Int32) -> String? {
        commandLines().first(where: { $0.pid == pid })?.command
    }

    private static func parse(_ output: String) -> [(pid: Int32, command: String)] {
        var result: [(Int32, String)] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let split = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
            guard let pid = Int32(trimmed[..<split]) else { continue }
            let command = String(trimmed[split...]).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            result.append((pid, command))
        }
        return result
    }

    public static func descendants(of pid: Int32) -> [Int32] {
        guard pid > 0 else { return [] }
        var seen = Set<Int32>()
        var result: [Int32] = []
        func walk(_ parent: Int32) {
            guard let output = run("/usr/bin/pgrep", ["-P", "\(parent)"]) else { return }
            for line in output.split(separator: "\n") {
                guard let child = Int32(line.trimmingCharacters(in: .whitespaces)),
                      child > 0,
                      seen.insert(child).inserted else { continue }
                result.append(child)
                walk(child)
            }
        }
        walk(pid)
        return result
    }

    /// 先叶子后父进程；force 时直接 SIGKILL。
    public static func killTree(pid: Int32, signal: Int32 = SIGKILL) {
        guard pid > 0 else { return }
        for child in descendants(of: pid).reversed() {
            kill(child, signal)
        }
        kill(pid, signal)
    }

    public static func terminate(pid: Int32, grace: TimeInterval = 2.0) {
        guard pid > 0 else { return }
        killTree(pid: pid, signal: SIGTERM)
        guard grace > 0 else {
            killTree(pid: pid, signal: SIGKILL)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if isAlive(pid) {
                killTree(pid: pid, signal: SIGKILL)
            }
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
