import Foundation

// MARK: - Manifest

public struct ToolManifest: Codable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let category: String?
    public let icon: String?
    public let summary: String?
    public let agent: AgentSpec?
    public let requirements: [Requirement]?
    public let inputs: [InputField]
    public let presets: [Preset]?
    public let quick: QuickSpec?
    public let promptPresets: [PromptPreset]?
    public let resources: [String]?
    public let batch: BatchSpec?
    public let nativeView: String?
    public let run: CommandSpec?
    public let doctor: CommandSpec?
    public let setup: CommandSpec?

    public var allRequirements: [Requirement] { requirements ?? [] }
    public var allPresets: [Preset] { presets ?? [] }
    public var allPromptPresets: [PromptPreset] { promptPresets ?? [] }
    public var allResources: [String] { resources ?? [] }
}

/// Agent / CLI 元数据。全部可选；缺失时 CLI 仍可运行，但工具目录信息不完整。
public struct AgentSpec: Codable {
    public let enabled: Bool?
    public let capability: String?
    public let description: String?
    public let stability: String?
    public let readOnly: Bool?
    public let idempotent: Bool?
    public let timeoutSec: Double?
    public let checkpoint: String?
    public let tags: [String]?
    public let outputs: [String]?
    public let examples: [AgentExample]?
}

public struct AgentExample: Codable {
    public let title: String?
    public let inputs: [String: FieldValue]?
}

public struct QuickSpec: Codable {
    public let title: String?
    public let inputs: [String]?
    public let defaults: [String: FieldValue]?

    public var allInputs: [String] { inputs ?? [] }
    public var allDefaults: [String: FieldValue] { defaults ?? [:] }
}

public struct BatchSpec: Codable {
    public let input: String
    public let accept: [String]?
    public let title: String?
    public let skipExisting: Bool?
    /// 跳过已存在输出时使用的扩展名；不填时优先读 form 里的 `format`。
    public let outputExtension: String?

    public var allAccept: [String] { accept ?? [] }
    public var defaultSkipExisting: Bool { skipExisting ?? false }
}

public struct Requirement: Codable, Identifiable {
    public var id: String { name }
    public let kind: String
    public let name: String
    public let installHint: String?
    public let optional: Bool?
}

public struct InputField: Codable, Identifiable {
    public struct Condition: Codable {
        public let field: String
        public let equals: FieldValue
    }

    public var id: String { key }
    public let key: String
    public let type: String
    public let label: String
    public let required: Bool?
    public let defaultValue: FieldValue?
    public let options: [FieldOption]?
    public let modelSource: ModelSource?
    public let accept: [String]?
    public let min: Double?
    public let max: Double?
    public let placeholder: String?
    public let help: String?
    public let group: String?
    public let advanced: Bool?
    public let visibleWhen: Condition?

    enum CodingKeys: String, CodingKey {
        case key, type, label, required
        case defaultValue = "default"
        case options, modelSource, accept, min, max, placeholder, help, group, advanced, visibleWhen
    }

    public var isRequired: Bool { required ?? false }
    public var isAdvanced: Bool { advanced ?? false }
    public var groupName: String { group ?? "参数" }
}

public struct FieldOption: Codable, Identifiable {
    public var id: String { value }
    public let value: String
    public let label: String
}

public struct PromptPreset: Codable, Identifiable {
    public let id: String
    public let name: String
    public let prompt: String
}

public struct ModelSource: Codable {
    public let baseURLField: String
    public let apiKeyField: String?

    public init(baseURLField: String, apiKeyField: String? = nil) {
        self.baseURLField = baseURLField
        self.apiKeyField = apiKeyField
    }
}

public struct Preset: Codable, Identifiable {
    public let id: String
    public let name: String
    public let values: [String: FieldValue]

    public init(id: String, name: String, values: [String: FieldValue]) {
        self.id = id
        self.name = name
        self.values = values
    }
}

public struct CommandSpec: Codable {
    public let command: String
    public let args: [String]
}

// MARK: - Loaded tool

public struct LoadedTool: Identifiable {
    public var id: String { manifest.id }
    public let manifest: ToolManifest
    public let directory: URL

    public init(manifest: ToolManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
    }

    /// C 级原生工具：由 SwiftUI 直接渲染，不经过 JobRunner/Protocol。
    public var isNative: Bool {
        !(manifest.nativeView ?? "").isEmpty
    }

    public var isRunnable: Bool {
        !isNative && manifest.run != nil
    }

