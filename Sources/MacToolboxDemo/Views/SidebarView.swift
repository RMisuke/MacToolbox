import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            brand
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)

            collectionPicker
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            List(selection: $model.destination) {
                Section {
                    row(.home)
                    row(.tasks)
                }

                Section("管理") {
                    row(.tools)
                    row(.settings)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            statusFooter
                .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            AppBrandIcon(size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("MacToolbox")
                    .font(.headline)
                Text(model.tools.count == 1 ? "1 个工具" : "\(model.tools.count) 个工具")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var collectionPicker: some View {
        Menu {
            ForEach(model.collections) { collection in
                Button {
                    model.selectCollection(collection.id)
                } label: {
                    if collection.id == model.selectedCollection.id {
                        Label(collection.name, systemImage: "checkmark")
                    } else {
                        Label(collection.name, systemImage: collection.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: model.selectedCollection.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.selectedCollection.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(model.selectedCollection.toolIDs.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("切换工具箱集合")
    }

    private func row(_ destination: AppModel.Destination) -> some View {
        Label(destination.title, systemImage: destination.icon)
            .tag(destination)
    }

    private var statusFooter: some View {
        Button {
            model.destination = .settings
            model.recheckEnvironment()
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.caption.weight(.medium))
                    Text(statusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        if model.doctor.checks.isEmpty { return .secondary }
        return model.environmentIssueCount == 0 ? .green : .orange
    }

    private var statusTitle: String {
        if model.doctor.checks.isEmpty { return "正在检测环境" }
        return model.environmentIssueCount == 0 ? "环境就绪" : "\(model.environmentIssueCount) 项需处理"
    }

    private var statusDetail: String {
        if model.doctor.checks.isEmpty { return "点击重新检测" }
        if model.environmentIssueCount == 0 { return "\(model.doctor.checks.count) 项检查通过" }
        return "点击查看设置"
    }
}
