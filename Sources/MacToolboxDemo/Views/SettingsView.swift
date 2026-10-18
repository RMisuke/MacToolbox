import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLexiconManager = false
    @State private var collectionEditor: CollectionEditorContext?
    @State private var collectionToDelete: CustomCollection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                EnvironmentPanel(
                    doctor: model.doctor,
                    onRecheck: { model.recheckEnvironment() },
                    onSetup: { model.showSetup = true }
                )

                SectionCard("运行数据") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(ToolboxPaths.applicationSupport.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        HStack(spacing: 10) {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([ToolboxPaths.applicationSupport])
                            } label: {
                                Label("在 Finder 中显示", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([ToolboxPaths.jobs])
                            } label: {
                                Label("打开任务目录", systemImage: "clock.arrow.circlepath")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                SectionCard("工具参数") {
                    VStack(spacing: 0) {
                        ForEach(Array(model.tools.enumerated()), id: \.element.id) { index, tool in
                            HStack(spacing: 10) {
                                ToolIconTile(tool: tool, size: 30)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.manifest.name)
                                        .font(.subheadline.weight(.medium))
                                    Text("v\(tool.manifest.version)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("恢复默认") {
                                    model.resetDefaults(for: tool)
                                }
                                .controlSize(.small)

                                Button("高级设置") {
                                    model.openSettings(tool)
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 8)

                            if index < model.tools.count - 1 {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                }

                SectionCard("词表") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let tool = model.primaryTool {
                            Text("内置示例 + 用户词表：\(model.lexiconProfiles(for: tool).count) 个；导入 txt / csv / json 后自动生成版本历史。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(model.lexiconStore.userProfilesDirectory.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            HStack(spacing: 10) {
                                Button {
                                    showLexiconManager = true
                                } label: {
                                    Label("管理词表…", systemImage: "text.book.closed")
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([
                                        model.lexiconStore.userProfilesDirectory
                                    ])
                                } label: {
                                    Label("打开词表目录", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Text("还没有加载到工具。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .sheet(isPresented: $showLexiconManager) {
                    if let tool = model.primaryTool {
                        LexiconManagerSheet(tool: tool)
                            .environmentObject(model)
                    }
                }

                SectionCard("工具箱集合") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(autoCollections) { collection in
                            collectionRow(collection, isCustom: false)
                            Divider().padding(.leading, 30)
                        }

                        if !model.customCollections.isEmpty {
                            Text("自定义集合")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.bottom, 2)

                            ForEach(model.customCollections) { custom in
                                customCollectionRow(custom)
                                Divider().padding(.leading, 30)
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                collectionEditor = CollectionEditorContext(existing: nil)
                            } label: {
                                Label("新建集合…", systemImage: "plus")
                            }
                            .controlSize(.small)

                            Text("自定义集合内可拖动工具排序；侧边栏会立即出现。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 10)
                    }
                }
                .sheet(item: $collectionEditor) { context in
                    CollectionEditorSheet(existing: context.existing)
                        .environmentObject(model)
                }
                .confirmationDialog(
                    "删除自定义集合？",
                    isPresented: Binding(
                        get: { collectionToDelete != nil },
                        set: { if !$0 { collectionToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        if let collection = collectionToDelete {
                            model.deleteCustomCollection(collection.id)
                        }
                        collectionToDelete = nil
                    }
                    Button("取消", role: .cancel) {
                        collectionToDelete = nil
                    }
                } message: {
                    Text("只删除集合，不删除工具和任务记录。")
                }

                SectionCard("通知") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "任务完成 / 失败 / 停止时发送系统通知",
                            isOn: Binding(
                                get: { model.prefs.notificationsEnabled },
                                set: { enabled in
                                    model.prefs.setNotificationsEnabled(enabled)
                                    if enabled {
                                        NotificationController.shared.requestAuthorization()
                                    }
                                }
                            )
                        )
                        Text("首次开启会请求 macOS 通知权限；菜单栏状态项始终可用。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                SectionCard("关于") {
                    HStack(alignment: .top, spacing: 12) {
                        if let tool = model.primaryTool {
                            ToolIconTile(tool: tool, size: 38)
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 38, height: 38)
                                .overlay(
                                    Image(systemName: "wrench.and.screwdriver")
                                        .foregroundStyle(.secondary)
                                )
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("MacToolbox Demo 0.1")
                                .font(.subheadline.weight(.semibold))
                            Text("原生 SwiftUI 外壳 · Tool Protocol · Python 工具后端")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("架构设计说明见仓库 docs/架构设计-v0.1.md")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var autoCollections: [ToolCollection] {
        model.collections.filter { !$0.id.hasPrefix("custom-") }
    }

    private func collectionRow(_ collection: ToolCollection, isCustom: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: collection.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(collection.name)
                    .font(.subheadline.weight(.medium))
                Text("\(collection.toolIDs.count) 个工具")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if collection.id == model.selectedCollection.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("切换") {
                    model.selectCollection(collection.id)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 7)
    }

    private func customCollectionRow(_ custom: CustomCollection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: custom.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(custom.name)
                    .font(.subheadline.weight(.medium))
                Text("\(custom.toolIDs.count) 个工具")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if custom.id == model.selectedCollection.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("切换") {
                    model.selectCollection(custom.id)
                }
                .controlSize(.small)
            }

            Button("编辑") {
                collectionEditor = CollectionEditorContext(existing: custom)
            }
            .controlSize(.small)

            Button(role: .destructive) {
                collectionToDelete = custom
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 7)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("设置")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("环境、数据目录与工具参数。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CollectionEditorContext: Identifiable {
    let id = UUID()
    let existing: CustomCollection?
}
