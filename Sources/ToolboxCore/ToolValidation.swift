import Foundation

/// 工具包扫描/校验结果。无效工具不会进入 `tools`，但会保留可读的错误。
public struct ToolIssue: Identifiable, Hashable {
    public enum Severity: String, Hashable {
        case error
        case warning
    }

    public let id = UUID()
    public let severity: Severity
    public let toolID: String?
    public let path: String
    public let message: String

    public init(severity: Severity, toolID: String?, path: String, message: String) {
        self.severity = severity
        self.toolID = toolID
        self.path = path
        self.message = message
    }

    public var isError: Bool { severity == .error }
}

public struct ToolScanResult {
    public let tools: [LoadedTool]
    public let issues: [ToolIssue]

    public init(tools: [LoadedTool], issues: [ToolIssue]) {
        self.tools = tools
        self.issues = issues
    }

    public var errorCount: Int { issues.filter(\.isError).count }
    public var warningCount: Int { issues.count - errorCount }
}

/// `tool.json` 的语义校验。JSONDecoder 只保证字段形状，这里补上 id、引用、
/// 选项、批量和资源等契约，尽量把错误挡在启动/运行之前。
public enum ToolValidator {
    public static let inputTypes: Set<String> = [
        "file", "directory", "text", "textarea", "number", "toggle",
        "select", "secret", "model", "preset", "lexicon"
    ]

    public static let resourceNames: Set<String> = ["gpu", "network", "cpu"]

