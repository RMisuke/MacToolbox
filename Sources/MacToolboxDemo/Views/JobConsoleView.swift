import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct JobConsoleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedChildID: String?

    var body: some View {
        Group {
            if let id = selectedChildID,
               let job = model.coordinator.runner(for: id) {
                RunnerConsoleView(job: job, selectedChildID: $selectedChildID)
                    .id(id)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("任务控制台")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Button("关闭") { dismiss() }
                    }
                    ConsoleChildPicker(selectedChildID: $selectedChildID)
                    ContentUnavailableView(
                        "该子任务尚未启动",
                        systemImage: "hourglass",
                        description: Text("等待资源或任务已结束；可以在上方切换其他子任务。")
                    )
                    Spacer()
                }
                .padding(20)
                .frame(width: 980, height: 700)
            }
        }
        .onAppear(perform: selectInitialChild)
    }

    private func selectInitialChild() {
        guard selectedChildID == nil else { return }
        if let requested = model.consoleChildID,
           model.coordinator.runner(for: requested) != nil {
            selectedChildID = requested
            return
        }
        selectedChildID = model.coordinator.currentChildID
            ?? model.coordinator.children.first?.id
    }
}

struct RunnerConsoleView: View {
    @ObservedObject var job: JobRunner
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedChildID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let checkpoint = job.checkpoint {
                checkpointBanner(checkpoint)
            }

            if !job.steps.isEmpty {
                stepTimeline
            }

            logSection

            if !job.artifacts.isEmpty {
                artifactSection
            }

            footer
        }
        .padding(20)
        .frame(width: 980, height: 700)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("任务控制台")
                        .font(.title2.weight(.semibold))
                    statePill
                }
                if let dir = job.jobDirectory {
                    Text(dir.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                if let group = model.coordinator.group {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if group.isBatch {
                            Text(groupProgressText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            ConsoleChildPicker(selectedChildID: $selectedChildID)

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

    private var groupProgressText: String {
        guard model.coordinator.group != nil else { return "" }
        let total = model.coordinator.children.count
        guard let id = selectedChildID,
              let index = model.coordinator.children.firstIndex(where: { $0.id == id }) else {
            return "共 \(total) 项"
        }
        return "第 \(index + 1)/\(total) 项 · 整组 \(Int(model.coordinator.progress * 100))%"
    }

    private var statePill: some View {
        Text(job.state.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(stateColor.opacity(0.13)))
            .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch job.state {
        case .running: return .blue
        case .waiting: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .idle: return .secondary
        }
    }

    private func checkpointBanner(_ checkpoint: Checkpoint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(checkpoint.title)
                    .font(.headline)
                Spacer()
            }
            if let message = checkpoint.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(checkpoint.artifacts ?? []) { artifact in
                    Button {
                        openArtifact(artifact)
                    } label: {
                        Label(artifact.label ?? artifact.kind, systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                Button {
                    job.continueCheckpoint()
                } label: {
                    Label("继续执行", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private var stepTimeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(job.steps) { step in
                    HStack(spacing: 6) {
                        stepIcon(step.state)
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(step.state == "pending" ? .secondary : .primary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: String) -> some View {
        switch state {
        case "done":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "running":
            ProgressView().controlSize(.mini)
        case "failed":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("日志")
                    .font(.headline)
                Spacer()
                if job.state.isActive {
                    Button("取消任务") {
                        job.cancel()
                    }
                    .controlSize(.small)
                    .tint(.red)
                }
            }
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if job.logs.isEmpty {
                            Text("等待输出…")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(job.logs) { line in
                            LogText(line: line)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                    .padding(10)
                }
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .onChange(of: job.logs.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var artifactSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("产物")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(job.artifacts, id: \.path) { artifact in
                        Button {
                            openArtifact(artifact)
                        } label: {
                            Label(artifact.label ?? artifact.kind, systemImage: icon(for: artifact.kind))
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                revealJobDirectory()
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            .disabled(job.jobDirectory == nil)

            Button {
                copyLogs()
            } label: {
                Label("复制日志", systemImage: "doc.on.doc")
            }
            .disabled(job.logs.isEmpty)

            Spacer()

            if job.state.isActive {
                Button("取消任务") {
                    job.cancel()
                }
                .tint(.red)
            }

            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "subtitle": return "captions.bubble"
        case "video": return "film"
        case "audio": return "waveform"
        case "report": return "checklist"
        case "json": return "curlybraces"
        default: return "doc"
        }
    }

    private func openArtifact(_ artifact: Artifact) {
        let url = URL(fileURLWithPath: artifact.path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private func revealJobDirectory() {
        guard let dir = job.jobDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func copyLogs() {
        let text = job.logs.map { $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


private struct ConsoleChildPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedChildID: String?

    var body: some View {
        if model.coordinator.children.count > 1 {
            Picker("", selection: Binding(
                get: { selectedChildID ?? "" },
                set: { selectedChildID = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(model.coordinator.children) { child in
                    Text("\(child.itemLabel ?? child.id) · \(child.state.displayName)")
                        .tag(child.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 300)
            .help("切换并发池中的子任务控制台")
        }
    }
}
