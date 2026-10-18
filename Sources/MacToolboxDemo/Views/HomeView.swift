import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    var body: some View {
        NavigationStack(path: $model.homePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    if searchText.isEmpty && !model.recentTools.isEmpty {
                        quickAccessRow(title: "最近使用", tools: Array(model.recentTools.prefix(5)))
                    }

                    if searchText.isEmpty && !model.favoriteTools.isEmpty {
                        quickAccessRow(title: "收藏", tools: Array(model.favoriteTools.prefix(5)))
                    }

                    if filteredTools.isEmpty {
                        ContentUnavailableView(
                            "没有匹配的工具",
                            systemImage: "square.grid.2x2",
                            description: Text("换个关键词，或切换到其他工具箱集合。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        ForEach(groupedTools, id: \.name) { group in
                            categorySection(group)
                        }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(model.runnableTools) { tool in
                            Button(tool.manifest.name) {
                                model.openQuickRun(tool)
                            }
                        }
                    } label: {
                        Label("快速运行", systemImage: "bolt.fill")
                    }
                    .help("快速运行（⌘R）；忙碌时加入队列")
                    .disabled(model.tools.isEmpty)
                }
            }
            .navigationDestination(for: String.self) { toolID in
                if let tool = model.tools.first(where: { $0.id == toolID }) {
                    ToolDetailView(tool: tool)
                        .environmentObject(model)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("工具箱")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(model.selectedCollection.id == "all"
                     ? "选一个工具，几秒钟开始。"
                     : "\(model.selectedCollection.name) · 选一个工具开始。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SearchField(text: $searchText, placeholder: "搜索工具")
        }
    }

    private func categorySection(_ group: ToolCategoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(group.name)
                    .font(.title3.weight(.semibold))
                Text("\(group.tools.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(model.displayTools(group.tools, in: model.selectedCollection)) { tool in
                    ToolCard(tool: tool) {
                        model.homePath.append(tool.id)
                    }
                    .environmentObject(model)
                }
            }
        }
    }

    private var filteredTools: [LoadedTool] {
        let base = model.tools(in: model.selectedCollection)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { tool in
            tool.manifest.name.localizedCaseInsensitiveContains(query)
                || (tool.manifest.summary ?? "").localizedCaseInsensitiveContains(query)
                || (tool.manifest.category ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func quickAccessRow(title: String, tools: [LoadedTool]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tools) { tool in
                        Button {
                            model.openQuickRun(tool)
                        } label: {
                            HStack(spacing: 7) {
                                ToolIconTile(tool: tool, size: 24)
                                Text(tool.manifest.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                if model.prefs.isPinned(tool.id) {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("查看详情") { model.homePath.append(tool.id) }
                            Button("高级设置") { model.openSettings(tool) }
                        }
                    }
                }
            }
        }
    }

    private var groupedTools: [ToolCategoryGroup] {
        if model.selectedCollection.id.hasPrefix("custom-") {
            return [ToolCategoryGroup(name: model.selectedCollection.name, tools: filteredTools)]
        }
        var order: [String] = []
        var grouped: [String: [LoadedTool]] = [:]
        for tool in filteredTools {
            let category = tool.manifest.category ?? "其他"
            if grouped[category] == nil {
                order.append(category)
            }
            grouped[category, default: []].append(tool)
        }
        return order.map { ToolCategoryGroup(name: $0, tools: grouped[$0] ?? []) }
    }
}

private struct ToolCategoryGroup {
    let name: String
    let tools: [LoadedTool]
}

struct ToolCard: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    let onOpen: () -> Void

    @State private var isHovering = false

    private var isRunning: Bool {
        model.coordinator.isActive && model.coordinator.group?.toolID == tool.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                ToolIconTile(tool: tool, size: 52)
                Spacer()
                HStack(spacing: 5) {
                    if model.prefs.isPinned(tool.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    if model.prefs.isFavorite(tool.id) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            Text(tool.manifest.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            Text(tool.manifest.summary ?? " ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 2)

            HStack(spacing: 8) {
                Text(tool.manifest.category ?? "工具")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(categoryColor(tool.manifest.category))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(categoryColor(tool.manifest.category).opacity(0.12)))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(height: 190)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isHovering ? categoryColor(tool.manifest.category).opacity(0.45) : Color.secondary.opacity(0.12),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(isHovering ? 0.10 : 0.035), radius: isHovering ? 10 : 3, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .contextMenu {
            Button {
                model.openQuickRun(tool)
            } label: {
                Label("快速运行", systemImage: "play.fill")
            }
            .disabled(model.job.state.isActive)

            if tool.manifest.batch != nil {
                Button {
                    model.openBatchRun(tool)
                } label: {
                    Label("批量运行…", systemImage: "square.stack.3d.down.right")
                }
                .disabled(model.job.state.isActive)
            }

            Button {
                model.openSettings(tool)
            } label: {
                Label("高级设置", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button {
                model.togglePinned(tool)
            } label: {
                Label(
                    model.prefs.isPinned(tool.id) ? "取消置顶" : "置顶",
                    systemImage: model.prefs.isPinned(tool.id) ? "pin.slash" : "pin"
                )
            }

            Button {
                model.toggleFavorite(tool)
            } label: {
                Label(
                    model.prefs.isFavorite(tool.id) ? "取消收藏" : "收藏",
                    systemImage: model.prefs.isFavorite(tool.id) ? "star.slash" : "star"
                )
            }

            Divider()

            Button {
                onOpen()
            } label: {
                Label("查看详情", systemImage: "info.circle")
            }
        }
    }
}