    public static func validate(manifest: ToolManifest, directory: URL) -> [ToolIssue] {
        var issues: [ToolIssue] = []
        let path = directory.appendingPathComponent("tool.json").path

        func error(_ message: String) {
            issues.append(.init(severity: .error, toolID: manifest.id, path: path, message: message))
        }

        func warning(_ message: String) {
            issues.append(.init(severity: .warning, toolID: manifest.id, path: path, message: message))
        }

        if manifest.schemaVersion != 1 {
            error("schemaVersion 必须是 1，当前为 \(manifest.schemaVersion)")
        }
        if !matches(manifest.id, #"^[a-z0-9][a-z0-9._-]*$"#) {
            error("id 只能使用小写字母、数字、点、下划线和短横线，且不能以符号开头：\(manifest.id)")
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("name 不能为空")
        }
        if manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("version 不能为空")
        } else if !matches(manifest.version, #"^[0-9]+(\.[0-9]+){1,3}$"#) {
            warning("version 建议使用 1.0.0 形式，当前为 \(manifest.version)")
        }
        if manifest.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            warning("缺少 summary；工具卡片会没有一句话说明")
        }
        let nativeView = manifest.nativeView?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isNative = !nativeView.isEmpty
        let supportedNativeViews = NativeToolKind.allCases.map(\.rawValue)
        if isNative, !supportedNativeViews.contains(nativeView) {
            error("nativeView 不支持：\(nativeView)；当前支持 \(supportedNativeViews.joined(separator: " / "))")
        }

        // 所有工具都应声明 run：GUI 可以走 nativeView，CLI/Agent 走 run。
        if let run = manifest.run {
            if run.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                error("run.command 不能为空")
            }
        } else if isNative {
            warning("原生工具缺少 run：GUI 可用，但没有 CLI/Agent 入口")
        } else {
            error("非原生工具必须声明 run")
        }
        if manifest.inputs.isEmpty {
            if manifest.run == nil {
                error("inputs 不能为空")
            } else {
                warning("零输入工具：确认 run 不需要任何参数")
            }
        }
        if let doctor = manifest.doctor, doctor.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("doctor.command 不能为空")
        }
        if let setup = manifest.setup, setup.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("setup.command 不能为空")
        }

        var inputKeys = Set<String>()
        for field in manifest.inputs {
            if field.key.isEmpty {
                error("inputs 中存在空 key")
            } else if !matches(field.key, #"^[A-Za-z_][A-Za-z0-9_]*$"#) {
                error("input key 只能使用字母、数字、下划线，且不能以数字开头：\(field.key)")
            }
            if !inputKeys.insert(field.key).inserted {
                error("input key 重复：\(field.key)")
            }
            if !inputTypes.contains(field.type) {
                error("input \(field.key) 的 type 不支持：\(field.type)（支持：\(inputTypes.sorted().joined(separator: ", "))）")
            }
            if field.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warning("input \(field.key) 缺少 label")
            }
            if field.help?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                warning("input \(field.key) 缺少 help；表单里用户看不到说明")
            }
            if field.type == "select" {
                let options = field.options ?? []
                if options.isEmpty {
                    error("select \(field.key) 至少需要一个 option")
                }
                var values = Set<String>()
                for option in options {
                    if !values.insert(option.value).inserted {
                        error("select \(field.key) 的 option value 重复：\(option.value)")
                    }
                    if option.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        warning("select \(field.key) 的 option \(option.value) 缺少 label")
                    }
                }
                if let defaultValue = field.defaultValue?.stringValue,
                   !defaultValue.isEmpty,
                   !values.contains(defaultValue) {
                    error("select \(field.key) 的 default 不在 options 中：\(defaultValue)")
                }
            }
            if field.type == "number" {
                if let min = field.min, let max = field.max, min > max {
                    error("number \(field.key) 的 min > max")
                }
            }
            if field.type == "model" {
                guard let source = field.modelSource,
                      !source.baseURLField.trimmingCharacters(in: .whitespaces).isEmpty else {
                    error("model \(field.key) 需要 modelSource.baseURLField")
                    continue
                }
                if !inputKeys.contains(source.baseURLField) && !manifest.inputs.contains(where: { $0.key == source.baseURLField }) {
                    error("model \(field.key) 的 baseURLField 不存在：\(source.baseURLField)")
                }
                if let key = source.apiKeyField,
                   !key.isEmpty,
                   !manifest.inputs.contains(where: { $0.key == key }) {
                    error("model \(field.key) 的 apiKeyField 不存在：\(key)")
                }
            }
            if let condition = field.visibleWhen,
               !manifest.inputs.contains(where: { $0.key == condition.field }) {
                error("input \(field.key) 的 visibleWhen.field 不存在：\(condition.field)")
            }
            if field.type == "file" {
                for ext in field.accept ?? [] where ext.hasPrefix(".") {
                    warning("input \(field.key) 的 accept 建议不带点：\(ext)")
                }
            }
        }

        if let quick = manifest.quick {
            for key in quick.allInputs where !manifest.inputs.contains(where: { $0.key == key }) {
                error("quick.inputs 引用了不存在的 input：\(key)")
            }
            for key in quick.allDefaults.keys where !manifest.inputs.contains(where: { $0.key == key }) {
                error("quick.defaults 引用了不存在的 input：\(key)")
            }
            if quick.allInputs.isEmpty {
                warning("quick.inputs 为空；快速运行会退化为前几个必填字段")
            }
        }

        if let batch = manifest.batch {
            if let input = manifest.inputs.first(where: { $0.key == batch.input }) {
                if !["file", "directory"].contains(input.type) {
                    error("batch.input 必须是 file 或 directory：\(batch.input) 当前是 \(input.type)")
                }
            } else {
                error("batch.input 引用了不存在的 input：\(batch.input)")
            }
            if batch.allAccept.isEmpty {
                warning("batch.accept 为空；批量扫描时只能使用默认扩展名")
            }
            for ext in batch.allAccept where ext.hasPrefix(".") {
                warning("batch.accept 建议不带点：\(ext)")
            }
        }

        var presetIDs = Set<String>()
        for preset in manifest.allPresets {
            if !presetIDs.insert(preset.id).inserted {
                error("preset id 重复：\(preset.id)")
            }
            if preset.id.isEmpty || preset.name.isEmpty {
                warning("preset 的 id/name 不能为空")
            }
            for key in preset.values.keys where !manifest.inputs.contains(where: { $0.key == key }) {
                error("preset \(preset.id) 覆盖了不存在的 input：\(key)")
            }
        }

        var promptIDs = Set<String>()
        for preset in manifest.allPromptPresets {
            if !promptIDs.insert(preset.id).inserted {
                error("promptPreset id 重复：\(preset.id)")
            }
            if preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               preset.id != "custom" {
                error("promptPreset \(preset.id) 的 prompt 为空")
            }
        }

        var resources = Set<String>()
        for resource in manifest.allResources {
            let normalized = resource.lowercased()
            if !resources.insert(normalized).inserted {
                warning("resources 重复：\(resource)")
            }
            if !resourceNames.contains(normalized) {
                warning("未知 resource：\(resource)；调度器会按容量 1 处理")
            }
        }

        for requirement in manifest.allRequirements {
            if requirement.name.trimmingCharacters(in: .whitespaces).isEmpty {
                error("requirement 缺少 name")
            }
            if !["cli", "python-module", "asset"].contains(requirement.kind) {
                warning("未知 requirement.kind：\(requirement.kind)")
            }
        }

        validateAgent(manifest, error: error, warning: warning)

        return issues
    }

    /// Agent/CLI 元数据校验。字段全部可选，但一旦声明就必须符合契约。
    private static func validateAgent(
        _ manifest: ToolManifest,
        error: (String) -> Void,
        warning: (String) -> Void
    ) {
        guard let agent = manifest.agent else {
            warning("缺少 agent 元数据；CLI 仍可用，但 Agent 工具目录不完整（新工具应声明 agent）")
            return
        }
        if let capability = agent.capability,
           !matches(capability, #"^[a-z0-9][a-z0-9._-]*$"#) {
            error("agent.capability 只能使用小写字母、数字、点、下划线和短横线：\(capability)")
        }
        if let stability = agent.stability,
           !["experimental", "stable", "deprecated"].contains(stability) {
            error("agent.stability 必须是 experimental / stable / deprecated：\(stability)")
        }
        if let checkpoint = agent.checkpoint,
           !["never", "manual", "auto"].contains(checkpoint) {
            error("agent.checkpoint 必须是 never / manual / auto：\(checkpoint)")
        }
        if let timeout = agent.timeoutSec, timeout <= 0 {
            error("agent.timeoutSec 必须是正数")
        }
        for tag in agent.tags ?? [] where tag.isEmpty {
            error("agent.tags 不能包含空字符串")
        }
        for output in agent.outputs ?? [] where output.isEmpty {
            error("agent.outputs 不能包含空字符串（artifact kind）")
        }
        let inputKeys = Set(manifest.inputs.map(\.key))
        for (index, example) in (agent.examples ?? []).enumerated() {
            if let title = example.title, title.isEmpty {
                warning("agent.examples[\(index)].title 为空")
            }
            for key in (example.inputs ?? [:]).keys where !inputKeys.contains(key) {
                error("agent.examples[\(index)] 引用了不存在的 input：\(key)")
            }
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
