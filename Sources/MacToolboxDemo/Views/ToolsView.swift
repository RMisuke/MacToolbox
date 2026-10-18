import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct ToolsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path = NavigationPath()
    @State private var showNewTool = ProcessInfo.processInfo.environment["MCT_SHOW_NEW_TOOL"] == "1"

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if !model.toolIssues.isEmpty {
                        issuesSection
                    }

                    SectionCard("已安装（\(model.tools.count)）") {
                        VStack(spacing: 0) {
                            ForEach(Array(model.tools.enumerated()), id: \.element.id) { index, tool in
                                toolRow(tool)
                                if index < model.tools.count - 1 {
                                    Divider().padding(.leading, 54)
                                }
                            }
                            if model.tools.isEmpty {
                                Text("还没有可用工具。可以从模板新建，或把 `.toolbox` 放进用户工具目录。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            }
                        }
                    }

                    SectionCard("添加工具") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("从模板新建一个可运行的工具包，或把现成的 `.toolbox` 放进用户工具目录；改完点「重新扫描」即可，不必重启。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.userToolsDirectory.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                Button {
                                    showNewTool = true
                                } label: {
                                    Label("新建工具…", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    try? FileManager.default.createDirectory(
                                        at: model.userToolsDirectory,
                                        withIntermediateDirectories: true
                                    )
                                    NSWorkspace.shared.activateFileViewerSelecting([model.userToolsDirectory])
                                } label: {
                                    Label("打开工具目录", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    model.reloadTools()
                                } label: {
                                    Label("重新扫描", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)

                                if let guide = ToolScaffold.guideURL() {
                                    Button {
                                        NSWorkspace.shared.open(guide)
                                    } label: {
                                        Label("开发指南", systemImage: "book")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationDestination(for: String.self) { toolID in
                if let tool = model.tools.first(where: { $0.id == toolID }) {
                    ToolDetailView(tool: tool)
                        .environmentObject(model)
                }
            }
        }
        .sheet(isPresented: $showNewTool) {
            NewToolSheet()
                .environmentObject(model)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("工具管理")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("已安装的工具包、工具目录和校验结果。新增工具只需要 manifest + 脚本。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showNewTool = true
            } label: {
                Label("新建工具…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var issuesSection: some View {
        SectionCard("工具问题（\(model.toolIssues.count)）") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.toolIssues) { issue in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: issue.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.isError ? .red : .orange)
                            .font(.caption)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(issue.isError ? .red : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(issue.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(issue.isError ? "错误" : "警告")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(issue.isError ? .red : .orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((issue.isError ? Color.red : Color.orange).opacity(0.10)))
                    }
                    if issue.id != model.toolIssues.last?.id {
                        Divider()
                    }
                }
                Text("无效工具不会出现在上方列表；修正后点「重新扫描」。命令行校验：`python3 scripts/tool_lint.py --all`")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toolRow(_ tool: LoadedTool) -> some View {
        HStack(spacing: 12) {
            ToolIconTile(tool: tool, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.manifest.name)
                        .font(.headline)
                    Text("v\(tool.manifest.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if isUserTool(tool) {
                        Text("用户")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.10)))
                    }
                    if tool.hasCLI {
                        Text("CLI")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.teal.opacity(0.10)))
                            .help("Agent CLI：mct describe \(tool.id) --json")
                    }
                }
                Text(tool.manifest.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if tool.id == model.primaryTool?.id, !model.doctor.checks.isEmpty {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.environmentIssueCount == 0 ? .green : .orange)
                        .frame(width: 6, height: 6)
                    Text(model.environmentIssueCount == 0 ? "就绪" : "\(model.environmentIssueCount) 项")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                model.togglePinned(tool)
            } label: {
                Image(systemName: model.prefs.isPinned(tool.id) ? "pin.fill" : "pin")
                    .foregroundStyle(model.prefs.isPinned(tool.id) ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(model.prefs.isPinned(tool.id) ? "取消置顶" : "置顶")

            Button {
                model.toggleFavorite(tool)
            } label: {
                Image(systemName: model.prefs.isFavorite(tool.id) ? "star.fill" : "star")
                    .foregroundStyle(model.prefs.isFavorite(tool.id) ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(model.prefs.isFavorite(tool.id) ? "取消收藏" : "收藏")

            if !tool.isNative {
                Button {
                    model.openSettings(tool)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("高级设置")
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            path.append(tool.id)
        }
        .contextMenu {
            Button(model.prefs.isPinned(tool.id) ? "取消置顶" : "置顶") {
                model.togglePinned(tool)
            }
            Button(model.prefs.isFavorite(tool.id) ? "取消收藏" : "收藏") {
                model.toggleFavorite(tool)
            }
            Divider()
            if !tool.isNative {
                Button("高级设置") { model.openSettings(tool) }
            }
            if tool.manifest.batch != nil {
                Button("批量运行…") { model.openBatchRun(tool) }
            }
            Divider()
            Button("复制 Agent 描述命令") {
                copyToPasteboard("mct describe \(tool.id) --json")
            }
            if tool.hasCLI {
                Button("复制 CLI 运行模板") {
                    let key = tool.primaryPathKey
                        ?? tool.manifest.inputs.first?.key
                        ?? "key"
                    copyToPasteboard("mct run \(tool.id) --input \(key)=<value> --json")
                }
            }
            if !tool.isNative {
                Button("恢复默认参数") { model.resetDefaults(for: tool) }
            }
        }
    }

    private func isUserTool(_ tool: LoadedTool) -> Bool {
        tool.directory.path.hasPrefix(model.userToolsDirectory.path + "/")
    }

    private func copyToPasteboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
