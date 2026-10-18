import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct TasksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmForceStop = false
    @State private var confirmClearFinished = false
    @State private var clearNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                ResourceUsagePanel()

                if model.agentJobs.hasJobs {
                    agentJobsCard
                }

                if !model.queuedJobs.isEmpty {
                    queuedJobsCard
                }

                if let group = model.coordinator.group {
                    currentGroupCard(group)
                }

                historySection

                if model.coordinator.group == nil && model.store.recentGroups.isEmpty {
                    ContentUnavailableView(
                        "还没有任务",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("从主页选一个工具开始，单任务和批量任务都会记录在这里。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "强制停止当前任务？",
            isPresented: $confirmForceStop,
            titleVisibility: .visible
        ) {
            Button("强制停止", role: .destructive) {
                model.coordinator.forceCancel()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会直接终止 Python 进程树（含 ffmpeg/whisper），未完成的中间产物保留在任务目录。")
        }
        .confirmationDialog(
            "清理已结束任务？",
            isPresented: $confirmClearFinished,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) {
                let count = model.store.clearFinishedGroups(
                    excluding: model.coordinator.group?.id
                )
                clearNotice = count > 0 ? "已清理 \(count) 个已结束任务组" : "没有可清理的任务"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清理已完成 / 失败 / 已取消的任务组及其记录；运行中、等待确认、已中断的任务会保留。")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("任务")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("单任务、批量组、排队任务、断点续跑都在这里。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.coordinator.isActive {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("资源池执行中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var agentJobsCard: some View {
        SectionCard("Agent / CLI 任务" + (model.agentJobs.activeCount > 0
            ? "（\(model.agentJobs.activeCount) 运行中）" : "")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.teal)
                    Text("来自 bin/mct、MCP 或脚本的任务；与 GUI 任务共用 GPU/网络/CPU 资源锁。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.agentJobs.jobs.contains(where: { !$0.isActive }) {
                        Button("清理已结束") {
                            model.agentJobs.clearFinished()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    Button {
                        model.agentJobs.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .help("立即刷新")
                }

                ForEach(Array(model.agentJobs.jobs.enumerated()), id: \.element.id) { index, job in
                    agentJobRow(job)
                    if index < model.agentJobs.jobs.count - 1 {
                        Divider()
                    }
                }

                if model.agentJobs.activeCount == 0 {
                    Text("当前没有运行中的 Agent 任务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = model.agentJobs.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func agentJobRow(_ job: AgentJobRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: agentIcon(job))
                    .foregroundStyle(agentColor(job))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(job.toolName) · \(job.sourceLabel) · \(job.id)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                AgentJobStatusPill(status: job.status, label: job.statusLabel, stale: job.isStale)
            }

            HStack(spacing: 10) {
                ProgressView(value: job.progressValue)
                    .frame(maxWidth: 260)
                Text("\(Int(job.progressValue * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let batchIndex = job.batchIndex, let batchTotal = job.batchTotal {
                    Text("批量 \(batchIndex)/\(batchTotal)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let updated = job.updatedAt {
                    Text(dateText(updated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = job.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let error = job.error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if let step = job.steps?.last(where: { $0.state == "running" }) {
                Text("当前步骤：\(step.title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let checkpoint = job.checkpoint {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Text("等待人工确认：\(checkpoint.title)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("在 CLI 运行 mct resume --job \(job.jobDir ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                if let dir = job.jobDir {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
                    } label: {
                        Label("打开目录", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    let text = "mct jobs show \(job.id) --json"
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(text, forType: .string)
                } label: {
                    Label("复制查看命令", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if job.isActive {
                    Button(role: .destructive) {
                        model.agentJobs.cancel(job)
                    } label: {
                        Label("取消", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                if let artifact = job.artifacts?.last {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: artifact.path)])
                    } label: {
                        Label(artifact.label ?? "查看产物", systemImage: "shippingbox")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func agentIcon(_ job: AgentJobRecord) -> String {
        if job.isStale { return "exclamationmark.triangle.fill" }
        switch job.status {
        case "running": return "play.circle.fill"
        case "queued": return "hourglass"
        case "waiting": return "hand.raised.fill"
        case "succeeded": return "checkmark.circle.fill"
        case "failed", "timeout": return "xmark.circle.fill"
        case "cancelled", "skipped": return "slash.circle.fill"
        case "interrupted": return "pause.circle.fill"
        default: return "circle"
        }
    }

    private func agentColor(_ job: AgentJobRecord) -> Color {
        if job.isStale { return .orange }
        switch job.status {
        case "running": return .blue
        case "queued": return .secondary
        case "waiting", "interrupted": return .orange
        case "succeeded": return .green
        case "failed", "timeout": return .red
        default: return .secondary
        }
    }

    private var queuedJobsCard: some View {
        SectionCard("排队中的单任务") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("当前任务结束后自动开始；最多保留 20 个。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全部清除") {
                        model.clearQueuedJobs()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }

                ForEach(model.queuedJobs) { job in
                    HStack(spacing: 8) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.itemLabel ?? job.toolName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(job.toolName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.removeQueuedJob(job.id)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func currentGroupCard(_ group: JobGroupRecord) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.headline)
                        Text(group.isBatch ? "批量任务组" : "单任务")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    GroupStatePill(state: group.state)
                }

                HStack(spacing: 10) {
                    ProgressView(value: model.coordinator.progress)
                    Text("\(Int(model.coordinator.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                let counts = model.store.counts(of: group)
                Text("\(counts.done)/\(counts.total) 完成\(counts.failed > 0 ? " · \(counts.failed) 失败" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let checkpoint = model.job.checkpoint {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.orange)
                        Text(checkpoint.title)
                            .font(.subheadline.weight(.medium))
                        Text(checkpoint.message ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("继续执行") {
                            model.job.continueCheckpoint()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.08)))
                }

                if group.isBatch {
                    VStack(spacing: 0) {
                        ForEach(model.coordinator.children) { child in
                            childRow(child, current: child.id == model.coordinator.currentChildID)
                            if child.id != model.coordinator.children.last?.id {
                                Divider().padding(.leading, 26)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                    )
                }

                if let message = model.job.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 10) {
                    Button {
                        model.showConsole = true
                    } label: {
                        Label("打开控制台", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)

                    if model.coordinator.isActive {
                        Button("停止") {
                            model.coordinator.cancel()
                        }
                        .tint(.red)

                        Button("强制停止") {
                            confirmForceStop = true
                        }
                        .tint(.red)
                        .buttonStyle(.bordered)
                    }

                    if (group.state == .failed || group.state == .interrupted), canResume(group) {
                        Button {
                            model.resumeGroup(group)
                        } label: {
                            Label("继续", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Spacer()

                    if let dir = currentDirectory {
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

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("历史")
                    .font(.headline)
                if let clearNotice {
                    Text(clearNotice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.store.recentGroups.isEmpty {
                    Text("\(model.store.recentGroups.count) 组")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.store.recentGroups.contains(where: {
                    $0.state == .succeeded || $0.state == .failed || $0.state == .cancelled
                }) {
                    Button("清理已结束…") {
                        confirmClearFinished = true
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }

            ForEach(historyGroups) { group in
                historyRow(group)
            }
        }
    }

    private var historyGroups: [JobGroupRecord] {
        let currentID = model.coordinator.group?.id
        return model.store.recentGroups.filter { $0.id != currentID }
    }

    private func historyRow(_ group: JobGroupRecord) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: group.isBatch ? "square.stack.3d.down.right" : "doc.text")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.subheadline.weight(.medium))
                        Text(dateText(group.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    GroupStatePill(state: group.state)
                }

                let counts = model.store.counts(of: group)
                HStack(spacing: 10) {
                    ProgressView(value: model.store.progress(of: group))
                        .frame(maxWidth: 260)
                    Text("\(counts.done)/\(counts.total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 8) {
                    if canResume(group) {
                        Button {
                            model.resumeGroup(group)
                        } label: {
                            Label("继续", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Button {
                        openGroupDirectory(group)
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(groupDirectory(group) == nil)

                    Spacer()

                    Button(role: .destructive) {
                        model.store.remove(groupID: group.id)
                    } label: {
                        Label("删除记录", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    private func childRow(_ child: JobRecord, current: Bool) -> some View {
        HStack(spacing: 8) {
            childIcon(child.state)
            Text(child.itemLabel ?? child.id)
                .font(.caption)
                .lineLimit(1)
            if current {
                Text("当前")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.blue.opacity(0.1)))
            }
            Spacer()
            Text(child.state.displayName)
                .font(.caption2)
                .foregroundStyle(stateColor(child.state))
            if child.state == .running || child.state == .waiting {
                ProgressView(value: child.progress)
                    .frame(width: 70)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(current ? Color.accentColor.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.openConsole(childID: child.id)
        }
        .help("打开该子任务控制台")
    }

    @ViewBuilder
    private func childIcon(_ state: JobStatus) -> some View {
        switch state {
        case .succeeded, .skipped:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle.fill").foregroundStyle(.secondary)
        case .interrupted:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .running:
            ProgressView().controlSize(.mini)
        case .waiting:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange)
        case .queued:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func stateColor(_ state: JobStatus) -> Color {
        switch state {
        case .succeeded, .skipped: return .green
        case .failed: return .red
        case .interrupted, .waiting: return .orange
        case .running: return .blue
        default: return .secondary
        }
    }

    private func canResume(_ group: JobGroupRecord) -> Bool {
        guard group.state == .interrupted || group.state == .failed else { return false }
        return model.store.children(of: group).contains {
            $0.state == .interrupted || $0.state == .failed || $0.state == .queued
        }
    }

    private func openGroupDirectory(_ group: JobGroupRecord) {
        guard let directory = groupDirectory(group) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func groupDirectory(_ group: JobGroupRecord) -> URL? {
        model.store.children(of: group)
            .compactMap { $0.jobDirectory }
            .first
            .map { URL(fileURLWithPath: $0) }
    }

    private var currentDirectory: URL? {
        if let path = model.coordinator.currentChild?.jobDirectory {
            return URL(fileURLWithPath: path)
        }
        if let group = model.coordinator.group {
            return groupDirectory(group)
        }
        return nil
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private struct GroupStatePill: View {
    let state: GroupStatus

    var color: Color {
        switch state {
        case .running: return .blue
        case .waiting: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .interrupted: return .orange
        case .cancelled: return .secondary
        case .queued: return .secondary
        }
    }

    var body: some View {
        Text(state.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.13)))
            .foregroundStyle(color)
    }
}

