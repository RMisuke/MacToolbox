import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

// MARK: - Model picker

struct ModelPickerRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    let field: InputField
    let value: FieldValue
    let onChange: (FieldValue) -> Void

    private var baseURL: String {
        guard let key = field.modelSource?.baseURLField else { return "" }
        return model.values(for: tool)[key]?.stringValue ?? ""
    }

    private var apiKey: String {
        guard let key = field.modelSource?.apiKeyField else { return "" }
        let entered = model.values(for: tool)[key]?.stringValue ?? ""
        if !entered.isEmpty { return entered }
        return SecretStore.value(toolID: tool.id, key: key) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(field.placeholder ?? "模型 ID", text: stringBinding)
                    .textFieldStyle(.roundedBorder)

                Button {
                    model.fetchModels(baseURL: baseURL, apiKey: apiKey)
                } label: {
                    if model.modelCatalog.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("获取模型", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.modelCatalog.isLoading || baseURL.isEmpty)

                if !model.modelCatalog.models.isEmpty {
                    Menu {
                        ForEach(model.modelCatalog.models, id: \.self) { id in
                            Button(id) {
                                onChange(.string(id))
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .help("从已获取的模型列表中选择")
                }
            }

            if let error = model.modelCatalog.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !model.modelCatalog.models.isEmpty {
                Text("已获取 \(model.modelCatalog.models.count) 个模型，可直接选择或手动输入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("填写 Base URL（可带 API Key）后点「获取模型」；不获取也能手动输入 ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { value.stringValue },
            set: { onChange(.string($0)) }
        )
    }
}

// MARK: - Lexicon profile

struct LexiconProfileRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    let field: InputField
    let value: FieldValue
    let onChange: (FieldValue) -> Void

    @State private var showManager = false

    private var selection: String {
        let raw = value.stringValue.isEmpty ? "auto" : value.stringValue
        if raw == "auto" || raw == "none" { return raw }
        if profiles.contains(where: { $0.id == raw }) { return raw }
        return "auto"
    }

    private var profiles: [LexiconProfile] {
        model.lexiconProfiles(for: tool)
    }

    private var matched: LexiconMatch? {
        model.matchedLexicon(for: tool)
    }

    private var selected: LexiconProfile? {
        switch selection {
        case "auto": return matched?.profile
        case "none": return nil
        default: return model.lexiconStore.profile(id: selection)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: binding) {
                    Text("自动匹配").tag("auto")
                    Text("不使用词表").tag("none")
                    ForEach(profiles) { profile in
                        Text("\(profile.name) \(profile.displayVersion)").tag(profile.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)

                Button {
                    model.lexiconStore.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("重新加载词表")

                Button("管理…") {
                    showManager = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .sheet(isPresented: $showManager) {
                    LexiconManagerSheet(tool: tool)
                        .environmentObject(model)
                }
            }

            if let profile = selected {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.book.closed.fill")
                            .foregroundStyle(.green)
                        Text("\(profile.name) \(profile.displayVersion)")
                            .font(.caption.weight(.medium))
                        Text("\(profile.allHotwords.count) 热词 · \(profile.allRules.count) 规则")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if selection == "auto", let matched {
                        Text("自动匹配依据：" + matched.reasons.joined(separator: "；"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("手动选择；任务开始前会合并热词并优先执行规则。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.07)))
            } else if selection == "auto" {
                Text("当前文件未匹配到词表；批量任务会按第一个文件/目录名匹配。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("打开词表目录") {
                    try? FileManager.default.createDirectory(
                        at: model.lexiconStore.userProfilesDirectory,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([model.lexiconStore.userProfilesDirectory])
                }
                .controlSize(.small)

                Text("\(profiles.count) 个可用词表")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { selection },
            set: { onChange(.string($0)) }
        )
    }
}

// MARK: - Preset picker

struct PresetPickerRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    let value: FieldValue
    let onChange: (FieldValue) -> Void

    @State private var showManager = false

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: binding) {
                ForEach(model.allPresets(for: tool)) { preset in
                    Text(preset.name).tag(preset.id)
                }
                Text("自定义").tag("custom")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 340, alignment: .leading)

            Button("管理…") {
                showManager = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .sheet(isPresented: $showManager) {
                PresetManagerSheet(tool: tool)
                    .environmentObject(model)
            }
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { value.stringValue.isEmpty ? "custom" : value.stringValue },
            set: { onChange(.string($0)) }
        )
    }
}
