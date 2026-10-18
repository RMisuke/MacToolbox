import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct ResourceUsagePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionCard("资源占用") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    resourceRow("GPU", key: "gpu", icon: "cpu")
                    resourceRow("网络", key: "network", icon: "network")
                    resourceRow("CPU", key: "cpu", icon: "square.stack.3d.up")
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(model.coordinator.activeRunnerCount > 0 ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(model.coordinator.activeRunnerCount > 0
                         ? "运行中的子任务：\(model.coordinator.activeRunnerCount)"
                         : "空闲")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("资源容量由工具的 resources 声明")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func resourceRow(_ title: String, key: String, icon: String) -> some View {
        let capacity = model.resourceMonitor.capacities[key] ?? 0
        let usage = model.resourceMonitor.usage[key] ?? 0
        let fraction = capacity > 0 ? min(Double(usage) / Double(capacity), 1) : 0

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(usage)/\(capacity)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(usage >= capacity && capacity > 0 ? .orange : .secondary)
            }

            ProgressView(value: fraction)
                .tint(usage >= capacity && capacity > 0 ? .orange : .accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
