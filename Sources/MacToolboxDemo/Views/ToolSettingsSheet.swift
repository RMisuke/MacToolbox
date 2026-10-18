import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct ToolSettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    let tool: LoadedTool
    @Environment(\.dismiss) private var dismiss

    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EnvironmentPanel(
                        doctor: model.doctor,
                        onRecheck: { model.recheckEnvironment(for: tool) },
                        onSetup: {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                model.showSetup = true
                            }
                        }
                    )

                    ForEach(model.groups(for: model.fullFields(for: tool))) { group in
                        SectionCard(group.title) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(group.fields) { field in
                                    ToolFieldRow(tool: tool, field: field)
                                }
                            }
                        }
                    }

                    Text("这些参数与「快速运行」共用；修改后立即生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    confirmReset = true
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("v\(tool.manifest.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 780, height: 720)
        .onAppear {
            model.recheckEnvironment(for: tool)
        }
        .confirmationDialog(
            "恢复默认参数？",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                model.resetDefaults(for: tool)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会覆盖当前的工具参数，但不会删除已有任务或产物。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ToolIconTile(tool: tool, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("高级设置")
                    .font(.title3.weight(.semibold))
                Text(tool.manifest.name)
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
