import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct NewToolSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var toolID = "demo.hello"
    @State private var name = "示例工具"
    @State private var category = "示例"
    @State private var summary = "从模板创建的 MacToolbox 工具"
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新建工具")
                        .font(.title3.weight(.semibold))
                    Text("从 `_template.toolbox` 复制一个可运行的工具骨架，再改脚本。")
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

            SectionCard("身份") {
                VStack(alignment: .leading, spacing: 12) {
                    field("工具 ID", text: $toolID, placeholder: "demo.hello")
                    Text("反向域名风格；只能用小写字母、数字、点、下划线和短横线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    field("显示名称", text: $name, placeholder: "示例工具")
                    field("分类", text: $category, placeholder: "示例")
                    field("一句话说明", text: $summary, placeholder: "这个工具做什么")
                }
            }

            SectionCard("创建位置") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.userToolsDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("创建后会自动重新扫描；模板带有可运行的 Python 脚本、doctor/setup 和 4 个示例输入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            }

            Divider()

            HStack {
                if let guide = ToolScaffold.guideURL() {
                    Button("打开开发指南") {
                        NSWorkspace.shared.open(guide)
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("创建工具", systemImage: "plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func create() {
        errorMessage = nil
        isCreating = true
        Task {
            do {
                let url = try await ToolScaffold.create(
                    id: toolID,
                    name: name,
                    category: category,
                    summary: summary
                )
                await MainActor.run {
                    model.reloadTools()
                    isCreating = false
                    if !model.tools.contains(where: { $0.id == toolID }) {
                        errorMessage = "工具已创建，但没有通过扫描。请用 tool_lint.py 检查 \(url.path)。"
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
