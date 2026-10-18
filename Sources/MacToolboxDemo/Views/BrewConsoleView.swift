import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct BrewConsoleView: View {
    @ObservedObject var operation: BrewOperation
    let onCancel: () -> Void
    let onHide: () -> Void
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(operation.lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.stream == "stderr" ? Color.secondary : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                        if operation.lines.isEmpty {
                            Text("等待输出…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: operation.lines.count) { _, _ in
                    guard let last = operation.lines.last else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
#if os(macOS)
        .onExitCommand {
            if operation.state == .running {
                hide()
            } else {
                close()
            }
        }
#endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: stateIcon)
                .font(.title2)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .font(.headline)
                Text(operation.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(stateText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(stateColor.opacity(0.12)))
            Button {
                if operation.state == .running {
                    hide()
                } else {
                    close()
                }
            } label: {
                Image(systemName: operation.state == .running ? "chevron.down.circle.fill" : "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(operation.state == .running ? "收纳到后台，升级继续运行" : "关闭")
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("开始 \(operation.startedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let finished = operation.finishedAt {
                Text("结束 \(finished.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let code = operation.exitCode {
                Text("退出码 \(code)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(code == 0 ? Color.secondary : Color.red)
            }
            Spacer()
            if operation.state == .running {
                Button {
                    hide()
                } label: {
                    Label("收纳到后台", systemImage: "chevron.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button("取消任务", role: .destructive) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button("关闭") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private var stateText: String {
        switch operation.state {
        case .running: return "运行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private var stateIcon: String {
        switch operation.state {
        case .running: return "terminal.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private var stateColor: Color {
        switch operation.state {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private func hide() {
        onHide()
        dismiss()
    }

    private func close() {
        onClose()
        dismiss()
    }
}
