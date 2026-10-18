import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct BatchRunSheet: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    @Environment(\.dismiss) private var dismiss

    @State private var folder: URL?
    @State private var files: [URL] = []
    @State private var recursive = false
    @State private var skipExisting: Bool
    @State private var stopOnError = false
    @State private var outputDirectory = ""
    @State private var scanError: String?

    init(tool: LoadedTool) {
        self.tool = tool
        _skipExisting = State(initialValue: tool.manifest.batch?.defaultSkipExisting ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            SectionCard("选择目录") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(folder?.path ?? "尚未选择目录")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(folder == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .textSelection(.enabled)

                        Spacer()

                        Button("选择目录…") {
                            chooseFolder()
                        }
                        .buttonStyle(.bordered)
                    }

                    Toggle("包含子目录", isOn: $recursive)
                        .onChange(of: recursive) { _, _ in
                            if let folder { scan(folder) }
                        }

                    if let scanError {
                        Text(scanError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if !files.isEmpty {
                        Text("找到 \(files.count) 个匹配文件")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(files.prefix(12), id: \.path) { file in
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(file.lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                }
                                if files.count > 12 {
                                    Text("… 另有 \(files.count - 12) 个")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    } else if folder != nil {
                        Text("目录里没有匹配的文件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SectionCard("批量选项") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("输出目录（留空 = 每个文件同目录）", text: $outputDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") {
                            chooseOutputDirectory()
                        }
                        .buttonStyle(.bordered)
                    }

                    Toggle("跳过已存在的输出", isOn: $skipExisting)
                    Toggle("某一项失败时停止整批", isOn: $stopOnError)

                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = model.validationMessage, !message.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            }

            Divider()

            HStack(spacing: 10) {
                Label("GPU 串行执行", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("取消") {
                    dismiss()
                }

                Button {
                    model.runBatch(
                        tool: tool,
                        files: files,
                        outputDirectory: outputDirectory,
                        skipExisting: skipExisting,
                        stopOnError: stopOnError
                    )
                } label: {
                    Label("开始批量", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(files.isEmpty || model.coordinator.isActive || model.job.state.isActive)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear {
            model.validationMessage = nil
            outputDirectory = model.values(for: tool)["outputDir"]?.stringValue ?? ""
            // 开发/截图用：预设批量目录
            if let prefilled = ProcessInfo.processInfo.environment["MCT_BATCH_DIR"],
               folder == nil,
               !prefilled.isEmpty {
                folder = URL(fileURLWithPath: prefilled)
                scan(URL(fileURLWithPath: prefilled))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ToolIconTile(tool: tool, size: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.manifest.batch?.title ?? "批量运行")
                    .font(.title3.weight(.semibold))
                Text("每个文件独立任务，逐项交付；失败项不影响已完成项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var summary: String {
        let values = model.values(for: tool)
        if values["backend"] != nil || values["reviewMode"] != nil {
            let backend = values["backend"]?.stringValue == "cloud" ? "云端转写" : "本地 whisper.cpp"
            let review: String
            switch values["reviewMode"]?.stringValue {
            case "llm": review = "LLM 校对"
            case "manual": review = "人工校对"
            default: review = "不校对"
            }
            let presetID = values["preset"]?.stringValue ?? ""
            let presetLabel = tool.manifest.inputs
                .first(where: { $0.key == "preset" })?
                .options?
                .first(where: { $0.value == presetID })?
                .label ?? presetID
            return "使用当前参数：\(backend) · \(presetLabel) · \(review)"
        }
        let target = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "与源文件同目录"
            : outputDirectory
        return "使用当前参数；\(files.count) 个文件 · 输出：\(target)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        scan(url)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url.path
    }

    private func scan(_ folder: URL) {
        scanError = nil
        let accept = Set(
            (tool.manifest.batch?.allAccept ?? ["mp4", "mov", "mkv", "m4v"])
                .map { $0.lowercased() }
        )

        var results: [URL] = []
        let manager = FileManager.default
        if recursive {
            if let enumerator = manager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    if accept.contains(url.pathExtension.lowercased()) {
                        results.append(url)
                    }
                }
            }
        } else {
            let urls = (try? manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            results = urls.filter { accept.contains($0.pathExtension.lowercased()) }
        }

        files = results.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.count > 1000 {
            files = Array(files.prefix(1000))
            scanError = "只取前 1000 个文件"
        }
    }
}
