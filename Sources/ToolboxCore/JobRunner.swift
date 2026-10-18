import Combine
import Foundation

public struct LogLine: Identifiable {
    public let id = UUID()
    public let level: String
    public let text: String
    public let date = Date()

    public init(level: String, text: String) {
        self.level = level
        self.text = text
    }
}

public struct StepState: Identifiable {
    public let id: String
    public var title: String
    public var state: String // pending | running | done | failed

    public init(id: String, title: String, state: String) {
        self.id = id
        self.title = title
        self.state = state
    }
}

@MainActor
public final class JobRunner: ObservableObject {
    public enum State: String {
        case idle
        case running
        case waiting
        case succeeded
        case failed
        case cancelled

        public var isActive: Bool { self == .running || self == .waiting }
        public var displayName: String {
            switch self {
            case .idle: return "空闲"
            case .running: return "运行中"
            case .waiting: return "等待确认"
            case .succeeded: return "已完成"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            }
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var logs: [LogLine] = []
    @Published public private(set) var steps: [StepState] = []
    @Published public private(set) var artifacts: [Artifact] = []
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var jobDirectory: URL?
    @Published public private(set) var jobID: String?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var finishedAt: Date?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var summary: String?
    @Published public private(set) var fingerprint: String?
    public var processIdentifier: Int32? { childPID }
    @Published public var checkpoint: Checkpoint?

    private var runner: StreamingProcess?
    private var logHandle: FileHandle?
    private var childPID: Int32?
    private var pidFileURL: URL?
    private var resultOK = false
    private var sawResult = false

    public init() {}

    public func start(
        tool: LoadedTool,
        values: [String: FieldValue],
        jobDirectory existingDirectory: URL? = nil,
        resume: Bool = false,
        secrets: [String: String] = [:]
    ) {
        guard !state.isActive else { return }
        reset()
        guard let runSpec = tool.manifest.run else {
            state = .failed
            errorMessage = "该工具没有 run 命令（原生工具请从工具详情打开）"
            appendLog(level: "error", text: errorMessage ?? "缺少 run")
            return
        }

        do {
            let directory: URL
            if let existingDirectory {
                directory = existingDirectory
            } else {
                directory = try ToolboxPaths.newJobDirectory(toolID: tool.manifest.id)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            jobDirectory = directory
            jobID = directory.lastPathComponent
            startedAt = Date()

            var runtimeSecrets = secrets
            for field in tool.manifest.inputs where field.type == "secret" {
                if let existing = runtimeSecrets[field.key], !existing.isEmpty { continue }
                let entered = values[field.key]?.stringValue ?? ""
                let resolved = entered.isEmpty
                    ? (SecretStore.value(toolID: tool.id, key: field.key) ?? "")
                    : entered
                if !resolved.isEmpty {
                    runtimeSecrets[field.key] = resolved
                }
            }

            let computedFingerprint = JobFingerprintBuilder.make(tool: tool, values: values)
            fingerprint = computedFingerprint
            var effectiveResume = resume
            var invalidationMessage: String?

            if resume, existingDirectory != nil {
                let previous = JobConfig.readFingerprint(jobDir: directory)
                if previous != computedFingerprint {
                    effectiveResume = false
                    if let archived = archiveStaleArtifacts(in: directory) {
                        invalidationMessage = "输入/参数/工具版本已变化，旧产物已移入 \(archived.url.lastPathComponent)（\(archived.count) 项），本次从头执行"
                    } else {
                        invalidationMessage = "输入/参数/工具版本已变化，本次从头执行"
                    }
                }
            }

            let configURL = try JobConfig.write(
                tool: tool,
                values: values,
                jobDir: directory,
                resume: effectiveResume,
                fingerprint: computedFingerprint
            )

            let logURL = directory.appendingPathComponent("job.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try? Data().write(to: logURL)
            }
            logHandle = try? FileHandle(forWritingTo: logURL)
            logHandle?.seekToEndOfFile()

            var context: [String: String] = [
                "toolDir": tool.directory.path,
                "jobDir": directory.path,
                "configFile": configURL.path
            ]
            let (command, arguments) = Template.expand(runSpec, context: context)

            var environment = ToolEnvironment.base()
            environment["TOOLBOX_TOOL_DIR"] = tool.directory.path
            environment["TOOLBOX_JOB_DIR"] = directory.path
            environment["TOOLBOX_CONFIG"] = configURL.path
            if let jieba = values["jiebaLib"]?.stringValue, !jieba.isEmpty {
                environment["SUBTITLE_JIEBA_LIB"] = jieba
            }
            environment["SUBTITLE_TMPDIR"] = directory.appendingPathComponent("tmp").path
            for (key, value) in runtimeSecrets {
                environment["MCT_SECRET_\(key)"] = value
            }

            context["toolID"] = tool.manifest.id
            let process = StreamingProcess()
            process.onLine = { [weak self] stream, line in
                guard let self else { return }
                switch stream {
                case .stdout:
                    self.handleStdout(line)
                case .stderr:
                    self.appendLog(level: "stderr", text: line)
                }
            }
            process.onExit = { [weak self] code in
                self?.handleExit(code: code)
            }

            runner = process
            state = .running
            appendLog(level: "info", text: "任务目录：\(directory.path)")
            if let invalidationMessage {
                appendLog(level: "warn", text: invalidationMessage)
            } else if effectiveResume {
                appendLog(level: "info", text: "断点续跑：指纹一致，复用已存在的中间产物")
            }
            appendLog(level: "info", text: "缓存指纹：\(JobFingerprintBuilder.short(computedFingerprint))")
            appendLog(level: "info", text: "启动：\(command) \(arguments.joined(separator: " "))")

            try process.start(
                command: command,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment
            )

            pidFileURL = directory.appendingPathComponent("child.pid")
            if let pidFileURL {
                try? Data("\(process.processIdentifier)".utf8).write(to: pidFileURL)
            }
            childPID = process.processIdentifier
        } catch {
            NSLog("JobRunner start failed: %@", String(describing: error))
            state = .failed
            errorMessage = error.localizedDescription
            appendLog(level: "error", text: "启动失败：\(error.localizedDescription)")
        }
    }

    public func cancel(force: Bool = false) {
        guard state.isActive else { return }
        state = .cancelled
        appendLog(level: "warn", text: force ? "用户强制停止任务（进程树）" : "用户取消任务")
        runner?.terminate(force: force)
    }

    public func forceCancel() {
        cancel(force: true)
    }

    public func continueCheckpoint() {
        guard state == .waiting else { return }
        let payload = ["type": "continue", "checkpoint": checkpoint?.id ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            runner?.sendLine(text)
        }
        checkpoint = nil
        state = .running
        appendLog(level: "info", text: "已确认，继续执行")
    }

    // MARK: - Events

    private func handleStdout(_ line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(JobEvent.self, from: data) else {
            appendLog(level: "stdout", text: line)
            return
        }

        switch event.type {
        case "log":
            appendLog(level: event.level ?? "info", text: event.message ?? "")

        case "progress":
            if let fraction = event.fraction {
                progress = min(max(fraction, 0), 1)
            }

        case "step":
            guard let id = event.step ?? event.title else { return }
            let title = event.title ?? id
            let stateValue = event.state ?? "running"
            if let index = steps.firstIndex(where: { $0.id == id }) {
                steps[index].state = stateValue
                if let titleValue = event.title, !titleValue.isEmpty {
                    steps[index].title = titleValue
                }
            } else {
                steps.append(StepState(id: id, title: title, state: stateValue))
            }

        case "artifact":
            guard let path = event.path else { return }
            let artifact = Artifact(
                id: event.id ?? event.kind ?? path,
                kind: event.kind ?? "file",
                path: path,
                label: event.label ?? event.title
            )
            if !artifacts.contains(where: { $0.path == path }) {
                artifacts.append(artifact)
            }

        case "checkpoint":
            checkpoint = event.checkpoint
            state = .waiting
            appendLog(level: "info", text: "等待确认：\(event.checkpoint?.title ?? "")")

        case "result":
            sawResult = true
            resultOK = event.ok ?? true
            summary = event.summary
            if let items = event.artifacts {
                for artifact in items where !artifacts.contains(where: { $0.path == artifact.path }) {
                    artifacts.append(artifact)
                }
            }
            if !resultOK {
                errorMessage = event.summary ?? "任务失败"
            }

        case "error":
            let message = event.message ?? event.detail ?? "未知错误"
            errorMessage = message
            appendLog(level: "error", text: message)

        default:
            if let message = event.message {
                appendLog(level: "info", text: message)
            }
        }
    }

    private func handleExit(code: Int32) {
        finishedAt = Date()
        logHandle?.closeFile()
        logHandle = nil
        if let pidFileURL {
            try? FileManager.default.removeItem(at: pidFileURL)
        }
        pidFileURL = nil
        childPID = nil

        if state == .cancelled {
            return
        }
        if state == .waiting {
            state = .failed
            errorMessage = "任务在等待确认时结束"
            return
        }
        if sawResult && resultOK && code == 0 {
            state = .succeeded
            progress = 1
        } else if code == 0 && !sawResult {
            state = .succeeded
            progress = 1
        } else {
            state = .failed
            if errorMessage == nil {
                errorMessage = "进程退出码 \(code)"
            }
        }
    }

    private func reset() {
        state = .idle
        logs = []
        steps = []
        artifacts = []
        progress = 0
        jobDirectory = nil
        jobID = nil
        startedAt = nil
        finishedAt = nil
        errorMessage = nil
        summary = nil
        fingerprint = nil
        childPID = nil
        pidFileURL = nil
        checkpoint = nil
        resultOK = false
        sawResult = false
    }

    /// 参数或工具变化时，保留旧产物供排查，但不让 Python 的 resume 复用。
    private func archiveStaleArtifacts(in directory: URL) -> (url: URL, count: Int)? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        let staleDirectory = directory.appendingPathComponent("invalidated-\(stamp)")
        let names = [
            "config.json", "job.log", "audio.wav", "audio.mp3", "raw.json", "raw.txt", "raw",
            "fixes.json", "substitutions.json", "final.srt", "final.vtt", "qc.txt", "tmp"
        ]

        var moved = 0
        for name in names {
            let source = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if moved == 0 {
                try? FileManager.default.createDirectory(
                    at: staleDirectory,
                    withIntermediateDirectories: true
                )
            }
            let destination = staleDirectory.appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                moved += 1
            } catch {
                // 移动失败时直接删除，宁可丢旧产物也不能让 resume 复用。
                if (try? FileManager.default.removeItem(at: source)) != nil {
                    moved += 1
                }
            }
        }
        return moved > 0 ? (staleDirectory, moved) : nil
    }

    private func appendLog(level: String, text: String) {
        let line = LogLine(level: level, text: text)
        logs.append(line)
        if logs.count > 4000 {
            logs.removeFirst(logs.count - 4000)
        }
        if let data = (text + "\n").data(using: .utf8) {
            logHandle?.write(data)
        }
    }
}