    /// GUI 用 nativeView，CLI/Agent 用 run；两者可以同时存在。
    public var hasCLI: Bool {
        manifest.run != nil
    }

    public var agentCapability: String {
        manifest.agent?.capability ?? manifest.id
    }

    public var isAgentExposed: Bool {
        manifest.agent?.enabled ?? true
    }

    public var secretKeys: [String] {
        manifest.inputs.filter { $0.type == "secret" }.map(\.key)
    }

    /// 任务标题、队列标签和断点恢复用哪个输入作为「主路径」。
    /// 优先批量输入，其次第一个 file，再其次 directory；新工具不必再叫 video。
    public var primaryPathKey: String? {
        if let batch = manifest.batch?.input, !batch.isEmpty {
            return batch
        }
        if let file = manifest.inputs.first(where: { $0.type == "file" }) {
            return file.key
        }
        return manifest.inputs.first(where: { $0.type == "directory" })?.key
    }

    public func primaryPath(in values: [String: FieldValue]) -> String? {
        guard let key = primaryPathKey else { return nil }
        let path = values[key]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// records / config 里只保留 secret 字段的空占位。
    public func redactedValues(_ values: [String: FieldValue]) -> [String: FieldValue] {
        var result = values
        for key in secretKeys {
            result[key] = .string("")
        }
        return result
    }

    /// 只在当前进程内传给子进程环境变量，不进入 records/config。
    public func runtimeSecrets(from values: [String: FieldValue]) -> [String: String] {
        var result: [String: String] = [:]
        for key in secretKeys {
            let value = values[key]?.stringValue ?? ""
            if !value.isEmpty { result[key] = value }
        }
        return result
    }
}

// MARK: - Job protocol events

public struct JobEvent: Decodable {
    public let type: String
    public let level: String?
    public let message: String?
    public let detail: String?
    public let code: String?
    public let fraction: Double?
    public let step: String?
    public let title: String?
    public let state: String?
    public let path: String?
    public let kind: String?
    public let label: String?
    public let id: String?
    public let ok: Bool?
    public let summary: String?
    public let checks: [EnvCheck]?
    public let artifacts: [Artifact]?
    public let checkpoint: Checkpoint?
}

public struct EnvCheck: Codable, Identifiable {
    public let id: String
    public let label: String
    public let status: String
    public let detail: String?
    public let fixCommand: String?
    public let fixable: Bool?

    public var isOK: Bool { status == "ok" }
}

public struct Artifact: Codable, Identifiable, Hashable {
    public let id: String
    public let kind: String
    public let path: String
    public let label: String?
}

public struct Checkpoint: Codable, Identifiable {
    public let id: String
    public let title: String
    public let message: String?
    public let artifacts: [Artifact]?
}

// MARK: - Registry

public enum ToolRegistry {
    /// 扫描顺序就是覆盖顺序：后扫描到的同 id 工具覆盖先扫描到的。
    /// `_template` / `.hidden` 这类目录不进入工具列表。
    public static func searchDirectories() -> [URL] {
        var directories: [URL] = []
        let env = ProcessInfo.processInfo.environment

        if let custom = env["TOOLBOX_TOOLS_DIR"], !custom.isEmpty {
            directories.append(URL(fileURLWithPath: custom, isDirectory: true))
        }
        if let resource = Bundle.main.resourceURL {
            directories.append(resource.appendingPathComponent("Tools", isDirectory: true))
        }
        directories.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tools", isDirectory: true))
        directories.append(ToolboxPaths.applicationSupport.appendingPathComponent("Tools", isDirectory: true))
        return directories
    }

    public static func scan() -> ToolScanResult {
        var issues: [ToolIssue] = []
        var seenDirectories = Set<String>()
        var loaded: [String: LoadedTool] = [:]

        for directory in searchDirectories() {
            let standardized = directory.standardizedFileURL
            guard seenDirectories.insert(standardized.path).inserted else { continue }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: standardized,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                let name = child.lastPathComponent
                guard !name.hasPrefix("_"), !name.hasPrefix(".") else { continue }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }

                let manifestURL = child.appendingPathComponent("tool.json")
                guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                    issues.append(.init(
                        severity: .warning,
                        toolID: nil,
                        path: child.path,
                        message: "工具目录缺少 tool.json，已跳过"
                    ))
                    continue
                }

