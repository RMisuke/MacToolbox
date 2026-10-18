import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct QuickRunSheet: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if model.environmentIssueCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("环境有 \(model.environmentIssueCount) 项需要处理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("查看") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            model.destination = .settings
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.link)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            }

            ToolForm(
                tool: tool,
                fields: model.quickFields(for: tool),
                showsGroupCards: false,
                compact: true
            )
            .environmentObject(model)

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

            if model.values(for: tool)["reviewMode"]?.stringValue == "manual" {
                Label("人工校对会在转写后暂停，等你在控制台点「继续执行」。", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        model.openSettings(tool)
                    }
                } label: {
                    Label("全部参数…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)

                Text("其余参数使用已保存设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("取消") {
                    dismiss()
                }

                Button {
                    model.validationMessage = nil
                    model.run(tool: tool)
                } label: {
                    Label(
                        model.job.state.isActive || model.coordinator.isActive ? "加入队列" : "开始运行",
                        systemImage: model.job.state.isActive || model.coordinator.isActive
                            ? "text.badge.plus" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ToolIconTile(tool: tool, size: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.manifest.name)
                    .font(.title3.weight(.semibold))
                Text(tool.manifest.quick?.title ?? "快速运行")
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
}
