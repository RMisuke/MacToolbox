import Combine
import Foundation

// MARK: - Shared state

public struct AgentJobStep: Codable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let state: String

    public init(id: String, title: String, state: String) {
        self.id = id
        self.title = title
        self.state = state
    }
}

/// `AgentJobs/<jobID>/job.json` 的 Swift 视图。
/// Python 侧是 `scripts/agent_jobs.py`；字段变更时两边同步。
public struct AgentJobRecord: Codable, Identifiable {
    public let version: Int?
    public let id: String
    public let toolID: String
    public let toolName: String
    public let title: String?
    public let itemLabel: String?
    public let source: String?
    public let status: String
    public let progress: Double?
    public let summary: String?
    public let error: String?
    public let jobDir: String?
    public let logPath: String?
    public let pid: Int?
    public let resources: [String]?
    public let createdAt: Date?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let finishedAt: Date?
    public let steps: [AgentJobStep]?
    public let artifacts: [Artifact]?
    public let checkpoint: Checkpoint?
    public let batchID: String?
    public let batchIndex: Int?
    public let batchTotal: Int?
    public let cancelRequested: Bool?
    public let eventsPath: String?

    public var progressValue: Double {
        min(max(progress ?? 0, 0), 1)
    }

    public var isActive: Bool {
        ["queued", "running", "waiting"].contains(status)
    }

    public var isWaiting: Bool {
        status == "waiting"
    }

    public var isStale: Bool {
        guard isActive, let updatedAt else { return false }
        return Date().timeIntervalSince(updatedAt) > 90
    }

    public var statusLabel: String {
        switch status {
        case "queued": return "排队中"
        case "running": return "运行中"
        case "waiting": return "等待确认"
        case "succeeded": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        case "timeout": return "已超时"
        case "interrupted": return "已中断"
        case "skipped": return "已跳过"
        default: return status
        }
    }

    public var sourceLabel: String {
        switch source {
        case "mcp": return "MCP"
        case "batch": return "批量"
        case "resume": return "续跑"
        default: return "CLI"
        }
    }

    public var displayTitle: String {
        title ?? itemLabel ?? toolName
    }
}

// MARK: - Monitor

/// 轮询 AgentJobs 目录，让 GUI 能实时看到 CLI/MCP 发起的任务。
@MainActor
public final class AgentJobMonitor: ObservableObject {
    @Published public private(set) var jobs: [AgentJobRecord] = []
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var lastError: String?

    public let root: URL
    private var timer: Timer?
    private let decoder: JSONDecoder

    public init(root: URL? = nil) {
        self.root = root ?? ToolboxPaths.applicationSupport
            .appendingPathComponent("AgentJobs", isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public var activeCount: Int {
        jobs.filter(\.isActive).count
    }

    public var hasJobs: Bool {
        !jobs.isEmpty
    }

    public func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            if !jobs.isEmpty { jobs = [] }
            lastRefresh = Date()
            return
        }
        guard let children = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            lastError = "无法读取 AgentJobs 目录"
            return
        }

        var loaded: [AgentJobRecord] = []
        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let manifest = child.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: manifest) else { continue }
            if let record = try? decoder.decode(AgentJobRecord.self, from: data) {
                loaded.append(record)
            }
        }
        loaded.sort {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        jobs = Array(loaded.prefix(100))
        lastError = nil
        lastRefresh = Date()
    }

    public func cancel(_ job: AgentJobRecord) {
        guard job.isActive else { return }
        let directory = root.appendingPathComponent(job.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = ISO8601DateFormatter().string(from: Date()) + " GUI cancel request\n"
        try? Data(payload.utf8).write(to: directory.appendingPathComponent("cancel.request"))
        refresh()
    }

    public func clearFinished() {
        let manager = FileManager.default
        for job in jobs where !job.isActive {
            let directory = root.appendingPathComponent(job.id, isDirectory: true)
            try? manager.removeItem(at: directory)
        }
        refresh()
    }

    public func logTail(_ job: AgentJobRecord, limit: Int = 240) -> [String] {
        let path = job.eventsPath.map { URL(fileURLWithPath: $0) }
            ?? (job.logPath.map { URL(fileURLWithPath: $0) }
                ?? root.appendingPathComponent(job.id).appendingPathComponent("events.jsonl"))
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(limit).map(String.init))
    }
}