                let manifest: ToolManifest
                do {
                    let data = try Data(contentsOf: manifestURL)
                    manifest = try JSONDecoder().decode(ToolManifest.self, from: data)
                } catch {
                    issues.append(.init(
                        severity: .error,
                        toolID: nil,
                        path: manifestURL.path,
                        message: "tool.json 解析失败：\(error.localizedDescription)"
                    ))
                    NSLog("Toolbox: 跳过无法解析的工具 \(manifestURL.path): \(error)")
                    continue
                }

                let validation = ToolValidator.validate(manifest: manifest, directory: child)
                issues.append(contentsOf: validation)
                guard !validation.contains(where: \.isError) else { continue }

                if let previous = loaded[manifest.id] {
                    let userRoot = ToolboxPaths.applicationSupport
                        .appendingPathComponent("Tools", isDirectory: true)
                        .path + "/"
                    let involvesUserTool = child.path.hasPrefix(userRoot)
                        || previous.directory.path.hasPrefix(userRoot)
                    if involvesUserTool {
                        issues.append(.init(
                            severity: .warning,
                            toolID: manifest.id,
                            path: child.path,
                            message: "工具 id 重复：\(manifest.id)；当前目录会覆盖 \(previous.directory.path)"
                        ))
                    }
                }
                loaded[manifest.id] = LoadedTool(manifest: manifest, directory: child)
            }
        }

        let sorted = loaded.values.sorted {
            if $0.manifest.category == $1.manifest.category {
                return $0.manifest.name < $1.manifest.name
            }
            return ($0.manifest.category ?? "") < ($1.manifest.category ?? "")
        }
        return ToolScanResult(tools: sorted, issues: issues)
    }

    public static func discover() -> [LoadedTool] {
        scan().tools
    }
}

// MARK: - Paths

public enum ToolboxPaths {
    public static var applicationSupport: URL {
        let url: URL
        if let custom = ProcessInfo.processInfo.environment["MCT_DATA_DIR"], !custom.isEmpty {
            url = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            url = base.appendingPathComponent("MacToolboxDemo", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var jobs: URL {
        let url = applicationSupport.appendingPathComponent("Jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var temp: URL {
        let url = applicationSupport.appendingPathComponent("Temp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func newJobDirectory(toolID: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let shortID = UUID().uuidString.prefix(6)
        let safeTool = toolID.replacingOccurrences(of: "/", with: "-")
        let url = jobs.appendingPathComponent("\(stamp)-\(safeTool)-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Environment

public enum ToolEnvironment {
    public static func augmentedPATH() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/Library/Frameworks/Python.framework/Versions/Current/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let merged = candidates + existing.split(separator: ":").map(String.init)
        var seen = Set<String>()
        return merged.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    public static func base() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH()
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }
}

// MARK: - Templating

public enum Template {
    public static func expand(_ string: String, context: [String: String]) -> String {
        var result = string
        for (key, value) in context {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    public static func expand(_ spec: CommandSpec, context: [String: String]) -> (String, [String]) {
        (expand(spec.command, context: context), spec.args.map { expand($0, context: context) })
    }
}

// MARK: - Config

public enum JobConfig {
    public static func write(
        tool: LoadedTool,
        values: [String: FieldValue],
        jobDir: URL,
        resume: Bool = false,
        fingerprint: String? = nil
    ) throws -> URL {
        var payload: [String: Any] = [:]
        let secretKeys = Set(tool.secretKeys)
        for (key, value) in values {
            // secret 只走 Keychain/子进程环境变量，不进 config.json。
            payload[key] = secretKeys.contains(key) ? "" : value.rawObject
        }
        payload["resume"] = resume
        var meta: [String: String] = [
            "toolID": tool.manifest.id,
            "toolVersion": tool.manifest.version,
            "toolDir": tool.directory.path,
            "jobDir": jobDir.path,
            "jobID": jobDir.lastPathComponent,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let fingerprint {
            meta["fingerprint"] = fingerprint
        }
        payload["_meta"] = meta

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let url = jobDir.appendingPathComponent("config.json")
        // 注：不做 atomic 写。atomic 会先写临时文件再 rename，
        // 在部分受限沙箱/文件系统上会被拒绝（EPERM）。
        try data.write(to: url)
        return url
    }

    public static func readFingerprint(jobDir: URL) -> String? {
        let configURL = jobDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = json["_meta"] as? [String: Any] else { return nil }
        return meta["fingerprint"] as? String
    }

    public static func writeForDoctor(tool: LoadedTool, values: [String: FieldValue]) throws -> URL {
        let dir = ToolboxPaths.temp.appendingPathComponent("doctor", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try write(tool: tool, values: values, jobDir: dir)
    }
}
