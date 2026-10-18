import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let group = model.coordinator.group {
            Text(group.title)
            Text(group.state.displayName + " · \(Int(model.coordinator.progress * 100))%")
            ProgressView(value: model.coordinator.progress)
                .frame(width: 220)
            if let child = model.coordinator.currentChild {
                Text(child.itemLabel ?? child.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("显示主窗口") { showMainWindow() }
            Button("打开任务") {
                model.destination = .tasks
                showMainWindow()
            }
            if group.state == .waiting {
                Button("继续执行") { model.job.continueCheckpoint() }
            }
            if model.coordinator.isActive {
                Button("停止") { model.coordinator.cancel() }
                Button("强制停止") { model.coordinator.forceCancel() }
            }
        } else {
            Text(model.agentJobs.activeCount > 0
                 ? "空闲（Agent 任务 \(model.agentJobs.activeCount) 运行中）"
                 : "空闲")
            if model.agentJobs.activeCount > 0 {
                ForEach(model.agentJobs.jobs.filter(\.isActive).prefix(3)) { job in
                    Text("\(job.displayTitle) · \(job.statusLabel) \(Int(job.progressValue * 100))%")
                        .font(.caption)
                }
                Button("打开任务") {
                    model.destination = .tasks
                    showMainWindow()
                }
            }
            Button("显示主窗口") { showMainWindow() }
        }

        Divider()
        Button("退出 MacToolbox") { NSApp.terminate(nil) }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
