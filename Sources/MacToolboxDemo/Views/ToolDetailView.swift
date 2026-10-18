import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct ToolDetailView: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool

    @ViewBuilder
    var body: some View {
        Group {
            if tool.manifest.nativeView == "homebrew" {
                BrewManagerView()
                    .environmentObject(model)
                    .environmentObject(model.brewService)
            } else if tool.manifest.nativeView == "imageOCR" {
                ImageOCRView(tool: tool)
            } else {
                standardBody
            }
        }
        .onAppear {
            // 启动时只检测 tools.first；进入具体工具时补一次，避免新工具
            // 的环境行一直停留在「正在检测环境」。
            if !tool.isNative {
                model.recheckEnvironment(for: tool)
            }
        }
        .onReceive(model.doctor.objectWillChange) { _ in }
    }

    private var standardBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                environmentLine
                quickCard

                if model.job.state != .idle {
                    currentJob
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        model.openSettings(tool)
                    } label: {
                        Label("全部参数…", systemImage: "slider.horizontal.3")
                    }
                    if tool.manifest.batch != nil {
                        Button {
                            model.openBatchRun(tool)
                        } label: {
                            Label("批量运行…", systemImage: "square.stack.3d.down.right")
                        }
                    }
                    Button {
                        model.recheckEnvironment(for: tool)
                    } label: {
                        Label("重新检测环境", systemImage: "arrow.clockwise")
                    }
                    Button {
                        model.resetDefaults(for: tool)
                    } label: {
                        Label("恢复默认参数", systemImage: "arrow.counterclockwise")
                    }
                    Divider()
                    Button {
                        copyToPasteboard("mct describe \(tool.id) --json")
                    } label: {
                        Label("复制 Agent 描述命令", systemImage: "terminal")
                    }
                    if tool.hasCLI {
                        Button {
                            let key = tool.primaryPathKey
                                ?? tool.manifest.inputs.first?.key
                                ?? "key"
                            copyToPasteboard("mct run \(tool.id) --input \(key)=<value> --json")
                        } label: {
                            Label("复制 CLI 运行模板", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    Divider()
                    Button {
                        model.showSetup = true
                    } label: {
                        Label("环境修复…", systemImage: "wrench.and.screwdriver")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .help("高级操作")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ToolIconTile(tool: tool, size: 64)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(tool.manifest.name)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("v\(tool.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }
                Text(tool.manifest.summary ?? "")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let category = tool.manifest.category {
                        Text(category)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(categoryColor(category))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(categoryColor(category).opacity(0.12)))
                    }
                    if tool.hasCLI {
                        Label("Agent CLI", systemImage: "terminal")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.teal.opacity(0.10)))
                            .help("mct describe \(tool.id) --json")
                    }
                }
            }

            Spacer()
        }
    }

    private var environmentLine: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(environmentColor)
                .frame(width: 8, height: 8)

            Text(environmentText)
                .font(.subheadline)

            Spacer()

            Button("重新检测") {
                model.recheckEnvironment(for: tool)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Button("环境修复") {
                model.showSetup = true
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    private var quickCard: some View {
        SectionCard(tool.manifest.quick?.title ?? "快速开始") {
            VStack(alignment: .leading, spacing: 16) {
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
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                }

                HStack(spacing: 12) {
                    Button {
                        model.openSettings(tool)
                    } label: {
                        Label("全部参数…", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)

                    if tool.manifest.batch != nil {
                        Button {
                            model.openBatchRun(tool)
                        } label: {
                            Label("批量…", systemImage: "square.stack.3d.down.right")
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("其余参数使用已保存设置")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        model.validationMessage = nil
                        model.run(tool: tool)
                    } label: {
                        Label(
                            model.job.state.isActive || model.coordinator.isActive ? "加入队列" : "开始运行",
                            systemImage: model.job.state.isActive || model.coordinator.isActive
                                ? "text.badge.plus" : "play.fill"
                        )
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private var currentJob: some View {
        SectionCard("当前任务") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    JobStatePill(state: model.job.state)
                    if let name = model.jobToolName {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(model.job.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: model.job.progress)

                if let step = model.job.steps.last(where: { $0.state == "running" }) {
                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        model.showConsole = true
                    } label: {
                        Label("打开控制台", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)

                    if model.job.state.isActive {
                        Button("取消任务") {
                            model.job.cancel()
                        }
                        .tint(.red)
                    }

                    Spacer()

                    if let dir = model.job.jobDirectory {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private var environmentColor: Color {
        if model.doctor.checks.isEmpty { return .secondary }
        return model.environmentIssueCount == 0 ? .green : .orange
    }

    private var environmentText: String {
        if model.doctor.isChecking { return "正在检测环境…" }
        if model.doctor.checks.isEmpty {
            return model.doctor.errorMessage == nil ? "环境未检测" : "环境检测异常"
        }
        if model.environmentIssueCount == 0 { return "环境就绪" }
        return "\(model.environmentIssueCount) 项需要处理，打开「环境修复」查看"
    }
}
