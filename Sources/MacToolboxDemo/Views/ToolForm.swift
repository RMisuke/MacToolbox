import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif
import UniformTypeIdentifiers

struct ToolForm: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    let fields: [InputField]
    var showsGroupCards: Bool = true
    var compact: Bool = false

    var body: some View {
        Group {
            if showsGroupCards {
                VStack(spacing: 14) {
                    ForEach(model.groups(for: fields)) { group in
                        SectionCard(group.title) {
                            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                                ForEach(group.fields) { field in
                                    ToolFieldRow(tool: tool, field: field, compact: compact)
                                }
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                    ForEach(fields) { field in
                        ToolFieldRow(tool: tool, field: field, compact: compact)
                    }
                }
            }
        }
    }
}

struct ToolFieldRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    let field: InputField
    var compact: Bool = false

    private var value: FieldValue {
        model.values(for: tool)[field.key] ?? .string("")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(field.label)
                    .font(.subheadline.weight(.medium))
                if field.isRequired {
                    Text("*").foregroundStyle(.red)
                }
                Spacer()
            }

            ToolFieldControl(field: field, value: value, tool: tool, compact: compact) { newValue in
                model.setValue(newValue, for: field.key, tool: tool)
            }

            if !compact, let help = field.help, !help.isEmpty {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ToolFieldControl: View {
    let field: InputField
    let value: FieldValue
    let tool: LoadedTool
    var compact: Bool = false
    let onChange: (FieldValue) -> Void

    var body: some View {
        switch field.type {
        case "file":
            FileDropZone(field: field, value: value, compact: compact, onChange: onChange)
        case "directory":
            FilePathRow(field: field, value: value, chooseDirectories: true, onChange: onChange)
        case "preset":
            PresetPickerRow(tool: tool, value: value, onChange: onChange)

        case "model":
            ModelPickerRow(tool: tool, field: field, value: value, onChange: onChange)

        case "lexicon":
            LexiconProfileRow(tool: tool, field: field, value: value, onChange: onChange)

        case "select":
            Picker("", selection: stringBinding) {
                ForEach(field.options ?? []) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 340, alignment: .leading)

        case "toggle":
            Toggle("", isOn: boolBinding)
                .labelsHidden()
                .toggleStyle(.switch)

        case "number":
            HStack(spacing: 8) {
                TextField("", value: doubleBinding, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                if let min = field.min, let max = field.max {
                    Text("范围 \(format(min)) – \(format(max))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case "textarea":
            TextEditor(text: stringBinding)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

        case "secret":
            SecretFieldRow(
                field: field,
                tool: tool,
                value: value,
                onChange: onChange
            )

        default:
            TextField(field.placeholder ?? "", text: stringBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { value.stringValue },
            set: { onChange(.string($0)) }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { value.boolValue },
            set: { onChange(.bool($0)) }
        )
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { value.doubleValue },
            set: { onChange(.number($0)) }
        )
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

private struct SecretFieldRow: View {
    let field: InputField
    let tool: LoadedTool
    let value: FieldValue
    let onChange: (FieldValue) -> Void

    @State private var hasStored = false

    var body: some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: stringBinding)
                .textFieldStyle(.roundedBorder)

            if hasStored && value.stringValue.isEmpty {
                Text("已保存")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }

            if hasStored || !value.stringValue.isEmpty {
                Button("清除") {
                    onChange(.string(""))
                    hasStored = false
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            hasStored = !value.stringValue.isEmpty
                || SecretStore.has(toolID: tool.id, key: field.key)
        }
    }

    private var placeholder: String {
        if hasStored && value.stringValue.isEmpty {
            return "已保存在钥匙串；留空使用已保存 Key"
        }
        return field.placeholder ?? ""
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { value.stringValue },
            set: { newValue in
                onChange(.string(newValue))
                hasStored = !newValue.isEmpty
            }
        )
    }
}

private struct FileDropZone: View {
    let field: InputField
    let value: FieldValue
    let compact: Bool
    let onChange: (FieldValue) -> Void

    @State private var isTargeted = false
    @State private var dropError: String?

    private var path: String {
        value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fileURL: URL? {
        path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    private var fileExists: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private var fileName: String {
        fileURL?.lastPathComponent ?? ""
    }

    private var folderName: String {
        fileURL?.deletingLastPathComponent().path ?? ""
    }

    private var fileIcon: String {
        let ext = fileURL?.pathExtension.lowercased() ?? ""
        if ["mp4", "mov", "mkv", "m4v", "avi", "webm"].contains(ext) {
            return "film"
        }
        if ["jpg", "jpeg", "png", "webp", "heic", "heif", "avif", "tif", "tiff", "gif", "bmp"].contains(ext) {
            return "photo"
        }
        return "doc"
    }

    private var typeHint: String {
        let exts = field.accept ?? []
        guard !exts.isEmpty else { return "支持任意文件" }
        let shown = exts.prefix(6).map { $0.uppercased() }.joined(separator: " / ")
        return "支持 " + shown + (exts.count > 6 ? " 等" : "")
    }

    private var fileSize: String {
        guard let fileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber
        else { return "" }
        let bytes = size.doubleValue
        if bytes < 1024 { return "\(Int(bytes)) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", bytes / 1024 / 1024) }
        return String(format: "%.2f GB", bytes / 1024 / 1024 / 1024)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if path.isEmpty {
                emptyState
            } else {
                selectedState
            }

            if let dropError, !dropError.isEmpty {
                Label(dropError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 104 : 124)
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 12 : 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.09) : Color(nsColor: .textBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.2, dash: [7, 5])
                )
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.doc")
                .font(.system(size: compact ? 24 : 30, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text(isTargeted ? "松开即可使用这个文件" : "拖拽文件到此处")
                .font(.subheadline.weight(.medium))
            Text(typeHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                choose()
            } label: {
                Label("选择文件…", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private var selectedState: some View {
        HStack(spacing: 12) {
            Image(systemName: fileExists ? fileIcon : "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(fileExists ? Color.accentColor : Color.orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(folderName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if fileExists {
                        Text(fileSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("可拖拽新文件替换")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("文件不存在")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer(minLength: 8)

            Button("更换…") {
                choose()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onChange(.string(""))
                dropError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除这个文件")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            dropError = "请拖入一个文件"
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { object, error in
            DispatchQueue.main.async {
                if let error {
                    dropError = error.localizedDescription
                    return
                }
                guard let url = object else {
                    dropError = "无法读取拖入的文件"
                    return
                }
                accept(url)
            }
        }
        return true
    }

    private func accept(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            dropError = "文件不存在：\(url.lastPathComponent)"
            return
        }
        guard !isDirectory.boolValue else {
            dropError = "这里只能选择文件，不能选择文件夹"
            return
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            dropError = "文件不可读：\(url.lastPathComponent)"
            return
        }
        let accepted = field.accept ?? []
        if !accepted.isEmpty {
            let ext = url.pathExtension.lowercased()
            guard accepted.contains(ext) else {
                dropError = "不支持 .\(ext.isEmpty ? "无扩展名" : ext) 文件；\(typeHint)"
                return
            }
        }
        dropError = nil
        onChange(.string(url.path))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let accept = field.accept, !accept.isEmpty {
            let types = accept.compactMap { UTType(filenameExtension: $0) }
            if !types.isEmpty {
                panel.allowedContentTypes = types
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(url)
    }
}

private struct FilePathRow: View {
    let field: InputField
    let value: FieldValue
    let chooseDirectories: Bool
    let onChange: (FieldValue) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            TextField(field.placeholder ?? "", text: stringBinding)
                .textFieldStyle(.roundedBorder)

            Button(chooseDirectories ? "选择目录…" : "选择文件…") {
                choose()
            }
            .buttonStyle(.bordered)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.09) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    onChange(.string(url.path))
                }
            }
            return true
        }
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { value.stringValue },
            set: { onChange(.string($0)) }
        )
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !chooseDirectories
        panel.canChooseDirectories = chooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = chooseDirectories
        if !chooseDirectories, let accept = field.accept, !accept.isEmpty {
            let types = accept.compactMap { UTType(filenameExtension: $0) }
            if !types.isEmpty {
                panel.allowedContentTypes = types
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChange(.string(url.path))
    }
}
