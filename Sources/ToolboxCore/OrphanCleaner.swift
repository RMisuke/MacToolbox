import Darwin
import Foundation

public struct OrphanCleanupReport {
    public var killedPIDs: [Int32] = []
    public var directories: [String] = []
    public var logURL: URL?
    public var isEmpty: Bool { killedPIDs.isEmpty }
}

public enum OrphanCleaner {
    /// 启动时扫描任务目录：如果进程命令行仍引用这些目录，说明上次退出留下了
    /// Python/ffmpeg/whisper 子进程，直接清理整棵进程树并删除 child.pid。
    @discardableResult
    public static func cleanup() -> OrphanCleanupReport {
        var report = OrphanCleanupReport()
        let jobsDirectory = ToolboxPaths.jobs
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: jobsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return report }

        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !directories.isEmpty else { return report }

        let processes = ProcessTree.commandLines()
        let currentPID = getpid()
        var killed = Set<Int32>()

        for directory in directories {
            let jobID = directory.lastPathComponent
            let marker = "/Jobs/\(jobID)"
            let pidFile = directory.appendingPathComponent("child.pid")

            for process in processes where process.pid != currentPID {
                guard process.command.contains(marker) else { continue }
                if killed.insert(process.pid).inserted {
                    ProcessTree.killTree(pid: process.pid, signal: SIGKILL)
                }
            }

            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               ProcessTree.isAlive(pid),
               let command = ProcessTree.command(for: pid),
               command.contains(marker) {
                if killed.insert(pid).inserted {
                    ProcessTree.killTree(pid: pid, signal: SIGKILL)
                }
            }

            try? FileManager.default.removeItem(at: pidFile)
            report.directories.append(jobID)
        }

        report.killedPIDs = Array(killed).sorted()
        if !report.killedPIDs.isEmpty {
            report.logURL = appendLog(
                "killed \(report.killedPIDs.map(String.init).joined(separator: ",")) in \(report.directories.count) job dirs"
            )
        }
        return report
    }

    private static func appendLog(_ message: String) -> URL? {
        let url = ToolboxPaths.applicationSupport.appendingPathComponent("orphan-cleanup.log")
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return nil }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        return url
    }
}
