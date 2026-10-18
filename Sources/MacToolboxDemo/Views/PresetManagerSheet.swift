import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct PresetManagerSheet: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String?
    @State private var presetName = ""
    @State private var draft: [String: FieldValue] = [:]
    @State private var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                presetList
                    .frame(width: 210)

                Divider()

                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()
            footer
        }
        .padding(22)
        .frame(width: 880, height: 680)
        .onAppear(perform: loadInitial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("参数预设管理")
                    .font(.title2.weight(.semibold))
                Text("自定义预设只保存数值 / 开关 / 下拉项；文件、路径、密钥不进预设。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
        }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("预设")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.allPresets(for: tool)) { preset in
                        Button {
                            load(preset)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isBuiltin(preset.id) ? "lock" : "slider.horizontal.3")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(preset.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                if selectedID == preset.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(selectedID == preset.id ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                startNew()
            } label: {
                Label("新建预设", systemImage: "plus")
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("预设名称", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                if let selectedID, isBuiltin(selectedID) {
                    Text("内置预设")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if isNew {
                    Text("新预设")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(presetFields) { field in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(field.label)
                                .font(.subheadline.weight(.medium))
                            ToolFieldControl(
                                field: field,
                                value: draft[field.key] ?? .string(""),
                                tool: tool
                            ) { newValue in
                                draft[field.key] = newValue
                            }
                            if let help = field.help, !help.isEmpty {
                                Text(help)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let selectedID, !isBuiltin(selectedID) {
                Button(role: .destructive) {
                    model.deleteCustomPreset(selectedID, tool: tool)
                    startNew()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }

            Spacer()

            Button("保存") {
                _ = persist()
            }
            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("保存并应用") {
                if let saved = persist() {
                    model.setValue(.string(saved.id), for: "preset", tool: tool)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("应用") {
                guard let selectedID else { return }
                model.setValue(.string(selectedID), for: "preset", tool: tool)
                dismiss()
            }
            .disabled(selectedID == nil || isNew)
        }
    }

    private var presetFields: [InputField] {
        let allowed: Set<String> = [
            "format", "maxChar", "lineChar", "maxDur", "minDur",
            "mergeGap", "stripPunct", "dropFillers", "allowQCFail", "overwrite"
        ]
        return tool.manifest.inputs.filter { field in
            guard allowed.contains(field.key) else { return false }
            guard ["number", "toggle", "select"].contains(field.type) else { return false }
            guard let condition = field.visibleWhen else { return true }
            return draft[condition.field]?.stringValue == condition.equals.stringValue
        }
    }

    private func loadInitial() {
        let currentID = model.values(for: tool)["preset"]?.stringValue ?? "custom"
        if let preset = model.allPresets(for: tool).first(where: { $0.id == currentID }) {
            load(preset)
        } else {
            startNew()
        }
    }

    private func load(_ preset: Preset) {
        selectedID = preset.id
        presetName = preset.name
        var values = model.values(for: tool)
        for (key, value) in preset.values {
            values[key] = value
        }
        draft = values
        isNew = false
    }

    private func startNew() {
        selectedID = nil
        presetName = "我的预设"
        draft = model.values(for: tool)
        isNew = true
    }

    @discardableResult
    private func persist() -> CustomPreset? {
        let fields = Set(presetFields.map(\.key))
        var values: [String: FieldValue] = [:]
        for key in fields {
            values[key] = draft[key] ?? .string("")
        }
        let reuseID = isNew || (selectedID.map(isBuiltin) ?? false) ? nil : selectedID
        let saved = model.saveCustomPreset(
            tool: tool,
            id: reuseID,
            name: presetName.trimmingCharacters(in: .whitespaces),
            values: values
        )
        selectedID = saved.id
        presetName = saved.name
        isNew = false
        return saved
    }

    private func isBuiltin(_ id: String) -> Bool {
        tool.manifest.allPresets.contains { $0.id == id }
    }
}
