import AppKit
import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct EnvironmentPanel: View {
    @ObservedObject var doctor: DoctorController
    let onRecheck: () -> Void
    let onSetup: () -> Void

    @State private var selectedCheck: EnvCheck?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("环境状态")
                    .font(.headline)
                if doctor.isChecking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    onRecheck()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(doctor.isChecking)

                Button {
                    onSetup()
                } label: {
                    Label("环境修复", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let error = doctor.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if doctor.checks.isEmpty && !doctor.isChecking {
                Text("尚未检测环境。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 138), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(doctor.checks) { check in
                        Button {
                            selectedCheck = check
                        } label: {
                            HStack(spacing: 6) {
                                StatusDot(status: check.status)
                                Text(check.label)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(check.status == "ok" ? "就绪" : (check.status == "warn" ? "注意" : "缺失"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .popover(item: $selectedCheck) { check in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(status: check.status)
                    Text(check.label).font(.headline)
                }
                if let detail = check.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fix = check.fixCommand, !fix.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("修复命令").font(.caption).foregroundStyle(.secondary)
                        Text(fix)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button("复制命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fix, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(16)
            .frame(width: 380, alignment: .leading)
        }
    }
}
