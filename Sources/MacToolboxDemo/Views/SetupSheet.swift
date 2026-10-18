import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct SetupSheet: View {
    @ObservedObject var setup: SetupController
    let tool: LoadedTool
    let values: [String: FieldValue]
    let initialChecks: [EnvCheck]
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("环境修复")
                        .font(.title2.weight(.semibold))
                    Text("自动安装 ffmpeg / whisper.cpp、下载模型、修复 jieba。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") {
                    dismiss()
                    onClose()
                }
            }

            if !displayChecks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(displayChecks) { check in
                            HStack(spacing: 6) {
                                StatusDot(status: check.status)
                                Text(check.label).font(.caption)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }

            if let summary = setup.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(setup.errorMessage == nil ? Color.secondary : Color.red)
            }
            if let error = setup.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(setup.logs) { line in
                            LogText(line: line)
                        }
                        Color.clear.frame(height: 1).id("setup-bottom")
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
                .onChange(of: setup.logs.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("setup-bottom", anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    setup.start(tool: tool, values: values)
                } label: {
                    Label("开始自动修复", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(setup.isRunning)

                Button("取消") {
                    setup.cancel()
                }
                .disabled(!setup.isRunning)

                Spacer()

                if setup.isRunning {
                    ProgressView().controlSize(.small)
                    Text("修复中…").font(.caption).foregroundStyle(.secondary)
                } else if setup.isFinished {
                    Text("修复结束").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(22)
        .frame(width: 860, height: 600)
    }

    private var displayChecks: [EnvCheck] {
        setup.checks.isEmpty ? initialChecks : setup.checks
    }
}
