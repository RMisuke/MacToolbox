import Combine
import Foundation

// MARK: - Records

public enum JobStatus: String, Codable {
    case queued
    case running
    case waiting
    case succeeded
    case failed
    case cancelled
    case interrupted
    case skipped

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .skipped: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "运行中"
        case .waiting: return "等待确认"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        case .skipped: return "已跳过"
        }
    }
}

public enum GroupStatus: String, Codable {
    case queued
    case running
    case waiting
    case succeeded
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "运行中"
        case .waiting: return "等待确认"
        case .succeeded: return "已完成"
        case .failed: return "有失败项"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        }
    }
}

public struct JobStepRecord: Codable, Identifiable {
    public var id: String
    public var title: String
    public var state: String

    public init(id: String, title: String, state: String) {
        self.id = id
        self.title = title
        self.state = state
    }
}

public struct JobRecord: Codable, Identifiable {
    public var id: String
    public var toolID: String
    public var toolName: String
    public var groupID: String?
    public var itemLabel: String?
    public var values: [String: FieldValue]
    public var state: JobStatus
    public var progress: Double
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var jobDirectory: String?
    public var errorMessage: String?
    public var summary: String?
    public var steps: [JobStepRecord]
    public var artifacts: [Artifact]
    public var isResumable: Bool
    public var fingerprint: String?

    public init(
        id: String,
        toolID: String,
        toolName: String,
        groupID: String? = nil,
        itemLabel: String? = nil,
        values: [String: FieldValue],
        state: JobStatus = .queued,
        progress: Double = 0,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        jobDirectory: String? = nil,
        errorMessage: String? = nil,
        summary: String? = nil,
        steps: [JobStepRecord] = [],
        artifacts: [Artifact] = [],
        isResumable: Bool = false,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.toolID = toolID
        self.toolName = toolName
        self.groupID = groupID
        self.itemLabel = itemLabel
        self.values = values
        self.state = state
        self.progress = progress
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.jobDirectory = jobDirectory
        self.errorMessage = errorMessage
        self.summary = summary
        self.steps = steps
        self.artifacts = artifacts
        self.isResumable = isResumable
        self.fingerprint = fingerprint
    }
}

public struct JobGroupRecord: Codable, Identifiable {
    public var id: String
    public var toolID: String
    public var toolName: String
    public var title: String
    public var state: GroupStatus
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var childIDs: [String]
    public var currentChildID: String?
    public var values: [String: FieldValue]
    public var outputDirectory: String?
    public var isBatch: Bool
    public var stopOnError: Bool
    public var errorMessage: String?

    public init(
        id: String,
        toolID: String,
        toolName: String,
        title: String,
        state: GroupStatus = .queued,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        childIDs: [String],
        currentChildID: String? = nil,
        values: [String: FieldValue],
        outputDirectory: String? = nil,
        isBatch: Bool = false,
        stopOnError: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.toolID = toolID
        self.toolName = toolName
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.childIDs = childIDs
        self.currentChildID = currentChildID
        self.values = values
        self.outputDirectory = outputDirectory
        self.isBatch = isBatch
        self.stopOnError = stopOnError
        self.errorMessage = errorMessage
    }
}

// MARK: - Store

private struct JobStoreFile: Codable {
    var version: Int
    var jobs: [JobRecord]
    var groups: [JobGroupRecord]
}

@MainActor
public final class JobStore: ObservableObject {
    @Published public private(set) var jobs: [JobRecord] = []
    @Published public private(set) var groups: [JobGroupRecord] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let directory = ToolboxPaths.applicationSupport
        fileURL = directory.appendingPathComponent("records.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
        markInterrupted()
    }

    // MARK: Queries

    public var recentGroups: [JobGroupRecord] {
        groups.sorted { $0.createdAt > $1.createdAt }
    }

    public var resumableGroups: [JobGroupRecord] {
        groups.filter { group in
            guard group.state == .interrupted || group.state == .failed else { return false }
            return children(of: group).contains { $0.state == .interrupted || $0.state == .failed || $0.state == .queued }
        }
    }

    public func job(id: String) -> JobRecord? {
        jobs.first(where: { $0.id == id })
    }

    public func group(id: String) -> JobGroupRecord? {
        groups.first(where: { $0.id == id })
    }

    public func children(of group: JobGroupRecord) -> [JobRecord] {
        group.childIDs.compactMap { job(id: $0) }
    }

    public func progress(of group: JobGroupRecord) -> Double {
        let children = children(of: group)
        guard !children.isEmpty else { return 0 }
        let total = children.reduce(0.0) { partial, child in
            if child.state == .skipped || child.state == .succeeded { return partial + 1 }
            return partial + child.progress
        }
        return min(max(total / Double(children.count), 0), 1)
    }

    public func counts(of group: JobGroupRecord) -> (done: Int, failed: Int, total: Int) {
        let children = children(of: group)
        let done = children.filter { $0.state == .succeeded || $0.state == .skipped }.count
        let failed = children.filter { $0.state == .failed }.count
        return (done, failed, children.count)
    }

    // MARK: Mutations

    public func upsert(_ job: JobRecord) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        save()
    }

    public func upsert(_ group: JobGroupRecord) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        save()
    }

    public func remove(groupID: String) {
        groups.removeAll { $0.id == groupID }
        jobs.removeAll { $0.groupID == groupID }
        save()
    }

    /// 只清理已经结束的任务组；运行中/等待确认/中断的保留。
    @discardableResult
    public func clearFinishedGroups(excluding groupID: String? = nil) -> Int {
        let finishedIDs = Set(
            groups
                .filter {
                    $0.id != groupID
                        && ($0.state == .succeeded || $0.state == .failed || $0.state == .cancelled)
                }
                .map(\.id)
        )
        guard !finishedIDs.isEmpty else { return 0 }
        groups.removeAll { finishedIDs.contains($0.id) }
        jobs.removeAll { job in
            guard let groupID = job.groupID else { return false }
            return finishedIDs.contains(groupID)
        }
        save()
        return finishedIDs.count
    }

    // MARK: Interruption

    public func markInterrupted() {
        var changed = false
        for index in jobs.indices {
            if jobs[index].state == .running || jobs[index].state == .waiting {
                jobs[index].state = .interrupted
                jobs[index].isResumable = jobs[index].jobDirectory != nil
                changed = true
            }
        }
        for index in groups.indices {
            if groups[index].state == .running || groups[index].state == .waiting {
                groups[index].state = .interrupted
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let file = try? decoder.decode(JobStoreFile.self, from: data) else {
            NSLog("JobStore: records.json 解码失败，忽略历史")
            return
        }
        jobs = file.jobs
        groups = file.groups
    }

    private func save() {
        let file = JobStoreFile(version: 1, jobs: jobs, groups: groups)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL)
    }

}
