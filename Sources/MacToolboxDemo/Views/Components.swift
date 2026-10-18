import SwiftUI
#if canImport(ToolboxCore)
import ToolboxCore
#endif

struct SectionCard<Content: View>: View {
    let title: String?
    let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct StatusDot: View {
    let status: String

    var color: Color {
        switch status {
        case "ok": return .green
        case "warn": return .orange
        default: return .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

struct ToolIconTile: View {
    let tool: LoadedTool
    var size: CGFloat = 46

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        categoryColor(tool.manifest.category).opacity(0.95),
                        categoryColor(tool.manifest.category).opacity(0.62)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: tool.manifest.icon ?? "wrench.and.screwdriver")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            )
            .shadow(color: categoryColor(tool.manifest.category).opacity(0.22), radius: 5, y: 2)
    }
}

func categoryColor(_ category: String?) -> Color {
    switch category {
    case "媒体": return .blue
    case "文档": return .orange
    case "开发": return .purple
    case "系统": return .teal
    default: return .accentColor
    }
}

struct JobStatePill: View {
    let state: JobRunner.State

    var color: Color {
        switch state {
        case .running: return .blue
        case .waiting: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .idle: return .secondary
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

struct AgentJobStatusPill: View {
    let status: String
    let label: String
    let stale: Bool

    var color: Color {
        if stale { return .orange }
        switch status {
        case "running": return .blue
        case "queued": return .secondary
        case "waiting": return .orange
        case "succeeded": return .green
        case "failed", "timeout": return .red
        case "cancelled", "skipped": return .secondary
        case "interrupted": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Text(stale ? "可能已中断" : label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.13)))
            .foregroundStyle(color)
    }
}

struct LogText: View {
    let line: LogLine

    var color: Color {
        switch line.level {
        case "error": return .red
        case "warn": return .orange
        case "stderr": return .secondary
        default: return .primary
        }
    }

    var body: some View {
        Text(line.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .frame(width: 240)
    }
}
